# MDB2SQL - Setup Guide for Windows 11

**Target OS**: Windows 11 (x64)
**Last Updated**: 2025-11-16

---

## PREREQUISITES

### 1. Install Windows Terminal (Optional but Recommended)
```powershell
winget install Microsoft.WindowsTerminal
```

### 2. Install Git for Windows
```powershell
winget install Git.Git
```

Restart terminal after install.

---

## STACK-SPECIFIC SETUP

### GO + WAILS + REACT

#### Install Go 1.21+
```powershell
winget install GoLang.Go
```

Verify:
```powershell
go version  # Should show 1.21+
```

#### Install Node.js 20+
```powershell
winget install OpenJS.NodeJS.LTS
```

Verify:
```powershell
node --version  # Should show v20+
npm --version
```

#### Install Wails CLI
```powershell
go install github.com/wailsapp/wails/v2/cmd/wails@latest
```

Add to PATH (PowerShell as Admin):
```powershell
$env:Path += ";$env:USERPROFILE\go\bin"
[Environment]::SetEnvironmentVariable("Path", $env:Path, "User")
```

Verify:
```powershell
wails version  # Should show v2.11+
```

#### PDF Toolchain (pandoc + MiKTeX) - opcional para gerar PDFs de docs
```powershell
winget install Pandoc.Pandoc
winget install MiKTeX.MiKTeX
pandoc --version
xelatex --version
```

Usado por `scripts/generate_md_pdfs.sh`.

#### Install WebView2 Runtime (Required for Wails)
Usually pre-installed on Windows 11. If missing:
```powershell
winget install Microsoft.EdgeWebView2Runtime
```

#### Build Go/Wails Implementation
```powershell
cd go_wails_react
go mod tidy
cd frontend
npm install
cd ..
wails dev
```

**CRITICAL**: If you get Arrow linker errors:
```powershell
# Build without Arrow (recommended - Arrow not needed)
wails dev -tags no_duckdb_arrow
wails build -tags no_duckdb_arrow
```

**Expected**: Window opens with database viewer showing sample data.

---

### RUST + TAURI + SVELTE

#### Install Rust via rustup
Download and run: https://rust-lang.org/tools/install

Or via winget:
```powershell
winget install Rustlang.Rustup
```

Restart terminal, then verify:
```powershell
rustc --version  # Should show 1.70+
cargo --version
```

#### Install Node.js (if not already installed)
See Go/Wails section above.

#### Install Visual Studio Build Tools
Required for Rust native compilation:
```powershell
winget install Microsoft.VisualStudio.2022.BuildTools
```

During install, select:
- Desktop development with C++
- Windows 10/11 SDK

#### Install Tauri Prerequisites
```powershell
# WebView2 already installed (see Wails section)
```

#### Build Rust/Tauri Implementation
```powershell
cd rust_tauri_svelte
cargo check  # Download deps and verify build
cd ui
pnpm install
cd ..
cargo tauri dev
```

**Expected**: Window opens with database viewer showing sample data.

---

### PYTHON + PYQT6

#### Install Python 3.12
```powershell
winget install Python.Python.3.12
```

Verify:
```powershell
python --version  # Should show 3.12.x
pip --version
```

#### Install uv (Python dependency manager)
```powershell
irm https://astral.sh/uv/install.ps1 | iex
```

Verify:
```powershell
uv --version
```

#### Build Python/PyQt6 Implementation
```powershell
cd py_qt6
uv sync
uv run python -m src.main
```
**Build binario (dist em build\windows-<arch>):**
```powershell
uv run pyinstaller --onefile --windowed --distpath build\windows-$env:PROCESSOR_ARCHITECTURE src\main.py
```

**Alternative sem uv**:
```powershell
cd py_qt6
python -m venv venv
.\venv\Scripts\activate
pip install .
python -m src.main
```

**Expected**: Qt window opens with database viewer showing sample data.

---

## LOADING SAMPLE DATABASE

All implementations look for database at:
```
data/sample.duckdb
```

### Option 1: Use Environment Variable
```powershell
$env:MDB2SQL_DB_PATH="C:\path\to\your\database.duckdb"
```

### Option 2: Copy Sample Database
```powershell
# Assuming you have a converted DuckDB file
copy path\to\sample.duckdb data\sample.duckdb
```

---

## COMMON ISSUES

### Go: "wails: command not found"
**Fix**: Add `%USERPROFILE%\go\bin` to PATH (see Wails install section)

### Rust: "linker 'link.exe' not found"
**Fix**: Install Visual Studio Build Tools with C++ workload

### Python: "No module named 'PyQt6'"
**Fix**: Run `uv sync` (ou `pip install .` se não usar uv)

### Wails: "Failed to detect webview2"
**Fix**: Install WebView2 Runtime (see Wails section)

### Tauri: "NSIS error"
**Fix**: Only occurs during build, not dev. Ignore for development.

---

## RUNNING TESTS

### Go/Wails
```powershell
cd go_wails_react
go test ./...
```

### Rust/Tauri
```powershell
cd rust_tauri_svelte
cargo test
```

### Python/PyQt6
```powershell
cd py_qt6
uv run pytest  # If tests implemented
```

---

## BUILDING FOR PRODUCTION

### Go/Wails
```powershell
cd go_wails_react
wails build
# Output: build/bin/mdb2sql.exe
```

### Rust/Tauri
```powershell
cd rust_tauri_svelte
cargo tauri build
# Output: target/release/bundle/nsis/mdb2sql_0.1.0_x64-setup.exe
```

### Python/PyQt6 (using PyInstaller)
```powershell
cd py_qt6
uv add --dev pyinstaller
uv run pyinstaller --onefile --windowed src/main.py
# Output: dist/main.exe
```

---

## DEVELOPMENT WORKFLOW

1. Start implementation in dev mode
2. Make code changes
3. Hot reload updates UI automatically
4. Check console for errors
5. Test with sample database

**Dev Mode Commands**:
```powershell
# Go/Wails
cd go_wails_react && wails dev

# Rust/Tauri
cd rust_tauri_svelte && cargo tauri dev

# Python/PyQt6
cd py_qt6 && uv run python -m src.main
```

---

## NOTES FOR WINDOWS 11

- **WebView2** is built-in (Edge-based)
- **Windows Defender** may scan first build (slow)
- **PowerShell 7** recommended over PowerShell 5.1
- **WSL2** not required but useful for cross-platform testing
- **Path separators**: Use `\` or `/` (both work in PowerShell)

---

**Setup finalizado. Prosseguir para a stack desejada conforme os guias.**
