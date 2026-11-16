# MDB2SQL

Desktop viewers for Microsoft Access databases converted to DuckDB: open a `.duckdb` file read-only,
list and filter tables, page through data, see the schema, search the loaded rows and copy values or whole
rows (TAB-separated). The same app is written in four stacks; each folder is a self-contained subproject
with its own README.md, README-BUILD.txt and one build command.

## Subprojects

| Folder | Language | Technology | Status | Windows products today | Build (Windows 11 amd64) |
| --- | --- | --- | --- | --- | --- |
| [python_pyqt6](python_pyqt6/README.md) | Python 3.12 | PyQt6 6.10, DuckDB 2.0, pyodbc + mdbtools, XlsxWriter, PyInstaller, NSIS | 1.1.0 | single exe, zip, NSIS installer | `pwsh -NoProfile -File python_pyqt6\build_w11_amd64.ps1` |
| [go_wails_react](go_wails_react/README.md) | Go 1.26 + TypeScript | Wails 2.13, React 18, duckdb-go (DuckDB 2.0) | 1.0.1 | single exe | `pwsh -NoProfile -File go_wails_react\build_w11_amd64.ps1` |
| [rust_tauri_svelte](rust_tauri_svelte/README.md) | Rust 1.99 + JavaScript | Tauri 2.12, Svelte 5, duckdb crate (DuckDB 2.0), rusqlite, odbc-api, rust_xlsxwriter, mdbtools 1.0.1 embedded | 1.1.0: opens .duckdb/.sqlite/.mdb/.accdb, exports DuckDB/SQLite/Excel/CSV | single exe, zip, NSIS and MSI installers | `pwsh -NoProfile -File rust_tauri_svelte\build_w11_amd64.ps1` |
| [zig_imgui](zig_imgui/README.md) | Zig 0.17 | Dear ImGui 1.93, GLFW 3.4, libduckdb 2.0 | 1.0.1, Windows x64 only | zip of the app folder | `pwsh -NoProfile -File zig_imgui\build_w11_amd64.ps1` |

Every build command cleans, downloads its pinned tools into `<subproject>\.tools\` (sha256 checked),
builds, runs the tests and puts the products in `<subproject>\dist\w11\amd64\`, named
`mdb2sql-<version>-w11-amd64-<stack>...`. Details: [README-BUILD.txt](README-BUILD.txt) and the
README-BUILD.txt of each folder.

## Other folders

- `docs/` - machine setup guides: [SetupWindows11.md](docs/SetupWindows11.md) (short, per stack),
  [SetupWindows.md](docs/SetupWindows.md) (full Windows 11 install), [SetupDebian.md](docs/SetupDebian.md).
- `scripts/` - Bash + mdbtools + DuckDB CLI converters from `.accdb` to `.duckdb`:
  `convert_latest_mdb.sh [folder]` converts the newest `.accdb` of the folder (default `data/importacao/`)
  to `data/<name>.duckdb`; `convert_sample_tables.sh [folder]` converts three sample tables to
  `data/sample.duckdb`. `data/` is not in git.
- `pnpm-workspace.yaml`, `pnpm-lock.yaml` - one pnpm workspace for the two web frontends
  (`go_wails_react/frontend`, `rust_tauri_svelte/ui`).
- `RELEASE-NOTES-v*.md` - notes of each release.

## Safety

All four open the database read-only, accept only database file extensions and validate table names
against the list read from the database before using them in SQL.

## License

Proprietary - All rights reserved.
