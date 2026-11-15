package main

import (
	"database/sql"
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

func TestGetAppInfo(t *testing.T) {
	info := NewApp().GetAppInfo()
	if info.Version != "1.0.1" {
		t.Fatalf("version must come from wails.json info.productVersion, got %q", info.Version)
	}
	if !regexp.MustCompile(`^\d+\.\d+`).MatchString(info.Go) {
		t.Fatalf("unexpected Go version %q", info.Go)
	}
	if !regexp.MustCompile(`^v\d+\.\d+\.\d+`).MatchString(info.DuckDB) {
		t.Fatalf("unexpected DuckDB version %q", info.DuckDB)
	}
}

// "Sample data" com MDB2SQL_DB_PATH deve informar o nome real do arquivo, nao "sample.duckdb"
func TestLoadDatabase_ReportsRealFileNameFromEnv(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "other name.duckdb")
	db, err := sql.Open("duckdb", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("CREATE TABLE t (id INTEGER)"); err != nil {
		t.Fatal(err)
	}
	db.Close()
	t.Setenv("MDB2SQL_DB_PATH", dbPath)

	app := NewApp()
	t.Cleanup(func() { _ = app.dbManager.Close() })
	tables, err := app.LoadDatabase("")
	if err != nil {
		t.Fatalf("load failed: %v", err)
	}
	if len(tables) != 1 || app.DatabaseName() != "other name.duckdb" {
		t.Fatalf("got tables %v, name %q", tables, app.DatabaseName())
	}
}

func TestValidateDatabasePath_AllowsSupportedExts(t *testing.T) {
	app := NewApp()

	exts := []string{".duckdb", ".db", ".sqlite", ".sqlite3"}
	for _, ext := range exts {
		t.Run(ext, func(t *testing.T) {
			tmp, err := os.CreateTemp("", "mdb2sql_*"+ext)
			if err != nil {
				t.Fatalf("failed to create temp file: %v", err)
			}
			defer os.Remove(tmp.Name())
			tmp.Close()

			validated, err := app.validateDatabasePath(tmp.Name())
			if err != nil {
				t.Fatalf("expected success for ext %s, got err: %v", ext, err)
			}
			if validated != filepath.Clean(validated) {
				t.Fatalf("expected clean path, got: %s", validated)
			}
		})
	}
}

func TestValidateDatabasePath_RejectsDirectory(t *testing.T) {
	app := NewApp()
	dir := t.TempDir()

	if _, err := app.validateDatabasePath(dir); err == nil {
		t.Fatalf("expected error for directory path")
	}
}

func TestValidateDatabasePath_RejectsUnsupportedExt(t *testing.T) {
	app := NewApp()
	tmp, err := os.CreateTemp("", "mdb2sql_*.txt")
	if err != nil {
		t.Fatalf("failed to create temp file: %v", err)
	}
	defer os.Remove(tmp.Name())
	tmp.Close()

	if _, err := app.validateDatabasePath(tmp.Name()); err == nil {
		t.Fatalf("expected error for unsupported extension")
	}
}
