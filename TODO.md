# TODO

- [x] Revisar `go_wails_react/backend/db_manager.go` (validação de tableName) para reduzir overhead de conexão mantendo a proteção contra SQL injection.
- [x] Avaliar `go_wails_react/frontend/.npmrc` (hoisting pnpm) frente à arvore de deps real e decidir se `shamefully-hoist=true` é necessário.
- [x] Corrigir referências antigas no arquivo `temp/Diario20251116.md` que ainda apontam para caminhos/links obsoletos.
- [x] Reavaliar a escolha do Python 3.14 em `SetupDebian.md` (versão pré-release) e considerar versão estável para compatibilidade.
- [x] Toolchain PDF (pandoc + tectonic): `scripts/generate_md_pdfs.sh` gera todos os PDFs sem erros.
