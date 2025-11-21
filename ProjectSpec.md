# PROJECT SPECIFICATION - MDB2SQL

**Version:** 0.1.0
**Date:** 2025-11-21
**Status:** POC Phase Complete, Active Development

---

## OVERVIEW

Sistema multi-plataforma para gestao, pesquisa e comparacao de bancos de dados MDB rotativos exportados do Oracle. Foco em performance, flexibilidade e experiencia de usuario.

---

## CONTEXT

- Bancos MDB sao exportacoes rotativas Oracle
- Formato: `importacao/YYYYMM_dbN.mdb` onde N = numero rotativo (db1, db3, etc)
- Multiplos bancos por mes sao possiveis
- Ultimo banco sempre considerado padrao
- Relacoes existem entre tabelas do mesmo banco

---

## CORE REQUIREMENTS

### 1. PLATAFORMAS
- Windows 11 (foco principal)
- Linux
- macOS
- Distribuicao: binario unico sem dependencias externas

### 2. BANCO DE DADOS
- Pre-carregar ultimo banco se tamanho permitir
- Pesquisas padrao sempre no ultimo banco
- Suporte a queries multi-banco

### 3. PERFORMANCE CRITICA
- Comparacoes entre bancos devem ser muito rapidas
- Buscas cross-table com baixa latencia
- Indices otimizados para campos principais

---

## FEATURES

### F1: PESQUISA
- Busca por termos em campos/tabelas/bancos
- Exclusao de termos
- Suporte a regex
- Case sensitive/insensitive toggle
- Ignorar acentos toggle
- Filtros cumulativos tipo E (OU previsto, nao implementado ainda)
- Highlight visual de termos encontrados

### F2: OCORRENCIAS
- Primeira ocorrencia de termo
- Ultima ocorrencia de termo
- Ocorrencias por campo em DB especifico
- Ocorrencias cross-DB

### F3: PREDICAO ML
- Sugerir campos para nova linha baseado em padroes
- Requer dados suficientes para treinamento
- Confianca/score da sugestao

### F4: CUSTOMIZACAO
- Filtrar/exibir/ocultar colunas por tabela
- Regras de exibicao salvas
- Filtros cumulativos
- Travar banco escolhido (override padrao)
- Filtros por ano/periodo

### F5: PREFERENCIAS
- Temas: gruvbox, tokyonight, nord, darkmodern
- Contraste adequado para acessibilidade
- Highlight de selecao visivel
- Highlight de search hits nao conflita com selecao
- Salvamento facil de configuracoes

### F6: COMPARACAO (DIFF)
- Comparar 2 bancos quaisquer (padrao: 2 ultimos)
- Relatorio visual de mudancas
- Exibir linhas alteradas
- Detalhar campos alterados
- Performance: comparacao rapida mesmo com muitos dados
- Export de relatorio (MD/HTML)

### F7: VALIDACAO BATCH
- Importar linhas novas (CSV/JSON)
- Validar consistencia
- Detectar conflitos com dados existentes
- Relatorio de validacao

---

## TECHNICAL DECISIONS

### IMPLEMENTACOES PARALELAS

Projeto mantem 3 implementacoes + POC arquivado:

#### PYTHON + PYQT6 (Funcional - Producao)
- Backend: Python 3.14 + Poetry
- Frontend: PyQt6
- DB: DuckDB (read-only mode)
- Status: Feature complete, security hardened
- Package Manager: Poetry (pyproject.toml)

#### GO + WAILS + REACT (Funcional - Producao)
- Backend: Go 1.23 + go-duckdb
- Frontend: React 19 + Vite
- Bridge: Wails v2.11
- DB: DuckDB embedded
- Status: Feature complete, security hardened
- Package Manager: pnpm 10.x (frontend), Go modules (backend)

#### RUST + TAURI + SVELTE (POC - Em Desenvolvimento)
- Backend: Rust 1.83
- Frontend: Svelte + Vite
- Bridge: Tauri v2
- DB: duckdb-rs
- Status: Known compatibility issues, linker errors
- Package Manager: Cargo (backend), pnpm (frontend)
- Issues: Arrow Flight dependency, Tauri v1/v2 migration

#### POC (Arquivado)
- Codigo original pre-refactor
- Referencia historica
- Localizacao: poc/

### DATABASE ENGINE
- DuckDB escolhido por:
  - Analytics SQL otimizado
  - ATTACH multiplos databases
  - Embedded (no server)
  - Bindings para Rust/Go/Python

### CONVERSAO MDB
- Manter mdbtools (rapido) e Jackcess (confiavel)
- Remover pyodbc (Windows-only descartado)
- Output: DuckDB nativo
- Metadata JSON acompanha cada conversao

---

## ARCHITECTURE PATTERNS

