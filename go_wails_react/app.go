package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"mdb2sql/backend"
	"mdb2sql/i18n"
	"os"
	"path/filepath"
	goruntime "runtime"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// wails.json e a fonte unica da versao (info.productVersion); o Wails CLI usa o mesmo campo no recurso do exe
// !T: Single source of the app version, embedded so the About dialog and the exe resource always agree
//
//go:embed wails.json
var wailsJSON []byte

// Numero e data do build, gravados por scripts\build_w11.ps1 (-ldflags -X); vazios = "build dev"
var (
	buildNumber string
	buildDate   string
)

// App struct principal do Wails - contem contexto e DB manager
// !T: Main Wails application struct holding context and database manager singleton
type App struct {
	ctx       context.Context
	dbManager *backend.DBManager
	dbName    string
	dbPath    string // resolved path of the open file; default folder of the save dialogs
	settings  Settings

	// Access file converted to SQLite: the file (temporary until saved or deleted) and the Access file it came from
	converted, convertedFrom string
	convChoice               string          // "save" or "delete" remembered for this session ("" = ask)
	convDir                  string          // folder of the last "save", used when "save" is remembered
	convertedFromKey         string          // fileKey of the Access file converted now
	displayWarn              *DisplayWarning // Linux: X11 missing, running on Wayland (display.go)

	jobMu        sync.Mutex
	cancel       context.CancelFunc // of the running load or export
	queryCancel  context.CancelFunc // of the running SQL tab query (one at a time)
	querySeq     int
	searchCancel context.CancelFunc // of the running "All tables" search
	countCancel  context.CancelFunc // of the running row count of the table list
}

// AppInfo alimenta o dialogo Sobre: versao do app e versoes de runtime lidas em execucao
// !T: Data for the About dialog; React adds its own version on the frontend side
type AppInfo struct {
	Version   string `json:"version"`
	Build     string `json:"build"`
	BuildDate string `json:"buildDate"`
	Go        string `json:"go"`
	Wails     string `json:"wails"`
	DuckDB    string `json:"duckdb"`
	Access    string `json:"access"`  // reader an Access file would use now: "Access ODBC", "mdbtools" or ""
	Webview   string `json:"webview"` // what draws the window: "WebView2 158.0.4370.33", "WebKitGTK"
	// "mdbtools 1.0.1" (embedded) or "mdbtools" (on PATH, MdbtoolsSystem); "" = none
	Mdbtools       string `json:"mdbtools"`
	MdbtoolsSystem bool   `json:"mdbtoolsSystem"`
}

func productVersion() string {
	var cfg struct {
		Info struct {
			ProductVersion string `json:"productVersion"`
		} `json:"info"`
	}
	if err := json.Unmarshal(wailsJSON, &cfg); err != nil || cfg.Info.ProductVersion == "" {
		return "unknown"
	}
	return cfg.Info.ProductVersion
}

// wailsVersion le a versao do modulo Wails realmente linkado no binario
func wailsVersion() string {
	if bi, ok := debug.ReadBuildInfo(); ok {
		for _, dep := range bi.Deps {
			if dep.Path == "github.com/wailsapp/wails/v2" {
				return dep.Version
			}
		}
	}
	return "unknown"
}

// GetAppInfo retorna versao do app e dos runtimes para o dialogo Sobre
func (a *App) GetAppInfo() AppInfo {
	duck, err := backend.DuckDBVersion()
	if err != nil {
		duck = "unknown"
	}
	mdbtools, system := backend.MdbtoolsLabel()
	return AppInfo{
		Version:        productVersion(),
		Build:          buildNumber,
		BuildDate:      buildDate,
		Go:             strings.TrimPrefix(goruntime.Version(), "go"),
		Wails:          wailsVersion(),
		DuckDB:         duck,
		Access:         backend.AccessReader(),
		Webview:        webviewVersion(),
		Mdbtools:       mdbtools,
		MdbtoolsSystem: system,
	}
}

