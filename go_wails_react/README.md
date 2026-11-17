# MDB2SQL (Go + Wails + React) 1.2.0

Windows program to open, browse and convert databases: DuckDB, SQLite and Microsoft Access
(`.mdb`, `.accdb`). It lists the tables, shows data and schema, runs SQL, and exports the whole database
to DuckDB, SQLite or Excel, or one table / one query result to CSV or Excel. It never changes the file
it opens.

## Which file to download

Release `go_wails_react-v1.2.0`, three files with the same program (Windows 11, 64-bit):

| File | What it is | When to use |
| --- | --- | --- |
| `mdb2sql-1.2.0-w11-amd64-go-wails-react.exe` | single executable, nothing to install | copy anywhere and double-click |
| `mdb2sql-1.2.0-w11-amd64-go-wails-react.zip` | folder with `mdb2sql.exe`, `LEIAME.txt` and `LICENSE` | unzip to a folder (USB stick, shared drive) |
| `mdb2sql-1.2.0-w11-amd64-go-wails-react-installer.exe` | NSIS installer: `Program Files\Mauricio Menon\MDB2SQL`, Start menu and desktop shortcuts, uninstaller | permanent install; asks for administrator rights |

Windows SmartScreen may warn because the files are not code-signed: "More info" > "Run anyway".

Changes in 1.2.0:

- Short window title, "mdb2sql 1.2.0 - Go"; the full stack with versions moved to Help > About.
- Help > About redone: name and version, what the program does, build number and date, "Go x + Wails x +
  React x", DuckDB version, the Access reader this computer would use (ODBC driver or embedded mdbtools),
  author, license, and two links that open in the default browser (GitHub and GitLab).
