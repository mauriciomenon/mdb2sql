# MDB2SQL (Go + Wails + React) 1.3.0

Program to open, browse and convert databases: Microsoft Access (`.accdb`, `.mdb`), SQLite (`.sqlite`,
`.sqlite3`, `.db`) and DuckDB (`.duckdb`). Access files open without Microsoft Access or any driver installed
(mdbtools is inside the program) and are converted once to a SQLite file, which you can keep. It lists the
tables, shows data and schema, searches the whole table, runs SQL, and exports the whole database to SQLite,
DuckDB or Excel, or one table / one query result to CSV or Excel. It never changes the file it opens.
English (default), Portuguese (Brazil) and Spanish.

## Which file to download

Release `go_wails_react-v1.3.0`. Windows 11, 64-bit, three files with the same program:

| File | What it is | When to use |
| --- | --- | --- |
| `mdb2sql-1.3.0-w11-amd64-go-wails-react.exe` | single executable, nothing to install | copy anywhere and double-click |
| `mdb2sql-1.3.0-w11-amd64-go-wails-react.zip` | folder with `mdb2sql.exe`, `LEIAME.txt` and `LICENSE` | unzip to a folder (USB stick, shared drive) |
| `mdb2sql-1.3.0-w11-amd64-go-wails-react-installer.exe` | NSIS installer: `Program Files\Mauricio Menon\MDB2SQL`, Start menu and desktop shortcuts, uninstaller | permanent install; asks for administrator rights |

Debian 13 (trixie), amd64:

| File | What it is |
| --- | --- |
| `mdb2sql-1.3.0-debian-amd64-go-wails-react.deb` | package: command `mdb2sql-go-wails-react`, menu entry; `sudo apt install ./<file>.deb` installs the libraries it needs |
| `mdb2sql-1.3.0-debian-amd64-go-wails-react.zip` | folder with the `mdb2sql` binary, `README.md` and `LICENSE`; needs the libraries below |

Debian runtime libraries (the `.deb` declares them; for the `.zip`: `sudo apt install libgtk-3-0t64
libwebkit2gtk-4.1-0 libglib2.0-0t64`): GTK 3 and WebKitGTK 4.1 draw the window (Wails on Linux),
GLib is used by the embedded mdbtools. Nothing else: DuckDB, mdbtools (with `libmdb.so.3`) and the
SQLite extension are inside the binary.

Windows SmartScreen may warn because the files are not code-signed: "More info" > "Run anyway".

Changes in 1.3.0:

- Access first, then SQLite, then DuckDB, everywhere (Open dialog filters, Export menu, About, this README).
- Access is converted ONCE to a SQLite file (on disk, not in memory) and read from there, with the types kept:
  integers `INTEGER`, Currency/Decimal `DECIMAL(p,s)`, Single `REAL`, Double `DOUBLE`, Date/Time `DATETIME`,
  Yes/No `BOOLEAN` (0/1), text `TEXT`, OLE/binary `BLOB` (also through mdbtools, which 1.2.0 turned into hex
  text), NULL kept. Database > SQLite export writes the same typed tables.
- When an Access file was converted, closing it (File > Close database), opening another file or exiting asks
  once: "Save..." (save dialog, next to the Access file by default, name `<file>.sqlite`), "Delete" or
  "Cancel"; "Remember for this session" keeps the answer until the program closes (a remembered "Save" goes
  to the same folder and never overwrites: `<file> (2).sqlite`). Converted files left by a crash are deleted at
  the next start.
- mdbtools exports several tables at once (4 processes): the 287-table test file converts in about 50 s; the
  same exports one at a time took about 100 s on the same machine.
- The Data search runs in the database over the WHOLE table (not only the loaded rows): every word in one
  cell, any order, ignoring case and accents; the line under the grid says "showing 100 of 412 rows matching
  (36754 in the table)". The SQL tab still searches its loaded result.
