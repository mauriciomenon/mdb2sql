package backend

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/xuri/excelize/v2"

	"mdb2sql/i18n"
)

// featureDBs: one DuckDB file and, when the sqlite extension is embedded (after a build), the same data as SQLite
// (there the view "dupla" is a table). Tables in list order: dupla, outra, pontos, termos, vazia.
func featureDBs(t *testing.T) map[string]string {
	t.Helper()
	dir := t.TempDir()
	duck := filepath.Join(dir, "f.duckdb")
	db, err := sql.Open("duckdb", duck)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE pontos (id INTEGER, nome VARCHAR, sub VARCHAR, num INTEGER, valor DOUBLE);
		INSERT INTO pontos VALUES (1, 'GERADOR A', 'U9A', 10, 1.5), (2, ' gerador a ', 'U9A', 20, 2), (3, 'Turbina B', 'gerador a', 30, 3),
		                          (4, 'Turbina C', NULL, 238, 4), (5, 'GERADOR A', 'GERADOR A', 50, 5);
		CREATE TABLE outra (codigo VARCHAR, obs VARCHAR); INSERT INTO outra VALUES ('238', 'turbina b fora'), ('x', NULL);
		CREATE TABLE termos ("Term" VARCHAR, x INTEGER); INSERT INTO termos VALUES ('gerador a', 1);
		CREATE TABLE vazia (a INTEGER);
		CREATE VIEW dupla AS SELECT * FROM (VALUES ('a', 1), ('a', 1), ('b', 2)) v(k, n);`)
	db.Close()
	if err != nil {
		t.Fatal(err)
	}
	files := map[string]string{SourceDuckDB: duck}
	if hasAsset(sqliteExtensionAsset) {
		m := NewDBManager()
		if err := m.Connect(duck); err != nil {
			t.Fatal(err)
		}
		lite := filepath.Join(dir, "f.sqlite")
		if err := m.ExportDatabase(context.Background(), "sqlite", lite, func(int, int, string) {}); err != nil {
			t.Fatal(err)
		}
		m.Close()
		files[SourceSQLite] = lite
	}
	return files
}

// eachFeatureDB runs the test on the DuckDB file and on the SQLite file
func eachFeatureDB(t *testing.T, test func(t *testing.T, m *DBManager, source string)) {
	for source, file := range featureDBs(t) {
		t.Run(source, func(t *testing.T) {
			m := NewDBManager()
			if err := m.Connect(file); err != nil {
				t.Fatal(err)
			}
			defer m.Close()
			test(t, m, source)
		})
	}
}

func noProgress(int, int, string) {}

// section 5: the SQL tab runs reads only, classified by DuckDB's statement type; nothing else runs at all, and the
// file, its copy and the in-memory catalog stay as they were
func TestSQLTabIsReadOnly(t *testing.T) {
	eachFeatureDB(t, func(t *testing.T, m *DBManager, source string) {
		ctx := context.Background()
		for _, q := range []string{
			`SELECT * FROM pontos`, `FROM pontos`, `WITH a AS (SELECT 1 AS x) SELECT * FROM a`, `VALUES (1)`, `SHOW TABLES`,
			`DESCRIBE pontos`, `SUMMARIZE pontos`, `EXPLAIN SELECT * FROM pontos`, `EXPLAIN ANALYZE SELECT count(*) FROM pontos`,
			`PRAGMA table_info('pontos')`, `PRAGMA database_size`, `select 1;`, `SELECT 1; SELECT 2 AS two`,
			`PIVOT pontos ON sub USING count(*)`,
			`SELECT 'sqlite_attach(x) it''s' AS s /* checkpoint() */ -- force_checkpoint()`, // names in text and comments are no calls
		} {
			res, err := m.RunQuery(ctx, q, 10)
			if err != nil || len(res.Columns) == 0 {
				t.Errorf("read refused: %s: %v", q, err)
			}
			if q == `SELECT 1; SELECT 2 AS two` && !reflect.DeepEqual(res.Columns, []string{"two"}) {
				t.Errorf("script of reads: columns %v", res.Columns)
			}
		}
		target := filepath.Join(t.TempDir(), "copied.csv")
		refused := i18n.T("err.sqlReadOnly")
		for _, q := range []string{
			`INSERT INTO pontos VALUES (9, 'z', 'z', 9, 9)`, `UPDATE pontos SET id = 0`, `DELETE FROM pontos`, `DROP TABLE pontos`,
			`ALTER TABLE pontos ADD COLUMN q INTEGER`, `CREATE TABLE memory.main.zz (a INTEGER)`, `CREATE TEMP TABLE zz (a INTEGER)`,
			`CREATE VIEW memory.main.zv AS SELECT 1`, `COPY pontos TO ` + quoteLiteral(target), `SET threads = 2`, `PRAGMA threads = 2`,
			`USE memory`, `ATTACH ':memory:' AS zm`, `DETACH src`, `BEGIN`, `COMMIT`, `CALL pragma_table_info('pontos')`, `CHECKPOINT`,
			`VACUUM`, `SELECT 1; CREATE TABLE memory.main.zz (a INTEGER)`, `CREATE TABLE memory.main.zz (a INTEGER); SELECT 1`,
			`COMMIT; CREATE TABLE memory.main.zz (a INTEGER); SELECT 1`,
			// review 26/11 (B1): a SELECT whose table function attaches or writes
			`SELECT * FROM sqlite_attach(` + quoteLiteral(filepath.Join(t.TempDir(), "outro.sqlite")) + `, overwrite=true)`,
			`FROM SQLITE_ATTACH('x.sqlite')`, `SELECT * FROM checkpoint()`, `SELECT 1; SELECT * FROM force_checkpoint()`,
			`SELECT * FROM (SELECT * FROM postgres_attach('dbname=x')) s`,
		} {
			if _, err := m.RunQuery(ctx, q, 10); err == nil || err.Error() != refused {
				t.Errorf("write not refused: %s: %v", q, err)
			}
			if err := m.ExportQuery(ctx, q, "csv", filepath.Join(t.TempDir(), "q.csv"), noProgress); err == nil || err.Error() != refused {
				t.Errorf("export of a write not refused: %s: %v", q, err)
			}
		}
		// EXPLAIN is a read for DuckDB, but EXPLAIN ANALYZE runs what it explains: the read-only transaction stops it
		if _, err := m.RunQuery(ctx, `EXPLAIN ANALYZE CREATE TABLE memory.main.zz AS SELECT 1 AS a`, 10); err == nil {
			t.Error("EXPLAIN ANALYZE of a CREATE ran")
		}
		// a query the engine cannot run says why, in the engine's words
		if _, err := m.RunQuery(ctx, `selec 1`, 10); err == nil || !strings.Contains(err.Error(), "syntax error") {
			t.Errorf("syntax error: %v", err)
		}
		if _, err := m.RunQuery(ctx, `SELECT * FROM nada`, 10); err == nil || err.Error() == refused {
			t.Errorf("unknown table: %v", err)
		}
		// nothing changed: the tables and their rows, no new table or view anywhere, no file written
		left := queryText(t, m, `SELECT table_name FROM duckdb_tables() WHERE table_name LIKE 'z%' UNION ALL SELECT view_name FROM duckdb_views() WHERE view_name LIKE 'z%'`)
		if len(left) != 0 {
			t.Errorf("created by a refused command: %v", left)
		}
		if n, _ := m.GetRowCount("pontos", ""); n != 5 {
			t.Errorf("pontos has %d rows", n)
		}
		if tables, _ := m.ListTables(); len(tables) != 5 {
			t.Errorf("tables %v", tables)
		}
		if _, err := os.Stat(target); !os.IsNotExist(err) {
			t.Errorf("COPY wrote %s", target)
		}
		// the SQL result still exports, on its read-only connection
		out := filepath.Join(t.TempDir(), "r.csv")
		if err := m.ExportQuery(ctx, `SELECT id FROM pontos WHERE id < 3 ORDER BY id`, "csv", out, noProgress); err != nil {
			t.Fatal(err)
		}
		if data, _ := os.ReadFile(out); string(data) != "\xEF\xBB\xBFid\r\n1\r\n2\r\n" {
			t.Errorf("exported result %q", data)
		}
		xlsx := filepath.Join(t.TempDir(), "r.xlsx")
		if err := m.ExportQuery(ctx, `SELECT id FROM pontos ORDER BY id`, "xlsx", xlsx, noProgress); err != nil {
			t.Fatal(err)
		}
	})
}

func ids(rows []map[string]any, col string) []any {
	out := make([]any, len(rows))
	for i, r := range rows {
		out[i] = r[col]
	}
	return out
}

// item 31: the marked rows of a table by the engine's rowid (DuckDB and SQLite tables), in table order whatever the
// order of marking; with no rowid (a view, a column named rowid) by all their values, equal rows marked together
func TestMarkedRows(t *testing.T) {
	eachFeatureDB(t, func(t *testing.T, m *DBManager, source string) {
		rows, err := m.QueryTable("pontos", 100, "")
		if err != nil || len(rows) != 5 {
			t.Fatalf("rows %v %v", rows, err)
		}
		for _, r := range rows {
			if _, ok := r[RowIDKey]; !ok {
				t.Fatalf("row without rowid: %v", r)
			}
		}
		// the search does not change which row is which
		found, _ := m.QueryTable("pontos", 100, "turbina c")
		if len(found) != 1 || found[0][RowIDKey] != rows[3][RowIDKey] {
			t.Errorf("rowid of the row found %v, want %v", found, rows[3][RowIDKey])
		}
		marks := []map[string]any{ // marked 4, then 2: as the UI sends them back (through JSON)
			{RowIDKey: uiValue(t, rows[3][RowIDKey])},
			{RowIDKey: uiValue(t, rows[1][RowIDKey])},
		}
		marked, err := m.MarkedRows("pontos", marks)
		if err != nil || !reflect.DeepEqual(ids(marked, "id"), []any{int32(2), int32(4)}) && !reflect.DeepEqual(ids(marked, "id"), []any{int64(2), int64(4)}) {
			t.Errorf("marked ids %v (%v), want 2 and 4 in table order", ids(marked, "id"), err)
		}
		if len(marked) == 2 && marked[0][RowIDKey] != rows[1][RowIDKey] {
			t.Errorf("marked row without its rowid: %v", marked[0])
		}
		if none, err := m.MarkedRows("pontos", nil); err != nil || none == nil || len(none) != 0 {
			t.Errorf("no marks: %v %v (want an empty list)", none, err)
		}
		if _, err := m.MarkedRows("nope", marks); err == nil {
			t.Error("unknown table must fail")
		}
		if _, err := m.MarkedRows("pontos", []map[string]any{{"id": 1.0}}); err == nil {
			t.Error("a mark without the rowid must fail on a table that has one")
		}
		out := filepath.Join(t.TempDir(), "m.csv")
		if err := m.ExportMarked(context.Background(), "pontos", marks, "csv", out, noProgress); err != nil {
			t.Fatal(err)
		}
		want := "\xEF\xBB\xBFid,nome,sub,num,valor\r\n2,\" gerador a \",U9A,20,2\r\n4,Turbina C,,238,4\r\n"
		if data, _ := os.ReadFile(out); string(data) != want {
			t.Errorf("marked csv\n%q\nwant\n%q", data, want)
		}
		if err := m.ExportMarked(context.Background(), "pontos", nil, "csv", out, noProgress); err == nil {
			t.Error("export without marks must fail")
		}
		if source != SourceDuckDB {
			return
		}
		// a view has no rowid: the row is all its values, and the two equal rows are marked together
		view, err := m.QueryTable("dupla", 100, "")
		if err != nil || len(view) != 3 {
			t.Fatalf("view rows %v %v", view, err)
		}
		if _, ok := view[0][RowIDKey]; ok {
			t.Fatalf("a view row with a rowid: %v", view[0])
		}
		both, err := m.MarkedRows("dupla", []map[string]any{uiValue(t, view[0]).(map[string]any)})
		if err != nil || !reflect.DeepEqual(ids(both, "k"), []any{"a", "a"}) {
			t.Errorf("marked by values %v (%v), want the two equal rows", both, err)
		}
	})
}

// a column named rowid hides the engine's rowid: such a table marks by values too
func TestMarkedRowsOfATableWithARowidColumn(t *testing.T) {
	src := filepath.Join(t.TempDir(), "r.duckdb")
	db, _ := sql.Open("duckdb", src)
	_, err := db.Exec(`CREATE TABLE r (rowid INTEGER, a VARCHAR); INSERT INTO r VALUES (7, 'x'), (7, NULL), (8, 'x')`)
	db.Close()
	if err != nil {
		t.Fatal(err)
	}
	m := NewDBManager()
	if err := m.Connect(src); err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	rows, _ := m.QueryTable("r", 100, "")
	if _, ok := rows[1][RowIDKey]; ok || len(rows) != 3 {
		t.Fatalf("rows %v", rows)
	}
	marked, err := m.MarkedRows("r", []map[string]any{uiValue(t, rows[1]).(map[string]any)})
	if err != nil || len(marked) != 1 || marked[0]["a"] != nil {
		t.Errorf("marked %v (%v), want only the row with the NULL", marked, err)
	}
}

func hitsOf(res TermsResult) []string {
	out := []string{}
	for _, h := range res.Hits {
		out = append(out, h.Term+"/"+h.Table+"/"+strings.Repeat("i", h.Rows))
	}
	return out
}

// item 32: terms are the pasted lines without the spaces at the ends, a repeated one searched once; whole value =
// the cell as trimmed text equals the term, ignoring case; contains = the cell has the term inside; every column of
// every table; hits in the order of the pasted list, a row found by two terms once per term
func TestSearchTerms(t *testing.T) {
	lines := []string{"gerador a", "  GERADOR A  ", "", "238", "PNTNAM", "   ", "turbina b", "Gerador A"}
	terms, repeated := CleanTerms(lines)
	if !reflect.DeepEqual(terms, []string{"gerador a", "238", "PNTNAM", "turbina b"}) || repeated != 2 {
		t.Fatalf("terms %q, %d repeated", terms, repeated)
	}
	eachFeatureDB(t, func(t *testing.T, m *DBManager, source string) {
		ctx := context.Background()
		var seen []string
		res, err := m.SearchTerms(ctx, lines, false, "", func(done, total int, table string) { seen = append(seen, table) })
		if err != nil {
			t.Fatal(err)
		}
		// "gerador a": rows 1, 2 (spaces at the ends), 3 (another column) and 5 (two cells, one row); 238 is a number
		// in pontos and a text in outra; "turbina b fora" is not the whole value
		if want := []string{"gerador a/pontos/iiii", "gerador a/termos/i", "238/outra/i", "238/pontos/i", "turbina b/pontos/i"}; !reflect.DeepEqual(hitsOf(res), want) {
			t.Errorf("whole value hits %v\nwant %v", hitsOf(res), want)
		}
		// per table, each row once: pontos row 3 (found by "gerador a" and "turbina b") counts once (standard 19d)
		if want := []TableHits{{"outra", 1}, {"pontos", 5}, {"termos", 1}}; !reflect.DeepEqual(res.Tables, want) {
			t.Errorf("tables %v, want %v", res.Tables, want)
		}
		if !reflect.DeepEqual(res.NotFound, []string{"PNTNAM"}) || !reflect.DeepEqual(res.Terms, terms) || res.Repeated != 2 {
			t.Errorf("not found %q, terms %q, repeated %d", res.NotFound, res.Terms, res.Repeated)
		}
		if want := []string{"dupla", "outra", "pontos", "termos", "vazia"}; !reflect.DeepEqual(seen, want) {
			t.Errorf("progress %v", seen)
		}
		// contains: the same, plus "turbina b fora"
		has, err := m.SearchTerms(ctx, lines, true, "", noProgress)
		if want := []string{"gerador a/pontos/iiii", "gerador a/termos/i", "238/outra/i", "238/pontos/i", "turbina b/outra/i", "turbina b/pontos/i"}; err != nil || !reflect.DeepEqual(hitsOf(has), want) {
			t.Errorf("contains hits %v (%v)\nwant %v", hitsOf(has), err, want)
		}
		// one table only (scope "This table")
		one, err := m.SearchTerms(ctx, lines, false, "outra", noProgress)
		if err != nil || !reflect.DeepEqual(hitsOf(one), []string{"238/outra/i"}) || !reflect.DeepEqual(one.NotFound, []string{"gerador a", "PNTNAM", "turbina b"}) {
			t.Errorf("one table: %v, not found %q (%v)", hitsOf(one), one.NotFound, err)
		}
		if _, err := m.SearchTerms(ctx, lines, false, "nope", noProgress); err == nil {
			t.Error("unknown table must fail")
		}
		if empty, err := m.SearchTerms(ctx, []string{" ", ""}, false, "", noProgress); err != nil || empty.Terms == nil || len(empty.Hits) != 0 {
			t.Errorf("no term: %+v %v", empty, err)
		}
		cancelled, cancel := context.WithCancel(ctx)
		cancel()
		if _, err := m.SearchTerms(cancelled, lines, false, "", noProgress); err == nil {
			t.Error("cancelled search must fail")
		}

		// the grid of a table (standard 19d): its own columns, no Term column; each row once, in the order of the first
		// term that finds it, then of the table (row 3, found by "gerador a" and "turbina b", once)
		grid, err := m.TermRows(ctx, "pontos", res.Terms, false, 0)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{"id", "nome", "sub", "num", "valor"}; !reflect.DeepEqual(grid.Columns, want) {
			t.Errorf("grid columns %v", grid.Columns)
		}
		var got []string
		for _, r := range grid.Rows {
			got = append(got, cellString(r["id"]))
		}
		if want := []string{"1", "2", "3", "5", "4"}; !reflect.DeepEqual(got, want) {
			t.Errorf("grid rows %v\nwant %v", got, want)
		}
		if first, err := m.TermRows(ctx, "pontos", res.Terms, false, 2); err != nil || len(first.Rows) != 2 || !first.More {
			t.Errorf("limited grid: %d rows, more %v (%v)", len(first.Rows), first.More, err)
		}
		// a column of the table called Term keeps its name and values
		if same, err := m.TermRows(ctx, "termos", res.Terms, false, 0); err != nil || !reflect.DeepEqual(same.Columns, []string{"Term", "x"}) || len(same.Rows) != 1 {
			t.Errorf("table with a Term column: %v (%v)", same, err)
		}

		// the report: Excel
		dir := t.TempDir()
		xlsx := filepath.Join(dir, "t.xlsx")
		if err := m.ExportTerms(ctx, res, false, "xlsx", xlsx, noProgress); err != nil {
			t.Fatal(err)
		}
		f, err := excelize.OpenFile(xlsx)
		if err != nil {
			t.Fatal(err)
		}
		defer f.Close()
		// standard 19d: one sheet per table found, no result sheet; the columns of the table, numbers as numbers
		if want := []string{"outra", "pontos", "termos"}; !reflect.DeepEqual(f.GetSheetList(), want) {
			t.Errorf("sheets %v", f.GetSheetList())
		}
		if sheet, _ := f.GetRows("pontos"); len(sheet) != 6 || !reflect.DeepEqual(sheet[0], []string{"id", "nome", "sub", "num", "valor"}) {
			t.Errorf("pontos sheet %v", sheet)
		}
		for _, cell := range []string{"A2", "D2", "E2"} { // id, num, valor
			if !numericCell(f, "pontos", cell) {
				t.Errorf("pontos %s is not a number", cell)
			}
		}
		// CSV: a folder, one file per sheet
		csvDir := filepath.Join(dir, "csv")
		os.Mkdir(csvDir, 0o755)
		if err := m.ExportTerms(ctx, res, false, "csv", csvDir, noProgress); err != nil {
			t.Fatal(err)
		}
		var files []string
		entries, _ := os.ReadDir(csvDir)
		for _, e := range entries {
			files = append(files, e.Name())
		}
		sort.Strings(files)
		if want := []string{"outra.csv", "pontos.csv", "termos.csv"}; !reflect.DeepEqual(files, want) || !reflect.DeepEqual(CSVNames(TermsSheets(res)), want) {
			t.Errorf("csv files %v", files)
		}
		if data, _ := os.ReadFile(filepath.Join(csvDir, "termos.csv")); string(data) != "\xEF\xBB\xBFTerm,x\r\ngerador a,1\r\n" {
			t.Errorf("termos.csv %q", data)
		}
		// SQLite and DuckDB: the same sheets as tables
		for _, format := range []string{"duckdb", "sqlite"} {
			if format == "sqlite" && !hasAsset(sqliteExtensionAsset) {
				continue
			}
			out := filepath.Join(dir, "t."+format)
			if err := m.ExportTerms(ctx, res, false, format, out, noProgress); err != nil {
				t.Fatalf("%s: %v", format, err)
			}
			back := NewDBManager()
			if err := back.Connect(out); err != nil {
				t.Fatalf("%s: %v", format, err)
			}
			tables, _ := back.ListTables()
			sort.Strings(tables)
			if want := []string{"outra", "pontos", "termos"}; !reflect.DeepEqual(tables, want) {
				t.Errorf("%s tables %v", format, tables)
			}
			if n, _ := back.GetRowCount("pontos", ""); n != 5 {
				t.Errorf("%s: pontos has %d rows", format, n)
			}
			if schema, _ := back.GetTableSchema("pontos"); len(schema) != 5 || schema[0].Name != "id" || !strings.Contains(schema[0].Type, "INT") {
				t.Errorf("%s: pontos columns %+v", format, schema)
			}
			back.Close()
		}
	})
}

// section 4: the schema of a table and of the database, every table to a folder of CSV files (all or nothing) and the
// "All tables" search to Excel
func TestSchemaFolderAndSearchExports(t *testing.T) {
	defer i18n.SetLang(i18n.Lang())
	if got, want := CSVNames([]string{"a/b", "A_B", "CON", "x.", `q:"*?<>|\`}), []string{"a_b.csv", "A_B (2).csv", "_CON.csv", "x.csv", "q" + strings.Repeat("_", 8) + ".csv"}; !reflect.DeepEqual(got, want) {
		t.Errorf("CSVNames %q, want %q", got, want)
	}
	eachFeatureDB(t, func(t *testing.T, m *DBManager, source string) {
		ctx := context.Background()
		dir := t.TempDir()
		read := func(name string) string {
			data, err := os.ReadFile(filepath.Join(dir, name))
			if err != nil {
				t.Fatal(err)
			}
			return strings.TrimPrefix(string(data), "\xEF\xBB\xBF")
		}
		i18n.SetLang("pt-BR")
		if err := m.ExportSchema(ctx, "outra", "csv", filepath.Join(dir, "outra_schema.csv"), noProgress); err != nil {
			t.Fatal(err)
		}
		if got, want := read("outra_schema.csv"), "Coluna,Tipo,Aceita nulo\r\ncodigo,VARCHAR,Sim\r\nobs,VARCHAR,Sim\r\n"; got != want {
			t.Errorf("table schema %q, want %q", got, want)
		}
		i18n.SetLang("en")
		if err := m.ExportSchema(ctx, "", "csv", filepath.Join(dir, "db_schema.csv"), noProgress); err != nil {
			t.Fatal(err)
		}
		all := read("db_schema.csv")
		if !strings.HasPrefix(all, "Table,Column,Type,Nullable\r\ndupla,k,VARCHAR,Yes\r\n") || !strings.Contains(all, "\r\npontos,id,") || strings.Count(all, "\r\n") != 13 {
			t.Errorf("database schema %q", all)
		}
		if err := m.ExportSchema(ctx, "nope", "csv", filepath.Join(dir, "x.csv"), noProgress); err == nil {
			t.Error("schema of an unknown table must fail")
		}
		xlsx := filepath.Join(dir, "db_schema.xlsx")
		if err := m.ExportSchema(ctx, "", "xlsx", xlsx, noProgress); err != nil {
			t.Fatal(err)
		}
		if f, err := excelize.OpenFile(xlsx); err != nil || f.GetSheetList()[0] != "Schema" {
			t.Errorf("schema workbook: %v", err)
		} else {
			f.Close()
		}

		// every table to CSV: a cancelled export changes nothing in the folder
		folder := filepath.Join(dir, "all")
		os.Mkdir(folder, 0o755)
		os.WriteFile(filepath.Join(folder, "pontos.csv"), []byte("old"), 0o644)
		cancelled, cancel := context.WithCancel(ctx)
		cancel()
		if err := m.ExportTablesCSV(cancelled, folder, noProgress); err == nil || err.Error() != i18n.T("err.exportCancelled") {
			t.Errorf("cancelled folder export: %v", err)
		}
		if entries, _ := os.ReadDir(folder); len(entries) != 1 {
			t.Errorf("cancelled export left %d entries", len(entries))
		}
		if data, _ := os.ReadFile(filepath.Join(folder, "pontos.csv")); string(data) != "old" {
			t.Errorf("cancelled export changed pontos.csv: %q", data)
		}
		if err := m.ExportTablesCSV(ctx, folder, noProgress); err != nil {
			t.Fatal(err)
		}
		var names []string
		entries, _ := os.ReadDir(folder)
		for _, e := range entries {
			names = append(names, e.Name())
		}
		if want := []string{"dupla.csv", "outra.csv", "pontos.csv", "termos.csv", "vazia.csv"}; !reflect.DeepEqual(names, want) {
			t.Errorf("folder %v", names)
		}
		if data, _ := os.ReadFile(filepath.Join(folder, "outra.csv")); string(data) != "\xEF\xBB\xBFcodigo,obs\r\n238,turbina b fora\r\nx,\r\n" {
			t.Errorf("outra.csv %q", data)
		}

		// the "All tables" search to Excel: one sheet per table of the list, the rows the search finds
		found := filepath.Join(dir, "busca.xlsx")
		if err := m.ExportSearch(ctx, "turbina", []string{"outra", "pontos"}, found, noProgress); err != nil {
			t.Fatal(err)
		}
		f, err := excelize.OpenFile(found)
		if err != nil {
			t.Fatal(err)
		}
		defer f.Close()
		if !reflect.DeepEqual(f.GetSheetList(), []string{"outra", "pontos"}) {
			t.Errorf("search sheets %v", f.GetSheetList())
		}
		if rows, _ := f.GetRows("pontos"); len(rows) != 3 || rows[1][1] != "Turbina B" || rows[2][1] != "Turbina C" {
			t.Errorf("pontos sheet %v", rows)
		}
		if rows, _ := f.GetRows("outra"); len(rows) != 2 {
			t.Errorf("outra sheet %v", rows)
		}
		if err := m.ExportSearch(ctx, "turbina", []string{"nope"}, found, noProgress); err == nil {
			t.Error("search export of an unknown table must fail")
		}
		if err := m.ExportSearch(ctx, "turbina", nil, found, noProgress); err == nil {
			t.Error("search export without tables must fail")
		}
	})
	if q := valuesQuery([]string{"a", "b"}, nil); q != `SELECT CAST(NULL AS VARCHAR) AS "a", CAST(NULL AS VARCHAR) AS "b" WHERE false` {
		t.Errorf("empty valuesQuery: %s", q)
	}
}

