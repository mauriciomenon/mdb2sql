package main

import (
	"context"
	"fmt"
	"mdb2sql/backend"
	"os"
	"path/filepath"
)

// App struct principal do Wails - contem contexto e DB manager
// !T: Main Wails application struct holding context and database manager singleton
type App struct {
	ctx       context.Context
	dbManager *backend.DBManager
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
	ext := filepath.Ext(resolvedPath)
	if ext != ".duckdb" && ext != ".db" {
		return "", fmt.Errorf("only .duckdb and .db files are supported, got: %s", ext)
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
			// !T: Fallback to default relative path
			dbPath = filepath.Join("data", "sample.duckdb")
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
		return nil, fmt.Errorf("failed to connect: %w", err)
	}

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
