package backend

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/xuri/excelize/v2"
)

func TestSheetName(t *testing.T) {
	used := map[string]bool{}
	long := strings.Repeat("A", 40)
	cases := []struct {
		table string
		part  int
		want  string
	}{
		{"RANGER_SOSTAT", 1, "RANGER_SOSTAT"},
		{"RANGER_SOSTAT", 2, "RANGER_SOSTAT (2)"},
		{"a/b:c*d?e[f]g\\h", 1, "a_b_c_d_e_f_g_h"},
		{long, 1, long[:31]},
		{long, 2, long[:27] + " (2)"},
		{long + "x", 1, long[:29] + "~2"},       // same first 31 characters as the one above
		{"ranger_sostat", 1, "ranger_sostat~2"}, // Excel names ignore case
		{"'quoted'", 1, "quoted"},
		{"History", 1, "History_"},
		{"", 1, "Sheet"},
		{strings.Repeat("é", 35), 1, strings.Repeat("é", 31)},
	}
	for _, c := range cases {
		got := SheetName(c.table, c.part, used)
		if got != c.want {
			t.Errorf("SheetName(%q, %d) = %q, want %q", c.table, c.part, got, c.want)
		}
		if utf16Len(got) > 31 {
			t.Errorf("%q is longer than 31", got)
		}
	}
	// a cut must not end with an apostrophe
	if got := SheetName(strings.Repeat("b", 30)+"'c", 1, used); strings.HasSuffix(got, "'") {
		t.Errorf("name ends with apostrophe: %q", got)
	}
}

func TestChooseAccessReader(t *testing.T) {
	cases := []struct {
		force          string
		odbc, mdbtools bool
		want           string // "" = error
	}{
		{"", true, true, SourceODBC},
		{"", false, true, SourceMdbtools},
		{"auto", false, true, SourceMdbtools},
		{"", false, false, ""},
		{"mdbtools", true, true, SourceMdbtools},
		{"MDBTOOLS", true, false, ""},
		{"odbc", false, true, ""},
		{"odbc", true, false, SourceODBC},
		{"jet", true, true, ""},
	}
	for _, c := range cases {
		got, err := chooseAccessReader(c.force, c.odbc, c.mdbtools)
		if got != c.want || (c.want == "") != (err != nil) {
			t.Errorf("chooseAccessReader(%q, %v, %v) = %q, %v; want %q", c.force, c.odbc, c.mdbtools, got, err, c.want)
		}
	}
	// with nothing available the message must say what to install
	if _, err := chooseAccessReader("", false, false); !strings.Contains(err.Error(), "Access Database Engine") {
		t.Errorf("unhelpful message: %v", err)
	}
}

func TestParseAccessSchema(t *testing.T) {
	ddl := "-- header\r\n\r\nCREATE TABLE [T 1]\r\n (\r\n\t[ID]\t\t\tLong Integer, \r\n\t[V]\t\t\tNumeric (10, 2), \r\n" +
		"\t[NAME]\t\t\tText (8), \r\n\t[OK]\t\t\tBoolean, \r\n\t[AT]\t\t\tDateTime\r\n);\r\n\r\nCREATE TABLE [EMPTY]\r\n (\r\n\t[X]\t\t\tCurrency\r\n);\r\n"
	got := parseAccessSchema(ddl)
	want := map[string][]string{
		"T 1":   {"ID INTEGER", "V DECIMAL(10,2)", "NAME VARCHAR", "OK BOOLEAN", "AT TIMESTAMP"},
		"EMPTY": {"X DECIMAL(19,4)"},
	}
	if len(got) != len(want) {
		t.Fatalf("tables: %v", got)
	}
	for table, cols := range want {
		if len(got[table]) != len(cols) {
			t.Fatalf("%s: %v", table, got[table])
		}
		for i, c := range got[table] {
			if s := c.name + " " + accessToDuck(c.typ); s != cols[i] {
				t.Errorf("%s column %d: %q, want %q", table, i, s, cols[i])
			}
		}
	}
}

