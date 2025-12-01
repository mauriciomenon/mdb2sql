<# Gera pacote minimal (Windows/PowerShell). Copia binarios existentes e READMEs. #>

$ErrorActionPreference = "Stop"

$ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
$ROOT = Resolve-Path (Join-Path $ROOT "..")
$OS = if ($env:TARGET_OS) { $env:TARGET_OS } else { $env:OS }
$ARCH = if ($env:TARGET_ARCH) { $env:TARGET_ARCH } else { $env:PROCESSOR_ARCHITECTURE }
$PACKAGE_DIR = Join-Path $ROOT "build\minimal"
$ZIP_NAME = "minimal_${OS}_${ARCH}.zip"

Remove-Item -Recurse -Force $PACKAGE_DIR -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $PACKAGE_DIR | Out-Null

Write-Host "[INFO] Copiando Go/Wails binarios se existirem"
$goBinSrc = Join-Path $ROOT ("go_wails_react/build/bin/{0}-{1}" -f $OS,$ARCH)
if (Test-Path $goBinSrc) {
  New-Item -ItemType Directory -Force -Path (Join-Path $PACKAGE_DIR "go_wails_react") | Out-Null
  Copy-Item -Recurse $goBinSrc (Join-Path $PACKAGE_DIR "go_wails_react")
} else { throw "Binario Go/Wails nao encontrado em $goBinSrc (execute wails build e organize em build/bin/<os>-<arch>)" }

Write-Host "[INFO] Copiando Rust/Tauri binarios release se existirem"
$rustSrc = Join-Path $ROOT "rust_tauri_svelte/src-tauri/target"
$rustBins = Get-ChildItem $rustSrc -Recurse -Filter "mdb2sql*" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match "release" }
if ($rustBins) {
  New-Item -ItemType Directory -Force -Path (Join-Path $PACKAGE_DIR "rust_tauri_svelte") | Out-Null
  foreach ($b in $rustBins) { Copy-Item $b.FullName (Join-Path $PACKAGE_DIR "rust_tauri_svelte") }
} else { throw "Binario Rust/Tauri release nao encontrado (execute cargo tauri build)" }

Write-Host "[INFO] Copiando build Python/PyQt6 se existir"
$pyBuild = Join-Path $ROOT ("py_qt6/build/{0}-{1}" -f $OS,$ARCH)
if (Test-Path $pyBuild) {
  New-Item -ItemType Directory -Force -Path (Join-Path $PACKAGE_DIR "py_qt6") | Out-Null
  Copy-Item -Recurse $pyBuild (Join-Path $PACKAGE_DIR "py_qt6")
} else { throw "Build Python/PyQt6 nao encontrado em $pyBuild (execute pyinstaller/nuitka com saida em build/<os>-<arch>)" }

Write-Host "[INFO] Adicionando READMEs"
Get-ChildItem $ROOT -MaxDepth 1 -File | Where-Object { $_.Name -match "^README\.(md|txt)$" } | ForEach-Object {
  Copy-Item $_.FullName $PACKAGE_DIR
}

Write-Host "[INFO] Gerando zip"
$parentDir = Split-Path $PACKAGE_DIR -Parent
Push-Location $parentDir
if (Test-Path $ZIP_NAME) { Remove-Item $ZIP_NAME }
Compress-Archive -Path (Split-Path $PACKAGE_DIR -Leaf) -DestinationPath $ZIP_NAME
Pop-Location

Write-Host "[INFO] Pacote criado em $(Join-Path $parentDir $ZIP_NAME)"