// DatabaseName retorna o nome do arquivo aberto (sem pasta); "" se nenhum
// !T: The frontend cannot know which file an empty path resolved to (MDB2SQL_DB_PATH or sample)
func (a *App) DatabaseName() string {
	return a.dbName
}

// DatabasePath is the full path of the open file ("" if none): the path field of the top bar shows it
func (a *App) DatabasePath() string {
	return a.dbPath
}

// SourceKind diz por qual leitor o arquivo foi aberto (DuckDB, SQLite, Access ODBC, mdbtools)
func (a *App) SourceKind() string {
	return a.dbManager.Source()
}

// Cria nova instancia App com DB manager inicializado
// !T: Factory function returning App with initialized database manager singleton
func NewApp() *App {
	return &App{
		dbManager: backend.NewDBManager(),
		settings:  loadSettings(),
	}
}

// Callback de startup chamado quando app inicia - salva contexto
// !T: Wails lifecycle hook called on app startup, stores context for runtime methods
func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	if n := backend.CleanStaleConverted(); n > 0 {
		a.logText(i18n.N("log.staleRemoved", n, n))
	}
}

// log sends one line to the Log panel (View > Log) in the current language
func (a *App) log(key string, args ...any) {
	a.logText(i18n.T(key, args...))
}

func (a *App) logText(text string) {
	if a.ctx != nil { // nil in tests: the Wails runtime only works inside the app
		runtime.EventsEmit(a.ctx, "log", text)
	}
}

// beforeClose (window close button, Exit): a converted SQLite file still pending makes the UI ask first
func (a *App) beforeClose(ctx context.Context) bool {
	if a.converted == "" {
		return false
	}
	if a.convChoice != "" {
		if _, err := a.resolveConversion(a.convChoice); err == nil {
			return false
		}
	}
	runtime.EventsEmit(ctx, "conversion-pending", "exit")
	return true
}

// shutdown: never leave the temporary SQLite behind (normally beforeClose already resolved it); Close waits for the
// reads in progress, so a running load, export, query or search is stopped first
func (a *App) shutdown(context.Context) {
	a.CancelJob()
	a.cancelReads()
	a.dbManager.Close()
	backend.RemoveConverted(a.converted)
}

// ConversionResult: Done = the converted file was saved or deleted (and the database closed); Saved = its new path
type ConversionResult struct {
	Done  bool   `json:"done"`
	Saved string `json:"saved"`
}

// PendingConversion is the name of the converted SQLite file still waiting for "save or delete" ("" = none);
// RememberedChoice tells whether the user already chose for the session (then the UI does not ask)
func (a *App) PendingConversion() string {
	if a.converted == "" {
		return ""
	}
	return backend.ConvertedName(a.convertedFrom)
}

func (a *App) RememberedChoice() string { return a.convChoice }

// ResolveConversion applies the user's answer: "save" (save dialog, next to the Access file by default), "delete"
// or "cancel"; remember keeps "save"/"delete" for the rest of the session (not written to the settings)
func (a *App) ResolveConversion(choice string, remember bool) (ConversionResult, error) {
	if choice != "save" && choice != "delete" {
		return ConversionResult{}, nil
	}
	res, err := a.resolveConversion(choice)
	if err == nil && res.Done && remember {
		a.convChoice = choice
	}
	return res, err
}

