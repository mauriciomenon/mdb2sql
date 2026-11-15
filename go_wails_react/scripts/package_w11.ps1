# Monta os produtos em dist\.stage e so no fim troca dist\w11\amd64 (se algo falhar, os produtos anteriores ficam).
# Hoje: executavel unico. Zip e instalador entram aqui (ver README-BUILD.txt, secao 4).
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot
Set-Location $Root

$version = (Get-Content wails.json -Raw | ConvertFrom-Json).info.productVersion
$name = "mdb2sql-$version-w11-amd64-go-wails-react"

$stage = Join-Path $Root 'dist\.stage'
$out = Join-Path $Root 'dist\w11\amd64'
Remove-Item -Recurse -Force $stage -ErrorAction Ignore
New-Item -ItemType Directory -Force $stage, (Split-Path $out) | Out-Null

Copy-Item build\bin\mdb2sql.exe (Join-Path $stage "$name.exe")

Remove-Item -Recurse -Force $out -ErrorAction Ignore
Move-Item $stage $out
"Source: $(git describe --tags --always --dirty)"
Get-ChildItem $out | Select-Object FullName, Length
