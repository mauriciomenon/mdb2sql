# MDB2SQL - Zig + Dear ImGui

Desktop viewer for the DuckDB files converted from Access, written in Zig with
Dear ImGui (GLFW + OpenGL 3.3) and the DuckDB C API. Same core flows as `py_qt6`,
plus paging, search, sort and a free SQL tab.

## Features

- Open a `.duckdb` / `.db` file (read-only): command line argument,
  `MDB2SQL_DB_PATH` environment variable, path box + **Open**, or drop the file
  on the window.
- Table list with row counts and a name filter.
- **Data** tab: 100 rows per page, Prev/Next, search across all columns
  (case- and accent-insensitive), click a column header to sort.
- **Schema** tab: column, type, nullable.
- **SQL** tab: run any SQL (Ctrl+Enter) and see the result grid; the first
  10,000 rows are shown and the total is reported.

## Requirements

- Windows x64.
- Zig **0.17.x** on `PATH` (built and tested with 0.17.1).
- Internet on the first build: `zig build` downloads the pinned dependencies
  into `zig-pkg/` (ignored by git) and checks their hashes.

## Build, run, test

```bash
cd zig_imgui
zig build -Doptimize=ReleaseSafe          # zig-out/bin/mdb2sql-zig.exe + duckdb.dll
zig build run -Doptimize=ReleaseSafe -- "C:/path/to/file.duckdb"
zig build test --summary all              # unit tests (query builder + DuckDB access)
```

From the repository root: `./run_zig_imgui.sh [file.duckdb]` and
`./clean_zig_imgui.sh` (clean rebuild).

The first build is slow (about 2 minutes for each `translate-c` of `duckdb.h`
and `cimgui.h`, plus the C++ compile of Dear ImGui); later builds use the cache.

Optional start state, useful for scripts and screenshots:

```bash
mdb2sql-zig.exe file.duckdb --table RANGER_SOSTAT --sql "SELECT COUNT(*) FROM RANGER_SOSTAT"
```

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
DuckDB 2.0.0 (storage version 69) and libduckdb 1.5.6 refuses to open them. The
other GUIs in this repository still pin DuckDB 1.x (`rust_tauri_svelte` 1.5.6,
`py_qt6` lock 1.4.2), so they cannot open those files until they are updated.

DuckDB is linked **dynamically**: the build links `duckdb.lib` (import library)
and installs `duckdb.dll` next to the exe in `zig-out/bin`. Keep the two files
together when you copy the program. ImGui, cimgui and GLFW are linked statically.

## Layout

- `src/query.zig` - pure logic: extension check, SQL builder with bound
  parameters and whitelisted identifiers, paging math. Has unit tests.
- `src/db.zig` - DuckDB C API wrapper: open read-only, tables, schema, page,
  count, free SQL. Has unit tests that create real databases.
- `src/main.zig` - the GUI.
- `src/shim.c` - three small C functions for ImGui struct fields that Zig's
  `translate-c` cannot expose.

## Gaps

- Windows x64 only: the build stops on other targets, because only the Windows
  libduckdb is pinned.
- No native file dialog; use the path box, drag and drop, or the command line.
- No CSV export (`py_qt6` has none either) and no `.mdb` to DuckDB conversion.
- SQL tab: values are shown as text because the statement is wrapped in
  `SELECT CAST(COLUMNS(*) AS VARCHAR) FROM (...)`. A statement that cannot be
  wrapped (PRAGMA, SET, or a SELECT with a comment after its final `;`) runs
  as written, and then only text, integer, float and boolean columns are
  decoded; other types show `(not text)`.
- Queries run on the UI thread, so a slow SQL statement freezes the window
  until it ends.
- `query.zig` supports per-column criteria (AND/OR), but the GUI exposes only
  the global search and the sort.
- The exe is a console-subsystem program: a console window opens with it when
  it is started from Explorer.
- The GUI itself has no automated tests; it was checked with screenshots of the
  real NMR5 DB4 database (open, table list, paging, sort, search, SQL).
- Long cell text is cut at the column width; drag the column border to widen.