func (a *App) resolveConversion(choice string) (ConversionResult, error) {
	if a.converted == "" {
		return ConversionResult{Done: true}, nil
	}
	dest := ""
	if choice == "save" {
		name := backend.ConvertedName(a.convertedFrom)
		if a.convChoice == "save" && existingDir(a.convDir) != "" {
			dest = backend.UniquePath(a.convDir, name) // remembered: same folder, never over an existing file
		} else {
			var err error
			dest, err = runtime.SaveFileDialog(a.ctx, runtime.SaveDialogOptions{
				Title:            i18n.T("dlg.saveConverted"),
				DefaultDirectory: existingDir(filepath.Dir(a.convertedFrom)),
				DefaultFilename:  name,
				Filters:          []runtime.FileFilter{{DisplayName: i18n.T("filter.sqliteOut"), Pattern: "*.sqlite"}},
			})
			if err != nil || dest == "" {
				return ConversionResult{}, err
			}
			if !strings.EqualFold(filepath.Ext(dest), ".sqlite") {
				dest += ".sqlite"
			}
			if ok, err := a.replaceOK(dest); !ok {
				return ConversionResult{}, err
			}
		}
	}
	a.closeDatabase()
	file, from := a.converted, a.convertedFrom
	a.converted, a.convertedFrom = "", ""
	if dest == "" {
		if err := backend.RemoveConverted(file); err != nil {
			return ConversionResult{Done: true}, err
		}
		a.log("log.convertedDeleted", filepath.Base(file))
		return ConversionResult{Done: true}, nil
	}
	if err := backend.SaveConverted(file, dest); err != nil {
		backend.RemoveConverted(file)
		return ConversionResult{Done: true}, fmt.Errorf("%s: %w", dest, err)
	}
	a.convDir = filepath.Dir(dest)
	a.rememberConversion(from, a.convertedFromKey, dest)
	a.log("log.convertedSaved", dest)
	return ConversionResult{Done: true, Saved: dest}, nil
}

// fileKey identifies a file version: path, size and modification time ("" if it cannot be read)
func fileKey(path string) string {
	st, err := os.Stat(path)
	if err != nil {
		return ""
	}
	return fmt.Sprintf("%s|%d|%d", strings.ToLower(path), st.Size(), st.ModTime().UnixNano())
}

// rememberConversion keeps in the settings, between runs, the SQLite saved from an Access file: the Access file's
// fileKey (path, size, date), the saved file and its own fileKey (standard item 22). One entry per Access file.
func (a *App) rememberConversion(src, srcKey, dest string) {
	if src == "" || srcKey == "" {
		return
	}
	if a.settings.Converted == nil {
		a.settings.Converted = map[string]SavedConversion{}
	}
	a.settings.Converted[strings.ToLower(src)] = SavedConversion{Key: srcKey, Dest: dest, DestKey: fileKey(dest)}
	_ = a.saveSettings() // best effort: unsaved, the next run converts the file again
}

// savedConversion returns the SQLite saved from this same Access file, in this run or an earlier one, if neither file
// changed since; a changed one is forgotten, so the file is converted again
func (a *App) savedConversion(src string) string {
	if ext := strings.ToLower(filepath.Ext(src)); ext != ".accdb" && ext != ".mdb" {
		return ""
	}
	id := strings.ToLower(src)
	s, ok := a.settings.Converted[id]
	if !ok {
		return ""
	}
	if s.Key != "" && s.Key == fileKey(src) && s.DestKey != "" && fileKey(s.Dest) == s.DestKey {
		return s.Dest
	}
	delete(a.settings.Converted, id)
	_ = a.saveSettings()
	return ""
}

// replaceOK asks before writing over an existing file: the Wails save dialog does not ask (seen with the
// release exe: Save over an existing name replaced it without a prompt)
func (a *App) replaceOK(path string) (bool, error) {
	if _, err := os.Stat(path); err != nil {
		return true, nil
	}
	ans, err := runtime.MessageDialog(a.ctx, runtime.MessageDialogOptions{
		Type:          runtime.QuestionDialog,
		Title:         i18n.T("dlg.replaceTitle"),
		Message:       i18n.T("dlg.replace", filepath.Base(path)),
		DefaultButton: "No",
	})
	return err == nil && ans == "Yes", err
}

func (a *App) closeDatabase() {
	a.cancelReads()
	a.dbManager.Close()
	a.dbName, a.dbPath = "", ""
	a.updateTitle()
}

