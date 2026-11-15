# Windows 11 amd64: limpa, baixa as ferramentas fixas, compila, testa e gera os produtos em dist\w11\amd64.
# Uso: pwsh -NoProfile -File build_w11_amd64.ps1   (detalhes em README-BUILD.txt)
$ErrorActionPreference = 'Stop'
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { Write-Output 'este comando gera o pacote amd64 e so roda em Windows amd64'; exit 2 }

& (Join-Path $PSScriptRoot 'clean.ps1')
foreach ($step in 'setup_tools', 'build_w11', 'test_w11', 'package_w11') {
    "=== $step"
    & (Join-Path $PSScriptRoot "scripts\$step.ps1")
}
exit 0
