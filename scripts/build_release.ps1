<# Build release por OS/arch (PowerShell) #>
$ErrorActionPreference = "Stop"

$ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
$ROOT = Resolve-Path (Join-Path $ROOT "..")
$OS = if ($env:TARGET_OS) { $env:TARGET_OS } else { $env:OS }
$ARCH = if ($env:TARGET_ARCH) { $env:TARGET_ARCH } else { $env:PROCESSOR_ARCHITECTURE }
$PLATFORM = if ($env:TARGET_PLATFORM) { $env:TARGET_PLATFORM } else { "$($env:GOOS)/$($env:GOARCH)" }

Write-Host "[INFO] Building Go/Wails (platform=$PLATFORM)"
Push-Location (Join-Path $ROOT "go_wails_react")
wails build -clean -tags=no_duckdb_arrow -platform $PLATFORM
$outBin = Join-Path $ROOT ("go_wails_react/build/bin/{0}-{1}" -f $OS,$ARCH)
New-Item -ItemType Directory -Force -Path $outBin | Out-Null
Get-ChildItem (Join-Path $ROOT "go_wails_react/build/bin") -Filter "mdb2sql*" | ForEach-Object { Move-Item -Force $_.FullName $outBin }
Pop-Location

Write-Host "[INFO] Building Rust/Tauri release"
Push-Location (Join-Path $ROOT "rust_tauri_svelte")
cargo tauri build
Pop-Location

Write-Host "[INFO] Building Python/PyQt6 (PyInstaller) for $OS-$ARCH"
Push-Location (Join-Path $ROOT "py_qt6")
if (-not (Get-Command pyinstaller -ErrorAction SilentlyContinue)) { throw "PyInstaller nao encontrado (uv add --dev pyinstaller)" }
$distDir = Join-Path $ROOT ("py_qt6/build/{0}-{1}" -f $OS,$ARCH)
uv run pyinstaller --onefile --windowed --distpath $distDir src/main.py
Pop-Location

Write-Host "[INFO] Build release concluido:"
Write-Host " - Go/Wails: $outBin"
Write-Host " - Rust/Tauri: rust_tauri_svelte/src-tauri/target/**/release/"
Write-Host " - Python/PyQt6: $distDir"
