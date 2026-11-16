package backend

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/xuri/excelize/v2"
)

// Conferencia com o banco real do NMR5 (copias em MDB2SQL_TEST_DB_DIR: "2026-07-14 DB4.accdb/.sqlite/.duckdb").
// Lenta (Access: ~1 min por leitor), por isso so roda com a variavel definida.
// !T: go test ./backend -run RealDB -v -timeout 30m   with MDB2SQL_TEST_DB_DIR set
const (
	realTables     = 287
	realBigTable   = "RANGER_SOSTAT"
	realBigCount   = 36754
	realDBBaseName = "2026-07-14 DB4"
)

func realDBDir(t *testing.T) string {
	dir := os.Getenv("MDB2SQL_TEST_DB_DIR")
	if dir == "" {
		t.Skip("MDB2SQL_TEST_DB_DIR not set")
	}
	return dir
}

func checkReal(t *testing.T, m *DBManager, wantSource string) {
	t.Helper()
	if m.Source() != wantSource {
		t.Fatalf("source %q, want %q", m.Source(), wantSource)
	}
	tables, err := m.ListTables()
	if err != nil || len(tables) != realTables {
		t.Fatalf("tables: %d %v", len(tables), err)
	}
	if n, err := m.GetRowCount(realBigTable); err != nil || n != realBigCount {
		t.Fatalf("%s: %d rows %v", realBigTable, n, err)
	}
}

func TestRealDB_OpenAllFormats(t *testing.T) {
	dir := realDBDir(t)
	cases := []struct{ ext, reader, source string }{
		{".duckdb", "", SourceDuckDB},
		{".sqlite", "", SourceSQLite},
		{".accdb", "odbc", SourceODBC},
		{".accdb", "mdbtools", SourceMdbtools},
	}
	refCounts := map[string]int{}
	refPrint := ""
	for _, c := range cases {
		t.Run(c.source, func(t *testing.T) {
			t.Setenv("MDB2SQL_ACCESS_READER", c.reader)
			m := NewDBManager()
			defer m.Close()
			if err := m.Connect(filepath.Join(dir, realDBBaseName+c.ext)); err != nil {
				t.Fatal(err)
			}
			checkReal(t, m, c.source)
			// all readers must agree with the DuckDB file (first case): every table count and a fingerprint of the big table
			tables, _ := m.ListTables()
			for _, tb := range tables {
				n, err := m.GetRowCount(tb)
				if err != nil {
					t.Fatal(err)
				}
				if c.source == SourceDuckDB {
					refCounts[tb] = n
				} else if refCounts[tb] != n {
					t.Errorf("%s: %d rows, DuckDB file has %d", tb, n, refCounts[tb])
				}
			}
			res, err := m.RunQuery(context.Background(),
				`SELECT count(DISTINCT RTUNO) AS rtus, sum(PNTNO) AS s, max(PNTNAM) AS n,
				        count(*) FILTER (WHERE PNTNAM LIKE '%Í%') AS accents FROM RANGER_SOSTAT`, 10)
			if err != nil {
				t.Fatal(err)
			}
			got := fmt.Sprint(res.Rows[0])
			if c.source == SourceDuckDB {
				refPrint = got
			} else if got != refPrint {
				t.Errorf("fingerprint %s, DuckDB file %s", got, refPrint)
			}
			t.Logf("%s: %s", c.source, got)
			cols, err := m.GetTableSchema(realBigTable)
			if err != nil || len(cols) < 100 {
				t.Fatalf("schema: %d columns %v", len(cols), err)
			}
			if rows, err := m.QueryTable(realBigTable, 1000); err != nil || len(rows) != 1000 {
				t.Fatalf("data: %d rows %v", len(rows), err)
			}
			if c.source != SourceODBC {
				return
			}
			// the Access types (DECIMAL, TIMESTAMP...) must also go to SQLite and xlsx
			out := t.TempDir()
			for _, format := range []string{"sqlite", "xlsx"} {
				if err := m.ExportDatabase(context.Background(), format, filepath.Join(out, "a."+format), func(int, int, string) {}); err != nil {
					t.Fatalf("export %s: %v", format, err)
				}
			}
			back := NewDBManager()
			defer back.Close()
			if err := back.Connect(filepath.Join(out, "a.sqlite")); err != nil {
				t.Fatal(err)
			}
			checkReal(t, back, SourceSQLite)
		})
	}
}

func TestRealDB_ExportRoundTrip(t *testing.T) {
	dir := realDBDir(t)
	m := NewDBManager()
	defer m.Close()
	if err := m.Connect(filepath.Join(dir, realDBBaseName+".duckdb")); err != nil {
		t.Fatal(err)
	}
	want := map[string]int{}
	tables, _ := m.ListTables()
	for _, tb := range tables {
		n, err := m.GetRowCount(tb)
		if err != nil {
			t.Fatal(err)
		}
		want[tb] = n
	}
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
			if n, err := back.GetRowCount(tb); err != nil || n != want[tb] {
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
