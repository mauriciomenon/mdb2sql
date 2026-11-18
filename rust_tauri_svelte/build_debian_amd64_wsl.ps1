# Gera os pacotes Debian amd64 pelo WSL sem passos manuais e traz o resultado para dist\debian\amd64\.
# O build Linux nao roda na pasta do Windows (scripts/build_debian.sh recusa /mnt/c com codigo 2): este script
# mantem um clone no disco do Linux (~/src/mdb2sql-rust-tauri-svelte), coloca nele o MESMO commit do Windows, roda
# o build la e copia dist/debian/amd64 de volta, conferindo o sha256 de cada arquivo.
# Uso (arvore commitada): pwsh -NoProfile -File build_debian_amd64_wsl.ps1
$ErrorActionPreference = 'Stop'
$stack = $PSScriptRoot
$repo = (git -C $stack rev-parse --show-toplevel).Trim()
$sub = Split-Path $stack -Leaf
$clone = 'mdb2sql-rust-tauri-svelte'

if (git -C $repo status --porcelain --untracked-files=no) { Write-Host 'Arvore com alteracoes nao commitadas; commite antes.'; exit 2 }
$commit = (git -C $repo rev-parse HEAD).Trim()
$winRepo = (wsl.exe -e wslpath -a ($repo -replace '\\', '/')).Trim()

# O clone Linux busca o commit direto do repo do Windows; target/ e .tools/ (cache do cargo e ferramentas) ficam.
$linux = @"
set -euo pipefail
src="`$HOME/src/$clone"
if [ ! -d "`$src/.git" ]; then mkdir -p "`$HOME/src"; git clone -q '$winRepo' "`$src"; fi
cd "`$src"
git fetch -q '$winRepo' '$commit'
git checkout -q --detach '$commit'
git clean -q -fdx -e target -e .tools -e node_modules
'$sub/build_debian_amd64.sh'
"@ -replace "`r", ''
wsl.exe -e bash -c $linux
if ($LASTEXITCODE) { Write-Host "build Debian falhou no WSL (codigo $LASTEXITCODE)"; exit $LASTEXITCODE }

# Copia de volta e confere: cada arquivo do Windows tem de ter o mesmo sha256 do arquivo no Linux.
$dest = Join-Path $stack 'dist\debian\amd64'
$linuxDist = (wsl.exe -e bash -c ('printf %s "$HOME/src/' + $clone + '/' + $sub + '/dist/debian/amd64"')).Trim()
if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
New-Item -ItemType Directory -Force $dest | Out-Null
$winDest = (wsl.exe -e wslpath -a ($dest -replace '\\', '/')).Trim()
wsl.exe -e cp -rL "$linuxDist/." "$winDest/"
if ($LASTEXITCODE) { Write-Host "copia de $linuxDist falhou (codigo $LASTEXITCODE)"; exit 1 }
$sums = wsl.exe -e bash -c "cd '$linuxDist' && find . -type f -exec sha256sum {} +"
$bad = 0
foreach ($line in $sums) {
    $hash, $rel = ($line -split '\s+', 2)
    $file = Join-Path $dest ($rel.Trim().TrimStart('.', '/') -replace '/', '\')
    if ((Get-FileHash $file SHA256).Hash.ToLower() -ne $hash) { Write-Host "  DIFERENTE: $rel"; $bad++ }
}
if ($bad) { Write-Host "$bad arquivo(s) diferentes depois da copia"; exit 1 }
Write-Host "Source: $(git -C $repo describe --tags --always) -> $dest ($(@($sums).Count) arquivos, sha256 conferido)"
