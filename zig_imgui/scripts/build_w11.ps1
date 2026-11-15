# So o build (sem testes nem dist/): zig-out\bin\mdb2sql-zig.exe + duckdb.dll (os dois precisam ficar juntos).
# Comando oficial: ..\build_w11_amd64.ps1 (ver README-BUILD.txt).
. (Join-Path $PSScriptRoot 'env_w11.ps1')

& $zig build -Doptimize=ReleaseSafe
if ($LASTEXITCODE) { throw "zig build falhou ($LASTEXITCODE)" }
Get-ChildItem zig-out\bin | Select-Object Name, Length, LastWriteTime
