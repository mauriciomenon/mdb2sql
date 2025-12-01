# Erros e Problemas Encontrados - POC MDB2SQL

## Data: 2025-11-20
## Status: Em Desenvolvimento

---

## PROBLEMAS IDENTIFICADOS

### 1. Rust + Tauri + Svelte

#### Problema A: Incompatibilidade de Versoes
**Erro:**
```
unknown field `app`, expected one of `$schema`, `package`, `tauri`, `build`, `plugins`
found an unknown configuration field. This usually means that you are using a CLI version
that is newer than `tauri-build` and is incompatible.
```

**Causa Raiz:**
- CLI Tauri v2.x incompativel com tauri-build v1.x
- Arquivo `tauri.conf.json` usa schema v2 mas dependencias sao v1

**Solucao:**
```bash
cd rust_tauri_svelte
cargo update
# OU atualizar Cargo.toml para usar tauri 2.x
```

**Status:** NAO RESOLVIDO (baixa prioridade para POC)

---

#### Problema B: Configuracao de Paths Frontend
**Erro:**
```
sh: line 0: cd: ui: No such file or directory
sh: line 0: cd: ../ui: No such file or directory
sh: line 0: cd: ../../ui: No such file or directory
```

**Causa Raiz:**
- Multiplos arquivos tauri.conf.json (root e src-tauri/)
- Paths relativos diferentes dependendo do diretorio de execucao
- Estrutura: `rust_tauri_svelte/ui/` mas comandos executam de diretorios diferentes

**Tentativas:**
1. `cd ui` - falhou (execucao de rust_tauri_svelte/)
2. `cd ../ui` - falhou (execucao de rust_tauri_svelte/src-tauri/)
3. `cd ../../ui` - falhou (path incorreto)

**Solucao Correta:**
- De `rust_tauri_svelte/`: usar `cd ui`
- De `rust_tauri_svelte/src-tauri/`: usar `cd ../ui`
- **Problema:** Tauri v2 executa de src-tauri/ por padrao

**Status:** PARCIALMENTE RESOLVIDO (configs atualizadas, build ainda falha por incompatibilidade)

---

### 2. Go + Wails + React

#### Problema A: Wails Runtime Nao Carregava
**Erro:**
```
Hello menon! (Wails runtime loading...)
```
(Ficava apenas nesta mensagem, sem conectar ao backend)

**Causa Raiz:**
- Configuracao `dev:vite` tentava conectar a servidor Vite inexistente
- Frontend nao estava sendo servido corretamente
- `window.go` API nao era injetada

**Solucao Aplicada:**
1. Mudei de `dev:vite` para `dev:watcher` em wails.json
2. Servi arquivos estaticos de `frontend/dist/`
3. Wails injeta runtime automaticamente no modo watcher

**Status:** ✅ RESOLVIDO

---

#### Problema B: Database File Not Found
**Erro:**
```
database file not found or path is invalid:
lstat /Users/menon/git/mdb2sql/go_wails_react/data: no such file or directory
```

**Causa Raiz:**
- Backend esperava `go_wails_react/data/sample.duckdb`
- Arquivo existia em `/Users/menon/git/mdb2sql/data/sample.duckdb`

**Solucao Aplicada:**
```bash
mkdir -p go_wails_react/data
cp data/sample.duckdb go_wails_react/data/
```

**Status:** ✅ RESOLVIDO

---

#### Problema C: Node Modules no Git
**Observacao:**
- Mais de 200.000 linhas de node_modules foram committadas inicialmente
- Ocupavam espaco desnecessario no repositorio

**Solucao Aplicada:**
- Atualizei `.gitignore` para excluir node_modules
- Git removeu automaticamente no proximo commit

**Status:** ✅ RESOLVIDO

---

### 3. Python + PyQt6

#### Problema A: Poetry Interpreter Path (LEGADO - migrado para uv)
**Erro:**
```
(eval):1: /opt/homebrew/bin/poetry: bad interpreter:
/opt/homebrew/opt/python@3.11/bin/python3.11: no such file or directory
```

**Causa Raiz (historico):**
- Poetry foi instalado com Python 3.11
- Sistema atualizava para Python 3.14 e symlink quebrou

