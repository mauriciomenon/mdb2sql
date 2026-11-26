package main

import (
	"context"
	"database/sql"
	"mdb2sql/backend"
	"mdb2sql/i18n"
	"os"
	"path/filepath"
	"regexp"
	goruntime "runtime"
	"slices"
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
	// About > Janela: the full WebView2 version (Windows 11 has the runtime), not the 158.0.0.0 of the user agent
	if goruntime.GOOS == "windows" && !regexp.MustCompile(`^WebView2 \d+\.\d+\.\d+\.\d+$`).MatchString(info.Webview) {
		t.Fatalf("unexpected window engine %q", info.Webview)
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
	// a wrong path typed in the path bar: the UI drops the open file, Go closes it too (title without a name)
	if _, err := app.LoadDatabase(filepath.Join(t.TempDir(), "missing.duckdb")); err == nil {
		t.Fatal("a missing file opened")
	}
	if app.DatabaseName() != "" || app.DatabasePath() != "" || app.dbManager.Source() != "" {
		t.Fatalf("still open after a failed open: %q %q", app.DatabaseName(), app.dbManager.Source())
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

// coordinator 26/11: the progress of a search goes to the UI at most ~10 times a second, the first and last always
func TestProgressAtMostTenASecond(t *testing.T) {
	a := &App{}
	t0 := time.Now()
	ms := func(n int) time.Time { return t0.Add(time.Duration(n) * time.Millisecond) }
	steps := []struct {
		done, total int
		at          time.Time
		want        bool
	}{
		{1, 287, ms(0), true},   // the first
		{2, 287, ms(10), false}, // 10 ms later
		{3, 287, ms(99), false}, // still inside the 100 ms
		{4, 287, ms(100), true}, // 100 ms after the last one sent
		{5, 287, ms(150), false},
		{287, 287, ms(160), true}, // the last
		{40, 0, ms(170), false},   // unknown total: also limited
		{41, 0, ms(260), true},
	}
	for _, s := range steps {
		if got := a.progressDue(s.done, s.total, s.at); got != s.want {
			t.Errorf("progressDue(%d, %d) at %v = %v, want %v", s.done, s.total, s.at.Sub(t0), got, s.want)
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

// standard items 27-29: Access is converted once to a SQLite file in the temporary folder. Only leaving the app asks
// about it, and only while it was not saved; another file, Close and Reopen just delete it. File > Save writes it as
// SQLite (a copy), DuckDB or Excel, the database stays open, and the same unchanged Access file then opens the SQLite or
// DuckDB saved from it.
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
	gone := func(path string) bool { _, err := os.Stat(path); return os.IsNotExist(err) }
	// each conversion needs its own Access file: the same one reopened uses what was saved from it
	copyMDB := func(name string) string {
		data, _ := os.ReadFile(mdb)
		p := filepath.Join(t.TempDir(), name)
		os.WriteFile(p, data, 0o644)
		return p
	}

	var logged []string
	logHook = func(text string) { logged = append(logged, text) }
	t.Cleanup(func() { logHook = nil })
	app := NewApp()
	t.Cleanup(func() { app.shutdown(context.Background()) })
	if _, err := app.LoadDatabase(mdb); err != nil {
		t.Skipf("no Access reader or sqlite extension here (run a build first): %v", err)
	}
	first := app.converted
	if app.PendingConversion() != "types.mdb" || !strings.HasPrefix(first, filepath.Join(os.TempDir(), "mdb2sql-go-wails-react")+string(filepath.Separator)) {
		t.Fatalf("pending %q, converted file %q (want it in the temporary folder)", app.PendingConversion(), first)
	}
	if !app.asksOnExit() {
		t.Fatal("leaving with the converted file not saved must ask")
	}
	// another file: nobody is asked, the converted file is deleted
	if _, err := app.LoadDatabase(other); err != nil || app.dbName != "other.duckdb" || app.converted != "" || !gone(first) {
		t.Fatalf("another file: %v, open %q, converted %q left=%v", err, app.dbName, app.converted, !gone(first))
	}
	if app.asksOnExit() {
		t.Fatal("nothing to ask with a DuckDB file open")
	}
	// Close: the same
	if _, err := app.LoadDatabase(mdb); err != nil {
		t.Fatal(err)
	}
	second := app.converted
	if err := app.CloseDatabase(); err != nil || app.dbName != "" || !gone(second) {
		t.Fatalf("close: %v, open %q, left=%v", err, app.dbName, !gone(second))
	}

	// Save as SQLite: a copy of the converted file; the database stays open, nothing more to ask, and it is remembered
	dir := t.TempDir()
	if _, err := app.LoadDatabase(mdb); err != nil {
		t.Fatal(err)
	}
	third, saved := app.converted, filepath.Join(dir, "types.sqlite")
	if err := app.saveTo(saved, "sqlite"); err != nil {
		t.Fatal(err)
	}
	if gone(saved) || gone(third) || app.dbName != "types.mdb" || app.PendingConversion() != "" || app.asksOnExit() {
		t.Fatalf("after save: saved gone=%v, temp gone=%v, open %q, pending %q", gone(saved), gone(third), app.dbName, app.PendingConversion())
	}
	if rows, err := app.GetRowCount("Tipos", nil, ""); err != nil || rows != 3 {
		t.Fatalf("the database must stay open after a save: %d rows (%v)", rows, err)
	}
	// Reopen (F5): the temporary file goes, and the same unchanged Access file opens the SQLite saved from it
	if _, err := app.LoadDatabase(mdb); err != nil || !gone(third) || app.converted != "" || app.dbManager.Source() != backend.SourceSQLite {
		t.Fatalf("reopen: %v, temp left=%v, converted %q, source %q", err, !gone(third), app.converted, app.dbManager.Source())
	}
	// the name Save proposes there would be the file that is open: "<name> (copy)"; and saving over it is refused
	if got := saveName(dir, app.dbStem(), "sqlite", app.dbPath, app.dbManager.Path()); got != "types (copy).sqlite" {
		t.Errorf("proposed name %q", got)
	}
	if got := saveName(dir, app.dbStem(), "duckdb", app.dbPath, app.dbManager.Path()); got != "types.duckdb" {
		t.Errorf("proposed name %q", got)
	}
	if err := app.saveTo(saved, "sqlite"); err == nil || err.Error() != i18n.T("err.exportOverOpen") {
		t.Errorf("save over the open file: %v", err)
	}

	// Save as DuckDB: remembered too (the same Access file then opens the DuckDB file)
	second2 := copyMDB("duck.mdb")
	if _, err := app.LoadDatabase(second2); err != nil {
		t.Fatal(err)
	}
	duck := filepath.Join(dir, "duck.duckdb")
	if err := app.saveTo(duck, "duckdb"); err != nil || app.asksOnExit() {
		t.Fatalf("save as DuckDB: %v", err)
	}
	if _, err := app.LoadDatabase(second2); err != nil || app.converted != "" || app.dbManager.Source() != backend.SourceDuckDB || app.dbManager.Path() != duck {
		t.Fatalf("reopen after DuckDB: %v, converted %q, source %q", err, app.converted, app.dbManager.Source())
	}
	// the Log says the format of the saved file (standard 13), SQLite or DuckDB, never "SQLite" for a .duckdb
	for _, want := range []string{"types.mdb: opened the SQLite saved from it (" + saved + ")", "duck.mdb: opened the DuckDB saved from it (" + duck + ")"} {
		if !slices.Contains(logged, want) {
			t.Errorf("Log without %q: %q", want, logged)
		}
	}
	// Save as Excel: nothing more to ask, but the Access file is converted again next time
	third2 := copyMDB("sheet.mdb")
	if _, err := app.LoadDatabase(third2); err != nil {
		t.Fatal(err)
	}
	if err := app.saveTo(filepath.Join(dir, "sheet.xlsx"), "xlsx"); err != nil || app.asksOnExit() || app.savedConversion(third2) != "" {
		t.Fatalf("save as Excel: %v, asks %v, remembered %q", err, app.asksOnExit(), app.savedConversion(third2))
	}
	// a save that fails leaves the question in place
	if _, err := app.LoadDatabase(copyMDB("fail.mdb")); err != nil {
		t.Fatal(err)
	}
	if err := app.saveTo(filepath.Join(dir, "missing", "x.sqlite"), "sqlite"); err == nil || !app.asksOnExit() {
		t.Fatalf("failed save: %v, asks %v", err, app.asksOnExit())
	}
	// Exit: the UI asked (Exit), nothing more is asked and the converted file is removed
	last := app.converted
	app.Exit()
	if app.asksOnExit() {
		t.Fatal("asked again after Exit")
	}
	app.shutdown(context.Background())
	if !gone(last) {
		t.Fatalf("converted file left after exit: %s", last)
	}
}

// standard item 29: what a crash left is removed at startup from the temporary folders, from the folders beside
// Access files that had to hold a converted file (kept in the settings) and from where 1.3.0 kept them; the Log line
// waits for the UI to ask for it
func TestStartupCleansLeftovers(t *testing.T) {
	t.Setenv("APPDATA", t.TempDir())         // Windows
	t.Setenv("XDG_CONFIG_HOME", t.TempDir()) // Linux
	cache, temp := t.TempDir(), t.TempDir()
	t.Setenv("LOCALAPPDATA", cache)
	t.Setenv("XDG_CACHE_HOME", cache)
	for _, k := range []string{"TMP", "TEMP", "TMPDIR"} {
		t.Setenv(k, temp)
	}
	beside := filepath.Join(t.TempDir(), "mdb2sql-go-wails-react")
	roots := []string{backend.ConvertedRoots("")[0], beside, backend.LegacyConvertedRoot()}
	if roots[0] != filepath.Join(temp, "mdb2sql-go-wails-react") {
		t.Fatalf("temporary root %q", roots[0])
	}
	for _, root := range roots {
		dead := filepath.Join(root, "2147483646", "x") // no such process
		if err := os.MkdirAll(dead, 0o755); err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(dead, "old.sqlite"), []byte("x"), 0o644)
	}
	NewApp().rememberTempDir(beside)
	app := NewApp() // the next run
	if len(app.settings.TempDirs) != 1 || app.settings.TempDirs[0] != beside {
		t.Fatalf("folder beside the Access file not kept: %q", app.settings.TempDirs)
	}
	app.cleanStale()
	for _, root := range roots {
		if _, err := os.Stat(root); !os.IsNotExist(err) {
			t.Errorf("leftover folder %s: %v", root, err)
		}
	}
	lines := app.StartupLog()
	if len(lines) != 1 || !strings.Contains(lines[0], "3") || app.StartupLog() != nil {
		t.Errorf("startup log %q", lines)
	}
	if len(NewApp().settings.TempDirs) != 0 {
		t.Errorf("a folder that is gone still kept: %q", NewApp().settings.TempDirs)
	}
}

// standard item 22: the SQLite saved from an Access file is kept in the settings between runs; the same unchanged file
// opens it without converting, and a change in the Access file or in the saved SQLite converts again
func TestSavedConversionPersists(t *testing.T) {
	t.Setenv("APPDATA", t.TempDir())         // Windows
	t.Setenv("XDG_CONFIG_HOME", t.TempDir()) // Linux
	dir := t.TempDir()
	src, dest := filepath.Join(dir, "DB4.accdb"), filepath.Join(dir, "DB4.sqlite")
	write := func(path, text string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(src, "access")
	write(dest, "sqlite")
	NewApp().rememberConversion(src, fileKey(src), dest)
	if got := NewApp().savedConversion(src); got != dest { // a new run
		t.Fatalf("saved conversion after restart: %q", got)
	}
	write(src, "access, changed") // another size: converted again, and the old entry is dropped
	if got := NewApp().savedConversion(src); got != "" {
		t.Fatalf("changed Access file reused %q", got)
	}
	if _, ok := NewApp().settings.Converted[strings.ToLower(src)]; ok {
		t.Fatal("entry of a changed Access file kept")
	}
	NewApp().rememberConversion(src, fileKey(src), dest)
	write(dest, "sqlite, changed")
	if got := NewApp().savedConversion(src); got != "" {
		t.Fatalf("changed SQLite reused %q", got)
	}
	if got := NewApp().savedConversion(filepath.Join(dir, "DB4.duckdb")); got != "" {
		t.Fatalf("not an Access file: %q", got)
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
