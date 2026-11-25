package main

import (
	"context"
	"database/sql"
	"mdb2sql/backend"
	"mdb2sql/i18n"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
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
	if info.Version != "1.3.0" {
		t.Fatalf("version must come from wails.json info.productVersion, got %q", info.Version)
	}
	if got := windowTitle(); got != "mdb2sql 1.3.0 - Go" {
		t.Fatalf("window title must carry the wails.json version, got %q", got)
	}
	// standard item 3: the open file's name in front of the title, as Python
	if got := titleFor("DB4.accdb"); got != "DB4.accdb - mdb2sql 1.3.0 - Go" {
		t.Fatalf("title with a file open: %q", got)
	}
	if got := titleFor(""); got != "mdb2sql 1.3.0 - Go" {
		t.Fatalf("title without a file: %q", got)
	}
	if !regexp.MustCompile(`^\d+\.\d+`).MatchString(info.Go) {
		t.Fatalf("unexpected Go version %q", info.Go)
	}
	if !regexp.MustCompile(`^v\d+\.\d+\.\d+`).MatchString(info.DuckDB) {
		t.Fatalf("unexpected DuckDB version %q", info.DuckDB)
	}
}

// audit item 16: a long SQL tab query ignored Cancel and a second one ran beside it. Now a new query, CancelJob
// and opening another file stop the running one, which returns "query cancelled".
func TestRunQueryOneAtATime(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "q.duckdb")
	db, err := sql.Open("duckdb", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("CREATE TABLE t (id INTEGER)"); err != nil {
		t.Fatal(err)
	}
	db.Close()
	app := NewApp()
	t.Cleanup(func() { _ = app.dbManager.Close() })
	if _, err := app.LoadDatabase(dbPath); err != nil {
		t.Fatal(err)
	}
	const slow = "SELECT sum(a.range * b.range) FROM range(1000000000) a, range(1000) b" // minutes if not stopped
	stopped := func(stop func()) {
		t.Helper()
		errc := make(chan error, 1)
		go func() { _, err := app.RunQuery(slow, 10); errc <- err }()
		time.Sleep(300 * time.Millisecond)
		stop()
		select {
		case err := <-errc:
			if err == nil || !strings.Contains(err.Error(), "cancelled") {
				t.Errorf("slow query: %v, want cancelled", err)
			}
		case <-time.After(20 * time.Second):
			t.Fatal("slow query was not stopped")
		}
	}
	stopped(func() {
		if res, err := app.RunQuery("SELECT 42 AS n", 10); err != nil || len(res.Rows) != 1 {
			t.Errorf("second query: %v %v", res, err)
		}
	})
	stopped(app.CancelJob)
	stopped(func() {
		if _, err := app.LoadDatabase(dbPath); err != nil {
			t.Errorf("reopen: %v", err)
		}
	})
}

