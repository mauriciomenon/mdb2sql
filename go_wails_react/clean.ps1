# "make clean": apaga os intermediarios. -Dist apaga tambem os produtos em dist\.
# .tools\ (Go, GCC e Wails baixados) fica; apague a mao para forcar novo download.
param([switch]$Dist)
$ErrorActionPreference = 'Stop'

# build\appicon.png, build\windows\icon.ico e build\windows\installer\project.nsi ficam (versionados); o resto de
# build\ e gerado pelo wails build
$targets = 'build\bin', 'build\windows\installer\tmp', 'build\windows\installer\wails_tools.nsh', 'build\windows\info.json',
    'build\windows\wails.exe.manifest',
    'frontend\dist', 'dist\.stage'
if ($Dist) { $targets += 'dist' }
foreach ($target in $targets) {
    $path = Join-Path $PSScriptRoot $target
    if (Test-Path -LiteralPath $path) {
        Remove-Item -Recurse -Force -LiteralPath $path
        "removed $path"
    }
}
# copias de .tools embutidas no exe (o .gitkeep fica: go:embed precisa da pasta)
Get-ChildItem (Join-Path $PSScriptRoot 'backend\embedded') -Exclude '.gitkeep' | ForEach-Object {
    Remove-Item -Force -LiteralPath $_.FullName
    "removed $($_.FullName)"
}
