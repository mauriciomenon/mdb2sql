# MDB2SQL (Zig + Dear ImGui)

Desktop program to open Microsoft Access (`.accdb`, `.mdb`), SQLite (`.sqlite`, `.sqlite3`, `.db`) and DuckDB
(`.duckdb`) databases, browse and search their tables, run SQL, and export them to SQLite, Excel (`.xlsx`, one sheet
per table), CSV and DuckDB. Written in Zig with Dear ImGui (GLFW + OpenGL 3.3) and the DuckDB C API. Version
**1.3.0**. Windows 10/11 x64 and Debian 13 amd64. English (default), Portuguese (Brazil) and Spanish.

The file you open is never changed. An Access file is read once, without Microsoft Access, by the **mdbtools that
ship with the program**, and converted into a SQLite file; the program then reads that SQLite file. SQLite and DuckDB
files are attached read-only.

## Which file to download

Release `zig_imgui-v1.3.0`; every file holds the same program:

| File | What it is | When to use it |
| --- | --- | --- |
| `mdb2sql-1.3.0-w11-amd64-zig-imgui.exe` | single executable (Windows) | copy anywhere and double-click; nothing to install |
| `mdb2sql-1.3.0-w11-amd64-zig-imgui.zip` | the program folder (Windows) | unzip anywhere and run `mdb2sql-zig.exe`; keep the files together |
| `mdb2sql-1.3.0-w11-amd64-zig-imgui-installer.exe` | installer (NSIS) | installs for the current user (no administrator), Start menu shortcut, uninstall in Settings > Apps |
| `mdb2sql-1.3.0-debian-amd64-zig-imgui.deb` | Debian package | `sudo apt install ./mdb2sql-1.3.0-debian-amd64-zig-imgui.deb`; command `mdb2sql-zig`, menu entry |
| `mdb2sql-1.3.0-debian-amd64-zig-imgui.zip` | the program folder (Linux) | unzip and run `mdb2sql-zig`; needs the runtime packages listed below |

