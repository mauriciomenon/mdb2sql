# Baixa para .tools/ do subprojeto (fora do git) as ferramentas e arquivos fixos, conferindo o sha256 de cada um:
#   Zig (compilador), extensao sqlite do DuckDB (vai junto do programa), mdbtools estatico (leitor .mdb/.accdb de
#   reserva, vai junto do programa) e NSIS (gera o instalador).
# Chamado por ..\build_w11_amd64.ps1; sozinho: pwsh -NoProfile -File scripts/setup_tools.ps1
# As outras dependencias (Dear ImGui, cimgui, zglfw, libduckdb) sao baixadas pelo proprio `zig build`,
# fixadas por hash em build.zig.zon.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Versoes fixas. Para trocar: versao + sha256 juntos.
# Zig estavel: "shasum" de x86_64-windows em https://ziglang.org/download/index.json
$ZigVersion = '0.17.1'
$ZigSha256 = 'b03f477a1943673e02aca0f570e8030dffd536ce1f45cbc4d3326ec31159562e'
# Extensao sqlite_scanner da MESMA versao da libduckdb de build.zig.zon (v2.0.0, windows_amd64, assinada pela DuckDB).
# sha256 do .gz conferido no download de 2026-11-15 (o site nao publica hash).
$DuckDbVersion = 'v2.0.0'
$SqliteExtSha256 = '3088cb24796c749d35aa3cb782cabc3df0c7d13dab4392f16fb5d2f02cd70d71'
# mdbtools 1.0.1 estatico (release win-static-1.0.1 de mauriciomenon/mdbtools_custom), sha256 do SHA256SUMS.txt do release
$MdbtoolsZip = 'mdbtools-1.0.1-w11-amd64.zip'
$MdbtoolsSha256 = 'e15c69b9da2f8218f8c1db18fe0147d242cb888522d6c481e8c7c9d97e0405de'
# NSIS 3.13 (2026-09-27), zip portatil; sha256 calculado no download e conferido contra o md5 publicado no SourceForge
# (530e3623c077cba879ed2ae6e13be362)
$NsisVersion = '3.13'
$NsisSha256 = 'ba63dffc4410ee89193e1cb5a41989991bd77c61068da17e3156d136b7b0b3d8'

$tools = Join-Path (Split-Path $PSScriptRoot) '.tools'
New-Item -ItemType Directory -Force $tools | Out-Null

function Assert-Sha256([string]$File, [string]$Sha256) {
    $got = (Get-FileHash $File -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $Sha256) {
        Remove-Item $File
        throw "sha256 de $(Split-Path -Leaf $File) nao confere: esperado $Sha256, veio $got"
    }
}

# Zip: baixa, confere e extrai em pasta propria; so depois move para o lugar ($Inner = pasta raiz do zip, se houver)
function Install-Zip([string]$Name, [string]$Url, [string]$Sha256, [string]$Dest, [string]$Inner, [scriptblock]$Download) {
    if (Test-Path (Join-Path $Dest ".sha256-$Sha256")) { "$Name ja esta em $Dest"; return }
    $zip = Join-Path $tools "_download.zip"
    "Baixando $Name..."
    if ($Download) { & $Download $zip } else { Invoke-WebRequest $Url -OutFile $zip }
    Assert-Sha256 $zip $Sha256
    $tmp = Join-Path $tools '_extract'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    New-Item -ItemType Directory $tmp | Out-Null
    & "$env:SystemRoot\System32\tar.exe" -xf $zip -C $tmp
    if ($LASTEXITCODE) { throw "falha ao extrair $Name ($LASTEXITCODE)" }
    if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
    Move-Item (Join-Path $tmp $Inner) $Dest
    New-Item -ItemType File (Join-Path $Dest ".sha256-$Sha256") | Out-Null
    Remove-Item $tmp, $zip -Recurse -Force -ErrorAction Ignore
    "$Name instalado em $Dest"
}

# Zig (a pasta tem o mesmo nome da raiz do zip)
$zigName = "zig-x86_64-windows-$ZigVersion"
if (Test-Path (Join-Path $tools "$zigName\zig.exe")) { "Zig $ZigVersion ja esta em $tools\$zigName" }
else { Install-Zip "Zig $ZigVersion" "https://ziglang.org/download/$ZigVersion/$zigName.zip" $ZigSha256 (Join-Path $tools $zigName) $zigName }

# Extensao sqlite do DuckDB (.gz de um arquivo so)
$extDir = Join-Path $tools "duckdb-ext-$DuckDbVersion"
$ext = Join-Path $extDir 'sqlite_scanner.duckdb_extension'
if (Test-Path (Join-Path $extDir ".sha256-$SqliteExtSha256")) { "extensao sqlite $DuckDbVersion ja esta em $extDir" }
else {
    New-Item -ItemType Directory -Force $extDir | Out-Null
    $gz = "$ext.gz"
    "Baixando sqlite_scanner $DuckDbVersion..."
    Invoke-WebRequest "http://extensions.duckdb.org/$DuckDbVersion/windows_amd64/sqlite_scanner.duckdb_extension.gz" -OutFile $gz
    Assert-Sha256 $gz $SqliteExtSha256
    $in = [IO.File]::OpenRead($gz)
    $out = [IO.File]::Create($ext)
    try { $z = [IO.Compression.GZipStream]::new($in, [IO.Compression.CompressionMode]::Decompress); $z.CopyTo($out); $z.Dispose() }
    finally { $out.Dispose(); $in.Dispose() }
    Remove-Item $gz
    New-Item -ItemType File (Join-Path $extDir ".sha256-$SqliteExtSha256") | Out-Null
    "extensao sqlite instalada em $extDir"
}

# mdbtools: o repositorio pode ser privado; com o gh autenticado baixa por ele, senao pelo link publico
$getMdbtools = {
    param($zip)
    if (Get-Command gh -ErrorAction Ignore) {
        $dir = Split-Path $zip
        & gh release download win-static-1.0.1 -R mauriciomenon/mdbtools_custom -p $MdbtoolsZip -D $dir --clobber
        if ($LASTEXITCODE) { throw "gh release download falhou ($LASTEXITCODE)" }
        Move-Item -Force (Join-Path $dir $MdbtoolsZip) $zip
    } else {
        Invoke-WebRequest "https://github.com/mauriciomenon/mdbtools_custom/releases/download/win-static-1.0.1/$MdbtoolsZip" -OutFile $zip
    }
}
Install-Zip 'mdbtools 1.0.1' '' $MdbtoolsSha256 (Join-Path $tools 'mdbtools-1.0.1') 'mdbtools-1.0.1-w11-amd64' $getMdbtools

# NSIS portatil. O SourceForge so entrega o arquivo direto (sem a pagina de espera) para clientes de linha de comando.
$getNsis = {
    param($zip)
    Invoke-WebRequest "https://downloads.sourceforge.net/project/nsis/NSIS%203/$NsisVersion/nsis-$NsisVersion.zip" -UserAgent 'Wget' -OutFile $zip
}
Install-Zip "NSIS $NsisVersion" '' $NsisSha256 (Join-Path $tools "nsis-$NsisVersion") "nsis-$NsisVersion" $getNsis
