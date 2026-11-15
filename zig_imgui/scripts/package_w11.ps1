# Monta os produtos em dist\.stage e so no fim troca dist\w11\amd64 (se algo falhar, os produtos anteriores ficam).
# Hoje: pasta do app e o zip dela. Executavel unico e instalador entram aqui (ver README-BUILD.txt, secao 4).
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot
Set-Location $Root

$version = (Select-String -Path build.zig.zon -Pattern '\.version = "(.+)"').Matches[0].Groups[1].Value
$name = "mdb2sql-$version-w11-amd64-zig-imgui"

$stage = Join-Path $Root 'dist\.stage'
$out = Join-Path $Root 'dist\w11\amd64'
Remove-Item -Recurse -Force $stage -ErrorAction Ignore
$app = Join-Path $stage 'mdb2sql-zig-imgui'
New-Item -ItemType Directory -Force $app, (Split-Path $out) | Out-Null

Copy-Item zig-out\bin\mdb2sql-zig.exe, zig-out\bin\duckdb.dll $app
Compress-Archive -Path $app -DestinationPath (Join-Path $stage "$name.zip")

Remove-Item -Recurse -Force $out -ErrorAction Ignore
Move-Item $stage $out
"Source: $(git describe --tags --always --dirty)"
Get-ChildItem $out -Recurse -File | Select-Object FullName, Length
