# MDB2SQL

Desktop viewers for Microsoft Access databases: open `.accdb`/`.mdb` with nothing installed (mdbtools inside),
SQLite and DuckDB; list and filter tables, page through data, see the schema, search whole tables in the database,
copy values or rows (TAB-separated) and export to SQLite, Excel, CSV or DuckDB. An Access file is converted once to
SQLite; on close the program asks to save or delete that file. The same app is written in four stacks; each folder
is a self-contained subproject with its own README.md, README-BUILD.txt and build commands.

## Quick build (Windows 11 amd64)

At the repo root, everything committed, one fresh `pwsh` per command. Products land in
`<stack>\dist\w11\amd64\` (single exe, zip, installer).

| Stack | Command | Needs on the machine | Last run |
| --- | --- | --- | --- |
| python_pyqt6 | `pwsh -NoProfile -File python_pyqt6\build_w11_amd64.ps1` | uv | 2026-11-24, 5 min 33 s |
| go_wails_react | `pwsh -NoProfile -File go_wails_react\build_w11_amd64.ps1` | Node.js 22+ and pnpm on PATH, WebView2 | 2026-11-24: stopped, pnpm not on PATH |
| rust_tauri_svelte | `pwsh -NoProfile -File rust_tauri_svelte\build_w11_amd64.ps1` | rustup, VS Build Tools, Node.js and pnpm, WebView2 | 2026-11-24: stopped, pnpm not on PATH |
| zig_imgui | `pwsh -NoProfile -File zig_imgui\build_w11_amd64.ps1` | PowerShell 7, tar.exe and internet access to the DuckDB extensions | 2026-11-24: stopped, the network proxy blocked the sqlite_scanner download |

Debian amd64 from Windows (WSL): `pwsh -NoProfile -File <stack>\build_debian_amd64_wsl.ps1` (table below).
Setup guides: docs\SetupWindows11.md, docs\SetupDebian.md. Details: README-BUILD.txt.

## Subprojects

| Folder | Language | Technology | Version | Products | Build (Windows 11 amd64 / Debian amd64 from WSL) |
| --- | --- | --- | --- | --- | --- |
| [python_pyqt6](python_pyqt6/README.md) | Python 3.12 | PyQt6 6.10, DuckDB 2.0, pyodbc + mdbtools 1.0.1, XlsxWriter, PyInstaller, NSIS | 1.3.0 | Windows: single exe, zip, NSIS installer; Debian: .deb, .zip | `python_pyqt6\build_w11_amd64.ps1` / `python_pyqt6\build_debian_amd64_wsl.ps1` |
| [go_wails_react](go_wails_react/README.md) | Go 1.26 + TypeScript | Wails 2.13, React 18, duckdb-go (DuckDB 2.0), excelize, ODBC + mdbtools 1.0.1 | 1.3.0 | Windows: single exe, zip, NSIS installer; Debian: .deb, .zip | `go_wails_react\build_w11_amd64.ps1` / `go_wails_react\build_debian_amd64_wsl.ps1` |
| [rust_tauri_svelte](rust_tauri_svelte/README.md) | Rust 1.99 + JavaScript | Tauri 2.12, Svelte 5, duckdb crate (DuckDB 2.0), rusqlite, odbc-api, rust_xlsxwriter, mdbtools 1.0.1 | 1.3.0 | Windows: single exe, zip, NSIS and MSI installers; Debian: .deb, .zip | `rust_tauri_svelte\build_w11_amd64.ps1` / `rust_tauri_svelte\build_debian_amd64_wsl.ps1` |
| [zig_imgui](zig_imgui/README.md) | Zig 0.17 | Dear ImGui 1.93, GLFW 3.4, libduckdb 2.0, ODBC (Windows) + mdbtools 1.0.1 | 1.3.0 | Windows: single exe, zip, NSIS installer; Debian: .deb, .zip | `zig_imgui\build_w11_amd64.ps1` / `zig_imgui\build_debian_amd64_wsl.ps1` |

New in 1.3.0 (all four): Access first with nothing installed; one conversion to SQLite with save/delete on close;
English, Português (Brasil) and Español; log panel; whole-table search in the database; faster Access open;
Debian amd64 packages; on Linux X11 first and Wayland only as fallback. Full list:
[RELEASE-NOTES-v1.3.0.md](RELEASE-NOTES-v1.3.0.md).

Run each build with `pwsh -NoProfile -File <script>`. Every build cleans, downloads its pinned tools into
`<subproject>\.tools\` (sha256 checked), builds, runs the tests and puts the products in
`<subproject>\dist\w11\amd64\` or `<subproject>\dist\debian\amd64\`, named `mdb2sql-<version>-<platform>-<stack>...`.
Details: [README-BUILD.txt](README-BUILD.txt) and the README-BUILD.txt of each folder.

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

All four open the source database read-only (an Access file is read into a separate SQLite file), accept only
database file extensions, validate table names against the list read from the database and pass search values as
bound parameters.

## License

GPL v2 or later (GPL-2.0-or-later), text in [LICENSE](LICENSE). Third-party components keep their own licenses.
