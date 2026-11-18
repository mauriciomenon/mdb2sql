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
- The status bar says which reader opened the file: `via mdbtools`, `via Access ODBC`, `via SQLite` or `via DuckDB`.

## Use

Open a file with File > Open Database (Ctrl+O), by passing the path on the command line
(`mdb2sql.exe "C:\data\base.accdb"`), or with the environment variable `MDB2SQL_DB_PATH` and F5.

**Access files** are converted once, when opened, into a SQLite file in a temporary folder, and the program reads
from there (status bar: "Converting ... table N of M", then `... via mdbtools, converted to SQLite`). The SQLite
keeps the column types (integer, decimal, double, text, date, true/false, binary) and NULLs. A 115 MB `.accdb`
with 287 tables takes 20-35 s by mdbtools and 8-18 s by ODBC (Intel Core Ultra 7 258V, 8 cores; the time is mostly
one big table, 36,754 rows x 123 columns, in mdb-export). The source file is
never changed.
When the file is closed (File > Close Database, Ctrl+W), another file is opened or the program is closed, it asks
what to do with the converted SQLite:

- **Save SQLite...**: choose where; the default is next to the Access file, with the same name and `.sqlite`. The
  saved file is a normal SQLite database (any SQLite tool opens it; this program opens it as SQLite).
- **Delete**: the temporary file is removed.
- **Cancel** (also Esc or the window X): nothing is closed. Enter chooses Save SQLite...; cancelling the save
  dialog returns to the question.

