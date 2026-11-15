# MDB2SQL

Multi-platform desktop application for converting Microsoft Access databases (.mdb) to DuckDB format with advanced search, filtering, and comparison capabilities.

## Project Overview

MDB2SQL provides four independent GUI implementations showcasing different technology stacks, each demoing the same core functionality: loading, viewing, and querying DuckDB databases converted from Microsoft Access.

### Technology Stacks

1. **Python + PyQt6**
   - Backend: Python 3.12 + DuckDB
   - UI: PyQt6 native widgets (table sidebar with filter, Data/Schema tabs, row limit, search; DuckDB work off the UI thread; light/dark follows the system)
   - Status: 1.0.0; run from source with `uv run` (no packaged binary in the release)

2. **Go + Wails + React**
   - Backend: Go 1.26 (go.mod `go 1.26.0`, required by the security updates of wails/echo/x-crypto) + duckdb-go v2.20000.0 (`github.com/duckdb/duckdb-go/v2`, DuckDB 2.0.0 linked statically; no DuckDB DLL/shared library to install or ship)
   - Frontend: React 19 + Vite
   - Bridge: Wails v2.13
   - Notes: cgo needs a C toolchain (Windows: MinGW-w64 GCC with the UCRT runtime, see SetupWindows11.md; Linux: gcc/g++). Wails CLI: `go install github.com/wailsapp/wails/v2/cmd/wails@v2.13.0`. With Go 1.27 installed, run the Wails CLI with `GOTOOLCHAIN=go1.26.11` (CLI 2.13.0 fails on Go 1.27 with "package without types was imported")
   - Status: 1.0.0; single exe (`wails build`), DuckDB linked in

3. **Rust + Tauri + Svelte**
   - Backend: Rust 1.90+ (required by Tauri 2.12) + duckdb-rs
   - Frontend: Svelte + Vite
   - Bridge: Tauri v2 (tauri 2.12, tauri-build 2.7, config v2 + `capabilities/default.json`); CLI: `cargo install tauri-cli --version "^2" --locked`
   - Status: 1.0.0; `cargo tauri build` produces the NSIS and MSI installers on Windows

4. **Zig + Dear ImGui**
   - Backend: Zig 0.17 + libduckdb 2.0.0 (C API)
   - UI: Dear ImGui 1.93 (cimgui) on GLFW + OpenGL 3.3, no web view
   - Status: Windows x64 only; open, table list with row counts, paged data, search, sort, schema, free SQL

## Quick Start

### Prerequisites

All platforms require:
- Git
- Node.js 23.x with pnpm 10.x (pinned to avoid dependency breakage)
- Go 1.26.x (see go_wails_react/go.mod) and a C compiler for cgo (DuckDB is linked statically)
- Python 3.12.x + uv
- Platform-specific toolchains (see setup guides)

### Installation

#### macOS / Linux
```bash
git clone https://github.com/mauriciomenon/mdb2sql.git
cd mdb2sql
```

#### Windows
```powershell
git clone https://github.com/mauriciomenon/mdb2sql.git
cd mdb2sql
```

### Running Implementations

#### Python + PyQt6
```bash
cd py_qt6
uv sync
uv run python src/main.py
```

#### Go + Wails + React
```bash
cd go_wails_react/frontend
pnpm install && pnpm run build   # main.go embeds frontend/dist; go build/vet fail without it
cd ..
go test ./... && go vet ./... && go build ./...
wails dev                        # or: wails build -platform windows/amd64
```
Windows needs a UCRT MinGW-w64 GCC first in PATH (see [SetupWindows11.md](SetupWindows11.md)).

#### Rust + Tauri + Svelte
```bash
cd rust_tauri_svelte/ui
pnpm install
cd ..
cargo tauri dev
```

#### Zig + Dear ImGui (Windows x64)
```bash
cd zig_imgui
zig build run -Doptimize=ReleaseSafe -- path/to/file.duckdb
```
See [zig_imgui/README.md](zig_imgui/README.md).

## Documentation

### Setup Guides
- [SetupWindows.md](SetupWindows.md) - Complete Windows 11 installation
- [SetupDebian.md](SetupDebian.md) - Debian 13.2 Stable setup
- [SetupSummary.md](SetupSummary.md) - Quick reference for all platforms

### Project Documentation
- [ProjectSpec.md](ProjectSpec.md) - Complete project specification
- [temp/ErrosEProblemasPoc.md](temp/ErrosEProblemasPoc.md) - Known issues and solutions
- `scripts/generate_md_pdfs.sh` - requires pandoc + xelatex (MiKTeX/texlive-xetex) to export docs as PDF
- Build outputs: Vite defaults to `dist/<platform>-<arch>` (override with `OUT_DIR`), Wails binaries in `build/bin/<os>-<arch>`, Tauri in `rust_tauri_svelte/target/release` (installers in `target/release/bundle`), Python builds under `build/<os>-<arch>/`.
- Sanity: `scripts/run_sanity.sh` runs go test/vet/build (+ frontend build), cargo test, and uv pytest using pinned tools.
- Packaging: `scripts/package_minimal.sh` gera `build/minimal/minimal_<os>_<arch>.zip` apenas com binarios e READMEs.
- Windows equivalents: `scripts/run_sanity.ps1`, `scripts/package_minimal.ps1`, `scripts/validate_build.ps1` para o mesmo fluxo em PowerShell.
- Release build helpers: `scripts/build_release.sh` / `scripts/build_release.ps1` geram binarios em `build/bin/<os>-<arch>`, `rust_tauri_svelte/target/release`, `py_qt6/build/<os>-<arch>` antes do pacote minimo.
- Clean: `scripts/clean.sh` / `scripts/clean.ps1` removem dist/target/build/minimal por OS/arch.
- Go/Wails UI (`frontend/src/App.tsx`): abre um arquivo DuckDB pelo dialogo nativo, lista/filtra tabelas, mostra dados e schema, tema claro/escuro. Nao converte .mdb/.accdb.

