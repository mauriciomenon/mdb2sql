# MDB2SQL (Python + PyQt6)

Windows desktop program that opens Microsoft Access (`.mdb`, `.accdb`), SQLite (`.sqlite`, `.sqlite3`)
and DuckDB (`.duckdb`, `.db`) databases read-only, shows tables, schema and data, runs SQL, and exports
the whole database to DuckDB, SQLite or Excel (one sheet per table), or the current table / SQL result
to CSV or Excel. Version 1.1.1.

## Download: which file

Release `python_pyqt6-v1.1.1`, the three files are the same program, pick one:

| File | What it is | When to use |
| --- | --- | --- |
| `mdb2sql-1.1.1-w11-amd64-python-pyqt6.exe` | Single exe. Double-click, nothing to install. At every start it unpacks itself into a temporary folder (a few seconds) and removes it on exit. | Try it, run from a USB stick or a shared folder. |
| `mdb2sql-1.1.1-w11-amd64-python-pyqt6.zip` | The app folder (`mdb2sql.exe` + `_internal\`). Unzip anywhere, run `mdb2sql.exe`. Starts faster than the single exe. | Daily use without installing. |
| `mdb2sql-1.1.1-w11-amd64-python-pyqt6-installer.exe` | Installer for the current user (no administrator): `%LOCALAPPDATA%\Programs\MDB2SQL (Python + PyQt6)`, Start menu shortcut, uninstaller in Settings > Apps. | Daily use, installed like any program. |

Windows may show SmartScreen ("Windows protected your PC") because the files are not signed:
More info > Run anyway.

## Requirements

- Windows 10/11, 64 bits (amd64). Nothing else for DuckDB and SQLite files.
- Access files are read in this order:
  1. the Microsoft Access ODBC driver "Microsoft Access Driver (*.mdb, *.accdb)", 64 bits, if installed
     (it comes with 64-bit Office, or with the free
     [Microsoft Access Database Engine 2016 Redistributable](https://www.microsoft.com/download/details.aspx?id=54920), x64);
  2. otherwise mdbtools 1.0.1 (static build, inside the program). No installation needed. On first use it is
     copied to `%LOCALAPPDATA%\mdb2sql\python-pyqt6-<version>\mdbtools\` (older versions of that folder are deleted).
  To force one of them: environment variable `MDB2SQL_ACCESS_READER=odbc` or `MDB2SQL_ACCESS_READER=mdbtools`.
- The status bar says which reader opened the file: `via DuckDB`, `via SQLite`, `via Access ODBC` or `via mdbtools`.

## Use

Open a file with File > Open Database (Ctrl+O), by passing the path on the command line
(`mdb2sql.exe "C:\data\base.accdb"`), or with the environment variable `MDB2SQL_DB_PATH` and F5.
Access files are copied into memory (DuckDB) when opened; the status bar shows "Converting ... table N of M".
A 115 MB `.accdb` with 287 tables takes about 10-15 s by ODBC and 30-40 s by mdbtools.
The source file is never changed.

Left panel: list of tables with a filter box (Ctrl+L goes to the list); the filter works like the search below.
Tabs:

- **Data** (Ctrl+1): first rows of the selected table; "Rows" in the toolbar sets how many (100 by default, 1,000,
  10,000). Click a header to sort (numbers sort as numbers; third click returns to the original order). Search box
  (Ctrl+F) filters the loaded rows: a row stays when one of its cells has all the words typed, in any order,
  ignoring case and accents (`tensao campo` finds `EXCITAÇÃO TENSÃO DE CAMPO`; words that are only in different
  cells do not match). Long values are cut at 320 px; the tooltip shows the full text.
- **Schema** (Ctrl+2): columns, types and nullability.
- **SQL** (Ctrl+3): free SQL (DuckDB dialect) over the open database, run with Ctrl+Enter or Run. Shows up to
  the "Rows" limit. Table names with spaces or symbols go in double quotes: `SELECT * FROM "My Table"`.

Menus:

- **File**: Open Database, Reload (F5), Export (submenu, also the Export button in the toolbar), Quit (Ctrl+Q).
  - Database to DuckDB / Database to SQLite: every table, with its types.
  - Database to Excel (one sheet per table): sheet name = table name, cleaned of `[]:*?/\` and cut to the
    31-character Excel limit (repeated names get `~2`, `~3`); header in row 1; a table with more than 1,048,575 rows
    continues in sheets `<name> (2)`, `<name> (3)`, ...
  - Current Table/Result to CSV / to Excel: the whole current table (not only the loaded rows) or, when the SQL tab
    is open, the whole SQL result. CSV is UTF-8 with BOM, comma separated.
  - The save dialog opens in the folder of the open database (after that, the last folder used). Exports run in the
    background with a progress window; Cancel stops and deletes the partial file. Exporting the whole DB4 example
    takes ~5 s to DuckDB or SQLite and ~1 min to Excel.
  - Writing `.mdb`/`.accdb` is not offered: there is no reliable free library that writes Access files.
- **Edit**: Copy Value (Ctrl+C), Copy Row (Ctrl+Shift+C), Copy Row with Header, Find in Rows (Ctrl+F). Also on the
  right-click menu of every grid. Copied rows are TAB-separated: they paste as columns in Excel.
- **View**: Tables Panel (Ctrl+B), Go to Table List (Ctrl+L), Data / Schema / SQL tabs, Run SQL.
- **Settings > Theme**: System, Light or Dark. Saved for the next start (registry `HKCU\Software\MDB2SQL`).
- **Help > Sobre**: name, version, build number and date, runtime versions, author, source link.

## Tested (2026-11-15)

Windows 11 Pro (10.0.26300) amd64, release exe built by `build_w11_amd64.ps1`, Python 3.12.16, PyQt6/Qt 6.10.0,
DuckDB 2.0.0, XlsxWriter 3.3.1, pyodbc 5.3.0, Access ODBC driver of Microsoft 365 (64 bits).
Real database "2026-07-14 DB4" (copies): 287 tables, 113,962 rows, RANGER_SOSTAT 36,754 rows.

- `.accdb` by Access ODBC and by mdbtools: same 287 tables, same types, all 6,080,691 cells identical between the
  two readers; row counts of every table equal to the `.duckdb` and `.sqlite` conversions of the same file.
- `.sqlite` and `.duckdb`: 287 tables, all counts equal.
- Export of the `.accdb` to `.duckdb`, `.sqlite` and `.xlsx`, reopened: 287 tables with equal counts; the `.xlsx`
  has 287 sheets with the right row counts.
- 54 automatic tests (pytest + pytest-qt; 52 run in every build, 2 need local data: a real `.accdb` copy in
  `MDB2SQL_TEST_ACCDB`, run here with DB4, and `data/sample.duckdb`): sheet names and split, reader order and
  forcing, export formats, cancel, default folder, theme saving, SQL tab, menus, DECIMAL display, search.
- 1.1.1 search (2026-11-16, DB4 `.duckdb` copy): `tensao energ barra` finds RANGER_SOPERM "IOPI 62 - Não energizar
  BARRA B4 com tensão maior que 525kV." (1.1.0 found nothing); on RANGER_SOSTAT, 10,000 loaded rows x 123 columns,
  the first search takes ~1 s (text prepared once per load) and each next one 40-80 ms (1.1.0: up to 12 s).
- Products checked: zip extracted, installer installed and uninstalled silently (no files, shortcut or registry key
  left); the exe, the zip folder and the installed folder have no path or name of the build machine.

## Known limits

- Search and sort work on the loaded rows only (100 by default, at most 10,000): a row beyond the "Rows" limit is
  not found. Raise "Rows" or use the SQL tab for the whole table.
- mdbtools is slower than ODBC (~20 s for a 36,000-row table) and has the mdbtools limits: Access paths with
  characters outside the Windows ANSI code page, attachment and multi-value fields are not supported.
  Binary (OLE) columns are read as bytes; in Excel and CSV they are written as hexadecimal text.
- Excel limits: text longer than 32,767 characters is cut; dates before 1900 are written as text.
- The SQL tab on an Access file works on the in-memory copy: changes made there are not saved to the `.accdb`
  (they do go into an export). DuckDB and SQLite files are opened read-only.
- The exe and the installer are not code-signed.

## Source, tests, build

Code: <https://github.com/mauriciomenon/mdb2sql>, folder `python_pyqt6/`. Prerequisite: [uv](https://docs.astral.sh/uv/).

```powershell
uv run --python 3.12 python src/main.py [database]              # run from source (after scripts\setup_tools.ps1)
$env:QT_QPA_PLATFORM='offscreen'; uv run --python 3.12 pytest -q  # tests
pwsh -NoProfile -File build_w11_amd64.ps1                        # the three products in dist\w11\amd64\
```

Commands, products, work folders and cleaning: [README-BUILD.txt](README-BUILD.txt).

Layout: `src/main.py` entry point; `src/ui/` window and table model; `src/backend/` database access
(`db_manager.py`), Access readers (`access.py`), exports (`export.py`); `src/shared/` About text, TAB copy,
bundled files; `tests/`; `mdb2sql.spec` PyInstaller spec (single exe and app folder); `scripts/` build steps and
`installer.nsi`.

License: proprietary, all rights reserved. mdbtools (GPL/LGPL, license files inside the program, folder
`mdbtools`) is run as a separate program.