**Solucoes Alternativas (historicas):**
1. Executar diretamente via venv: `.venv/bin/python src/main.py`
2. (historico) Reinstalar Poetry para Python 3.14
3. (historico) Usar Poetry via `python3 -m poetry`

**Estado Atual:** stack Python migrou para uv; problema nao se aplica mais. Manter registro apenas para audit trail.

---

## DECISOES TECNICAS TOMADAS

### 1. Go Wails - Modo Watcher vs Vite

**Decisao:** Usar `dev:watcher` em vez de `dev:vite`

**Justificativa:**
- Watcher serve arquivos estaticos diretamente
- Nao precisa de build process separado
- Wails injeta runtime automaticamente
- Mais simples para POC

**Configuracao:**
```json
{
  "frontend": {
    "dev:watcher": {
      "enabled": true
    }
  }
}
```

---

### 2. Interface Go Wails - HTML Puro vs React Build

**Decisao:** HTML/CSS/JS puro em `frontend/dist/index.html`

**Justificativa:**
- Evita complexidade de build do React
- Nao precisa de npm run build
- Codigo inline facilita debug
- Suficiente para POC

**Resultado:**
- Interface completa em 357 linhas de HTML
- 0 dependencias de runtime
- Funciona perfeitamente

---

### 3. Dual-Level Comments (NIVEL BASICO/TECNICO)

**Decisao:** Manter comentarios em dois niveis conforme especificado

**Aplicacao:**
```go
// NIVEL BASICO: Valida caminho do banco de dados
// NIVEL TECNICO: Prevents path traversal via symlinks and validates file extension
func (a *App) validateDatabasePath(dbPath string) (string, error) {
```

**Status:** Aplicado parcialmente (precisa completar em todos os arquivos)

---

## LICOES APRENDIDAS

### 1. Versionamento de Ferramentas Desktop

**Problema:** Tauri v1 vs v2 incompatibilidade total
**Licao:** Sempre especificar versoes exatas em POCs
**Acao:** Documentar versoes usadas com sucesso

### 2. Estrutura de Diretorios

**Problema:** Paths relativos confusos em projetos multi-dir
**Licao:** Executar sempre do mesmo diretorio base
**Acao:** Criar scripts wrapper que garantem working directory correto

### 3. Package Managers

**Problema (historico):** Poetry/npm/pnpm/cargo tem comportamentos diferentes; Python migrou para uv
**Licao:** Documentar comandos exatos para cada plataforma
**Acao:** Scripts `run_*.sh` para cada implementacao

---

## MELHORIAS NECESSARIAS

### Alta Prioridade
1. [ ] Completar comentarios NIVEL BASICO/TECNICO em TODOS os arquivos
2. [ ] Resolver Rust Tauri build (atualizar para v2 ou downgrade para v1)
3. [ ] Documentar versoes exatas de todas as ferramentas
4. [ ] Criar READMEs especificos de cada projeto

### Media Prioridade
5. [ ] Padronizar UI entre as 3 implementacoes
6. [ ] Adicionar tratamento de erros mais robusto
7. [ ] Criar testes basicos para cada implementacao

### Baixa Prioridade
8. [ ] Otimizar build do Go Wails
9. [ ] Melhorar Poetry workflow
10. [ ] Adicionar CI/CD basico

---

## VERSOES QUE FUNCIONARAM

### macOS Darwin 25.1.0

#### Go + Wails
```
go version go1.23.3 darwin/arm64
wails version v2.11.0
node v23.3.0
npm 10.9.0
```

#### Python + PyQt6
```
Python 3.12.x
uv (latest)
PyQt6 == (verificar em pyproject.toml)
```

#### Rust + Tauri
```
rustc 1.83.0
cargo 1.83.0
tauri-cli 1.x (PROBLEMA: incompativel com v2 schema)
```

---

## PROXIMOS PASSOS

1. Criar guia passo-a-passo para Windows 11
2. Criar guia passo-a-passo para Debian 13
3. Documentar instalacao de TODAS as dependencias
4. Testar processo completo em VM limpa
5. Criar scripts de setup automatizado

---

**Ultima Atualizacao:** 2025-11-20 21:50 UTC-3
**Responsavel:** Claude Code
**Branch:** dev
**Commit:** f7b6315
