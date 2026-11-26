// Exportacao: banco inteiro para .duckdb/.sqlite/.xlsx; tabela ou resultado de SQL para .csv/.xlsx
// !T: Writes into a new private folder next to the target and renames at the end, so a cancelled or failed export
// leaves no half file and never touches another file or the old target

package backend

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/csv"
	"errors"
	"fmt"
	"math"
	"math/big"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode/utf16"
	"unicode/utf8"

	"github.com/duckdb/duckdb-go/v2"
	"github.com/xuri/excelize/v2"

	"mdb2sql/i18n"
)

// MaxExcelDataRows: an Excel sheet has 1,048,576 rows and the first is the header (a var so tests can split small tables)
var MaxExcelDataRows = 1048575

const maxSheetName = 31 // Excel limit, in UTF-16 units

var sheetBad = strings.NewReplacer(":", "_", `\`, "_", "/", "_", "?", "_", "*", "_", "[", "_", "]", "_")

// SheetName returns the Excel name for part (1-based) of a table: invalid characters replaced, cut to 31,
// " (2)", " (3)"... for continuation sheets and "~2", "~3"... when the cut name is already used (case-insensitive)
func SheetName(table string, part int, used map[string]bool) string {
	base := strings.Trim(sheetBad.Replace(table), "'")
	if strings.TrimSpace(base) == "" {
		base = "Sheet"
	}
	if strings.EqualFold(base, "History") { // reserved by Excel
		base += "_"
	}
	suffix := ""
	if part > 1 {
		suffix = fmt.Sprintf(" (%d)", part)
	}
	for n := 1; ; n++ {
		tag := suffix
		if n > 1 {
			tag = fmt.Sprintf("~%d", n) + suffix
		}
		// a cut may leave an apostrophe at the end, which Excel rejects
		head := strings.TrimRight(truncUTF16(base, maxSheetName-utf16Len(tag)), "'")
		name := head + tag
		if key := strings.ToLower(name); !used[key] {
			used[key] = true
			return name
		}
	}
}

func utf16Len(s string) int { return len(utf16.Encode([]rune(s))) }

func truncUTF16(s string, max int) string {
	n := 0
	for i, r := range s {
		if n += utf16.RuneLen(r); n > max {
			return s[:i]
		}
	}
	return s
}

// exportItem: the sheet/table name, its SELECT and the values of the SELECT's ? parameters (search and filters)
type exportItem struct {
	name, query string
	args        []any
	on          queryer // nil = the connection pool; the SQL tab result is read on its read-only connection
}

func (m *DBManager) queryerOf(it exportItem) queryer {
	if it.on != nil {
		return it.on
	}
	return m.conn
}

// valuesQuery is a SELECT that returns rows under header (schema and report sheets go through the same writers as the
// tables); an int becomes a number, anything else a text
func valuesQuery(header []string, rows [][]any) string {
	cols := make([]string, len(header))
	if len(rows) == 0 {
		for i, h := range header {
			cols[i] = "CAST(NULL AS VARCHAR) AS " + quoteIdent(h)
		}
		return "SELECT " + strings.Join(cols, ", ") + " WHERE false"
	}
	lines := make([]string, len(rows))
	for i, r := range rows {
		cells := make([]string, len(r))
		for j, v := range r {
			if n, ok := v.(int); ok {
				cells[j] = fmt.Sprint(n)
			} else {
				cells[j] = quoteLiteral(fmt.Sprint(v))
			}
		}
		lines[i] = "(" + strings.Join(cells, ", ") + ")"
	}
	for i, h := range header {
		cols[i] = quoteIdent(h)
	}
	return "SELECT * FROM (VALUES " + strings.Join(lines, ", ") + ") AS v(" + strings.Join(cols, ", ") + ")"
}

var (
	fileBad      = strings.NewReplacer("<", "_", ">", "_", ":", "_", `"`, "_", "/", "_", `\`, "_", "|", "_", "?", "_", "*", "_")
	fileReserved = regexp.MustCompile(`(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])$`) // device names on Windows
)

// uniqueFold gives a name already taken, ignoring case (as file and table names do), the suffix " (2)", " (3)"...
func uniqueFold(names []string) []string {
	used := map[string]bool{}
	out := make([]string, len(names))
	for i, base := range names {
		name := base
		for k := 2; used[strings.ToLower(name)]; k++ {
			name = fmt.Sprintf("%s (%d)", base, k)
		}
		used[strings.ToLower(name)] = true
		out[i] = name
	}
	return out
}

