// Gerenciador de conexoes DuckDB em Go - carrega bancos, lista tabelas, executa queries
// !T: Core database manager handling DuckDB connections, query execution and schema inspection

package backend

import (
	"bytes"
	"context"
	"database/sql"
	"database/sql/driver"
	"fmt"
	"math"
	"math/big"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/duckdb/duckdb-go/v2"
)

// Struct que gerencia acesso aos bancos DuckDB - conectar, listar tabelas, queries
// !T: Every format ends up in one in-memory DuckDB: DuckDB/SQLite files attached read-only as "src", Access imported
type DBManager struct {
	conn      *sql.DB // !T: Standard sql.DB interface from database/sql
	currentDB string
	source    string // reader used: DuckDB, SQLite, Access ODBC or mdbtools
	tableSet  map[string]struct{}
	tableList []string
}

// Progress reports long work (Access import, export): done of total steps; label = current table
type Progress func(done, total int, label string)

// Readers shown in the status bar
const (
	SourceDuckDB   = "DuckDB"
	SourceSQLite   = "SQLite"
	SourceODBC     = "Access ODBC"
	SourceMdbtools = "mdbtools"
)

// Cria novo DBManager sem conectar - conexao sera feita com Connect()
// !T: Factory function returning unconnected DBManager, lazy initialization pattern
func NewDBManager() *DBManager {
	return &DBManager{}
}

// Connect abre o arquivo sem progresso nem cancelamento (testes e chamadas simples)
func (m *DBManager) Connect(dbPath string) error {
	return m.Open(context.Background(), dbPath, nil)
}

// Open fecha o banco anterior e abre dbPath pelo leitor do formato; Access e importado para a memoria
func (m *DBManager) Open(ctx context.Context, dbPath string, progress Progress) error {
	m.Close()
	if progress == nil {
		progress = func(int, int, string) {}
	}
	var conn *sql.DB
	var source string
	var err error
	switch fileKind(dbPath) {
	case "access":
		conn, source, err = openAccess(ctx, dbPath, progress)
	case "sqlite":
		conn, err = openAttached(dbPath, true)
		source = SourceSQLite
	default:
		conn, err = openAttached(dbPath, false)
		source = SourceDuckDB
	}
	if err != nil {
		return err
	}
	// attached files are only opened here, by the connection setup
	if err := conn.PingContext(ctx); err != nil {
		conn.Close()
		return fmt.Errorf("failed to open database: %w", err)
	}
	m.conn, m.currentDB, m.source = conn, dbPath, source

	// Pre-carrega cache de tabelas para validar nomes sem overhead por chamada
	if err := m.refreshTableCache(); err != nil {
		m.Close()
		return fmt.Errorf("failed to load table cache: %w", err)
	}
	return nil
}

// Source returns the reader used for the open file ("" when nothing is open)
func (m *DBManager) Source() string { return m.source }

// fileKind: Access by extension; SQLite by its file header (a .db may be either); otherwise DuckDB
func fileKind(path string) string {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".mdb", ".accdb":
		return "access"
	}
	f, err := os.Open(path)
	if err != nil {
		return "duckdb" // the open error is reported by DuckDB
	}
	defer f.Close()
	head := make([]byte, 16)
	if n, _ := f.Read(head); n == 16 && bytes.Equal(head, []byte("SQLite format 3\x00")) {
		return "sqlite"
	}
	return "duckdb"
}

// openAttached attaches the file read-only as "src" in an in-memory DuckDB, so exports can ATTACH writable files
func openAttached(path string, sqlite bool) (*sql.DB, error) {
	var setup []string
	attach := "ATTACH IF NOT EXISTS " + quoteLiteral(path) + " AS src (READ_ONLY)"
	if sqlite {
		ext, err := sqliteExtension()
		if err != nil {
			return nil, err
		}
		setup = append(setup, "LOAD "+quoteLiteral(ext))
		attach = "ATTACH IF NOT EXISTS " + quoteLiteral(path) + " AS src (TYPE sqlite, READ_ONLY)"
	}
	return openMemory(append(setup, attach, "USE src")...)
}

