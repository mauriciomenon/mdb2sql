# MDB2SQL

Multi-platform desktop application for converting Microsoft Access databases (.mdb) to DuckDB format with advanced search, filtering, and comparison capabilities.

## Project Overview

MDB2SQL provides three independent GUI implementations showcasing different technology stacks, each demonstrating the same core functionality: loading, viewing, and querying DuckDB databases converted from Microsoft Access.

### Technology Stacks

1. **Python + PyQt6** - Feature complete
   - Backend: Python 3.14 + DuckDB
   - UI: PyQt6 native widgets
   - Status: Fully functional, production-ready

2. **Go + Wails + React** - Feature complete
   - Backend: Go 1.23 + go-duckdb
   - Frontend: React 19 + Vite
   - Bridge: Wails v2.11
   - Status: Fully functional, production-ready

3. **Rust + Tauri + Svelte** - POC stage
   - Backend: Rust 1.83 + duckdb-rs
   - Frontend: Svelte + Vite
   - Bridge: Tauri v2
   - Status: Known compatibility issues, under development

## Quick Start

### Prerequisites

All platforms require:
- Git
- Node.js 23.x with pnpm 10.x
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
poetry install
poetry run python src/main.py
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
- Python: Poetry (pyproject.toml)
- JavaScript/TypeScript: pnpm (packageManager field in package.json)
- Go: Go modules (go.mod)
- Rust: Cargo (Cargo.toml)

### Testing

#### Python
```bash
cd py_qt6
poetry run pytest tests/
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
- Tauri v1/v2 compatibility issues
- Arrow Flight dependency linker errors on some platforms
- See [temp/ErrosEProblemasPoc.md](temp/ErrosEProblemasPoc.md) for workarounds

### Go + Wails
- WebView2 required on Windows (auto-installs on first run)
- May require firewall exceptions for dev server

## Version History

### v0.1.0 (Current - POC Stage)
- ✅ Python implementation complete
- ✅ Go implementation complete
- 🔄 Rust implementation in progress
- ✅ Dual-level code documentation
- ✅ Security hardening (path traversal, SQL injection)
- ✅ Platform setup guides (Windows 11, Debian 13.2)

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
