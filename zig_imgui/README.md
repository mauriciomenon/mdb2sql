# MDB2SQL (Zig + Dear ImGui)

Desktop program to open Microsoft Access (`.mdb`, `.accdb`), SQLite (`.sqlite`, `.sqlite3`) and DuckDB
(`.duckdb`, `.db`) databases, browse and search their tables, run SQL, and export them to DuckDB, SQLite,
Excel (`.xlsx`, one sheet per table) and CSV. Written in Zig with Dear ImGui (GLFW + OpenGL 3.3) and the
DuckDB C API. Version **1.2.0**. Windows 10/11 x64.

The file you open is never changed: DuckDB and SQLite files are attached read-only, and an Access file is
read once and converted into an in-memory DuckDB database.

## Which file to download

Release `zig_imgui-v1.2.0`, all three contain the same program:

| File | What it is | When to use it |
| --- | --- | --- |
| `mdb2sql-1.2.0-w11-amd64-zig-imgui.exe` | single executable (about 37 MB) | copy anywhere and double-click; nothing to install |
| `mdb2sql-1.2.0-w11-amd64-zig-imgui.zip` | the program folder | unzip anywhere and run `mdb2sql-zig.exe`; keep the files together |
| `mdb2sql-1.2.0-w11-amd64-zig-imgui-installer.exe` | installer (NSIS) | installs for the current user (no administrator), Start menu shortcut, uninstall in Settings > Apps |

