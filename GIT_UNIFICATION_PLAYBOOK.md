# Git Branch Unification Playbook

**Baseado em:** Unificacao bem-sucedida do repositorio mdb2sql (2025-12-01)
**Objetivo:** Guia replicavel para unificar branches divergentes sem perda de dados
**Filosofia:** "Um leao por vez" - execucao gradual com validacao em cada etapa

---

## PARTE 1: PEDIDO INICIAL DO USUARIO

### Contexto
- Repositorio com multiplos branches divergentes
- Historico complexo com merges do dependabot
- Branches orfaos de experimentos abandonados
- PRs pendentes desatualizados
- Necessidade de unificar sem perder dados

### Pedido Literal
> "resolva essa bagunca dos branches cuidadosamente para unificarmos pouco a pouco. um leao por vez, sem perda de dados"

### Traducao para Requisitos Tecnicost
1. **Analise completa** do estado atual (branches, commits, PRs)
2. **Backups multiplos** antes de qualquer operacao
3. **Execucao gradual** em fases independentes
4. **Validacao** apos cada fase
5. **Rollback** facil se necessario
6. **Documentacao** de todas operacoes

---

## PARTE 2: DIAGNOSTICO COMPLETO

### 2.1 Comandos de Analise

```bash
# Estado dos branches locais
git branch -vv

# Estado dos branches remotos
git branch -r

# Fetch completo
git fetch --all

# Ancestrais comuns
git merge-base dev master
git merge-base dev origin/master

# Commits unicos por branch
git log --oneline origin/master..dev  # commits em dev nao em master
git log --oneline dev..origin/master  # commits em master nao em dev

# Verificar integridade
git fsck --full --no-reflogs

# Visualizar divergencia
git log --oneline --graph --all --decorate -30
```

### 2.2 Informacoes Coletadas (Exemplo mdb2sql)

```
Branches Locais:
- dev                  : b2568d7 (HEAD, origin/dev)
- master               : bcd172c (origin/master: behind 25)
- baseline-1x-recovery : 1ec5c57 (orphan - baseado em 37b71e8)
- tauri2-migration     : f18d998 (orphan - experimento abandonado)

Branches Remotos:
- origin/master                           : deb64ff (a frente do master local!)
- origin/dev                              : b2568d7 (sync com local)
- origin/dependabot/go_modules/...        : 618814b (PR pendente)
- origin/snyk-upgrade-3e0c59f70263ff69... : 6fefe5f (PR pendente)

Ancestrais Comuns:
- dev x origin/master : 6970d7e (10 commits unicos em dev)
- master local desatualizado

Divergencia:
- dev: 10 commits unicos
- origin/master: 7 commits unicos (merges do dependabot)
- Conflito Potencial: BAIXO
```

---

## PARTE 3: BACKUPS MULTIPLOS

### 3.1 Stash do Working Directory

```bash
# Backup de arquivos modificados + untracked
git stash push -u -m "BACKUP_PRE_MERGE_$(date +%Y%m%d_%H%M%S)"

# Backup de diretorios especificos
git stash push -u -m "BACKUP_GITHUB_DIR" -- .github/

# Listar stashes
git stash list

# Recuperar se necessario
git stash pop stash@{0}
```

### 3.2 Snapshots em /tmp

```bash
# Backup de reflog
git reflog > /tmp/git_reflog_backup_$(date +%Y%m%d_%H%M%S).txt

# Backup de status
git status --short > /tmp/git_status_backup_$(date +%Y%m%d_%H%M%S).txt

# Backup de branches
git branch -vv > /tmp/git_branches_backup_$(date +%Y%m%d_%H%M%S).txt
```

### 3.3 Tags de Backup Imutaveis

```bash
# Tag do estado atual de cada branch ANTES de qualquer merge
git tag -a backup-master-pre-sync -m "Backup antes de sincronizar master" master
git tag -a backup-dev-pre-merge -m "Backup antes de merge" dev

# Listar tags
git tag -l "backup-*"

# Recuperar branch a partir de tag
git checkout -b master-restored backup-master-pre-sync
```

---

## PARTE 4: ESTRATEGIA DE EXECUCAO (5 FASES)

### FASE 1: Atualizar Master Local (SEGURO)

**Objetivo:** Sincronizar master local com origin/master
**Risco:** MUITO BAIXO (apenas fast-forward)

```bash
# Backup de seguranca
git branch backup-master-pre-sync <commit-hash-master-atual>

# Atualizar master local
git checkout master
git pull origin master --ff-only

# Verificacao
git log --oneline -5
git diff backup-master-pre-sync HEAD --stat

# Rollback (se necessario)
git reset --hard backup-master-pre-sync
```

