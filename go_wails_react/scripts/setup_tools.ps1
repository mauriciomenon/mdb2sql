# Baixa para .tools/ do subprojeto (fora do git) as ferramentas de build em versoes fixas:
#   .tools/go       Go (zip oficial de go.dev)
#   .tools/winlibs  GCC MinGW-w64 UCRT (WinLibs), exigido pelo cgo do duckdb-go
#   .tools/bin      Wails CLI, compilado com o Go acima
#   .tools/nsis     NSIS (makensis), para o instalador
#   .tools/mdbtools mdb-tables/mdb-schema/mdb-export estaticos (embutidos no exe)
#   .tools/duckdb-ext  extensao sqlite do DuckDB (embutida no exe)
#   .tools/pnpm     pnpm (executavel do release oficial)
# Chamado por ..\build_w11_amd64.ps1; sozinho: pwsh -NoProfile -File scripts/setup_tools.ps1
# (repetir e seguro: so refaz o que mudou)
# Node.js continua pre-requisito do sistema (ver README.md desta pasta).
$ErrorActionPreference = 'Stop'

# Versoes fixas. Para atualizar: troque versao + sha256 juntos (sha256 publicado pelo proprio projeto).
# Go: ultima 1.26.x com mais de 2 semanas em 2026-11-15 (1.26.11 saiu em 2026-11-10); 1.27 quebra o Wails CLI 2.13.0.
# sha256 de https://go.dev/dl/?mode=json&include=all
$goVersion = '1.26.10'
$goSha256 = '7ecd2d7260e82c59bcbd7f1077a07cee2dea607295b858df67195a1e4e09629b'
# WinLibs: GCC 16.2.0 + MinGW-w64 14.0.0 UCRT r3 (2026-10-18), pacote sem LLVM; sha256 do arquivo .zip.sha256 do release
$winlibsTag = '16.2.0posix-23.1.3-14.0.0-ucrt-r3'
$winlibsZip = 'winlibs-x86_64-posix-seh-gcc-16.2.0-mingw-w64ucrt-14.0.0-r3.zip'
$winlibsSha256 = '3c69305081e4a647144339a936244fcf7d3d9e558319e1ad7be2cd2886d4b6a1'
# Wails CLI: mesma versao do modulo em go.mod; o go confere o hash do modulo em sum.golang.org
$wailsVersion = 'v2.13.0'
# NSIS: gera o instalador (wails build -nsis). Mesma versao e sha256 dos repos NMR5 (SourceForge nao publica sha256;
# calculado do zip oficial em 2026-11-13).
$nsisVersion = '3.12'
$nsisSha256 = '56581f90db321581c5381193d796fffcf2d24b2f8fed2160a6c6a3baa67f2c4f'
# mdbtools estatico (leitor Access reserva, embutido no exe): release win-static-1.0.1 de mdbtools_custom
$mdbtoolsTag = 'win-static-1.0.1'
$mdbtoolsZip = 'mdbtools-1.0.1-w11-amd64.zip'
$mdbtoolsSha256 = 'e15c69b9da2f8218f8c1db18fe0147d242cb888522d6c481e8c7c9d97e0405de'
# Extensao sqlite do DuckDB para a versao linkada pelo duckdb-go (v2.0.0) e a plataforma do build MinGW
# (PRAGMA platform = windows_amd64_mingw); arquivo assinado pelo DuckDB, publicado em 2026-10-20; embutida no exe
$duckdbExtUrl = 'https://extensions.duckdb.org/v2.0.0/windows_amd64_mingw/sqlite_scanner.duckdb_extension.gz'
$duckdbExtSha256 = '781af1d36475e9119dcf2b7b204ab3acc74602b34d6cf3a250c769d04ebf746d'
# pnpm: ultima versao (2026-11-22), a mesma do packageManager de frontend/package.json; sha256 publicado no release
$pnpmVersion = '12.23.0'
$pnpmSha256 = '1a954bdc1b15ff036294279391d01a09407b7d46ff972a59d81f23becce96c1c'

$tools = Join-Path (Split-Path $PSScriptRoot) '.tools'
$downloads = Join-Path $tools 'downloads'
New-Item -ItemType Directory -Force $downloads | Out-Null
# tar do Windows (bsdtar) abre zip e e bem mais rapido que Expand-Archive; o tar do Git Bash nao abre zip
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'

# Baixa, confere o sha256 e extrai em pasta propria; o marcador evita refazer quando a versao nao mudou
function Get-Download([string]$Name, [string]$Url, [string]$Sha256, [string]$File) {
    "baixando $Name ..."
    curl.exe -fL --retry 3 --silent --show-error -A 'curl/8.0' -o $File $Url
    if ($LASTEXITCODE -and $Url -match '^https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/(.+)$' -and (Get-Command gh -ErrorAction Ignore)) {
        # release de repositorio privado: o curl anonimo recebe 404; o gh usa o login do dono
        gh release download $Matches[2] -R $Matches[1] -p $Matches[3] -O $File --clobber
    }
    if ($LASTEXITCODE) { throw "download falhou: $Url" }
    $got = (Get-FileHash $File -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $Sha256) { Remove-Item $File; throw "sha256 de $Name nao confere: esperado $Sha256, obtido $got" }
}

