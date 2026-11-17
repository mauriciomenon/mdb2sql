# Monta os produtos em dist\.stage e so no fim troca dist\w11\amd64 (se algo falhar, os produtos anteriores ficam).
# Os tres de sempre: executavel unico, zip da pasta do app e instalador NSIS (gerado pelo wails build -nsis).
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot
Set-Location $Root

$version = (Get-Content wails.json -Raw | ConvertFrom-Json).info.productVersion
$name = "mdb2sql-$version-w11-amd64-go-wails-react"

$stage = Join-Path $Root 'dist\.stage'
$out = Join-Path $Root 'dist\w11\amd64'
Remove-Item -Recurse -Force $stage -ErrorAction Ignore
New-Item -ItemType Directory -Force $stage, (Split-Path $out) | Out-Null

# 1) executavel unico: o exe do Wails ja e autossuficiente (DuckDB estatico, UI e ferramentas embutidas)
Copy-Item build\bin\mdb2sql.exe (Join-Path $stage "$name.exe")

# 2) zip da pasta do app: <name>\mdb2sql.exe + LEIAME.txt
$appDir = Join-Path $stage "zip\$name"
New-Item -ItemType Directory -Force $appDir | Out-Null
Copy-Item build\bin\mdb2sql.exe $appDir
@(
    "MDB2SQL (Go + Wails + React) $version"
    ''
    'Abra mdb2sql.exe (nao precisa instalar). Abre .duckdb, .db, .sqlite, .sqlite3, .mdb e .accdb e exporta para'
    '.duckdb, .sqlite, .xlsx e .csv. Precisa do Microsoft Edge WebView2 Runtime (parte do Windows 11).'
    'Arquivos Access: usa o driver ODBC do Access (64 bits) se instalado; senao, o mdbtools embutido.'
    'Cache das ferramentas embutidas: %LOCALAPPDATA%\mdb2sql\go-wails-react-<versao>-<build>.'
    'Codigo: https://github.com/mauriciomenon/mdb2sql  e  https://gitlab.com/mauricio.menon/mdb2sql'
) | Set-Content (Join-Path $appDir 'LEIAME.txt') -Encoding utf8
Compress-Archive -Path $appDir -DestinationPath (Join-Path $stage "$name.zip")
Remove-Item -Recurse -Force (Join-Path $stage 'zip')

# 3) instalador
Copy-Item build\bin\mdb2sql-amd64-installer.exe (Join-Path $stage "$name-installer.exe")

Remove-Item -Recurse -Force $out -ErrorAction Ignore
Move-Item $stage $out
"Source: $(git describe --tags --always --dirty)"
Get-ChildItem $out | Select-Object FullName, Length
