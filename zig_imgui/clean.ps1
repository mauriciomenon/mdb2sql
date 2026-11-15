# "make clean": apaga os intermediarios. -Dist apaga tambem os produtos em dist\.
# .tools\ (Zig baixado) e zig-pkg\ (dependencias baixadas, conferidas por hash) ficam; apague a mao para baixar de novo.
param([switch]$Dist)
$ErrorActionPreference = 'Stop'

$targets = '.zig-cache', 'zig-out', 'dist\.stage'
if ($Dist) { $targets += 'dist' }
foreach ($target in $targets) {
    $path = Join-Path $PSScriptRoot $target
    if (Test-Path -LiteralPath $path) {
        Remove-Item -Recurse -Force -LiteralPath $path
        "removed $path"
    }
}
