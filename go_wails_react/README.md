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
- When an Access file was converted, closing it (File > Close), opening another file or exiting asks
  once: "Save..." (save dialog, next to the Access file by default, name `<file>.sqlite`), "Delete" or
  "Cancel"; "Remember for this session" keeps the answer until the program closes (a remembered "Save" goes
  to the same folder and never overwrites: `<file> (2).sqlite`). Converted files left by a crash are deleted at
  the next start.
- Faster Access open: mdbtools exports up to 6 tables at once, the widest first, and the SQLite file is written in
  one transaction. The 287-table test file (DB4): mdbtools 72 s → 33 s, ODBC 37 s → 10 s; Export → SQLite 31-72 s
  → 3 s (median of 3, same machine, see "Tested").
- The Data search runs in the database over the WHOLE table (not only the loaded rows): every word in one
  cell, any order, ignoring case and accents; the line under the grid says "RANGER_SOSTAT: showing 100 of
  412 rows found". The SQL tab still searches its loaded result.
- Languages: Settings > Language: English (default), Português (Brasil), Español; saved; changes at once,
  without restarting. Every text (menus, dialogs, messages, About, tooltips, native dialogs) comes from
  `i18n/en.json`, `i18n/pt-BR.json`, `i18n/es.json` (same keys, shared by Go and React).
- Log panel at the bottom: the session messages with the time (open, convert, save/delete, export, copy,
  errors), read-only and selectable (Ctrl+A, Ctrl+C), "Copy all"; monospace one step smaller than the rest; about
  10% of the window, resized by its top border (3 lines to 25%). Collapsed by default; the arrow in its header,
  the arrow in the status bar, View > Log and Ctrl+L collapse or expand it, and the state is kept for the next
  start. Collapsed, the status bar shows the last unread error (highlighted), else the last warning, else the
  last action, with a counter of unread errors and warnings; a click on it opens the log. The status bar text is
  selectable and right-click > Copy.
- Numeric columns are right-aligned, their header too.
- An error of the SQL tab shows one line in the status bar, for example `SQL query error: syntax error at or near
  "selec"`; the engine's full message stays in the log.
- The save/delete question never traps you: Esc, its x and Cancel close it (nothing is lost, the app stays
  open), Enter is Save, and cancelling the file dialog of Save asks again.
- Every dialog has its own OK/Close/Cancel button; Enter is the default button and Esc closes (the progress
  window: Esc is Cancel).
- Reopening the same Access file (same path, size and date) after saving its SQLite opens that SQLite at once,
  without a new conversion, also in a later run (kept in the settings); a changed file is converted again.
- Names are never cut with "...": long table names in the list and long column names in "Columns..." wrap
  to a second line; the status bar wraps too.
- Debian 13 amd64 build (`.deb` and `.zip`) with mdbtools inside.
- Saving the converted SQLite or an export over an existing file asks "Replace file?" first (the native save
  dialog did not ask; 1.2.0 replaced the file silently).
- Linux: X11 first, Wayland as fallback with a "Display mode" warning at start (see "Linux: X11 e Wayland").
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
  otherwise the embedded mdbtools 1.0.1; a file the driver refuses (Access 97 `.mdb`) is read by mdbtools too.
  `MDB2SQL_ACCESS_READER=mdbtools` (or `=odbc`) forces one reader.
- No internet connection: everything the program needs is inside it.

## How to use

Open a file with the path bar on top (type the path, then Open or Enter; a long path shows its end; Browse...
opens the file dialog; with the field empty, Open opens `MDB2SQL_DB_PATH` or the sample), File > Open... (Ctrl+O,
the dialog lists Access, SQLite and DuckDB files), by dropping the file on the window, on the command line
(`mdb2sql.exe "C:\data\DB4.accdb"`, or drag the file onto the exe) or with `MDB2SQL_DB_PATH`. The status bar says
"Loaded: DB4.accdb (287 tables)" (pt-BR "Aberto: ...") and the window title starts with the file name.

- Left: the tables with their row count; "Filter N tables" narrows the list (same word rule as the search) after
  a 300 ms pause in typing; Enter applies it at once.
- Right, three tabs:
  - Data: the first rows of the table (Rows: 100, 500 or 1000). "Search the whole table" keeps the rows with
    one cell containing every word typed, in any order, ignoring case and accents, over the whole table in the
    database: `tension de campo` finds "EXCITACION TENSION DE CAMPO" even beyond the first rows; there is no
    fuzzy match (`tensao` does not find "TENSION"). It runs after a 300 ms pause in typing (Enter: at once).
    Beside it, This table | All tables: All tables lists the tables with matching rows (same rule) as
    `table (n)`; a click opens that table with the same search and no value filters. The default is in Settings >
    Default search scope. Opening another file empties the search and the table list filter and returns to that
    default.
  - Schema: column names, types and nullability (Yes/No).
  - SQL: any DuckDB SQL over the open database (the field starts empty); Run or Ctrl+Enter; the search field
    filters its loaded result. A query that runs fine takes an earlier SQL error off the status bar.