function Install-Zip([string]$Name, [string]$Url, [string]$Sha256, [string]$Dest) {
    $marker = Join-Path $Dest ".installed-$Sha256"
    if (Test-Path $marker) { "$Name ja instalado em $Dest"; return }
    $zip = Join-Path $downloads ([IO.Path]::GetFileName($Url))
    Get-Download $Name $Url $Sha256 $zip
    Remove-Item -Recurse -Force $Dest -ErrorAction Ignore
    New-Item -ItemType Directory -Force $Dest | Out-Null
    & $tar -xf $zip -C $Dest
    if ($LASTEXITCODE) { throw "extracao de $Name falhou" }
    Remove-Item $zip
    New-Item -ItemType File $marker | Out-Null
    "$Name instalado em $Dest"
}

# os dois zips trazem uma pasta raiz (go/, mingw64/), por isso cada um vai para uma pasta propria
Install-Zip "Go $goVersion" "https://go.dev/dl/go$goVersion.windows-amd64.zip" $goSha256 (Join-Path $tools 'go')
Install-Zip "WinLibs GCC $winlibsTag" "https://github.com/brechtsanders/winlibs_mingw/releases/download/$winlibsTag/$winlibsZip" $winlibsSha256 (Join-Path $tools 'winlibs')
Install-Zip "NSIS $nsisVersion" "https://downloads.sourceforge.net/project/nsis/NSIS%203/$nsisVersion/nsis-$nsisVersion.zip" $nsisSha256 (Join-Path $tools 'nsis')
Install-Zip "mdbtools ($mdbtoolsTag)" "https://github.com/mauriciomenon/mdbtools_custom/releases/download/$mdbtoolsTag/$mdbtoolsZip" $mdbtoolsSha256 (Join-Path $tools 'mdbtools')
# o wails.json chama "pnpm": env_w11.ps1 poe esta pasta no PATH
Install-Zip "pnpm $pnpmVersion" "https://github.com/pnpm/pnpm/releases/download/v$pnpmVersion/pnpm-win32-x64.zip" $pnpmSha256 (Join-Path $tools 'pnpm')

# a extensao fica compactada (.gz): e assim que vai para dentro do exe
$extDir = Join-Path $tools 'duckdb-ext'
$extFile = Join-Path $extDir ([IO.Path]::GetFileName($duckdbExtUrl))
if ((Test-Path $extFile) -and (Get-FileHash $extFile -Algorithm SHA256).Hash.ToLower() -eq $duckdbExtSha256) {
    "extensao sqlite do DuckDB ja em $extDir"
} else {
    New-Item -ItemType Directory -Force $extDir | Out-Null
    Get-Download 'extensao sqlite do DuckDB' $duckdbExtUrl $duckdbExtSha256 $extFile
}

$go = Join-Path $tools 'go\go\bin\go.exe'
$bin = Join-Path $tools 'bin'
$wailsMarker = Join-Path $bin ".installed-wails-$wailsVersion-go$goVersion"
if (Test-Path $wailsMarker) {
    "Wails CLI $wailsVersion ja instalado em $bin"
} else {
    "compilando Wails CLI $wailsVersion ..."
    Remove-Item -Recurse -Force $bin -ErrorAction Ignore
    $env:GOBIN = $bin
    $env:GOTOOLCHAIN = 'local'   # usa o Go de .tools, sem baixar outro toolchain
    $env:GOFLAGS = '-trimpath'
    Remove-Item Env:GOROOT -ErrorAction Ignore
    & $go install "github.com/wailsapp/wails/v2/cmd/wails@$wailsVersion"
    if ($LASTEXITCODE) { throw "go install do Wails CLI falhou ($LASTEXITCODE)" }
    New-Item -ItemType File $wailsMarker | Out-Null
}

& $go version
& (Join-Path $tools 'winlibs\mingw64\bin\gcc.exe') --version | Select-Object -First 1
& (Join-Path $bin 'wails.exe') version | Select-Object -First 1
"NSIS $(& (Join-Path $tools "nsis\nsis-$nsisVersion\makensis.exe") /VERSION)"
Get-Content (Join-Path $tools "mdbtools\$([IO.Path]::GetFileNameWithoutExtension($mdbtoolsZip))\VERSION.txt") -TotalCount 1
"pnpm $(& (Join-Path $tools 'pnpm\pnpm.exe') --version)"