func TestFileKind(t *testing.T) {
	dir := t.TempDir()
	write := func(name, content string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	cases := map[string]string{
		write("a.db", "SQLite format 3\x00 rest of header"): "sqlite",
		write("b.db", "not sqlite at all, duckdb maybe"):    "duckdb",
		write("c.ACCDB", "x"):                               "access",
		write("d.mdb", "x"):                                 "access",
	}
	for path, want := range cases {
		if got := fileKind(path); got != want {
			t.Errorf("fileKind(%s) = %s, want %s", filepath.Base(path), got, want)
		}
	}
}

func TestUniqueNamesAndCellString(t *testing.T) {
	if got := strings.Join(uniqueNames([]string{"id", "x", "id", "id"}), ","); got != "id,x,id (2),id (3)" {
		t.Errorf("uniqueNames: %s", got)
	}
	cases := map[string]any{
		"1000000":             1000000.0,
		"0.1":                 0.1,
		"1e+20":               1e20,
		"2026-07-14":          time.Date(2026, 7, 14, 0, 0, 0, 0, time.UTC),
		"2026-07-14 10:20:30": time.Date(2026, 7, 14, 10, 20, 30, 0, time.UTC),
		"":                    nil,
		"0AFF":                []byte{0x0a, 0xff}, // not UTF-8 -> hex
		"abc":                 []byte("abc"),
	}
	for want, v := range cases {
		if got := cellString(v); got != want {
			t.Errorf("cellString(%v) = %q, want %q", v, got, want)
		}
	}
}

// every SQL result must reach the UI as JSON (Wails encodes it); MAP keys, NaN and UUID used to break or print bytes
func TestRunQueryResultsAreJSON(t *testing.T) {
	m := NewDBManager()
	if err := m.Connect(fixtureDB(t)); err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	res, err := m.RunQuery(context.Background(), `SELECT MAP {1: 'a'} AS m, 'nan'::DOUBLE AS d, 12.5::DECIMAL(5,2) AS dec,
		'0e7f1b43-9d2c-4f1a-8a50-6f3c3f0b1a2c'::UUID AS u, [1, 2] AS l, {'k': 1} AS s, '\xC3\xA9'::BLOB AS b,
		TIMESTAMP '2026-07-14 10:20:30' AS ts, 1 AS id, 2 AS id`, 10)
	if err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(res)
	if err != nil {
		t.Fatalf("not JSON: %v", err)
	}
	for _, want := range []string{`"d":"NaN"`, `"dec":12.5`, `"u":"0e7f1b43-9d2c-4f1a-8a50-6f3c3f0b1a2c"`, `"ts":"2026-07-14 10:20:30"`, `"id (2)":2`, `"b":"é"`} {
		if !strings.Contains(string(data), want) {
			t.Errorf("%s missing in %s", want, data)
		}
	}
}

// fixture: a DuckDB file with the types the readers produce, accents and NULLs
func fixtureDB(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "fixture.duckdb")
	db, err := sql.Open("duckdb", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	_, err = db.Exec(`CREATE TABLE "Pontos A" (id INTEGER, valor DECIMAL(10,2), x DOUBLE, nome VARCHAR, ok BOOLEAN, em TIMESTAMP);
		INSERT INTO "Pontos A" VALUES (1, 12.34, 0.5, 'LÍMITE "a", b', true, '2026-07-14 10:20:30'),
		                              (2, NULL, NULL, NULL, NULL, NULL), (3, -1, 1e6, '', false, '2026-01-02');
		CREATE TABLE seven AS SELECT range AS n FROM range(7);
		CREATE TABLE vazia (a INTEGER);`)
	if err != nil {
		t.Fatal(err)
	}
	return path
}

// standard item 6: the table list shows each table's row count (as Zig), in table list order; a cancel stops it
func TestTableCounts(t *testing.T) {
	m := NewDBManager()
	if err := m.Connect(fixtureDB(t)); err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	tables, _ := m.ListTables()
	counts, err := m.TableCounts(context.Background())
	if err != nil || len(counts) != len(tables) {
		t.Fatalf("counts %v for %v: %v", counts, tables, err)
	}
	want := map[string]int{"Pontos A": 3, "seven": 7, "vazia": 0}
	for i, table := range tables {
		if counts[i] != want[table] {
			t.Errorf("%s: %d rows, want %d", table, counts[i], want[table])
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := m.TableCounts(ctx); err == nil {
		t.Error("a cancelled count must fail")
	}
}

func TestExportXLSXSplitsSheets(t *testing.T) {
	old := MaxExcelDataRows
	MaxExcelDataRows = 3
	t.Cleanup(func() { MaxExcelDataRows = old })
	m := NewDBManager()
	if err := m.Connect(fixtureDB(t)); err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	out := filepath.Join(t.TempDir(), "all.xlsx")
	var steps []string
	err := m.ExportDatabase(context.Background(), "xlsx", out, func(done, total int, label string) {
		steps = append(steps, label)
	})
	if err != nil {
		t.Fatal(err)
	}
	f, err := excelize.OpenFile(out)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	want := map[string]int{"Pontos A": 3, "seven": 3, "seven (2)": 3, "seven (3)": 1, "vazia": 0}
	if got := f.GetSheetList(); len(got) != len(want) {
		t.Fatalf("sheets %v", got)
	}
	for sheet, n := range want {
		rows, err := f.GetRows(sheet)
		if err != nil || len(rows) != n+1 || rows[0][0] == "" {
			t.Errorf("sheet %q: %d rows (want header + %d) %v", sheet, len(rows), n, err)
		}
	}
	// the dimension must cover the data: openpyxl read-only (pandas) trusts it
	for sheet, want := range map[string]string{"Pontos A": "A1:F4", "seven": "A1:A4", "seven (3)": "A1:A2", "vazia": "A1:A1"} {
		if got, _ := f.GetSheetDimension(sheet); got != want {
			t.Errorf("dimension of %q = %q, want %q", sheet, got, want)
		}
	}
	// numbers stay numbers; text with accents survives
	if v, _ := f.GetCellValue("Pontos A", "B2"); v != "12.34" {
		t.Errorf("decimal cell %q", v)
	}
	if v, _ := f.GetCellValue("Pontos A", "D2"); v != `LÍMITE "a", b` {
		t.Errorf("text cell %q", v)
	}
	if typ, _ := f.GetCellType("Pontos A", "C2"); typ != excelize.CellTypeNumber && typ != excelize.CellTypeUnset {
		t.Errorf("double cell type %v", typ)
	}
	if len(steps) != 4 {
		t.Errorf("progress labels %v", steps)
	}
}

// audit item 2: the old temp name "<name>.partial.<ext>" deleted a user file with that name (and its .wal), and
// the target was removed before the rename. Now other files and the old target survive every outcome.
func TestExportKeepsOtherFilesAndOldTarget(t *testing.T) {
	src := fixtureDB(t)
	m := NewDBManager()
	if err := m.Connect(src); err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	dir := t.TempDir()
	noop := func(int, int, string) {}
	write := func(name, text string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	check := func(name, want string) {
		t.Helper()
		if data, err := os.ReadFile(filepath.Join(dir, name)); err != nil || string(data) != want {
			t.Errorf("%s: %q %v, want %q", name, data, err, want)
		}
	}
	out := filepath.Join(dir, "p.csv")
	write("p.csv", "old target")
	write("p.partial.csv", "user file")
	write("p.partial.csv.wal", "user wal")

	if err := m.ExportTable(context.Background(), "nope", "csv", out, noop); err == nil {
		t.Fatal("unknown table must fail")
	}
	check("p.csv", "old target") // failed export: old target intact
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := m.ExportTable(ctx, "Pontos A", "csv", out, noop); err == nil {
		t.Fatal("cancelled export must fail")
	}
	check("p.csv", "old target")
	if err := m.ExportTable(context.Background(), "Pontos A", "csv", out, noop); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(out); !strings.HasPrefix(string(data), "\xEF\xBB\xBFid,") {
		t.Errorf("target not replaced: %q", data)
	}
	check("p.partial.csv", "user file")
	check("p.partial.csv.wal", "user wal")
	if left, _ := filepath.Glob(filepath.Join(dir, ".mdb2sql-export-*")); len(left) != 0 {
		t.Errorf("temporary folder left behind: %v", left)
	}
}

func TestExportTableCSVAndDatabases(t *testing.T) {
	src := fixtureDB(t)
	m := NewDBManager()
	if err := m.Connect(src); err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	dir := t.TempDir()
	noop := func(int, int, string) {}

	csvPath := filepath.Join(dir, "p.csv")
	if err := m.ExportTable(context.Background(), "Pontos A", "csv", csvPath, noop); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(csvPath)
	want := "\xEF\xBB\xBFid,valor,x,nome,ok,em\r\n1,12.34,0.5,\"LÍMITE \"\"a\"\", b\",true,2026-07-14 10:20:30\r\n" +
		"2,,,,,\r\n3,-1,1000000,,false,2026-01-02\r\n"
	if string(data) != want {
		t.Errorf("csv:\n%q\nwant\n%q", data, want)
	}
	if err := m.ExportTable(context.Background(), "nope", "csv", csvPath, noop); err == nil {
		t.Error("unknown table must fail")
	}
	if err := m.ExportDatabase(context.Background(), "duckdb", src, noop); err == nil {
		t.Error("exporting over the open file must fail")
	}

	formats := []string{"duckdb"}
	if hasAsset(sqliteExtensionAsset) {
		formats = append(formats, "sqlite")
	}
	for _, format := range formats {
		out := filepath.Join(dir, "copy."+format)
		if err := m.ExportDatabase(context.Background(), format, out, noop); err != nil {
			t.Fatalf("%s: %v", format, err)
		}
		if left, _ := filepath.Glob(filepath.Join(dir, ".mdb2sql-export-*")); len(left) != 0 {
			t.Errorf("%s: temporary folder left behind: %v", format, left)
		}
		back := NewDBManager()
		if err := back.Connect(out); err != nil {
			t.Fatal(err)
		}
		tables, _ := back.ListTables()
		res, err := back.RunQuery(context.Background(), `SELECT nome FROM "Pontos A" WHERE id = 1`, 5)
		back.Close()
		if err != nil || len(tables) != 3 || res.Rows[0]["nome"] != `LÍMITE "a", b` {
			t.Errorf("%s: tables %v, rows %v, %v", format, tables, res.Rows, err)
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	out := filepath.Join(dir, "cancelled.xlsx")
	if err := m.ExportDatabase(ctx, "xlsx", out, noop); err == nil || !strings.Contains(err.Error(), "cancel") {
		t.Errorf("cancelled export: %v", err)
	}
	if entries, _ := filepath.Glob(filepath.Join(dir, "cancelled*")); len(entries) != 0 {
		t.Errorf("cancelled export left %v", entries)
	}
}
