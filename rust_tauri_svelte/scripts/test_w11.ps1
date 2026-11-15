# Testes do backend (cargo test) e do frontend (node --test). Rodar depois do build: o Tauri embute ui/dist
# na compilacao. --release reaproveita as dependencias ja compiladas pelo build (DuckDB leva varios minutos).
. (Join-Path $PSScriptRoot 'env_w11.ps1')

cargo test --release
if ($LASTEXITCODE) { throw "cargo test falhou ($LASTEXITCODE)" }
pnpm --filter mdb2sql-ui test
if ($LASTEXITCODE) { throw "teste do frontend falhou ($LASTEXITCODE)" }
