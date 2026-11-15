# So o build (sem testes nem dist/): target\release\mdb2sql.exe e os instaladores NSIS e MSI em
# target\release\bundle\, sem caminhos locais embutidos. Comando oficial: ..\build_w11_amd64.ps1 (ver README-BUILD.txt).
. (Join-Path $PSScriptRoot 'env_w11.ps1')

# tauri-cli fixado pelo setup_tools.ps1; sem ele usa o `cargo tauri` instalado no sistema
$localCli = Join-Path $Root '.tools\bin\cargo-tauri.exe'
if (Test-Path $localCli) { & $localCli tauri build } else { cargo tauri build }
if ($LASTEXITCODE) { throw "cargo tauri build falhou ($LASTEXITCODE)" }
Get-ChildItem target\release\bundle\nsis\*.exe, target\release\bundle\msi\*.msi | Select-Object Name, Length, LastWriteTime
