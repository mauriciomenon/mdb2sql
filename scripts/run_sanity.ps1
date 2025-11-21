<# Sanity script (Windows/PowerShell). Requires Go, pnpm, Rust/cargo, uv installed. #>

$ErrorActionPreference = "Stop"

$ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
$ROOT = Resolve-Path (Join-Path $ROOT "..")
$OS = if ($env:TARGET_OS) { $env:TARGET_OS } else { $env:OS }
$ARCH = if ($env:TARGET_ARCH) { $env:TARGET_ARCH } else { $env:PROCESSOR_ARCHITECTURE }
$OUT_DIR = if ($env:OUT_DIR) { $env:OUT_DIR } else { "dist/$OS-$ARCH" }

Write-Host "[INFO] Go/Wails: backend build+tests"
Push-Location (Join-Path $ROOT "go_wails_react")
go test ./...
go vet ./...
go build -tags=no_duckdb_arrow ./...

Write-Host "[INFO] Go/Wails: frontend install+build (OUT_DIR=$OUT_DIR)"
Push-Location (Join-Path $ROOT "go_wails_react/frontend")
pnpm install --frozen-lockfile=false --prefer-offline | Out-Null
$env:OUT_DIR = $OUT_DIR
pnpm run build
$distIndex = Join-Path (Get-Location) $OUT_DIR
$distIndex = Join-Path $distIndex "index.html"
if (-not (Test-Path $distIndex)) {
  throw "Frontend dist not found at $distIndex"
}
Pop-Location
Pop-Location

Write-Host "[INFO] Rust/Tauri: backend check+tests"
Push-Location (Join-Path $ROOT "rust_tauri_svelte")
cargo test
cargo clippy -- -D warnings
Pop-Location

Write-Host "[INFO] Python/PyQt6: tests"
Push-Location (Join-Path $ROOT "py_qt6")
uv run pytest
uv run ruff check
uv run flake8 src tests --max-line-length 120 --extend-exclude ".venv,venv,env,build,dist,.ruff_cache,data"
Pop-Location

Write-Host "[INFO] Sanity checks completed (OS=$OS, ARCH=$ARCH, OUT_DIR=$OUT_DIR)."
Write-Host "Abrir alguma solucao agora? [g] Go/Wails | [r] Rust/Tauri | [p] Python/PyQt6 | [n] nenhum (default)"
$choice = Read-Host "(g/r/p/n)"
switch ($choice.ToLower()) {
  "g" { Push-Location (Join-Path $ROOT "go_wails_react"); wails dev; Pop-Location }
  "r" { Push-Location (Join-Path $ROOT "rust_tauri_svelte"); cargo tauri dev; Pop-Location }
  "p" { Push-Location (Join-Path $ROOT "py_qt6"); uv run python src/main.py; Pop-Location }
  default { Write-Host "Nenhuma solucao aberta." }
}
