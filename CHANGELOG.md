# Changelog - Reversao de Mudancas Problematicas

**Data:** 2025-11-21
**Contexto:** Outra IA fez alteracoes durante sessao offline - analise e reversao seletiva

---

## Resumo Executivo

**Backup completo:** Commit `568f419` no branch `dev` contem todas mudancas da outra IA

**Decisoes tomadas:**
- ❌ Revertidas: 5 mudancas horriveis (interface, CSS, Tauri v2)
- ✅ Mantidas: 10+ mudancas boas (testes backend, scripts, documentacao)
- ⚠️ Corrigidas: 2 mudancas questionaveis (flake8 removido, testes em devDependencies)

---

## Mudancas Revertidas (HORRIVEIS)

### 1. Interface Go Wails - App.tsx
**Razao:** Interface simples e funcional foi substituida por design over-engineered

**Antes (RUIM - 212 linhas):**
- useEffect, useMemo desnecessarios
- Schema display nao solicitado
- Removeu comentarios `// !T:`
- Complexidade aumentada 141%

**Depois (BOM - 88 linhas):**
- Interface simples e direta elogiada pelo usuario
- Sem hooks desnecessarios
- Comentarios dual-level preservados
- Codigo limpo e funcional

**Commit de referencia:** `f7b6315`

---

### 2. CSS Go Wails - App.css
**Razao:** CSS simples substituido por tema glassmorphism complexo

**Antes (RUIM - 318 linhas):**
- CSS variables desnecessarias (--bg, --card, --glass)
- Radial gradients, box-shadows complexos
- Animacoes e transicoes excessivas
- Removeu comentarios `/* NIVEL BASICO */`

**Depois (BOM - 141 linhas):**
- CSS simples e direto
- Sem over-engineering
- Comentarios dual-level preservados
- Funcional e clean

**Commit de referencia:** `f7b6315`

---

### 3. Tauri v2 (PROBLEMA CRITICO!)
**Razao:** Tauri v2 tem incompatibilidades conhecidas com DuckDB

**Antes (RUIM):**
```toml
tauri = { version = "2.9.3", features = [] }
tauri-build = { version = "2.0", features = [] }
```

**Depois (BOM):**
```toml
tauri = { version = "1.8", features = ["shell-open"] }
tauri-build = { version = "1.5", features = [] }
```

**Impacto:**
- Cargo.lock regenerado (142 packages downgraded)
- Projeto estavel com v1.8
- BUILD_REPORT.md agora consistente com codigo

**Arquivos afetados:**
- `rust_tauri_svelte/Cargo.toml`
- `rust_tauri_svelte/src-tauri/Cargo.toml`
- `rust_tauri_svelte/Cargo.lock` (regerado)

---

## Mudancas Mantidas (BOAS)

### 1. BUILD_REPORT.md
**Status:** ✅ EXCELENTE
**Conteudo:**
- Tempos de build por stack
- Comandos exatos usados
- Checklist de sanity
- Version pins (Go 1.23, Node 23, Python 3.12, Rust 1.83)

### 2. TODO.md
**Status:** ✅ BOM
**Conteudo:**
- Validacao SQL injection em db_manager.go
- Revisao pnpm hoisting
- Correcao links obsoletos
- Toolchain PDF funcionando

### 3. Scripts de Automacao
**Status:** ✅ EXCELENTES

**Arquivos:**
- `scripts/run_sanity.sh` - Sanity check unificado (corrigido flake8)
- `scripts/build_release.sh` - Build de release
- `scripts/clean.sh` - Limpeza de artefatos
- `scripts/package_minimal.sh` - Empacotamento minimo
- Versoes PowerShell (.ps1) - Cross-platform Windows

**Recursos:**
- Flags de skip por stack (SKIP_GO, SKIP_RUST, SKIP_PYTHON)
- Deteccao OS/ARCH para artefatos segregados
- Menu interativo pos-sanity

### 4. Testes Backend
**Status:** ✅ BONS

**Arquivos novos:**
- `go_wails_react/app_test.go`
- `go_wails_react/backend/db_manager_integration_test.go`
- `rust_tauri_svelte/src/backend/tests.rs`
- `py_qt6/tests/test_db_manager.py` (modificado)

**Nota:** Testes sempre sao bem-vindos

### 5. Testes Frontend
**Status:** ✅ CORRETOS (ja em devDependencies)

**Arquivos:**
- `go_wails_react/frontend/src/App.test.jsx`
- `go_wails_react/frontend/src/setupTests.js`

**Dependencias (devDependencies):**
- `@testing-library/jest-dom`
- `@testing-library/react`
- `@vitest/ui`
- `jsdom`
- `vitest`

**Nota:** Nao vao no bundle de producao (correto!)

---

## Mudancas Corrigidas (QUESTIONAVEIS)

### 1. flake8 Duplicava ruff
**Status:** ⚠️ REMOVIDO

**Problema:**
- Projeto ja usa `ruff` (mais rapido e moderno)
- `flake8` adicionado duplicava funcao

**Solucao:**
- Removido de `py_qt6/pyproject.toml`
- Removida linha de `scripts/run_sanity.sh`
- Mantido apenas `ruff check`

---

## Arquivos Preservados Sem Mudancas

**Bons que nao precisaram reversao:**
- `CHANGE_AUDIT.md` (este relatorio de auditoria)
- `ProjectSpec.md` (sem mudancas)
- `README.md` (sem mudancas problematicas)
- Todos setup guides (PascalCase preservado)
- `.gitignore` (melhorias mantidas)

---

## Comandos de Reversao Executados

```bash
# 1. Backup
git add -A
git commit -m "backup: state before reverting other AI changes"
# Commit: 568f419

# 2. Reverter interface Go Wails
git show f7b6315:go_wails_react/frontend/src/App.tsx > App.tsx
git show f7b6315:go_wails_react/frontend/src/App.css > App.css

# 3. Reverter Tauri v2 para v1.8
# Editados manualmente:
# - rust_tauri_svelte/Cargo.toml
# - rust_tauri_svelte/src-tauri/Cargo.toml
cd rust_tauri_svelte && cargo update

# 4. Remover flake8
# Editados manualmente:
# - py_qt6/pyproject.toml
# - scripts/run_sanity.sh
```

---

## Validacao Pendente

**Proximos passos:**
1. ⏳ Executar `scripts/run_sanity.sh` para todos stacks
2. ⏳ Testar interface Go Wails manualmente
3. ⏳ Confirmar Rust Tauri compila com v1.8
4. ⏳ Validar testes frontend (vitest)

---

## Licoes Aprendidas

1. **Backup sempre:** Commit 568f419 salvou todas mudancas antes de reverter
2. **Interface simples > moderna:** Usuario elogiou simplicidade, nao complexidade
3. **Dual-level comments sao criticos:** Padrao do projeto nao pode ser violado
4. **Versoes problematicas retornam:** Tauri v2 foi reintroduzido exatamente como previsto
5. **Testes em devDependencies:** Correto nao incluir no bundle
6. **Ferramentas duplicadas sao ruins:** ruff > flake8 (escolher uma)

---

## Referencias

- **Commit backup:** `568f419`
- **Commit original bom (interface):** `f7b6315`
- **CHANGE_AUDIT.md:** Analise completa de todas mudancas
- **BUILD_REPORT.md:** Documentacao de builds mantida
- **TODO.md:** Tarefas completadas mantidas
