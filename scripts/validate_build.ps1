<# Valida build e seguranca (PowerShell). Requer Go, pnpm, Rust/cargo, uv. #>
$ErrorActionPreference = "Stop"

$ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
$ROOT = Resolve-Path (Join-Path $ROOT "..")

function Pass($msg) { Write-Host "PASS $msg" -ForegroundColor Green }
function Fail($msg) { Write-Host "FAIL $msg" -ForegroundColor Red }
function Warn($msg) { Write-Host "WARN $msg" -ForegroundColor Yellow }

Write-Host "=== MDB2SQL Build Validation (PowerShell) ==="

Push-Location (Join-Path $ROOT "go_wails_react")
if (Get-Command go -ErrorAction SilentlyContinue) {
  $goVersion = (& go version).Split()[2]
  if ($goVersion -notlike "go1.23.*") { Warn "Go version $goVersion (pin go1.23.x recomendado)" } else { Pass "Go version $goVersion" }
  go test ./... | Out-Null
  go vet ./... | Out-Null
  go build -tags=no_duckdb_arrow ./... | Out-Null
  if (Select-String -Path app.go -Pattern "EvalSymlinks") { Pass "Go path traversal check present" } else { Warn "Go path traversal check missing" }
} else { Fail "Go not found" }
Pop-Location

Push-Location (Join-Path $ROOT "rust_tauri_svelte")
if (Get-Command cargo -ErrorAction SilentlyContinue) {
  $rustVersion = (& rustc --version).Split()[1]
  if ($rustVersion -notlike "1.83.*") { Warn "Rust version $rustVersion (pin 1.83.x recomendado)" } else { Pass "Rust version $rustVersion" }
  cargo test | Out-Null
  cargo clippy -- -D warnings | Out-Null
  if (Select-String -Path src\backend\db_manager.rs -Pattern "canonicalize") { Pass "Rust path traversal check present" } else { Warn "Rust canonicalize not found" }
} else { Fail "Rust not found" }
Pop-Location

Push-Location (Join-Path $ROOT "py_qt6")
if (Get-Command uv -ErrorAction SilentlyContinue) {
  $pyVersion = (& python --version).Split()[1]
  if ($pyVersion -notlike "3.12.*") { Warn "Python version $pyVersion (pin 3.12.x recomendado)" } else { Pass "Python version $pyVersion" }
  uv run pytest | Out-Null
  uv run ruff check | Out-Null
  uv run flake8 src tests --max-line-length 120 --extend-exclude ".venv,venv,env,build,dist,.ruff_cache,data" | Out-Null
  if (Select-String -Path src\backend\db_manager.py -Pattern "\.resolve") { Pass "Python path traversal check present" } else { Warn "Python Path.resolve not found" }
} else { Fail "uv not found" }
Pop-Location

if ((Test-Path (Join-Path $ROOT "SetupWindows.md")) -and (Test-Path (Join-Path $ROOT "SetupDebian.md"))) {
  Pass "Setup docs found"
} else { Warn "Setup docs missing" }

Write-Host "Validation complete."
