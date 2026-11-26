package backend

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

// testdata/types.mdb (scripts/make_test_mdb.ps1): every Access type, a row of NULLs, accents, CRLF and binary
const typesMDB = "testdata/types.mdb"

// declared SQLite types of the converted Tipos table, in column order
var wantDecl = []string{"ID INTEGER", "Flag BOOLEAN", "B INTEGER", "S INTEGER", "L INTEGER", "Money DECIMAL(19,4)",
	"Dec DECIMAL(10,2)", "Sng REAL", "Dbl DOUBLE", "When DATETIME", "Txt TEXT", "Note TEXT", "Bin BLOB"}

// declTipos is the schema of Tipos in the open SQLite file, "name TYPE" per column (standard 20: the tests check the
// schema, the type of each column as in Access)
func declTipos(t *testing.T, m *DBManager) []string {
	t.Helper()
	var decl []string
	for _, r := range queryText(t, m, `SELECT * FROM sqlite_query('src', 'SELECT name, type FROM pragma_table_info(''Tipos'')')`) {
		decl = append(decl, r[0]+" "+r[1])
	}
	return decl
}

// numericTipos: the number columns of Tipos are numeric types when read (a declared DECIMAL reads as DOUBLE)
func numericTipos(t *testing.T, m *DBManager) {
	t.Helper()
	schema, _ := m.GetTableSchema("Tipos")
	for _, c := range schema {
		if strings.Contains("|B|S|L|Money|Dec|Sng|Dbl|", "|"+c.Name+"|") && !numericType(c.Type) {
			t.Errorf("column %s reads as %s, not a number", c.Name, c.Type)
		}
	}
}

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
			if decl := declTipos(t, m); !reflect.DeepEqual(decl, wantDecl) {
				t.Errorf("declared types\n got %q\nwant %q", decl, wantDecl)
			}
			numericTipos(t, m)
			// Save as DuckDB keeps DECIMAL and BOOLEAN (DuckDB reads them from SQLite as DOUBLE and BIGINT)
			duck := filepath.Join(t.TempDir(), "saved.duckdb")
			if err := m.ExportDatabase(context.Background(), "duckdb", duck, func(int, int, string) {}); err != nil {
				t.Fatal(err)
			}
			saved := NewDBManager()
			if err := saved.Connect(duck); err != nil {
				t.Fatal(err)
			}
			types := map[string]string{}
			schema, _ := saved.GetTableSchema("Tipos")
			for _, c := range schema {
				types[c.Name] = c.Type
			}
			saved.Close()
			if types["Money"] != "DECIMAL(19,4)" || types["Dec"] != "DECIMAL(10,2)" || types["Flag"] != "BOOLEAN" || types["Dbl"] != "DOUBLE" {
				t.Errorf("saved DuckDB types %v", types)
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
			// File > Save copies the converted file (never over itself) and the database stays open on it; Close leaves
			// it to the caller, who removes it with its folder
			dest := filepath.Join(t.TempDir(), "saved.sqlite")
			if err := m.SaveConverted(dest); err != nil {
				t.Fatal(err)
			}
			if err := m.SaveConverted(conv); err == nil {
				t.Error("saved over the temporary file itself")
			}
			if n, _ := m.GetRowCount("Tipos", ""); n != 3 {
				t.Errorf("after save: %d rows in the open database", n)
			}
			m.Close()
			if _, err := os.Stat(conv); err != nil {
				t.Fatalf("converted file gone after Close: %v", err)
			}
			if err := RemoveConverted(conv); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(filepath.Dir(conv)); !os.IsNotExist(err) {
				t.Errorf("temporary folder left: %v", err)
			}
			back := NewDBManager()
			defer back.Close()
			if err := back.Connect(dest); err != nil || back.Source() != SourceSQLite {
				t.Fatalf("saved file: %v %q", err, back.Source())
			}
			if n, _ := back.GetRowCount("Tipos", ""); n != 3 {
				t.Errorf("saved file: %d rows", n)
			}
			if decl := declTipos(t, back); !reflect.DeepEqual(decl, wantDecl) {
				t.Errorf("saved file declared types\n got %q\nwant %q", decl, wantDecl)
			}
			// Save as SQLite of the open file keeps the schema (standard 19h and 20)
			lite := filepath.Join(t.TempDir(), "again.sqlite")
			if err := back.ExportDatabase(context.Background(), "sqlite", lite, func(int, int, string) {}); err != nil {
				t.Fatal(err)
			}
			again := NewDBManager()
			defer again.Close()
			if err := again.Connect(lite); err != nil {
				t.Fatal(err)
			}
			if decl := declTipos(t, again); !reflect.DeepEqual(decl, wantDecl) {
				t.Errorf("Save as SQLite declared types\n got %q\nwant %q", decl, wantDecl)
			}
			numericTipos(t, again)
		})
	}
}