// audit 2026-11-24: an "All tables" search kept counting on the connection while another file opened or the file
// closed. Now both stop the search first: its slow count is interrupted and it returns an error.
func TestSearchStopsWhenFileChanges(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "s.duckdb")
	db, err := sql.Open("duckdb", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	// minutes to count if not stopped
	if _, err := db.Exec("CREATE VIEW slow AS SELECT a.range * b.range AS n FROM range(1000000000) a, range(1000) b"); err != nil {
		t.Fatal(err)
	}
	db.Close()
	app := NewApp()
	t.Cleanup(func() { _ = app.dbManager.Close() })
	reopen := func() error { _, err := app.LoadDatabase(dbPath); return err }
	if err := reopen(); err != nil {
		t.Fatal(err)
	}
	for name, change := range map[string]func() error{"open": reopen, "close": app.CloseDatabase} {
		if app.dbName == "" {
			if err := reopen(); err != nil {
				t.Fatal(err)
			}
		}
		searched, changed := make(chan error, 1), make(chan error, 1)
		registered := func() bool { app.jobMu.Lock(); defer app.jobMu.Unlock(); return app.searchCancel != nil }
		app.jobMu.Lock()
		app.searchCancel = nil
		app.jobMu.Unlock()
		go func() { _, err := app.SearchAllTables("x"); searched <- err }()
		for !registered() { // a loaded machine may start the goroutine late; the change must find the search
			time.Sleep(20 * time.Millisecond)
		}
		time.Sleep(300 * time.Millisecond) // counting the view by now
		go func() { changed <- change() }()
		select {
		case err := <-searched:
			if err == nil {
				t.Errorf("%s: the search must stop with an error", name)
			}
		case <-time.After(20 * time.Second):
			t.Fatalf("%s: the search was not stopped", name)
		}
		if err := <-changed; err != nil {
			t.Errorf("%s: %v", name, err)
		}
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

// the user's real settings (a saved language, for one) must not change what the tests see
func TestMain(m *testing.M) {
	dir, _ := os.MkdirTemp("", "mdb2sql-settings-")
	os.Setenv("APPDATA", dir)
	os.Setenv("XDG_CONFIG_HOME", dir)
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// Access is converted once to a SQLite file that waits for "save or delete"; another file cannot be opened before
// that, a remembered choice is applied by itself (never over an existing file), and exit removes what is left
func TestConvertedSQLiteLifecycle(t *testing.T) {
	// not t.TempDir: the sqlite extension unpacked here stays loaded in this process, so Windows cannot delete it
	cache, _ := os.MkdirTemp("", "mdb2sql-cache-")
	t.Cleanup(func() { os.RemoveAll(cache) }) // best effort
	t.Setenv("LOCALAPPDATA", cache)
	t.Setenv("XDG_CACHE_HOME", cache)
	t.Setenv("MDB2SQL_ACCESS_READER", "")
	mdb := filepath.Join("backend", "testdata", "types.mdb")
	other := filepath.Join(t.TempDir(), "other.duckdb")
	db, _ := sql.Open("duckdb", other)
	db.Exec("CREATE TABLE t (id INTEGER)")
	db.Close()

	app := NewApp()
	if _, err := app.LoadDatabase(mdb); err != nil {
		t.Skipf("no Access reader or sqlite extension here (run a build first): %v", err)
	}
	first := app.converted
	if app.PendingConversion() != "types.sqlite" || first == "" {
		t.Fatalf("pending %q (%q)", app.PendingConversion(), first)
	}
	if _, err := app.LoadDatabase(other); err == nil || app.dbName != "types.mdb" {
		t.Fatalf("opened another file over a pending conversion: %v", err)
	}
	if res, err := app.ResolveConversion("cancel", true); err != nil || res.Done || app.converted == "" {
		t.Fatalf("cancel: %+v %v", res, err)
	}
	if res, err := app.ResolveConversion("delete", true); err != nil || !res.Done {
		t.Fatalf("delete: %+v %v", res, err)
	}
	if _, err := os.Stat(first); !os.IsNotExist(err) || app.dbName != "" || app.RememberedChoice() != "delete" {
		t.Fatalf("after delete: %v, open %q, remembered %q", err, app.dbName, app.RememberedChoice())
	}

	// remembered "delete": the next file just opens
	if _, err := app.LoadDatabase(mdb); err != nil {
		t.Fatal(err)
	}
	second := app.converted
	if _, err := app.LoadDatabase(other); err != nil || app.converted != "" {
		t.Fatalf("remembered delete: %v %q", err, app.converted)
	}
	if _, err := os.Stat(second); !os.IsNotExist(err) {
		t.Fatalf("second converted file left: %v", err)
	}

	// remembered "save" (folder of the first save): types.sqlite, then types (2).sqlite, never over a file; two
	// copies of the .mdb, since the same file reopened uses the SQLite saved from it (session cache)
	copyMDB := func(name string) string {
		data, _ := os.ReadFile(mdb)
		p := filepath.Join(t.TempDir(), name)
		os.WriteFile(p, data, 0o644)
		return p
	}
	app.convChoice, app.convDir = "save", t.TempDir()
	for _, c := range []struct{ src, want string }{{mdb, "types.sqlite"}, {copyMDB("types.mdb"), "types (2).sqlite"}} {
		if _, err := app.LoadDatabase(c.src); err != nil {
			t.Fatal(err)
		}
		if app.beforeClose(context.Background()) { // the window may close: the choice was applied
			t.Fatal("close blocked with a remembered choice")
		}
		if _, err := os.Stat(filepath.Join(app.convDir, c.want)); err != nil {
			t.Fatalf("%s not saved: %v", c.want, err)
		}
	}
	// session cache: the same .mdb again opens types.sqlite, no new conversion
	if _, err := app.LoadDatabase(mdb); err != nil || app.converted != "" || app.dbManager.Source() != backend.SourceSQLite {
		t.Fatalf("reopen: %v, converted %q, source %q", err, app.converted, app.dbManager.Source())
	}
	if app.savedConversion(copyMDB("other.mdb")) != "" {
		t.Fatal("cache hit for a file never converted")
	}
	// an exit with a pending file removes it
	app.convChoice = ""
	if _, err := app.LoadDatabase(copyMDB("third.mdb")); err != nil {
		t.Fatal(err)
	}
	last := app.converted
	app.shutdown(context.Background())
	if _, err := os.Stat(last); !os.IsNotExist(err) {
		t.Fatalf("converted file left after exit: %v", err)
	}
}

// Tema, idioma e ultima pasta sobrevivem a um reinicio; valor desconhecido e recusado
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
	defer i18n.SetLang("en")
	if app.GetLanguage() != "en" {
		t.Fatalf("default language %q", app.GetLanguage())
	}
	if err := app.SetLanguage("es"); err != nil || app.SetLanguage("fr") == nil {
		t.Fatalf("SetLanguage: %v", err)
	}
	if got := NewApp().GetLanguage(); got != "es" || i18n.T("menu.file") != "Archivo" {
		t.Fatalf("language after restart %q", got)
	}
	// the Log panel starts collapsed and keeps the last state
	if app.GetLogOpen() {
		t.Fatal("log expanded by default")
	}
	if err := app.SetLogOpen(true); err != nil || !NewApp().GetLogOpen() {
		t.Fatalf("log state after restart: %v", err)
	}
	// Show NULL: off by default, also for a settings file written before the option existed
	if err := os.WriteFile(settingsPath(), []byte(`{"theme": "dark"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if app = NewApp(); app.GetShowNull() {
		t.Fatal("Show NULL on by default")
	}
	if err := app.SetShowNull(true); err != nil || !NewApp().GetShowNull() {
		t.Fatalf("Show NULL after restart: %v", err)
	}
	// default search scope: this table, then what was chosen; an unknown one is refused
	if app.GetSearchScope() != "table" {
		t.Fatalf("default search scope %q", app.GetSearchScope())
	}
	if err := app.SetSearchScope("all"); err != nil || app.SetSearchScope("everything") == nil || NewApp().GetSearchScope() != "all" {
		t.Fatalf("search scope after restart: %v", err)
	}
}