### Implementation Guides
- [py_qt6/temp/PythonConceptsGuide.md](py_qt6/temp/PythonConceptsGuide.md)
- [go_wails_react/temp/GoConceptsGuide.md](go_wails_react/temp/GoConceptsGuide.md)
- [rust_tauri_svelte/temp/RustConceptsGuide.md](rust_tauri_svelte/temp/RustConceptsGuide.md)

## Features

### Implemented (Python + Go)
- ✅ Load DuckDB databases via environment variable or default path
- ✅ List all tables in database
- ✅ Display table data with pagination (default 100 rows)
- ✅ View table schemas (column names, types, nullable)
- ✅ Row count display
- ✅ Path traversal protection
- ✅ SQL injection prevention
- ✅ Read-only mode for data safety

### Planned Features
- 🔄 Advanced search with case/accent-insensitive matching
- 🔄 Multi-criteria filtering (AND/OR operators)
- 🔄 Database comparison engine
- 🔄 Theme support (Gruvbox, Tokyo Night, Nord, Dark Modern)
- 🔄 Export to CSV/Excel
- 🔄 SQL query builder

## Architecture

### Code Structure
```
mdb2sql/
├── py_qt6/              # Python implementation
│   ├── src/
│   │   ├── backend/     # Business logic
│   │   ├── ui/          # PyQt6 widgets
│   │   └── shared/      # Common types
│   └── temp/            # Documentation
├── go_wails_react/      # Go implementation
│   ├── frontend/        # React UI
│   └── temp/            # Documentation
├── rust_tauri_svelte/   # Rust implementation (POC)
│   ├── src/             # Rust backend
│   ├── capabilities/    # Tauri v2 permissions
│   ├── ui/              # Svelte frontend
│   └── temp/            # Documentation
├── data/                # Sample databases
├── scripts/             # Utility scripts
└── temp/                # Project-level documentation
```

### Security Features

All implementations include:
- **Path Traversal Protection**: Validates database paths using `Path.resolve()`
- **SQL Injection Prevention**: Whitelist validation of table names
- **Read-Only Mode**: Databases opened with `read_only=True`
- **File Extension Validation**: Only `.duckdb` and `.db` files accepted

## Development

### Comment Standards

All code uses dual-level comments:
```python
# Portuguese comment for Brazilian developers
# !T: English technical comment for international developers
```

### Package Managers
- Python: uv (pyproject.toml)
- JavaScript/TypeScript: pnpm (packageManager field in package.json)
- Go: Go modules (go.mod)
- Rust: Cargo (Cargo.toml)

### Testing

#### Python
```bash
cd py_qt6
uv run pytest tests/
```

#### Go
```bash
cd go_wails_react
go test ./...
```

#### Rust
```bash
cd rust_tauri_svelte
cargo test
```

#### Zig
```bash
cd zig_imgui
zig build test --summary all
```

## Known Issues

### Rust + Tauri + Svelte
- Release builds: use `cargo tauri build`; a plain `cargo build --release` produces an exe that loads the dev server (localhost:1420) and shows an empty window
- Arrow Flight dependency linker errors on some platforms
- See [temp/ErrosEProblemasPoc.md](temp/ErrosEProblemasPoc.md) for workarounds

### Go + Wails
- WebView2 required on Windows (auto-installs on first run)
- May require firewall exceptions for dev server
- Release build on Windows: `pwsh -NoProfile -File go_wails_react/build_windows.ps1`. It deletes `frontend/dist` first (Vite writes to `frontend/dist/<platform>-<arch>/`, and a stale `frontend/dist/index.html` from an older build would be embedded instead of the new UI) and builds with `-trimpath` so no local paths end up in the exe. Tauri: `pwsh -NoProfile -File rust_tauri_svelte/build_windows.ps1` (same idea with `--remap-path-prefix`)
- "Sample data" reports `sample.duckdb` in the status line even when `MDB2SQL_DB_PATH` points to another file

## Version History

### v1.0.0 (2026-11-15)
- Four GUIs over DuckDB 2.0 files: PyQt6, Go + Wails + React, Rust + Tauri 2 + Svelte, Zig + Dear ImGui
- New UIs in all four; checked against a real 287-table database (screenshots of table list and data)
- DuckDB 2.0 in every stack (duckdb-go v2.20000.0, duckdb crate 1.20000.2, libduckdb 2.0.0, Python duckdb 2.0.0)
- Tauri migrated from v1 to v2; Go 1.26 with Wails 2.13
- Dependabot alerts reduced from 79 to the ones listed in RELEASE-NOTES-v1.0.0.md

### v0.4.0 (Documentation Standardization)
- Python implementation: core features working; release readiness under review
- Go implementation: core features working; release readiness under review
- Rust implementation: in progress, not release ready
- Dual-level code documentation in place
- Security hardening: path traversal and SQL injection mitigations
- Platform setup guides: Windows 11 and Debian 13.2
- Documentation files standardized to PascalCase
- README and ProjectSpec consolidated

## Contributing

This is a private proof-of-concept project. Contributions are by invitation only.

## License

Proprietary - All rights reserved

## Contact

**Maintainer**: Development Team
**Repository**: https://github.com/mauriciomenon/mdb2sql
**Branch**: dev (main development branch)

---

**Last Updated**: 2025-11-21
**Document Version**: 1.0
