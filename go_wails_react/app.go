package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"mdb2sql/backend"
	"os"
	"path/filepath"
	goruntime "runtime"
	"runtime/debug"
	"strings"
	"sync"

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

	jobMu       sync.Mutex
	cancel      context.CancelFunc // of the running load or export
	queryCancel context.CancelFunc // of the running SQL tab query (one at a time)
	querySeq    int
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
	Access    string `json:"access"` // reader an Access file would use now: "Access ODBC", "mdbtools" or ""
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
	return AppInfo{
		Version:   productVersion(),
		Build:     buildNumber,
		BuildDate: buildDate,
		Go:        strings.TrimPrefix(goruntime.Version(), "go"),
		Wails:     wailsVersion(),
		DuckDB:    duck,
		Access:    backend.AccessReader(),
	}
}

// DatabaseName retorna o nome do arquivo aberto (sem pasta); "" se nenhum
// !T: The frontend cannot know which file an empty path resolved to (MDB2SQL_DB_PATH or sample)
func (a *App) DatabaseName() string {
	return a.dbName
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
		Title:            "Open database",
		DefaultDirectory: existingDir(a.settings.LastDir),
		Filters: []runtime.FileFilter{
			{DisplayName: "Databases (*.duckdb;*.db;*.sqlite;*.sqlite3;*.mdb;*.accdb)", Pattern: "*.duckdb;*.db;*.sqlite;*.sqlite3;*.mdb;*.accdb"},
			{DisplayName: "DuckDB (*.duckdb;*.db)", Pattern: "*.duckdb;*.db"},
			{DisplayName: "SQLite (*.sqlite;*.sqlite3;*.db)", Pattern: "*.sqlite;*.sqlite3;*.db"},
			{DisplayName: "Microsoft Access (*.mdb;*.accdb)", Pattern: "*.mdb;*.accdb"},
		},
	})
}

var allowedExts = map[string]struct{}{
	".duckdb": {}, ".db": {}, ".sqlite": {}, ".sqlite3": {}, ".mdb": {}, ".accdb": {},
}

// Valida caminho do banco de dados com protecao contra path traversal
// !T: Prevents path traversal via symlinks and validates file extension
func (a *App) validateDatabasePath(dbPath string) (string, error) {
	// Converte para caminho absoluto
	absPath, err := filepath.Abs(dbPath)
	if err != nil {
		return "", fmt.Errorf("invalid database path: %w", err)
	}

	// Resolve symlinks para prevenir path traversal
	// !T: EvalSymlinks prevents attacks via malicious.db -> /etc/passwd
	resolvedPath, err := filepath.EvalSymlinks(absPath)
	if err != nil {
		return "", fmt.Errorf("database file not found or path is invalid: %w", err)
	}

	// Valida extensao do arquivo no caminho final
	ext := strings.ToLower(filepath.Ext(resolvedPath))
	if _, ok := allowedExts[ext]; !ok {
		return "", fmt.Errorf("unsupported database format: %s", ext)
	}

	// Garante que o caminho e um arquivo, nao diretorio
	info, err := os.Stat(resolvedPath)
	if err != nil {
		return "", fmt.Errorf("could not access file info: %w", err)
	}
	if info.IsDir() {
		return "", fmt.Errorf("database path points to a directory, not a file: %s", resolvedPath)
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

// cancelQuery stops the running SQL tab query, if any (a new query or another file replaces it)
func (a *App) cancelQuery() {
	a.jobMu.Lock()
	defer a.jobMu.Unlock()
	if a.queryCancel != nil {
		a.queryCancel()
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
		return nil, err
	}

	a.cancelQuery() // a query on the previous file must not outlive it
	ctx, done := a.startJob()
	defer done()
	a.dbName, a.dbPath = "", "" // Open closes the previous database first
	if err := a.dbManager.Open(ctx, validatedPath, a.progress); err != nil {
		if ctx.Err() != nil {
			return nil, fmt.Errorf("loading cancelled")
		}
		return nil, fmt.Errorf("failed to connect: %w", err)
	}
	a.dbName = filepath.Base(validatedPath)
	a.dbPath = validatedPath

	// Lista tabelas disponiveis
	tables, err := a.dbManager.ListTables()
	if err != nil {
		return nil, fmt.Errorf("failed to list tables: %w", err)
	}

	return tables, nil
}

// GetTableData retorna linhas de uma tabela com limite configuravel; filters = coluna = valor (clique direito), no banco
// !T: Returns slice of maps with column names as keys, limit defaults to 100 rows
func (a *App) GetTableData(tableName string, limit int, filters []backend.Filter) ([]map[string]interface{}, error) {
	if limit <= 0 {
		limit = 100
	}

	return a.dbManager.QueryTable(tableName, limit, filters...)
}

// GetRowCount retorna total de linhas em tabela (das que casam com os filtros, se houver)
// !T: Executes COUNT(*) query and returns integer result
func (a *App) GetRowCount(tableName string, filters []backend.Filter) (int, error) {
	return a.dbManager.GetRowCount(tableName, filters...)
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
		return backend.QueryResult{}, fmt.Errorf("query cancelled")
	}
	return res, err
}

var exportFilters = map[string]runtime.FileFilter{
	"duckdb": {DisplayName: "DuckDB database (*.duckdb)", Pattern: "*.duckdb"},
	"sqlite": {DisplayName: "SQLite database (*.sqlite)", Pattern: "*.sqlite"},
	"xlsx":   {DisplayName: "Excel workbook (*.xlsx)", Pattern: "*.xlsx"},
	"csv":    {DisplayName: "CSV UTF-8 (*.csv)", Pattern: "*.csv"},
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
		Title:            "Export to " + strings.ToUpper(format),
		DefaultDirectory: defaultSaveDir(a.dbPath, a.settings.LastDir),
		DefaultFilename:  name + "." + format,
		Filters:          []runtime.FileFilter{filter},
	})
	if err != nil || path == "" {
		return "", err
	}
	if !strings.EqualFold(filepath.Ext(path), "."+format) {
		path += "." + format
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

// ExportTable exporta a tabela atual inteira (format csv ou xlsx)
func (a *App) ExportTable(table, format string) (string, error) {
	return a.runExport(table, format, func(ctx context.Context, out string) error {
		return a.dbManager.ExportTable(ctx, table, format, out, a.progress)
	})
}

// ExportQuery exporta o resultado completo do SQL (format csv ou xlsx)
func (a *App) ExportQuery(query, format string) (string, error) {
	return a.runExport("result", format, func(ctx context.Context, out string) error {
		return a.dbManager.ExportQuery(ctx, query, format, out, a.progress)
	})
}
