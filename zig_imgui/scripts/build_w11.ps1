# So o build (sem testes nem dist/): zig-out\bin\ (pasta do app) e zig-out\onefile\ (executavel unico).
# Grava no programa o numero do build (git rev-list --count HEAD) e a data de hoje (janela Sobre).
# Comando oficial: ..\build_w11_amd64.ps1 (ver README-BUILD.txt).
. (Join-Path $PSScriptRoot 'env_w11.ps1')

$number = (git rev-list --count HEAD 2>$null)
if ($LASTEXITCODE -or -not $number) { $number = '' } # fora de um clone git: "build dev"
$date = Get-Date -Format 'yyyy-MM-dd'
"Build $number ($date)"

& $zig build install onefile -Doptimize=ReleaseSafe "-Dbuild_number=$number" "-Dbuild_date=$date"
if ($LASTEXITCODE) { throw "zig build falhou ($LASTEXITCODE)" }
Get-ChildItem zig-out\bin, zig-out\onefile -File | Select-Object Name, Length, LastWriteTime
