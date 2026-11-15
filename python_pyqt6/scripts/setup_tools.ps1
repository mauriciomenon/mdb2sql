# Baixa para .tools/ o Python fixado em .python-version (unica ferramenta que o build precisa alem do uv).
# Chamado por ..\build_w11_amd64.ps1; sozinho: pwsh -NoProfile -File scripts/setup_tools.ps1
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot
Set-Location $Root

if (-not (Get-Command uv -ErrorAction Ignore)) { throw 'uv nao encontrado no PATH (https://docs.astral.sh/uv/); e o unico pre-requisito do sistema' }

$version = (Get-Content .python-version -TotalCount 1).Trim()
$env:UV_PYTHON_INSTALL_DIR = Join-Path $Root '.tools\python'
# --no-bin/--no-registry: nada fora desta pasta (sem python3.12.exe em ~/.local/bin, sem entrada no registro).
# O uv confere o sha256 do pacote do python-build-standalone ao baixar.
uv python install $version --no-bin --no-registry
if ($LASTEXITCODE) { throw "uv python install falhou ($LASTEXITCODE)" }
uv python find $version --managed-python
