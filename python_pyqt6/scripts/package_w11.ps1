# Monta os tres produtos em dist\.stage e so no fim troca dist\w11\amd64 (se algo falhar, os produtos anteriores ficam):
#   <nome>.exe            exe unico (build\dist\mdb2sql-pyqt.exe)
#   <nome>.zip            pasta do app (build\dist\mdb2sql\) dentro de uma pasta <nome>\
#   <nome>-installer.exe  instalador NSIS por usuario da mesma pasta (scripts\installer.nsi)
. (Join-Path $PSScriptRoot 'env_w11.ps1')

$version = (Select-String -Path pyproject.toml -Pattern '^version = "(.+)"').Matches[0].Groups[1].Value
$name = "mdb2sql-$version-w11-amd64-python-pyqt6"

$stage = Join-Path $Root 'dist\.stage'
$out = Join-Path $Root 'dist\w11\amd64'
Remove-Item -Recurse -Force $stage -ErrorAction Ignore
New-Item -ItemType Directory -Force $stage, (Split-Path $out) | Out-Null

Copy-Item build\dist\mdb2sql-pyqt.exe (Join-Path $stage "$name.exe")

$appDir = Join-Path $Root 'build\dist\mdb2sql'
$zipDir = Join-Path $stage $name
Copy-Item -Recurse $appDir $zipDir
Compress-Archive -Path $zipDir -DestinationPath (Join-Path $stage "$name.zip") -CompressionLevel Optimal
Remove-Item -Recurse -Force $zipDir

$makensis = Join-Path $Root '.tools\nsis\makensis.exe'
& $makensis /V2 "/DAPP_NAME=MDB2SQL (Python + PyQt6)" '/DAPP_SLUG=mdb2sql-python-pyqt6' "/DAPP_VERSION=$version" `
    "/DAPP_DIR=$appDir" "/DOUT_FILE=$(Join-Path $stage "$name-installer.exe")" (Join-Path $PSScriptRoot 'installer.nsi')
if ($LASTEXITCODE) { throw "makensis falhou ($LASTEXITCODE)" }

Remove-Item -Recurse -Force $out -ErrorAction Ignore
Move-Item $stage $out
"Source: $(git describe --tags --always --dirty)"
Get-ChildItem $out | Select-Object FullName, Length
