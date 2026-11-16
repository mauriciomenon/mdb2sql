# MDB2SQL (Go + Wails + React)

Viewer and converter for DuckDB, SQLite and Microsoft Access databases: tables, schema, data and free SQL,
export to DuckDB, SQLite, Excel and CSV. One exe, DuckDB linked statically, UI in the system WebView2.

Version: `wails.json` -> `info.productVersion` is the single source. Go embeds that file and
serves it to the About dialog (`GetAppInfo`); the Wails CLI writes the same value into the exe resource.
The build number (`git rev-list --count HEAD`) and date are set by `scripts/build_w11.ps1` (`-ldflags -X`);
outside that build About shows "build dev".

## Stack and versions

| Part | Version | Fixed by |
| --- | --- | --- |
| Go | 1.26.10 (go.mod: `go 1.26.0`) | `scripts/setup_tools.ps1` |
| Wails (module and CLI) | 2.13.0 | `go.mod`, `scripts/setup_tools.ps1` |
| duckdb-go | v2.20000.0 (DuckDB 2.0.0, static) | `go.mod` / `go.sum` |
| DuckDB sqlite extension | v2.0.0, windows_amd64_mingw (embedded) | `scripts/setup_tools.ps1` (sha256) |
| mdbtools (static, Access fallback reader) | 1.0.1, release `win-static-1.0.1` of mdbtools_custom (embedded) | `scripts/setup_tools.ps1` (sha256) |
| alexbrainman/odbc (Access ODBC reader) | v0.0.0-20250601004241-49e6b2bc0cf0 | `go.mod` / `go.sum` |
| excelize (xlsx export) | v2.11.0 | `go.mod` / `go.sum` |
| WinLibs GCC (MinGW-w64 UCRT, for cgo) | 16.2.0, MinGW-w64 14.0.0, r3 | `scripts/setup_tools.ps1` |
| NSIS (installer) | 3.12 | `scripts/setup_tools.ps1` (sha256) |
| React / Vite / Vitest | 18.3 / 8.3 / 4.1 | `pnpm-lock.yaml` (repo root) |

Why these: cgo (duckdb-go) needs a GCC with the UCRT runtime; the Wails CLI 2.13.0 does not run on
Go 1.27, so Go stays on 1.26.x; the CLI version matches the Wails module in `go.mod`. The duckdb-go
Windows library is a MinGW build, so its extensions are the `windows_amd64_mingw` ones; the sqlite extension
is embedded and loaded from a file, never downloaded at run time. `alexbrainman/odbc` is the pure-Go
(no cgo) ODBC driver for `database/sql`; its last commit is from 2025-06, it is not archived, and the two
catalog calls it lacks (SQLTables, SQLColumns) are called on `odbc32.dll` directly. excelize 2.11.0
(2026-07) instead of 2.11.1 (2026-11-02, under two weeks old at the time of this release).
To update a tool, change its version and sha256 together at the top of `scripts/setup_tools.ps1`.

Without `.tools/` the scripts fall back to the system: `go` and `wails` from PATH with
`GOTOOLCHAIN=go1.26.11`, GCC from `MDB2SQL_GCC_BIN` or `~\.local\winlibs-gcc-16.2.0-ucrt-r3\mingw64\bin`.
`MDB2SQL_GCC_BIN` always wins. The mdbtools release lives in a private repository: `setup_tools.ps1`
downloads it with `curl` and, when that gets 404, with `gh release download` (logged-in GitHub CLI).

### Prerequisites that stay on the system

- Node.js (22 or newer) and pnpm: the frontend is one package of the pnpm workspace at the repo root
  (`pnpm-workspace.yaml`, one `pnpm-lock.yaml` shared with the Tauri UI). The lockfile already fixes
  every frontend dependency.
- Microsoft Edge WebView2 Runtime: part of Windows 11; the app needs it at run time, too.
- The Go module cache (`%USERPROFILE%\go\pkg\mod`) is the normal per-user cache; modules are checked against `go.sum`.

## Build

```powershell
pwsh -NoProfile -File build_w11_amd64.ps1   # -> dist\w11\amd64\: single exe, zip and NSIS installer
```

Commands, products, work folders and cleaning: [README-BUILD.txt](README-BUILD.txt).

## Run and test (development)

```powershell
. scripts\env_w11.ps1        # Go, GCC, Wails and NSIS from .tools\ on PATH
wails dev
go test ./...                # needs frontend\dist and backend\embedded (go:embed): build once before
pnpm --dir frontend exec vitest run
$env:MDB2SQL_TEST_DB_DIR = '<folder with copies of "2026-07-14 DB4".accdb/.sqlite/.duckdb>'
go test ./backend -run RealDB -v -timeout 30m   # all four readers and the exports on the real database
```

## Use

- Open (File > Open database, the Load database button, the first command-line argument, or
  `MDB2SQL_DB_PATH` at start): `.duckdb`, `.db`, `.sqlite`, `.sqlite3`, `.mdb`, `.accdb`.
  - DuckDB and SQLite files are attached read-only (`.db` is told apart by the SQLite file header).
  - Access files are read, in this order, with the ODBC driver "Microsoft Access Driver (*.mdb, *.accdb)"
    (64-bit Microsoft Access Database Engine) when it is installed, else with the embedded static mdbtools.
    `MDB2SQL_ACCESS_READER=odbc` or `=mdbtools` forces one. With neither, the error says what to install.
    The tables are imported into an in-memory DuckDB, so everything else works as for the other formats.
  - The status bar shows the reader used: DuckDB, SQLite, Access ODBC or mdbtools.
  - The embedded mdbtools programs and sqlite extension are extracted on first use to
    `%LOCALAPPDATA%\mdb2sql\go-wails-react-<version>-<build>\`; folders of older builds are deleted.
- Export (File > Export, or the Export button):
  - whole database to `.duckdb` or `.sqlite` (every table, types mapped by DuckDB);
  - whole database to Excel `.xlsx`: one sheet per table, named after the table (invalid characters
    replaced, cut to 31 characters, `~2` added when two cut names collide), header in row 1; a table with
    more than 1,048,575 rows continues in sheets `<name> (2)`, `<name> (3)`...;
  - current table or the full SQL result to CSV (UTF-8 with BOM) or `.xlsx`.
  - The save dialog starts in the folder of the open file; with none open, in the last folder used.
  - Exports run in Go, off the UI thread, with progress and Cancel; a cancelled export leaves no file.
  - Writing `.mdb`/`.accdb` is not offered: there is no reliable library to create Access files.
- Data grid: click selects a cell; right-click opens Copy value, Copy row and Copy row with header
  (TAB-separated, pastes into Excel); Ctrl+C copies the selected cell. "Search loaded rows" filters the loaded
  rows by text in any column; "Filter tables" filters the table list; Rows sets the limit (100, 500 or 1000).
- SQL tab: free DuckDB SQL over the open database (Ctrl+Enter runs); the result uses the same grid and copy.
- Settings > Theme: System, Light or Dark, saved in `%APPDATA%\mdb2sql\go-wails-react.json` together with
  the last folder used. Help > About: version, build number and date, runtime versions, author and code.

## Layout

- `main.go`, `app.go`, `settings.go` - Wails entry point, the methods the UI calls, saved settings.
- `backend/` - DuckDB access (`db_manager.go`), Access readers (`access.go`, `odbc_windows.go`),
  exports (`export.go`), embedded tools (`assets.go`, `embedded/` filled by the build).
- `frontend/` - React UI (Vite); `frontend/wailsjs/` - bindings generated by Wails.
- `scripts/` - build steps called by `build_w11_amd64.ps1`.
