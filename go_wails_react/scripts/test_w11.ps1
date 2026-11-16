# Testes do backend (go test) e do frontend (vitest). Rodar depois do build: o go:embed precisa de
# frontend/dist e o vitest de node_modules, e os dois sao criados pelo `wails build`.
. (Join-Path $PSScriptRoot 'env_w11.ps1')

go test ./...
if ($LASTEXITCODE) { throw "go test falhou ($LASTEXITCODE)" }
pnpm --dir frontend exec vitest run
if ($LASTEXITCODE) {
    # com a maquina carregada o worker do vitest as vezes nao sobe a tempo ("Timeout waiting for worker");
    # um teste quebrado de verdade falha de novo
    'vitest falhou; repetindo uma vez'
    pnpm --dir frontend exec vitest run
    if ($LASTEXITCODE) { throw "vitest falhou ($LASTEXITCODE)" }
}
