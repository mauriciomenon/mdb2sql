# Monta os tres produtos Windows em dist\.stage e so no fim troca dist\w11\amd64 (se algo falhar, os anteriores ficam):
#   mdb2sql-<versao>-w11-amd64-zig-imgui.exe             executavel unico (zig-out\onefile)
#   mdb2sql-<versao>-w11-amd64-zig-imgui.zip             pasta do app
#   mdb2sql-<versao>-w11-amd64-zig-imgui-installer.exe   instalador NSIS (por usuario, sem administrador)
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot
Set-Location $Root

$version = (Select-String -Path build.zig.zon -Pattern '\.version = "(.+)"').Matches[0].Groups[1].Value
$name = "mdb2sql-$version-w11-amd64-zig-imgui"
$makensis = Get-ChildItem .tools\nsis-*\makensis.exe -ErrorAction Ignore | Select-Object -First 1 -ExpandProperty FullName
if (-not $makensis) { throw 'NSIS nao encontrado: rode scripts\setup_tools.ps1' }

$stage = Join-Path $Root 'dist\.stage'
$out = Join-Path $Root 'dist\w11\amd64'
Remove-Item -Recurse -Force $stage -ErrorAction Ignore
$app = Join-Path $stage 'mdb2sql-zig-imgui'
New-Item -ItemType Directory -Force (Join-Path $app 'mdbtools'), (Split-Path $out) | Out-Null

# pasta do app: exe, duckdb.dll, extensao sqlite e mdbtools\ (o .pdb fica de fora)
Copy-Item zig-out\bin\mdb2sql-zig.exe, zig-out\bin\duckdb.dll, zig-out\bin\sqlite_scanner.duckdb_extension $app
Copy-Item zig-out\bin\mdbtools\* (Join-Path $app 'mdbtools')
Copy-Item README.md (Join-Path $app 'README.md')
Copy-Item LICENSE (Join-Path $app 'LICENSE') # GPL v2 (texto integral)

Copy-Item zig-out\onefile\mdb2sql-zig-onefile.exe (Join-Path $stage "$name.exe")
Compress-Archive -Path $app -DestinationPath (Join-Path $stage "$name.zip")

& $makensis /V2 "/DVERSION=$version" "/DAPPDIR=$app" "/DOUTFILE=$(Join-Path $stage "$name-installer.exe")" scripts\installer.nsi
if ($LASTEXITCODE) { throw "makensis falhou ($LASTEXITCODE)" }
Remove-Item -Recurse -Force $app # o zip e o instalador ja levam a pasta

Remove-Item -Recurse -Force $out -ErrorAction Ignore
Move-Item $stage $out
"Source: $(git describe --tags --always --dirty)"
Get-ChildItem $out -File | Select-Object Name, Length
