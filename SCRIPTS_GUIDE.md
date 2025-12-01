# Guia de Scripts MDB2SQL

## Scripts de Execução (run_*.sh)

Execute cada implementação individualmente:

### 1. [run_go_wails.sh](run_go_wails.sh)
**Tecnologia:** Go + Wails v2 + React + TypeScript
**Porta:** http://localhost:34115
**Status:** ✅ Funcionando (interface elogiada)
**Badge na interface:** "Go Wails + React" (canto inferior direito)

```bash
./run_go_wails.sh
```

### 2. [run_rust_tauri.sh](run_rust_tauri.sh)
**Tecnologia:** Rust + Tauri v1.8 + Svelte
**Porta:** http://localhost:1420
**Status:** ✅ Funcionando
**Badge na interface:** "Rust Tauri + Svelte" (canto inferior direito)

```bash
./run_rust_tauri.sh
```

### 3. [run_node_electron.sh](run_node_electron.sh)
**Tecnologia:** Node.js + Electron + React
**Porta:** http://localhost:5173
**Status:** ❌ Bloqueado - DuckDB build trava (veja [NODE_ELECTRON_STATUS.md](NODE_ELECTRON_STATUS.md))
**Badge na interface:** "Node Electron + React" (canto inferior direito)

```bash
# IMPORTANTE: v25 não é LTS! Use v22 ou v24
nvm use 22  # ou nvm use 24
./run_node_electron.sh

# Problema: DuckDB trava durante build
# Solução: Use Go Wails ou Rust Tauri
```

### 4. [run_python_pyqt6.sh](run_python_pyqt6.sh)
**Tecnologia:** Python + PyQt6
**Tipo:** Desktop nativo (sem porta)
**Status:** ⏸️ Congelado temporariamente

```bash
./run_python_pyqt6.sh
```

### 5. [run_all_guis.sh](run_all_guis.sh)
**Descrição:** Roda todas as 4 implementações em paralelo
**Nota:** Útil para comparação visual

```bash
./run_all_guis.sh
# Mostra PIDs de todos os processos
# Ctrl+C para parar todos
```

---

## Scripts de Limpeza (clean_*.sh)

Rebuild limpo de cada implementação (remove cache e rebuilda tudo):

### [clean_go_wails.sh](clean_go_wails.sh)
```bash
./clean_go_wails.sh
# Remove frontend/dist e build/
# Reinstala deps e rebuilda frontend
```

### [clean_rust_tauri.sh](clean_rust_tauri.sh)
```bash
./clean_rust_tauri.sh
# Remove ui/dist e target/
# Reinstala deps e rebuilda frontend
```

### [clean_node_electron.sh](clean_node_electron.sh)
```bash
./clean_node_electron.sh
# Remove frontend/dist
# Reinstala todas as dependências
```

### [clean_python_pyqt6.sh](clean_python_pyqt6.sh)
```bash
./clean_python_pyqt6.sh
# Remove __pycache__ e uv.lock
# Sincroniza deps com uv
```

---

## Scripts Utilitários

### [kill_all_guis.sh](kill_all_guis.sh)
**Descrição:** Mata todos os processos GUI rodando

```bash
./kill_all_guis.sh
# Mata: Wails, Tauri, Electron, Vite, PyQt6
```

### [test_go_wails.sh](test_go_wails.sh)
**Descrição:** Testa Go Wails com validações pré-flight

```bash
./test_go_wails.sh
# Verifica database, frontend/dist, etc
```

---

## Workflow Recomendado

### Primeira execução
```bash
# 1. Escolha uma implementação
./clean_go_wails.sh      # Ou clean_rust_tauri.sh, clean_node_electron.sh

# 2. Rode a implementação
./run_go_wails.sh         # Ou run_rust_tauri.sh, run_node_electron.sh
```

### Desenvolvimento normal
```bash
# Execute diretamente (sem clean)
./run_go_wails.sh
```

### Problemas / Rebuild necessário
```bash
# 1. Mate processos
./kill_all_guis.sh

# 2. Clean build
./clean_go_wails.sh

# 3. Rode novamente
./run_go_wails.sh
```

### Comparar todas as implementações
```bash
./run_all_guis.sh
# Abre todas as 4 ao mesmo tempo
# Cada uma mostra badge de identificação
```

---

## Identificação Visual

Todas as interfaces agora mostram um **badge discreto** no canto inferior direito:

- **Go Wails:** "Go Wails + React"
- **Rust Tauri:** "Rust Tauri + Svelte"
- **Node Electron:** "Node Electron + React"

O badge tem:
- Fundo semi-transparente (`rgba(0, 0, 0, 0.05)`)
- Texto cinza (`#888`)
- Fonte pequena (11px)
- Não interfere com interação (`pointer-events: none`)

---

## Configurações Globais

### pnpm
Configurado em [.npmrc](.npmrc):
```
allow-scripts=esbuild,duckdb,electron
auto-install-peers=true
shamefully-hoist=true
```

**Global:**
```bash
pnpm config get auto-install-peers  # true
pnpm config get shamefully-hoist    # true
```

### Workspaces
Configurado em [pnpm-workspace.yaml](pnpm-workspace.yaml):
```yaml
packages:
  - go_wails_react/frontend
  - rust_tauri_svelte/ui
  - node_electron_react
  - node_electron_react/frontend

onlyBuiltDependencies:
  - duckdb
  - esbuild
```

---

## Troubleshooting

### "Command not found: wails"
```bash
go install github.com/wailsapp/wails/v2/cmd/wails@latest
```

### "Command not found: cargo"
```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### "DuckDB build failed" (Node Electron)
```bash
# Requer Node.js v22
nvm install 22
nvm use 22
./clean_node_electron.sh
```

### "Frontend not found" / "White screen"
```bash
./kill_all_guis.sh
./clean_go_wails.sh  # ou a implementação com problema
./run_go_wails.sh
```

### "Port already in use"
```bash
./kill_all_guis.sh
# Ou manualmente:
lsof -ti:34115 | xargs kill  # Go Wails
lsof -ti:1420 | xargs kill   # Rust Tauri
lsof -ti:5173 | xargs kill   # Node Electron
```

---

## Arquivos de Documentação

- [IMPLEMENTATION_GUIDE.md](IMPLEMENTATION_GUIDE.md) - Guia detalhado de cada implementação
- [TEST_RESULTS.md](TEST_RESULTS.md) - Resultados dos testes de scripts
- [BUILD_REPORT.md](BUILD_REPORT.md) - Relatório de builds
- [TODO.md](TODO.md) - Lista de tarefas pendentes
- [ProjectSpec.md](ProjectSpec.md) - Especificação completa do projeto

---

## Resumo Executivo

| Script | Propósito | Quando Usar |
|--------|-----------|-------------|
| `run_*.sh` | Executar implementação | Desenvolvimento normal |
| `clean_*.sh` | Rebuild limpo | Após mudanças grandes, problemas |
| `run_all_guis.sh` | Executar todas | Comparar implementações |
| `kill_all_guis.sh` | Matar processos | Antes de rebuild, resolver travamentos |
| `test_go_wails.sh` | Validar Go Wails | Debug de problemas específicos |

**Recomendação:** Use **Go Wails** como implementação principal - é a interface elogiada e está funcionando perfeitamente.
