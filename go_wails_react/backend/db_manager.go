// Gerenciador de conexoes DuckDB em Go - carrega bancos, lista tabelas, executa queries
// !T: Core database manager handling DuckDB connections, query execution and schema inspection

package backend

import (
	"database/sql"
	"fmt"

	_ "github.com/marcboeker/go-duckdb" // !T: Import for side effects (register DuckDB driver)
)

// Struct que gerencia acesso aos bancos DuckDB - conectar, listar tabelas, queries
// !T: Database manager with singleton pattern holding connection and current DB path
type DBManager struct {
	conn      *sql.DB // !T: Standard sql.DB interface from database/sql
	currentDB string
}

// Cria novo DBManager sem conectar - conexao sera feita com Connect()
// !T: Factory function returning unconnected DBManager, lazy initialization pattern
func NewDBManager() *DBManager {
	return &DBManager{}
}

// Conecta ao banco DuckDB especificado - fecha conexao anterior se existir
// !T: Opens read-only connection with DSN format: path?access_mode=read_only
func (m *DBManager) Connect(dbPath string) error {
	// Fecha conexao anterior se existir
	if m.conn != nil {
		m.conn.Close()
	}

	// Abre conexao DuckDB com modo read-only
	// !T: DSN format: path?access_mode=read_only prevents accidental writes
	dsn := fmt.Sprintf("%s?access_mode=read_only", dbPath)
	conn, err := sql.Open("duckdb", dsn)
	if err != nil {
		return fmt.Errorf("failed to open database: %w", err)
	}

	// Testa se conexao funciona
	if err := conn.Ping(); err != nil {
		conn.Close()
		return fmt.Errorf("failed to ping database: %w", err)
	}

	m.conn = conn
	m.currentDB = dbPath
	return nil
}

// Retorna lista de nomes de tabelas no banco atual
// !T: Executes DuckDB-specific SHOW TABLES query and returns string slice
func (m *DBManager) ListTables() ([]string, error) {
	if m.conn == nil {
		return nil, fmt.Errorf("no database connected")
	}

	// Query SHOW TABLES retorna lista de tabelas
	// !T: DuckDB-specific SHOW TABLES syntax
	rows, err := m.conn.Query("SHOW TABLES")
	if err != nil {
		return nil, fmt.Errorf("failed to list tables: %w", err)
	}
	defer rows.Close()

	// Le cada linha e adiciona nome da tabela na lista
	var tables []string
	for rows.Next() {
		var tableName string
		if err := rows.Scan(&tableName); err != nil {
			return nil, fmt.Errorf("failed to scan table name: %w", err)
		}
		tables = append(tables, tableName)
	}

	return tables, rows.Err()
}

// Struct que representa schema de uma coluna com nome, tipo e nullable
// !T: Column metadata struct exported to frontend via JSON tags
type ColumnSchema struct {
	Name string `json:"name"`
	Type string `json:"type"`
	Null string `json:"null"`
}

// Retorna schema de uma tabela (colunas, tipos, nullable)
// !T: Executes PRAGMA table_info() which is more efficient than DESCRIBE SELECT *
func (m *DBManager) GetTableSchema(tableName string) ([]ColumnSchema, error) {
	if m.conn == nil {
		return nil, fmt.Errorf("no database connected")
	}

	// Valida tableName contra lista de tabelas
	// !T: Prevent SQL injection by validating input
	validatedName, err := m.validateTableName(tableName)
	if err != nil {
		return nil, err
	}
	tableName = validatedName

	// PRAGMA table_info retorna metadata sem varrer dados
	// !T: More efficient than DESCRIBE SELECT *
	query := fmt.Sprintf(`PRAGMA table_info("%s")`, tableName)
	rows, err := m.conn.Query(query)
	if err != nil {
		return nil, fmt.Errorf("failed to get table info: %w", err)
	}
	defer rows.Close()

	// Le metadata de cada coluna
	// !T: PRAGMA returns: cid, name, type, notnull, dflt_value, pk
	var schema []ColumnSchema
	for rows.Next() {
		var cid int
		var name, colType string
		var notNull int
		var dfltValue interface{}
		var pk int

		if err := rows.Scan(&cid, &name, &colType, &notNull, &dfltValue, &pk); err != nil {
			return nil, fmt.Errorf("failed to scan column: %w", err)
		}

		nullStr := "YES"
		if notNull == 1 {
			nullStr = "NO"
		}

		schema = append(schema, ColumnSchema{
			Name: name,
			Type: colType,
			Null: nullStr,
		})
	}

	return schema, rows.Err()
}