// titleFor: "{file} - mdb2sql 1.3.0 - Go" with a file open, "mdb2sql 1.3.0 - Go" without (as Python)
func titleFor(name string) string {
	if name == "" {
		return windowTitle()
	}
	return name + " - " + windowTitle()
}

// updateTitle puts the name of the open file in the window title
func (a *App) updateTitle() {
	if a.ctx != nil { // nil in tests: the Wails runtime only works inside the app
		runtime.WindowSetTitle(a.ctx, titleFor(a.dbName))
	}
}

// CloseDatabase fecha o arquivo aberto (Arquivo > Fechar); a UI resolve antes um SQLite convertido pendente
func (a *App) CloseDatabase() error {
	if a.converted != "" {
		return errors.New(i18n.T("err.pendingConversion"))
	}
	a.closeDatabase()
	return nil
}

// StartupPath: arquivo da linha de comando ou, sem ele, MDB2SQL_DB_PATH; "" = nada para abrir ao iniciar
func (a *App) StartupPath() string {
	for _, arg := range os.Args[1:] {
		if !strings.HasPrefix(arg, "-") {
			return arg
		}
	}
	return os.Getenv("MDB2SQL_DB_PATH")
}

// SelectDatabase abre o seletor de arquivo nativo; retorna "" se o usuario cancelar
// !T: Only returns a path; LoadDatabase still validates it
func (a *App) SelectDatabase() (string, error) {
	return runtime.OpenFileDialog(a.ctx, runtime.OpenDialogOptions{
		Title:            i18n.T("dlg.open"),
		DefaultDirectory: existingDir(a.settings.LastDir),
		Filters:          openFilters(),
	})
}

// openFilters: Access first, SQLite second, DuckDB last (owner's order); "All databases" is the default filter
func openFilters() []runtime.FileFilter {
	return []runtime.FileFilter{
		{DisplayName: i18n.T("filter.all") + " (*.accdb;*.mdb;*.sqlite;*.sqlite3;*.db;*.duckdb)", Pattern: "*.accdb;*.mdb;*.sqlite;*.sqlite3;*.db;*.duckdb"},
		{DisplayName: "Microsoft Access (*.accdb;*.mdb)", Pattern: "*.accdb;*.mdb"},
		{DisplayName: "SQLite (*.sqlite;*.sqlite3;*.db)", Pattern: "*.sqlite;*.sqlite3;*.db"},
		{DisplayName: "DuckDB (*.duckdb)", Pattern: "*.duckdb"},
	}
}

var allowedExts = map[string]struct{}{
	".accdb": {}, ".mdb": {}, ".sqlite": {}, ".sqlite3": {}, ".db": {}, ".duckdb": {},
}

// Valida caminho do banco de dados com protecao contra path traversal
// !T: Prevents path traversal via symlinks and validates file extension
func (a *App) validateDatabasePath(dbPath string) (string, error) {
	// Converte para caminho absoluto
	absPath, err := filepath.Abs(dbPath)
	if err != nil {
		return "", fmt.Errorf("%s: %w", i18n.T("err.badPath"), err)
	}

	// Resolve symlinks para prevenir path traversal
	// !T: EvalSymlinks prevents attacks via malicious.db -> /etc/passwd
	resolvedPath, err := filepath.EvalSymlinks(absPath)
	if err != nil {
		return "", fmt.Errorf("%s: %w", i18n.T("err.notFound"), err)
	}

	// Valida extensao do arquivo no caminho final
	ext := strings.ToLower(filepath.Ext(resolvedPath))
	if _, ok := allowedExts[ext]; !ok {
		return "", errors.New(i18n.T("err.unsupported", ext))
	}

	// Garante que o caminho e um arquivo, nao diretorio
	info, err := os.Stat(resolvedPath)
	if err != nil {
		return "", fmt.Errorf("%s: %w", i18n.T("err.notFound"), err)
	}
	if info.IsDir() {
		return "", errors.New(i18n.T("err.isDir", resolvedPath))
	}

	return resolvedPath, nil
}

