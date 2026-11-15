# Build de release do app Wails no Windows: build/bin/mdb2sql.exe sem caminhos locais embutidos.
# Uso: pwsh -NoProfile -File go_wails_react/build_windows.ps1
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# cgo precisa de GCC MinGW-w64 com runtime UCRT (WinLibs); MDB2SQL_GCC_BIN aponta para a pasta bin dele
$gcc = if ($env:MDB2SQL_GCC_BIN) { $env:MDB2SQL_GCC_BIN } else { Join-Path $HOME '.local\winlibs-gcc-16.2.0-ucrt-r3\mingw64\bin' }
if (-not (Test-Path (Join-Path $gcc 'gcc.exe'))) { throw "gcc.exe nao encontrado em $gcc; instale o WinLibs UCRT ou defina MDB2SQL_GCC_BIN" }
$env:PATH = "$gcc;$env:PATH"
$env:CGO_ENABLED = '1'
# o Wails CLI 2.13.0 quebra com Go 1.27; o go baixa este toolchain sozinho
$env:GOTOOLCHAIN = 'go1.26.11'

# Vite escreve em frontend/dist/<plataforma>-<arch>; um frontend/dist/index.html antigo seria embutido no lugar da UI nova
Remove-Item -Recurse -Force frontend\dist -ErrorAction Ignore

# -trimpath tira do exe os caminhos da maquina de build (pasta do usuario, cache de modulos)
wails build -clean -trimpath
if ($LASTEXITCODE) { throw "wails build falhou ($LASTEXITCODE)" }
Get-Item build\bin\mdb2sql.exe | Select-Object Name, Length, LastWriteTime
