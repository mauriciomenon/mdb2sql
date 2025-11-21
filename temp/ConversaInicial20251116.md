# CONVERSA INICIAL - 2025-11-16

---

## CONTEXTO FORNECIDO PELO USUARIO

### Requisitos Principais

1. **Estrutura de Bancos**
   - MDBs rotativos exportados do Oracle
   - Formato: `YYYYMM_dbN.mdb` onde N = numero rotativo (db1, db3, etc)
   - Multiplos bancos por mes possiveis
   - Numero junto ao db e informacao importante

2. **Premissas**
   - Ultimo banco sempre considerado padrao
   - Se nao for pesado, deve ser pre-carregado
   - Pesquisas padrao sempre consideram ultimo banco
   - Existirao pesquisas para busca de hits em varios bancos

3. **Plataformas**
   - Windows, Linux, macOS
   - Grande foco em Windows 11

4. **Objetivos do Sistema**
   - Pesquisa de campos por termos, exclusao, regex
   - Pesquisa para primeira/ultima ocorrencia
   - Similaridade para criar linha nova sugerindo campos
   - Filtrar colunas, customizacao, regras de exibicao salvas
   - Filtros cumulativos
   - Menu padrao completo
   - Comparar bancos (normalmente 2 ultimos)
   - Relatorio visual de mudancas
   - Gerar relatorio de validacao para batch insert

5. **Detalhes Tecnicos**
   - Primeiros campos tem valores principais (ou no final)
   - Sempre verificar ID
   - Arquivos de mapeamento necessarios
   - Schemas, mapeamentos constantes e confiaveis
   - Estrutura de diretorios: nao muito profunda, nao muitos subniveis
   - Diretorios: build, teste, scripts auxiliares
   - Um arquivo por tecnologia, internamente modularizado

6. **Stack Tecnologias**
   - Python facilidade (domina)
   - DuckDB (minisql similar, domina)
   - PyQt6 (domina)
   - Distribuicao: pyoxidizer, nuitka, pyinstaller
   - Backend: Rust ou Go (rapidos)
   - Frontend: JavaScript moderno, flexivel, bem feito
   - Vue descartado (inflexivel)

7. **Regras de Formato**
   - Nunca usar emojis, acentos, cedilhas, adjetivos
   - Nada de: profissional, final, melhorado, production ready, bullet proof
   - Vale para qualquer conteudo

8. **Diario de Bordo**
   - Manter controle detalhado em MD
   - Pasta temp/ somente para diarios, documentos MD parciais
   - Estrutura nao rigida ainda (estudando)

9. **Remocoes**
   - Remover ODBC Windows mantendo demais

---

## DECISAO INICIAL: PLANO DETALHADO

### Opcoes Apresentadas

**Opcao A: Rust + Tauri + Svelte**
- Backend: Rust (performance maxima)
- Frontend: Svelte (moderno, flexivel, rapido)
- Bridge: Tauri
- DB: DuckDB embedded

**Opcao C: Go + Wails + React**
- Backend: Go
- Frontend: React (flexivel)
- Bridge: Wails
- DB: DuckDB embedded

**Opcao D: Python + PyQt6 + DuckDB (Hibrido)**
- Core: Python modular
- Performance: modulos Rust/Go quando necessario
- Frontend: PyQt6
- DB: DuckDB
- Distribuicao: Nuitka/PyInstaller

### Recomendacao Aceita

Opcao D inicialmente, com porta gradual para Opcao A.

Justificativa:
1. Usuario domina Python/PyQt6/DuckDB
2. DuckDB resolve performance SQL analytics
3. Modulos criticos podem ser Rust/Go
4. Nuitka gera binarios rapidos
5. Migrar modulos conforme gargalos identificados

---

## DECISAO FINAL: ESTRUTURA APROVADA

Usuario decidiu implementar todas 3 opcoes em paralelo:

```
mdb2sql/
├── poc/                    # codigo atual movido
├── rust_tauri_svelte/      # opcao A
├── go_wails_react/         # opcao C
└── py_qt6/                 # opcao D
```

### Regras

1. Cada pasta 100% independente (dados, config, scripts)
2. Implementacao simultanea das 4 versoes
3. XP: funcionar rapido, evoluir incremental
4. Preparar: temas, contraste, highlight search, case/accent insensitive
5. Filtros E/OU (implementar so E agora)
6. Documentacao: nivel basico + comentario tecnico
7. Sincronizacao obrigatoria de features

### Features Preparadas (nao implementadas ainda)

- Temas: gruvbox, tokyonight, nord, darkmodern
- Contraste para acessibilidade
- Highlight search nao conflita com selecao
- Case/accent insensitive toggle
- Filtros E (OU previsto)

---

## ARQUITETURA MODULAR PLANEJADA

### Backend Modules

```
src/backend/
├── db_manager.py          # load, index, metadata MDBs
├── search_engine.py       # regex, termos, exclusoes, multi-db
├── diff_engine.py         # comparacao bancos (candidato Rust/Go)
├── prediction_engine.py   # ML para sugestao linhas novas
├── schema_manager.py      # load/apply schemas e mappings
├── query_builder.py       # queries DuckDB otimizadas
└── export_report.py       # geracao relatorios diff
```

### Frontend Modules