// Progress is sent to the UI as the "progress" event during loads and exports
type Progress struct {
	Done  int    `json:"done"`
	Total int    `json:"total"` // 0 = unknown
	Label string `json:"label"`
}

func (a *App) progress(done, total int, label string) {
	if a.ctx != nil { // nil in tests: the Wails runtime only works inside the app
		runtime.EventsEmit(a.ctx, "progress", Progress{done, total, label})
	}
}

// startJob gives a load or export its own cancellable context; CancelJob stops it
func (a *App) startJob() (context.Context, func()) {
	ctx, cancel := context.WithCancel(context.Background())
	a.jobMu.Lock()
	a.cancel = cancel
	a.jobMu.Unlock()
	return ctx, func() {
		a.jobMu.Lock()
		a.cancel = nil
		a.jobMu.Unlock()
		cancel()
	}
}

// CancelJob cancela a carga, exportacao ou consulta SQL em andamento (botao Cancelar)
func (a *App) CancelJob() {
	a.jobMu.Lock()
	defer a.jobMu.Unlock()
	if a.cancel != nil {
		a.cancel()
	}
	if a.queryCancel != nil {
		a.queryCancel()
	}
}

// cancelReads stops the running SQL tab query, "All tables" search and table list count, if any: another file or
// Close replaces the connection they read, and Close waits for them
func (a *App) cancelReads() {
	a.jobMu.Lock()
	defer a.jobMu.Unlock()
	for _, cancel := range []context.CancelFunc{a.queryCancel, a.searchCancel, a.countCancel} {
		if cancel != nil {
			cancel()
		}
	}
}

// LoadDatabase abre o arquivo (Access e importado, com progresso) e retorna lista de tabelas
// !T: Wails automatically exposes this to frontend via IPC
func (a *App) LoadDatabase(dbPath string) ([]string, error) {
	// Se path vazio, tenta env var ou usa default
	if dbPath == "" {
		if envPath := os.Getenv("MDB2SQL_DB_PATH"); envPath != "" {
			dbPath = envPath
		} else {
			dbPath = filepath.Join("data", "sample.duckdb")
			// !T: the macOS .app bundle keeps data/ in Contents/Resources/
			if exePath, err := os.Executable(); err == nil {
				bundled := filepath.Join(filepath.Dir(filepath.Dir(exePath)), "Resources", "data", "sample.duckdb")
				if _, err := os.Stat(bundled); err == nil {
					dbPath = bundled
				}
			}
		}
	}

	// Valida caminho do banco
	// !T: Prevent path traversal and validate file extension
	validatedPath, err := a.validateDatabasePath(dbPath)
	if err != nil {
		// a wrong path typed in the path bar: the UI has already dropped the open file, so Go closes it too and the
		// window title loses its name (a converted SQLite still pending stays: it must be saved or deleted first)
		if a.converted == "" {
			a.closeDatabase()
		}
		return nil, err
	}

	// the converted SQLite of the previous Access file is saved or deleted first (the UI asks, ResolveConversion)
	if a.converted != "" {
		if a.convChoice == "" {
			return nil, errors.New(i18n.T("err.pendingConversion"))
		}
		if _, err := a.resolveConversion(a.convChoice); err != nil {
			return nil, err
		}
	}
	a.cancelReads() // a query or search on the previous file must not outlive it
	ctx, done := a.startJob()
	defer done()
	a.dbName, a.dbPath = "", "" // Open closes the previous database first
	defer a.updateTitle()       // the new file's name, or none if it failed
	start := time.Now()
	// the same Access file (path, size, date) saved as SQLite, in this run or an earlier one: open that file, no new
	// conversion
	openPath := validatedPath
	if saved := a.savedConversion(validatedPath); saved != "" {
		openPath = saved
		a.log("log.reused", filepath.Base(validatedPath), saved)
	}
	if err := a.dbManager.Open(ctx, openPath, a.progress); err != nil {
		if ctx.Err() != nil {
			return nil, errors.New(i18n.T("err.loadCancelled"))
		}
		return nil, fmt.Errorf("%s: %w", i18n.T("err.openFailed"), err)
	}
	a.dbName = filepath.Base(validatedPath)
	a.dbPath = validatedPath
	if conv := a.dbManager.Converted(); conv != "" {
		a.converted, a.convertedFrom, a.convertedFromKey = conv, validatedPath, fileKey(validatedPath)
		a.log("log.converted", a.dbName, a.dbManager.Source(), time.Since(start).Round(100*time.Millisecond), conv)
	}

	// Lista tabelas disponiveis
	tables, err := a.dbManager.ListTables()
	if err != nil {
		return nil, fmt.Errorf("failed to list tables: %w", err)
	}

	return tables, nil
}

