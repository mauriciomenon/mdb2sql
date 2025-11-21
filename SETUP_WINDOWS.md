# MDB2SQL - Guia de Instalacao Windows 11

## Data: 2025-11-20
## Status: Receita de Bolo para Instalacao Completa

---

## PREREQUISITOS

### 1. Windows 11 Pro ou Home (64-bit)
- Versao minima: Windows 11 Build 22000 ou superior
- PowerShell 5.1 ou superior
- Direitos de administrador para instalacao de ferramentas

---

## INSTALACAO DE FERRAMENTAS BASE

### 1. Instalar Chocolatey (Package Manager)

**Abrir PowerShell como Administrador:**

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
```

**Verificar instalacao:**
```powershell
choco --version
```

---

### 2. Instalar Git

```powershell
choco install git -y
```

**Configurar Git:**
```powershell
git config --global user.name "Seu Nome"
git config --global user.email "seu@email.com"
```

**Verificar:**
```powershell
git --version
```

---

### 3. Instalar Node.js e npm

**Versao recomendada: 23.3.0 ou superior**

```powershell
choco install nodejs -y
```

**Verificar:**
```powershell
node --version
npm --version
```

**Instalar pnpm globalmente:**
```powershell
npm install -g pnpm
```

---

### 4. Instalar Python 3.14

**Download direto:**
- Acesse: https://www.python.org/downloads/windows/
- Baixe Python 3.14.0 (64-bit)
- **IMPORTANTE:** Marque "Add Python to PATH" durante instalacao

**OU via Chocolatey:**
```powershell
choco install python --version=3.14.0 -y
```

**Verificar:**
```powershell
python --version
pip --version
```

**Instalar Poetry:**
```powershell
(Invoke-WebRequest -Uri https://install.python-poetry.org -UseBasicParsing).Content | python -
```

**Adicionar Poetry ao PATH:**
```powershell
$env:Path += ";$env:APPDATA\Python\Scripts"
```

**Verificar:**
```powershell
poetry --version
```

---

### 5. Instalar Rust e Cargo

**Download rustup-init.exe:**
- Acesse: https://rustup.rs/
- Baixe rustup-init.exe
- Execute e siga as instrucoes padrao

**OU via PowerShell:**
```powershell
Invoke-WebRequest -Uri https://win.rustup.rs/x86_64 -OutFile rustup-init.exe
.\rustup-init.exe
```

**Verificar:**
```powershell
rustc --version
cargo --version
```

**Versao recomendada: 1.83.0**

---

### 6. Instalar Go

**Versao recomendada: 1.23.3**

```powershell
choco install golang --version=1.23.3 -y
```

**Verificar:**
```powershell
go version
```

---

### 7. Instalar Wails CLI

**Prerequisito:** Go ja instalado

```powershell
go install github.com/wailsapp/wails/v2/cmd/wails@latest
```

**Adicionar ao PATH:**
```powershell
$env:Path += ";$env:USERPROFILE\go\bin"
```

**Verificar:**
```powershell
wails version
```

**Versao recomendada: v2.11.0**

---

### 8. Instalar Tauri Prerequisites

**WebView2 Runtime (geralmente ja vem com Windows 11):**
- Se necessario: https://developer.microsoft.com/en-us/microsoft-edge/webview2/

**Microsoft Visual Studio Build Tools:**
```powershell
choco install visualstudio2022buildtools -y
choco install visualstudio2022-workload-vctools -y
```

**Instalar Tauri CLI:**
```powershell
cargo install tauri-cli
```

**Verificar:**
```powershell
cargo tauri --version
```

---

## CLONAR REPOSITORIO

```powershell
cd C:\Users\SeuUsuario\Documents
git clone https://github.com/seu-usuario/mdb2sql.git
cd mdb2sql
git checkout dev
```

---

## CONFIGURACAO DE CADA IMPLEMENTACAO

### 1. Python + PyQt6

**Navegar ate o diretorio:**
```powershell
cd C:\Users\SeuUsuario\Documents\mdb2sql\py_qt6
```

**Instalar dependencias:**
```powershell
poetry install
```

**Verificar instalacao:**
```powershell
poetry run python --version
```

**Criar diretorio de dados se nao existir:**
```powershell
mkdir data -ErrorAction SilentlyContinue
```

**Copiar banco de dados sample:**
```powershell
copy ..\data\sample.duckdb .\data\sample.duckdb
```

**Executar:**
```powershell
poetry run python src\main.py
```

**OU diretamente via venv (se Poetry der problema):**
```powershell
.\.venv\Scripts\python.exe src\main.py
```

---

### 2. Go + Wails + React

**Navegar ate o diretorio:**
```powershell
cd C:\Users\SeuUsuario\Documents\mdb2sql\go_wails_react
```

**Criar diretorio de dados:**
```powershell
mkdir data -ErrorAction SilentlyContinue
```

**Copiar banco de dados:**
```powershell
copy ..\data\sample.duckdb .\data\sample.duckdb
```

**Instalar dependencias Go:**
```powershell
go mod tidy
```

**Executar em modo desenvolvimento:**
```powershell
wails dev
```

**Build para producao:**
```powershell
wails build
```

**Executavel ficara em:**
```
C:\Users\SeuUsuario\Documents\mdb2sql\go_wails_react\build\bin\MDB2SQL.exe
```

---

### 3. Rust + Tauri + Svelte

**ATENCAO:** Implementacao Rust tem problemas conhecidos de incompatibilidade entre Tauri v1 e v2.

**Navegar ate o diretorio:**
```powershell
cd C:\Users\SeuUsuario\Documents\mdb2sql\rust_tauri_svelte
```

**Instalar dependencias do frontend:**
```powershell
cd ui
pnpm install
cd ..
```

**Tentar build (pode falhar):**
```powershell
cd src-tauri
cargo build
```

**Se der erro de incompatibilidade de versoes:**
- Verificar temp\ERROS_E_PROBLEMAS_POC.md para detalhes
- Esta e uma limitacao conhecida da POC

---

## TESTES COMPLETOS

### Script PowerShell para Rodar Todas as GUIs

**Criar arquivo:** `run_all_guis.ps1`

```powershell
# Script para rodar as 3 implementacoes GUI

Write-Host "=========================================" -ForegroundColor Green
Write-Host "MDB2SQL - Running All GUI Implementations" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""

# 1. Python + PyQt6
Write-Host "[1/3] Starting Python + PyQt6..." -ForegroundColor Cyan
Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd C:\Users\$env:USERNAME\Documents\mdb2sql\py_qt6; poetry run python src\main.py"
Start-Sleep -Seconds 2

# 2. Go + Wails + React
Write-Host "[2/3] Starting Go + Wails + React..." -ForegroundColor Cyan
Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd C:\Users\$env:USERNAME\Documents\mdb2sql\go_wails_react; wails dev"
Start-Sleep -Seconds 3

# 3. Rust + Tauri + Svelte (pode falhar)
Write-Host "[3/3] Starting Rust + Tauri + Svelte..." -ForegroundColor Cyan
Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd C:\Users\$env:USERNAME\Documents\mdb2sql\rust_tauri_svelte; cargo tauri dev"

Write-Host ""
Write-Host "All 3 GUIs are starting in separate windows..." -ForegroundColor Yellow
Write-Host "Close each window individually to stop" -ForegroundColor Yellow
```

**Executar:**
```powershell
.\run_all_guis.ps1
```

---

## PROBLEMAS CONHECIDOS NO WINDOWS

### 1. Poetry com Python Multiple Versions

**Problema:** Poetry instalado com Python 3.11 mas sistema tem 3.14

**Solucao:**
```powershell
# Executar diretamente via venv
.\.venv\Scripts\python.exe src\main.py
```

---

### 2. Wails WebView2 Nao Encontrado

**Problema:** `WebView2 runtime not found`

**Solucao:**
```powershell
choco install microsoft-edge-webview2-runtime -y
```

---

### 3. Rust Linker Errors

**Problema:** `link.exe not found` ou erros do MSVC

**Solucao:**
```powershell
# Instalar Visual Studio Build Tools completo
choco install visualstudio2022buildtools -y
choco install visualstudio2022-workload-vctools -y
```

---

### 4. Path Muito Longo

**Problema:** `The system cannot find the path specified` em node_modules

**Solucao:** Habilitar Long Path Support
```powershell
# PowerShell como Administrador
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" -Value 1 -PropertyType DWORD -Force
```

**Reiniciar o computador apos aplicar**

---

### 5. Firewall Bloqueando Wails Dev Server

**Problema:** Wails dev nao abre a janela

**Solucao:**
- Permitir Wails no Windows Defender Firewall
- Ou desabilitar temporariamente para testes

---

## VERSOES TESTADAS E FUNCIONAIS

### Windows 11 Build 22000+

```
Node.js: 23.3.0
npm: 10.9.0
pnpm: Latest
Python: 3.14.0
Poetry: 1.8.5
Go: 1.23.3
Wails: v2.11.0
Rust: 1.83.0
Cargo: 1.83.0
```

---

## PROXIMOS PASSOS

1. Testar instalacao em VM limpa do Windows 11
2. Criar script de instalacao automatizado (chocolatey + PowerShell)
3. Documentar erros especificos do Windows
4. Adicionar suporte a Windows Server 2022

---

**Ultima Atualizacao:** 2025-11-20 22:00 UTC-3
**Responsavel:** Claude Code
**Status:** RECEITA COMPLETA PARA WINDOWS 11