// review 26/11 (P1): the marked rows of a big table come in table order, by rowid and by values (a view has no
// rowid), whatever the order of marking, also in their export
func TestMarkedRowsOfABigTableInTableOrder(t *testing.T) {
	path := filepath.Join(t.TempDir(), "big.duckdb")
	db, err := sql.Open("duckdb", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE big AS SELECT i, i % 7 AS k FROM range(500000) t(i); CREATE VIEW bigv AS SELECT * FROM big`)
	db.Close()
	if err != nil {
		t.Fatal(err)
	}
	m := NewDBManager()
	if err := m.Connect(path); err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	want := []any{int64(5), int64(250000), int64(499990)}
	rows, err := m.MarkedRows("big", []map[string]any{{RowIDKey: float64(499990)}, {RowIDKey: float64(5)}, {RowIDKey: float64(250000)}})
	if err != nil || !reflect.DeepEqual(ids(rows, "i"), want) {
		t.Errorf("by rowid: %v (%v)", ids(rows, "i"), err)
	}
	byValues := []map[string]any{{"i": float64(499990), "k": float64(499990 % 7)}, {"i": float64(5), "k": float64(5)}, {"i": float64(250000), "k": float64(250000 % 7)}}
	rows, err = m.MarkedRows("bigv", byValues)
	if err != nil || !reflect.DeepEqual(ids(rows, "i"), want) {
		t.Errorf("by values: %v (%v)", ids(rows, "i"), err)
	}
	out := filepath.Join(t.TempDir(), "m.csv")
	if err := m.ExportMarked(context.Background(), "bigv", byValues, "csv", out, noProgress); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(out); string(data) != "\xEF\xBB\xBFi,k\r\n5,5\r\n250000,"+strconv.Itoa(250000%7)+"\r\n499990,"+strconv.Itoa(499990%7)+"\r\n" {
		t.Errorf("export %q", data)
	}
}

// standard 19d (owner 26/11): the grid of the Advanced Search has the columns of the table, with their own titles, in
// every language: no Term column added, no title changed (it had "Term", then "Term (2)" for a table column Term)
func TestTermColumnNameOfTheTable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "t.duckdb")
	db, err := sql.Open("duckdb", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE t ("Term" VARCHAR, "Termo" VARCHAR, "Término" VARCHAR, x VARCHAR); INSERT INTO t VALUES ('en', 'pt', 'es', 'abc')`)
	db.Close()
	if err != nil {
		t.Fatal(err)
	}
	m := NewDBManager()
	if err := m.Connect(path); err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	defer i18n.SetLang("en")
	for _, lang := range []string{"en", "pt-BR", "es"} {
		i18n.SetLang(lang)
		res, err := m.TermRows(context.Background(), "t", []string{"abc"}, false, 0)
		if err != nil || len(res.Rows) != 1 || !reflect.DeepEqual(res.Columns, []string{"Term", "Termo", "Término", "x"}) {
			t.Fatalf("%s: %v (%v)", lang, res, err)
		}
		if r := res.Rows[0]; r["Term"] != "en" || r["Termo"] != "pt" || r["Término"] != "es" || r["x"] != "abc" {
			t.Errorf("%s: row %v", lang, r)
		}
	}
}