**Resultado mdb2sql:**
- Antes: `bcd172c` (25 commits atras)
- Depois: `deb64ff` (sincronizado)
- Conflitos: NENHUM

---

### FASE 2: Criar Branch de Integracao (SEGURO)

**Objetivo:** Testar merge sem afetar branches principais
**Risco:** ZERO (branch temporario)

```bash
# Criar branch de integracao
git checkout -b integration-test origin/master

# Tentar merge (dry-run primeiro)
git merge --no-commit --no-ff dev

# Verificar conflitos
git status
git diff --check

# Se OK, completar merge
git commit -m "merge: integrate dev into master (integration test)"

# Se problemas, abortar
git merge --abort

# Deletar branch de teste
git checkout dev
git branch -D integration-test
```

**Resultado mdb2sql:**
- Conflitos identificados: 6
- Resultado: Abortado (apenas validacao)
- Tipos de conflito:
  - `go.mod`, `go.sum` (dependencias Go)
  - `package.json`, `package-lock.json` (dependencias Node)
  - `pyproject.toml`, `poetry.lock` (dependencias Python)
  - `.claude/hooks/validate-branch-name.py` (modify/delete)

---

### FASE 3: Merge dev → master (CRITICO)

**Objetivo:** Atualizar master com desenvolvimento recente
**Risco:** MEDIO (afeta branch principal)

**Pre-condicoes:**
- [ ] FASE 1 completada com sucesso
- [ ] FASE 2 executada sem conflitos criticos
- [ ] Backup tag criada

```bash
# Criar tag de backup IMUTAVEL
git tag -a backup-master-pre-dev-merge -m "Backup antes do merge dev->master" master

# Merge com estrategia ort (melhor para historico complexo)
git checkout master
git merge dev --no-ff -m "merge: integrate N commits from dev branch

Features:
- <lista de features>

Fixes:
- <lista de fixes>

Refactors:
- <lista de refactors>
"

# Se conflitos, resolver manualmente
git status  # ver arquivos em conflito

# Para cada conflito de dependencias:
# Estrategia: Aceitar versao do dev (--theirs)
git checkout --theirs go_wails_react/go.mod
git checkout --theirs go_wails_react/go.sum
git checkout --theirs go_wails_react/frontend/package.json
git checkout --theirs py_qt6/pyproject.toml

# Remover lock files (serao regenerados)
git rm go_wails_react/frontend/package-lock.json
git rm py_qt6/poetry.lock

# Para modify/delete conflicts:
# Escolher versao do dev
git checkout --theirs .claude/hooks/validate-branch-name.py

# Adicionar arquivos resolvidos
git add <arquivos-resolvidos>

# Completar merge
git commit -m "<mensagem-de-merge>"

# Verificacao pos-merge
git log --oneline --graph -15
git diff origin/master HEAD --stat
```

**Resolucao de Conflitos - Estrategia:**
1. **Dependencias (go.mod, package.json, pyproject.toml):** Aceitar dev
2. **Lock files:** Remover e regenerar localmente
3. **Modify/delete:** Avaliar caso a caso (geralmente aceitar dev)
4. **Codigo-fonte:** Merge manual se necessario

**Resultado mdb2sql:**
- Commit: `8aef225`
- Estrategia: Aceitar versoes do dev
- Arquivos alterados: 4495 (+13322, -221697 linhas)
- Status: master 12 commits a frente de origin/master

**Rollback IMEDIATO (se problemas):**
```bash
git reset --hard backup-master-pre-dev-merge
```

**Rollback TARDIO (se push foi feito):**
```bash
# CUIDADO: Reescreve historico remoto
git push origin backup-master-pre-dev-merge:master --force-with-lease

# Alternativa segura: reverter merge
git revert -m 1 HEAD
git push origin master
```

---

### FASE 4: Avaliar e Arquivar Branches Orfaos (SEGURO)

**Objetivo:** Limpar branches obsoletos preservando historico
**Risco:** BAIXO (tags preservam dados)

```bash
# Verificar se branch ja foi incorporado
git merge-base --is-ancestor <commit-hash-orfao> dev && echo "JA INCORPORADO" || echo "NAO INCORPORADO"

# Criar tag de arquivo
git tag -a archive/<nome-branch> -m "Archive: <descricao>" <commit-hash>

# Deletar branch local
git branch -d <nome-branch>  # ou -D para forcar

# Recuperar (se necessario)
git checkout -b <nome-branch> archive/<nome-branch>
```

