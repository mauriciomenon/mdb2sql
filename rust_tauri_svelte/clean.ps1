# "make clean": apaga os intermediarios. -Dist apaga tambem os produtos em dist\.
# .tools\ (tauri-cli compilado) fica; apague a mao para forcar nova instalacao.
param([switch]$Dist)
$ErrorActionPreference = 'Stop'

$targets = 'target', 'ui\dist', 'dist\.stage'
if ($Dist) { $targets += 'dist' }
foreach ($target in $targets) {
    $path = Join-Path $PSScriptRoot $target
    if (Test-Path -LiteralPath $path) {
        Remove-Item -Recurse -Force -LiteralPath $path
        "removed $path"
    }
}
