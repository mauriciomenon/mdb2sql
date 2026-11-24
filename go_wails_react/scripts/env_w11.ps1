# Ambiente comum de build e teste (dot-source: . scripts\env_w11.ps1): Go, GCC, Wails e pnpm no PATH.
# Tambem serve para desenvolver: `. scripts\env_w11.ps1; wails dev`. Vai para a raiz do subprojeto.
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot
Set-Location $Root

# Ferramentas fixas de setup_tools.ps1 (.tools/) tem prioridade; sem elas vale o que estiver no sistema
$tools = Join-Path $Root '.tools'
$toolsGcc = Join-Path $tools 'winlibs\mingw64\bin'
$toolsGo = Join-Path $tools 'go\go\bin'
$toolsBin = Join-Path $tools 'bin'

# cgo precisa de GCC MinGW-w64 com runtime UCRT (WinLibs); MDB2SQL_GCC_BIN aponta para a pasta bin dele
$gcc = if ($env:MDB2SQL_GCC_BIN) { $env:MDB2SQL_GCC_BIN }
    elseif (Test-Path (Join-Path $toolsGcc 'gcc.exe')) { $toolsGcc }
    else { Join-Path $HOME '.local\winlibs-gcc-16.2.0-ucrt-r3\mingw64\bin' }
if (-not (Test-Path (Join-Path $gcc 'gcc.exe'))) { throw "gcc.exe nao encontrado em $gcc; rode scripts\setup_tools.ps1 ou defina MDB2SQL_GCC_BIN" }
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
# makensis para `wails build -nsis` (sem .tools vale o NSIS do sistema, se houver)
$toolsNsis = Get-ChildItem (Join-Path $tools 'nsis') -Directory -Filter 'nsis-*' -ErrorAction Ignore | Select-Object -First 1
if ($toolsNsis) { $env:PATH = "$($toolsNsis.FullName);$env:PATH" }
# pnpm fixo de .tools, com store e cache tambem em .tools: nada do pnpm fica fora desta pasta
$toolsPnpm = Join-Path $tools 'pnpm'
if (Test-Path (Join-Path $toolsPnpm 'pnpm.exe')) {
    $env:PATH = "$toolsPnpm;$env:PATH"
    $env:pnpm_config_store_dir = Join-Path $tools 'pnpm-store'
    $env:pnpm_config_cache_dir = Join-Path $tools 'pnpm-cache'
}
"go:    $((Get-Command go).Source)"
"gcc:   $((Get-Command gcc).Source)"
"wails: $((Get-Command wails).Source)"
"nsis:  $((Get-Command makensis -ErrorAction Ignore).Source)"
"pnpm:  $((Get-Command pnpm -ErrorAction Ignore).Source)"