- Click a cell; Ctrl+C copies the value. Right-click a cell: Filter by this value, Clear filters, Copy value,
  Copy row, Copy row with header (TAB-separated, pastes into Excel in columns).
- A NULL cell is empty; Settings > Show NULL (off by default) shows NULL there. Display only: copy, search and
  exports are the same either way.
- Filter by a value: a `WHERE column = value` (`IS NULL` for a NULL cell) in the database query; filters on
  several columns add up (AND) and show as removable chips. With the search or a filter on, exporting the current
  table asks: the whole table or only the rows found.
- Columns...: one checkbox per column, a field to filter the list; "Show all" and "Hide all" act on the
  listed columns only, and one column always stays visible. Right-click a Data column header: Size column to fit,
  Size all columns to fit, Hide this column, Columns..., Show all columns, then the columns with a check mark (a
  click shows or hides one; the last visible one stays). Dragging the right edge of a header resizes the column;
  fit returns it to its content.
  Hidden columns and widths last while the table is open.
- Status bar: the last message, or the last unread error or warning while the log is collapsed (click: opens
  the log; right-click > Copy), and the reader used ("Opened via mdbtools,
  converted to SQLite", "Opened via SQLite"...).

Menus (every button has a menu item):

- File: Open... Ctrl+O, Open the typed path, Reopen F5, Save Ctrl+S, Save as... Ctrl+Shift+S, Export >, Close
  Ctrl+W, Exit Ctrl+Q. Save (any open file) opens the native save dialog in the folder of the file, with its name,
  as SQLite, DuckDB or Excel (one sheet per table); Save as... starts in the last folder saved or exported to.
  .mdb and .accdb files cannot be written.
- Export > (the same list under the Export... button; what does not apply now is disabled): Current table, Marked
  rows, Current table schema, Database schema (each CSV or Excel), All tables to CSV (one file per table, in a
  folder), SQL result (CSV or Excel, `query.csv`), All-tables search result (Excel), Advanced Search report (Excel,
  CSV, SQLite or DuckDB). All with progress and Cancel; a failed export leaves no half file.
- Edit: Copy value Ctrl+C, Copy row Ctrl+Shift+C, Copy row with header, Copy the whole log, Search Ctrl+F, Filter
  by this value, Clear filters, Mark or unmark row (Space), Unmark all rows.
- View: Data Ctrl+1, Schema Ctrl+2, SQL Ctrl+3, Advanced Search Ctrl+4, Rows (100/500/1000), Columns..., Search in (This
  table, All tables), Only marked rows, Go to the table list Ctrl+T, Favorite or unfavorite table Ctrl+D, Run SQL
  Ctrl+Enter, Search terms Ctrl+Enter, Log Ctrl+L.

Favorite tables: right-click a table of the list (Add to favorites / Remove from favorites) or Ctrl+D on the open
table. Favorites come first in the list, in alphabetical order, with "★ " before the name; they are kept by name while
the program is open (also for another file), never saved.
- Settings: Theme, Language, Default search scope, Term matching (Whole value, Contains), Show NULL.
- Help: About mdb2sql.

An Access file is converted to a SQLite file in the temporary folder. Close, another file and Reopen leave it
without a question (the Log says it was discarded); exiting with it not saved asks: Save | Back, Exit. Exiting
during an export asks Back or Exit (Exit cancels the export). The SQL tab only reads: a command that would write
is refused before it runs.

Pages (Data tab): the line under the grid says "RANGER_SOSTAT: rows 1 to 100 of 36,804" ("... found" with a
search or filter) and ◀ ▶ go to the previous and next page; a page has the rows of the Rows list; another table,
search, filter or Rows goes back to the first page.

Marked rows (Data tab): a box at the start of each row (also Space and the menus); the marked rows of a table stay
on top of the grid, in table order, on every page, whatever the search or filter; "Only marked" under the grid shows
only them. A row is told apart by the engine's rowid (DuckDB and SQLite tables, Access converted to SQLite); a view
has none: there all the values of the row count, so equal rows are marked together.

Advanced Search tab: paste a list (one term per line, for example an Excel column); each term is searched in every
column of this table or of all tables, the whole cell (Whole value) or inside it (Contains), ignoring case and the
spaces at the ends. In Whole value a term and a cell that read as numbers meet when any reading of one equals any
reading of the other. A text reads as a number with a decimal point and commas of thousands, or with a decimal
comma and points of thousands; a thousands mark only stands between groups of 3 digits. So "216" finds 216.0,
"216,0" and 216 (never 2160), "0,1" finds 0.1 (and "1" does not find "0,1"), "1234.5" finds "1.234,5" and "1,234"
reads 1.234 or 1234. The tables found, their rows with the term first, and the terms not
found (copiable). Its report: a first sheet "Filter Result" with every term, where it was found and how many rows,
then one sheet per table.

Opening Access: the progress window counts the tables; Cancel (or Esc) stops it. The 287-table NMR5 test file
(115 MB) takes about 10 s with the ODBC driver and about 33 s with mdbtools on Windows (Intel Core Ultra 7 258V, 8
cores, 32 GB, SSD; `go test ./backend -run Perf` with `MDB2SQL_PERF=1`), more on a busy machine; most of the
mdbtools time is mdb-export itself (RANGER_SOSTAT alone needs about 25-40 s). On Debian the mdbtools of the
distribution is slower (about 3 min for RANGER_SOSTAT alone). The table list and the first table appear when the
conversion ends.

Files the program creates (nothing else):

- `%LOCALAPPDATA%\mdb2sql\go-wails-react-<version>-<build>\` (Linux: `~/.cache/mdb2sql/...`): mdbtools and the
  SQLite extension, unpacked on first use; folders of older builds are deleted automatically.
- `%TEMP%\mdb2sql-go-wails-react\<process id>\` (else `%SystemRoot%\Temp\...`, else beside the Access file;
  Linux: `/tmp/...`): the SQLite converted from an Access file, deleted when the file is left or the program
  exits; left-overs of a crash are deleted at the next start.
- `%LOCALAPPDATA%\mdb2sql\go-wails-react-webview\`: WebView2 data (Windows).
- `%APPDATA%\mdb2sql\go-wails-react.json` (Linux: `~/.config/mdb2sql/`): theme, language, last folder, Log panel
  state, Show NULL, default search scope, term matching and the files saved from Access files.

## Tested

Windows 11 Pro 10.0.26300 amd64, Access ODBC driver 16.0 (64-bit), with COPIES of the NMR5 files
"2026-07-14 DB4.accdb" and "2026-06-25 DB3 1.accdb" and of their reference conversions (`.sqlite` and
`.duckdb` made by the reference converter from the same `.accdb`): `go test ./backend -run RealDB` opens each
`.accdb` through mdbtools and through ODBC, converts it to SQLite, and checks the 287 tables, the row count of
every table (DB4: 113,962 rows; DB3 1: 113,826) and a fingerprint of RANGER_SOSTAT against both references; the
whole-table search finds "CE01 TRAFO TRB-01 ACEITE NIVEL MUY BAJO" (not among the first 100 rows of RANGER_SOSTAT)
and RTUNO 50 PNTNO 9 in RANGER_SOANLG by "tension de campo" ("tensao" finds only the names written "TENSAO").
`backend/testdata/types.mdb` (generated by `scripts/make_test_mdb.ps1`, versioned, no external file needed)
checks every Access type, NULLs, accents, CRLF and binary through both readers. With `MDB2SQL_TEST_NWIND` (a
copy of nwind.mdb of mdbtestdata, Access 97) Currency stays numeric in the converted file and in Export > SQLite:
Products.UnitPrice > 20 gives 37 rows, sum 1695.11, top 263.5, 123.79, 97. Debian 13 in WSL: the official
build (tests included) and the `.deb`; on Wayland (no `DISPLAY`) the window shows the program and "Display mode".
Speed on Debian 13 in WSL, DB4 copied to the Linux disk, mdbtools reader (`MDB2SQL_PERF=1 MDB2SQL_PERF_BASE="2026-07-14
DB4" go test ./backend -run Perf`, median of 3 per session): 33.9-44.9 s with the embedded Debian mdbtools, 31.0-35.0 s
with the static mdbtools 1.0.1 built from the official tarball (the build of the Rust and Zig stacks); both give the
same CSV (RANGER_SOSTAT: 36,755 lines, same sha256), and the gap is inside the run-to-run noise of a shared
machine, so the Debian package is kept.

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
downloaded at run time. System prerequisites: Windows: Node.js 22+, WebView2, git. Debian:
`sudo apt install build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev dpkg-dev zip curl nodejs`
(Node 20.19+). pnpm 12.23.0 is downloaded to `.tools` by the build command, never installed on the system.

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

## Linux: X11 e Wayland

The window (GTK 3 + WebKitGTK 4.1) opens on X11 when it can, with Wayland as fallback (`GDK_BACKEND=x11,wayland`).
A `GDK_BACKEND` you set yourself is used as is, without warning. Without X11 (no `DISPLAY`: the X server or
XWayland is missing) the program opens on Wayland and shows "Display mode" at start, with the command below for
your distribution (the same text goes to the log and to the terminal); it shows again at each start while X11 is
missing. With neither X11 nor Wayland it stops with a message on the terminal (exit code 1). The X11 libraries
come with GTK, so the X server is the only part that can be missing.

| Distribution (`ID` / `ID_LIKE` of /etc/os-release) | Command |
| --- | --- |
| Debian, Ubuntu | `sudo apt install xwayland` |
| Fedora, RHEL | `sudo dnf install xorg-x11-server-Xwayland` |
| Arch | `sudo pacman -S xorg-xwayland` |
| openSUSE | `sudo zypper install xwayland` |
| other | install the X server or XWayland of your distribution |

## Licenca

GPL v2 ou posterior (`GPL-2.0-or-later`), text in [`LICENSE`](LICENSE).
Third-party parts keep their own licenses (Go, Wails, React, DuckDB, excelize; the embedded mdbtools is
GPL/LGPL, its license files go inside the program).
