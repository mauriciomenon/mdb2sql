package backend

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/xuri/excelize/v2"
)

// Conferencia com os bancos reais do NMR5 (COPIAS em MDB2SQL_TEST_DB_DIR): "<base>.accdb" e as referencias
// "<base>.sqlite" e "<base>.duckdb" do conversor de referencia (mesmo .accdb). Lenta, so roda com a variavel.
// !T: go test ./backend -run RealDB -v -timeout 30m   with MDB2SQL_TEST_DB_DIR set
const (
	realTables     = 287
	realBigTable   = "RANGER_SOSTAT"
	realBigCount   = 36754
	realDBBaseName = "2026-07-14 DB4"
)

// the .accdb files compared with their references (DB4 and "DB3 1")
var realBases = []string{realDBBaseName, "2026-06-25 DB3 1"}

func realDBDir(t *testing.T) string {
	dir := os.Getenv("MDB2SQL_TEST_DB_DIR")
	if dir == "" {
		t.Skip("MDB2SQL_TEST_DB_DIR not set")
	}
	return dir
}

func rowCounts(t *testing.T, m *DBManager) map[string]int {
	t.Helper()
	tables, err := m.ListTables()
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]int{}
	for _, tb := range tables {
		n, err := m.GetRowCount(tb, "")
		if err != nil {
			t.Fatal(err)
		}
		out[tb] = n
	}
	return out
}

type realCase struct{ ext, reader, source string }

// every Access reader (converted to SQLite) must match the reference files: table list and rows of every table,
// plus a fingerprint of the big table (accents, sums)
func TestRealDB_OpenAllFormats(t *testing.T) {
	dir := realDBDir(t)
	for _, base := range realBases {
		if _, err := os.Stat(filepath.Join(dir, base+".accdb")); err != nil {
			t.Logf("%s.accdb not in %s: skipped", base, dir)
			continue
		}
		cases := []realCase{{".duckdb", "", SourceDuckDB}, {".sqlite", "", SourceSQLite}, {".accdb", "mdbtools", SourceMdbtools}}
		if odbcInstalled() {
			cases = append(cases, realCase{".accdb", "odbc", SourceODBC})
		}
		var ref map[string]int
		refPrint := ""
		for _, c := range cases {
			t.Run(base+" "+c.source, func(t *testing.T) {
				t.Setenv("MDB2SQL_ACCESS_READER", c.reader)
				m := NewDBManager()
				defer m.Close()
				start := time.Now()
				if err := m.Connect(filepath.Join(dir, base+c.ext)); err != nil {
					t.Fatal(err)
				}
				t.Logf("opened in %s", time.Since(start).Round(time.Millisecond))
				if conv := m.Converted(); conv != "" {
					defer RemoveConverted(conv)
				}
				if m.Source() != c.source {
					t.Fatalf("source %q, want %q", m.Source(), c.source)
				}
				counts := rowCounts(t, m)
				total := 0
				for _, n := range counts {
					total += n
				}
				t.Logf("%d tables, %d rows", len(counts), total)
				if ref == nil {
					ref = counts
				} else {
					if len(counts) != len(ref) {
						t.Errorf("%d tables, reference %d", len(counts), len(ref))
					}
					for tb, n := range ref {
						if got, ok := counts[tb]; !ok || got != n {
							t.Errorf("%s: %d rows (present %v), reference %d", tb, got, ok, n)
						}
					}
				}
				res, err := m.RunQuery(context.Background(),
					`SELECT count(DISTINCT RTUNO) AS rtus, sum(PNTNO) AS s, max(PNTNAM) AS n,
					        count(*) FILTER (WHERE PNTNAM LIKE '%Í%') AS accents FROM RANGER_SOSTAT`, 10)
				if err != nil {
					t.Fatal(err)
				}
				got := fmt.Sprint(res.Rows[0])
				if refPrint == "" {
					refPrint = got
				} else if got != refPrint {
					t.Errorf("fingerprint %s, reference %s", got, refPrint)
				}
				t.Logf("fingerprint %s", got)
				if base != realDBBaseName {
					return
				}
				if len(counts) != realTables || counts[realBigTable] != realBigCount {
					t.Fatalf("%d tables, %s %d rows", len(counts), realBigTable, counts[realBigTable])
				}
				cols, err := m.GetTableSchema(realBigTable)
				if err != nil || len(cols) < 100 {
					t.Fatalf("schema: %d columns %v", len(cols), err)
				}
				if rows, err := m.QueryTable(realBigTable, 1000, ""); err != nil || len(rows) != 1000 {
					t.Fatalf("data: %d rows %v", len(rows), err)
				}
				checkRealSearch(t, m)
				if c.ext == ".accdb" {
					// the converted data must also go to xlsx
					out := filepath.Join(t.TempDir(), "a.xlsx")
					if err := m.ExportDatabase(context.Background(), "xlsx", out, func(int, int, string) {}); err != nil {
						t.Fatalf("export xlsx: %v", err)
					}
				}
			})
		}
	}
}