The single executable carries the program folder compressed inside it. On its first run it extracts the folder
once to `%LOCALAPPDATA%\mdb2sql\zig-imgui-1.2.0-<hash>\` (about 110 MB, a few seconds) and starts the program
from there; the next runs start at once. Older `zig-imgui-*` folders there are deleted automatically (other
programs' folders in `%LOCALAPPDATA%\mdb2sql\` are left alone).

The program folder (zip, installer, cache) holds `mdb2sql-zig.exe`, `duckdb.dll` (DuckDB 2.0.0),
`sqlite_scanner.duckdb_extension` (DuckDB's SQLite reader, loaded from disk, never downloaded) and
`mdbtools\` (static mdbtools 1.0.1: `mdb-tables`, `mdb-schema`, `mdb-export`, with their GPL/LGPL license
files).

## Requirements

- Windows 10 or 11, 64 bits, with a graphics driver that supports OpenGL 3.3 (any normal PC; a remote desktop
  session or a virtual machine without 3D may fail to start, and then a message says so).
- Nothing else for DuckDB and SQLite files.
- Access files (`.mdb`, `.accdb`) are read, in this order:
  1. by the **Microsoft Access ODBC driver** "Microsoft Access Driver (*.mdb, *.accdb)", 64-bit, when it is
     installed (it comes with 64-bit Office or with the free "Microsoft Access Database Engine 2016
     Redistributable", x64). Optional;
  2. otherwise by the **mdbtools** that ship with the program (no installation);
  3. if neither is available (for example the `mdbtools` folder was deleted), a message tells what to install.

  The status line says which way was used ("opened with Access ODBC" or "opened with mdbtools").
  `MDB2SQL_ACCESS_READER=odbc` or `=mdbtools` forces one of them (`auto` or unset: the order above).

## How to use

### Opening a file

- **File > Open...** (Ctrl+O) or **Browse...**: Windows dialog, filtered by database type.
- Type or paste the path in the box and press **Open** (or Enter).
- Drag the file from Explorer onto the window.
- Command line: `mdb2sql-zig.exe "C:\data\file.accdb"` (also works with the single exe and the shortcut).
- Environment variable `MDB2SQL_DB_PATH`: opened at start when no file is given on the command line.

While a file opens, the status line shows the time, a progress bar (tables converted or counted) and
**Cancel**. When it is done it shows `Loaded: <file> (<n> tables) - opened with <DuckDB | SQLite | Access ODBC |
mdbtools>`.

### Window

- **Table list** (left): every table with its row count; the box on top filters by name (same word rule as
  the searches). Click a table to load it.
- **Data** tab: 100 rows per page, **< Prev** / **Next >**, search box (Enter), click a column header to sort
  (click again: descending, again: no sort). The search runs in the database over the whole table, not only
  the page shown. **Export...** (top bar) > **Current table to CSV / Excel** exports the whole table with the
  search, filters and sort shown.
- **Columns...** (Data tab and SQL result): one check box per column, **Show all**, **Hide all** and a box to
  find a column by name; tick or untick several and close. Right-click a column header: **Hide this column**,
  **Columns...**, **Show all**. Hidden columns last until another table, result or file is loaded; the line
  above the grid says `N columns hidden`. The search still looks at every column and exports still write
  every column.
- **Filter by this value** (right-click a cell of the Data tab): adds `column = value` to the database query
  (exact text as shown; a NULL cell filters `IS NULL`), so it finds rows beyond the page loaded and the row
  count and pages follow it. Several filters add up (AND) and combine with the search. Each active filter is a
  button above the grid (`SUBNAM = 'U02'  x`, click to remove it); **Clear filters** removes all. Choosing
  another table clears them. The column name is quoted and the value is a bound parameter, never SQL text.
- **Schema** tab: column, type, nullable.
- **SQL** tab: write any SQL and press **Run** (or Ctrl+Enter). The first 10,000 rows are shown; a bigger
  result says so, and its export writes all rows. The search box under the buttons filters the rows shown
  (only those 10,000 loaded rows).
- **Search rule** (Data search, SQL result search and table filter): the text is split into words; a row
  matches when one cell holds every word, in any order, ignoring case and accents. `tensao de campo` and
  `campo tensao` both find `EXCITAÇÃO TENSÃO DE CAMPO`; words found only in different cells of the row do
  not match. An empty search shows every row. The search boxes show this rule in a one-line tooltip.
  The open file is read-only: `CREATE`, `INSERT` and the like fail on it (an Access file is a copy in
  memory, so changes there are possible but are lost when another file is opened).
- Every grid: click a cell to select it, **Ctrl+C** copies the value, right-click opens **Copy value** /
  **Copy row (TAB separated)**, with the option to include the header line (Data tab: also **Filter by this
  value** and **Clear filters**). A copied row pastes into one Excel row.
- Long work (opening, loading a table, SQL, export) runs in the background: the window stays responsive and
  **Cancel** stops it.

### Menus

- **File**
  - **Open...** (Ctrl+O).
  - **Export** (also the **Export...** button next to Open):
    - **Database to DuckDB (.duckdb)...** - every table, DuckDB types.
    - **Database to SQLite (.sqlite)...** - every table.
    - **Database to Excel (.xlsx, one sheet per table)...** - sheet name = table name, made valid for Excel
      (at most 31 characters, without `\ / ? * [ ] :`, never repeated); header on row 1, frozen; numbers
      stay numbers. A table with more than 1,048,575 rows continues in sheets `<name> (2)`, `<name> (3)`...
    - **Current table / Current table schema / Current SQL result to CSV...** - UTF-8 with BOM (Excel shows
      the accents), comma separated, CRLF, quotes doubled; NULL is an empty field, empty text is `""`.
    - **... to Excel (.xlsx)...** - one sheet (split as above if needed).
    - Export to `.mdb`/`.accdb` is **not** available (there is no reliable library to write Access files).
  - **Exit**.
- **Settings > Theme**: **System** (follows the Windows light/dark setting), **Light**, **Dark**. Saved.
- **Help > About mdb2sql**: name and version, what the program does, build number and date, the stack with
  versions (Zig, Dear ImGui, GLFW + OpenGL, DuckDB), the Access reader (ODBC or mdbtools), author, license and
  two links that open in the default browser: GitHub and GitLab (only these two fixed addresses can be opened).

The save dialog opens in the folder of the open file and suggests a name (file or table name). An export first
writes `<chosen file>.part` and only replaces the chosen file when everything worked; on error or Cancel the
`.part` file is deleted and an existing file keeps its old content. The program refuses to export over the
file that is open.

### Saved settings

`%APPDATA%\mdb2sql\zig-imgui.ini`: theme and the last folder used (the dialogs start there when no file is
open). Delete it to go back to the defaults.

### Command line

```
mdb2sql-zig.exe [file] [--table NAME] [--sql "SELECT ..."] [--search TEXT] [--cell ROW,COL]
                [--theme system|light|dark] [--about] [--menu File|Settings|Help|Export] [--export KIND]
