package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"mdb2sql/backend"
	"mdb2sql/i18n"
	"os"
	"path/filepath"
	goruntime "runtime"
	"runtime/debug"
	"slices"
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

	// Access file converted to SQLite: the temporary file it is read from and the Access file it came from
	converted, convertedFrom string
	convertedFromKey         string          // fileKey of the Access file converted now
	convSaved                bool            // File > Save already wrote it somewhere: leaving it asks nothing
	startLog                 []string        // Log lines of the startup, read by the UI once it listens (StartupLog)
	displayWarn              *DisplayWarning // Linux: X11 missing, running on Wayland (display.go)

	progressMu   sync.Mutex
	lastProgress time.Time // when the last "progress" event went to the UI (progressDue)

	jobMu        sync.Mutex
	cancel       context.CancelFunc // of the running load, export or term search
	exporting    bool               // the running job is an export or a save: leaving the app asks first
	exitOK       bool               // the UI asked what it had to (Exit): the window may close
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
	a := &App{
		dbManager: backend.NewDBManager(),
		settings:  loadSettings(),
	}
	backend.OnSourceFolderTemp = a.rememberTempDir
	return a
}

// Callback de startup chamado quando app inicia - salva contexto
// !T: Wails lifecycle hook called on app startup, stores context for runtime methods
func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	a.cleanStale()
}

// cleanStale removes the converted files a crash left behind: in the two temporary folders, in the folders beside
// Access files that had to hold one (kept in the settings) and where 1.3.0 kept them (%LOCALAPPDATA%)
func (a *App) cleanStale() {
	roots := append(backend.ConvertedRoots(""), a.settings.TempDirs...)
	if n := backend.CleanStaleConverted(append(roots, backend.LegacyConvertedRoot())...); n > 0 {
		a.startLog = append(a.startLog, i18n.N("log.staleRemoved", n, n))
	}
	// a folder that is gone needs no more looking
	kept := slices.DeleteFunc(slices.Clone(a.settings.TempDirs), func(d string) bool { return existingDir(d) == "" })
	if len(kept) != len(a.settings.TempDirs) {
		a.settings.TempDirs = kept
		_ = a.saveSettings()
	}
}

// rememberTempDir keeps in the settings the folder created beside an Access file to hold its converted SQLite (no
// temporary folder could): the next start also looks there for leftovers
func (a *App) rememberTempDir(root string) {
	if !slices.Contains(a.settings.TempDirs, root) {
		a.settings.TempDirs = append(a.settings.TempDirs, root)
		_ = a.saveSettings()
	}
}

// StartupLog returns, once, the Log lines of the startup: the events of Go sent before the UI listens would be lost
func (a *App) StartupLog() []string {
	lines := a.startLog
	a.startLog = nil
	return lines
}

// log sends one line to the Log panel (View > Log) in the current language
func (a *App) log(key string, args ...any) {
	a.logText(i18n.T(key, args...))
}

// logHook gets every Log line too (tests read them; the Wails runtime only works inside the app)
var logHook func(text string)

func (a *App) logText(text string) {
	if logHook != nil {
		logHook(text)
	}
	if a.ctx != nil { // nil in tests: the Wails runtime only works inside the app
		runtime.EventsEmit(a.ctx, "log", text)
	}
}

// beforeClose (window close button, Alt+F4): with an export running, or the SQLite converted from an Access file not
// saved, the UI asks first and then calls Exit (standard item 27)
func (a *App) beforeClose(ctx context.Context) bool {
	ask := a.asksOnExit()
	if ask {
		runtime.EventsEmit(ctx, "exit-asked")
	}
	return ask
}

func (a *App) asksOnExit() bool {
	a.jobMu.Lock()
	defer a.jobMu.Unlock()
	return !a.exitOK && (a.exporting || a.PendingConversion() != "")
}

// Exit closes the app with no more questions: the UI calls it after asking what it had to (File > Exit, Ctrl+Q and
// the window close button). shutdown cancels a running export and deletes the converted file.
func (a *App) Exit() {
	a.jobMu.Lock()
	a.exitOK = true
	a.jobMu.Unlock()
	if a.ctx != nil { // nil in tests: the Wails runtime only works inside the app
		runtime.Quit(a.ctx)
	}
}