// Valida se tableName existe no banco
// !T: Prevents SQL injection using parameterized query against information_schema
func (m *DBManager) validateTableName(tableName string) (string, error) {
	if m.conn == nil {
		return "", fmt.Errorf("no database connected")
	}

	// Query parametrizada contra information_schema
	// !T: Parameterized query is safer and more efficient than fetching all tables
	var validatedName string
	err := m.conn.QueryRow(`SELECT table_name FROM information_schema.tables WHERE table_name = ?`, tableName).Scan(&validatedName)

	if err != nil {
		if err == sql.ErrNoRows {
			return "", fmt.Errorf("table not found: %s", tableName)
		}
		return "", fmt.Errorf("failed to validate table name: %w", err)
	}

	return validatedName, nil
}

// Executa SELECT na tabela e retorna resultados como slice de maps
// !T: Returns []map[string]interface{} for dynamic column handling in frontend
func (m *DBManager) QueryTable(tableName string, limit int) ([]map[string]interface{}, error) {
	if m.conn == nil {
		return nil, fmt.Errorf("no database connected")
	}

	// Valida tableName contra lista de tabelas
	// !T: Prevent SQL injection by validating input
	validatedName, err := m.validateTableName(tableName)
	if err != nil {
		return nil, err
	}
	tableName = validatedName

	// SELECT com LIMIT parametrizado
	// !T: Only limit is parameterized, table name is validated
	query := fmt.Sprintf(`SELECT * FROM "%s" LIMIT ?`, tableName)
	rows, err := m.conn.Query(query, limit)
	if err != nil {
		return nil, fmt.Errorf("failed to query table: %w", err)
	}
	defer rows.Close()

	// Pega nomes das colunas
	columns, err := rows.Columns()
	if err != nil {
		return nil, fmt.Errorf("failed to get columns: %w", err)
	}

	// Le cada row e converte para map
	var results []map[string]interface{}
	for rows.Next() {
		// !T: Create slice of interface{} to scan into
		values := make([]interface{}, len(columns))
		valuePtrs := make([]interface{}, len(columns))
		for i := range values {
			valuePtrs[i] = &values[i]
		}

		if err := rows.Scan(valuePtrs...); err != nil {
			return nil, fmt.Errorf("failed to scan row: %w", err)
		}

		// Cria map com nome_coluna -> valor
		row := make(map[string]interface{})
		for i, col := range columns {
			row[col] = values[i]
		}
		results = append(results, row)
	}

	return results, rows.Err()
}

// Retorna numero total de linhas em uma tabela
// !T: Executes COUNT(*) query with validated table name
func (m *DBManager) GetRowCount(tableName string) (int, error) {
	if m.conn == nil {
		return 0, fmt.Errorf("no database connected")
	}

	// Valida tableName contra lista de tabelas
	// !T: Prevent SQL injection by validating input
	validatedName, err := m.validateTableName(tableName)
	if err != nil {
		return 0, err
	}
	tableName = validatedName

	// COUNT(*) retorna total de linhas
	// !T: Table name validated, safe to use in query
	query := fmt.Sprintf(`SELECT COUNT(*) FROM "%s"`, tableName)
	var count int
	if err = m.conn.QueryRow(query).Scan(&count); err != nil {
		return 0, fmt.Errorf("failed to count rows: %w", err)
	}

	return count, nil
}

// Fecha conexao com o banco - sempre chame ao finalizar uso
// !T: Closes sql.DB connection and resets manager state
func (m *DBManager) Close() error {
	if m.conn != nil {
		err := m.conn.Close()
		m.conn = nil
		m.currentDB = ""
		return err
	}
	return nil
}
