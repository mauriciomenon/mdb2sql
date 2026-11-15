# Baixa para .tools/ do subprojeto (fora do git) as ferramentas de build em versoes fixas:
#   .tools/go       Go (zip oficial de go.dev)
#   .tools/winlibs  GCC MinGW-w64 UCRT (WinLibs), exigido pelo cgo do duckdb-go
#   .tools/bin      Wails CLI, compilado com o Go acima
# Chamado por ..\build_w11_amd64.ps1; sozinho: pwsh -NoProfile -File scripts/setup_tools.ps1
# (repetir e seguro: so refaz o que mudou)
# Node.js e pnpm continuam sendo pre-requisitos do sistema (ver README.md desta pasta).
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

$tools = Join-Path (Split-Path $PSScriptRoot) '.tools'
$downloads = Join-Path $tools 'downloads'
New-Item -ItemType Directory -Force $downloads | Out-Null
# tar do Windows (bsdtar) abre zip e e bem mais rapido que Expand-Archive; o tar do Git Bash nao abre zip
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'

# Baixa, confere o sha256 e extrai em pasta propria; o marcador evita refazer quando a versao nao mudou
function Install-Zip([string]$Name, [string]$Url, [string]$Sha256, [string]$Dest) {
    $marker = Join-Path $Dest ".installed-$Sha256"
    if (Test-Path $marker) { "$Name ja instalado em $Dest"; return }
    $zip = Join-Path $downloads ([IO.Path]::GetFileName($Url))
    "baixando $Name ..."
    curl.exe -fL --retry 3 --silent --show-error -o $zip $Url
    if ($LASTEXITCODE) { throw "download falhou: $Url" }
    $got = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $Sha256) { Remove-Item $zip; throw "sha256 de $Name nao confere: esperado $Sha256, obtido $got" }
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
