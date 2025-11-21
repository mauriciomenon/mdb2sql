# Guia Extensivo de Conceitos em Python + PyQt6

> [!info]
> Referencia rapida e longa (cerca de 20 pgs equivalentes) cobrindo conceitos chave de Python, PyQt6 e integrações usadas no projeto MDB2SQL. Tudo em Markdown plain-Obsidian.

## Sumario
- 01. Fundamentos de Python Moderno
- 02. Ambiente, Virtualenvs e Poetry
- 03. Tipagem Estatica Pratica (mypy, pyright)
- 04. Estruturas de Dados Essenciais
- 05. Funcoes, Closures e Decorators
- 06. Orientacao a Objetos Idiomatica
- 07. Gerenciamento de Erros e Context Managers
- 08. Concurrency em Python (threads, asyncio, multiprocess)
- 09. I/O, Pathlib e Streams de Dados
- 10. Manipulacao de Dados com DuckDB e DataFrames
- 11. FFI e Integracao com Rust/Go
- 12. Logging, Observabilidade e CLI Tools
- 13. Testes Automatizados (pytest) e Fixtures
- 14. Performance: Perfis, Vetorizacao e Caches
- 15. Distribuicao: Nuitka/PyInstaller e Empacotamento
- 16. PyQt6: Ciclo de Vida da Aplicacao
- 17. PyQt6: Layouts, Widgets e Estilos
- 18. PyQt6: Signals/Slots, Threads e Tasks Longas
- 19. Arquitetura de Aplicacao e Padroes de Estado
- 20. Segurança, Configuracao e Boas Praticas de Equipe
- 21. Roteiro de Estudos e Cheatsheets Relacionados

## 01. Fundamentos de Python Moderno
- CPython 3.11+ com melhorias de velocidade e PAT (precise line numbers).
- PEP8 para estilo; black/ruff como formatadores/linters consistentes.
- Operadores modernos: walrus (`if (val := func())`), pattern matching (`match`), f-strings, comprehensions com condicionais.
- Mutabilidade: listas/dicts mutaveis; tuplas/frozenset imutaveis; usar `dataclasses` ou `pydantic` para dados estruturados.
- Imutabilidade defensiva para configs carregadas de JSON.

## 02. Ambiente, Virtualenvs e Poetry
- Separar deps via venv (`python -m venv .venv`) ou Poetry (`poetry env use python3.11`).
- Poetry.lock garante reproducao; usar grupos opcionais para build (`--with build`).
- Scripts em `[tool.poetry.scripts]` para comandos customizados.
- Variaveis de ambiente em `.env`; carregar com `python-dotenv` quando necessario sem hardcode.
- Estrutura de pastas recomendada: `src/` com pacote raiz, `tests/` paralelo.

## 03. Tipagem Estatica Pratica (mypy, pyright)
- Use type hints em funcoes publicas e contratos de camada GUI/backend.
- `typing` basico: `list[str]`, `dict[str, Any]`, `Optional[T]`, `TypedDict`.
- Protocolos para DuckDB adapters e interfaces de servico.
- mypy configs: `disallow_untyped_defs = True`, `warn_return_any = True` para manter contrato.
- Tipos literais para chaves de tabela/campos evitam erros em queries string-based.

## 04. Estruturas de Dados Essenciais
- List/dict comprehensions para filtros rapidos em memoria.
- `deque` para buffers de eventos UI; `heapq` para ranking de resultados.
- `dataclasses` para linhas de tabela exibidas; `slots=True` reduz memoria.
- `Enum` e `StrEnum` para estados de UI (Idle, Loading, Error).
- `pathlib.Path` para paths multiplataforma e seguro vs strings cruas.

## 05. Funcoes, Closures e Decorators
- Funcoes tratadas como valores; usar closures para capturar estado local controlado.
- Decorators de memoizacao (`functools.lru_cache`) em funcoes puras de leitura.
- Decorators customizados para medir tempo de queries ou registrar erros.
- Partial application (`functools.partial`) util para conectar slots com contexto.

