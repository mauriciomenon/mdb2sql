# "make clean": apaga os intermediarios. -Dist apaga tambem os produtos em dist\.
# .tools\ (tauri-cli compilado) fica; apague a mao para forcar nova instalacao.
param([switch]$Dist)
$ErrorActionPreference = 'Stop'

# node_modules do workspace pnpm (raiz e ui): ligado ao store de outra stack ou de outro pnpm, o install recusa;
# refeito do store de .tools em segundos
$targets = 'target', 'ui\dist', 'dist\.stage', '..\node_modules', 'ui\node_modules'
if ($Dist) { $targets += 'dist' }
foreach ($target in $targets) {
    $path = Join-Path $PSScriptRoot $target
    if (Test-Path -LiteralPath $path) {
        Remove-Item -Recurse -Force -LiteralPath $path
        "removed $path"
    }
}
