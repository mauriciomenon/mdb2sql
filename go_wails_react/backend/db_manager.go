// NIVEL BASICO: Gerenciador de conexoes DuckDB em Go
// Responsavel por carregar bancos, listar tabelas, executar queries

package backend

import (
	"database/sql"
	"fmt"

	_ "github.com/marcboeker/go-duckdb" // NIVEL TECNICO: Import for side effects (register driver)
)

// NIVEL BASICO: Struct que gerencia acesso aos bancos DuckDB
// Funcionalidades: conectar, listar tabelas, executar queries
type DBManager struct {
	conn      *sql.DB // NIVEL TECNICO: Standard sql.DB interface
	currentDB string
}

// NIVEL BASICO: Cria novo DBManager sem conectar
// Conexao sera feita com Connect()
func NewDBManager() *DBManager {
	return &DBManager{}
}

// NIVEL BASICO: Conecta ao banco DuckDB especificado
// Se ja existe conexao, fecha antes de abrir nova
//
// Args:
//   - dbPath: Caminho para arquivo .duckdb
//
// Returns:
//   - error: nil se sucesso, erro caso contrario
func (m *DBManager) Connect(dbPath string) error {
	// NIVEL BASICO: Fecha conexao anterior se existir
	if m.conn != nil {
		m.conn.Close()
	}

	// NIVEL BASICO: Abre conexao DuckDB com modo read-only
	// NIVEL TECNICO: DSN format: path?access_mode=read_only
	dsn := fmt.Sprintf("%s?access_mode=read_only", dbPath)
	conn, err := sql.Open("duckdb", dsn)
	if err != nil {
		return fmt.Errorf("failed to open database: %w", err)
	}

	// NIVEL BASICO: Testa se conexao funciona
	if err := conn.Ping(); err != nil {
		conn.Close()
		return fmt.Errorf("failed to ping database: %w", err)
	}

	m.conn = conn
	m.currentDB = dbPath
	return nil
}