// the Data search runs in the database over the whole table: a point past the first 100 rows is found, by words
// in any order, ignoring case and accents; no fuzzy match (Portuguese "tensao" does not find Spanish "TENSION")
func checkRealSearch(t *testing.T, m *DBManager) {
	t.Helper()
	// a point name far past the first 100 rows of RANGER_SOSTAT (the grid loads 100 by default) and not among them
	far, err := m.RunQuery(context.Background(), `SELECT PNTNAM FROM RANGER_SOSTAT WHERE PNTNAM IS NOT NULL AND PNTNAM NOT IN
		(SELECT PNTNAM FROM (SELECT PNTNAM FROM RANGER_SOSTAT LIMIT 100) WHERE PNTNAM IS NOT NULL) LIMIT 1 OFFSET 30000`, 1)
	if err != nil || len(far.Rows) != 1 {
		t.Fatalf("far point: %v %v", far.Rows, err)
	}
	name := fmt.Sprint(far.Rows[0]["PNTNAM"])
	got, err := m.QueryTable(realBigTable, 100, strings.ToLower(name))
	if err != nil || len(got) == 0 {
		t.Fatalf("search %q beyond the first 100 rows: %d rows %v", name, len(got), err)
	}
	t.Logf("RANGER_SOSTAT: %q (not in the first 100 rows) found by the search: %d row(s)", name, len(got))

	const table = "RANGER_SOANLG" // RTUNO 50, PNTNO 9: "EXCITACION TENSION DE CAMPO"
	is509 := func(r map[string]any) bool { return fmt.Sprint(r["RTUNO"]) == "50" && fmt.Sprint(r["PNTNO"]) == "9" }
	total, _ := m.GetRowCount(table, "")
	n, err := m.GetRowCount(table, "campo TENSIÓN de")
	if err != nil || n < 1 {
		t.Fatalf("search 'campo TENSIÓN de': %d rows %v", n, err)
	}
	rows, err := m.QueryTable(table, 100, "tension de campo")
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, r := range rows {
		found = found || is509(r)
	}
	if !found || len(rows) != min(n, 100) {
		t.Errorf("RTUNO 50 PNTNO 9 not found by 'tension de campo' (%d rows, count %d)", len(rows), n)
	}
	t.Logf("%s: %d rows; 'tension de campo' finds %d (RTUNO 50 PNTNO 9 among them)", table, total, n)
	// no fuzzy match: DB4 also has Portuguese names ("EXCITACAO TENSAO DE CAMPO"), so "tensao" finds only those
	pt, err := m.QueryTable(table, 100, "tensao de campo")
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range pt {
		if is509(r) || !strings.Contains(fmt.Sprint(r["PNTNAM"]), "TENSAO") {
			t.Errorf("'tensao de campo' found %v %v %q", r["RTUNO"], r["PNTNO"], r["PNTNAM"])
		}
	}
	t.Logf("'tensao de campo' finds %d rows, all with TENSAO in the name (not RTUNO 50 PNTNO 9)", len(pt))
}

func TestRealDB_ExportRoundTrip(t *testing.T) {
	dir := realDBDir(t)
	m := NewDBManager()
	defer m.Close()
	if err := m.Connect(filepath.Join(dir, realDBBaseName+".duckdb")); err != nil {
		t.Fatal(err)
	}
	want := rowCounts(t, m)
	tables, _ := m.ListTables()
	out := t.TempDir()
	if keep := os.Getenv("MDB2SQL_TEST_OUT_DIR"); keep != "" {
		out = keep // keep the exported files to check them with other tools (openpyxl)
	}
	noProgress := func(int, int, string) {}
	for _, format := range []string{"duckdb", "sqlite"} {
		path := filepath.Join(out, "db4."+format)
		if err := m.ExportDatabase(context.Background(), format, path, noProgress); err != nil {
			t.Fatalf("%s: %v", format, err)
		}
		back := NewDBManager()
		if err := back.Connect(path); err != nil {
			t.Fatal(err)
		}
		got, _ := back.ListTables()
		if len(got) != realTables {
			t.Fatalf("%s: %d tables", format, len(got))
		}
		for _, tb := range got {
			if n, err := back.GetRowCount(tb, ""); err != nil || n != want[tb] {
				t.Fatalf("%s %s: %d rows, want %d (%v)", format, tb, n, want[tb], err)
			}
		}
		back.Close()
	}

	xlsx := filepath.Join(out, "db4.xlsx")
	if err := m.ExportDatabase(context.Background(), "xlsx", xlsx, noProgress); err != nil {
		t.Fatal(err)
	}
	f, err := excelize.OpenFile(xlsx)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if n := len(f.GetSheetList()); n != realTables {
		t.Fatalf("xlsx: %d sheets", n)
	}
	for _, tb := range []string{realBigTable, "RANGER_SOAGC", tables[0]} {
		rows, err := f.GetRows(SheetName(tb, 1, map[string]bool{}))
		if err != nil || len(rows)-1 != want[tb] {
			t.Fatalf("xlsx %s: %d data rows, want %d (%v)", tb, len(rows)-1, want[tb], err)
		}
	}
}
