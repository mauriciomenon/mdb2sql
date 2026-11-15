# Build de release do app Tauri no Windows: instaladores NSIS e MSI sem caminhos locais embutidos.
# Uso: pwsh -NoProfile -File rust_tauri_svelte/build_windows.ps1
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# troca a pasta do usuario (registry do cargo) e a pasta do projeto por caminhos neutros nas mensagens do binario
$env:RUSTFLAGS = "--remap-path-prefix=$HOME=~ --remap-path-prefix=$PSScriptRoot=."
# o duckdb bundled e C++ compilado pelo MSVC (crate cc le CFLAGS/CXXFLAGS); /d1trimfile tira o prefixo do __FILE__
$env:CFLAGS = "/d1trimfile:$PSScriptRoot\"
$env:CXXFLAGS = "/d1trimfile:$PSScriptRoot\"

cargo tauri build
if ($LASTEXITCODE) { throw "cargo tauri build falhou ($LASTEXITCODE)" }
Get-ChildItem target\release\bundle\nsis\*.exe, target\release\bundle\msi\*.msi | Select-Object Name, Length, LastWriteTime
