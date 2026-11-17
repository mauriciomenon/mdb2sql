package main

import (
	"database/sql"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// GPL v2 text shipped in the zip and the installer; package metadata says GPL-2.0-or-later
func TestLicense(t *testing.T) {
	read := func(name string) string {
		data, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	if text := read("LICENSE"); !regexp.MustCompile(`^\s*GNU GENERAL PUBLIC LICENSE\s+Version 2, June 1991`).MatchString(text) {
		t.Errorf("LICENSE must be the GPL v2 text, starts with %q", text[:min(80, len(text))])
	}
	if !strings.Contains(read("frontend/package.json"), `"license": "GPL-2.0-or-later"`) {
		t.Error(`frontend/package.json must say "license": "GPL-2.0-or-later"`)
	}
	if !strings.Contains(read("build/windows/installer/project.nsi"), `File "..\..\..\LICENSE"`) {
		t.Error("the installer must install LICENSE")
	}
	if !strings.Contains(read("scripts/package_w11.ps1"), `Copy-Item build\bin\mdb2sql.exe, LICENSE $appDir`) {
		t.Error("the zip must carry LICENSE")
	}
}

func TestGetAppInfo(t *testing.T) {
	info := NewApp().GetAppInfo()
	if info.Version != "1.2.0" {
		t.Fatalf("version must come from wails.json info.productVersion, got %q", info.Version)
	}
	if got := windowTitle(); got != "mdb2sql 1.2.0 - Go" {
		t.Fatalf("window title must carry the wails.json version, got %q", got)
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

	exts := []string{".duckdb", ".db", ".sqlite", ".sqlite3", ".mdb", ".accdb"}
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

// Pasta padrao do dialogo de salvar: a do arquivo aberto; sem ele, a ultima usada; pastas que sumiram nao valem
func TestDefaultSaveDir(t *testing.T) {
	open := t.TempDir()
	last := t.TempDir()
	gone := filepath.Join(last, "removed")
	cases := []struct{ file, last, want string }{
		{filepath.Join(open, "db.accdb"), last, open},
		{"", last, last},
		{"", gone, ""},
		{filepath.Join(gone, "db.duckdb"), last, last},
		{"", "", ""},
	}
	for _, c := range cases {
		if got := defaultSaveDir(c.file, c.last); got != c.want {
			t.Errorf("defaultSaveDir(%q, %q) = %q, want %q", c.file, c.last, got, c.want)
		}
	}
}

// Tema e ultima pasta sobrevivem a um reinicio; valor desconhecido e recusado
func TestSettingsPersist(t *testing.T) {
	t.Setenv("APPDATA", t.TempDir())         // Windows
	t.Setenv("XDG_CONFIG_HOME", t.TempDir()) // Linux
	app := NewApp()
	if app.GetTheme() != "system" {
		t.Fatalf("default theme %q", app.GetTheme())
	}
	if err := app.SetTheme("dark"); err != nil {
		t.Fatal(err)
	}
	if err := app.SetTheme("blue"); err == nil {
		t.Fatal("unknown theme accepted")
	}
	if got := NewApp().GetTheme(); got != "dark" {
		t.Fatalf("theme after restart %q", got)
	}
}