// NIVEL BASICO: Retorna lista de nomes de tabelas no banco atual
//
// Returns:
//   - []string: Lista de nomes de tabelas
//   - error: nil se sucesso
func (m *DBManager) ListTables() ([]string, error) {
	if m.conn == nil {
		return nil, fmt.Errorf("no database connected")
	}

	// NIVEL BASICO: Query SHOW TABLES retorna lista de tabelas
	// NIVEL TECNICO: DuckDB-specific SHOW TABLES syntax
	rows, err := m.conn.Query("SHOW TABLES")
	if err != nil {
		return nil, fmt.Errorf("failed to list tables: %w", err)
	}
	defer rows.Close()

	// NIVEL BASICO: Le cada linha e adiciona nome da tabela na lista
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

// NIVEL BASICO: Struct que representa schema de uma coluna
type ColumnSchema struct {
	Name string `json:"name"`
	Type string `json:"type"`
	Null string `json:"null"`
}

// NIVEL BASICO: Retorna schema (colunas e tipos) de uma tabela
//
// Args:
//   - tableName: Nome da tabela
//
// Returns:
//   - []ColumnSchema: Lista de colunas com metadata
//   - error: nil se sucesso
func (m *DBManager) GetTableSchema(tableName string) ([]ColumnSchema, error) {
	if m.conn == nil {
		return nil, fmt.Errorf("no database connected")
	}

	// NIVEL BASICO: Valida tableName contra lista de tabelas
	// NIVEL TECNICO: Prevent SQL injection by validating input
	validatedName, err := m.validateTableName(tableName)
	if err != nil {
		return nil, err
	}
	tableName = validatedName

	// NIVEL BASICO: PRAGMA table_info retorna metadata sem varrer dados
	// NIVEL TECNICO: More efficient than DESCRIBE SELECT *
	query := fmt.Sprintf(`PRAGMA table_info("%s")`, tableName)
	rows, err := m.conn.Query(query)
	if err != nil {
		return nil, fmt.Errorf("failed to get table info: %w", err)
	}
	defer rows.Close()

	// NIVEL BASICO: Le metadata de cada coluna
	// NIVEL TECNICO: PRAGMA returns: cid, name, type, notnull, dflt_value, pk
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

// NIVEL BASICO: Valida se tableName existe no banco
// NIVEL TECNICO: Prevents SQL injection by checking against known tables
// Returns validated table name to mitigate TOCTOU race condition
func (m *DBManager) validateTableName(tableName string) (string, error) {
	if m.conn == nil {
		return "", fmt.Errorf("no database connected")
	}

	// NIVEL BASICO: Query inline para evitar race condition
	// NIVEL TECNICO: TOCTOU mitigation - validate and return in single operation
	rows, err := m.conn.Query("SHOW TABLES")
	if err != nil {
		return "", fmt.Errorf("failed to validate table: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			return "", fmt.Errorf("failed to scan table name: %w", err)
		}
		if t == tableName {
			return tableName, nil
		}
	}

	if err := rows.Err(); err != nil {
		return "", fmt.Errorf("failed to validate table: %w", err)
	}

	return "", fmt.Errorf("table not found: %s", tableName)
}

// NIVEL BASICO: Executa SELECT na tabela e retorna resultados
//
// Args:
//   - tableName: Nome da tabela
//   - limit: Numero maximo de linhas
//
// Returns:
//   - []map[string]interface{}: Lista de rows como maps
//   - error: nil se sucesso
func (m *DBManager) QueryTable(tableName string, limit int) ([]map[string]interface{}, error) {
	if m.conn == nil {
		return nil, fmt.Errorf("no database connected")
	}

	// NIVEL BASICO: Valida tableName contra lista de tabelas
	// NIVEL TECNICO: Prevent SQL injection by validating input
	validatedName, err := m.validateTableName(tableName)
	if err != nil {
		return nil, err
	}
	tableName = validatedName

	// NIVEL BASICO: SELECT com LIMIT parametrizado
	// NIVEL TECNICO: Only limit is parameterized, table name is validated
	query := fmt.Sprintf(`SELECT * FROM "%s" LIMIT ?`, tableName)
	rows, err := m.conn.Query(query, limit)
	if err != nil {
		return nil, fmt.Errorf("failed to query table: %w", err)
	}
	defer rows.Close()

	// NIVEL BASICO: Pega nomes das colunas
	columns, err := rows.Columns()
	if err != nil {
		return nil, fmt.Errorf("failed to get columns: %w", err)
	}

	// NIVEL BASICO: Le cada row e converte para map
	var results []map[string]interface{}
	for rows.Next() {
		// NIVEL TECNICO: Create slice of interface{} to scan into
		values := make([]interface{}, len(columns))
		valuePtrs := make([]interface{}, len(columns))
		for i := range values {
			valuePtrs[i] = &values[i]
		}

		if err := rows.Scan(valuePtrs...); err != nil {
			return nil, fmt.Errorf("failed to scan row: %w", err)
		}

		// NIVEL BASICO: Cria map com nome_coluna -> valor
		row := make(map[string]interface{})
		for i, col := range columns {
			row[col] = values[i]
		}
		results = append(results, row)
	}

	return results, rows.Err()
}

// NIVEL BASICO: Retorna numero total de linhas em uma tabela
//
// Args:
//   - tableName: Nome da tabela
//
// Returns:
//   - int: Numero de linhas
//   - error: nil se sucesso
func (m *DBManager) GetRowCount(tableName string) (int, error) {
	if m.conn == nil {
		return 0, fmt.Errorf("no database connected")
	}

	// NIVEL BASICO: Valida tableName contra lista de tabelas
	// NIVEL TECNICO: Prevent SQL injection by validating input
	validatedName, err := m.validateTableName(tableName)
	if err != nil {
		return 0, err
	}
	tableName = validatedName

	// NIVEL BASICO: COUNT(*) retorna total de linhas
	// NIVEL TECNICO: Table name validated, safe to use in query
	query := fmt.Sprintf(`SELECT COUNT(*) FROM "%s"`, tableName)
	var count int
	if err = m.conn.QueryRow(query).Scan(&count); err != nil {
		return 0, fmt.Errorf("failed to count rows: %w", err)
	}

	return count, nil
}

// NIVEL BASICO: Fecha conexao com o banco
// Sempre chame este metodo ao finalizar uso
func (m *DBManager) Close() error {
	if m.conn != nil {
		err := m.conn.Close()
		m.conn = nil
		m.currentDB = ""
		return err
	}
	return nil
}