// GetTableData retorna linhas de uma tabela com limite configuravel; filters = coluna = valor (clique direito) e
// search = pesquisa da aba Data, as duas no banco sobre a tabela inteira
// !T: Returns slice of maps with column names as keys, limit defaults to 100 rows
func (a *App) GetTableData(tableName string, limit int, filters []backend.Filter, search string) ([]map[string]interface{}, error) {
	if limit <= 0 {
		limit = 100
	}

	return a.dbManager.QueryTable(tableName, limit, search, filters...)
}

// GetRowCount retorna total de linhas em tabela (das que casam com os filtros e a pesquisa, se houver)
// !T: Executes COUNT(*) query and returns integer result
func (a *App) GetRowCount(tableName string, filters []backend.Filter, search string) (int, error) {
	return a.dbManager.GetRowCount(tableName, search, filters...)
}

// SearchAllTables: the tables with rows matching search (Data tab, "All tables") and how many, with a progress
// event per table; a new search stops the previous one
func (a *App) SearchAllTables(search string) ([]backend.TableHits, error) {
	ctx, cancel := context.WithCancel(context.Background())
	a.jobMu.Lock()
	if a.searchCancel != nil {
		a.searchCancel()
	}
	a.searchCancel = cancel
	a.jobMu.Unlock()
	defer cancel()
	return a.dbManager.SearchTables(ctx, search, a.progress)
}

// TableCounts: the row count of each table, in table list order, for the table list (asked after the file opens,
// so the list shows at once); another file or Close stops it
func (a *App) TableCounts() ([]int, error) {
	ctx, cancel := context.WithCancel(context.Background())
	a.jobMu.Lock()
	if a.countCancel != nil {
		a.countCancel()
	}
	a.countCancel = cancel
	a.jobMu.Unlock()
	defer cancel()
	return a.dbManager.TableCounts(ctx)
}

// GetTableSchema retorna schema da tabela com tipos de colunas
// !T: Returns slice of ColumnSchema with name and type for each column
func (a *App) GetTableSchema(tableName string) ([]backend.ColumnSchema, error) {
	return a.dbManager.GetTableSchema(tableName)
}

// RunQuery executa SQL livre (aba SQL) e devolve no maximo limit linhas; uma consulta por vez: a nova cancela a
// anterior, e CancelJob ou abrir outro arquivo tambem a cancelam
func (a *App) RunQuery(query string, limit int) (backend.QueryResult, error) {
	if limit <= 0 {
		limit = 100
	}
	ctx, cancel := context.WithCancel(context.Background())
	a.jobMu.Lock()
	if a.queryCancel != nil {
		a.queryCancel()
	}
	a.querySeq++
	seq := a.querySeq
	a.queryCancel = cancel
	a.jobMu.Unlock()
	defer func() {
		a.jobMu.Lock()
		if a.querySeq == seq {
			a.queryCancel = nil
		}
		a.jobMu.Unlock()
		cancel()
	}()
	res, err := a.dbManager.RunQuery(ctx, query, limit)
	if ctx.Err() != nil {
		return backend.QueryResult{}, errors.New(i18n.T("err.queryCancelled"))
	}
	return res, err
}

