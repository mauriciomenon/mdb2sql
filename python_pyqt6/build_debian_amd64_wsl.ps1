# Gera os produtos Debian amd64 pelo WSL e traz o resultado para dist\debian\amd64\ (sem passos manuais).
# O build Linux nao roda na pasta do Windows (build_debian_amd64.sh recusa /mnt/c com codigo 2): este script mantem
# um clone no disco do Linux (~/src/mdb2sql-python-pyqt6), coloca nele o MESMO commit do Windows, roda o build la e
# copia dist/debian/amd64 de volta conferindo o sha256 de cada arquivo.
# Uso (nesta pasta, arvore commitada): pwsh -NoProfile -File build_debian_amd64_wsl.ps1
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$repo = (git rev-parse --show-toplevel).Trim()
if (git status --porcelain --untracked-files=no) { Write-Output 'Arvore com alteracoes nao commitadas; commite antes.'; exit 2 }
$commit = (git rev-parse HEAD).Trim()
$winRepo = (wsl.exe -e wslpath -a $repo).Trim()
$clone = 'src/mdb2sql-python-pyqt6'

# o clone Linux busca o commit direto do repo do Windows; .tools/ (ferramentas Linux baixadas) e preservado
$linux = @"
set -euo pipefail
src="`$HOME/$clone"
if [ ! -d "`$src/.git" ]; then mkdir -p "`$HOME/src"; git clone -q '$winRepo' "`$src"; fi
cd "`$src"
git fetch -q '$winRepo' '$commit'
git checkout -q --detach '$commit'
git clean -q -fdx -e .tools
cd python_pyqt6
./build_debian_amd64.sh
"@ -replace "`r", ''
wsl.exe -e bash -c $linux
if ($LASTEXITCODE) { Write-Output "build Debian falhou no WSL (codigo $LASTEXITCODE)"; exit $LASTEXITCODE }

$linuxDist = (wsl.exe -e bash -c "printf %s `"`$HOME/$clone/python_pyqt6/dist/debian/amd64`"").Trim()
$dest = Join-Path $PSScriptRoot 'dist\debian\amd64'
Remove-Item -Recurse -Force $dest -ErrorAction Ignore
New-Item -ItemType Directory -Force $dest | Out-Null
wsl.exe -e cp -r "$linuxDist/." "$winRepo/python_pyqt6/dist/debian/amd64/"
if ($LASTEXITCODE) { Write-Output "copia de $linuxDist falhou (codigo $LASTEXITCODE)"; exit 1 }
$sums = wsl.exe -e bash -c "cd '$linuxDist' && sha256sum -- *"
$bad = 0
foreach ($line in $sums) {
    $hash, $file = $line -split '\s+\*?', 2
    if ((Get-FileHash (Join-Path $dest $file) SHA256).Hash.ToLower() -ne $hash) { Write-Output "  DIFERENTE: $file"; $bad++ }
}
if ($bad) { Write-Output "$bad arquivo(s) diferentes depois da copia"; exit 1 }
"Source: $(git describe --tags --always) -> $dest (sha256 conferido)"
$sums
exit 0
