package backend

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/xuri/excelize/v2"

	"mdb2sql/i18n"
)

// Aceitacao da pesquisa de termos, das marcas e do SQL so leitura com o banco do dono (COPIAS: DB3.accdb e as conversoes
// DB3.sqlite e DB3.duckdb, mais termos_dono.txt, em MDB2SQL_TERMS_DIR). Lenta, so roda com a variavel.
// !T: go test ./backend -run TestRealDB_Terms -v -timeout 30m   with MDB2SQL_TERMS_DIR set
func TestRealDB_Terms(t *testing.T) {
	dir := os.Getenv("MDB2SQL_TERMS_DIR")
	if dir == "" {
		t.Skip("MDB2SQL_TERMS_DIR not set")
	}
	text, err := os.ReadFile(filepath.Join(dir, "termos_dono.txt"))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.ReplaceAll(string(text), "\r\n", "\n"), "\n")
	noProgress := func(int, int, string) {}
	for _, name := range []string{"DB3.accdb", "DB3.sqlite", "DB3.duckdb"} {
		t.Run(name, func(t *testing.T) {
			m := NewDBManager()
			start := time.Now()
			if err := m.Open(context.Background(), filepath.Join(dir, name), noProgress); err != nil {
				t.Fatal(err)
			}
			conv := m.Converted() // the temporary SQLite of the Access file, deleted at the end
			defer func() {
				m.Close()
				RemoveConverted(conv)
			}()
			t.Logf("%s: opened with %s in %s", name, m.Source(), time.Since(start).Round(100*time.Millisecond))
			if name == "DB3.accdb" { // standard 19a: the Access types (mdb-schema: 1681 whole, 5816 double, 2867 text)
				types := map[string]int{}
				rows, err := m.conn.Query("SELECT data_type, count(*) FROM duckdb_columns() WHERE database_name = 'src' GROUP BY 1")
				if err != nil {
					t.Fatal(err)
				}
				for rows.Next() {
					var typ string
					var n int
					rows.Scan(&typ, &n)
					types[typ] = n
				}
				rows.Close()
				t.Logf("DB3.accdb converted, column types: %v", types)
				if types["BIGINT"] != 1681 || types["DOUBLE"] != 5816 || types["VARCHAR"]+types["TIMESTAMP"] != 2867 {
					t.Errorf("converted types %v, want BIGINT 1681, DOUBLE 5816, VARCHAR+TIMESTAMP 2867", types)
				}
				schema, _ := m.tableSchema(realBigTable)
				for i, want := range []string{"RTUNO", "PNTNO"} {
					if len(schema) <= i || schema[i].Name != want || schema[i].Type != "BIGINT" {
						t.Errorf("%s column %d: %+v, want %s BIGINT", realBigTable, i, schema[min(i, len(schema)-1)], want)
					}
				}
			}

			// identity of a marked row (standard item 31): the engine's rowid, or all the values
			rowID, err := m.hasRowID(realBigTable)
			if err != nil {
				t.Fatal(err)
			}
			t.Logf("%s: marked rows of %s told apart by %s", name, realBigTable, map[bool]string{true: "rowid", false: "all the values"}[rowID])

			for _, contains := range []bool{false, true} {
				start := time.Now()
				res, err := m.SearchTerms(context.Background(), lines, contains, "", noProgress)
				if err != nil {
					t.Fatal(err)
				}
				took := time.Since(start).Round(10 * time.Millisecond)
				var tables []string
				for _, h := range res.Tables {
					tables = append(tables, fmt.Sprintf("%s (%d)", h.Table, h.Rows))
				}
				t.Logf("%s contains=%v: all tables in %s; %d terms, not found %q; tables %s", name, contains, took, len(res.Terms), res.NotFound, strings.Join(tables, ", "))
				// Contains finds PNTNAM inside longer texts (RANGER_SOTEXT); the whole value is in no cell
				if !contains && !slices.Equal(res.NotFound, []string{"PNTNAM"}) {
					t.Errorf("not found %q, want [PNTNAM]", res.NotFound)
				}
				rows, err := m.TermRows(context.Background(), realBigTable, res.Terms, contains, 0)
				if err != nil {
					t.Fatal(err)
				}
				col := func(r map[string]any, name string) string { return fmt.Sprint(r[name]) }
				var pntno []string
				for _, r := range rows.Rows {
					pntno = append(pntno, col(r, "PNTNO"))
					if col(r, "RTUNO") != "50" {
						t.Errorf("RTUNO %s in %v", col(r, "RTUNO"), r)
					}
				}
				subnam := map[string]bool{}
				for _, r := range rows.Rows {
					subnam[col(r, "SUBNAM")] = true
				}
				t.Logf("%s contains=%v: %s %d rows, PNTNO in list order %v, SUBNAM %v, first column %q", name, contains, realBigTable, len(rows.Rows), pntno, subnam, rows.Columns[0])
				var nums []int
				for _, p := range pntno {
					n, _ := strconv.Atoi(p)
					nums = append(nums, n)
				}
				slices.Sort(nums)
				if want := []int{238, 242, 254, 256, 260, 304, 308, 2190}; !slices.Equal(nums, want) {
					t.Errorf("PNTNO %v, want the set %v", pntno, want)
				}
				if schema, _ := m.tableSchema(realBigTable); len(rows.Columns) != len(schema) || rows.Columns[0] != schema[0].Name {
					t.Errorf("grid columns %v, want the %d columns of %s (no Term column, standard 19d)", rows.Columns[:min(3, len(rows.Columns))], len(schema), realBigTable)
				}
			}
			if name == "DB3.accdb" { // standard 19f: the report of the owner's 8 terms to Excel, read back
				var eight []string
				for _, l := range lines {
					if l = strings.TrimSpace(l); l != "" && l != "PNTNAM" {
						eight = append(eight, l)
					}
				}
				res, err := m.SearchTerms(context.Background(), eight, false, "", noProgress)
				if err != nil {
					t.Fatal(err)
				}
				xlsx := filepath.Join(t.TempDir(), "DB3 - Pesquisa Avançada.xlsx")
				if err := m.ExportTerms(context.Background(), res, false, "xlsx", xlsx, noProgress); err != nil {
					t.Fatal(err)
				}
				f, err := excelize.OpenFile(xlsx)
				if err != nil {
					t.Fatal(err)
				}
				defer f.Close()
				if want := []string{"RANGER_SOEQID", "RANGER_SOSTAT"}; !slices.Equal(f.GetSheetList(), want) {
					t.Errorf("sheets %v, want %v", f.GetSheetList(), want)
				}
				sheet, _ := f.GetRows(realBigTable)
				schema, _ := m.tableSchema(realBigTable)
				var names []string
				for _, c := range schema {
					names = append(names, c.Name)
				}
				if len(sheet) != 9 || !slices.Equal(sheet[0], names) {
					t.Errorf("%s sheet: %d lines, titles %v", realBigTable, len(sheet), sheet[0][:min(3, len(sheet[0]))])
				}
				for row := 2; row <= 9; row++ {
					for _, col := range []string{"A", "B"} { // RTUNO, PNTNO
						if typ, _ := f.GetCellType(realBigTable, fmt.Sprintf("%s%d", col, row)); typ != excelize.CellTypeNumber {
							t.Errorf("%s %s%d: cell type %v, want a number", realBigTable, col, row, typ)
						}
					}
				}
				t.Logf("DB3.accdb report of the 8 terms: sheets %v, %s titles %v..., RTUNO/PNTNO numeric", f.GetSheetList(), realBigTable, sheet[0][:3])
			}

			// the SQL tab only reads (standard item 33): a write is refused before it runs, a read works
			for _, q := range []string{"CREATE TABLE x AS SELECT 1", "DELETE FROM " + realBigTable, "SELECT 1; DROP TABLE " + realBigTable} {
				if _, err := m.RunQuery(context.Background(), q, 10); err == nil || !strings.Contains(err.Error(), i18n.T("err.sqlReadOnly")) {
					t.Errorf("%q: %v", q, err)
				}
			}
			if res, err := m.RunQuery(context.Background(), "SELECT count(*) AS n FROM "+realBigTable, 10); err != nil || len(res.Rows) != 1 {
				t.Errorf("count: %v %v", res, err)
			} else {
				t.Logf("%s: SELECT count(*) = %v (the table is still there)", name, res.Rows[0]["n"])
			}
		})
	}
}