"Remember for this session" skips the question until the program is closed. Temporary files are never left behind:
the folder of the session is removed on exit, and the folder of a session that crashed is removed at the next start
(`%TEMP%\mdb2sql-python-pyqt6\`, `/tmp/mdb2sql-python-pyqt6/` on Linux).

Left panel: list of tables with a filter box (Ctrl+T goes to the list); all words, any order, no case or accents.
Names are never cut: the panel opens as wide as the longest name (up to 35% of the window, then it scrolls).
Tabs:

- **Data** (Ctrl+1): first rows of the selected table; "Rows" in the toolbar sets how many (100 by default, 1,000,
  10,000). Click a header to sort the loaded rows (numbers sort as numbers; third click returns to the original
  order). Search box (Ctrl+F) searches the **whole table in the database**, not only the loaded rows: a row stays
  when one of its cells has all the words typed, in any order, ignoring case and accents (`tension de campo`
  finds `EXCITACIÓN TENSIÓN DE CAMPO`; words that are only in different cells do not match; `tensao` does not find
  `TENSIÓN`, there is no fuzzy match). The status bar says how many rows match
  (`Showing 25 of 25 matching rows (36,754 rows in table)`). Columns fit the header name and the longest loaded
  value, so nothing is cut with "..." (only above 1,200 px; the tooltip shows the full text; header tooltip: name
  and type).
  - **Columns...** (button above the grid): check boxes in a grid that follows the dialog width (1 to 6 per row,
    4 at the default window size), a search field on top, "Show all" / "Hide all" (only the columns the search
    shows) and "Close"; each change applies at once. With several boxes selected, checking one checks them all.
    Right-click on a column header: "Hide this column", "Columns...", "Show all". The status bar shows
    "N hidden columns". Hidden columns last until another table or file is selected. Search still looks at every
    column and exports still write every column.
  - **Filter by This Value** (right-click on a cell, or Edit menu): only the rows where that column has exactly that
    value (an empty NULL cell filters `IS NULL`), in the database query. Several filters add up (AND) and combine
    with the search. Each active filter is a button above the grid (`SUBNAM = 'U02' ×`, click to remove it);
    "Clear Filters" removes all. Selecting another table clears them. Exports are not filtered.
- **Schema** (Ctrl+2): columns, types and nullability.
- **SQL** (Ctrl+3): free SQL (DuckDB dialect) over the open database, run with Ctrl+Enter or Run. Shows up to
  the "Rows" limit. Table names with spaces or symbols go in double quotes: `SELECT * FROM "My Table"`.

Menus:

- **File**: Open Database, Reload (F5), Close Database (Ctrl+W), Export (submenu, also the Export button in the
  toolbar), Quit (Ctrl+Q).
  - Database to SQLite / Database to DuckDB: every table, with its types (an Access file copies its converted
    SQLite).
  - Database to Excel (one sheet per table): sheet name = table name, cleaned of `[]:*?/\` and cut to the
    31-character Excel limit (repeated names get `~2`, `~3`); header in row 1; a table with more than 1,048,575 rows
    continues in sheets `<name> (2)`, `<name> (3)`, ...
  - Current Table/Result to CSV / to Excel: the whole current table (not only the loaded rows) or, when the SQL tab
    is open, the whole SQL result. CSV is UTF-8 with BOM, comma separated.
  - The save dialog opens in the folder of the open database (after that, the last folder used). Exports run in the
    background with a progress window; Cancel stops and deletes the partial file.
  - Writing `.mdb`/`.accdb` is not offered: there is no reliable free library that writes Access files.
- **Edit**: Copy Value (Ctrl+C), Copy Row (Ctrl+Shift+C), Copy Row with Header, Find in Table (Ctrl+F), Filter by
  This Value, Clear Filters. Copy is also on the right-click menu of every grid. Copied rows are TAB-separated:
  they paste as columns in Excel.
- **View**: Tables Panel (Ctrl+B), Log (Ctrl+L), Go to Table List (Ctrl+T), Data / Schema / SQL tabs, Run SQL.
  The **Log** panel, at the bottom (about 10% of the height, drag the edge to resize), lists the messages of the
  session with the time in a smaller fixed font (selectable, Ctrl+C, "Copy all"). It starts collapsed and keeps
  the last state; the arrow in its header and the arrow at the left of the status bar collapse and expand it. While
  it is collapsed, the status bar shows the most important message (last error in red, then last warning, then
  the last action) and the number of errors and warnings not seen yet; a click on the message opens the log.
  Right-click on the status bar: Copy (the whole message) and Log. Numeric columns and their headers are right-aligned.
- **Settings > Theme**: System, Light or Dark. **Settings > Language**: English (default), Português (Brasil),
  Español; applies when the program is reopened. Both are saved (Windows registry `HKCU\Software\MDB2SQL`,
  Linux `~/.config/MDB2SQL/MDB2SQL.conf`).
- **Help > About**: name, version, build number and date, stack and library versions, the Access reader in use
  ("Embedded mdbtools", or "Access ODBC driver (Windows); embedded mdbtools as fallback"), author, license, links.

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
- Search beyond the loaded rows, value filters, save / delete / cancel of the converted SQLite, temporary folder of
  a crashed session removed, three language catalogs with the same keys and no screen text outside them.
  103 automatic tests (pytest + pytest-qt); the real-database comparison runs with `MDB2SQL_TEST_ACCDB`.

## Known limits

- mdbtools reads an empty Access text (`""`) as NULL (mdb-export cannot tell them apart); the ODBC driver keeps `""`.
- mdbtools 1.0.1 cannot read dates before 1900 or after about 9998 (for example `1898-01-01`, `9999-01-01`):
  they become NULL. The ODBC driver reads them; Access 97 files (Jet 3, such as `nwind.mdb`) open only by mdbtools.
- Other mdbtools limits: attachment and multi-value fields are not read; on Windows the path of the
  Access file must be in the Windows ANSI code page.
- SQLite stores decimals as REAL: values with more than 15 significant digits lose the last digits (Access Currency
  up to 100 billion with 4 decimals is exact). The program shows them again as DECIMAL(p,s).
- Sort works on the loaded rows (100 by default, at most 10,000); search and filters run on the whole table.
- The SQL tab works on the open copy: on Access, the converted SQLite is read-only and new tables go to memory
  (they are not saved; they do go into an export). DuckDB and SQLite files are opened read-only.
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
(`export.py`); `src/shared/` About data, language catalogs loader (`i18n.py`), TAB copy, bundled files;
`src/resources/i18n/` the three catalogs; `tests/`; `mdb2sql.spec` PyInstaller spec; `scripts/` build steps and
`installer.nsi`.

## Licenca

Licenca: GPL v2 ou posterior (`GPL-2.0-or-later`, text in [LICENSE](LICENSE); the zip, the installed folder and the
`.deb` carry it).

Third-party parts keep their own licenses: Qt and PyQt6, DuckDB, XlsxWriter, pyodbc, and mdbtools (GPL/LGPL,
license files inside the program, folder `mdbtools`, run as a separate program).
