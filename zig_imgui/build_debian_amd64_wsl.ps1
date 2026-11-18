# Gera os pacotes Debian amd64 pelo WSL (distro Debian) e traz o resultado para dist\debian\amd64\.
# O build Linux nao roda na pasta do Windows (scripts/build_debian.sh recusa /mnt/c com codigo 2): este script mantem um
# clone no disco do Linux (~/src/mdb2sql-zig), coloca nele o MESMO commit do Windows, roda o build la e copia
# dist/debian/amd64 de volta, conferindo o sha256 de cada arquivo.
# Uso (nesta pasta, arvore commitada): pwsh -NoProfile -File .\build_debian_amd64_wsl.ps1
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root

if (git status --porcelain --untracked-files=no) { Write-Host 'Arvore com alteracoes nao commitadas; commite antes.'; exit 2 }
$commit = (git rev-parse HEAD).Trim()
$repo = (git rev-parse --show-toplevel).Trim()
$winRepo = (wsl.exe -d Debian -e wslpath -a $repo).Trim()

# O clone Linux busca o commit direto do repo do Windows; .tools/ e zig-pkg/ (downloads conferidos) ficam.
$linux = @"
set -euo pipefail
src="`$HOME/src/mdb2sql-zig"
if [ ! -d "`$src/.git" ]; then mkdir -p "`$HOME/src"; git clone -q '$winRepo' "`$src"; fi
cd "`$src"
git fetch -q '$winRepo' '$commit'
git checkout -q --detach '$commit'
git clean -q -fdx -e zig_imgui/.tools -e zig_imgui/zig-pkg
cd zig_imgui
./build_debian_amd64.sh
"@ -replace "`r", ''
wsl.exe -d Debian -e bash -c $linux
if ($LASTEXITCODE) { Write-Host "build Debian falhou no WSL (codigo $LASTEXITCODE)"; exit $LASTEXITCODE }

# Copia de volta e confere: cada arquivo do Windows tem de ter o mesmo sha256 do arquivo no Linux.
$dest = Join-Path $root 'dist\debian\amd64'
$linuxDist = (wsl.exe -d Debian -e bash -c 'printf %s "$HOME/src/mdb2sql-zig/zig_imgui/dist/debian/amd64"').Trim()
$winDest = (wsl.exe -d Debian -e wslpath -a $dest.Replace('\', '/')).Trim()
if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
New-Item -ItemType Directory -Force $dest | Out-Null
wsl.exe -d Debian -e cp -rL "$linuxDist/." "$winDest/"
if ($LASTEXITCODE) { Write-Host "copia de $linuxDist falhou (codigo $LASTEXITCODE)"; exit 1 }
$sums = wsl.exe -d Debian -e bash -c "cd '$linuxDist' && find . -type f -exec sha256sum {} +"
$bad = 0
foreach ($line in $sums) {
    $hash, $rel = ($line -split '\s+', 2)
    $file = Join-Path $dest ($rel.Trim().TrimStart('.', '/') -replace '/', '\')
    if ((Get-FileHash $file SHA256).Hash.ToLower() -ne $hash) { Write-Host "  DIFERENTE: $rel"; $bad++ }
}
if ($bad) { Write-Host "$bad arquivo(s) diferentes depois da copia"; exit 1 }
Write-Host "Source: $(git describe --tags --always) -> $dest ($(@($sums).Count) arquivos, sha256 conferido)"
