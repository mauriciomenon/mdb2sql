# MDB2SQL - Windows 11 Installation Guide

## Document Information
- **Date**: 2025-11-20
- **Platform**: Windows 11 Pro/Home (64-bit)
- **Minimum Build**: 22000

---

## Prerequisites

### System Requirements
- Windows 11 Build 22000 or higher (64-bit)
- PowerShell 5.1 or higher
- Administrator privileges for tool installation
- 8GB RAM minimum (16GB recommended)
- 10GB free disk space

---

## Base Tools Installation

### 1. Install Git

**Using winget:**
```powershell
winget install --id Git.Git -e --source winget
```

**Direct download alternative:**
- URL: https://git-scm.com/download/win
- Download Git for Windows (64-bit)
- Run installer with default options

**Configure Git:**
```powershell
git config --global user.name "Your Name"
git config --global user.email "your@email.com"
```

**Verify installation:**
```powershell
git --version
```

---

### 2. Install Node.js 23.x

**Using winget:**
```powershell
winget install OpenJS.NodeJS
```

**Direct download alternative:**
- URL: https://nodejs.org/en/download/
- Download Node.js 23.3.0 LTS (64-bit Windows Installer)
- Run installer with default options

**Verify installation:**
```powershell
node --version
npm --version
```

**Install pnpm globally:**
```powershell
npm install -g pnpm@10.18.2
```

**Verify pnpm:**
```powershell
pnpm --version
```

---

### 3. Install Python 3.14

**Direct download (recommended):**
- URL: https://www.python.org/downloads/windows/
- Download Python 3.14.0 (64-bit)
- **CRITICAL**: Check "Add Python to PATH" during installation
- Select "Install for all users" if prompted

**Verify installation:**
```powershell
python --version
pip --version
```

**Install Poetry:**
```powershell
(Invoke-WebRequest -Uri https://install.python-poetry.org -UseBasicParsing).Content | python -
```

**Add Poetry to PATH:**
```powershell
$env:Path += ";$env:APPDATA\Python\Scripts"
[Environment]::SetEnvironmentVariable("Path", $env:Path, [System.EnvironmentVariableTarget]::User)
```

**Verify Poetry:**
```powershell
poetry --version
```

---

### 4. Install Rust 1.83.0

**Direct download:**
- URL: https://rustup.rs/
- Download rustup-init.exe
- Run with default options (select option 1)

**PowerShell alternative:**
```powershell
Invoke-WebRequest -Uri https://win.rustup.rs/x86_64 -OutFile rustup-init.exe
.\rustup-init.exe -y
```

**Refresh environment:**
```powershell
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
```

**Verify installation:**
```powershell
rustc --version
cargo --version
```

---

### 5. Install Go 1.23.3

**Using winget:**
```powershell
winget install GoLang.Go
```

**Direct download alternative:**
- URL: https://go.dev/dl/
- Download go1.23.3.windows-amd64.msi
- Run installer with default options

**Verify installation:**
```powershell
go version
```

---

### 6. Install Wails v2.11.0

**Prerequisites:** Go must be installed first

```powershell
go install github.com/wailsapp/wails/v2/cmd/wails@latest
```

**Add to PATH:**
```powershell
$env:Path += ";$env:USERPROFILE\go\bin"
[Environment]::SetEnvironmentVariable("Path", $env:Path, [System.EnvironmentVariableTarget]::User)
```

**Verify installation:**
```powershell
wails version
```

---

### 7. Install Tauri Prerequisites

**WebView2 Runtime:**

Check if already installed:
```powershell
Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction SilentlyContinue
```

If not installed, download from:
- URL: https://developer.microsoft.com/en-us/microsoft-edge/webview2/

**Microsoft Visual Studio Build Tools:**

Using winget:
```powershell
winget install Microsoft.VisualStudio.2022.BuildTools
```

Direct download:
- URL: https://visualstudio.microsoft.com/downloads/
- Download "Build Tools for Visual Studio 2022"
- During installation, select "Desktop development with C++"

**Install Tauri CLI:**
```powershell
cargo install tauri-cli
```

**Verify installation:**
```powershell
cargo tauri --version
```

---

## Repository Setup

### Clone Repository

```powershell
cd C:\Users\$env:USERNAME\Documents
git clone https://github.com/your-username/mdb2sql.git
cd mdb2sql
git checkout dev
```

---

## Implementation Configuration

### 1. Python + PyQt6

**Navigate to directory:**
```powershell
cd C:\Users\$env:USERNAME\Documents\mdb2sql\py_qt6
```

**Install dependencies:**
```powershell
poetry install
```

**Verify installation:**
```powershell
poetry run python --version
```

**Create data directory:**
```powershell
New-Item -ItemType Directory -Force -Path data
```

**Copy sample database:**
```powershell
Copy-Item -Path ..\data\sample.duckdb -Destination .\data\sample.duckdb
```

**Run application:**
```powershell
poetry run python src\main.py
```

