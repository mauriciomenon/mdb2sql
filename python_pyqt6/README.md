# MDB2SQL (Python + PyQt6)

Desktop program that opens Microsoft Access (`.accdb`, `.mdb`), SQLite (`.sqlite`, `.sqlite3`, `.db`) and DuckDB
(`.duckdb`) databases read-only, shows tables, schema and data, runs SQL, and exports the whole database to
SQLite, DuckDB or Excel (one sheet per table), or the current table / SQL result to CSV or Excel.
Access files open without Microsoft Access, drivers or anything else installed. Version 1.3.0.

## Download: which file

Release `python_pyqt6-v1.3.0`. Windows: the three files are the same program, pick one.

| File | What it is | When to use |
| --- | --- | --- |
| `mdb2sql-1.3.0-w11-amd64-python-pyqt6.exe` | Single exe. Double-click, nothing to install. At every start it unpacks itself into a temporary folder (a few seconds) and removes it on exit. | Try it, run from a USB stick or a shared folder. |
| `mdb2sql-1.3.0-w11-amd64-python-pyqt6.zip` | The app folder (`mdb2sql.exe` + `_internal\`). Unzip anywhere, run `mdb2sql.exe`. Starts faster than the single exe. | Daily use without installing. |
| `mdb2sql-1.3.0-w11-amd64-python-pyqt6-installer.exe` | Installer for the current user (no administrator): `%LOCALAPPDATA%\Programs\MDB2SQL (Python + PyQt6)`, Start menu shortcut, uninstaller in Settings > Apps. | Daily use, installed like any program. |
| `mdb2sql-1.3.0-debian-amd64-python-pyqt6.deb` | Debian 13 / Ubuntu package: `/opt/mdb2sql-python-pyqt6`, command `mdb2sql-python-pyqt6`, menu entry. `sudo apt install ./<file>.deb` | Debian and derivatives, amd64. |
| `mdb2sql-1.3.0-debian-amd64-python-pyqt6.zip` | The Linux app folder; unzip and run `mdb2sql`. Needs the libraries listed as `Depends` of the `.deb` (present on a desktop install). | Linux without installing. |

Windows may show SmartScreen ("Windows protected your PC") because the files are not signed:
More info > Run anyway.

## Requirements

- Windows 10/11 64 bits, or Debian 13 (or derived) amd64. Nothing else, also for Access files.
- Access files are read by mdbtools 1.0.1, inside the program (Windows: static build; Debian: the Debian
  mdbtools programs and `libmdb`). When the Microsoft Access ODBC driver "Microsoft Access Driver (*.mdb, *.accdb)"
  (64 bits, from 64-bit Office or the free Access Database Engine) is installed, it is used instead because it is
  faster. To force one: environment variable `MDB2SQL_ACCESS_READER=mdbtools` or `MDB2SQL_ACCESS_READER=odbc`.
- The right end of the status bar says how the file was read: `Opened via mdbtools, converted to SQLite`,
  `Opened via Access ODBC, converted to SQLite`, `Opened via SQLite` or `Opened via DuckDB`.

## Use

The top line holds the path of the open file (a path longer than the field shows its end, the file name) and the
buttons Open... and Export.... Open a file with Open... or File > Open... (Ctrl+O), which show the file chooser,
by typing or pasting its full path in the field and pressing Enter (or File > Open the typed path; an empty field
shows the file chooser), by dragging it onto the window, by passing the path on the command line
(`mdb2sql.exe "C:\data\base.accdb"`), or with the environment variable `MDB2SQL_DB_PATH` (opened at start). F5
(File > Reopen) opens the open file again; with no file open it shows the file chooser. A path that is not a
file, or not a full path, gives only "File not found: <path>" in the bottom bar and the Log.

**Access files** are converted once, when opened, into a SQLite file in a temporary folder, and the program reads
from there (status bar: "Converting ... table N of M", then `Loaded: <file> (N tables)`; the right end says
`Opened via mdbtools, converted to SQLite`). The SQLite
keeps the column types (integer, decimal, double, text, date, true/false, binary) and NULLs. A 115 MB `.accdb`
with 287 tables takes 20-35 s by mdbtools and 8-18 s by ODBC (Intel Core Ultra 7 258V, 8 cores; the time is mostly
one big table, 36,754 rows x 123 columns, in mdb-export). The source file is
never changed. The temporary folder is the user one (`%TEMP%`), else the system one (`%SystemRoot%\Temp`, `/tmp`),
last the folder of the Access file: the first where a file can be created (subfolder `mdb2sql-python-pyqt6`).

**File > Save** (Ctrl+S) and **Save as...** (Ctrl+Shift+S) write the open database, whatever its format, to SQLite,
DuckDB or Excel (one sheet per table). The native dialog opens with the name of the original and the type of the
open file already chosen (Access -> SQLite); Save starts in the folder of the original, Save as... in the last
folder used to save or export. The open file and the converted temporary file are refused as targets. `.mdb` and
`.accdb` files cannot be written: the Access format is proprietary to Microsoft. An Access file saved to SQLite or
DuckDB is remembered in the settings with the path, size and date of both files: opening the same Access file again
opens the saved file at once, also in later runs; if either file changed, the Access file is converted again.

Closing the file (File > Close, Ctrl+W), opening another one or F5 never asks: a converted SQLite that was not saved
is deleted and the Log says `SQLite converted from <file> discarded`. Only exiting the program (X, File > Exit,
Ctrl+Q, Alt+F4) with an unsaved conversion asks "Save" (the save dialog; cancelled, the question comes back),
"Back" or "Exit" (Esc and the X of the question = Back). Exiting during an export asks first: Back, or Exit, which
cancels the export (no half-written file). Temporary files are never left behind: the folder of the session is
removed on exit, and the leftovers of a session that crashed are removed at the next start, with a Log line.

Left panel: list of tables with the row count of each one (Table | Rows), and a filter box (Ctrl+T goes to the
list); all words, any order, no case or accents, applied 300 ms after the last key or at once with Enter.
Names are never cut: the panel opens as wide as the longest name (up to 35% of the window, then it scrolls).
Favorite tables (right-click on a table > Add to favorites / Remove from favorites, or View > Favorite or unfavorite
table, Ctrl+D, for the current one) stay at the top in alphabetical order, marked `★ `; they are kept by name while
the program is open (closing, opening another file and F5 keep them; nothing is saved).
Tabs:

- **Data** (Ctrl+1): first rows of the selected table. Click a header to sort the loaded rows (numbers sort as
  numbers; third click returns to the original order). One line above the grid holds the search field (Ctrl+F),
  "This table | All tables" (All tables by default), "Rows" (rows loaded from the table and from the SQL result: 100 by default, 500,
  1000) and Columns...; in a narrow window it wraps to a second line. The
  search runs 300 ms after the last key, or at once with Enter, over the **whole table in the database**, not only
  the loaded rows: a row stays when one of its cells has all the words typed, in any order, ignoring case and
  accents (`tension de campo` finds `EXCITACIÓN TENSIÓN DE CAMPO`; words that are only in different cells do not
  match; `tensao` does not find `TENSIÓN`, there is no fuzzy match). "All tables" lists the tables with matching
  rows as `table (n)`; choosing one opens it with the same search and no value filter. The table is shown in
  pages of "Rows" lines: the line under the grid says `RANGER_SOSTAT: rows 1 to 100 of 36,804` (with a search
  or value filter: `... of 25 found`) and has the previous / next page buttons, disabled at the ends. A new
  search, filter, Rows value or table goes back to page 1.
  Columns fit the header name and the longest loaded value, so nothing is cut with "..." (only above 1,200 px; the
  tooltip shows the full text; header tooltip: name and type).
  - **Columns...**: check boxes in a grid that follows the dialog width (1 to 6 per row,
    4 at the default window size), a filter field on top, "Show all" / "Hide all" (only the columns the filter
    shows) and "Close"; each change applies at once; one column always stays visible. With several boxes selected,
    checking one checks them all. Right-click on a column header: "Size column to fit", "Size all columns to fit",
    "Hide this column", "Columns...", "Show all columns" (only with a hidden column) and the list of the columns
    with a check mark. The right end of the status bar shows "N hidden columns". Hidden columns last until another
    table or file is selected. Search still looks at every column and exports still write every column.
  - **Filter by this value** (right-click on a cell, or Edit menu): only the rows where that column has exactly that
    value (an empty NULL cell filters `IS NULL`), in the database query. Several filters add up (AND) and combine
    with the search. Each active filter is a button in a line above the grid (`SUBNAM = 'U02' ×`, click to remove
    it); "Clear filters" removes all. Selecting another table clears them.
  - **Marked rows**: the first column of the grid is a check box per row (click it, Space on the current row, the
    cell menu or Edit > Mark or unmark row). Marks are kept per table while the file is open (Close, opening another
    file and F5 clear them). Marked rows always stay at the top of the grid, in table order, whatever the search,
    the value filters or the scope; the rows of the current search follow without repeats (a newly marked row moves
    to the top at the next query). The line under the grid adds `, N marked` and, only with marks, the "Only
    marked" box (= View > Only marked rows). Export > Marked rows and the cell menu export them (all columns, table
    order, `<table>_marcadas`). A row is identified by the engine rowid (DuckDB and SQLite tables, also the
    converted Access); in a view or a SQLite `WITHOUT ROWID` table by all its values, so identical rows mark
    together.
- **Schema** (Ctrl+2): columns, types and nullability (Yes / No), 6 px more on each side of the text.
- **SQL** (Ctrl+3): SQL (DuckDB dialect) over the open database, run with Ctrl+Enter or Run. Only reading commands
  run (SELECT/WITH, SHOW, DESCRIBE, EXPLAIN, SUMMARIZE, reading PRAGMA, by the DuckDB statement type); anything else
  is refused before it runs ("The SQL tab only reads the database"), so the file, the converted copy and the memory
  never change. Shows up to
  the "Rows" limit. Table names with spaces or symbols go in double quotes: `SELECT * FROM "My Table"`. The line of
  the Run button shows the result (`SQL result: 3 rows`) or the error; an error clears the previous result, and the
  next query that works clears the error there and in the status bar.
- **Advanced Search** (Ctrl+4): paste a list of terms (one per line, for example an Excel column), choose "Whole value |
  Contains" (default in Settings > Term matching) and "This table | All tables" (it always starts in All tables;
  with This table the summary ends with `(only in <table>)`), and Search terms (Ctrl+Enter in the tab). Every column of every table is compared as text: whole value = the cell without spaces at the ends is
  the term; contains = the cell contains it; case does not count. Empty lines are skipped and a repeated term is
  searched once (`8 terms, 2 repeated`); a header pasted from Excel is a term like any other. The search runs in
  the database engine with progress and Cancel, then shows `X of Y terms found: N rows in M tables`, the tables with
  hits as `table (n)` and the grid of the chosen one: the columns of the table (names, order and types as in the
  table, nothing added), each row found once, in the order of the first term that found it and then of the
  table, limited by "Rows". The terms not found are listed below, one per line, with Copy. Right-click on the
  grid: the three copy items, Copy the rows found in this table (with header, TAB separated, pastes into Excel as
  exactly the found rows) and the report (Excel, CSV folder, SQLite or DuckDB: one sheet/table/file per table
  with hits, named after it, with the rows found; name `<database> - Advanced Search.xlsx`, in Portuguese
  `<banco> - Pesquisa Avançada.xlsx`). In Whole value, numbers match loosely: a term and a cell that read as numbers match when
  a reading of one equals a reading of the other (216 finds 216.0, 216,0 and "216"; 1234.5 finds "1.234,5";
  never 2160 or 216.5). DB3 (287 tables), a list of 9 terms, whole value, all tables: 6.8 s on the
  SQLite file, 3.6 s on the DuckDB file.

Menus:

- **File**: Open... (Ctrl+O, = the Open... button), Open the typed path (= Enter in the path), Reopen (F5), Save (Ctrl+S), Save as...
  (Ctrl+Shift+S), Export (submenu, also the Export... button at the top), Close (Ctrl+W), Exit (Ctrl+Q).
- **Export** (a fixed list; what does not apply is disabled): Current table, Marked rows, Current table schema
  (Column, Type, Nullable; `<table>_schema`), Database schema (Table, Column, Type, Nullable; `<database>_schema`),
  each to CSV or Excel; All tables to CSV (a folder, `<table>.csv` each; files that already exist: one question);
  SQL result to CSV or Excel; All-tables search result (Excel: one sheet per table with hits, the rows the search
  finds; `<database>_busca`); Advanced Search report (see Advanced Search).
  - Excel: sheet name = table name, cleaned of `[]:*?/\` and cut to the 31-character Excel limit (repeated names
    get `~2`, `~3`); header in row 1; a table with more than 1,048,575 rows continues in sheets `<name> (2)`, ...
  - Current table: the whole current table (not only the loaded rows). When the grid shows part of the
    table (a search or a value filter) it asks first: "Whole table" or "Only the N rows found" (the rows the grid counts, value filters included).
  - SQL result: the whole result of the last query that ran; default name `query.csv` /
    `query.xlsx`. CSV is UTF-8 with BOM, comma separated.
  - The save dialog opens in the folder of the open database (after that, the last folder used). Exports run in the
    background with a progress window; Cancel stops and deletes the partial file.
- **Edit**: Copy value (Ctrl+C), Copy row (Ctrl+Shift+C), Copy row with header, Copy the whole log, Search (Ctrl+F),
  Filter by this value, Clear filters, Mark or unmark row (Space), Unmark all rows. Right-click on a cell of the
  Data grid: Filter by this value and Clear filters first, then the three copy items, then the mark items and
  Export marked rows (the other grids: copy only). Copied rows are TAB-separated: they paste as columns in Excel.
- **View**: Data / Schema / SQL / Advanced Search tabs (Ctrl+1 to Ctrl+4), Rows (100 / 500 / 1000), Columns..., Search in
  (This table / All tables), Only marked rows, Go to the table list (Ctrl+T), Run SQL (Ctrl+Enter), Search terms
  (Ctrl+Enter in the Advanced Search tab), Log (Ctrl+L). The tables panel cannot be closed.
  The **Log** panel, at the bottom (about 10% of the height, drag the edge to resize), lists the messages of the
  session with the time, in the app font like the rest of the window (selectable, Ctrl+C, "Copy all"). It always starts collapsed; the arrow in its header and the arrow at the left of the status bar collapse and expand it. While
  it is collapsed, the status bar shows the most important message (last error in red, then last warning, then
  the last action) and, at its right end, the number of errors and warnings not seen yet; a click on the message
  opens the log. Right-click on the status bar: Copy (the whole message) and Log. Numeric columns and their headers
  are right-aligned.
- **Settings**: Theme (System, Light or Dark; switching changes the whole window), Language (English by default,
  Português (Brasil), Español; applies at once), Default search scope (All tables by default, or This table;
  the Data tab only), Term matching (Whole value or Contains) and Show NULL
  (off by default: a NULL cell is empty). All are saved (Windows registry `HKCU\Software\MDB2SQL`,
  Linux `~/.config/MDB2SQL/MDB2SQL.conf`; with the environment variable `MDB2SQL_SETTINGS=<file.ini>`, in that file).
- **Help > About mdb2sql**: name, version, Build (number and date), Stack (Python and PyQt6 versions), Window (Qt
  version), Databases (SQLite and DuckDB versions), Access reading ("Embedded mdbtools 1.0.1", or "Access ODBC
  driver (installed); fallback: embedded mdbtools 1.0.1"), Writing (SQLite, DuckDB, Excel and CSV; `.mdb` and
  `.accdb` cannot be written), Author, License, links.

The window title is short, `mdb2sql 1.3.0 - Python` (with a file open, `<file> - mdb2sql 1.3.0 - Python`).
Changes of each version: [CHANGELOG.md](CHANGELOG.md).

## Linux: X11 e Wayland

On Linux the program uses X11 (Qt `xcb`) and falls back to Wayland only when X11 cannot start. In that case a
"Display mode" warning appears at every start (also in View > Log) naming what is missing and the install command
for the distribution. A `QT_QPA_PLATFORM` set by the user is always respected and gives no warning. With neither
X11 nor Wayland the program prints the reason on stderr and exits with code 1.

The package carries Qt, `libX11`, `libxcb-cursor` and the other xcb helper libraries; X11 still needs these from
the system:

| Needed | Debian / Ubuntu (apt) | Fedora / RHEL (dnf) | Arch (pacman) | openSUSE (zypper) |
| --- | --- | --- | --- | --- |
| X server in a Wayland session (`DISPLAY`) | `xwayland` | `xorg-x11-server-Xwayland` | `xorg-xwayland` | `xwayland` |
| `libxcb.so.1` | `libxcb1` | `libxcb` | `libxcb` | `libxcb1` |
| `libGL.so.1` | `libgl1` | `libglvnd-glx` | `libglvnd` | `libGL1` |
| `libEGL.so.1` | `libegl1` | `libglvnd-egl` | `libglvnd` | `libEGL1` |

Other distributions: the warning lists the missing libraries without a command.

## Tested (2026-11-18)

Windows 11 Pro (10.0.26300) amd64, Python 3.12.16, PyQt6/Qt 6.10.0, DuckDB 2.0.0, SQLite 3.53.1; Debian 13 (WSL).
Copies of two real databases ("2026-07-14 DB4" and "2026-06-25 DB3 1", 287 tables each) and the conversions of
the same files made by another converter as reference.

- DB4 and DB3 `.accdb`, by mdbtools and by Access ODBC: 287 tables each, 113,962 rows (DB4) and 113,826 rows (DB3),
  every table with the same row count as the reference SQLite; all cells identical between the two readers.
  Release exe on DB4 by mdbtools: "tension de campo" in RANGER_SOSTAT (36,754 rows) finds the only match, row 18,148.
- Public files of the mdbtools project (mdbtestdata): `nwind.mdb` (Access 97: 9 tables, 4,032 rows, mdbtools only),
  `ASampleDatabase.accdb` (both readers identical), `DateTestDatabase.mdb` (dates before 1900 and year 9999: see
  Known limits).
- Generated `tests/data/sample.mdb` (versioned, made by `tests/data/make_sample_mdb.py`): integer, Byte, Integer,
  Currency (exact `18.0000`, `12.3456`), Double, text with accents, quotes and line breaks, dates, Yes/No, binary
  (empty and NULL), NULL, a table name with spaces; read by both readers, also on Debian.
- Search beyond the loaded rows, value filters, Save / Save as, the exit question, marked rows, the term search
  (whole value, contains, case, spaces, repeats, list order, not found), the read-only SQL tab, the temporary
  folder fallback, the menu tree, three language catalogs with the same keys and no screen text outside them.
  192 automatic tests (pytest + pytest-qt); the real-database comparison runs with `MDB2SQL_TEST_ACCDB`.
- 2026-11-26: copies of DB3 (`.accdb`, and its `.sqlite` and `.duckdb` conversions), a list of 9 terms,
  whole value, all tables: RANGER_SOSTAT 8 rows (RTUNO 50, PNTNO 238, 242, 254, 256, 260, 304, 308, 2190, SUBNAM
  U9A) in the order of the list, RANGER_SOEQID 8 rows, `PNTNAM` not found; contains adds RANGER_SOTEXT (72 rows of
  `PNTNAM`).

## Known limits

- mdbtools reads an empty Access text (`""`) as NULL (mdb-export cannot tell them apart); the ODBC driver keeps `""`.
- mdbtools 1.0.1 cannot read dates before 1900 or after about 9998 (for example `1898-01-01`, `9999-01-01`):
  they become NULL. The ODBC driver reads them; Access 97 files (Jet 3, such as `nwind.mdb`) open only by mdbtools.
- Other mdbtools limits: attachment and multi-value fields are not read; on Windows the path of the
  Access file must be in the Windows ANSI code page.
- SQLite stores decimals as REAL: values with more than 15 significant digits lose the last digits (Access Currency
  up to 100 billion with 4 decimals is exact). The program shows them again as DECIMAL(p,s).
- Sort works on the loaded rows (100 by default, at most 1000); search and filters run on the whole table.
- Every file is opened read-only and the SQL tab only reads: changes are made in a saved copy with another tool.
- Excel limits: text longer than 32,767 characters is cut; dates before 1900 are written as text.
- The Windows exe and installer are not code-signed. macOS, Arch and BSD builds are not provided in this version.

## Source, tests, build

Code: <https://github.com/mauriciomenon/mdb2sql>, folder `python_pyqt6/`. Prerequisite: [uv](https://docs.astral.sh/uv/).

```powershell
pwsh -NoProfile -File scripts\setup_tools.ps1                     # once: Python, mdbtools, sqlite extension, NSIS
uv run --python 3.12 python src/main.py [database]              # run from source
$env:QT_QPA_PLATFORM='offscreen'; uv run --python 3.12 pytest -q  # tests
pwsh -NoProfile -File build_w11_amd64.ps1                        # Windows products in dist\w11\amd64\
pwsh -NoProfile -File build_debian_amd64_wsl.ps1                 # Debian products (WSL) in dist\debian\amd64\
```

Commands, products, work folders and cleaning: [README-BUILD.txt](README-BUILD.txt).

Layout: `src/main.py` entry point; `src/ui/` window, dialogs and table model; `src/backend/` database access
(`db_manager.py`), Access to SQLite conversion (`access.py`), session temporary folder (`temp_store.py`), exports
(`export.py`), term search (`terms.py`); `src/shared/` About data, language catalogs loader (`i18n.py`), TAB copy, bundled files;
`src/resources/i18n/` the three catalogs; `tests/`; `mdb2sql.spec` PyInstaller spec; `scripts/` build steps and
`installer.nsi`.

## Licenca

Licenca: GPL v2 ou posterior (`GPL-2.0-or-later`, text in [LICENSE](LICENSE); the zip, the installed folder and the
`.deb` carry it).

Third-party parts keep their own licenses: Qt and PyQt6, DuckDB, XlsxWriter, pyodbc, and mdbtools (GPL/LGPL,
license files inside the program, folder `mdbtools`, run as a separate program).