- Hide several columns at once: "Colunas..." button (one checkbox per column, "Mostrar todas", "Ocultar
  todas") and right-click on a column header ("Ocultar esta coluna", "Colunas...", "Mostrar todas"). The
  status bar shows "N colunas ocultas". Search and exports still use every column.
- Right-click a cell > "Filtrar por este valor": keeps the rows where that column has exactly that value
  (a NULL cell: `IS NULL`). The filter runs in the database query, so it finds rows beyond the ones
  loaded; filters on several columns add up (AND) and are shown as removable chips ("Filtro: SIGLA = 'U9A'").
- Each action appears once: the toolbar row ("Load database", "Sample data" and a second "Export", copies of
  File > Open and of the export list in File) is gone; the exports have their own Export menu.
- A selected cell opens its menu with the keyboard menu key too (cells take focus).
- Licenca: GPL v2 ou posterior (antes: proprietaria). The zip and the installer carry `LICENSE`.

Changes in 1.1.1: the row search and the table filter match every word typed, in any order, ignoring case
and accents (before, the whole text had to appear as typed, accents included); own app icon (exe, window,
installer, shortcuts) instead of the Wails default; the title bar shows the version; excelize 2.11.1.

## Requirements

- Windows 11 (or Windows 10) 64-bit.
- Microsoft Edge WebView2 Runtime: already part of Windows 11. The installer installs it if it is missing
  (that step downloads it from Microsoft).
- For Access files, nothing is mandatory:
  - if the 64-bit "Microsoft Access Driver (*.mdb, *.accdb)" is installed (it comes with 64-bit Microsoft
    Office or with the free Microsoft Access Database Engine 2016 Redistributable,
    https://www.microsoft.com/download/details.aspx?id=54920), the program uses it (fastest);
  - otherwise it uses mdbtools 1.0.1, which is embedded in the program.
- No internet connection: everything the program needs is inside the exe.

## How to use

Start the program; open a file with File > Open database. A file can also be
given on the command line (`mdb2sql.exe "C:\data\DB4.accdb"`, or drag the file onto the exe) or in the
environment variable `MDB2SQL_DB_PATH`; it then opens at start.

Window parts:

- Left: the tables; "Filter N tables" narrows the list (same word rule as the row search below).
- Right, three tabs:
  - Data: the first rows of the selected table (Rows: 100 by default, 500 or 1000); every column is as wide
    as its content (scroll sideways). "Search loaded rows" keeps the rows that have one cell containing every
    word typed, in any order, ignoring case and accents: `tensao campo` finds "EXCITAÇÃO TENSÃO DE CAMPO";
    words found only in different cells of the row do not match. It searches only the rows loaded now
    (raise Rows, or use the SQL tab with `WHERE`, to search the whole table).
  - Schema: column names, types and nullability.
  - SQL: any DuckDB SQL over the open database (`SELECT ... FROM "TABLE" WHERE ...`); Run or Ctrl+Enter.
- Click a cell to select it; Ctrl+C copies the value. Right-click a cell: Copy value, Copy row,
  Copy row with header (TAB-separated; pastes into Excel in columns; hidden columns are copied too).
- Filter by a value (Data tab): right-click a cell > "Filtrar por este valor" shows only the rows where that
  column has exactly that value; a NULL cell filters by `IS NULL`. It is a `WHERE` in the database query, so
  it also finds rows that were not loaded, and Rows still limits how many are shown: the line under the grid
  says "Showing 100 of 1234 rows matching the filters (40000 in the table)". Filters on other columns add up
  (AND); filtering the same column again replaces its value. Each active filter is a chip above the grid
  ("Filtro: SIGLA = 'U9A'") with an x to remove it; "Limpar filtros" (chip bar or cell menu) removes all.
  Another table starts without filters. The word search works on the filtered rows; the SQL tab is not
  affected. Exports ignore the filters (they write the whole table).
- Hide columns (Data tab): "Colunas..." lists every column with a checkbox (checked = visible), plus
  "Mostrar todas" and "Ocultar todas"; change as many as needed and close. Right-click a column header:
  "Ocultar esta coluna", "Colunas...", "Mostrar todas". The status bar shows "N colunas ocultas". Hidden
  columns come back when another table or file is opened. The search still looks at every column and
  exports still write every column.
- Bottom status bar: what was opened (file and number of tables), the last export or the error, and on the
  right the reader used: "Opened via DuckDB", "SQLite", "Access ODBC" or "mdbtools".

Menus:

- File
  - Open database...: `.duckdb`, `.db`, `.sqlite`, `.sqlite3`, `.mdb`, `.accdb`.
  - Open sample data: the file in `MDB2SQL_DB_PATH` (or `data\sample.duckdb` next to where it runs).
  - Exit.
- Export, all run in the background with a progress window and a Cancel button:
  - Database as DuckDB (.duckdb) and Database as SQLite (.sqlite): every table, with its types;
  - Database as Excel (.xlsx, one sheet per table): sheet name = table name (characters Excel refuses
    become `_`, cut to Excel's 31 characters, `~2` added if two cut names are equal); first row = column
    names; a table with more than 1,048,575 rows continues in sheets `NAME (2)`, `NAME (3)`...;
  - Current table as CSV / as Excel: the whole table, not only the rows shown;
  - SQL result as CSV / as Excel: the whole result of the last query run in the SQL tab.
  - CSV files are UTF-8 with BOM, comma separated (Excel opens them with accents right).
  - The save dialog opens in the folder of the open file; with none open, in the last folder used.
  - A cancelled or failed export leaves no half-written file; an existing file is replaced only at the end.
- Settings > Theme: System (follows Windows), Light or Dark; remembered for the next start.
- Help > About: version, build number and date, stack (Go + Wails + React) and DuckDB versions, Access reader
  in use on this computer, author, license, and the GitHub and GitLab links (they open in the default browser).

Opening Access files: the tables are copied into memory first (progress window with Cancel); the 287-table
test database (115 MB) takes about 20 s with the ODBC driver and about 45 s with mdbtools on an idle machine (up to
4-5 min on a busy one). `MDB2SQL_ACCESS_READER=mdbtools` (or `=odbc`) forces one reader. With neither available, the error
message says what to install.

Files the program creates on the user's computer (nothing else):

- `%LOCALAPPDATA%\mdb2sql\go-wails-react-1.2.0-<build>\`: mdbtools and the SQLite extension, unpacked on
  first use; folders of older builds are deleted automatically.
- `%LOCALAPPDATA%\mdb2sql\go-wails-react-webview\`: WebView2 data.
- `%APPDATA%\mdb2sql\go-wails-react.json`: theme and last folder used.

## Tested

On Windows 11 Pro 10.0.26300 (amd64), WebView2 Runtime 157.0.4341.46, Access ODBC driver
16.0.20527 (64-bit Office), with copies of the real NMR5 database "2026-07-14 DB4" (287 tables;
RANGER_SOSTAT 36,754 rows, 130 columns):

- `.accdb` through Access ODBC and through mdbtools, `.sqlite`, `.duckdb`: same 287 tables, same row count
  in every table, same values in a fingerprint query (distinct RTUNO, sum of PNTNO, max PNTNAM, names with
  accents) - automatic test `go test ./backend -run RealDB`.
- Export of the database to `.duckdb` and `.sqlite` and reopening: 287 tables, all row counts equal; to
  `.xlsx`: 287 sheets, row counts of RANGER_SOSTAT, RANGER_SOAGC and the first table equal; also an Access
  (ODBC) source exported to `.sqlite` and `.xlsx`.
- The `.xlsx` of the whole database, written by the same export code, reopened with openpyxl
  (287 sheets; row counts of three tables checked).
- The release exe driven through UI Automation: Access opened (status "Opened via Access ODBC" and
  "Opened via mdbtools"), File and Export menus, Settings > Theme (dark and light), Help > About, SQL tab.
  The native save dialog itself was not driven (its file name field did not answer to UI Automation in the
  test session); the exports behind it were checked by the automatic tests above.
- 1.1.1 search, release exe through UI Automation on the `.duckdb` copy: RANGER_SOMESG (100 of 10,000 rows
  loaded), "banco numero" -> 1 match, the row "Número do banco invalido". Timing on 1000 rows x 123
  columns of RANGER_SOSTAT: about 21 ms to prepare the rows once, 2-3 ms per search.

## Known limits

- Writing `.mdb`/`.accdb` is not offered: there is no reliable library to create Access files.
- Access files are read completely into memory; very large files need RAM in proportion.
- Access through mdbtools: binary/OLE columns come as hexadecimal text (the ODBC reader keeps them binary).
- Access through ODBC: DECIMAL columns wider than 19 digits become DOUBLE; Currency stays DECIMAL(19,4).
- Excel dates before 1900 are written as text (Excel cannot store them as dates); cells longer than
  32,767 characters are cut by Excel's limit; numbers above 15 significant digits lose precision in Excel.
- The SQL tab runs any SQL on the in-memory copy or session; it cannot change the opened file (attached
  read-only), and "SQL result as..." runs the query again. A query in the SQL tab has no Cancel button:
  a very slow query runs until it ends (the window stays usable).- The grid shows at most 1000 rows; exports always write every row.
- Windows only for the packaged program (the code builds on Linux with mdbtools from PATH, no ODBC).

---

## For developers

Version: `wails.json` -> `info.productVersion` is the single source. Go embeds that file and serves it to the
About dialog (`GetAppInfo`); the Wails CLI writes the same value into the exe resource. The build number
(`git rev-list --count HEAD`) and date are set by `scripts/build_w11.ps1` (`-ldflags -X`); outside that build
About shows "build dev".

### Stack and versions

| Part | Version | Fixed by |
| --- | --- | --- |
| Go | 1.26.10 (go.mod: `go 1.26.0`) | `scripts/setup_tools.ps1` |
| Wails (module and CLI) | 2.13.0 | `go.mod`, `scripts/setup_tools.ps1` |
| duckdb-go | v2.20000.0 (DuckDB 2.0.0, static) | `go.mod` / `go.sum` |
| DuckDB sqlite extension | v2.0.0, windows_amd64_mingw (embedded) | `scripts/setup_tools.ps1` (sha256) |
| mdbtools (static, Access fallback reader) | 1.0.1, release `win-static-1.0.1` of mdbtools_custom (embedded) | `scripts/setup_tools.ps1` (sha256) |
| alexbrainman/odbc (Access ODBC reader) | v0.0.0-20250601004241-49e6b2bc0cf0 | `go.mod` / `go.sum` |
| excelize (xlsx export) | v2.11.1 | `go.mod` / `go.sum` |
| WinLibs GCC (MinGW-w64 UCRT, for cgo) | 16.2.0, MinGW-w64 14.0.0, r3 | `scripts/setup_tools.ps1` |
| NSIS (installer) | 3.12 | `scripts/setup_tools.ps1` (sha256) |
| React / Vite / Vitest | 18.3 / 8.3 / 4.1 | `pnpm-lock.yaml` (repo root) |

Why these: cgo (duckdb-go) needs a GCC with the UCRT runtime; the Wails CLI 2.13.0 does not run on Go 1.27,
so Go stays on 1.26.x; the CLI version matches the Wails module in `go.mod`. The duckdb-go Windows library is a
MinGW build (`PRAGMA platform` = `windows_amd64_mingw`), so the sqlite extension is that platform's signed
file, embedded and loaded from disk, never downloaded at run time. `alexbrainman/odbc` is the pure-Go (no cgo)
ODBC driver for `database/sql`; its last commit is from 2025-06 and it is not archived; the two catalog calls it
lacks (SQLTables, SQLColumns) are called on `odbc32.dll` directly. excelize 2.11.1 (2026-11-02) since 1.1.1
(Dependabot PR #27; it also raised golang.org/x/crypto, x/net, x/sys, x/text and mscfb). To update a tool,
change its version and sha256 together at the top of `scripts/setup_tools.ps1`.

Without `.tools/` the scripts fall back to the system: `go` and `wails` from PATH with
`GOTOOLCHAIN=go1.26.11`, GCC from `MDB2SQL_GCC_BIN` or `~\.local\winlibs-gcc-16.2.0-ucrt-r3\mingw64\bin`,
`makensis` from PATH. The mdbtools release lives in a private repository: `setup_tools.ps1` downloads it with
`curl` and, when that gets 404, with `gh release download` (logged-in GitHub CLI).

System prerequisites: Node.js 22+ and pnpm (the frontend is one package of the pnpm workspace at the repo
root, one `pnpm-lock.yaml` shared with the Tauri UI), WebView2 Runtime, git. The Go module cache
(`%USERPROFILE%\go\pkg\mod`) is the normal per-user cache; modules are checked against `go.sum`.

### Build

```powershell
pwsh -NoProfile -File build_w11_amd64.ps1   # -> dist\w11\amd64\: single exe, zip and NSIS installer
```

Commands, products, work folders and cleaning: [README-BUILD.txt](README-BUILD.txt).

### Run and test

```powershell
. scripts\env_w11.ps1        # Go, GCC, Wails and NSIS from .tools\ on PATH
wails dev
go test ./...                # needs frontend\dist and backend\embedded (go:embed): build once before
pnpm --dir frontend exec vitest run
$env:MDB2SQL_TEST_DB_DIR = '<folder with copies of "2026-07-14 DB4".accdb/.sqlite/.duckdb>'
go test ./backend -run RealDB -v -timeout 30m   # all four readers and the exports on the real database
```

How it works: every format ends in one in-memory DuckDB. DuckDB and SQLite files are attached read-only as
`src` (`.db` is told apart by the SQLite file header); Access tables are imported (ODBC: types from
SQLColumns, rows through the DuckDB appender; mdbtools: `mdb-schema ... access` for the types, `mdb-export`
CSV loaded with `read_csv`). Exports attach the target file (`.duckdb`/`.sqlite`) and copy each table with
`CREATE TABLE AS`, or stream rows to excelize / `encoding/csv`, writing `<name>.partial.<ext>` and renaming
at the end.

### Layout

- `main.go`, `app.go`, `settings.go` - Wails entry point, the methods the UI calls, saved settings.
- `backend/` - DuckDB access (`db_manager.go`), Access readers (`access.go`, `odbc_windows.go`),
  exports (`export.go`), embedded tools (`assets.go`, `embedded/` filled by the build).
- `frontend/` - React UI (Vite); `frontend/wailsjs/` - bindings generated by Wails.
- `scripts/` - build steps called by `build_w11_amd64.ps1`.

## Licenca

GPL v2 ou posterior (`GPL-2.0-or-later`), text in [`LICENSE`](LICENSE). Copyright (C) 2026 Mauricio Menon.
Third-party parts keep their own licenses (Go, Wails, React, DuckDB, excelize; the embedded mdbtools is
GPL/LGPL, its `COPYING` files go inside the exe).