## 06. Orientacao a Objetos Idiomatica
- Composicao > heranca: widgets especializados recebem helpers em vez de subclassar profundamente.
- `@dataclass` para DTOs; `attrs` se precisar de validacao e conversao automatica.
- Propriedades com validacao leve para estados sensiveis (db_path, table_name).
- Uso consciente de mixins em UI (ex: MixIn de shortcuts de teclado).

## 07. Gerenciamento de Erros e Context Managers
- `try/except` com excecoes especificas (`duckdb.Error`, `OSError`).
- Sempre feche conexoes: `with duckdb.connect(path) as conn:`.
- Defina excecoes de dominio (ex: `DatabaseNotFound`, `InvalidMapping`).
- Use context managers para locks de threads (`threading.Lock()` via `with lock:`).

## 08. Concurrency em Python (threads, asyncio, multiprocess)
- CPU-bound => `multiprocessing` ou extensoes (Rust/Go via FFI). I/O-bound => `threading`/`concurrent.futures`.
- `ThreadPoolExecutor` para consultas paralelas em duckdb read-only; mantenha conexoes isoladas por thread.
- Evite interagir com widgets fora da main thread; use sinais/slots ou `QMetaObject.invokeMethod`.
- Asyncio e PyQt6: integrar via `QEventLoop` ou `asyncqt` quando necessario, mas preferir QThread para simplicidade.

## 09. I/O, Pathlib e Streams de Dados
- `Path.glob('*.mdb')` para descobrir bancos rotativos; ordene por timestamp/numero.
- Leitura de JSON configs com `json.loads(Path.read_text())`; validar schema antes de usar.
- Stream de CSV para importacoes: `with open(...) as f: reader = csv.DictReader(f)`; evite carregar tudo em memoria.
- Controle de codificacao: usar UTF-8 sempre (`encoding='utf-8'`).

## 10. Manipulacao de Dados com DuckDB e DataFrames
- Conexoes read-only para UI; write isolado em pipelines offline.
- Queries parametrizadas: `conn.execute("SELECT * FROM tbl WHERE field LIKE ?", [pattern])`.
- Conector para pandas/polars: `df = conn.execute(query).df()`; use para rendering rapido.
- Views temporarias (`CREATE VIEW`) para juntar bancos rotativos sem copiar.
- Indexacao logica: criar colunas derivadas com `GENERATED` dentro de schema padrao.

## 11. FFI e Integracao com Rust/Go
- `ctypes`/`cffi` para chamar libs Rust/Go quando performance exigir.
- Defina interface C-stable (tipos primitivos, slices) e mantenha funcoes puras e reentrantes.
- Converta DataFrames para Arrow/Parquet para trafegar entre linguagens sem copiar muito.
- Cuidados: GIL continua ativo; libs nativas devem liberar GIL (`Py_BEGIN_ALLOW_THREADS`).

## 12. Logging, Observabilidade e CLI Tools
- Use `logging` com dictConfig; niveis: DEBUG para dev, INFO padrao, ERROR para excecoes.
- Append-only logs em `logs/app.log`; rotacao com `RotatingFileHandler`.
- CLI auxiliares em `scripts/` com `argparse`/`typer` para tarefas offline.
- Rastreamento de tempo: `time.perf_counter()`; decoradores de metrica.

## 13. Testes Automatizados (pytest) e Fixtures
- Estrutura: `tests/unit`, `tests/integration`; nome de arquivos `test_*.py`.
- Fixtures para conexoes DuckDB isoladas (`tmp_path` + base dummy).
- Use `pytest-qt` para testar sinais/slots e interacao basica de UI sem janela real.
- Marcar testes pesados com `@pytest.mark.slow`; coletar cobertura com `pytest --cov`.

## 14. Performance: Perfis, Vetorizacao e Caches
- Perfil rapido com `cProfile` + `snakeviz` para hotspots.
- Evite loops Python sobre muitas linhas; delegue a DuckDB/pandas.
- Cache de resultados recentes em `functools.lru_cache` ou `cachetools.TTLCache`.
- Use `py-spy` ou `perf` em prod-like; para UI travada procure funcoes longas na main thread.