```

`--table` selects a table, `--sql` runs a statement and shows the SQL tab, `--search` fills the Data search,
`--cell ROW,COL` (from 1) selects a cell and opens its copy menu, `--theme` picks the colors for this run only,
`--about` opens About, `--menu` opens that menu, `--export db_duckdb|db_sqlite|db_xlsx|table_csv|table_xlsx|
result_csv|result_xlsx` opens the save dialog of that export. They exist for scripts and screenshots; an
unknown flag shows this text in a message box.

## Tested

On Windows 11 Pro x64 (build 26300), release build (ReleaseSafe) of this version, Zig 0.17.1,
DuckDB 2.0.0, Dear ImGui 1.93.0, GLFW 3.4, Microsoft Access ODBC driver installed. With copies of the real
NMR5 databases "2026-07-14 DB4" (287 tables, 113,962 rows; RANGER_SOSTAT 36,754 rows):

- `DB4.accdb` through Access ODBC and, forced, through mdbtools: 287 tables, 113,962 rows both ways, every
  table count equal. Conversion time (release build): 10 to 20 s with ODBC, about 75 s with mdbtools (eight
  `mdb-export` processes at a time).
- `DB4.sqlite` (about 8 s to open: the row count of 287 tables through the SQLite reader) and `DB4.duckdb`
  (about 1 s): 287 tables, RANGER_SOSTAT 36,754 rows.
- Through the real window and save dialog (driven by UI Automation): `DB4.accdb` > Export > Database to Excel;
  the dialog opened in the folder of the `.accdb` suggesting `DB4.xlsx`; 113,962 rows written in about 5 s.
- DB4 exported to `.duckdb` and `.sqlite`, reopened: 287 tables, every count equal to the source.
- DB4 exported to `.xlsx` (22 MB) and read back with openpyxl: 287 sheets; RANGER_SOSTAT 36,754,
  RANGER_SOANLG 4,460, RANGER_SOTEXT 3,516 and RANGER_SOACCU 27 data rows, numbers read as numbers.
- Search in DB4.duckdb, table RANGER_SOSTAT (36,754 rows, 123 columns): `freios supervisao` finds the 3 rows
  `SUPERVISÃO DE FREIOS UG 12 - ...` (1.1.0 found none: it looked for the whole text as one piece). Time on that
  table: about 0.15 s for one word, 0.2 to 0.4 s for two to six words. The SQL result search over 10,000 real
  rows x 123 columns takes about 10 ms per keystroke.
- Unit tests (`zig build test`, 51 plus 1 of the single-exe packer; the real-Access one runs only when `MDB2SQL_TEST_ACCDB` is set): SQL building and whitelists, paging, streaming results, sheet names and
  splitting, the xlsx zip read back by Zig's zip reader (CRC and headers checked), CSV, Access reader choice,
  Access type mapping and `mdb-schema` parsing, settings file and default dialog folder, worker thread jobs,
  cancel, and a long session (25 rounds of reopen, SQL errors, a 10-billion-row result, exports and cancels)
  with the leak-checking allocator. Search: every word in one cell, any order, case and accents
  (`EXCITACAO` finds `Excitação`), words only in different cells, empty search, invalid or cut UTF-8.

### Changes in 1.2.0

- Short window title: `mdb2sql 1.2.0 - Zig`; the details moved to Help > About, now laid out as a table with
  the stack versions and clickable GitHub and GitLab links.
- **Columns...** and the column header right-click menu hide or show several columns at once. The dialog takes
  about 65% of the window width (420 to 900 px) and up to 70% of its height, can be resized, and lays the check
  boxes out in 1 to 6 columns (4 at the default window size) with vertical scrolling only.
- Right-click a cell > **Filter by this value**: exact-value filter in the database query, shown as removable
  buttons, with **Clear filters**.
- One export action per place: the **Export CSV...** / **Export Excel...** buttons of the Data and SQL tabs
  repeated the **Export...** menu (same items) and were removed.
- Slightly smaller text: Segoe UI at 16 px instead of 17 (about 6%); the About title stays 1.4 times the text.
- Shorter texts on screen: the search boxes say only `search`, `filter tables` and `search the rows shown`
  (the word rule moved to a tooltip); the read-only note of the SQL tab and the "Export to .mdb/.accdb: not
  available" line of the Export menu were removed (the README says it).
- Nothing cut on a narrow window: the table name and row count line wraps, filter buttons move to the next line
  when they do not fit, and a table name or column header narrower than its text shows the full name as a
  tooltip. Grid columns start at the width of their header and content (no maximum width).
- Excel export fixes: a table name of 22 or more non-ASCII characters (for example Japanese) stopped the
  program while naming the sheet; sheet names are now sized for any Unicode text (characters above U+FFFF count
  as 2, as in Excel). Texts cut at 32,767 characters and columns past 16,384 are now counted and shown in the
  status line at the end of the export (they were dropped without a word).
- License: GPL v2 or later (before: proprietary, all rights reserved). `LICENSE` goes in the zip and the installer.
- Tested: unit tests for the exact filter SQL (quoted column, bound value, quotes and an injection attempt in the
  value, NULL, empty text, AND with the search, row limit) on DuckDB, SQLite and the in-memory Access copy, the
  filter list and its button label, the short title, the two allowed links and the license. Screenshots of the release
  program on a copy of DB4.duckdb: title and table, About, Columns with several hidden, an active filter.

### Changes in 1.1.1

- Search by words: the Data search, the SQL result search and the table filter split the text into words and
  find a cell that holds all of them, in any order, ignoring case and accents. Before, the whole text had to
  appear as one piece, so `tensao de campo` did not find `EXCITAÇÃO TENSÃO DE CAMPO`; the SQL result search
  and the table filter also did not ignore accents. The search hints say so.
- Program icon on the exe, the window, the single executable and the installer; the window title shows the
  version (`mdb2sql 1.1.1 - Zig + Dear ImGui`).

### Stability

The previous version could fail in these ways; 1.1.0 fixes them:

- A free SQL statement with a big result (for example a join without condition) was materialized whole in
  memory before the first 10,000 rows were shown: memory grew until the program died. Results now stream; only
  the rows shown are computed (`SELECT * FROM RANGER_SOSTAT a, RANGER_SOSTAT b`, 1.35 billion rows, shows its
  first 10,000 rows at once and memory stays flat).
- A start error (for example no OpenGL 3.3) or an internal error closed the release program without any
  message (it has no console). Both now show a message box.
- Closing the window while a file was opening waited until the whole open finished (a hang of minutes on a
  big Access file). Opening, like every other job, can now be canceled and stops between tables.
- A cancel pressed while switching databases could interrupt a connection that was being closed. The DuckDB
  connection now lives for the whole run, so Cancel is always safe.
- A failed parameter bind destroyed an uninitialized DuckDB result.
- During this work, the new Excel export crashed on the real DB4 (buffer full in the middle of a row); fixed
  before release and covered by a test with random cell sizes.

## Known limits

- Windows x64 only (only the Windows libduckdb is pinned).
- An Access file is converted entirely into memory when opened (DB4: about 350 MB of RAM with ODBC). Files of
  several GB need as much memory.
- The Access ODBC driver may create a `.laccdb` lock file next to the `.accdb` while it reads it (normal
  Access behavior); it is removed when the reading ends.
- mdbtools reads Access 97 `.mdb` text as Latin-1: characters 0x80-0x9F of Windows-1252 may come out wrong.
  Access 2000 and later files are fine.
- Opening a large SQLite file is slower than DuckDB (the row count of every table is computed when it opens).
- The single executable needs `%LOCALAPPDATA%` to be writable (it extracts there).
- The save and open dialogs are the classic Windows ones and block the window while open (running work continues).
- The SQL result search and the table filter ignore case and accents of ASCII and Latin-1 letters (á, Ç, Ñ,
  ÿ...) only; other scripts are compared as written. The Data search, done by DuckDB, covers all of Unicode.
  Copy works on one cell or one row.
- SQL tab: values are shown as text. A statement that cannot be wrapped in a `SELECT` (PRAGMA, SET, ...) runs as
  written and only text, integer, float and boolean columns are decoded; others show `(not text)`.
- An `.xlsx` sheet is limited to 4 GB of XML (no ZIP64); far beyond DB4 (whole DB4: 22 MB).
- Excel keeps at most 32,767 characters per cell and 16,384 columns per sheet: longer texts are cut and extra
  columns left out in the `.xlsx` (not in CSV/DuckDB/SQLite); the status line says how many after the export.
- Grids show at most 512 columns (Dear ImGui limit); exports write all of them.
- The GUI itself has no automated tests (Dear ImGui exposes no UI Automation tree); it was checked with
  screenshots of the release program on the real DB4 files, driven by the command line flags.

## Build

One command from a clean clone (downloads the pinned tools, builds, tests, makes the three files):

```powershell
pwsh -NoProfile -File build_w11_amd64.ps1   # -> dist\w11\amd64\
```

Everything about building, products, folders and cleaning: [README-BUILD.txt](README-BUILD.txt).

## Dependencies

| Dependency | Version | Use | How it is pinned |
|---|---|---|---|
| [Zig](https://ziglang.org) | 0.17.1 | compiler | sha256 in `scripts/setup_tools.ps1` |
| [Dear ImGui](https://github.com/ocornut/imgui) | 1.93.0 docking, commit `6d32174` | UI, GLFW and OpenGL3 backends | hash in `build.zig.zon` |
| [cimgui](https://github.com/cimgui/cimgui) | tag `1.93dock`, commit `2a6a93f` | C API of Dear ImGui | hash in `build.zig.zon` |
| [zglfw](https://github.com/zig-gamedev/zglfw) | commit `2450fe3` (GLFW 3.4) | window, input, OpenGL context | hash in `build.zig.zon` |
| [libduckdb](https://github.com/duckdb/duckdb/releases/tag/v2.0.0) | 2.0.0, `duckdb-shared-libs-windows-amd64.tar.gz` | database engine (`duckdb.dll`) | hash in `build.zig.zon` |
| DuckDB `sqlite_scanner` extension | v2.0.0 windows_amd64 (signed by DuckDB) | SQLite read and write | sha256 in `scripts/setup_tools.ps1` |
| [mdbtools_custom](https://github.com/mauriciomenon/mdbtools_custom/releases/tag/win-static-1.0.1) | 1.0.1 static, `mdbtools-1.0.1-w11-amd64.zip` | Access reader without ODBC | sha256 in `scripts/setup_tools.ps1` |
| [NSIS](https://nsis.sourceforge.io) | 3.13 | installer | sha256 in `scripts/setup_tools.ps1` |

The NMR5 `.duckdb` files were written by DuckDB 2.0.0 (storage version 69); older libduckdb versions refuse them.
The DuckDB extension must be the same version as `duckdb.dll`. The Excel writer (zip + XML) and the gzip
payload of the single executable use only Zig's standard library.

## Layout

- `src/query.zig` - extension check, SQL builder with bound parameters and whitelisted identifiers, paging.
- `src/db.zig` - DuckDB C API: the program's in-memory instance, read-only `ATTACH` of the file, streaming
  results, tables, schema, page, counts.
- `src/access.zig` - Access reader: ODBC (odbc32) and mdbtools, reader choice, type mapping.
- `src/exporter.zig` - exports to DuckDB, SQLite, xlsx and CSV, with progress and cancel.
- `src/xlsx.zig` - streaming `.xlsx` writer (deflated zip, inline strings) and sheet names.
- `src/csv.zig`, `src/gridtools.zig` - CSV and TAB-separated row copy, word search (case and accent folding), right-click filters.
- `src/worker.zig` - the background jobs (open, table, page, SQL, export) and the thread slot the UI polls.
- `src/settings.zig` - saved settings, default dialog folder, Windows theme.
- `src/about.zig` - window title, About data and the two links it may open. `src/dialog.zig` - Windows open/save dialogs.
- `src/main.zig` - the GUI. `src/shim.c` - three ImGui struct fields `translate-c` cannot reach.
- `src/launcher.zig`, `src/pack.zig` - the single executable and the build tool that compresses its payload.
- `scripts/installer.nsi` - the NSIS installer. `assets/` - the program icon and its Windows resource file.

## License

GPL v2 or later (`GPL-2.0-or-later`), full text in [LICENSE](LICENSE).

Third-party parts keep their own licenses: mdbtools (in `mdbtools\`) is GPL/LGPL, DuckDB is MIT, Dear ImGui is
MIT, GLFW is zlib.
