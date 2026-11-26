package backend

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"reflect"
	"sort"
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
		if want := []TableHits{{"outra", 1}, {"pontos", 6}, {"termos", 1}}; !reflect.DeepEqual(res.Tables, want) {
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

		// the grid of a table: the term first, then its columns; term order, then table order; row 3 is there twice
		grid, err := m.TermRows(ctx, "pontos", res.Terms, false, 0)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{"Term", "id", "nome", "sub", "num", "valor"}; !reflect.DeepEqual(grid.Columns, want) {
			t.Errorf("grid columns %v", grid.Columns)
		}
		var got []string
		for _, r := range grid.Rows {
			got = append(got, cellString(r["Term"])+":"+cellString(r["id"]))
		}
		if want := []string{"gerador a:1", "gerador a:2", "gerador a:3", "gerador a:5", "238:4", "turbina b:3"}; !reflect.DeepEqual(got, want) {
			t.Errorf("grid rows %v\nwant %v", got, want)
		}
		if first, err := m.TermRows(ctx, "pontos", res.Terms, false, 2); err != nil || len(first.Rows) != 2 || !first.More {
			t.Errorf("limited grid: %d rows, more %v (%v)", len(first.Rows), first.More, err)
		}
		// a column called as the term column keeps its values under another name
		if same, err := m.TermRows(ctx, "termos", res.Terms, false, 0); err != nil || !reflect.DeepEqual(same.Columns, []string{"Term", "Term (2)", "x"}) || len(same.Rows) != 1 {
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
		if want := []string{"Summary", "outra", "pontos", "termos", "Not found"}; !reflect.DeepEqual(f.GetSheetList(), want) {
			t.Errorf("sheets %v", f.GetSheetList())
		}
		summary, _ := f.GetRows("Summary")
		wantSummary := [][]string{{"Term", "Status", "Table", "Rows"}, {"gerador a", "Found", "pontos", "4"}, {"gerador a", "Found", "termos", "1"},
			{"238", "Found", "outra", "1"}, {"238", "Found", "pontos", "1"}, {"PNTNAM", "Not found", "", "0"}, {"turbina b", "Found", "pontos", "1"}}
		if !reflect.DeepEqual(summary, wantSummary) {
			t.Errorf("summary sheet %v\nwant %v", summary, wantSummary)
		}
		if nf, _ := f.GetRows("Not found"); !reflect.DeepEqual(nf, [][]string{{"Term"}, {"PNTNAM"}}) {
			t.Errorf("not found sheet %v", nf)
		}
		if sheet, _ := f.GetRows("pontos"); len(sheet) != 7 || !reflect.DeepEqual(sheet[0], []string{"Term", "id", "nome", "sub", "num", "valor"}) {
			t.Errorf("pontos sheet %v", sheet)
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
		if want := []string{"Not found.csv", "Summary.csv", "outra.csv", "pontos.csv", "termos.csv"}; !reflect.DeepEqual(files, want) || !reflect.DeepEqual(CSVNames(TermsSheets(res)), []string{"Summary.csv", "outra.csv", "pontos.csv", "termos.csv", "Not found.csv"}) {
			t.Errorf("csv files %v", files)
		}
		if data, _ := os.ReadFile(filepath.Join(csvDir, "Not found.csv")); string(data) != "\xEF\xBB\xBFTerm\r\nPNTNAM\r\n" {
			t.Errorf("Not found.csv %q", data)
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
			if want := []string{"Not found", "Summary", "outra", "pontos", "termos"}; !reflect.DeepEqual(tables, want) {
				t.Errorf("%s tables %v", format, tables)
			}
			if n, _ := back.GetRowCount("pontos", ""); n != 6 {
				t.Errorf("%s: pontos has %d rows", format, n)
			}
			if n, _ := back.GetRowCount("Summary", ""); n != 6 {
				t.Errorf("%s: Summary has %d rows", format, n)
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