The single executable carries the program folder compressed inside it. On its first run it extracts the folder
once to `%LOCALAPPDATA%\mdb2sql\zig-imgui-1.3.0-<hash>\` and starts the program from there; the next runs start at
once. Older `zig-imgui-*` folders there are deleted automatically.

The program folder holds `mdb2sql-zig(.exe)`, the DuckDB 2.0.0 library (`duckdb.dll` / `libduckdb.so`),
`sqlite_scanner.duckdb_extension` (DuckDB's SQLite reader and writer, loaded from disk, never downloaded) and
`mdbtools/` (mdbtools 1.0.1 built statically: `mdb-tables`, `mdb-schema`, `mdb-export`, with their GPL/LGPL license
files). Nothing else is needed to open Access files.

## Requirements

- Windows 10 or 11, 64 bits, or Debian 13 amd64, with a graphics driver that supports OpenGL 3.3 (a remote desktop
  session or a virtual machine without 3D may fail to start, and then a message says so).
- Debian: the `.deb` pulls in what the program loads at run time: `libgl1`, `libx11-6`, `libxrandr2`,
  `libxinerama1`, `libxcursor1`, `libxi6` (GLFW), `zenity` (open and save dialogs), `xdg-utils` (links in About),
  `fonts-dejavu-core` (text with accents), plus `libc6`, `libstdc++6` and `libgcc-s1` found by `dpkg-shlibdeps`.
  With the `.zip`, install those packages yourself.
- Access files (`.accdb`, `.mdb`), in this order:
  1. on Windows, the **Microsoft Access ODBC driver** "Microsoft Access Driver (*.mdb, *.accdb)", 64-bit, when it is
     installed (64-bit Office or the free "Microsoft Access Database Engine 2016 Redistributable"). Optional and
     faster (DB4: about 17 s instead of about 87 s);
  2. otherwise the **mdbtools** that ship with the program (no installation, no driver, nothing from the computer);
  3. if neither is available (the `mdbtools` folder was deleted), a message says so.

  `MDB2SQL_ACCESS_READER=mdbtools` forces mdbtools (also on a computer with the ODBC driver), `=odbc` forces ODBC,
  `auto` or unset: the order above. The status line says which way was used.

## Access files: one conversion to SQLite

Opening an `.accdb`/`.mdb` converts every table once into a temporary SQLite file in `<TEMP>/mdb2sql-zig/` and the
program reads that file (the status line says `read with mdbtools, converted to SQLite`). Types are kept as SQLite
stores them: integers (`Byte`, `Integer`, `Long Integer`, `Numeric (p, 0)` up to 18 digits) as INTEGER, `Single`,
`Double` and `Numeric` up to 15 digits as REAL (exact for that many digits), `Currency` and longer `Numeric` as exact
decimal text (`19.9900`), dates as ISO text (`2026-07-14 10:30:00`), Yes/No as 0/1, OLE/binary as BLOB, text as TEXT;
NULL stays NULL.

When the file is closed (**File > Close**), another file is opened, or the program exits, a short dialog asks what to
do with that SQLite file:

- **Save...** - save dialog, by default next to the source file as `<source>.sqlite`;
- **Delete** - the temporary file is deleted;
- **Cancel** - nothing is closed (the program stays open).

The first answer is remembered until the program closes (a remembered **Save** writes into the same folder; if that
name already exists the save dialog opens). Temporary files are never left behind: they are deleted on **Delete**,
and if the program crashes, the next start deletes the temporaries of programs that are no longer running.

## How to use

### Opening a file

- **File > Open...** (Ctrl+O) or **Browse...**: open dialog filtered by type (Access first, then SQLite and DuckDB);
  Windows dialog on Windows, `zenity` on Linux.
- Type or paste the path in the box and press **Open** (or Enter). Drag the file onto the window.
- Command line: `mdb2sql-zig "C:\data\file.accdb"`; environment variable `MDB2SQL_DB_PATH` when no file is given.

While a file opens, the status line shows the time, a progress bar (tables converted or counted) and **Cancel**.

### Window

- **Table list** (left): every table with its row count, the whole name shown (the panel starts as wide as the
  longest name, up to 40% of the window, and scrolls sideways beyond that); the box on top filters by name.
- **Data** tab: 100 rows per page, **< Prev** / **Next >**, search box (Enter), click a column header to sort.
  The search runs in the database over the **whole table** (every column), for Access, SQLite and DuckDB alike, before
  the paging: the row count and pages follow it.
- **Columns...** (Data tab and SQL result): one check box per column, a box to find a column by name, **Show all** and
  **Hide all** (with text in the find box they act only on the columns listed). Right-click a column header:
  **Hide this column**, **Columns...**, **Show all**. Hidden columns are still searched and exported.
- **Filter by this value** (right-click a cell of the Data tab): exact `column = value` filter in the database
  query; several add up (AND) and combine with the search; each is a button above the grid (click to remove).
- **Schema** tab: column, type, nullable. **SQL** tab: any SQL, **Run** (Ctrl+Enter), first 10,000 rows shown.
- **Search rule**: the text is split into words; a row matches when one cell holds every word, in any order,
  ignoring case and accents (`Tensión campo` finds `EXCITACION TENSION DE CAMPO`; `tensao` does not: there is no
  fuzzy matching).
- A NULL cell is shown empty (as in the other stacks); copy gives an empty value.
- Every grid: click a cell, **Ctrl+C** copies it, right-click: **Copy value** / **Copy row (TAB separated)**.
- Long work runs in the background with **Cancel**.

### Menus

- **File**: **Open...**, **Export** (also the **Export...** button): **Database to SQLite**, **Database to Excel**
  (one sheet per table), **Database to DuckDB**, **Current table / schema / SQL result to CSV or Excel**; **Close**;
  **Exit**. Export to `.accdb`/`.mdb` is not available (no reliable library writes Access files).
- **View > Log** (Ctrl+L): every message of the session with its time; select and Ctrl+C, or **Copy all**,
  **Clear**. Right-click the status line: **Copy** (the whole text) or **Log**.
- **Settings > Theme**: System, Light, Dark. **Settings > Language**: English, Português (Brasil), Español. Both are
  saved and apply at once, without restarting.
- **Help > About mdb2sql**: version, build, stack, Access reader, license and the GitHub and GitLab links.

### Saved settings

Windows: `%APPDATA%\mdb2sql\zig-imgui.ini`; Linux: `~/.config/mdb2sql/zig-imgui.ini` (`$XDG_CONFIG_HOME` if set).
Theme, language and the last folder used.

### Command line

```
mdb2sql-zig [file] [--table NAME] [--sql "SELECT ..."] [--search TEXT] [--cell ROW,COL]
            [--theme system|light|dark] [--lang en|pt_br|es] [--about] [--menu File|View|Settings|Help|Export]
            [--export KIND]
