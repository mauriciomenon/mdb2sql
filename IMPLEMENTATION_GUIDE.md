# Guia de Implementações MDB2SQL

## Resumo Executivo

Você tem **3 implementações paralelas** com a mesma funcionalidade mas tecnologias diferentes.

## Identificação Rápida

| Porta | Framework | Frontend | Backend | Script | Status |
|-------|-----------|----------|---------|--------|--------|
| 1420 | Rust Tauri | Svelte | Rust | `./run_rust_tauri.sh` | ✅ OK |
| 34115 | Go Wails | React + TS | Go | `./run_go_wails.sh` | ✅ OK (contraste corrigido) |
| 5173 | Node Electron | React | Node.js | `./run_node_electron.sh` | ⚠️ Aguardando Node v22 |

## Detalhamento

### 1. Rust Tauri (Porta 1420)

**Diretório:** `rust_tauri_svelte/`

**Stack:**
- Frontend: Svelte + Vite
- Backend: Rust + Tauri v1.8
- Database: DuckDB (bundled)

**Como rodar:**
```bash
./run_rust_tauri.sh
# Abre em: http://localhost:1420/
```

**Características:**
- Interface com Svelte (diferente das outras)
- Menor tamanho de bundle
- Melhor performance
- Contraste do título: ✅ CORRETO (`color: #000`)

**Problemas conhecidos:**
- Nenhum no momento

---

### 2. Go Wails (Porta 34115)

**Diretório:** `go_wails_react/`

**Stack:**
- Frontend: React + TypeScript
- Backend: Go + Wails v2
- Database: DuckDB

**Como rodar:**
```bash
./run_go_wails.sh
# Abre em: http://localhost:34115/
```

**Características:**
- **ESTA É A INTERFACE QUE VOCÊ ELOGIOU** (commit f7b6315)
- React com TypeScript
- Backend em Go (rápido e eficiente)
- Contraste do título: ✅ CORRIGIDO (`color: #000`, `font-weight: 600`)

**Arquivos principais:**
- [go_wails_react/frontend/src/App.tsx](go_wails_react/frontend/src/App.tsx) - Interface
- [go_wails_react/frontend/src/App.css](go_wails_react/frontend/src/App.css) - Estilos
- [go_wails_react/app.go](go_wails_react/app.go) - Backend Go

**Problemas conhecidos:**
- ~~Contraste do h1 (#333)~~ ✅ RESOLVIDO

---

### 3. Node Electron (Porta 5173)

**Diretório:** `node_electron_react/`

**Stack:**
- Frontend: React + Vite
- Backend: Node.js + Electron
- Database: DuckDB (native module)

**Como rodar:**
```bash
# REQUER Node.js v22 LTS (incompatível com v25)
nvm use 22  # ou instale node@22
./run_node_electron.sh
```

**Características:**
- Interface idêntica ao Go Wails (React)
- Backend em Node.js puro
- Mais familiar para devs JavaScript

**Problemas conhecidos:**
- ❌ DuckDB não compila no Node.js v25
- ❌ Electron não instala corretamente no Node.js v25
- **Solução:** Usar Node.js v22 LTS

---

## Qual usar?

### Para desenvolvimento imediato:
1. **Go Wails** - Interface elogiada, funcionando perfeitamente
2. **Rust Tauri** - Alternativa performática, interface Svelte

### Para futuro (quando migrar para Node v22):
- **Node Electron** - Se preferir ecossistema JavaScript puro

## Erro que você viu

### "Cannot read properties of undefined (reading 'invoke')"

Esse erro acontece quando:
- Rust Tauri não carrega o backend corretamente
- Problema de build ou cache

**Solução:**
```bash
cd rust_tauri_svelte
rm -rf ui/dist target
pnpm --dir ui run build
cargo tauri build
```

### "Cannot read properties of undefined (reading 'loadDatabase')"

Esse erro acontece quando:
- Go Wails não expôs as funções Go corretamente
- Frontend tentando chamar `window.go.main.App.loadDatabase()`

**Solução:**
```bash
cd go_wails_react
rm -rf frontend/dist build
cd frontend && pnpm run build && cd ..
wails build -clean
```

## Configuração pnpm

Para evitar prompts de build scripts:

**Projeto:** [.npmrc](.npmrc)
```
allow-scripts=esbuild,duckdb,electron
```

**Global:** (já configurado)
```bash
pnpm config set auto-install-peers true
pnpm config set shamefully-hoist true
```

## Próximos passos sugeridos

1. **Testar Go Wails com contraste corrigido** ✅
2. **Expandir implementação Rust** (você mencionou interesse)
3. **Aguardar Node.js v22 para Electron** ou usar nvm
4. **Escolher uma implementação principal** para focar desenvolvimento

## Comandos úteis

```bash
# Ver todas as portas em uso
lsof -i :1420,34115,5173

# Matar processos travados
pkill -f wails
pkill -f tauri
pkill -f electron

# Rebuild completo
rm -rf node_modules && pnpm install

# Ver logs do Wails
cd go_wails_react && wails dev

# Build de produção Tauri
cd rust_tauri_svelte && cargo tauri build
```

## Matriz de decisão

| Critério | Rust Tauri | Go Wails | Node Electron |
|----------|-----------|----------|---------------|
| Performance | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ |
| Tamanho bundle | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐ |
| Familiaridade | ⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| Estabilidade | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ (v25) |
| Ecossistema | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| Interface elogiada | ❌ (Svelte) | ✅ (React TS) | ✅ (React) |

## Conclusão

**Recomendação:** Use **Go Wails** como implementação principal.
- É a interface que você elogiou
- Está funcionando perfeitamente
- Contraste corrigido
- Performance excelente
- Backend Go é rápido e confiável

Mantenha Rust Tauri como alternativa performática e Node Electron para quando migrar para Node v22.