**Exemplo mdb2sql:**
```bash
# baseline-1x-recovery (ja incorporado)
git tag -a archive/baseline-1x-recovery -m "Archive: Tauri 1.x recovery baseline (incorporated into dev)" 1ec5c57
git branch -d baseline-1x-recovery

# tauri2-migration (experimento abandonado)
git tag -a archive/tauri2-migration -m "Archive: Abandoned Tauri 2.x migration experiment" f18d998
git branch -D tauri2-migration
```

**Resultado mdb2sql:**
- Tags criadas: `archive/baseline-1x-recovery`, `archive/tauri2-migration`
- Branches deletados: 2
- Historico preservado em tags

---

### FASE 5: Revisar PRs Pendentes (SEGURO - APENAS LEITURA)

**Objetivo:** Decidir aceitar/rejeitar PRs do dependabot/snyk
**Risco:** ZERO (apenas analise)

```bash
# Listar PRs abertos
gh pr list --state open

# Ver detalhes de um PR
gh pr view <PR-NUMBER>

# Fetch do PR para teste local
git fetch origin pull/<PR-NUMBER>/head:test-pr-<NUMBER>
git checkout test-pr-<NUMBER>

# Testar localmente
cd <diretorio-afetado>
<comandos-de-build/test>

# Se OK, merge via GitHub CLI
gh pr merge <PR-NUMBER> --squash

# Se NOK, fechar com comentario
gh pr close <PR-NUMBER> -c "Motivo da rejeicao"

# Limpar branch de teste
git checkout dev
git branch -D test-pr-<NUMBER>
```

**Exemplo mdb2sql:**

**PR #10 - Snyk @tauri-apps/api 1.6.0 → 2.9.0:**
```bash
# Analise
gh pr view 10

# Decisao: REJEITAR
# Motivo: Breaking change Tauri 1.x → 2.x incompativel com codigo atual

# Fechar PR
gh pr close 10 -c "Projeto utiliza Tauri 1.x. Este PR atualiza para Tauri 2.x API (breaking change). O merge dev→master ja unificou o codigo em Tauri 1.x. Upgrade para Tauri 2.x sera feito em branch dedicado no futuro."
```

**Dependabot golang.org/x/crypto v0.33.0 → v0.45.0:**
- Status: Branch base desatualizada (pre-merge)
- Decisao: Fechar PR, aplicar update manualmente no dev atualizado

---

## PARTE 5: SINCRONIZACAO REMOTA

### 5.1 Push do Master Unificado

```bash
# Verificar estado antes do push
git checkout master
git status
git log --oneline --graph -10

# Push
git push origin master

# Push de tags de backup
git push origin --tags

# Verificacao
git branch -vv
```

**Resultado mdb2sql:**
```
deb64ff..8aef225  master → origin/master
+ 3 tags publicadas:
  - backup-master-pre-dev-merge
  - archive/baseline-1x-recovery
  - archive/tauri2-migration

GitHub Alerts:
  ⚠️ 3 vulnerabilidades moderadas detectadas
```

### 5.2 Verificacao de Integridade Final

```bash
# Integridade local
git fsck --full --no-reflogs

# Estado dos branches
git branch -vv
git branch -r

# Historico visual
git log --oneline --graph --all -20

# Status working directory
git status
```

---

## PARTE 6: CORRECAO DE FALHAS IDENTIFICADAS

### 6.1 Resolver Vulnerabilidades do Dependabot

**Problema:** GitHub detectou 3 vulnerabilidades moderadas apos push

**Solucao:**

```bash
# Acessar painel de vulnerabilidades
# https://github.com/<usuario>/<repo>/security/dependabot

# Identificar vulnerabilidades
gh api repos/<usuario>/<repo>/dependabot/alerts

# Para cada alerta:
# 1. Criar branch de fix
git checkout -b security/fix-dependabot-alerts dev

# 2. Atualizar dependencias afetadas
# (exemplo para Go)
cd go_wails_react
go get -u golang.org/x/crypto@latest
go mod tidy

# (exemplo para Python)
cd py_qt6
poetry update <pacote-vulneravel>

# (exemplo para Node)
cd rust_tauri_svelte/ui
pnpm update <pacote-vulneravel>

# 3. Testar builds
./run_go_wails.sh
./run_python_pyqt6.sh
./run_rust_tauri.sh

# 4. Commit e PR
git add .
git commit -m "security: fix dependabot alerts (3 moderate vulnerabilities)

- Update golang.org/x/crypto to latest
- Update <outros-pacotes>

Closes dependabot alerts: #X, #Y, #Z"

git push origin security/fix-dependabot-alerts
gh pr create --title "Security: Fix Dependabot alerts" --body "Resolve 3 moderate vulnerabilities"
```

