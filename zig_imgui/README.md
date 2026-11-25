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
     faster (DB4: about 7 s instead of about 40 s, see "Performance");
  2. otherwise the **mdbtools** that ship with the program (no installation, no driver, nothing from the computer);
  3. if neither is available (the `mdbtools` folder was deleted), a message says so.

  `MDB2SQL_ACCESS_READER=mdbtools` forces mdbtools (also on a computer with the ODBC driver), `=odbc` forces ODBC,
  `auto` or unset: the order above. The status line says which way was used.

## Linux: X11 and Wayland

The program opens its window with X11 (on a Wayland desktop, through XWayland). Native Wayland is only the fallback:
when X11 is not available (no `DISPLAY`, or one of the X11 libraries below is missing), the program opens on Wayland
and shows a **Display mode** warning at every start (also in **View > Log**) naming what is missing and the command
to install it. With neither X11 nor Wayland it prints the reason on the terminal and exits with code 3.

To choose yourself (no warning): `MDB2SQL_DISPLAY=x11` or `MDB2SQL_DISPLAY=wayland`; an empty `WAYLAND_DISPLAY=`
also means X11 only.

| What X11 needs | Debian / Ubuntu (`apt install`) | Fedora / RHEL (`dnf install`) | Arch (`pacman -S`) | openSUSE (`zypper install`) |
|---|---|---|---|---|
| X server on a Wayland desktop | `xwayland` | `xorg-x11-server-Xwayland` | `xorg-xwayland` | `xwayland` |
| `libX11.so.6` | `libx11-6` | `libX11` | `libx11` | `libX11-6` |
| `libXrandr.so.2` | `libxrandr2` | `libXrandr` | `libxrandr` | `libXrandr2` |
| `libXinerama.so.1` | `libxinerama1` | `libXinerama` | `libxinerama` | `libXinerama1` |
| `libXcursor.so.1` | `libxcursor1` | `libXcursor` | `libxcursor` | `libXcursor1` |
| `libXi.so.6` | `libxi6` | `libXi` | `libxi` | `libXi6` |

The `.deb` already depends on these libraries; on Debian the warning normally means the desktop runs without
XWayland (`sudo apt install xwayland`). Why X11 first: under native Wayland GLFW draws the window frame through
libdecor, which loads GTK; two early starts on WSLg crashed inside it (README-BUILD.txt, section 7).

## Access files: one conversion to SQLite

Opening an `.accdb`/`.mdb` converts every table once into a temporary SQLite file in `<TEMP>/mdb2sql-zig/` and the
program reads that file (the status line says `read with mdbtools, converted to SQLite`). Types are kept as SQLite
stores them: integers (`Byte`, `Integer`, `Long Integer`, `Numeric (p, 0)` up to 18 digits) as INTEGER (declared
BIGINT), `Single`, `Double`, `Currency` and the other `Numeric` as REAL (declared DOUBLE; exact up to 15 significant
digits), dates as ISO text (`2026-07-14 10:30:00`, declared VARCHAR: ISO text sorts and compares in date order),
Yes/No as 0/1, OLE/binary as BLOB, text as TEXT; NULL stays NULL. Every number has numeric affinity, so a filter
(`WHERE SCALE > 100`), `ORDER BY` and `SUM` compare numbers, in the program and in any tool that opens the saved file.

When the file is closed (**File > Close**), another file is opened, or the program exits, a short dialog asks
`Save the SQLite file converted from Access (<source>.sqlite)?`:

- **Save...** - save dialog, by default next to the source file as `<source>.sqlite`;
- **Delete** - the temporary file is deleted;
- **Cancel** (or Esc, or the dialog's X) - nothing is closed (the program stays open).

With **Remember for this session** checked, the answer is used until the program closes without asking (a remembered
**Save** writes into the same folder; if that name already exists the save dialog opens). A saved SQLite is kept in
the settings with the key of the Access file (path, size and modification date): opening the same, unchanged Access
file again, also in a later run, opens the saved SQLite at once, with no conversion and no question; if the Access
file (or the saved SQLite) changed, it is converted again. Temporary files are never left behind: they are deleted
on **Delete**, and if the program crashes, the next start deletes the temporaries of programs that are no longer
running.

## How to use

### Opening a file

- **File > Open...** (Ctrl+O) or **Browse...**: open dialog filtered by type (Access first, then SQLite and DuckDB);
  Windows dialog on Windows, `zenity` on Linux.
- Type or paste the path in the box and press **Open** (or Enter). Drag the file onto the window.
- Command line: `mdb2sql-zig "C:\data\file.accdb"`; environment variable `MDB2SQL_DB_PATH` when no file is given.

While a file opens, the status line shows the time, a progress bar (tables converted or counted) and **Cancel**.

### Window

- **Table list** (left): every table with its row count, the whole name shown (the panel starts as wide as the
  longest name, up to 40% of the window, and scrolls sideways beyond that); the box on top filters by name 300 ms
  after the last key (Enter: at once).
- **Data** tab, top to bottom: one line with the search box, **This table** | **All tables**, **Rows** (the first 100,
  500 or 1000 rows) and **Columns...** (a narrow window wraps it, nothing cut); the value filters line, only when
  there are filters; the grid (click a column header to sort); under the grid `<table>: showing <n> of <total> rows`
  (with a search or filter: `... rows found`). The search
  runs 300 ms after the last key (Enter: at once), in the database over the **whole table** (every column), for
  Access, SQLite and DuckDB alike, before the row limit: the row count follows it.
- Next to the search box, **This table** | **All tables**: with **All tables** the text is searched in every table
  (same rule and same query as the table search) and the Data tab shows `<n> tables with rows matching "<text>"` and
  the list `<table> (<rows found>)`; clicking one opens that table with the same search and without value filters, showing that same number of rows.
  Changing the term, the scope, the table or the file stops the running search and its result is dropped. The default
  is in **Settings > Default search scope**; opening a file clears the search and the table filter and goes back to
  it.
- **Columns...** (Data tab and SQL result; dialog "Columns of <table>"): one check box per column, a box to find a
  column by name, **Show all** and **Hide all** (with text in the find box they act only on the columns listed).
  Right-click a column header: **Size column to fit**, **Size all columns to fit**, **Hide this column**,
  **Columns...**, **Show all columns** (disabled with no hidden column) and the list of columns with a check mark (a click shows or hides it; the menu stays open). The last visible column
  cannot be hidden. Hidden columns last while the table is open, are not saved, and are still searched and exported.
- **Filter by this value** (right-click a cell of the Data tab): exact `column = value` filter in the database
  query; several add up (AND) and combine with the search; each is a button above the grid (click to remove).
- **Schema** tab: column, type, nullable (Yes / No in the screen language, also in its export).
- **SQL** tab: any SQL (the empty box shows `SELECT * FROM ...`), **Run** (Ctrl+Enter), first 10,000 rows shown; a
  run that works clears the previous error next to the button and in the status bar, an error clears the old grid.
- **Search rule**: the text is split into words; a row matches when one cell holds every word, in any order,
  ignoring case and accents (`Tensión campo` finds `EXCITACION TENSION DE CAMPO`; `tensao` does not: there is no
  fuzzy matching).
- A NULL cell is shown empty; with **Settings > Show NULL** on it shows `NULL` (display only: copy gives an empty
  value, search and export do not change).
- Every grid: click a cell, **Ctrl+C** copies it, right-click: (Data tab) **Filter by this value** / **Clear
  filters**, then **Copy value**, **Copy row** (TAB separated) and **Copy row with header**.
- Long work runs in the background with **Cancel**.

### Menus

- **File**: **Open...**, **Export** (also the **Export...** button): **Database to SQLite**, **Database to DuckDB**,
  **Database to Excel** (one sheet per table), **Current table / schema / SQL result to CSV or Excel**; **Close**;
  **Exit** (Ctrl+Q). Exporting the table while a search or value filter is active asks first: **Whole table** or **Only the
  <n> rows found**. Export to `.accdb`/`.mdb` is not available (no reliable library writes Access files).
- **Log** panel at the bottom (**View > Log**, Ctrl+L, or the arrow at the left of the status bar and in the panel
  header): every message of the session with its time, in a monospace font one step smaller; select and Ctrl+C, or
  **Copy all**, **Clear**. About 10% of the window high (at least 3 lines, at most 25%), resized by dragging its top
  edge; open/closed state and height are saved; closed by default. While it is closed, the status bar shows the most
  important message not yet seen in the log (last error in red, else last warning, else the last action) and, on the
  right, how many errors and warnings are unread; clicking the message opens the log. Right-click the status bar:
  **Copy** (the whole text). Also on the right, always: the hidden columns of the grid on screen and how the open file
  was read (`Opened via Access ODBC, converted to SQLite`, `Opened via mdbtools, ...`, `Opened via SQLite`,
  `Opened via DuckDB`). Opening a file says `Loaded: <file> (<n> tables)`.
- Numbers are right-aligned in the grids and in the row counts of the table list (headers too); arrows are `←` `→`.
- **Settings > Theme**: System, Light, Dark. **Settings > Language**: English, Português (Brasil), Español.
  **Settings > Default search scope**: This table, All tables. **Settings > Show NULL** (off by default). All are
  saved and apply at once, without restarting.
- **Help > About mdb2sql**: version, build, stack, Access reader, license and the GitHub and GitLab links.

### Saved settings

Windows: `%APPDATA%\mdb2sql\zig-imgui.ini`; Linux: `~/.config/mdb2sql/zig-imgui.ini` (`$XDG_CONFIG_HOME` if set).
Theme, language, Log panel, default search scope, Show NULL, the last folder used and the last 8 Access files saved
as SQLite (path, size and date of both files).

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
  pandas/pyodbc converter): 0 differences. Conversion to SQLite: about 40 s with mdbtools, about 7 s with ODBC.
  The converted file exported again to `.duckdb` and `.sqlite` and reopened: every count equal. Row counts of the
  287 tables after the conversion: 0.7 s (8.7 s before, through DuckDB's SQLite reader).
- `DB3 1.accdb` through mdbtools: 287 tables, 113,826 rows, every name and count equal to its reference
  (`2026-06-25 DB3 1.sqlite`): 0 differences; conversion about 35 s.
- Whole-table search on the converted DB4 (RANGER_SOSTAT, 36,754 rows): `tension de campo` finds the one row
  `EXCITACION TENSION DE CAMPO`, which is not on the first page; `tensao de campo` finds nothing.
- Types of the converted DB4 and DB3 1: 1,681 INTEGER, 5,816 REAL and 2,867 text columns; the text ones are the
  2,861 Access text/memo columns and the 6 DateTime columns (ISO text); no number is stored as text. Six queries with
  a numeric filter, `ORDER BY ... LIMIT` and `SUM` on RTUNO, PNTNO, SCALE and BIAS (and the max of a date) give the
  same result through the program's SQL and directly in SQLite, on the converted file and on the reference: 0
  differences in 6 x 4 results, on both databases.
- Unit tests (`zig build test`) on Windows and on Debian, among them: the versioned `.mdb` read by the embedded
  mdbtools into a SQLite file (the file is a real SQLite file in the temporary folder, 3 tables with 3/2/0 rows,
  types read back, `typeof` in SQLite integer/real for every number, numeric filter, `SUM` and `ORDER BY` on the
  Currency column, ISO date, 0/1, binary, accents, quotes, NULLs, the whole-table search
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
  cleanup on the next start. `Numeric (p, 0)` columns are now integers (sorting `RTUNO` is numeric, no `.0`), and
  `Currency` and decimal `Numeric` are REAL: no number is stored as text in the SQLite file.
- Row counts of SQLite files and of converted Access files are computed by SQLite itself: opening DB4.sqlite no
  longer spends about 8 s counting.
- Languages: English (default), Portuguese (Brazil), Spanish, in **Settings > Language**, saved, applied at once.
  Every screen text, dialog, message, tooltip and About line comes from `src/lang/en.zig`, `pt_br.zig`, `es.zig`.
- Log panel docked at the bottom (time + text, monospace, selectable, **Copy all**), closed by default, with the
  status bar moved to the bottom showing the last unseen error or warning; right-click the status bar to copy it.
- Numbers right-aligned in the grids and in the table list; `← Prev` / `Next →` with Unicode arrows.
- A NULL cell is shown empty (before: a grey `NULL`), as in the other stacks.
- Columns dialog: **Show all** / **Hide all** act only on the columns listed by the find box.
- Table list: the whole table name is shown (panel as wide as the longest name, sideways scrolling beyond 40% of the
  window).
- **File > Close** closes the open file.
- Linux: X11 first, Wayland only as a fallback with a **Display mode** warning at start (section "Linux: X11 and
  Wayland"); `MDB2SQL_DISPLAY=x11|wayland` chooses without warning.
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

## Performance (opening Access)

Measured by the performance protocol of README-BUILD.txt (release build, copies of the files, median of 3 runs, the
same machine: Intel Core Ultra 7 258V, 8 cores, 32 GB, NVMe SSD; whole test process at most about 390 MB). Seconds
until the table list appears (conversion + row counts); the first table appears 0.1 s later.

| Case | DB4 before | DB4 now | DB3 1 before | DB3 1 now |
|---|---|---|---|---|
| Access through ODBC | 16.6 | 6.7 | 19.4 | 6.2 |
| Access through mdbtools | 73.5 | 39.9 | 46.1 | 35.5 |
| of which waiting for `mdb-export` | 57.8 | 33.3 | 36.1 | 29.5 |
| of which writing the SQLite file | 11.3 | 4.4 | 7.4 | 3.8 |
| Reopen the saved SQLite | 1.4 | 0.5 | 0.4 | 0.4 |
| Export to SQLite (Access open) | 15.4 | 1.6 | 12.1 | 1.6 |
| Export to DuckDB (Access open) | 12.2 | 2.4 | 9.3 | 2.5 |
| Open the reference `.sqlite` / `.duckdb` | 0.5 / 0.3 | 0.5 / 0.4 | 0.6 / 0.3 | 0.4 / 0.3 |

What changed: the conversion and the database exports write in one transaction (SQLite commits the file once
instead of once per table); `mdb-export` runs as a queue of up to 6 processes (cores - 1), each one taking the next
table as soon as it ends, and the table it exported is written to SQLite while the others still run (before:
batches of 8 that waited for the slowest). Table and row counts stay identical to the reference conversions (the
real-file test checks every table). Most of the remaining mdbtools time is each `mdb-export` process reading the
file's catalog again (about 0.3 s per table, 287 tables).

## Known limits

- x86_64 only (Windows and Debian). Other systems are not built in this version.
- mdbtools reads Access 97 `.mdb` text as Latin-1: characters 0x80-0x9F of Windows-1252 may come out wrong. Access
  2000 and later files are fine. mdbtools cannot tell an empty text from NULL: both come out as NULL.
- In the converted SQLite file, `Currency` and `Numeric` values with decimals are REAL: exact up to 15 significant
  digits (any value below 100 billion with 4 decimals); longer values are rounded to the nearest double. `Numeric`
  integers longer than 18 digits are REAL too. (DB4 and DB3 1 have no Currency and no Numeric with decimals.)
- The ODBC driver may create a `.laccdb` lock file next to the `.accdb` while it reads it (normal Access behavior).
- The single executable (Windows) needs `%LOCALAPPDATA%` to be writable.
- The open and save dialogs block the window while open (running work continues). On Linux without `zenity` there
  is no dialog: type the path in the box.
- On Linux without X11 the window opens on native Wayland, where GLFW decorates it through libdecor/GTK; two early
  WSLg starts crashed there (README-BUILD.txt, section 7).
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

- `src/query.zig` - extension check, SQL builder with bound parameters and whitelisted identifiers, row limits.
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