// file name the save dialog proposes for the SQL result: query.csv / query.xlsx (standard item 17)
const queryExportName = "query"

// export file types: catalog key of the name and the pattern
var exportFilters = map[string][2]string{
	"duckdb": {"filter.duckdbOut", "*.duckdb"},
	"sqlite": {"filter.sqliteOut", "*.sqlite"},
	"xlsx":   {"filter.xlsxOut", "*.xlsx"},
	"csv":    {"filter.csvOut", "*.csv"},
}

// defaultSaveDir: pasta do arquivo aberto; sem arquivo aberto, a ultima pasta usada (se ainda existir)
func defaultSaveDir(openFile, lastDir string) string {
	if openFile != "" {
		if dir := existingDir(filepath.Dir(openFile)); dir != "" {
			return dir
		}
	}
	return existingDir(lastDir)
}

func existingDir(dir string) string {
	if info, err := os.Stat(dir); dir != "" && err == nil && info.IsDir() {
		return dir
	}
	return ""
}

// saveDialog asks for the target file; "" = cancelled. The chosen folder becomes the last used folder.
func (a *App) saveDialog(name, format string) (string, error) {
	filter, ok := exportFilters[format]
	if !ok {
		return "", fmt.Errorf("unknown export format %q", format)
	}
	path, err := runtime.SaveFileDialog(a.ctx, runtime.SaveDialogOptions{
		Title:            i18n.T("dlg.export", strings.ToUpper(format)),
		DefaultDirectory: defaultSaveDir(a.dbPath, a.settings.LastDir),
		DefaultFilename:  name + "." + format,
		Filters:          []runtime.FileFilter{{DisplayName: i18n.T(filter[0]), Pattern: filter[1]}},
	})
	if err != nil || path == "" {
		return "", err
	}
	if !strings.EqualFold(filepath.Ext(path), "."+format) {
		path += "." + format
	}
	if ok, err := a.replaceOK(path); !ok {
		return "", err
	}
	a.settings.LastDir = filepath.Dir(path)
	a.saveSettings()
	return path, nil
}

func (a *App) runExport(name, format string, export func(ctx context.Context, out string) error) (string, error) {
	out, err := a.saveDialog(name, format)
	if err != nil || out == "" {
		return "", err
	}
	ctx, done := a.startJob()
	defer done()
	if err := export(ctx, out); err != nil {
		return "", err
	}
	return out, nil
}

// ExportDatabase exporta todas as tabelas (format duckdb, sqlite ou xlsx); devolve o arquivo salvo ("" = cancelado)
func (a *App) ExportDatabase(format string) (string, error) {
	name := strings.TrimSuffix(a.dbName, filepath.Ext(a.dbName))
	return a.runExport(name, format, func(ctx context.Context, out string) error {
		return a.dbManager.ExportDatabase(ctx, format, out, a.progress)
	})
}

// ExportTable exporta a tabela atual (format csv ou xlsx): inteira, ou com search/filters so as linhas encontradas
// (com a busca ativa a UI pergunta qual das duas)
func (a *App) ExportTable(table, format string, filters []backend.Filter, search string) (string, error) {
	return a.runExport(table, format, func(ctx context.Context, out string) error {
		return a.dbManager.ExportTable(ctx, table, format, out, a.progress, search, filters...)
	})
}

// ExportQuery exporta o resultado completo do SQL (format csv ou xlsx); nome proposto query.csv / query.xlsx
func (a *App) ExportQuery(query, format string) (string, error) {
	return a.runExport(queryExportName, format, func(ctx context.Context, out string) error {
		return a.dbManager.ExportQuery(ctx, query, format, out, a.progress)
	})
}