### MODULARIZACAO
- Separacao clara backend/frontend
- Schemas/configs externalizados
- Mapeamentos de campos/tabelas/relacoes em JSON
- Codigo preparado para features futuras (temas, filtros OU, etc)

### ESTRUTURA DIRETORIOS (POR IMPLEMENTACAO)
```
{impl}/
├── src/
│   ├── backend/
│   ├── frontend/
│   └── shared/
├── config/
│   ├── schemas/
│   ├── column_mappings/
│   ├── table_rules/
│   └── display_preferences/
├── data/               # bancos convertidos
├── importacao/         # MDBs originais
├── scripts/            # auxiliares
├── build/              # artefatos compilacao
└── test/               # testes
```

### NAMING CONVENTIONS
- Arquivos/diretorios: `snake_case` (codigo) e `PascalCase` (documentacao)
- Arquivos MD de documentacao: PascalCase (SetupWindows.md, ProjectSpec.md, etc)
- Sem acentos, cedilhas, espacos, emojis
- Ingles tecnico em codigo
- Dual-level comments: portugues basico + `!T:` ingles tecnico
- Package managers: pnpm (JS), Poetry (Python), Cargo (Rust), Go modules (Go)

---

## DATA MAPPINGS

### FIELDS PRIORITY
- Primeiros campos geralmente tem valores principais
- IDs sempre prioritarios
- Mapeamento fixo: `config/column_mappings/field_priority_map.json`

### TABLE RELATIONS
- FKs entre tabelas mapeadas
- Cascata de mudancas deve ser rastreavel
- Arquivo: `config/table_rules/relations_map.json`

### SCHEMAS
- Tipos, constraints, defaults
- Arquivo: `config/schemas/standard_schema.json`

---

## DEVELOPMENT METHODOLOGY

### EXTREME PROGRAMMING (XP)
- Ciclo: Entender -> Codificar -> Corrigir -> Adicionar Feature -> Refatorar
- Implementacao incremental
- Nunca reescrever codigo inteiro
- Funcionalidades existentes sao imutaveis (apenas estender)

### SYNC REQUIREMENTS
- Todas 4 implementacoes devem ter mesmas features
- Commits sincronizados
- Diario de bordo trackeia estado de cada implementacao

### DOCUMENTATION
- Dual-level comments: Portuguese (basic) + `// !T:` English (technical)
- Documentation files: PascalCase (SetupWindows.md, ProjectSpec.md)
- Comprehensive setup guides for Windows 11, Debian 13.2, macOS
- Concept guides per implementation in temp/ folders
- Security documentation: path traversal, SQL injection prevention

---

## QUALITY CONSTRAINTS

### CODE STYLE
- Sem adjetivos desnecessarios (profissional, melhorado, production-ready)
- Nomes descritivos e concisos
- Validacao lexica antes de gerar codigo
- Codigo testavel

### SECURITY
- Input sanitization (SQL injection, path traversal)
- Validacao tipos
- Backup antes de operacoes destrutivas

### PERFORMANCE
- Indices estrategicos
- Cache inteligente
- Lazy loading quando apropriado
- Profile antes de otimizar

---

## ROADMAP PHASES

### PHASE 1: FOUNDATION
- Estrutura diretorios
- Setup builds
- Conversao MDB -> DuckDB
- Load/display ultimo banco

### PHASE 2: SEARCH
- Busca simples (termo, campo, tabela)
- Regex support
- Case/accent insensitive
- Highlight hits

### PHASE 3: MULTI-DB
- ATTACH multiplos DBs
- Primeira/ultima ocorrencia
- Cross-DB search

### PHASE 4: CUSTOMIZATION
- Column show/hide
- Filters cumulativos (E apenas)
- Preferences save/load
- Temas basicos

### PHASE 5: DIFF ENGINE
- Comparacao 2 bancos
- Visual diff viewer
- Export relatorio

### PHASE 6: ADVANCED
- ML prediction
- Batch validation
- Temas completos
- Polish UI/UX

---

## OPEN QUESTIONS

### IMMEDIATE
- Frequencia atualizacao diario? (diaria/semanal/por feature)
- Prioridade features? (assumindo: search -> diff -> ML -> batch)

### FUTURE
- Filtros OU: UI design (pills, query builder?)
- ML: qual biblioteca? (sklearn simples vs tensorflow?)
- Temas: customizacao user ou presets fixos?

---

## CONSTRAINTS

### IMMUTABLE
- Multi-plataforma
- Performance em comparacoes
- Sem dependencias Python para distribuicao final
- 4 implementacoes sincronizadas

### FLEXIBLE
- Choice entre implementacoes para uso
- Adicao de novos temas
- Extensao de features

---

**Document End**