**Alternative execution (if Poetry has issues):**
```powershell
.\.venv\Scripts\python.exe src\main.py
```

---

### 2. Go + Wails + React

**Navigate to directory:**
```powershell
cd C:\Users\$env:USERNAME\Documents\mdb2sql\go_wails_react
```

**Create data directory:**
```powershell
New-Item -ItemType Directory -Force -Path data
```

**Copy sample database:**
```powershell
Copy-Item -Path ..\data\sample.duckdb -Destination .\data\sample.duckdb
```

**Install Go dependencies:**
```powershell
go mod tidy
```

**Run in development mode:**
```powershell
wails dev
```

**Build for production:**
```powershell
wails build
```

**Executable location:**
```
C:\Users\$env:USERNAME\Documents\mdb2sql\go_wails_react\build\bin\MDB2SQL.exe
```

---

### 3. Rust + Tauri + Svelte

**WARNING:** This implementation has known compatibility issues between Tauri v1 and v2.

**Navigate to directory:**
```powershell
cd C:\Users\$env:USERNAME\Documents\mdb2sql\rust_tauri_svelte
```

**Install frontend dependencies:**
```powershell
cd ui
pnpm install
cd ..
```

**Attempt build (may fail):**
```powershell
cd src-tauri
cargo build
```

**On version incompatibility errors:**
- Refer to temp\ERROS_E_PROBLEMAS_POC.md for details
- This is a known POC limitation

---

## Integration Testing

### PowerShell Script to Run All GUIs

**Create file:** `run_all_guis.ps1`

```powershell
# MDB2SQL - Multi-implementation launcher

Write-Host "=========================================" -ForegroundColor Green
Write-Host "MDB2SQL - Launching GUI Implementations" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""

$ProjectRoot = "C:\Users\$env:USERNAME\Documents\mdb2sql"

# Launch Python + PyQt6
Write-Host "[1/3] Launching Python + PyQt6..." -ForegroundColor Cyan
Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd $ProjectRoot\py_qt6; poetry run python src\main.py"
Start-Sleep -Seconds 2

# Launch Go + Wails + React
Write-Host "[2/3] Launching Go + Wails + React..." -ForegroundColor Cyan
Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd $ProjectRoot\go_wails_react; wails dev"
Start-Sleep -Seconds 3

# Launch Rust + Tauri + Svelte (may fail)
Write-Host "[3/3] Launching Rust + Tauri + Svelte..." -ForegroundColor Cyan
Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd $ProjectRoot\rust_tauri_svelte; cargo tauri dev"

Write-Host ""
Write-Host "All implementations launching in separate windows" -ForegroundColor Yellow
Write-Host "Close each window individually to terminate" -ForegroundColor Yellow
```

**Execute:**
```powershell
.\run_all_guis.ps1
```

---

## Troubleshooting

### Poetry Version Conflicts

**Symptom:** Poetry installed with Python 3.11 but system uses 3.14

**Solution:**
```powershell
# Execute directly via venv
.\.venv\Scripts\python.exe src\main.py
```

---

### Wails WebView2 Not Found

**Symptom:** `WebView2 runtime not found`

**Solution:**
```powershell
# Download and install WebView2 Runtime
$WebView2Url = "https://go.microsoft.com/fwlink/p/?LinkId=2124703"
Invoke-WebRequest -Uri $WebView2Url -OutFile "MicrosoftEdgeWebview2Setup.exe"
.\MicrosoftEdgeWebview2Setup.exe /silent /install
```

---

### Rust Linker Errors

**Symptom:** `link.exe not found` or MSVC errors

**Solution:**
```powershell
# Install complete Visual Studio Build Tools
winget install Microsoft.VisualStudio.2022.BuildTools

# During installation, select:
# - Desktop development with C++
# - Windows 10 SDK
```

---

### Long Path Issues

**Symptom:** `The system cannot find the path specified` in node_modules

**Solution - Enable Long Path Support:**
```powershell
# Run PowerShell as Administrator
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" `
  -Name "LongPathsEnabled" `
  -Value 1 `
  -PropertyType DWORD `
  -Force
```

**Restart computer after applying**

---

### Firewall Blocking Wails Dev Server

**Symptom:** Wails dev does not open application window

**Solution:**
1. Open Windows Defender Firewall
2. Allow wails.exe through firewall
3. Or temporarily disable for testing (not recommended for production)

---

## Tested Versions

### Windows 11 Build 22000+

```
Node.js: 23.3.0
npm: 10.9.0
pnpm: 10.18.2
Python: 3.14.0
Poetry: 1.8.5
Go: 1.23.3
Wails: v2.11.0
Rust: 1.83.0
Cargo: 1.83.0
Tauri CLI: 1.5.14
```

---

## Next Steps

1. Test installation on clean Windows 11 VM
2. Create automated installation script (winget + PowerShell)
3. Document Windows-specific edge cases
4. Add Windows Server 2022 support

---

**Last Updated:** 2025-11-20 22:00 UTC-3
**Maintainer:** Development Team
**Document Version:** 1.0