- Languages: Settings > Language: English (default), Português (Brasil), Español; saved; changes at once,
  without restarting. Every text (menus, dialogs, messages, About, tooltips, native dialogs) comes from
  `i18n/en.json`, `i18n/pt-BR.json`, `i18n/es.json` (same keys, shared by Go and React).
- View > Log: the session messages with the time (open, convert, save/delete, export, copy, errors), read-only
  and selectable (Ctrl+A, Ctrl+C), "Copy all". The status bar text is selectable and right-click > Copy.
- Names are never cut with "...": long table names in the list and long column names in "Columns..." wrap
  to a second line; the status bar wraps too.
- Debian 13 amd64 build (`.deb` and `.zip`) with mdbtools inside.
- Saving the converted SQLite or an export over an existing file asks "Replace file?" first (the native save
  dialog did not ask; 1.2.0 replaced the file silently).
- Licenca: GPL v2 ou posterior (sem mudanca desde 1.2.0).

Changes in 1.2.0: short window title; Help > About redone; "Columns..." dialog; right-click > filter by this
value (in the database query); every action once; the table name above the grid is never cut; one font
size. Corrected in 1.2.0 (external audit): exports never delete a user file, late answers dropped, integers
beyond 2^53 keep their digits, one SQL query at a time. Changes in 1.1.1: word search in any order ignoring
accents, own icon, excelize 2.11.1.

## Requirements

