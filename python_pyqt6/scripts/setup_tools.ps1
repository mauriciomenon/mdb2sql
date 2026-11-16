# Baixa para .tools/ as ferramentas fixas, com sha256 conferido:
#   python\        Python de .python-version (via uv)
#   mdbtools\      mdb-tables/mdb-schema/mdb-export estaticos (reserva para .mdb/.accdb sem ODBC; vao no exe)
#   duckdb_ext\    extensao sqlite do DuckDB (le e grava .sqlite offline; vai no exe)
#   nsis\          NSIS (makensis) do instalador
# Chamado por ..\build_w11_amd64.ps1; sozinho: pwsh -NoProfile -File scripts/setup_tools.ps1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
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

# Versoes fixas. A extensao tem de ser da mesma versao do DuckDB do uv.lock.
$MdbtoolsUrl = 'https://github.com/mauriciomenon/mdbtools_custom/releases/download/win-static-1.0.1/mdbtools-1.0.1-w11-amd64.zip'
$MdbtoolsSha = 'e15c69b9da2f8218f8c1db18fe0147d242cb888522d6c481e8c7c9d97e0405de'
$DuckdbVersion = '2.0.0'
$SqliteExtUrl = "https://extensions.duckdb.org/v$DuckdbVersion/windows_amd64/sqlite_scanner.duckdb_extension.gz"
$SqliteExtSha = '3088cb24796c749d35aa3cb782cabc3df0c7d13dab4392f16fb5d2f02cd70d71'
$NsisUrl = 'https://downloads.sourceforge.net/project/nsis/NSIS%203/3.12/nsis-3.12.zip'
$NsisSha = '56581f90db321581c5381193d796fffcf2d24b2f8fed2160a6c6a3baa67f2c4f'

# Baixa $Url, confere o sha256 e chama $Install com o arquivo baixado; pula se .tools\<Name>\.sha256 ja bate.
function Install-Pinned([string]$Name, [string]$Url, [string]$Sha, [scriptblock]$Install) {
    $dest = Join-Path $Root ".tools\$Name"
    $stamp = Join-Path $dest '.sha256'
    if ((Test-Path $stamp) -and (Get-Content $stamp -Raw).Trim() -eq $Sha) { "$Name ok ($dest)"; return }
    $tmp = Join-Path $Root ".tools\$Name.download"
    Remove-Item -Recurse -Force $dest, $tmp -ErrorAction Ignore
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $file = Join-Path $tmp ([IO.Path]::GetFileName(([uri]$Url).AbsolutePath))
    try {
        # SourceForge responde HTML ao user agent de navegador
        Invoke-WebRequest -Uri $Url -OutFile $file -UseBasicParsing -UserAgent 'curl/8.0'
    } catch {
        # release de repositorio privado: so com o gh autenticado
        $m = [regex]::Match($Url, 'github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/(.+)$')
        if (-not ($m.Success -and (Get-Command gh -ErrorAction Ignore))) { throw "download falhou: $Url ($($_.Exception.Message)); coloque o arquivo (sha256 $Sha) em $file" }
        gh release download $m.Groups[2].Value -R $m.Groups[1].Value -p $m.Groups[3].Value -D $tmp --clobber
        if ($LASTEXITCODE) { throw "gh release download falhou ($LASTEXITCODE): $Url" }
    }
    $got = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLowerInvariant()
    if ($got -ne $Sha) { Remove-Item -Recurse -Force $tmp; throw "sha256 errado em $Url : $got (esperado $Sha)" }
    New-Item -ItemType Directory -Force $dest | Out-Null
    & $Install $file $dest
    Remove-Item -Recurse -Force $tmp
    Set-Content -LiteralPath $stamp -Value $Sha -NoNewline
    "$Name baixado de $Url (sha256 $got conferido)"
}

Install-Pinned 'mdbtools' $MdbtoolsUrl $MdbtoolsSha {
    param($file, $dest)
    $unzip = "$file.d"
    Expand-Archive $file $unzip
    # so o que o app usa, com as licencas (GPL/LGPL) e a versao
    $dir = (Get-ChildItem $unzip -Directory | Select-Object -First 1).FullName
    Copy-Item (Join-Path $dir '*') $dest -Include 'mdb-tables.exe', 'mdb-schema.exe', 'mdb-export.exe', 'COPYING', 'COPYING.LIB', 'VERSION.txt'
}

Install-Pinned 'duckdb_ext' $SqliteExtUrl $SqliteExtSha {
    param($file, $dest)
    $in = [IO.File]::OpenRead($file)
    $out = [IO.File]::Create((Join-Path $dest 'sqlite_scanner.duckdb_extension'))
    try { $gz = [IO.Compression.GZipStream]::new($in, [IO.Compression.CompressionMode]::Decompress); $gz.CopyTo($out) }
    finally { $out.Dispose(); $in.Dispose() }
}

Install-Pinned 'nsis' $NsisUrl $NsisSha {
    param($file, $dest)
    $unzip = "$file.d"
    Expand-Archive $file $unzip
    # o zip tem uma pasta nsis-<versao>
    Copy-Item (Join-Path (Get-ChildItem $unzip -Directory | Select-Object -First 1).FullName '*') $dest -Recurse
}
"makensis $(& (Join-Path $Root '.tools\nsis\makensis.exe') /VERSION)"
if ($LASTEXITCODE) { throw "makensis /VERSION falhou ($LASTEXITCODE)" }
