# Testes (pytest + pytest-qt, sem abrir janela) com as versoes do uv.lock.
. (Join-Path $PSScriptRoot 'env_w11.ps1')

uv sync --locked
if ($LASTEXITCODE) { throw "uv sync falhou ($LASTEXITCODE)" }
$env:QT_QPA_PLATFORM = 'offscreen'
uv run --no-sync pytest -q
if ($LASTEXITCODE) { throw "pytest falhou ($LASTEXITCODE)" }
