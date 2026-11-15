# MDB2SQL - Zig + Dear ImGui

Desktop viewer for the DuckDB files converted from Access, written in Zig with
Dear ImGui (GLFW + OpenGL 3.3) and the DuckDB C API. Same core flows as `py_qt6`,
plus paging, search, sort and a free SQL tab.

## Features

- Open a `.duckdb` / `.db` file (read-only): command line argument,
  `MDB2SQL_DB_PATH` environment variable, **Browse...** / **File > Open...**
  (native Windows dialog), path box + **Open**, or drop the file on the window.
- Table list with row counts and a name filter.
- **Data** tab: 100 rows per page, Prev/Next, search across all columns
  (case- and accent-insensitive), click a column header to sort.
- **Schema** tab: column, type, nullable.
- **SQL** tab: run any SQL (Ctrl+Enter) and see the result grid; the first
  10,000 rows are shown and the total is reported. A search box under the
  buttons filters the rows shown, looking at every column.
- Every grid (Data, Schema, SQL result): click a cell to select it, **Ctrl+C**
  copies its value, right-click opens **Copy value** / **Copy row**. Copy row
  puts the whole row on the clipboard separated by TAB, optionally with the
  header line, in the format Excel uses (a value with a TAB, a line break or a
  quote goes inside quotes), so it pastes into one spreadsheet row.
- Opening a database, loading a table page and running SQL happen on a worker
  thread: the window stays responsive, the status line shows what is running
  and for how long, and **Cancel** interrupts a table load or a query.
- **Export CSV...** (Data and SQL tabs, or **File > Export CSV...** for the
  current tab, Schema included): writes the grid on screen (the current page,
  or the SQL rows shown) to a file chosen in a save dialog. UTF-8 with BOM,
  comma separated, CRLF, RFC 4180 quoting; NULL is an empty field and an empty
  text is `""`.
- **View > Theme**: dark (default) or light.
- **Help > About MDB2SQL**: name, version (from `build.zig.zon`), purpose and
  the versions of Zig, Dear ImGui, GLFW and DuckDB in the running program.

## Requirements

- Windows x64.
- Zig **0.17.1**: `setup_tools.ps1` downloads it into `zig_imgui/.tools/`
  (ignored by git), so no system-wide Zig is needed. A `zig` 0.17.x on `PATH`
  also works and is used when `.tools/` does not exist.
- Stays on the system: PowerShell 7 (`pwsh`) to run the two scripts, and the
  `tar.exe` that ships with Windows to extract the zip. No C/C++ compiler or
  Windows SDK is needed: Zig compiles Dear ImGui and GLFW itself and carries
  the Windows import libraries.
- Internet on the first build: `zig build` downloads the pinned dependencies
  into `zig-pkg/` (ignored by git) and checks their hashes.

## Build, run, test

Release build from a clean clone:

```powershell
pwsh -NoProfile -File zig_imgui/setup_tools.ps1    # once: Zig 0.17.1 into .tools/, sha256 checked
pwsh -NoProfile -File zig_imgui/build_windows.ps1  # zig_imgui/dist/mdb2sql-zig-windows-x64/
```

The output folder is recreated on every build and holds `mdb2sql-zig.exe` and
`duckdb.dll`.

`setup_tools.ps1` pins the Zig version and the sha256 published in
<https://ziglang.org/download/index.json>; the zip is extracted only when the
hash matches. 0.17.1 (released 2026-11-02) is the current stable release and
the one this code was written and tested with.

Day to day, with `zig` on `PATH` or `.tools/zig-x86_64-windows-0.17.1/zig.exe`:

```bash
cd zig_imgui
zig build -Doptimize=ReleaseSafe          # zig-out/bin/mdb2sql-zig.exe + duckdb.dll
zig build run -Doptimize=ReleaseSafe -- "C:/path/to/file.duckdb"
zig build test --summary all              # unit tests
zig build -Doptimize=ReleaseSafe -Dconsole=true   # release exe that keeps a console
```

Release builds are Windows GUI programs: no console window opens with them.
Debug builds (`zig build`) keep the console, so stderr is visible;
`-Dconsole=true|false` overrides either way.

From the repository root: `./run_zig_imgui.sh [file.duckdb]` and
`./clean_zig_imgui.sh` (clean rebuild); both use `.tools/` when it exists.

The first build is slow (about 2 minutes for each `translate-c` of `duckdb.h`
and `cimgui.h`, plus the C++ compile of Dear ImGui); later builds use the cache.

Optional start state, useful for scripts and screenshots:

```bash
mdb2sql-zig.exe file.duckdb --table RANGER_SOSTAT --sql "SELECT COUNT(*) FROM RANGER_SOSTAT"
mdb2sql-zig.exe file.duckdb --theme light --about
mdb2sql-zig.exe file.duckdb --table RANGER_SOSTAT --search "rele 86"
mdb2sql-zig.exe file.duckdb --table RANGER_SOSTAT --cell 4,4
```

`--table NAME` selects a table, `--sql "..."` runs a statement and shows the
SQL tab, `--search TEXT` fills the Data tab search, `--cell ROW,COL` (from 1)
selects a grid cell and opens its copy menu, `--theme dark|light` picks the
colors and `--about` opens the About window. An unknown flag shows the usage text (in a message box in the release
build, which has no console).

## Dependencies (pinned by hash in `build.zig.zon`)

| Dependency | Version | Use |
|---|---|---|
| [Dear ImGui](https://github.com/ocornut/imgui) | 1.93.0 docking, commit `6d32174` | UI, GLFW and OpenGL3 backends, built from source |
| [cimgui](https://github.com/cimgui/cimgui) | tag `1.93dock`, commit `2a6a93f` | C API of Dear ImGui, read by `translate-c` |
| [zglfw](https://github.com/zig-gamedev/zglfw) | commit `2450fe3` (GLFW 3.4) | window, input, OpenGL context |
| [libduckdb](https://github.com/duckdb/duckdb/releases/tag/v2.0.0) | 2.0.0, official `duckdb-shared-libs-windows-amd64.tar.gz` | database engine |

The Dear ImGui commit is the one the cimgui tag points to as its submodule.
zgui was not used: its `main` branch does not build with Zig 0.17.

DuckDB 2.0.0 is required by the data: the NMR5 `.duckdb` files were written by
DuckDB 2.0.0 (storage version 69) and libduckdb 1.5.6 refuses to open them.

DuckDB is linked **dynamically**: the build links `duckdb.lib` (import library)
and installs `duckdb.dll` next to the exe in `zig-out/bin`. Keep the two files
together when you copy the program. ImGui, cimgui and GLFW are linked statically.

The program version (1.0.1) has one source, `.version` in `build.zig.zon`;
`build.zig` passes it to the code as a build option and the About window shows
it.

## Layout

- `src/query.zig` - pure logic: extension check, SQL builder with bound
  parameters and whitelisted identifiers, paging math. Has unit tests.
- `src/db.zig` - DuckDB C API wrapper: open read-only, tables, schema, page,
  count, free SQL. Has unit tests that create real databases.
- `src/worker.zig` - the database jobs (open, select table, reload page, SQL)
  and the one-job-at-a-time thread slot that the GUI polls. Has unit tests.
- `src/csv.zig` - CSV writer. Has unit tests for the quoting.
- `src/gridtools.zig` - TAB-separated row copy and the filter over loaded
  rows. Has unit tests for the escaping.
- `src/about.zig` - About text. Has a unit test.
- `src/dialog.zig` - Windows open/save dialogs (`comdlg32`).
- `src/main.zig` - the GUI: menu, themes, tabs, grids.
- `src/shim.c` - three small C functions for ImGui struct fields that Zig's
  `translate-c` cannot expose.

## Gaps

- Windows x64 only: the build stops on other targets, because only the Windows
  libduckdb is pinned.
- No `.mdb` to DuckDB conversion.
- CSV export writes what the grid holds: one page of 100 rows in the Data tab,
  at most 10,000 rows in the SQL tab. There is no whole-table export.
- The theme choice is not saved: the program starts dark unless
  `--theme light` is given.
- The file dialogs are the classic `GetOpenFileNameW` / `GetSaveFileNameW`
  ones and block the window while they are open (a running query continues).
- The SQL result search ignores ASCII case only (the Data tab search, done by
  DuckDB over the whole table, also ignores accents). There is no multi-cell
  selection: copy works on one cell or one row.
- One database job at a time: a click made while a job runs is applied when
  it ends. Opening a database cannot be cancelled (table loads and SQL can).
- SQL tab: values are shown as text because the statement is wrapped in
  `SELECT CAST(COLUMNS(*) AS VARCHAR) FROM (...)`. A statement that cannot be
  wrapped (PRAGMA, SET, or a SELECT with a comment after its final `;`) runs
  as written, and then only text, integer, float and boolean columns are
  decoded; other types show `(not text)`.
- `query.zig` supports per-column criteria (AND/OR), but the GUI exposes only
  the global search and the sort.
- The GUI itself has no automated tests (Dear ImGui exposes no UI Automation
  tree); it was checked with screenshots of the real NMR5 DB4 database, driven
  by the start flags.
- Long cell text is cut at the column width; drag the column border to widen.
