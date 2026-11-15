# Build de release do app Wails no Windows: build/bin/mdb2sql.exe sem caminhos locais embutidos.
# Uso: pwsh -NoProfile -File go_wails_react/build_windows.ps1
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# Ferramentas fixas de setup_tools.ps1 (.tools/) tem prioridade; sem elas vale o que estiver no sistema
$tools = Join-Path $PSScriptRoot '.tools'
$toolsGcc = Join-Path $tools 'winlibs\mingw64\bin'
$toolsGo = Join-Path $tools 'go\go\bin'
$toolsBin = Join-Path $tools 'bin'

# cgo precisa de GCC MinGW-w64 com runtime UCRT (WinLibs); MDB2SQL_GCC_BIN aponta para a pasta bin dele
$gcc = if ($env:MDB2SQL_GCC_BIN) { $env:MDB2SQL_GCC_BIN }
    elseif (Test-Path (Join-Path $toolsGcc 'gcc.exe')) { $toolsGcc }
    else { Join-Path $HOME '.local\winlibs-gcc-16.2.0-ucrt-r3\mingw64\bin' }
if (-not (Test-Path (Join-Path $gcc 'gcc.exe'))) { throw "gcc.exe nao encontrado em $gcc; rode setup_tools.ps1 ou defina MDB2SQL_GCC_BIN" }
$env:PATH = "$gcc;$env:PATH"
$env:CGO_ENABLED = '1'

if (Test-Path (Join-Path $toolsGo 'go.exe')) {
    $env:PATH = "$toolsGo;$env:PATH"
    $env:GOTOOLCHAIN = 'local'   # o Go de .tools ja e a versao fixa; nao baixar outro
    Remove-Item Env:GOROOT -ErrorAction Ignore
} else {
    # o Wails CLI 2.13.0 quebra com Go 1.27; o go do sistema baixa este toolchain sozinho
    $env:GOTOOLCHAIN = 'go1.26.11'
}
if (Test-Path (Join-Path $toolsBin 'wails.exe')) { $env:PATH = "$toolsBin;$env:PATH" }
"go:    $((Get-Command go).Source)"
"gcc:   $((Get-Command gcc).Source)"
"wails: $((Get-Command wails).Source)"

# Vite escreve em frontend/dist/<plataforma>-<arch>; um frontend/dist/index.html antigo seria embutido no lugar da UI nova
Remove-Item -Recurse -Force frontend\dist -ErrorAction Ignore

# -trimpath tira do exe os caminhos da maquina de build (pasta do usuario, cache de modulos)
wails build -clean -trimpath
if ($LASTEXITCODE) { throw "wails build falhou ($LASTEXITCODE)" }
Get-Item build\bin\mdb2sql.exe | Select-Object Name, Length, LastWriteTime
