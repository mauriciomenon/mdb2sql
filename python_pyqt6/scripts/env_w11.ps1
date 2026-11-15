# Ambiente comum de build e teste (dot-source: . scripts\env_w11.ps1). Vai para a raiz do subprojeto.
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot
Set-Location $Root

# usa o Python de .tools/ (setup_tools.ps1) quando existir; sem ele o uv resolve o .python-version sozinho
$tools = Join-Path $Root '.tools\python'
if (Test-Path $tools) { $env:UV_PYTHON_INSTALL_DIR = $tools; $env:UV_MANAGED_PYTHON = '1' }