// owner 26/11 (13h): pages of the Data tab: a table of more than 1000 rows read page by page in table order, the last
// page short; the search holds on every page; a view (no rowid) pages too
func TestQueryTablePages(t *testing.T) {
	path := filepath.Join(t.TempDir(), "p.duckdb")
	db, err := sql.Open("duckdb", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE p AS SELECT i, CASE WHEN i % 10 = 0 THEN 'ten' ELSE 'x' END AS s FROM range(1050) t(i); CREATE VIEW pv AS SELECT * FROM p`)
	db.Close()
	if err != nil {
		t.Fatal(err)
	}
	m := NewDBManager()
	if err := m.Connect(path); err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	for _, table := range []string{"p", "pv"} {
		var got []any
		for offset := 0; offset < 1050; offset += 500 {
			rows, err := m.QueryTablePage(table, 500, offset, "")
			if err != nil {
				t.Fatal(err)
			}
			got = append(got, ids(rows, "i")...)
		}
		if len(got) != 1050 || got[0] != int64(0) || got[500] != int64(500) || got[1049] != int64(1049) {
			t.Errorf("%s: %d rows, %v %v %v", table, len(got), got[0], got[500], got[len(got)-1])
		}
		last, err := m.QueryTablePage(table, 500, 1000, "")
		if err != nil || len(last) != 50 {
			t.Errorf("%s: last page %d rows (%v)", table, len(last), err)
		}
		found, err := m.QueryTablePage(table, 50, 50, "ten")
		if got := ids(found, "i"); err != nil || len(got) != 50 || got[0] != int64(500) {
			t.Errorf("%s: second page of the search: %v (%v)", table, got, err)
		}
	}
}

// standard 19d (owner 26/11, replaces 13i): the Advanced Search report has only one sheet per table found, named as
// the table, in any language; nothing found: nothing to export
func TestTermsReportResultSheet(t *testing.T) {
	defer i18n.SetLang("en")
	for _, lang := range []string{"en", "pt-BR", "es"} {
		i18n.SetLang(lang)
		if got := TermsSheets(TermsResult{Tables: []TableHits{{"RANGER_SOSTAT", 8}, {"RANGER_SOEQID", 8}}}); !reflect.DeepEqual(got, []string{"RANGER_SOSTAT", "RANGER_SOEQID"}) {
			t.Errorf("%s: sheets %q", lang, got)
		}
	}
	m := NewDBManager()
	if err := m.Connect(featureDBs(t)[SourceDuckDB]); err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	i18n.SetLang("en")
	err := m.ExportTerms(context.Background(), TermsResult{Terms: []string{"zzz"}}, false, "xlsx", filepath.Join(t.TempDir(), "n.xlsx"), noProgress)
	if err == nil || err.Error() != "No row found to export." {
		t.Errorf("empty report: %v", err)
	}
}

// owner 26/11 (13a): in Whole value a term and a cell that read as numbers meet when any reading of one equals any
// reading of the other (the readings of the Python): "216" finds 216.0, "216,0" and 216 but not 2160 nor 216.5;
// "0,1" and "0.1" find 0.10 and "0,1"; "1" does not find "0,1"; "1234.5" finds "1.234,5"; "1.234" finds "1,234"
// (both read 1.234 or 1234); "1234,567" is 1234.567 only (no thousands mark after 4 digits); text that is no number
// compares as text; a row met twice by one term (its text and its number) is one row
func TestTermsFindNumbersLoosely(t *testing.T) {
	path := filepath.Join(t.TempDir(), "n.duckdb")
	db, err := sql.Open("duckdb", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE n (d DOUBLE, m DECIMAL(10,2), i INTEGER, s VARCHAR);
		INSERT INTO n VALUES (216.0, 0.10, 7, '216,0'), (5.5, 1234.50, 2160, 'abc'), (216.5, 3.00, 216, '1.234,5'), (1.0, 2.00, 9, '1,234'), (NULL, NULL, 11, '0,1'), (NULL, NULL, 12, '1234,567'); CREATE VIEW nv AS SELECT * FROM n`)
	db.Close()
	if err != nil {
		t.Fatal(err)
	}
	m := NewDBManager()
	if err := m.Connect(path); err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	ctx := context.Background()
	lines := []string{"216", "216,0", "0,1", "0.1", "1234.5", "1.234", "216.5", "abc", "2160", "1", "1234567", "999"}
	res, err := m.SearchTerms(ctx, lines, false, "n", noProgress)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"216/n/ii", "216,0/n/ii", "0,1/n/ii", "0.1/n/ii", "1234.5/n/ii", "1.234/n/i", "216.5/n/i", "abc/n/i", "2160/n/i", "1/n/i"}
	if !reflect.DeepEqual(hitsOf(res), want) || !reflect.DeepEqual(res.NotFound, []string{"1234567", "999"}) {
		t.Errorf("hits %v, not found %q\nwant %v", hitsOf(res), res.NotFound, want)
	}
	grid, err := m.TermRows(ctx, "n", res.Terms, false, 0)
	if err != nil {
		t.Fatal(err)
	}
	// each row once (standard 19d), in the order of the first term that finds it: 216 (i 7, 216), 0,1 (11),
	// 1234.5 (2160), 1.234 (9)
	var got []string
	for _, r := range grid.Rows {
		got = append(got, cellString(r["i"]))
	}
	wantGrid := []string{"7", "216", "11", "2160", "9"}
	if !reflect.DeepEqual(got, wantGrid) {
		t.Errorf("grid rows %v\nwant %v", got, wantGrid)
	}
	// a view has no rowid: the rows are told apart by position, the same rows in the same order
	resView, err := m.SearchTerms(ctx, lines, false, "nv", noProgress)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.ReplaceAll(strings.Join(hitsOf(resView), " "), "/nv/", "/n/"); got != strings.Join(want, " ") {
		t.Errorf("view hits %s", got)
	}
	gridView, err := m.TermRows(ctx, "nv", res.Terms, false, 0)
	if err != nil {
		t.Fatal(err)
	}
	got = nil
	for _, r := range gridView.Rows {
		got = append(got, cellString(r["i"]))
	}
	if !reflect.DeepEqual(got, wantGrid) {
		t.Errorf("view grid rows %v", got)
	}
}