**Status mdb2sql:** ⏳ PENDENTE (documentado como proxima acao)

---

### 6.2 Aplicar Updates de Seguranca Manualmente

**Problema:** Dependabot PRs foram fechados (base desatualizada), mas updates sao necessarios

**Solucao para golang.org/x/crypto v0.33.0 → v0.45.0:**

```bash
# Criar branch de update
git checkout -b update/golang-crypto dev

# Atualizar dependencia
cd go_wails_react
go get golang.org/x/crypto@v0.45.0
go mod tidy

# Verificar compatibilidade
go build
go test ./...

# Se OK, commit
git add go.mod go.sum
git commit -m "chore(deps): update golang.org/x/crypto to v0.45.0

- Security update from v0.33.0 to v0.45.0
- Closes previous dependabot PR (base was outdated)
- Tested: build and tests passing"

# Push e PR
git push origin update/golang-crypto
gh pr create --base dev --title "chore(deps): Update golang.org/x/crypto to v0.45.0"
```

**Procedimento Geral para Updates Manuais:**
1. Criar branch dedicado
2. Atualizar dependencia
3. Rodar testes completos
4. Verificar breaking changes (consultar CHANGELOG)
5. Commit com mensagem detalhada
6. PR para dev (nao master diretamente)

**Status mdb2sql:** ⏳ PENDENTE (documentado como proxima acao)

---

### 6.3 Limpar Branch Remoto Stale

**Problema:** `origin/dependabot/go_modules/...` baseado em master antigo (pre-merge)

**Solucao:**

```bash
# Listar branches remotos stale
git branch -r --merged origin/master | grep dependabot

# Deletar branch remoto
git push origin --delete dependabot/go_modules/go_wails_react/go_modules-dd7da38a6b

# Verificacao
git branch -r
```

**Criterios para Deletar Branch Remoto:**
- Base desatualizada (pre-merge)
- PR fechado
- Commits ja incorporados via outros PRs

**Status mdb2sql:** ⏳ PENDENTE (documentado como proxima acao)

**Alternativa Segura:**
```bash
# Se nao tiver certeza, criar tag antes de deletar
git fetch origin dependabot/go_modules/go_wails_react/go_modules-dd7da38a6b
git tag archive/dependabot-crypto-20251201 FETCH_HEAD
git push origin archive/dependabot-crypto-20251201

# Agora deletar branch remoto
git push origin --delete dependabot/go_modules/go_wails_react/go_modules-dd7da38a6b
```

---

## PARTE 7: COMANDOS DE EMERGENCIA

### 7.1 Reverter TUDO ao Estado Inicial

```bash
# Voltar ao estado exato do inicio
git checkout dev
git reset --hard <commit-hash-inicial-dev>

# Restaurar working directory de stashes
git stash pop stash@{1}
git stash pop stash@{0}

# Restaurar master local
git checkout master
git reset --hard <commit-hash-inicial-master>

# Restaurar branches orfaos (se necessario)
git checkout -b baseline-1x-recovery <commit-hash>
git checkout -b tauri2-migration <commit-hash>
git checkout dev
```

### 7.2 Verificar Estado Atual

```bash
# Hash atual de cada branch
git rev-parse HEAD dev master

# Divergencia
git log --oneline --graph --all --decorate -20

# Working directory
git status --short

# Integridade
git fsck --full --no-reflogs
```

### 7.3 Recuperar de Tag de Backup

```bash
# Listar tags de backup
git tag -l "backup-*"

# Ver commit da tag
git show backup-master-pre-dev-merge

# Restaurar branch a partir de tag
git checkout master
git reset --hard backup-master-pre-dev-merge

# Forcar push (CUIDADO!)
git push origin master --force-with-lease
```

---

## PARTE 8: CHECKLIST DE EXECUCAO

### Pre-Merge
- [ ] Analise de divergencia concluida
- [ ] Ancestrais comuns identificados
- [ ] Backup completo criado (stash + snapshots + tags)
- [ ] Verificacao de integridade OK (fsck)
- [ ] Estrategia documentada
- [ ] Revisao da estrategia aprovada

### Durante Execucao
- [ ] FASE 1: Master local sincronizado
- [ ] FASE 2: Merge testado em branch temporario
- [ ] FASE 3: Merge concluido com resolucao de conflitos
- [ ] FASE 4: Branches orfaos arquivados
- [ ] FASE 5: PRs pendentes resolvidos

