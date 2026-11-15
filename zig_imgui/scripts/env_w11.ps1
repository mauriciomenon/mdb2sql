# Ambiente comum de build e teste (dot-source: . scripts\env_w11.ps1): define $zig. Vai para a raiz do subprojeto.
# Usa o Zig de .tools/ (setup_tools.ps1) quando existe; senao o `zig` do PATH.
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot
Set-Location $Root

$zig = Get-ChildItem .tools\zig-*\zig.exe -ErrorAction Ignore | Select-Object -First 1 -ExpandProperty FullName
if (-not $zig) { $zig = (Get-Command zig -ErrorAction Ignore).Source }
if (-not $zig) { throw 'Zig nao encontrado: rode scripts\setup_tools.ps1 (baixa o Zig fixado para .tools/)' }
"Zig $(& $zig version): $zig"
