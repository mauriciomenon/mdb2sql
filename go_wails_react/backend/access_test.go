package backend

import (
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"testing"
)

// testdata/types.mdb (scripts/make_test_mdb.ps1): every Access type, a row of NULLs, accents, CRLF and binary
const typesMDB = "testdata/types.mdb"

// declared SQLite types of the converted Tipos table, in column order
var wantDecl = []string{"ID INTEGER", "Flag BOOLEAN", "B INTEGER", "S INTEGER", "L INTEGER", "Money DECIMAL(19,4)",
	"Dec DECIMAL(10,2)", "Sng REAL", "Dbl DOUBLE", "When DATETIME", "Txt TEXT", "Note TEXT", "Bin BLOB"}

// rows of Tipos by ID as cellString text; NULL stays NULL
var wantRows = [][]string{
	{"1", "1", "200", "-5", "123456", "1234567.8901", "0.1", "0.1", "0.1", "2020-01-02 03:04:05", "Ação é ñ", "linha 1\r\nlinha 2", "AABB00"},
	{"2", "0", "NULL", "NULL", "NULL", "NULL", "NULL", "NULL", "NULL", "NULL", "NULL", "NULL", "NULL"},
	{"3", "0", "0", "0", "0", "0", "0", "0", "0", "1899-12-30", "NULL", "NULL", "01"},
}

func queryText(t *testing.T, m *DBManager, q string) [][]string {
	t.Helper()
	rows, err := m.conn.Query(q)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	cols, _ := rows.Columns()
	var out [][]string
	for rows.Next() {
		values, ptrs := scanTargets(len(cols))
		if err := rows.Scan(ptrs...); err != nil {
			t.Fatal(err)
		}
		line := make([]string, len(cols))
		for i, v := range values {
			if line[i] = cellString(v); v == nil {
				line[i] = "NULL"
			}
		}
		out = append(out, line)
	}
	return out
}

// Access is converted once to a typed SQLite file, read from there, with the same values from both readers
func TestAccessConvertsToSQLite(t *testing.T) {
	if !hasAsset(sqliteExtensionAsset) {
		t.Skip("no embedded sqlite extension: run a build first")
	}
	readers := map[string]string{}
	if mdbtoolsAvailable() {
		readers["mdbtools"] = SourceMdbtools
	}
	if odbcInstalled() {
		readers["odbc"] = SourceODBC
	}
	if len(readers) == 0 {
		t.Skip("no Access reader on this machine")
	}
	for force, source := range readers {
		t.Run(source, func(t *testing.T) {
			t.Setenv("MDB2SQL_ACCESS_READER", force)
			m := NewDBManager()
			if err := m.Connect(typesMDB); err != nil {
				t.Fatal(err)
			}
			conv := m.Converted()
			if m.Source() != source || filepath.Base(conv) != "types.sqlite" {
				t.Fatalf("source %q, converted %q", m.Source(), conv)
			}
			if tables, _ := m.ListTables(); !reflect.DeepEqual(tables, []string{"Cidades e Regiões", "Tipos"}) {
				t.Fatalf("tables %q", tables)
			}
			var decl []string
			for _, r := range queryText(t, m, `SELECT * FROM sqlite_query('src', 'SELECT name, type FROM pragma_table_info(''Tipos'')')`) {
				decl = append(decl, r[0]+" "+r[1])
			}
			if !reflect.DeepEqual(decl, wantDecl) {
				t.Errorf("declared types\n got %q\nwant %q", decl, wantDecl)
			}
			want := wantRows
			if source == SourceODBC {
				// row 3 has zero-length Txt and Note: ODBC sees ""; mdbtools 1.0.1 exports a zero-length text as NULL
				want = append([][]string{}, wantRows...)
				want[2] = append([]string{}, wantRows[2]...)
				want[2][10], want[2][11] = "", ""
			}
			if got := queryText(t, m, `SELECT * FROM "Tipos" ORDER BY "ID"`); !reflect.DeepEqual(got, want) {
				t.Errorf("rows\n got %q\nwant %q", got, want)
			}
			if got := queryText(t, m, `SELECT * FROM "Cidades e Regiões" ORDER BY 1 DESC`); !reflect.DeepEqual(got,
				[][]string{{"São Paulo", "11451245"}, {"Foz do Iguaçu", "NULL"}}) {
				t.Errorf("cities %q", got)
			}
			// Close leaves the converted file to the caller, who saves or deletes it
			m.Close()
			if _, err := os.Stat(conv); err != nil {
				t.Fatalf("converted file gone after Close: %v", err)
			}
			dest := filepath.Join(t.TempDir(), "saved.sqlite")
			if err := SaveConverted(conv, dest); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(filepath.Dir(conv)); !os.IsNotExist(err) {
				t.Errorf("temporary folder left after save: %v", err)
			}
			back := NewDBManager()
			defer back.Close()
			if err := back.Connect(dest); err != nil || back.Source() != SourceSQLite {
				t.Fatalf("saved file: %v %q", err, back.Source())
			}
			if n, _ := back.GetRowCount("Tipos", ""); n != 3 {
				t.Errorf("saved file: %d rows", n)
			}
		})
	}
}

func TestCleanStaleConvertedKeepsLiveProcesses(t *testing.T) {
	cache := t.TempDir()
	t.Setenv("LOCALAPPDATA", cache)  // os.UserCacheDir on Windows
	t.Setenv("XDG_CACHE_HOME", cache) // and on Linux
	root, _ := convertedRoot()
	mine, err := newConvertedPath("x.accdb")
	if err != nil {
		t.Fatal(err)
	}
	os.WriteFile(mine, []byte("x"), 0o644)
	dead := filepath.Join(root, "2147483646") // no such process
	os.MkdirAll(filepath.Join(dead, "a"), 0o755)
	os.WriteFile(filepath.Join(dead, "a", "old.sqlite"), []byte("x"), 0o644)
	notPid := filepath.Join(root, "notes")
	os.MkdirAll(notPid, 0o755)

	if n := CleanStaleConverted(); n != 1 {
		t.Errorf("removed %d folders, want 1", n)
	}
	for path, want := range map[string]bool{mine: true, dead: false, notPid: true} {
		if _, err := os.Stat(path); (err == nil) != want {
			t.Errorf("%s exists=%v, want %v", path, err == nil, want)
		}
	}
	if filepath.Base(filepath.Dir(filepath.Dir(mine))) != strconv.Itoa(os.Getpid()) {
		t.Errorf("converted file not under the process folder: %s", mine)
	}
	if got := UniquePath(filepath.Dir(mine), "x.sqlite"); filepath.Base(got) != "x (2).sqlite" {
		t.Errorf("UniquePath = %s", got)
	}
}
