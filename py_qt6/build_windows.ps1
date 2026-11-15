# Build de release do app PyQt6 no Windows: dist/mdb2sql-pyqt.exe (arquivo unico, Python/Qt/DuckDB embutidos).
# Uso: pwsh -NoProfile -File py_qt6/setup_tools.ps1 ; pwsh -NoProfile -File py_qt6/build_windows.ps1
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# usa o Python de .tools/ (setup_tools.ps1) quando existir; sem ele o uv resolve o .python-version sozinho
$tools = Join-Path $PSScriptRoot '.tools\python'
if (Test-Path $tools) { $env:UV_PYTHON_INSTALL_DIR = $tools; $env:UV_MANAGED_PYTHON = '1' }

# --locked: versoes fixas do uv.lock (PyInstaller, PyQt6, DuckDB); falha se o lock estiver desatualizado
uv sync --locked
if ($LASTEXITCODE) { throw "uv sync falhou ($LASTEXITCODE)" }

uv run --no-sync pyinstaller --noconfirm --clean --distpath dist --workpath build mdb2sql.spec
if ($LASTEXITCODE) { throw "pyinstaller falhou ($LASTEXITCODE)" }

# o exe nao pode levar caminhos da maquina de build
uv run --no-sync python scan_exe.py dist\mdb2sql-pyqt.exe
if ($LASTEXITCODE) { throw 'varredura encontrou dados locais no exe' }
Get-Item dist\mdb2sql-pyqt.exe | Select-Object Name, Length, LastWriteTime
