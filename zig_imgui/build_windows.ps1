# Build de release do MDB2SQL Zig + Dear ImGui no Windows x64.
# Uso: pwsh -NoProfile -File zig_imgui/build_windows.ps1
# Usa o Zig de .tools/ (setup_tools.ps1) quando existe; senao o `zig` do PATH.
# Saida: dist\mdb2sql-zig-windows-x64\ com mdb2sql-zig.exe + duckdb.dll (os dois precisam ficar juntos).
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$zig = Get-ChildItem .tools\zig-*\zig.exe -ErrorAction Ignore | Select-Object -First 1 -ExpandProperty FullName
if (-not $zig) { $zig = (Get-Command zig -ErrorAction Ignore).Source }
if (-not $zig) { throw 'Zig nao encontrado: rode setup_tools.ps1 (baixa o Zig fixado para .tools/)' }
"Zig $(& $zig version): $zig"

& $zig build -Doptimize=ReleaseSafe
if ($LASTEXITCODE) { throw "zig build falhou ($LASTEXITCODE)" }

$out = 'dist\mdb2sql-zig-windows-x64'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory $out | Out-Null
Copy-Item zig-out\bin\mdb2sql-zig.exe, zig-out\bin\duckdb.dll $out
Get-ChildItem $out | Select-Object Name, Length, LastWriteTime