// openMemory opens an in-memory DuckDB; setup runs on every pooled connection because USE is per connection
func openMemory(setup ...string) (*sql.DB, error) {
	connector, err := duckdb.NewConnector("", func(execer driver.ExecerContext) error {
		for _, q := range setup {
			if _, err := execer.ExecContext(context.Background(), q, nil); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}
	return sql.OpenDB(connector), nil
}

func quoteIdent(name string) string { return `"` + strings.ReplaceAll(name, `"`, `""`) + `"` }

func quoteLiteral(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

// jsonValue makes a scanned DuckDB value safe for the UI: JSON has no NaN, DECIMAL and BLOB need plain forms
// Integers beyond 2^53 and decimals a float64 cannot hold go as text: a JS Number would change their digits.
func jsonValue(v any) any {
	const maxSafe = 1<<53 - 1 // Number.MAX_SAFE_INTEGER
	switch x := v.(type) {
	case int64:
		if x > maxSafe || x < -maxSafe {
			return strconv.FormatInt(x, 10)
		}
	case uint64:
		if x > maxSafe {
			return strconv.FormatUint(x, 10)
		}
	case duckdb.Decimal:
		f := x.Float64()
		exact, ok1 := new(big.Rat).SetString(x.String())
		shown, ok2 := new(big.Rat).SetString(strconv.FormatFloat(f, 'g', -1, 64))
		if ok1 && ok2 && exact.Cmp(shown) != 0 {
			return x.String()
		}
		return f
	case *big.Int:
		return x.String()
	case float64:
		if math.IsNaN(x) || math.IsInf(x, 0) {
			return fmt.Sprint(x)
		}
	case float32:
		if math.IsNaN(float64(x)) || math.IsInf(float64(x), 0) {
			return fmt.Sprint(x)
		}
	case []byte, time.Time, duckdb.UUID, duckdb.Map: // Map has non-string keys, which JSON cannot encode
		return cellString(v)
	}
	return v
}

// cellString is the text form of a value for CSV, the UI and copy (dates without a zero time part)
func cellString(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case duckdb.UUID:
		return x.String() // String has a pointer receiver, so fmt alone would print the 16 bytes
	case time.Time:
		if x.Hour() == 0 && x.Minute() == 0 && x.Second() == 0 && x.Nanosecond() == 0 {
			return x.Format("2006-01-02")
		}
		return x.Format("2006-01-02 15:04:05.999999")
	case []byte:
		if utf8.Valid(x) {
			return string(x)
		}
		return fmt.Sprintf("%X", x)
	case float64:
		return formatFloat(x)
	case float32:
		return formatFloat(float64(x))
	}
	return fmt.Sprint(v)
}

// formatFloat avoids "1e+06" for ordinary numbers; keeps the exponent for very large or small ones
func formatFloat(f float64) string {
	if a := math.Abs(f); a == 0 || (a >= 1e-6 && a < 1e15) {
		return strconv.FormatFloat(f, 'f', -1, 64)
	}
	return fmt.Sprint(f)
}

// QueryResult is a free SQL result; Columns keeps the order (and duplicate names get a suffix)
type QueryResult struct {
	Columns []string         `json:"columns"`
	Rows    []map[string]any `json:"rows"`
	More    bool             `json:"more"` // more rows than the limit
}

// RunQuery executa SQL livre e devolve no maximo limit linhas
func (m *DBManager) RunQuery(ctx context.Context, query string, limit int) (QueryResult, error) {
	if m.conn == nil {
		return QueryResult{}, fmt.Errorf("no database connected")
	}
	rows, err := m.conn.QueryContext(ctx, query)
	if err != nil {
		return QueryResult{}, err
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return QueryResult{}, err
	}
	uuids := uuidColumns(rows)
	res := QueryResult{Columns: uniqueNames(cols), Rows: []map[string]any{}}
	values := make([]any, len(cols))
	ptrs := make([]any, len(cols))
	for i := range values {
		ptrs[i] = &values[i]
	}
	for rows.Next() {
		if len(res.Rows) == limit {
			res.More = true
			break
		}
		if err := rows.Scan(ptrs...); err != nil {
			return QueryResult{}, err
		}
		fixUUIDs(values, uuids)
		row := make(map[string]any, len(cols))
		for i, c := range res.Columns {
			row[c] = jsonValue(values[i])
		}
		res.Rows = append(res.Rows, row)
	}
	return res, rows.Err()
}

// uuidColumns marks UUID columns: the driver hands them over as 16 raw bytes, which would look like a BLOB
func uuidColumns(rows *sql.Rows) []bool {
	types, err := rows.ColumnTypes()
	if err != nil {
		return nil
	}
	out := make([]bool, len(types))
	for i, t := range types {
		out[i] = t.DatabaseTypeName() == "UUID"
	}
	return out
}

func fixUUIDs(values []any, uuids []bool) {
	for i, isUUID := range uuids {
		if b, ok := values[i].([]byte); isUUID && ok && len(b) == 16 {
			values[i] = fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
		}
	}
}

// uniqueNames renames repeated result columns ("id", "id (2)") so each one keeps its own value
func uniqueNames(cols []string) []string {
	seen := map[string]int{}
	out := make([]string, len(cols))
	for i, c := range cols {
		seen[c]++
		out[i] = c
		for n := seen[c]; n > 1; n++ {
			if cand := fmt.Sprintf("%s (%d)", c, n); seen[cand] == 0 {
				out[i] = cand
				seen[cand] = 1
				break
			}
		}
	}
	return out
}

// Retorna lista de nomes de tabelas no banco atual
// !T: Executes DuckDB-specific SHOW TABLES query and returns string slice
func (m *DBManager) ListTables() ([]string, error) {
	if m.conn == nil {
		return nil, fmt.Errorf("no database connected")
	}

	// Usa cache preenchido no Connect; evita nova consulta se cache existir
	if len(m.tableList) > 0 && len(m.tableSet) == len(m.tableList) {
		copied := make([]string, len(m.tableList))
		copy(copied, m.tableList)
		return copied, nil
	}

	if err := m.refreshTableCache(); err != nil {
		return nil, err
	}
	copied := make([]string, len(m.tableList))
	copy(copied, m.tableList)
	return copied, nil
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
	query := fmt.Sprintf(`PRAGMA table_info(%s)`, quoteIdent(tableName))
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
		var notNull bool // DuckDB returns BOOLEAN for notnull and pk
		var dfltValue interface{}
		var pk bool

		if err := rows.Scan(&cid, &name, &colType, &notNull, &dfltValue, &pk); err != nil {
			return nil, fmt.Errorf("failed to scan column: %w", err)
		}

		nullStr := "YES"
		if notNull {
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

	// Usa cache para evitar overhead de conexao repetida
	if m.tableSet == nil || len(m.tableSet) == 0 {
		if err := m.refreshTableCache(); err != nil {
			return "", err
		}
	}
	if _, ok := m.tableSet[tableName]; !ok {
		return "", fmt.Errorf("table not found: %s", tableName)
	}

	return tableName, nil
}

// Filter e uma condicao "coluna = valor exato" vinda do clique direito numa celula; Value nil = IS NULL
// !T: Value is the cell as the UI got it (JSON string, number or bool)
type Filter struct {
	Column string `json:"column"`
	Value  any    `json:"value"`
}

// filterWhere monta " WHERE ..." (AND entre os filtros) e os parametros; types = tipo DuckDB de cada coluna da tabela
// !T: Column names must exist in types and are quoted; values are always bound. The value is cast to the column
// type (text read from the catalog, never user input) so the comparison happens in that type: REAL 0.1 equals the
// shown 0.1, a timestamp equals its shown text.
func filterWhere(filters []Filter, types map[string]string) (string, []any, error) {
	var conds []string
	var args []any
	for _, f := range filters {
		typ, ok := types[f.Column]
		if !ok {
			return "", nil, fmt.Errorf("column not found: %s", f.Column)
		}
		switch f.Value.(type) {
		case nil:
			conds = append(conds, quoteIdent(f.Column)+" IS NULL")
			continue
		case string, bool, float64, float32, int, int64:
		default:
			return "", nil, fmt.Errorf("cannot filter column %s by a list or struct value", f.Column)
		}
		conds = append(conds, quoteIdent(f.Column)+" = CAST(? AS "+typ+")")
		args = append(args, f.Value)
	}
	if len(conds) == 0 {
		return "", nil, nil
	}
	return " WHERE " + strings.Join(conds, " AND "), args, nil
}

// tableWhere reads the column types of the (already validated) table only when there are filters
func (m *DBManager) tableWhere(tableName string, filters []Filter) (string, []any, error) {
	if len(filters) == 0 {
		return "", nil, nil
	}
	schema, err := m.GetTableSchema(tableName)
	if err != nil {
		return "", nil, err
	}
	types := make(map[string]string, len(schema))
	for _, c := range schema {
		types[c.Name] = c.Type
	}
	return filterWhere(filters, types)
}

// AccessReader diz qual leitor abriria um .mdb/.accdb agora (para o Sobre): "Access ODBC", "mdbtools" ou ""
func AccessReader() string {
	reader, _ := chooseAccessReader(os.Getenv("MDB2SQL_ACCESS_READER"), odbcInstalled(), mdbtoolsAvailable())
	return reader
}

// Executa SELECT na tabela e retorna resultados como slice de maps
// !T: Returns []map[string]interface{} for dynamic column handling in frontend
func (m *DBManager) QueryTable(tableName string, limit int, filters ...Filter) ([]map[string]interface{}, error) {
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
	where, args, err := m.tableWhere(tableName, filters)
	if err != nil {
		return nil, err
	}
	query := fmt.Sprintf(`SELECT * FROM %s%s LIMIT ?`, quoteIdent(tableName), where)
	rows, err := m.conn.Query(query, append(args, limit)...)
	if err != nil {
		return nil, fmt.Errorf("failed to query table: %w", err)
	}
	defer rows.Close()

	// Pega nomes das colunas
	columns, err := rows.Columns()
	if err != nil {
		return nil, fmt.Errorf("failed to get columns: %w", err)
	}
	uuids := uuidColumns(rows)

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
		fixUUIDs(values, uuids)

		// Cria map com nome_coluna -> valor
		row := make(map[string]interface{})
		for i, col := range columns {
			row[col] = jsonValue(values[i])
		}
		results = append(results, row)
	}

	return results, rows.Err()
}

// Retorna numero total de linhas em uma tabela
// !T: Executes COUNT(*) query with validated table name
func (m *DBManager) GetRowCount(tableName string, filters ...Filter) (int, error) {
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
	where, args, err := m.tableWhere(tableName, filters)
	if err != nil {
		return 0, err
	}
	query := fmt.Sprintf(`SELECT COUNT(*) FROM %s%s`, quoteIdent(tableName), where)
	var count int
	if err = m.conn.QueryRow(query, args...).Scan(&count); err != nil {
		return 0, fmt.Errorf("failed to count rows: %w", err)
	}

	return count, nil
}

// DuckDBVersion retorna a versao da biblioteca DuckDB linkada (ex.: "v2.0.0")
// !T: Uses a throwaway in-memory database so it works before any file is opened
func DuckDBVersion() (string, error) {
	conn, err := sql.Open("duckdb", "")
	if err != nil {
		return "", err
	}
	defer conn.Close()
	var version string
	err = conn.QueryRow("SELECT version()").Scan(&version)
	return version, err
}

// Fecha conexao com o banco - sempre chame ao finalizar uso
// !T: Closes sql.DB connection and resets manager state
func (m *DBManager) Close() error {
	if m.conn != nil {
		err := m.conn.Close()
		m.conn = nil
		m.currentDB = ""
		m.source = ""
		m.tableSet = nil
		m.tableList = nil
		return err
	}
	return nil
}

// Atualiza cache de tabelas existentes no banco atual
func (m *DBManager) refreshTableCache() error {
	if m.conn == nil {
		return fmt.Errorf("no database connected")
	}

	rows, err := m.conn.Query("SHOW TABLES")
	if err != nil {
		return fmt.Errorf("failed to list tables: %w", err)
	}
	defer rows.Close()

	tableSet := make(map[string]struct{})
	var tableList []string
	for rows.Next() {
		var tableName string
		if err := rows.Scan(&tableName); err != nil {
			return fmt.Errorf("failed to scan table name: %w", err)
		}
		tableSet[tableName] = struct{}{}
		tableList = append(tableList, tableName)
	}
	if err := rows.Err(); err != nil {
		return err
	}

	m.tableSet = tableSet
	m.tableList = tableList
	return nil
}
