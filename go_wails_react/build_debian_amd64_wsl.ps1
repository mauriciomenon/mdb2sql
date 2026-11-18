# Gera os pacotes Debian amd64 pelo WSL sem passos manuais e traz o resultado para dist\debian\amd64\.
# O build Linux nao roda na pasta do Windows (build_debian_amd64.sh recusa /mnt/c com codigo 2): este script mantem um
# clone no disco do Linux (~/src/mdb2sql-go_wails_react, so desta stack), coloca nele o MESMO commit do Windows, roda o
# build la e copia dist/debian/amd64 de volta, conferindo o sha256 de cada arquivo.
# Uso (arvore commitada): pwsh -NoProfile -File go_wails_react\build_debian_amd64_wsl.ps1
$ErrorActionPreference = 'Stop'
$stack = Split-Path $PSScriptRoot -Leaf
$repo = Split-Path $PSScriptRoot
Set-Location $repo

if (git status --porcelain --untracked-files=no) { Write-Host 'Arvore com alteracoes nao commitadas; commite antes.'; exit 2 }
$commit = (git rev-parse HEAD).Trim()
$winRepo = (wsl.exe -e wslpath -a ($repo -replace '\\', '/')).Trim()
$clone = "mdb2sql-$stack"

# O clone Linux busca o commit direto do repo do Windows; .tools/ (Go, Wails, mdbtools baixados) e preservado.
$linux = @"
set -euo pipefail
src="`$HOME/src/$clone"
if [ ! -d "`$src/.git" ]; then mkdir -p "`$HOME/src"; git clone -q '$winRepo' "`$src"; fi
cd "`$src"
git fetch -q '$winRepo' '$commit'
git checkout -q --detach '$commit'
git clean -q -fdx -e $stack/.tools
./$stack/build_debian_amd64.sh
"@ -replace "`r", ''
wsl.exe -e bash -c $linux
if ($LASTEXITCODE) { Write-Host "build Debian falhou no WSL (codigo $LASTEXITCODE)"; exit $LASTEXITCODE }

# Copia de volta e confere: cada arquivo do Windows tem de ter o mesmo sha256 do arquivo no Linux.
$dest = Join-Path $PSScriptRoot 'dist\debian\amd64'
$linuxDist = (wsl.exe -e bash -c ('printf %s "$HOME/src/' + $clone + '/' + $stack + '/dist/debian/amd64"')).Trim()
if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
New-Item -ItemType Directory -Force $dest | Out-Null
wsl.exe -e cp -rL "$linuxDist/." "$winRepo/$stack/dist/debian/amd64/"
if ($LASTEXITCODE) { Write-Host "copia de $linuxDist falhou (codigo $LASTEXITCODE)"; exit 1 }
$sums = wsl.exe -e bash -c "cd '$linuxDist' && find . -type f -exec sha256sum {} +"
$bad = 0
foreach ($line in $sums) {
    $hash, $rel = ($line -split '\s+', 2)
    $file = Join-Path $dest ($rel.Trim().TrimStart('.', '/') -replace '/', '\')
    if ((Get-FileHash $file SHA256).Hash.ToLower() -ne $hash) { Write-Host "  DIFERENTE: $rel"; $bad++ }
}
if ($bad) { Write-Host "$bad arquivo(s) diferentes depois da copia"; exit 1 }
Write-Host "Source: $(git describe --tags --always) -> $dest ($(@($sums).Count) arquivos, sha256 conferido)"
