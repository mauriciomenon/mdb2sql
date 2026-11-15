# "make clean": apaga os intermediarios. -Dist apaga tambem os produtos em dist\.
# .tools\ (Go, GCC e Wails baixados) fica; apague a mao para forcar novo download.
param([switch]$Dist)
$ErrorActionPreference = 'Stop'

$targets = 'build', 'frontend\dist', 'dist\.stage'
if ($Dist) { $targets += 'dist' }
foreach ($target in $targets) {
    $path = Join-Path $PSScriptRoot $target
    if (Test-Path -LiteralPath $path) {
        Remove-Item -Recurse -Force -LiteralPath $path
        "removed $path"
    }
}
