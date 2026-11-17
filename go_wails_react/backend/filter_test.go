package backend

import (
	"context"
	"database/sql"
	"encoding/json"
	"path/filepath"
	"testing"
)

// nome de coluna citado (aspas dobradas), valor sempre em parametro, NULL vira IS NULL
func TestFilterWhere(t *testing.T) {
	types := map[string]string{`a"b`: "VARCHAR", "n": "INTEGER"}
	evil := `x' OR '1'='1`
	where, args, err := filterWhere([]Filter{{`a"b`, evil}, {"n", nil}, {"n", 5.0}}, types)
	if err != nil {
		t.Fatal(err)
	}
	if want := ` WHERE "a""b" = CAST(? AS VARCHAR) AND "n" IS NULL AND "n" = CAST(? AS INTEGER)`; where != want {
		t.Errorf("where:\n%s\nwant\n%s", where, want)
	}
	if len(args) != 2 || args[0] != evil || args[1] != 5.0 {
		t.Errorf("args: %v", args)
	}
	if where, args, err := filterWhere(nil, types); where != "" || args != nil || err != nil {
		t.Errorf("no filters: %q %v %v", where, args, err)
	}
	if _, _, err := filterWhere([]Filter{{`n" = 1 OR "n`, 1.0}}, types); err == nil {
		t.Error("unknown column must fail")
	}
	if _, _, err := filterWhere([]Filter{{"n", []any{1.0}}}, types); err == nil {
		t.Error("list value must fail")
	}
}

// uiValue is the cell as the UI sends it back: through JSON, like the Wails bridge
func uiValue(t *testing.T, v any) any {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var out any
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

// o filtro roda no banco (acha linha alem do limite), em DuckDB e SQLite, com texto, inteiro, NULL e aspas
func TestTableFilters(t *testing.T) {
	const sigla = `si"gla x`
	src := filepath.Join(t.TempDir(), "filter.duckdb")
	db, err := sql.Open("duckdb", src)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE pts (id INTEGER, "si""gla x" VARCHAR, r REAL, valor DECIMAL(10,2), em TIMESTAMP, ok BOOLEAN);
		INSERT INTO pts VALUES (1, 'U9A', 0.1, 12.34, '2026-07-14 10:20:30', true), (2, 'U9A', 0.1, NULL, '2026-01-02', false),
			(3, 'O''Brien "q"', 2.5, -1, NULL, NULL), (4, NULL, NULL, NULL, NULL, NULL), (5, 'x'' OR ''1''=''1', 3, 7, NULL, true);
		INSERT INTO pts SELECT range + 10, 'Z', 1, 1, NULL, NULL FROM range(500);
		INSERT INTO pts VALUES (999, 'U18A', 9, 9, NULL, NULL);`)
	db.Close()
	if err != nil {
		t.Fatal(err)
	}
	m := NewDBManager()
	if err := m.Connect(src); err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	files := map[string]string{SourceDuckDB: src}
	if hasAsset(sqliteExtensionAsset) {
		files[SourceSQLite] = filepath.Join(t.TempDir(), "filter.sqlite")
		if err := m.ExportDatabase(context.Background(), "sqlite", files[SourceSQLite], func(int, int, string) {}); err != nil {
			t.Fatal(err)
		}
	} else {
		t.Log("no embedded sqlite extension: SQLite not checked (run a build first)")
	}

	cases := []struct {
		name    string
		filters []Filter
		count   int
	}{
		{"text", []Filter{{sigla, "U9A"}}, 2},
		{"quotes", []Filter{{sigla, `O'Brien "q"`}}, 1},
		{"injection text is just a value", []Filter{{sigla, `x' OR '1'='1`}}, 1},
		{"null", []Filter{{sigla, nil}}, 1},
		{"integer", []Filter{{"id", 3.0}}, 1}, // JSON numbers reach Go as float64
		{"beyond the loaded rows", []Filter{{sigla, "U18A"}}, 1},
		{"two filters are ANDed", []Filter{{sigla, "U9A"}, {"valor", nil}}, 1},
		{"no match", []Filter{{sigla, "u9a"}}, 0},
		{"many rows, limit kept", []Filter{{sigla, "Z"}}, 500},
	}
	for source, file := range files {
		t.Run(source, func(t *testing.T) {
			m := NewDBManager()
			if err := m.Connect(file); err != nil {
				t.Fatal(err)
			}
			defer m.Close()
			for _, c := range cases {
				n, err := m.GetRowCount("pts", c.filters...)
				if err != nil || n != c.count {
					t.Errorf("%s: count %d, want %d (%v)", c.name, n, c.count, err)
				}
				rows, err := m.QueryTable("pts", 100, c.filters...)
				if err != nil || len(rows) != min(c.count, 100) {
					t.Errorf("%s: %d rows, want %d (%v)", c.name, len(rows), min(c.count, 100), err)
				}
			}
			if _, err := m.QueryTable("pts", 100, Filter{"nope", 1.0}); err == nil {
				t.Error("unknown column must fail")
			}
			// every shown value, sent back as the UI does, must find its own row (REAL, DECIMAL, TIMESTAMP, BOOLEAN too)
			rows, err := m.QueryTable("pts", 5)
			if err != nil || len(rows) != 5 {
				t.Fatalf("rows: %d %v", len(rows), err)
			}
			for _, row := range rows {
				for col, v := range row {
					got, err := m.QueryTable("pts", 1000, Filter{col, uiValue(t, v)}, Filter{"id", uiValue(t, row["id"])})
					if err != nil || len(got) != 1 {
						t.Errorf("id %v, %s = %v: %d rows (%v)", row["id"], col, v, len(got), err)
					}
				}
			}
		})
	}
}

// audit item 12: 9007199254740993 reached the UI as 9007199254740992 (JS Number); big values go as text,
// keep every digit and still filter back to their own row
func TestBigNumbersKeepDigits(t *testing.T) {
	src := filepath.Join(t.TempDir(), "big.duckdb")
	db, err := sql.Open("duckdb", src)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE big (i BIGINT, u UBIGINT, d DECIMAL(38,2), small DECIMAL(10,2), n INTEGER);
		INSERT INTO big VALUES (9007199254740993, 18446744073709551615, 123456789012345678.91, 12.30, 7),
			(-9007199254740993, 1, 0.10, -1.5, NULL);`)
	db.Close()
	if err != nil {
		t.Fatal(err)
	}
	m := NewDBManager()
	if err := m.Connect(src); err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	rows, err := m.QueryTable("big", 10)
	if err != nil || len(rows) != 2 {
		t.Fatalf("rows %d %v", len(rows), err)
	}
	want := map[string]any{"i": "9007199254740993", "u": "18446744073709551615", "d": "123456789012345678.91", "small": 12.3, "n": 7.0}
	for col, w := range want {
		if got := uiValue(t, rows[0][col]); got != w {
			t.Errorf("%s: UI gets %#v, want %#v", col, got, w)
		}
	}
	if got := uiValue(t, rows[1]["i"]); got != "-9007199254740993" {
		t.Errorf("negative: %#v", got)
	}
	res, err := m.RunQuery(context.Background(), "SELECT i FROM big ORDER BY i DESC LIMIT 1", 10)
	if err != nil || uiValue(t, res.Rows[0]["i"]) != "9007199254740993" {
		t.Errorf("SQL tab: %v %v", res.Rows, err)
	}
	for _, col := range []string{"i", "u", "d"} {
		if n, err := m.GetRowCount("big", Filter{col, uiValue(t, rows[0][col])}); err != nil || n != 1 {
			t.Errorf("filter %s: %d rows %v", col, n, err)
		}
	}
}
