# MDB2SQL

Multi-platform desktop application for converting Microsoft Access databases (.mdb) to DuckDB format with advanced search, filtering, and comparison capabilities.

## Project Overview

MDB2SQL provides three independent GUI implementations showcasing different technology stacks, each demoing the same core functionality: loading, viewing, and querying DuckDB databases converted from Microsoft Access.

### Technology Stacks

1. **Python + PyQt6**
   - Backend: Python 3.12 + DuckDB
   - UI: PyQt6 native widgets
   - Status: Active development; core flows work but still under review for release

2. **Go + Wails + React**
   - Backend: Go 1.23 + go-duckdb
   - Frontend: React 19 + Vite
   - Bridge: Wails v2.11
   - Notes: stick to Go 1.23.x and Node 23.3.x + pnpm 10.18.x to avoid dependency breakage
   - Status: Active development; core flows work but still under review for release

3. **Rust + Tauri + Svelte** - POC stage
   - Backend: Rust 1.83 + duckdb-rs
   - Frontend: Svelte + Vite
   - Bridge: Tauri v1 (v2 upgrade deferred; keep tauri = 1.8, tauri-build = 1.5 config v1)
   - Status: Known compatibility issues, under development

## Quick Start

### Prerequisites

All platforms require:
- Git
- Node.js 23.x with pnpm 10.x (pinned to avoid dependency breakage)
- Go 1.23.x
- Python 3.12.x + uv
- Platform-specific toolchains (see setup guides)

### Installation

#### macOS / Linux
```bash
git clone https://github.com/mauriciomenon/mdb2sql.git
cd mdb2sql
git checkout dev
```

#### Windows
```powershell
git clone https://github.com/mauriciomenon/mdb2sql.git
cd mdb2sql
git checkout dev
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
cd go_wails_react
go mod tidy
wails dev
```

#### Rust + Tauri + Svelte
```bash
cd rust_tauri_svelte/ui
pnpm install
cd ../src-tauri
cargo tauri dev
```

## Documentation

### Setup Guides
- [SetupWindows.md](SetupWindows.md) - Complete Windows 11 installation
- [SetupDebian.md](SetupDebian.md) - Debian 13.2 Stable setup
- [SetupSummary.md](SetupSummary.md) - Quick reference for all platforms

### Project Documentation
- [ProjectSpec.md](ProjectSpec.md) - Complete project specification
- [temp/ErrosEProblemasPoc.md](temp/ErrosEProblemasPoc.md) - Known issues and solutions
- `scripts/generate_md_pdfs.sh` - requires pandoc + xelatex (MiKTeX/texlive-xetex) to export docs as PDF
- Build outputs: Vite defaults to `dist/<platform>-<arch>` (override with `OUT_DIR`), Wails binaries in `build/bin/<os>-<arch>`, Tauri in `src-tauri/target/<triple>`, Python builds under `build/<os>-<arch>/`.
- Sanity: `scripts/run_sanity.sh` runs go test/vet/build (+ frontend build), cargo test, and uv pytest using pinned tools.
- Packaging: `scripts/package_minimal.sh` gera `build/minimal/minimal_<os>_<arch>.zip` apenas com binarios e READMEs.
- Windows equivalents: `scripts/run_sanity.ps1`, `scripts/package_minimal.ps1`, `scripts/validate_build.ps1` para o mesmo fluxo em PowerShell.
- Release build helpers: `scripts/build_release.sh` / `scripts/build_release.ps1` geram binarios em `build/bin/<os>-<arch>`, `src-tauri/target/**/release`, `py_qt6/build/<os>-<arch>` antes do pacote minimo.
- Clean: `scripts/clean.sh` / `scripts/clean.ps1` removem dist/target/build/minimal por OS/arch.
- POC note: frontend Go/Wails `App.jsx` e um hello local sem IPC; para demo real exporte metodo no backend e ajuste o frontend.

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
│   ├── src-tauri/       # Rust backend
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
cd rust_tauri_svelte/src-tauri
cargo test
```

## Known Issues

### Rust + Tauri + Svelte
- Tauri v1 config; v2 upgrade deferred
- Arrow Flight dependency linker errors on some platforms
- See [temp/ErrosEProblemasPoc.md](temp/ErrosEProblemasPoc.md) for workarounds

### Go + Wails
- WebView2 required on Windows (auto-installs on first run)
- May require firewall exceptions for dev server

## Version History

### v0.4.0 (Current - Documentation Standardization)
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
