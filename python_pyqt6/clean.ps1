# "make clean": apaga os intermediarios. -Dist apaga tambem os produtos em dist\.
# .tools\ (ferramentas baixadas) e .venv\ ficam; apague a mao para forcar novo download.
param([switch]$Dist)
$ErrorActionPreference = 'Stop'

$targets = 'build', 'dist\.stage', '.pytest_cache', '.ruff_cache'
if ($Dist) { $targets += 'dist' }
foreach ($target in $targets) {
    $path = Join-Path $PSScriptRoot $target
    if (Test-Path -LiteralPath $path) {
        Remove-Item -Recurse -Force -LiteralPath $path
        "removed $path"
    }
}
