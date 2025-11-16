package main

import (
	"context"
	"fmt"
	"mdb2sql/backend"
	"os"
	"path/filepath"
)

// NIVEL BASICO: App struct principal do Wails
// Contem contexto e DB manager
type App struct {
	ctx       context.Context
	dbManager *backend.DBManager
}

// NIVEL BASICO: Cria nova instancia App
func NewApp() *App {
	return &App{
		dbManager: backend.NewDBManager(),
	}
}

// NIVEL BASICO: startup chamado quando app inicia
// Contexto salvo para usar runtime methods
func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
}

// NIVEL BASICO: LoadDatabase conecta ao banco DuckDB
// Retorna lista de tabelas ou erro
//
// NIVEL TECNICO: Wails automatically exposes this to frontend
func (a *App) LoadDatabase(dbPath string) ([]string, error) {
	// NIVEL BASICO: Se path vazio, tenta env var ou usa default
	if dbPath == "" {
		// NIVEL TECNICO: Check MDB2SQL_DB_PATH env var first
		if envPath := os.Getenv("MDB2SQL_DB_PATH"); envPath != "" {
			dbPath = envPath
		} else {
			// NIVEL TECNICO: Fallback to default relative path
			dbPath = filepath.Join("data", "sample.duckdb")
		}
	}

	// NIVEL BASICO: Conecta ao banco
	if err := a.dbManager.Connect(dbPath); err != nil {
		return nil, fmt.Errorf("failed to connect: %w", err)
	}

	// NIVEL BASICO: Lista tabelas disponiveis
	tables, err := a.dbManager.ListTables()
	if err != nil {
		return nil, fmt.Errorf("failed to list tables: %w", err)
	}

	return tables, nil
}

// NIVEL BASICO: GetTableData retorna linhas de uma tabela
//
// Args:
//   - tableName: Nome da tabela
//   - limit: Numero maximo de linhas (default 100)
//
// Returns:
//   - []map[string]interface{}: Dados da tabela
//   - error: nil se sucesso
func (a *App) GetTableData(tableName string, limit int) ([]map[string]interface{}, error) {
	if limit <= 0 {
		limit = 100
	}

	return a.dbManager.QueryTable(tableName, limit)
}

// NIVEL BASICO: GetRowCount retorna total de linhas em tabela
func (a *App) GetRowCount(tableName string) (int, error) {
	return a.dbManager.GetRowCount(tableName)
}

// NIVEL BASICO: GetTableSchema retorna schema da tabela
func (a *App) GetTableSchema(tableName string) ([]backend.ColumnSchema, error) {
	return a.dbManager.GetTableSchema(tableName)
}