## 15. Distribuicao: Nuitka/PyInstaller e Empacotamento
- Nuitka: melhor performance e obfuscacao leve; use plugin PyQt6.
- PyInstaller: mais tolerante a deps dinamicas; configure `--add-data` para arquivos config.
- Testar binarios em sandbox antes de distribuir; revisar tam. final e dependencia de libc.
- Versionamento semantico via `__version__` central.

## 16. PyQt6: Ciclo de Vida da Aplicacao
- Estrutura tipica:
  - `QApplication` criado em `main.py`.
  - Construir `MainWindow` com componentes, carregar preferencias.
  - Conectar sinais, iniciar workers, exibir janela e chamar `app.exec()`.
- Fechamento: interceptar `closeEvent` para salvar estado e fechar conexoes DuckDB.
- Icones e assets via `QResource` ou paths relativos; evitar caminhos absolutos.

## 17. PyQt6: Layouts, Widgets e Estilos
- Layouts: `QVBoxLayout`/`QHBoxLayout` para compor; `QGridLayout` para tabelas de filtros.
- Widgets principais do projeto: `QTableView` com `QAbstractTableModel`, `QLineEdit` para busca, `QComboBox` para bancos/anos.
- Estilos com QSS: aplicar no app (`app.setStyleSheet(...)`) ou por widget.
- Responsividade: usar `setSectionResizeMode(QHeaderView.Stretch)` para tabelas adaptarem.

## 18. PyQt6: Signals/Slots, Threads e Tasks Longas
- Conectar botoes a slots: `button.clicked.connect(self.on_click)`.
- QThread pattern:
```python
class Worker(QThread):
    finished = pyqtSignal(object)
    error = pyqtSignal(Exception)
    def __init__(self, query):
        super().__init__()
        self.query = query
    def run(self):
        try:
            data = run_query(self.query)
            self.finished.emit(data)
        except Exception as exc:
            self.error.emit(exc)
```
- Use `QRunnable` + `QThreadPool` para varias tasks sem muitas threads manuais.
- Nunca atualizar UI fora da thread principal; envie dados e deixe o slot aplicar no modelo.

## 19. Arquitetura de Aplicacao e Padroes de Estado
- Separar camadas: `backend/` (servicos), `ui/` (widgets), `shared/` (tipos/constantes).
- Model-View-Model (Qt) com modelos baseados em dados; evita copiar listas inteiras.
- Estado global em objeto `AppState` com referencias a configuracao, conexao atual e preferencia de UI.
- Eventos de dominio (busca concluida, diff pronto) propagados por sinais customizados.
- Guard rails: validacao de entrada antes de atingir DuckDB; mapeamentos de colunas vindos de `config/`.

## 20. Seguranca, Configuracao e Boas Praticas de Equipe
- Sanitizar entradas de busca; nunca concatenar SQL direto.
- Preferir arquivos de config somente leitura dentro de `config/`; escrever apenas em `data/` ou `~/.local/share/mdb2sql`.
- Logs nao devem conter dados sensiveis de usuarios.
- Checklists de PR: lint, testes, review de threads, review de UI freeze.
- Documentar decisoes em `docs/` ou `temp/` para replicabilidade.

## 21. Roteiro de Estudos e Cheatsheets Relacionados
- Sequencia sug. (em horas aproximadas):
  1. Revisar PEP8 + idioms (1h)
  2. PyQt6 basico: layouts, sinais (3h)
  3. DuckDB e pandas (3h)
  4. ThreadPoolExecutor + QThread (2h)
  5. Empacotar com Nuitka/PyInstaller (2h)
  6. Testes com pytest/pytest-qt (2h)
- Cheatsheets rapidas:
  - DuckDB: `ATTACH 'file.duckdb' (READ_ONLY); SHOW TABLES;`.
  - PyQt6 modelos: implementar `rowCount`, `columnCount`, `data`, `headerData`.
  - Typing: `type Alias = dict[str, str]`; usar `TypedDict` para records.