// numericCell: an Excel cell that holds a number (a date is one too): not a text type (excelize leaves a number's type
// unset or "n"), and its raw value parses as a number
func numericCell(f *excelize.File, sheet, cell string) bool {
	typ, _ := f.GetCellType(sheet, cell)
	raw, _ := f.GetCellValue(sheet, cell, excelize.Options{RawCellValue: true})
	_, err := strconv.ParseFloat(raw, 64)
	return (typ == excelize.CellTypeUnset || typ == excelize.CellTypeNumber) && err == nil
}

// standard 19c and 19g (owner 26/11): an Excel export has the columns and titles of the table, numbers as numeric
// cells, a date as a date, NULL empty; each column as wide as its longest text (title or cell), at most 60
func TestExcelKeepsTypesAndFitsColumns(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.duckdb")
	db, err := sql.Open("duckdb", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE x (RTUNO BIGINT, "Nome do ponto" VARCHAR, quando TIMESTAMP, valor DECIMAL(10,2), vazio VARCHAR, memo VARCHAR);
		INSERT INTO x VALUES (50, 'GENERADOR CGS VIBRACION ANORMAL 1 CANAL 1', '2024-01-02 03:04:05', 12.5, NULL, repeat('m', 200))`)
	db.Close()
	if err != nil {
		t.Fatal(err)
	}
	m := NewDBManager()
	if err := m.Connect(path); err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	out := filepath.Join(t.TempDir(), "x.xlsx")
	if err := m.ExportTable(context.Background(), "x", "xlsx", out, noProgress, ""); err != nil {
		t.Fatal(err)
	}
	f, err := excelize.OpenFile(out)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	rows, _ := f.GetRows("x")
	if len(rows) != 2 || !reflect.DeepEqual(rows[0], []string{"RTUNO", "Nome do ponto", "quando", "valor", "vazio", "memo"}) {
		t.Fatalf("rows %v", rows)
	}
	for _, cell := range []string{"A2", "C2", "D2"} {
		if !numericCell(f, "x", cell) {
			t.Errorf("%s is not a number", cell)
		}
	}
	if typ, _ := f.GetCellType("x", "B2"); typ != excelize.CellTypeSharedString && typ != excelize.CellTypeInlineString {
		t.Errorf("B2: cell type %v, want text", typ)
	}
	if v, _ := f.GetCellValue("x", "E2"); v != "" {
		t.Errorf("NULL shows %q", v)
	}
	if v, _ := f.GetCellValue("x", "C2"); !strings.Contains(v, "1/2/24") { // Excel date format m/d/yy h:mm
		t.Errorf("date cell shows %q", v)
	}
	for col, want := range map[string]float64{"A": 8, "B": 43, "C": 21, "D": 8, "E": 8, "F": 60} {
		if got, _ := f.GetColWidth("x", col); got != want {
			t.Errorf("column %s width %v, want %v", col, got, want)
		}
	}
}