- Windows 11 (or Windows 10) 64-bit, or Debian 13 amd64 (libraries above).
- Windows: Microsoft Edge WebView2 Runtime, already part of Windows 11 (the installer installs it if missing).
- Access files: nothing to install. If the 64-bit "Microsoft Access Driver (*.mdb, *.accdb)" exists (64-bit
  Office or the free Microsoft Access Database Engine 2016 Redistributable,
  https://www.microsoft.com/download/details.aspx?id=54920), the Windows program uses it because it is faster;
  otherwise the embedded mdbtools 1.0.1. `MDB2SQL_ACCESS_READER=mdbtools` (or `=odbc`) forces one reader.
- No internet connection: everything the program needs is inside it.

## How to use

Open a file with File > Open database (the dialog lists Access, SQLite and DuckDB files), on the command line
(`mdb2sql.exe "C:\data\DB4.accdb"`, or drag the file onto the exe) or with `MDB2SQL_DB_PATH`.

- Left: the tables; "Filter N tables" narrows the list (same word rule as the search).
- Right, three tabs:
  - Data: the first rows of the table (Rows: 100, 500 or 1000). "Search the whole table" keeps the rows with
    one cell containing every word typed, in any order, ignoring case and accents, over the whole table in the
    database: `tension de campo` finds "EXCITACION TENSION DE CAMPO" even beyond the first rows; there is no
    fuzzy match (`tensao` does not find "TENSION").
  - Schema: column names, types and nullability.
  - SQL: any DuckDB SQL over the open database; Run or Ctrl+Enter; the search field filters its loaded result.
- Click a cell; Ctrl+C copies the value. Right-click a cell: Filter by this value, Clear filters, Copy value,
  Copy row, Copy row with header (TAB-separated, pastes into Excel in columns).
- Filter by a value: a `WHERE column = value` (`IS NULL` for an empty cell) in the database query; filters on
  several columns add up (AND) and show as removable chips. Exports ignore filters and search.
- Columns...: one checkbox per column, a field to filter the list; "Show all" and "Hide all" act on the
  listed columns only. Right-click a column header: Hide this column, Columns..., Show all.
- Status bar: the last message (selectable; right-click > Copy) and the reader used ("Opened via mdbtools,
  converted to SQLite", "Opened via SQLite"...).

Menus: File (Open database..., Open sample data, Close database, Exit), Export (Database as SQLite / DuckDB /
Excel; Current table as CSV / Excel; SQL result as CSV / Excel; all with progress and Cancel; a failed export
leaves no half file), View (Log), Settings (Theme: System, Light, Dark; Language), Help (About).

Opening Access: the progress window counts the tables; Cancel stops it. The 287-table NMR5 test file (115 MB)
takes about 20-30 s with the ODBC driver and about 50-60 s with mdbtools on Windows (the slowest table,
RANGER_SOSTAT, needs about 40 s inside mdbtools by itself); more on a busy machine. On Debian the mdbtools of the
distribution is slower (about 3 min for RANGER_SOSTAT alone).

Files the program creates (nothing else):

- `%LOCALAPPDATA%\mdb2sql\go-wails-react-<version>-<build>\` (Linux: `~/.cache/mdb2sql/...`): mdbtools and the
  SQLite extension, unpacked on first use; folders of older builds are deleted automatically.
- `%LOCALAPPDATA%\mdb2sql\converted-go-wails-react\<process id>\`: the SQLite converted from an Access file,
  until you save or delete it (deleted on exit; left-overs of a crash are deleted at the next start).
- `%LOCALAPPDATA%\mdb2sql\go-wails-react-webview\`: WebView2 data (Windows).
- `%APPDATA%\mdb2sql\go-wails-react.json` (Linux: `~/.config/mdb2sql/`): theme, language and last folder.

## Tested

Windows 11 Pro 10.0.26300 amd64, Access ODBC driver 16.0 (64-bit), with COPIES of the NMR5 files
"2026-07-14 DB4.accdb" and "2026-06-25 DB3 1.accdb" and of their reference conversions (`.sqlite` and
`.duckdb` made by the reference converter from the same `.accdb`): `go test ./backend -run RealDB` opens each
`.accdb` through mdbtools and through ODBC, converts it to SQLite, and checks the 287 tables, the row count of
every table (DB4: 113,962 rows; DB3 1: 113,826) and a fingerprint of RANGER_SOSTAT against both references; the
whole-table search finds RTUNO 50 PNTNO 9 in RANGER_SOANLG (not in its first 100 rows) by "tension de campo".
`backend/testdata/types.mdb` (generated by `scripts/make_test_mdb.ps1`, versioned, no external file needed)
checks every Access type, NULLs, accents, CRLF and binary through both readers. Debian 13 in WSL: the official
build (tests included) and the `.deb`.

## Known limits

- Writing `.mdb`/`.accdb` is not offered: there is no reliable library to create Access files.
- SQLite stores decimals as 8-byte floats: Currency/Decimal values are exact up to 15 significant digits (all
  values of the NMR5 files); beyond that they are rounded. Integers are exact.
- mdbtools 1.0.1 exports an Access zero-length text ("") as NULL; the ODBC reader keeps "".
- The grid shows at most 1000 rows; search, filters and exports cover every row.
- Excel dates before 1900 are written as text; cells longer than 32,767 characters are cut by Excel; numbers
  above 15 significant digits lose precision in Excel.
- Messages that come from the database engines themselves (an error in a SQL typed in the SQL tab) stay in
  English.
- Arch, macOS and BSD builds are not offered in 1.3.0.

---

## For developers

Version: `wails.json` -> `info.productVersion` is the single source (About, exe resource, `.deb`). The build
number (`git rev-list --count HEAD`) and date are set by the build scripts (`-ldflags -X`); outside them About
shows "build dev".

### Stack and versions

| Part | Version | Fixed by |
| --- | --- | --- |
| Go | 1.26.10 (go.mod: `go 1.26.0`) | `scripts/setup_tools.ps1`, `scripts/build_debian.sh` |
| Wails (module and CLI) | 2.13.0 | `go.mod`, the two scripts above |
| duckdb-go | v2.20000.0 (DuckDB 2.0.0, static) | `go.mod` / `go.sum` |
| DuckDB sqlite extension | v2.0.0, windows_amd64_mingw / linux_amd64 (embedded) | the two scripts (sha256) |
| mdbtools, Windows | 1.0.1 static, release `win-static-1.0.1` of mdbtools_custom (embedded) | `scripts/setup_tools.ps1` (sha256) |
| mdbtools, Debian | 1.0.1-0.1 of Debian 13 with `libmdb.so.3` (embedded) | `scripts/build_debian.sh` (sha256) |
| alexbrainman/odbc (Access ODBC reader) | v0.0.0-20250601004241-49e6b2bc0cf0 | `go.mod` / `go.sum` |
| excelize (xlsx export) | v2.11.1 | `go.mod` / `go.sum` |
| WinLibs GCC (MinGW-w64 UCRT, for cgo) | 16.2.0, MinGW-w64 14.0.0, r3 | `scripts/setup_tools.ps1` |
| NSIS (installer) | 3.12 | `scripts/setup_tools.ps1` (sha256) |
| React / Vite / Vitest | 18.3 / 8.3 / 4.1 | `pnpm-lock.yaml` (repo root) |

cgo (duckdb-go) needs a GCC with the UCRT runtime on Windows; the Wails CLI 2.13.0 does not run on Go 1.27; the
sqlite extension is the signed file of the platform of the linked DuckDB, embedded and loaded from disk, never
downloaded at run time. System prerequisites: Windows: Node.js 22+ and pnpm, WebView2, git. Debian:
`sudo apt install build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev dpkg-dev zip curl nodejs`
(Node 20.19+; pnpm comes through corepack).

### Build

```powershell
pwsh -NoProfile -File build_w11_amd64.ps1            # Windows -> dist\w11\amd64\: single exe, zip, installer
pwsh -NoProfile -File build_debian_amd64_wsl.ps1     # Debian through WSL -> dist\debian\amd64\: .deb, .zip
```

On a Debian machine: `./build_debian_amd64.sh` in a clone on a Linux disk. Details: [README-BUILD.txt](README-BUILD.txt).

### Run and test

```powershell
. scripts\env_w11.ps1        # Go, GCC, Wails and NSIS from .tools\ on PATH
wails dev
go test ./...                # needs frontend\dist and backend\embedded (go:embed): build once before
pnpm --dir frontend exec vitest run
$env:MDB2SQL_TEST_DB_DIR = '<folder with COPIES of the .accdb files and their reference .sqlite/.duckdb>'
go test ./backend -run RealDB -v -timeout 60m
```

How it works: every format is read through one in-memory DuckDB. SQLite and DuckDB files are attached read-only
as `src` (`.db` is told apart by the SQLite file header). An Access file is read (ODBC: types from SQLColumns,
rows through the DuckDB appender; mdbtools: `mdb-schema ... access` for the types, `mdb-export` CSV, NULL as
`\N`, binary as hex, several tables at once) into a temporary in-memory DuckDB, written once to a SQLite file
with typed columns (`CREATE TABLE` sent to SQLite through `sqlite_query`, rows by `INSERT ... SELECT`), and that
file is attached like any SQLite file. The Data search and the filters are a `WHERE` built in Go (values bound,
words compared with `lower(strip_accents(...))`). Texts: `i18n/*.json`, read by Go (`i18n` package, embedded)
and imported by React (`frontend/src/i18n.ts`).

### Layout

- `main.go`, `app.go`, `settings.go` - Wails entry point, the methods the UI calls, saved settings.
- `i18n/` - text catalogs (en, pt-BR, es) and the Go side of them.
- `backend/` - DuckDB access (`db_manager.go`), Access readers (`access.go`, `odbc_windows.go`), the converted
  file (`convert.go`), exports (`export.go`), embedded tools (`assets.go`, `embedded/` filled by the build),
  test data (`testdata/types.mdb`).
- `frontend/` - React UI (Vite); `frontend/wailsjs/` - bindings generated by Wails.
- `scripts/` - build steps; `scripts/linux/` - the Debian menu entry.

## Licenca

GPL v2 ou posterior (`GPL-2.0-or-later`), text in [`LICENSE`](LICENSE).
Third-party parts keep their own licenses (Go, Wails, React, DuckDB, excelize; the embedded mdbtools is
GPL/LGPL, its license files go inside the program).
