package backend

import (
	"os"
	"path/filepath"
	"testing"
)

// Tests DuckDB queries against the real sample database to ensure IPC endpoints
// have a live backend to hit during the POC. Skips if the sample file is absent.
func TestDBManager_QuerySampleDatabase(t *testing.T) {
	samplePath := filepath.Join("data", "sample.duckdb")
	if !fileExists(samplePath) {
		t.Skip("sample.duckdb not found; skipping integration test")
	}

	mgr := NewDBManager()
	if err := mgr.Connect(samplePath); err != nil {
		t.Fatalf("connect failed: %v", err)
	}
	t.Cleanup(func() {
		_ = mgr.Close()
	})

	tables, err := mgr.ListTables()
	if err != nil {
		t.Fatalf("list tables failed: %v", err)
	}
	if len(tables) == 0 {
		t.Fatalf("expected at least one table in sample.duckdb")
	}

	// Sample database created in data/sample.duckdb has these tables
	expected := map[string]struct{}{
		"RANGER_SOACCU": {},
		"RANGER_SOGEN":  {},
		"RANGER_SOVARS": {},
	}
	for name := range expected {
		if _, ok := expected[name]; ok {
			if _, err := mgr.GetTableSchema(name); err != nil {
				t.Fatalf("schema for %s failed: %v", name, err)
			}
			rows, err := mgr.QueryTable(name, 5)
			if err != nil {
				t.Fatalf("query %s failed: %v", name, err)
			}
			if len(rows) == 0 {
				t.Fatalf("expected rows for %s", name)
			}
			count, err := mgr.GetRowCount(name)
			if err != nil {
				t.Fatalf("count %s failed: %v", name, err)
			}
			if count < len(rows) {
				t.Fatalf("row count %d smaller than fetched rows %d for %s", count, len(rows), name)
			}
		}
	}
}

func fileExists(path string) bool {
	if _, err := filepath.Abs(path); err != nil {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}
