# MDB2SQL - Setup Guide for Windows 11

> Nota (2026-11-14): `go_wails_react/go.mod` exige Go 1.26 e Wails v2.13.0 (atualizacoes de seguranca das
> dependencias) e usa `github.com/duckdb/duckdb-go/v2` v2.20000.0 (DuckDB 2.0.0 estatico, sem DLL). A secao
> GO + WAILS + REACT abaixo tem as versoes exatas. Python do `python_pyqt6`: 3.12 (o duckdb travado no uv.lock nao tem
> wheel para 3.15).

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

#### Install Go 1.26.x
```powershell
winget install GoLang.Go
```

Verify:
```powershell
go version  # 1.26.x, or newer (see the GOTOOLCHAIN note in the Wails CLI step)
```

#### Install a C toolchain for cgo (MinGW-w64 GCC, UCRT runtime)
DuckDB comes from the Go module `github.com/duckdb/duckdb-go/v2` v2.20000.0, which downloads the official
prebuilt static libraries of DuckDB 2.0.0 for windows/amd64 (`go.duckdb.org/libduckdb/windows-amd64`, verified by
go.sum). They are linked into `mdb2sql.exe`: there is no `duckdb.dll` to download, install or ship.

The link step needs GNU GCC + libstdc++ built for the UCRT runtime. Other toolchains fail at link time:
llvm-mingw/clang (`undefined symbol: std::...`, `pthread_...`) and msvcrt MinGW builds such as the one bundled with
Qt (`undefined reference to __stdio_common_vsnprintf_s`).

Tested with WinLibs GCC 16.2.0 + MinGW-w64 14.0.0 UCRT r3 (also `winget install BrechtSanders.WinLibs.POSIX.UCRT`):
```powershell
# https://github.com/brechtsanders/winlibs_mingw/releases/tag/16.2.0posix-23.1.3-14.0.0-ucrt-r3
# winlibs-x86_64-posix-seh-gcc-16.2.0-mingw-w64ucrt-14.0.0-r3.zip
# SHA-256 3c69305081e4a647144339a936244fcf7d3d9e558319e1ad7be2cd2886d4b6a1
# Extract anywhere (example below) and put it FIRST in PATH of the build shell:
$env:Path = "$env:USERPROFILE\.local\winlibs-gcc-16.2.0-ucrt-r3\mingw64\bin;$env:Path"
gcc --version   # must say x86_64-ucrt-posix-seh
```
Alternative recommended by duckdb-go (not tested here): MSYS2, `pacman -S mingw-w64-ucrt-x86_64-gcc`, with
`C:\msys64\ucrt64\bin` first in PATH.

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
go install github.com/wailsapp/wails/v2/cmd/wails@v2.13.0
```

Add to PATH (PowerShell as Admin):
```powershell
$env:Path += ";$env:USERPROFILE\go\bin"
[Environment]::SetEnvironmentVariable("Path", $env:Path, "User")
```

Verify:
```powershell
wails version  # v2.13.0 (must match go_wails_react/go.mod)
wails doctor
```

With Go 1.27 installed, Wails CLI 2.13.0 stops with
`internal error: package "database/sql" without types was imported` (its bundled golang.org/x/tools is older than
Go 1.27). Run the CLI with the Go 1.26 toolchain; Go downloads it by itself:
```powershell
$env:GOTOOLCHAIN = "go1.26.11"
```
`go build`, `go test` and `go vet` work with Go 1.27 without this.

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
cd go_wails_react\frontend
pnpm install --frozen-lockfile   # workspace member; uses the root pnpm-lock.yaml
pnpm run build                   # main.go embeds frontend/dist; go build/vet fail without it
cd ..
go test ./...
go vet ./...
go build ./...
wails dev
wails build -platform windows/amd64   # build\bin\mdb2sql.exe, single file, no DLL next to it
```

`wails build` runs `pnpm install --frozen-lockfile` and `pnpm run build` by itself (`frontend:install` /
`frontend:build` in wails.json). The linker line `.rsrc merge failure: multiple non-default manifests` is a warning:
the exe still carries the Wails manifest, icon and version info.

In the app: **Load database** opens a file dialog (.duckdb, .db, .sqlite, .sqlite3); **Sample data** loads
`MDB2SQL_DB_PATH` or `data/sample.duckdb`. The Go app reads DuckDB files; it does not convert .mdb/.accdb.

The first link of DuckDB takes 1-2 minutes. The `no_duckdb_arrow` tag of older guides is no longer needed:
duckdb-go v2 only builds Arrow with `-tags duckdb_arrow`.

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
rustc --version  # Should show 1.90+ (Tauri 2.12)
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
cargo install tauri-cli --version "^2" --locked
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
cd python_pyqt6
uv sync
uv run python -m src.main
```
**Build binario (dist em build\windows-<arch>):**
```powershell
uv run pyinstaller --onefile --windowed --distpath build\windows-$env:PROCESSOR_ARCHITECTURE src\main.py
```

**Alternative sem uv**:
```powershell
cd python_pyqt6
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
**Fix**: Only occurs during `cargo tauri build`, not dev. The Tauri v2 CLI downloads NSIS/WiX on the first build; check network access.

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
cd python_pyqt6
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
# Output: target/release/bundle/nsis/MDB2SQL_0.1.0_x64-setup.exe (+ bundle/msi/*.msi)
```

### Python/PyQt6 (using PyInstaller)
```powershell
cd python_pyqt6
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
cd python_pyqt6 && uv run python -m src.main
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
