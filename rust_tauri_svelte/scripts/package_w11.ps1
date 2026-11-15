# Monta os produtos em dist\.stage e so no fim troca dist\w11\amd64 (se algo falhar, os produtos anteriores ficam).
# Hoje: executavel unico e instaladores NSIS e MSI. O zip entra aqui (ver README-BUILD.txt, secao 4).
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot
Set-Location $Root

$version = (Select-String -Path Cargo.toml -Pattern '^version = "(.+)"').Matches[0].Groups[1].Value
$name = "mdb2sql-$version-w11-amd64-rust-tauri-svelte"

$stage = Join-Path $Root 'dist\.stage'
$out = Join-Path $Root 'dist\w11\amd64'
Remove-Item -Recurse -Force $stage -ErrorAction Ignore
New-Item -ItemType Directory -Force $stage, (Split-Path $out) | Out-Null

Copy-Item target\release\mdb2sql.exe (Join-Path $stage "$name.exe")
# o Tauri nomeia os instaladores com a versao; o curinga pega so o desta versao
Copy-Item "target\release\bundle\nsis\*_${version}_x64-setup.exe" (Join-Path $stage "$name-installer.exe")
Copy-Item "target\release\bundle\msi\*_${version}_x64_*.msi" (Join-Path $stage "$name-installer.msi")
if ((Get-ChildItem $stage).Count -ne 3) { throw "esperados 3 produtos em $stage; o nome dos instaladores do Tauri mudou?" }

Remove-Item -Recurse -Force $out -ErrorAction Ignore
Move-Item $stage $out
"Source: $(git describe --tags --always --dirty)"
Get-ChildItem $out | Select-Object FullName, Length
