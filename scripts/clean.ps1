<# Limpa artefatos por OS/arch #>
$ErrorActionPreference = "Stop"
$ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
$ROOT = Resolve-Path (Join-Path $ROOT "..")
$OS = if ($env:TARGET_OS) { $env:TARGET_OS } else { $env:OS }
$ARCH = if ($env:TARGET_ARCH) { $env:TARGET_ARCH } else { $env:PROCESSOR_ARCHITECTURE }

Write-Host "[INFO] Cleaning dist/build/target/minimal for $OS-$ARCH"
Remove-Item -Recurse -Force (Join-Path $ROOT "go_wails_react/frontend/dist/$OS-$ARCH") -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force (Join-Path $ROOT "go_wails_react/build/bin/$OS-$ARCH") -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force (Join-Path $ROOT "rust_tauri_svelte/src-tauri/target") -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force (Join-Path $ROOT "rust_tauri_svelte/ui/dist/$OS-$ARCH") -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force (Join-Path $ROOT "py_qt6/build/$OS-$ARCH") -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force (Join-Path $ROOT "build/minimal") -ErrorAction SilentlyContinue
