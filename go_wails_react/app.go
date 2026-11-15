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

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// wails.json e a fonte unica da versao (info.productVersion); o Wails CLI usa o mesmo campo no recurso do exe
// !T: Single source of the app version, embedded so the About dialog and the exe resource always agree
//
//go:embed wails.json
var wailsJSON []byte

// App struct principal do Wails - contem contexto e DB manager
// !T: Main Wails application struct holding context and database manager singleton
type App struct {
	ctx       context.Context
	dbManager *backend.DBManager
	dbName    string
}

// AppInfo alimenta o dialogo Sobre: versao do app e versoes de runtime lidas em execucao
// !T: Data for the About dialog; React adds its own version on the frontend side
type AppInfo struct {
	Version string `json:"version"`
	Go      string `json:"go"`
	Wails   string `json:"wails"`
	DuckDB  string `json:"duckdb"`
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
		Version: productVersion(),
		Go:      strings.TrimPrefix(goruntime.Version(), "go"),
		Wails:   wailsVersion(),
		DuckDB:  duck,
	}
}

// DatabaseName retorna o nome do arquivo aberto (sem pasta); "" se nenhum
// !T: The frontend cannot know which file an empty path resolved to (MDB2SQL_DB_PATH or sample)
func (a *App) DatabaseName() string {
	return a.dbName
}

// Cria nova instancia App com DB manager inicializado
// !T: Factory function returning App with initialized database manager singleton
func NewApp() *App {
	return &App{
		dbManager: backend.NewDBManager(),
	}
}

// Callback de startup chamado quando app inicia - salva contexto
// !T: Wails lifecycle hook called on app startup, stores context for runtime methods
func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
}

// SelectDatabase abre o seletor de arquivo nativo; retorna "" se o usuario cancelar
// !T: Only returns a path; LoadDatabase still validates it
func (a *App) SelectDatabase() (string, error) {
	return runtime.OpenFileDialog(a.ctx, runtime.OpenDialogOptions{
		Title: "Open database",
		Filters: []runtime.FileFilter{
			{DisplayName: "DuckDB / SQLite (*.duckdb;*.db;*.sqlite;*.sqlite3)", Pattern: "*.duckdb;*.db;*.sqlite;*.sqlite3"},
		},
	})
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
	allowedExts := map[string]struct{}{
		".duckdb":  {},
		".db":      {},
		".sqlite":  {},
		".sqlite3": {},
	}
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

// LoadDatabase conecta ao banco DuckDB e retorna lista de tabelas
// !T: Wails automatically exposes this to frontend via IPC
func (a *App) LoadDatabase(dbPath string) ([]string, error) {
	// Se path vazio, tenta env var ou usa default
	if dbPath == "" {
		// !T: Check MDB2SQL_DB_PATH env var first
		if envPath := os.Getenv("MDB2SQL_DB_PATH"); envPath != "" {
			dbPath = envPath
		} else {
			// !T: Get executable directory for bundled app
			exePath, err := os.Executable()
			if err == nil {
				// !T: In .app bundle, executable is in Contents/MacOS/
				// data/ should be in Contents/Resources/data/
				exeDir := filepath.Dir(exePath)
				parentDir := filepath.Dir(exeDir) // Contents/
				dbPath = filepath.Join(parentDir, "Resources", "data", "sample.duckdb")

				// !T: Fallback to project root if Resources path doesn't exist
				if _, err := os.Stat(dbPath); err != nil {
					// Development mode - use project root
					dbPath = filepath.Join("data", "sample.duckdb")
				}
			} else {
				// !T: Fallback to default relative path
				dbPath = filepath.Join("data", "sample.duckdb")
			}
		}
	}

	// Valida caminho do banco
	// !T: Prevent path traversal and validate file extension
	validatedPath, err := a.validateDatabasePath(dbPath)
	if err != nil {
		return nil, err
	}

	// Conecta ao banco
	if err := a.dbManager.Connect(validatedPath); err != nil {
		a.dbName = "" // Connect ja fechou o banco anterior
		return nil, fmt.Errorf("failed to connect: %w", err)
	}
	a.dbName = filepath.Base(validatedPath)

	// Lista tabelas disponiveis
	tables, err := a.dbManager.ListTables()
	if err != nil {
		return nil, fmt.Errorf("failed to list tables: %w", err)
	}

	return tables, nil
}

// GetTableData retorna linhas de uma tabela com limite configuravel
// !T: Returns slice of maps with column names as keys, limit defaults to 100 rows
func (a *App) GetTableData(tableName string, limit int) ([]map[string]interface{}, error) {
	if limit <= 0 {
		limit = 100
	}

	return a.dbManager.QueryTable(tableName, limit)
}

// GetRowCount retorna total de linhas em tabela
// !T: Executes COUNT(*) query and returns integer result
func (a *App) GetRowCount(tableName string) (int, error) {
	return a.dbManager.GetRowCount(tableName)
}

// GetTableSchema retorna schema da tabela com tipos de colunas
// !T: Returns slice of ColumnSchema with name and type for each column
func (a *App) GetTableSchema(tableName string) ([]backend.ColumnSchema, error) {
	return a.dbManager.GetTableSchema(tableName)
}
