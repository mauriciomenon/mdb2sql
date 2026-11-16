# So o build (sem testes nem dist/): build\dist\mdb2sql-pyqt.exe (arquivo unico com Python/Qt/DuckDB, extensao
# sqlite e mdbtools embutidos) e build\dist\mdb2sql\ (a mesma app em pasta, base do zip e do instalador).
# Comando oficial: ..\build_w11_amd64.ps1 (ver README-BUILD.txt).
. (Join-Path $PSScriptRoot 'env_w11.ps1')

# --locked: versoes fixas do uv.lock (PyInstaller, PyQt6, DuckDB); falha se o lock estiver desatualizado
uv sync --locked
if ($LASTEXITCODE) { throw "uv sync falhou ($LASTEXITCODE)" }

uv run --no-sync pyinstaller --noconfirm --clean --distpath build\dist --workpath build\work mdb2sql.spec
if ($LASTEXITCODE) { throw "pyinstaller falhou ($LASTEXITCODE)" }

# o exe e a pasta do app (base do zip e do instalador) nao podem levar caminhos da maquina de build
uv run --no-sync python scripts\scan_exe.py build\dist\mdb2sql-pyqt.exe build\dist\mdb2sql
if ($LASTEXITCODE) { throw 'varredura encontrou dados locais no exe ou na pasta do app' }
Get-Item build\dist\mdb2sql-pyqt.exe, build\dist\mdb2sql\mdb2sql.exe | Select-Object FullName, Length, LastWriteTime