// standard item 29: the converted file goes to the first folder where a file can be created (the user's temporary
// folder, the system's, then the folder of the Access file); the leftovers of dead processes are removed from all of
// them, and a folder that ends up empty is removed too
func TestConvertedFolderFallsBackAndIsCleaned(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "file") // nothing can be created under a file
	os.WriteFile(file, nil, 0o644)
	bad := filepath.Join(file, convertedDir)
	second := filepath.Join(dir, "system", convertedDir)
	third := filepath.Join(dir, "source", convertedDir)
	mine, err := newConvertedIn([]string{bad, second, third}, filepath.Join(dir, "source", "x.accdb"))
	if err != nil {
		t.Fatal(err)
	}
	pidDir := filepath.Dir(filepath.Dir(mine))
	if filepath.Base(mine) != "x.sqlite" || filepath.Base(pidDir) != strconv.Itoa(os.Getpid()) || filepath.Dir(pidDir) != second {
		t.Errorf("converted file %s, want <%s>/<pid>/<random>/x.sqlite", mine, second)
	}
	if _, err := os.Stat(mine); !os.IsNotExist(err) {
		t.Errorf("the path must not exist yet: %v", err)
	}
	if got, err := newConvertedIn([]string{bad}, "x.accdb"); err == nil {
		t.Errorf("no folder to write to must fail, got %s", got)
	}
	roots := ConvertedRoots(filepath.Join(dir, "source", "x.accdb"))
	if len(roots) != 3 || roots[0] != filepath.Join(os.TempDir(), convertedDir) || roots[2] != third || len(ConvertedRoots("")) != 2 {
		t.Errorf("roots %q", roots)
	}

	os.WriteFile(mine, []byte("x"), 0o644)
	dead := filepath.Join(third, "2147483646") // no such process
	os.MkdirAll(filepath.Join(dead, "a"), 0o755)
	os.WriteFile(filepath.Join(dead, "a", "old.sqlite"), []byte("x"), 0o644)
	notPid := filepath.Join(second, "notes")
	os.MkdirAll(notPid, 0o755)
	if n := CleanStaleConverted(bad, second, third); n != 1 {
		t.Errorf("removed %d folders, want 1", n)
	}
	for path, want := range map[string]bool{mine: true, third: false, notPid: true} {
		if _, err := os.Stat(path); (err == nil) != want {
			t.Errorf("%s exists=%v, want %v", path, err == nil, want)
		}
	}
	// the converted file leaves with its folders: nothing stays in the temporary folder nor beside an Access file
	os.Remove(notPid)
	if err := RemoveConverted(mine); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(second); !os.IsNotExist(err) {
		t.Errorf("empty folder %s left: %v", second, err)
	}
}

// standard 19a (owner 26/11): Access Numeric(p,0) (RTUNO, PNTNO...) goes to SQLite as INTEGER, which DuckDB reads back
// as an integer; a declared DECIMAL came back as DOUBLE. Up to 18 digits; a fraction keeps its DECIMAL
func TestSQLiteColumnKeepsWholeNumbersInteger(t *testing.T) {
	for duck, want := range map[string]string{
		"DECIMAL(10,0)": "INTEGER", "DECIMAL(18,0)": "INTEGER", "DECIMAL(28,0)": "DECIMAL(28,0)",
		"DECIMAL(19,4)": "DECIMAL(19,4)", "DECIMAL(10,2)": "DECIMAL(10,2)", "INTEGER": "INTEGER", "DOUBLE": "DOUBLE",
		"VARCHAR": "TEXT", "TIMESTAMP": "DATETIME",
	} {
		if got, _ := sqliteColumn("c", duck); got != want {
			t.Errorf("sqliteColumn(%s) = %s, want %s", duck, got, want)
		}
	}
}