// shutdown: never leave the temporary SQLite behind; Close waits for the work in progress, so a running load, export,
// query or search is stopped first and an export has already removed its half-written file
func (a *App) shutdown(context.Context) {
	a.CancelJob()
	a.cancelReads()
	a.dbManager.Close()
	backend.RemoveConverted(a.converted)
}

// PendingConversion is the name of the Access file whose converted SQLite was not saved yet: leaving the app asks about
// it ("" = nothing to ask)
func (a *App) PendingConversion() string {
	if a.converted == "" || a.convSaved {
		return ""
	}
	return filepath.Base(a.convertedFrom)
}

// fileKey identifies a file version: path, size and modification time ("" if it cannot be read)
func fileKey(path string) string {
	st, err := os.Stat(path)
	if err != nil {
		return ""
	}
	return fmt.Sprintf("%s|%d|%d", strings.ToLower(path), st.Size(), st.ModTime().UnixNano())
}

// rememberConversion keeps in the settings, between runs, the SQLite or DuckDB file saved from an Access file: the
// Access file's fileKey (path, size, date), the saved file and its own fileKey (standard item 22). One entry per
// Access file.
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

// savedConversion returns the file saved from this same Access file (SQLite or DuckDB), in this run or an earlier one,
// if neither file changed since; a changed one is forgotten, so the file is converted again
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

