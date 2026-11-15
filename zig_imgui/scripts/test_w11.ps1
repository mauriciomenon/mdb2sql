# Testes unitarios (zig build test).
. (Join-Path $PSScriptRoot 'env_w11.ps1')

& $zig build test --summary all
if ($LASTEXITCODE) { throw "zig build test falhou ($LASTEXITCODE)" }