```
src/frontend/
├── main_window.py         # PyQt6 window principal
├── db_selector.py         # widget selecao banco/periodo
├── search_panel.py        # interface busca com filtros
├── result_grid.py         # tabela resultados customizavel
├── diff_viewer.py         # visualizacao mudancas (highlight)
├── column_manager.py      # show/hide/reorder colunas
├── filter_manager.py      # filtros cumulativos
└── preferences.py         # salvar/carregar customizacoes
```

### Config/Schemas

```
config/
├── schemas/
│   └── standard_schema.json      # tipos, constraints
├── column_mappings/
│   └── field_priority_map.json   # quais campos sao ID/principais
├── table_rules/
│   └── relations_map.json        # FK, relations entre tabelas
└── display_preferences/
    └── default_views.json        # colunas visiveis, ordenacao
```

---

## ESTRATEGIA DE DADOS

### Conversao MDB

- Manter convert_mdbtools.py e convert_jackcess.py
- Converter para DuckDB direto
- Estrutura: `data/YYYYMM_dbN.duckdb`
- Metadata: `data/YYYYMM_dbN.meta.json`

### Pre-carregamento

- Ultimo banco sempre carregado em memoria (view DuckDB)
- Indices criados em campos principais

### Buscas Multi-DB

- DuckDB suporta ATTACH multiplos databases
- Query paralela via UNION ALL otimizado

### Comparacao (Diff Engine)

Algoritmo:
1. ATTACH db_old, db_new
2. Para cada tabela, gerar hash de linha
3. OUTER JOIN detectando added/removed/changed
4. Para changed, comparacao campo a campo
5. Resultado: DataFrame com metadata de mudancas

Otimizacao: candidato para modulo Rust usando Polars/DataFusion

---

## FEATURES DETALHADAS

### 1. Busca

- Input: termo, regex, exclusoes
- Scope: campo especifico, tabela, db, multi-db
- Resultado: linha completa + highlight termo
- Performance: indices full-text (DuckDB FTS extension)

### 2. Primeira/Ultima Ocorrencia

- Query ordenada por data banco + ORDER BY LIMIT 1

### 3. Sugestao Linha Nova (ML)

- Fase 1: rule-based (defaults via schema)
- Fase 2: ML simples (sklearn DecisionTree)
- Input: campos obrigatorios preenchidos
- Output: sugestoes para campos opcionais com confidence

### 4. Filtros Cumulativos

- Stack de filtros aplicados sequencialmente
- UI: pills removiveis
- Backend: WHERE clauses concatenadas

### 5. Customizacao Colunas

- Salvar em `display_preferences/table_NAME.json`
- Campos: visible_columns[], column_order[], column_widths{}

### 6. Comparacao Visual

- Diff viewer tipo split view
- Cores: verde (added), vermelho (removed), amarelo (changed)
- Drill-down: click em linha changed mostra campos especificos

### 7. Validacao Batch Insert

- Input: CSV/JSON linhas novas
- Validacao: tipos, constraints, duplicatas, consistency cross-table
- Output: relatorio com erros/warnings

---

## CRONOGRAMA (ORIGINAL)

### Semana 1: Fundacao
- Criar estrutura diretorios
- Setup diario em temp/
- Remover convert_pyodbc.py
- Analisar MDBs (estrutura, tabelas, relacoes)
- Documentar schema inicial
- Criar db_manager (load DuckDB, metadata)

### Semana 2: Busca Basica
- search_engine.py (termo simples)
- PyQt6 main_window + search_panel
- Integrar DuckDB FTS
- Teste: busca em ultimo banco

### Semana 3: Multi-DB e Filtros
- Busca multi-db (ATTACH)
- Primeira/ultima ocorrencia
- Filtros cumulativos UI
- Column manager (show/hide)

### Semana 4: Diff Engine
- diff_engine.py Python inicial
- Comparacao 2 bancos
- diff_viewer.py UI
- Relatorio export (MD/HTML)

### Semana 5: Otimizacao
- Profile diff_engine
- Se necessario: porta para Rust/Go
- Indices otimizados
- Cache estrategico

### Semana 6: ML Prediction
- Analise padroes dados
- prediction_engine.py (rule-based)
- UI para input campos + sugestoes

### Semana 7: Validacao Batch
- Parser CSV/JSON
- Validacao engine
- Relatorio validacao

### Semana 8: Polish
- Preferences salvamento
- Menu completo
- Build Nuitka/PyInstaller
- Teste Windows/Linux/macOS
- Documentacao usuario

---

## DECISOES PENDENTES (CONFIRMADAS)

1. Stack inicial: Python+PyQt6+DuckDB com porta gradual - APROVADO
2. DuckDB vs SQLite: DuckDB - APROVADO
3. Formato conversao: DuckDB nativo - APROVADO
4. Diario: conforme progresso
5. Prioridade features: Busca -> Diff -> ML -> Batch
6. Distribuicao: Nuitka preferencial

---

## PROXIMOS PASSOS IMEDIATOS (EXECUTADOS)

1. Criar estrutura temp/ e primeiro diario - FEITO
2. Analisar novos MDBs em importacao/ - PENDENTE
3. Remover convert_pyodbc.py - PENDENTE
4. Atualizar README/ROADMAP com decisoes - PENDENTE
5. Iniciar implementacao db_manager.py - PENDENTE

---

**Conversa arquivada para referencia futura**
**Token budget tracking iniciado**