// CSVNames gives each table or report sheet its file name "<name>.csv": the characters a file name cannot have become
// "_", and a name already taken gets " (2)", " (3)"...
func CSVNames(names []string) []string {
	out := make([]string, len(names))
	for i, n := range names {
		out[i] = strings.TrimRight(fileBad.Replace(n), " .")
		if out[i] == "" || fileReserved.MatchString(out[i]) {
			out[i] = "_" + out[i]
		}
	}
	out = uniqueFold(out)
	for i := range out {
		out[i] += ".csv"
	}
	return out
}

func tableItems(tables []string) []exportItem {
	items := make([]exportItem, len(tables))
	for i, t := range tables {
		items[i] = exportItem{name: t, query: "SELECT * FROM " + quoteIdent(t)}
	}
	return items
}

// ExportDatabase writes every table to out; format is "duckdb", "sqlite" or "xlsx"
func (m *DBManager) ExportDatabase(ctx context.Context, format, out string, progress Progress) error {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.conn == nil {
		return fmt.Errorf("no database connected")
	}
	items := tableItems(m.tableList)
	return m.writeAtomically(out, func(tmp string) error {
		switch format {
		case "duckdb", "sqlite":
			return copyDatabase(ctx, m.conn, format, tmp, items, progress)
		case "xlsx":
			return m.writeXLSX(ctx, tmp, items, progress, 0)
		}
		return fmt.Errorf("unknown export format %q", format)
	})
}

// ExportTable writes one table to out (format "csv" or "xlsx"): every row, or with a search or filters only the rows
// the Data tab finds with them (the user chose "only the rows found")
func (m *DBManager) ExportTable(ctx context.Context, table, format, out string, progress Progress, search string, filters ...Filter) error {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.conn == nil {
		return fmt.Errorf("no database connected")
	}
	if _, err := m.validateTableName(table); err != nil {
		return err
	}
	total, err := m.rowCount(ctx, table, search, filters...)
	if err != nil {
		return err
	}
	where, args, err := m.tableWhere(table, filters, search)
	if err != nil {
		return err
	}
	return m.exportOne(ctx, exportItem{name: table, query: "SELECT * FROM " + quoteIdent(table) + where, args: args}, format, out, progress, total)
}

// ExportQuery writes the full result of a SQL tab query to out (format "csv" or "xlsx"); the sheet is "Result". The
// query runs as in the SQL tab: only reads, inside a read-only transaction (readonly.go).
func (m *DBManager) ExportQuery(ctx context.Context, query, format, out string, progress Progress) error {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.conn == nil {
		return fmt.Errorf("no database connected")
	}
	conn, done, err := m.readOnlyConn(ctx, query)
	if err != nil {
		return err
	}
	defer done()
	return m.exportOne(ctx, exportItem{name: "Result", query: query, on: conn}, format, out, progress, 0)
}

// ExportMarked writes the marked rows of table (see markedTail) to out (format "csv" or "xlsx"): every column, in
// table order
func (m *DBManager) ExportMarked(ctx context.Context, table string, marks []map[string]any, format, out string, progress Progress) error {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.conn == nil {
		return fmt.Errorf("no database connected")
	}
	sel, from, args, _, err := m.markedTail(table, marks)
	if err != nil {
		return err
	}
	if from == "" {
		return fmt.Errorf("no marked row")
	}
	return m.exportOne(ctx, exportItem{name: table, query: "SELECT " + sel + from, args: args}, format, out, progress, len(marks))
}

// ExportSchema writes the schema of table, or with table "" of every table, to out (format "csv" or "xlsx"): the
// columns of the Schema tab under its translated titles (Column, Type, Nullable; the database schema starts with
// Table), nullability as the translated Yes/No
func (m *DBManager) ExportSchema(ctx context.Context, table, format, out string, progress Progress) error {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.conn == nil {
		return fmt.Errorf("no database connected")
	}
	header := []string{i18n.T("schema.table"), i18n.T("schema.column"), i18n.T("schema.type"), i18n.T("schema.nullable")}
	tables, sheet := m.tableList, i18n.T("tab.schema")
	if table != "" {
		tables, sheet, header = []string{table}, table, header[1:]
	}
	var rows [][]any
	for _, t := range tables {
		schema, err := m.tableSchema(t)
		if err != nil {
			return err
		}
		for _, c := range schema {
			row := []any{t, c.Name, c.Type, i18n.T("schema.yes")}
			if c.Null == "NO" {
				row[3] = i18n.T("schema.no")
			}
			rows = append(rows, row[4-len(header):])
		}
	}
	return m.exportOne(ctx, exportItem{name: sheet, query: valuesQuery(header, rows)}, format, out, progress, len(rows))
}