// closeDatabase leaves the open file (Close, another file, Reopen): nobody is asked; the temporary SQLite of an Access
// file is deleted and, when it was never saved, the Log says so (standard item 27)
func (a *App) closeDatabase() {
	a.cancelReads()
	a.dbManager.Close()
	a.dbName, a.dbPath = "", ""
	a.updateTitle()
	if a.converted != "" {
		backend.RemoveConverted(a.converted)
		if !a.convSaved {
			a.log("log.discarded", filepath.Base(a.convertedFrom))
		}
		a.converted, a.convertedFrom, a.convertedFromKey, a.convSaved = "", "", "", false
	}
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

// CloseDatabase fecha o arquivo aberto (Arquivo > Fechar), sem perguntar nada
func (a *App) CloseDatabase() error {
	a.closeDatabase()
	return nil
}

// StartupPath: arquivo da linha de comando ou, sem ele, MDB2SQL_DB_PATH; "" = nada para abrir ao iniciar. Relativo:
// contra a pasta de onde o programa foi chamado, aqui (LoadDatabase nao resolve caminho relativo, padrao 14)
func (a *App) StartupPath() string {
	path := os.Getenv("MDB2SQL_DB_PATH")
	for _, arg := range os.Args[1:] {
		if !strings.HasPrefix(arg, "-") {
			path = arg
			break
		}
	}
	if abs, err := filepath.Abs(path); path != "" && err == nil {
		return abs
	}
	return path
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
	if errors.Is(err, fs.ErrNotExist) {
		return "", errors.New(i18n.T("err.notFound", dbPath)) // only the path, never the system text (standard 14)
	}
	if err != nil {
		return "", fmt.Errorf("%s: %w", i18n.T("err.badPath"), err)
	}

	// Valida extensao do arquivo no caminho final
	ext := strings.ToLower(filepath.Ext(resolvedPath))
	if _, ok := allowedExts[ext]; !ok {
		return "", errors.New(i18n.T("err.unsupported", ext))
	}

	// Garante que o caminho e um arquivo, nao diretorio
	info, err := os.Stat(resolvedPath)
	if errors.Is(err, fs.ErrNotExist) {
		return "", errors.New(i18n.T("err.notFound", dbPath))
	}
	if err != nil {
		return "", fmt.Errorf("%s: %w", i18n.T("err.badPath"), err)
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
	if a.ctx != nil && a.progressDue(done, total, time.Now()) { // ctx nil in tests: the Wails runtime only works inside the app
		runtime.EventsEmit(a.ctx, "progress", Progress{done, total, label})
	}
}

// progressDue: at most one progress event per 200 ms (5 a second, owner 26/11), always the first and the last; each
// event goes through the window's thread, and with that thread busy (an accessibility client) one event per table made
// the 287-table term search of DB3 take 472 s instead of 22 s
func (a *App) progressDue(done, total int, now time.Time) bool {
	a.progressMu.Lock()
	defer a.progressMu.Unlock()
	if done > 1 && (total == 0 || done < total) && now.Sub(a.lastProgress) < 200*time.Millisecond {
		return false
	}
	a.lastProgress = now
	return true
}

// startJob gives a load, an export (export true: leaving the app asks first) or a term search its own cancellable
// context; CancelJob stops it
func (a *App) startJob(export bool) (context.Context, func()) {
	ctx, cancel := context.WithCancel(context.Background())
	a.jobMu.Lock()
	a.cancel, a.exporting = cancel, export
	a.jobMu.Unlock()
	return ctx, func() {
		a.jobMu.Lock()
		a.cancel, a.exporting = nil, false
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
	typed := dbPath // what the UI sent (path bar, file dialog, dropped file, StartupPath: absolute but the bar)
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
	if typed != "" && !filepath.IsAbs(typed) {
		// a relative path typed in the path bar would resolve against the folder of the exe (standard 14)
		validatedPath, err = "", errors.New(i18n.T("err.notFound", typed))
	}
	// the file open until now is left either way (the UI has already dropped it, also for a wrong path typed in the
	// path bar): its queries and searches stop, and the unsaved SQLite of an Access file is deleted, nobody asked
	a.closeDatabase()
	if err != nil {
		return nil, err
	}
	ctx, done := a.startJob(false)
	defer done()
	defer a.updateTitle() // the new file's name, or none if it failed
	start := time.Now()
	// the same Access file (path, size, date) saved as SQLite, in this run or an earlier one: open that file, no new
	// conversion
	openPath := validatedPath
	saved := a.savedConversion(validatedPath)
	if saved != "" {
		openPath = saved
	}
	if err := a.dbManager.Open(ctx, openPath, a.progress); err != nil {
		if ctx.Err() != nil {
			return nil, errors.New(i18n.T("err.loadCancelled"))
		}
		return nil, fmt.Errorf("%s: %w", i18n.T("err.openFailed"), err)
	}
	if saved != "" { // the format the saved file was read as: SQLite or DuckDB (standard 13)
		a.log("log.reused", filepath.Base(validatedPath), a.dbManager.Source(), saved)
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
func (a *App) GetTableData(tableName string, limit int, filters []backend.Filter, search string, offset int) ([]map[string]interface{}, error) {
	if limit <= 0 {
		limit = 100
	}

	return a.dbManager.QueryTablePage(tableName, limit, offset, search, filters...)
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
	ctx, done := a.startJob(true)
	defer done()
	if err := export(ctx, out); err != nil {
		return "", err
	}
	return out, nil
}

// csvFolder asks for the folder of an export that writes one CSV per table or sheet ("" = cancelled); names = the
// files it will write there. Files already there are replaced only after ONE question for all of them.
func (a *App) csvFolder(names []string) (string, error) {
	dir, err := runtime.OpenDirectoryDialog(a.ctx, runtime.OpenDialogOptions{
		Title:            i18n.T("dlg.export", "CSV"),
		DefaultDirectory: defaultSaveDir(a.dbPath, a.settings.LastDir),
	})
	if err != nil || dir == "" {
		return "", err
	}
	n := 0
	for _, name := range names {
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			n++
		}
	}
	if n > 0 {
		ans, err := runtime.MessageDialog(a.ctx, runtime.MessageDialogOptions{
			Type:          runtime.QuestionDialog,
			Title:         i18n.T("dlg.replaceTitle"),
			Message:       i18n.N("dlg.overwriteMany", n, n),
			DefaultButton: "No",
		})
		if err != nil || ans != "Yes" {
			return "", err
		}
	}
	a.settings.LastDir = dir
	a.saveSettings()
	return dir, nil
}

// runFolderExport: an export of one CSV per item into a folder the user picks; returns the folder ("" = cancelled)
func (a *App) runFolderExport(names []string, export func(ctx context.Context, dir string) error) (string, error) {
	dir, err := a.csvFolder(backend.CSVNames(names))
	if err != nil || dir == "" {
		return "", err
	}
	ctx, done := a.startJob(true)
	defer done()
	if err := export(ctx, dir); err != nil {
		return "", err
	}
	return dir, nil
}

// dbStem is the name of the open file without its extension: the start of the names the exports propose
func (a *App) dbStem() string {
	return strings.TrimSuffix(a.dbName, filepath.Ext(a.dbName))
}

// types of File > Save, in the order of the dialog: catalog key of the name and the pattern
var saveFormats = []string{"sqlite", "duckdb", "xlsx"}

var saveFilters = map[string][2]string{
	"sqlite": {"filter.sqliteOut", "*.sqlite"},
	"duckdb": {"filter.duckdbOut", "*.duckdb"},
	"xlsx":   {"filter.xlsxDb", "*.xlsx"},
}

// saveName is the name File > Save proposes in dir: the open file's own name with the extension of format; when that
// is the open file itself, "<name> (copy)"
func saveName(dir, stem, format string, open ...string) string {
	name := stem + "." + format
	for _, o := range open {
		if strings.EqualFold(filepath.Join(dir, name), o) {
			return i18n.T("dlg.copyName", stem) + "." + format
		}
	}
	return name
}

// SaveDatabase is File > Save (saveAs false: the dialog starts in the folder of the open file) and File > Save as...
// (in the last folder saved or exported to). The native dialog offers SQLite, DuckDB and Excel, starting on the type of
// the open file (Access: SQLite). Returns the file written ("" = cancelled). An Access file saved as SQLite or DuckDB
// is remembered (standard item 22), and once saved in any type, leaving it asks nothing (standard item 28).
func (a *App) SaveDatabase(saveAs bool) (string, error) {
	if a.dbPath == "" {
		return "", nil
	}
	format := "sqlite"
	if a.dbManager.Source() == backend.SourceDuckDB {
		format = "duckdb"
	}
	dir := existingDir(filepath.Dir(a.dbPath))
	if last := existingDir(a.settings.LastDir); saveAs && last != "" {
		dir = last
	}
	// the dialog starts on its first type (Wails cannot choose another), so the type of the open file goes first
	var filters []runtime.FileFilter
	for _, f := range append([]string{format}, saveFormats...) {
		if f != format || len(filters) == 0 {
			filters = append(filters, runtime.FileFilter{DisplayName: i18n.T(saveFilters[f][0]), Pattern: saveFilters[f][1]})
		}
	}
	path, err := runtime.SaveFileDialog(a.ctx, runtime.SaveDialogOptions{
		Title:            i18n.T("dlg.save"),
		DefaultDirectory: dir,
		DefaultFilename:  saveName(dir, a.dbStem(), format, a.dbPath, a.dbManager.Path()),
		Filters:          filters,
	})
	if err != nil || path == "" {
		return "", err
	}
	// the dialog puts the extension of the type chosen in it; a name with any other extension gets the starting type
	if ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(path), ".")); saveFilters[ext][0] != "" {
		format = ext
	} else {
		path += "." + format
	}
	for _, open := range []string{a.dbManager.Path(), a.converted} {
		if open != "" && strings.EqualFold(path, open) {
			return "", errors.New(i18n.T("err.exportOverOpen")) // refused before "replace it?" is asked
		}
	}
	if ok, err := a.replaceOK(path); !ok {
		return "", err
	}
	a.settings.LastDir = filepath.Dir(path)
	a.saveSettings()
	if err := a.saveTo(path, format); err != nil {
		return "", err
	}
	return path, nil
}

// saveTo writes the open database to path (format sqlite, duckdb or xlsx) as a job with progress and Cancel. The
// SQLite an Access file was converted to is already that file: it is copied; the other cases write table by table.
func (a *App) saveTo(path, format string) error {
	ctx, done := a.startJob(true)
	defer done()
	var err error
	if a.converted != "" && format == "sqlite" {
		err = a.dbManager.SaveConverted(path)
	} else {
		err = a.dbManager.ExportDatabase(ctx, format, path, a.progress)
	}
	if err == nil && a.converted != "" {
		a.convSaved = true
		if format != "xlsx" { // the same unchanged Access file now opens the saved database
			a.rememberConversion(a.convertedFrom, a.convertedFromKey, path)
		}
	}
	return err
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

// MarkedRows: the marked rows of a table (Data tab), in table order; marks = what the UI keeps of each marked row
func (a *App) MarkedRows(table string, marks []map[string]any) ([]map[string]any, error) {
	return a.dbManager.MarkedRows(table, marks)
}

// ExportMarked exporta as linhas marcadas da tabela (format csv ou xlsx), todas as colunas, na ordem da tabela; nome
// proposto <tabela>_marcadas
func (a *App) ExportMarked(table, format string, marks []map[string]any) (string, error) {
	return a.runExport(table+"_marcadas", format, func(ctx context.Context, out string) error {
		return a.dbManager.ExportMarked(ctx, table, marks, format, out, a.progress)
	})
}

// ExportSchema exporta o esquema da tabela (nome <tabela>_schema) ou, com table "", do banco inteiro (<banco>_schema);
// format csv ou xlsx
func (a *App) ExportSchema(table, format string) (string, error) {
	name := table
	if table == "" {
		name = a.dbStem()
	}
	return a.runExport(name+"_schema", format, func(ctx context.Context, out string) error {
		return a.dbManager.ExportSchema(ctx, table, format, out, a.progress)
	})
}

// ExportAllCSV exporta todas as tabelas, <tabela>.csv cada uma, na pasta escolhida; devolve a pasta ("" = cancelado)
func (a *App) ExportAllCSV() (string, error) {
	tables, err := a.dbManager.ListTables()
	if err != nil {
		return "", err
	}
	return a.runFolderExport(tables, func(ctx context.Context, dir string) error {
		return a.dbManager.ExportTablesCSV(ctx, dir, a.progress)
	})
}

// ExportSearch exporta para Excel o resultado da busca em todas as tabelas: uma aba por tabela da lista, com as linhas
// que a busca acha nela (todas as colunas); nome proposto <banco>_busca
func (a *App) ExportSearch(search string, tables []string) (string, error) {
	return a.runExport(a.dbStem()+"_busca", "xlsx", func(ctx context.Context, out string) error {
		return a.dbManager.ExportSearch(ctx, search, tables, out, a.progress)
	})
}

// SearchTerms is the search of the Terms tab: lines = the pasted text, one term per line; table "" = all tables. A job
// with progress events and Cancel.
func (a *App) SearchTerms(lines []string, contains bool, table string) (backend.TermsResult, error) {
	ctx, done := a.startJob(false)
	defer done()
	res, err := a.dbManager.SearchTerms(ctx, lines, contains, table, a.progress)
	if ctx.Err() != nil {
		return backend.TermsResult{}, errors.New(i18n.T("err.queryCancelled"))
	}
	return res, err
}

// TermRows: the rows of table the terms found, the term first and then every column, in term order; at most limit
// (0 = all of them, for "Copy the rows found")
func (a *App) TermRows(table string, terms []string, contains bool, limit int) (backend.QueryResult, error) {
	return a.dbManager.TermRows(context.Background(), table, terms, contains, limit)
}

// ExportTerms exporta o relatorio da pesquisa de termos: xlsx, sqlite ou duckdb num arquivo <banco>_termos; csv numa
// pasta, um arquivo por aba
func (a *App) ExportTerms(res backend.TermsResult, contains bool, format string) (string, error) {
	if format == "csv" {
		return a.runFolderExport(backend.TermsSheets(res), func(ctx context.Context, dir string) error {
			return a.dbManager.ExportTerms(ctx, res, contains, format, dir, a.progress)
		})
	}
	return a.runExport(a.dbStem()+"_termos", format, func(ctx context.Context, out string) error {
		return a.dbManager.ExportTerms(ctx, res, contains, format, out, a.progress)
	})
}