```

The flags set the start state (for scripts and screenshots); `--theme` and `--lang` apply to this run only.

## Tested

Windows 11 Pro x64 (build 26300) and Debian 13 (WSL 2), Zig 0.17.1, DuckDB 2.0.0, Dear ImGui 1.93.0, GLFW 3.4.
Databases used: COPIES of the real NMR5 files `2026-07-14 DB4.accdb` and `2026-06-25 DB3 1.accdb`, `nwind.mdb` from
the public mdbtools test data, and the small `testdata/mdb2sql_test.mdb` kept in this folder.

- `DB4.accdb` through mdbtools (forced) and through Access ODBC: 287 tables, 113,962 rows both ways, and every table
  name and row count equal to the reference conversion (`2026-07-14 DB4.sqlite`, made by the owner's
  pandas/pyodbc converter): 0 differences. Conversion to SQLite: about 87 s with mdbtools, about 17 s with ODBC.
  The converted file exported again to `.duckdb` and `.sqlite` and reopened: every count equal. Row counts of the
  287 tables after the conversion: 0.7 s (8.7 s before, through DuckDB's SQLite reader).
- `DB3 1.accdb` through mdbtools: 287 tables, 113,826 rows, every name and count equal to its reference
  (`2026-06-25 DB3 1.sqlite`): 0 differences; conversion about 105 s.
- Whole-table search on the converted DB4 (RANGER_SOSTAT, 36,754 rows): `tension de campo` finds the one row
  `EXCITACION TENSION DE CAMPO`, which is not on the first page; `tensao de campo` finds nothing.
- Unit tests (`zig build test`) on Windows and on Debian, among them: the versioned `.mdb` read by the embedded
  mdbtools into a SQLite file (the file is a real SQLite file in the temporary folder, 3 tables with 3/2/0 rows,
  types read back, exact decimal `19.9900`, ISO date, 0/1, binary, accents, quotes, NULLs, the whole-table search
  without accents through the SQLite path); a file that is not Access fails with a message and leaves no
  temporary; crash cleanup of old temporaries; the three language catalogs have the same keys and arguments; no
  screen text outside the catalogs (`main.zig`, `dialog.zig`, `platform.zig` are scanned); **Show all / Hide all**
  only on the listed columns; the session log; settings with the language.
- Screenshots of the release program, taken by its hidden test aid `--capture` (README-BUILD.txt) on copies of
  `DB4.accdb` and `nwind.mdb` read by mdbtools: table, filter, Columns at the default and maximized size, narrow
  window, Log, Settings > Language, About and the converted-SQLite dialog in the three languages, and the window
  after **Delete** (the capture also checks that the temporary file is gone).

### Changes in 1.3.0

- Access first: open dialog, file filters, error messages, About and this README list Access, then SQLite, then
  DuckDB; the export menu lists SQLite, Excel, CSV and DuckDB last.
- Access files are converted once into a SQLite file (before: into DuckDB memory) and read from there, with the
  **Save... / Delete / Cancel** dialog on close, open or exit, the answer remembered for the session, and crash
  cleanup on the next start. `Numeric (p, 0)` columns are now integers (sorting `RTUNO` is numeric, no `.0`).
- Row counts of SQLite files and of converted Access files are computed by SQLite itself: opening DB4.sqlite no
  longer spends about 8 s counting.
- Languages: English (default), Portuguese (Brazil), Spanish, in **Settings > Language**, saved, applied at once.
  Every screen text, dialog, message, tooltip and About line comes from `src/lang/en.zig`, `pt_br.zig`, `es.zig`.
- **View > Log** with every message of the session (time + text), selectable, **Copy all**; right-click the status
  line to copy it.
- A NULL cell is shown empty (before: a grey `NULL`), as in the other stacks.
- Columns dialog: **Show all** / **Hide all** act only on the columns listed by the find box.
- Table list: the whole table name is shown (panel as wide as the longest name, sideways scrolling beyond 40% of the
  window).
- **File > Close** closes the open file.
- Debian 13 amd64 build: `.deb` and `.zip`, mdbtools 1.0.1 compiled from its pinned source, GLFW/OpenGL, `zenity`
  dialogs; `build_debian_amd64_wsl.ps1` builds it through WSL.
- Unit tests now read the small versioned `testdata/mdb2sql_test.mdb` with the embedded mdbtools on every run.

### Changes in 1.2.0

- Short window title: `mdb2sql 1.2.0 - Zig`; the details moved to Help > About, now laid out as a table with
  the stack versions and clickable GitHub and GitLab links.
- **Columns...** and the column header right-click menu hide or show several columns at once (about 65% of the window
  width, 420 to 900 px, up to 70% of its height, 1 to 6 check box columns, vertical scrolling only).
- Right-click a cell > **Filter by this value**: exact-value filter in the database query, shown as removable
  buttons, with **Clear filters**.
- One export action per place: the **Export CSV...** / **Export Excel...** buttons of the Data and SQL tabs
  repeated the **Export...** menu and were removed.
- Segoe UI at 16 px instead of 17; shorter texts on screen; nothing cut on a narrow window.
- Whole DOUBLE/FLOAT values show without `.0` in the grids; copy, filter and exports keep the database value.
- Excel export fixes (long non-ASCII sheet names; cut cells and columns are counted and reported).
- License: GPL v2 or later (before: proprietary, all rights reserved).

### Changes in 1.1.1

- Search by words: every word in one cell, any order, ignoring case and accents.
- Program icon on the exe, the window, the single executable and the installer.

### Stability (1.1.0)

- Free SQL results stream (a join without condition no longer fills the memory).
- Start errors and internal errors show a message box (the release program has no console).
- Opening, like every other job, can be canceled; the DuckDB connection lives for the whole run.

## Known limits

- x86_64 only (Windows and Debian). Other systems are not built in this version.
- mdbtools reads Access 97 `.mdb` text as Latin-1: characters 0x80-0x9F of Windows-1252 may come out wrong. Access
  2000 and later files are fine. mdbtools cannot tell an empty text from NULL: both come out as NULL.
- In the converted SQLite file, `Currency` and `Numeric` columns longer than 15 digits are exact decimal text:
  sorting and `SUM` on them compare text unless cast in the SQL tab (`CAST(x AS DECIMAL(19,4))`).
- The ODBC driver may create a `.laccdb` lock file next to the `.accdb` while it reads it (normal Access behavior).
- The single executable (Windows) needs `%LOCALAPPDATA%` to be writable.
- The open and save dialogs block the window while open (running work continues). On Linux without `zenity` there
  is no dialog: type the path in the box.
- The SQL result search and the table filter ignore case and accents of ASCII and Latin-1 letters only; the Data
  search, done by the database, covers all of Unicode.
- Excel keeps at most 32,767 characters per cell and 16,384 columns per sheet (the status line says how many were
  cut). Grids show at most 512 columns (Dear ImGui limit); exports write all of them.
- The GUI has no UI Automation tree (Dear ImGui); it is checked with the `--capture` screenshots.

## Build

```powershell
pwsh -NoProfile -File build_w11_amd64.ps1          # Windows -> dist\w11\amd64\
pwsh -NoProfile -File build_debian_amd64_wsl.ps1   # Debian through WSL -> dist\debian\amd64\
```

On Debian itself: `./build_debian_amd64.sh`. Everything about building, products and cleaning:
[README-BUILD.txt](README-BUILD.txt).

## Dependencies

| Dependency | Version | Use | How it is pinned |
|---|---|---|---|
| [Zig](https://ziglang.org) | 0.17.1 | compiler | sha256 in `scripts/setup_tools.ps1` and `scripts/setup_tools_linux.sh` |
| [Dear ImGui](https://github.com/ocornut/imgui) | 1.93.0 docking, commit `6d32174` | UI, GLFW and OpenGL3 backends | hash in `build.zig.zon` |
| [cimgui](https://github.com/cimgui/cimgui) | tag `1.93dock`, commit `2a6a93f` | C API of Dear ImGui | hash in `build.zig.zon` |
| [zglfw](https://github.com/zig-gamedev/zglfw) | commit `2450fe3` (GLFW 3.4) | window, input, OpenGL context | hash in `build.zig.zon` |
| [libduckdb](https://github.com/duckdb/duckdb/releases/tag/v2.0.0) | 2.0.0, `duckdb-shared-libs-{windows,linux}-amd64.tar.gz` | database engine | hash in `build.zig.zon` |
| DuckDB `sqlite_scanner` extension | v2.0.0 windows_amd64 / linux_amd64 (signed by DuckDB) | SQLite read and write | sha256 in the setup scripts |
| [mdbtools_custom](https://github.com/mauriciomenon/mdbtools_custom/releases/tag/win-static-1.0.1) | 1.0.1 static, Windows | Access reader | sha256 in `scripts/setup_tools.ps1` |
| [mdbtools](https://github.com/mdbtools/mdbtools/releases/tag/v1.0.1) | 1.0.1 source, built static on Linux | Access reader | sha256 in `scripts/setup_tools_linux.sh` |
| [NSIS](https://nsis.sourceforge.io) | 3.13 | Windows installer | sha256 in `scripts/setup_tools.ps1` |

SQLite comes inside DuckDB's `sqlite_scanner` extension (no separate SQLite library). The Excel writer and the
gzip payload of the single executable use only Zig's standard library.

## Layout

- `src/query.zig` - extension check, SQL builder with bound parameters and whitelisted identifiers, paging.
- `src/db.zig` - DuckDB C API: the in-memory instance, read-only `ATTACH` of the file, streaming results, counts.
- `src/access.zig` - Access reader (mdbtools, ODBC on Windows), conversion to SQLite, temporary files and cleanup.
- `src/exporter.zig`, `src/xlsx.zig`, `src/csv.zig` - exports. `src/gridtools.zig` - row copy, word search, filters.
- `src/worker.zig` - background jobs. `src/settings.zig` - saved settings. `src/log.zig` - session log.
- `src/i18n.zig` and `src/lang/` - the language catalogs (one file per language, same keys).
- `src/about.zig` - window title and About data. `src/dialog.zig` - open/save dialogs. `src/platform.zig` - the
  Windows/Linux differences of the GUI. `src/main.zig` - the GUI. `src/capture.zig` - the screenshot test aid.
- `src/launcher.zig`, `src/pack.zig` - the Windows single executable.
- `testdata/mdb2sql_test.mdb` (made by `scripts/make_test_mdb.ps1`) - the small Access file of the unit tests.
- `scripts/` - setup, build, test and packaging scripts. `assets/` - icon, Windows resource, Linux menu entry.

## License

GPL v2 or later (`GPL-2.0-or-later`), full text in [LICENSE](LICENSE).

Third-party parts keep their own licenses: mdbtools (in `mdbtools/`) is GPL/LGPL, DuckDB is MIT, Dear ImGui is MIT,
GLFW is zlib.