// ExportTablesCSV writes every table to dir, one "<table>.csv" each (see CSVNames)
func (m *DBManager) ExportTablesCSV(ctx context.Context, dir string, progress Progress) error {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.conn == nil {
		return fmt.Errorf("no database connected")
	}
	return m.writeCSVFolder(ctx, dir, tableItems(m.tableList), progress)
}

// ExportSearch writes the result of the "All tables" search to an Excel file: one sheet per table of tables (the ones
// with a match) with the rows the Data tab search finds there, every column
func (m *DBManager) ExportSearch(ctx context.Context, search string, tables []string, out string, progress Progress) error {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.conn == nil {
		return fmt.Errorf("no database connected")
	}
	if len(tables) == 0 {
		return fmt.Errorf("no table to export")
	}
	items := make([]exportItem, len(tables))
	for i, t := range tables {
		if _, err := m.validateTableName(t); err != nil {
			return err
		}
		where, args, err := m.tableWhere(t, nil, search)
		if err != nil {
			return err
		}
		items[i] = exportItem{name: t, query: "SELECT * FROM " + quoteIdent(t) + where, args: args}
	}
	return m.writeAtomically(out, func(tmp string) error { return m.writeXLSX(ctx, tmp, items, progress, 0) })
}

// writeCSVFolder writes one CSV per item into dir (names by CSVNames): all of them go to a private folder inside dir
// first and are moved at the end, so a cancelled or failed export leaves dir as it was
func (m *DBManager) writeCSVFolder(ctx context.Context, dir string, items []exportItem, progress Progress) error {
	sheets := make([]string, len(items))
	for i, it := range items {
		sheets[i] = it.name
	}
	names := CSVNames(sheets)
	tmp, err := os.MkdirTemp(dir, ".mdb2sql-export-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	for i, it := range items {
		progress(i, len(items), it.name)
		if err := m.writeCSV(ctx, filepath.Join(tmp, names[i]), it, func(int, int, string) {}, 0); err != nil {
			if ctx.Err() != nil {
				return errors.New(i18n.T("err.exportCancelled"))
			}
			return fmt.Errorf("%s: %w", it.name, err)
		}
		if ctx.Err() != nil { // a small table ends before its writer looks at the cancel
			return errors.New(i18n.T("err.exportCancelled"))
		}
	}
	progress(len(items), len(items), "")
	for _, name := range names {
		if err := os.Rename(filepath.Join(tmp, name), filepath.Join(dir, name)); err != nil {
			return err
		}
	}
	return nil
}

func (m *DBManager) exportOne(ctx context.Context, it exportItem, format, out string, progress Progress, total int) error {
	return m.writeAtomically(out, func(tmp string) error {
		switch format {
		case "csv":
			return m.writeCSV(ctx, tmp, it, progress, total)
		case "xlsx":
			return m.writeXLSX(ctx, tmp, []exportItem{it}, progress, total)
		}
		return fmt.Errorf("unknown export format %q", format)
	})
}

// SaveConverted copies the SQLite file an Access file was converted to (File > Save as SQLite); the database stays
// open on the temporary file
func (m *DBManager) SaveConverted(out string) error {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.converted == "" {
		return fmt.Errorf("no converted file")
	}
	return m.writeAtomically(out, func(tmp string) error { return copyFile(m.converted, tmp) })
}