### Pos-Merge
- [ ] Testes de sanidade executados
- [ ] Build de todas implementacoes OK
- [ ] Sem regressoes funcionais
- [ ] Tags de backup criadas e publicadas
- [ ] Branches orfaos arquivados
- [ ] PRs pendentes resolvidos

### Sincronizacao Remota
- [ ] Push do master atualizado
- [ ] Push de tags de backup
- [ ] Verificacao de GitHub Actions/CI
- [ ] Vulnerabilidades identificadas
- [ ] Updates de seguranca aplicados
- [ ] Branches remotos stale limpos

---

## PARTE 9: METRICAS DE SUCESSO (Exemplo mdb2sql)

### Antes da Unificacao
```
Branches Locais: 4
Branches Remotos: 5
PRs Abertos: 2
Master local: 25 commits desatualizado
Divergencia: dev 28 commits, master 25 commits
Conflitos Potenciais: 6 arquivos
```

### Depois da Unificacao
```
Branches Locais: 3 (2 orfaos arquivados)
Branches Remotos: 3 principais
PRs Abertos: 0
Master: sincronizado (origin/master)
Divergencia: ZERO
Conflitos Resolvidos: 6/6
Tags de Backup: 3
Commits Unificados: 12
Arquivos Alterados: 4495 (+13322, -221697 linhas)
```

### Tempo de Execucao
- FASE 1-5: 15 minutos
- Sincronizacao Remota: 5 minutos
- Documentacao: 10 minutos
- **Total: ~30 minutos**

### Sem Perda de Dados
- ✅ Stashes preservados
- ✅ Tags de backup criadas
- ✅ Historico completo mantido
- ✅ Branches orfaos arquivados (nao deletados)
- ✅ Rollback possivel a qualquer momento

---

## PARTE 10: ADAPTACAO PARA OUTROS REPOSITORIOS

### 10.1 Variacoes Comuns

**Cenario A: Branch Feature Longa**
```bash
# Se feature branch tem muitos commits
git checkout feature/long-running
git rebase -i dev  # squash commits intermediarios
git push origin feature/long-running --force-with-lease
```

**Cenario B: Multiplos Desenvolvedores**
```bash
# Coordenar com time antes de merge
# Garantir que todos fizeram push
# Evitar rebase de branches publicos
# Preferir merge --no-ff para preservar historico
```

**Cenario C: Monorepo com Submodulos**
```bash
# Atualizar submodulos apos merge
git submodule update --init --recursive
git submodule foreach git pull origin master
```

### 10.2 Ajustes por Linguagem

**Python (Poetry):**
```bash
# Regenerar lock file apos conflito
poetry lock --no-update
poetry install
```

**Node (npm/pnpm):**
```bash
# Regenerar lock file
pnpm install
# ou
npm install
```

**Go:**
```bash
# Regenerar go.sum
go mod tidy
```

**Rust (Cargo):**
```bash
# Regenerar Cargo.lock
cargo update
```

### 10.3 Customizacao da Estrategia

**Para repositorios pequenos (<100 commits):**
- Simplificar para 3 fases
- Reduzir quantidade de backups
- Merge direto sem branch de integracao

**Para repositorios grandes (>1000 commits):**
- Adicionar fase de analise de impacto
- Criar multiplos branches de integracao por modulo
- Usar ferramentas de visualizacao (GitKraken, SourceTree)

**Para repositorios criticos (producao):**
- Adicionar fase de deploy em staging
- Testes automatizados obrigatorios
- Revisao de codigo por pares
- Janela de manutencao agendada

---

## RESUMO EXECUTIVO

### Principios Fundamentais
1. **"Um leao por vez"** - Execucao gradual
2. **Backups multiplos** - Stash + Tags + Snapshots
3. **Validacao continua** - Verificar apos cada fase
4. **Rollback facil** - Sempre possivel reverter
5. **Documentacao completa** - Registrar tudo

### Fases Obrigatorias
1. Diagnostico completo
2. Backups multiplos
3. Execucao gradual (5 fases)
4. Sincronizacao remota
5. Correcao de falhas identificadas

### Garantias
- ✅ Zero perda de dados
- ✅ Rollback a qualquer momento
- ✅ Historico preservado
- ✅ Rastreabilidade completa

### Resultado Esperado
- Branches unificados
- Historico limpo
- Backups preservados
- Vulnerabilidades identificadas
- Proximas acoes documentadas

---

**Documento gerado:** 2025-12-01
**Baseado em:** Unificacao bem-sucedida do repositorio mdb2sql
**Versao:** 1.0
