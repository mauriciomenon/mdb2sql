<# Executa as 3 GUIs com validação básica de caminhos. #>
$ErrorActionPreference = "Stop"

$ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
$ROOT = Resolve-Path (Join-Path $ROOT ".")

Write-Host "========================================="
Write-Host "MDB2SQL - Running All GUI Implementations"
Write-Host "========================================="
Write-Host ""

# Python + PyQt6
Push-Location (Join-Path $ROOT "py_qt6")
if (-not (Test-Path "src/main.py")) { throw "PyQt6 main not found" }
Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd \"$PWD\"; uv run python src/main.py"
Pop-Location

# Go + Wails + React
Push-Location (Join-Path $ROOT "go_wails_react")
if (-not (Test-Path "main.go")) { throw "Go Wails main.go not found" }
Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd \"$PWD\"; wails dev"
Pop-Location

# Rust + Tauri + Svelte
Push-Location (Join-Path $ROOT "rust_tauri_svelte")
if (-not (Test-Path "src/main.rs")) { throw "Rust Tauri main.rs not found" }
Start-Process powershell -ArgumentList "-NoExit", "-Command", "cd \"$PWD\"; cargo tauri dev"
Pop-Location

Write-Host ""
Write-Host "All implementations launching in separate windows"
Write-Host "Close each window individually to terminate"