func (m *DBManager) writeAtomically(out string, write func(tmp string) error) error {
	// never over the open file, nor over the temporary SQLite an Access file is read from
	if same, _ := filepath.Abs(out); m.currentDB != "" && (strings.EqualFold(same, m.currentDB) || strings.EqualFold(same, m.converted)) {
		return errors.New(i18n.T("err.exportOverOpen"))
	}
	// a folder of our own (unique name, same disk as the target): a user file named "x.partial.csv" is never
	// overwritten or deleted, and the .wal/-journal side files of the engines stay inside it
	dir, err := os.MkdirTemp(filepath.Dir(out), ".mdb2sql-export-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	tmp := filepath.Join(dir, filepath.Base(out))
	if err := write(tmp); err != nil {
		if errors.Is(err, context.Canceled) {
			return errors.New(i18n.T("err.exportCancelled"))
		}
		return err
	}
	// Rename replaces the old target in one step (MoveFileEx REPLACE_EXISTING); if it fails the old target stays
	return os.Rename(tmp, out)
}

// sqliteColumn gives the declared SQLite type of a DuckDB column and the expression that writes it. SQLite has no
// boolean, decimal or date types: the declared name keeps the type for readers (DuckDB reads DATETIME as TIMESTAMP),
// booleans are stored 0/1, dates as ISO text, decimals as REAL (exact up to 15 significant digits).
func sqliteColumn(name, duckType string) (decl, expr string) {
	col := quoteIdent(name)
	t := strings.ToUpper(duckType)
	switch t {
	case "BOOLEAN", "DOUBLE", "DATE", "BLOB":
		return t, col
	case "TINYINT", "SMALLINT", "INTEGER", "BIGINT", "UTINYINT", "USMALLINT", "UINTEGER":
		return "INTEGER", col
	case "FLOAT", "REAL":
		// through text: Access Single 0.1 must stay 0.1, not 0.10000000149011612
		return "REAL", "CAST(CAST(" + col + " AS VARCHAR) AS DOUBLE)"
	case "TIMESTAMP", "TIMESTAMP_S", "TIMESTAMP_MS", "TIMESTAMP_NS":
		return "DATETIME", col
	}
	if strings.HasPrefix(t, "DECIMAL(") {
		// a whole DECIMAL (Access Numeric(p,0): RTUNO, PNTNO...) is an integer: DuckDB reads a declared DECIMAL back as
		// DOUBLE and an INTEGER as BIGINT (standard 19a); up to 18 digits it fits SQLite's 64-bit integer
		var p, s int
		if _, err := fmt.Sscanf(t, "DECIMAL(%d,%d)", &p, &s); err == nil && s == 0 && p <= 18 {
			return "INTEGER", col
		}
		return t, col
	}
	// VARCHAR, UUID, TIME, HUGEINT, UBIGINT, lists...: text keeps every digit and character
	return "TEXT", "CAST(" + col + " AS VARCHAR)"
}

// copySQLiteTable creates the table in the attached SQLite file with typed columns (raw DDL through sqlite_query,
// because DuckDB's own CREATE TABLE would declare only BIGINT/DOUBLE/VARCHAR/BLOB) and inserts the rows
func copySQLiteTable(ctx context.Context, conn *sql.Conn, it exportItem) error {
	rows, err := conn.QueryContext(ctx, "SELECT column_name, column_type FROM (DESCRIBE "+it.query+")")
	if err != nil {
		return err
	}
	var defs, exprs []string
	for rows.Next() {
		var name, typ string
		if err := rows.Scan(&name, &typ); err != nil {
			rows.Close()
			return err
		}
		decl, expr := sqliteColumn(name, typ)
		defs = append(defs, quoteIdent(name)+" "+decl)
		exprs = append(exprs, expr)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	ddl := fmt.Sprintf("CREATE TABLE %s (%s)", quoteIdent(it.name), strings.Join(defs, ", "))
	if _, err := conn.ExecContext(ctx, "CALL sqlite_query('mdb2sql_out', "+quoteLiteral(ddl)+")"); err != nil {
		return err
	}
	_, err = conn.ExecContext(ctx, fmt.Sprintf("INSERT INTO mdb2sql_out.%s SELECT %s FROM (%s)",
		quoteIdent(it.name), strings.Join(exprs, ", "), it.query))
	return err
}

// copyDatabase attaches the target file and copies each item: DuckDB with CREATE TABLE AS, SQLite typed
func copyDatabase(ctx context.Context, db *sql.DB, format, path string, items []exportItem, progress Progress) error {
	conn, err := db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	attach := "ATTACH " + quoteLiteral(path) + " AS mdb2sql_out"
	if format == "sqlite" {
		ext, err := sqliteExtension()
		if err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, "LOAD "+quoteLiteral(ext)); err != nil {
			return err
		}
		attach += " (TYPE sqlite)"
	}
	if _, err := conn.ExecContext(ctx, attach); err != nil {
		return err
	}
	// on error the file must still be closed before it is deleted
	defer conn.ExecContext(context.Background(), "DETACH DATABASE IF EXISTS mdb2sql_out")
	if format == "sqlite" {
		// every table in one transaction: one commit for the file, not one per table (the sqlite extension runs
		// sqlite_query inside a transaction, so PRAGMA synchronous/journal_mode cannot be changed from here)
		if _, err := conn.ExecContext(ctx, "BEGIN TRANSACTION"); err != nil {
			return err
		}
		defer conn.ExecContext(context.Background(), "ROLLBACK") // no-op after COMMIT
	}
	for i, it := range items {
		progress(i, len(items), it.name)
		if format == "sqlite" {
			err = copySQLiteTable(ctx, conn, it)
		} else {
			_, err = conn.ExecContext(ctx, fmt.Sprintf("CREATE TABLE mdb2sql_out.%s AS %s", quoteIdent(it.name), it.query))
		}
		if err != nil {
			return fmt.Errorf("%s: %w", it.name, err)
		}
	}
	progress(len(items), len(items), "")
	if format == "sqlite" {
		if _, err := conn.ExecContext(ctx, "COMMIT"); err != nil {
			return err
		}
	}
	_, err = conn.ExecContext(ctx, "DETACH DATABASE mdb2sql_out")
	return err
}

// rowProgress reports rows when one table is exported (total 0 = unknown) and checks for cancel
func rowProgress(ctx context.Context, progress Progress, label string, total int) func(n int) error {
	return func(n int) error {
		if n%5000 != 0 {
			return nil
		}
		progress(n, total, label)
		return ctx.Err()
	}
}

func (m *DBManager) writeCSV(ctx context.Context, path string, it exportItem, progress Progress, total int) error {
	rows, err := m.queryerOf(it).QueryContext(ctx, it.query, it.args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return err
	}
	uuids := uuidColumns(rows)
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	bw := bufio.NewWriter(f)
	bw.WriteString("\xEF\xBB\xBF") // BOM: Excel then reads the file as UTF-8
	w := csv.NewWriter(bw)
	w.UseCRLF = true
	if err := w.Write(cols); err != nil {
		return err
	}
	values, ptrs := scanTargets(len(cols))
	record := make([]string, len(cols))
	onRow := rowProgress(ctx, progress, it.name, total)
	for n := 1; rows.Next(); n++ {
		if err := rows.Scan(ptrs...); err != nil {
			return err
		}
		fixUUIDs(values, uuids)
		for i, v := range values {
			record[i] = cellString(v)
		}
		if err := w.Write(record); err != nil {
			return err
		}
		if err := onRow(n); err != nil {
			return err
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	w.Flush()
	if err := w.Error(); err != nil {
		return err
	}
	if err := bw.Flush(); err != nil {
		return err
	}
	return f.Close()
}

func scanTargets(n int) ([]any, []any) {
	values := make([]any, n)
	ptrs := make([]any, n)
	for i := range values {
		ptrs[i] = &values[i]
	}
	return values, ptrs
}

// writeXLSX writes one sheet per item (more when an item has more rows than an Excel sheet holds)
func (m *DBManager) writeXLSX(ctx context.Context, path string, items []exportItem, progress Progress, total int) error {
	f := excelize.NewFile()
	defer f.Close()
	used := map[string]bool{}
	first := true
	for i, it := range items {
		onRow := func(int) error { return ctx.Err() }
		if len(items) == 1 {
			onRow = rowProgress(ctx, progress, it.name, total)
		} else {
			progress(i, len(items), it.name)
		}
		if err := m.writeSheets(ctx, f, used, &first, it, onRow); err != nil {
			return fmt.Errorf("%s: %w", it.name, err)
		}
	}
	if len(items) > 1 {
		progress(len(items), len(items), "")
	}
	return f.SaveAs(path)
}

func (m *DBManager) writeSheets(ctx context.Context, f *excelize.File, used map[string]bool, first *bool, it exportItem, onRow func(int) error) error {
	rows, err := m.queryerOf(it).QueryContext(ctx, it.query, it.args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return err
	}
	uuids := uuidColumns(rows)
	// counted on the pool (a SQL tab query that cannot be counted must not abort its own read-only transaction)
	total := -1 // row count for the sheet dimension; unknown (-1) if the query cannot be counted
	countQuery := "SELECT count(*) FROM (" + strings.TrimRight(strings.TrimSpace(it.query), "; \t\r\n") + ")"
	if err := m.conn.QueryRowContext(ctx, countQuery, it.args...).Scan(&total); err != nil {
		total = -1
	}
	header := make([]any, len(cols))
	for i, c := range cols {
		header[i] = c
	}
	widths := m.xlsxWidths(ctx, it, cols)
	var sw *excelize.StreamWriter
	part, line := 0, 0 // line = last written sheet row
	newSheet := func() error {
		if sw != nil {
			if err := sw.Flush(); err != nil {
				return err
			}
		}
		part++
		name := SheetName(it.name, part, used)
		if *first {
			if err := f.SetSheetName("Sheet1", name); err != nil {
				return err
			}
			*first = false
		} else if _, err := f.NewSheet(name); err != nil {
			return err
		}
		// the stream writer leaves <dimension ref="A1">; openpyxl read-only (and so pandas) would then see one cell
		if total >= 0 {
			last, _ := excelize.CoordinatesToCellName(max(len(cols), 1), min(total-(part-1)*MaxExcelDataRows, MaxExcelDataRows)+1)
			if err := f.SetSheetDimension(name, "A1:"+last); err != nil {
				return err
			}
		}
		if sw, err = f.NewStreamWriter(name); err != nil {
			return err
		}
		for i, w := range widths { // before the first row: the stream writer takes widths only then
			if err := sw.SetColWidth(i+1, i+1, w); err != nil {
				return err
			}
		}
		line = 1
		return sw.SetRow("A1", header)
	}
	if err := newSheet(); err != nil {
		return err
	}
	values, ptrs := scanTargets(len(cols))
	cells := make([]any, len(cols))
	for n := 1; rows.Next(); n++ {
		if line > MaxExcelDataRows {
			if err := newSheet(); err != nil {
				return err
			}
		}
		if err := rows.Scan(ptrs...); err != nil {
			return err
		}
		fixUUIDs(values, uuids)
		for i, v := range values {
			cells[i] = xlsxValue(v)
		}
		line++
		cell, _ := excelize.CoordinatesToCellName(1, line)
		if err := sw.SetRow(cell, cells); err != nil {
			return err
		}
		if err := onRow(n); err != nil {
			return err
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	return sw.Flush()
}

// xlsxWidths: the width of each column of a sheet, fitted to the longest text of its title and cells (best fit,
// standard 19g), between 8 and 60 characters; nil (Excel's default) if the query cannot be measured. Measured on the
// pool, as the row count, with the columns renamed by position (a result may repeat a name)
func (m *DBManager) xlsxWidths(ctx context.Context, it exportItem, cols []string) []float64 {
	if len(cols) == 0 {
		return nil
	}
	alias := make([]string, len(cols))
	exprs := make([]string, len(cols))
	for i := range cols {
		alias[i] = fmt.Sprintf("c%d", i)
		exprs[i] = fmt.Sprintf("coalesce(max(length(CAST(c%d AS VARCHAR))), 0)", i)
	}
	query := fmt.Sprintf("SELECT %s FROM (%s) AS mdb2sql_w(%s)", strings.Join(exprs, ", "),
		strings.TrimRight(strings.TrimSpace(it.query), "; \t\r\n"), strings.Join(alias, ", "))
	longest := make([]int64, len(cols))
	ptrs := make([]any, len(cols))
	for i := range longest {
		ptrs[i] = &longest[i]
	}
	if err := m.conn.QueryRowContext(ctx, query, it.args...).Scan(ptrs...); err != nil {
		return nil
	}
	widths := make([]float64, len(cols))
	for i, c := range cols {
		n := max(longest[i], int64(utf8.RuneCountInString(c)))
		widths[i] = min(max(float64(n)+2, 8), 60)
	}
	return widths
}

// xlsxValue keeps numbers, booleans and dates as Excel values; the rest becomes text
func xlsxValue(v any) any {
	switch x := v.(type) {
	case duckdb.Decimal:
		return x.Float64()
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
	case []byte:
		return cellString(x)
	case time.Time:
		if x.Year() < 1900 { // before Excel's first date
			return cellString(x)
		}
	case nil, bool, string, int8, int16, int32, int64, uint8, uint16, uint32, uint64, int, uint:
	default:
		return cellString(v)
	}
	return v
}
