# Gerenciador de conexoes - abre .accdb/.mdb, .sqlite/.sqlite3/.db e .duckdb, lista tabelas, executa queries
# !T: Every format ends up in one DuckDB connection: Access converted once into a SQLite file, SQLite attached
# !T: read-only through the bundled sqlite extension (typed views on top), DuckDB file read-only. Each call uses
# !T: its own cursor (threads); close() waits for the cursors still in use

import re
import shutil
import sqlite3
import tempfile
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, List, Optional, Sequence

import duckdb

from backend.access import Progress, convert_access, quote
from shared.bundle import bundled
from shared.i18n import tr

ACCESS_EXT = {".accdb", ".mdb"}
SQLITE_EXT = {".sqlite", ".sqlite3", ".db"}
DUCKDB_EXT = {".duckdb"}
SUPPORTED_EXT = ACCESS_EXT | SQLITE_EXT | DUCKDB_EXT
SQLITE_EXTENSION = "duckdb_ext/sqlite_scanner.duckdb_extension"
# tipo declarado no SQLite que o DuckDB le como DOUBLE/BIGINT e volta ao tipo certo pela view
_DECIMAL = re.compile(r"\s*(?:DECIMAL|NUMERIC)\s*\(\s*(\d+)\s*,\s*(\d+)\s*\)\s*", re.IGNORECASE)
_BOOLEAN = re.compile(r"\s*BOOL(?:EAN)?\s*", re.IGNORECASE)


def sql_string(text: str) -> str:
    return "'" + text.replace("'", "''") + "'"


# tipos de comando do DuckDB que so leem: SELECT (tambem WITH, VALUES, FROM, TABLE, SHOW, DESCRIBE, SUMMARIZE),
# EXPLAIN, PRAGMA e MULTI (o PIVOT sem lista de valores)
READ_STATEMENTS = {"SELECT", "EXPLAIN", "PRAGMA", "MULTI"}
# coluna com a identidade da linha (linhas marcadas da aba Dados); vem nas linhas da grade, nunca na tela
MARK_KEY = "mdb2sql_mark"


def reads_only(query: str) -> bool:
    """A aba SQL so le: todo comando de query e de leitura, pelo tipo que o DuckDB da a ele (nao pelo texto).

    !T: The engine also runs the query in a read-only transaction (execute_query), which refuses what these types can
    !T: still write: EXPLAIN ANALYZE of a write, IMPORT DATABASE (a PRAGMA)
    """
    try:
        return all(statement.type.name in READ_STATEMENTS for statement in duckdb.extract_statements(query))
    except duckdb.ParserException:
        return True  # erro de sintaxe: a consulta roda e mostra o erro do motor
    except ValueError:
        return False  # tipo de comando que esta versao do duckdb nao sabe nomear (UPDATE EXTENSIONS)


Filters = Sequence[tuple[str, Any]]  # (coluna, valor) do clique direito "Filtrar por este valor"


def filter_where(filters: Filters) -> tuple[str, list[Any]]:
    """' WHERE "a" = ? AND "b" IS NULL' e os parametros; sem filtros, ('', []).

    !T: The column name is always quoted (double quotes doubled) and the value is always a bound parameter,
    !T: never text inside the SQL. The value is the Python value read from that column, so DuckDB compares it
    !T: in the column type (number, text, date) for DuckDB, SQLite and Access files alike
    """
    if not filters:
        return "", []
    parts = [f"{quote(column)} IS NULL" if value is None else f"{quote(column)} = ?" for column, value in filters]
    return " WHERE " + " AND ".join(parts), [value for _, value in filters if value is not None]


def search_where(columns: Sequence[str], query: str) -> tuple[str, list[Any]]:
    """Condicao da pesquisa na tabela inteira: uma celula tem todas as palavras, qualquer ordem, sem caixa/acento.

    !T: Runs in the database before LIMIT, so rows beyond the loaded ones are found. Each word is a bound
    !T: parameter folded by the same lower(strip_accents()) as the cell; contains() has no LIKE wildcards
    """
    words = query.split()
    if not words or not columns:
        return "", []
    word = "contains(lower(strip_accents(CAST({} AS VARCHAR))), lower(strip_accents(?)))"
    cells = ["(" + " AND ".join(word.format(quote(column)) for _ in words) + ")" for column in columns]
    return "(" + " OR ".join(cells) + ")", words * len(columns)


def where_clause(filters: Filters, columns: Sequence[str], query: str) -> tuple[str, list[Any]]:
    """Filtros coluna = valor (AND) e a pesquisa de palavras juntos num WHERE so."""
    where, params = filter_where(filters)
    search, words = search_where(columns, query)
    if not search:
        return where, params
    return (f"{where} AND {search}" if where else f" WHERE {search}"), params + words


def load_sqlite_extension(conn: duckdb.DuckDBPyConnection) -> None:
    # extensao embutida no exe (offline); fora dele, a de .tools\ ou a instalada no DuckDB do usuario
    path = bundled(SQLITE_EXTENSION)
    conn.execute(f"LOAD {sql_string(path.as_posix()) if path.is_file() else 'sqlite'}")


def column_expr(name: str, declared: str) -> str:
    """Coluna da view sobre o SQLite: DECIMAL(p,s) e BOOLEAN declarados voltam ao tipo (o DuckDB le DOUBLE/BIGINT)."""
    decimal = _DECIMAL.fullmatch(declared or "")
    if decimal:
        kind = f"DECIMAL({min(int(decimal[1]), 38)},{min(int(decimal[2]), int(decimal[1]), 38)})"
    elif _BOOLEAN.fullmatch(declared or ""):
        kind = "BOOLEAN"
    else:
        return quote(name)
    return f"CAST({quote(name)} AS {kind}) AS {quote(name)}"


def sqlite_views(path: str) -> list[tuple[str, str, str | None]]:
    """(nome, SELECT ..., SELECT com o rowid na coluna MARK_KEY ou None) de cada tabela e view do SQLite, lidas por
    source_db, com os tipos declarados. Sem rowid: view e tabela WITHOUT ROWID."""
    lite = sqlite3.connect(Path(path).as_uri() + "?mode=ro", uri=True)
    try:
        found = lite.execute(
            "SELECT name, type = 'table' AND upper(sql) NOT LIKE '%WITHOUT ROWID%' FROM sqlite_master"
            " WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite~_%' ESCAPE '~'"
        ).fetchall()
        views = []
        for name, rowid in found:
            columns = lite.execute(f"PRAGMA table_info({quote(name)})").fetchall()
            select = ", ".join(column_expr(column[1], column[2]) for column in columns) or "*"
            keyed = f"SELECT rowid AS {MARK_KEY}, {select} FROM source_db.{quote(name)}" if rowid else None
            views.append((name, f"SELECT {select} FROM source_db.{quote(name)}", keyed))
        return views
    finally:
        lite.close()


class DBManager:
    """
    Classe que gerencia acesso aos bancos (todos lidos por uma conexao DuckDB).

    Funcionalidades:
    - Conectar ao banco (DuckDB, SQLite ou Access)
    - Listar tabelas disponiveis
    - Executar queries e retornar resultados como lista de dicts
    - Fechar conexao de forma segura
    """

    def __init__(self, db_path: Optional[str] = None):
        # Inicializa manager sem conectar - db_path pode ser None
        self.conn: Optional[duckdb.DuckDBPyConnection] = None
        self.current_db: Optional[str] = None
        self.reader = ""  # caminho usado para abrir: Access ODBC, mdbtools, SQLite ou DuckDB
        self.converted: Optional[Path] = None  # SQLite convertido do Access (pasta propria, apagada em release())
        self.sqlite_file: Optional[str] = None  # o arquivo SQLite lido (o proprio .sqlite ou o convertido do Access)
        self._tables: Optional[List[str]] = None
        self._keyed: Dict[str, str] = {}  # tabela com rowid -> SELECT com ele na coluna MARK_KEY
        self._cursors: set[duckdb.DuckDBPyConnection] = set()  # em uso (outras threads); close() interrompe e espera
        self._idle = threading.Condition()

        if db_path:
            self.connect(db_path)

    def connect(self, db_path: str, progress: Optional[Progress] = None, work_dir: Optional[Path] = None) -> None:
        """
        Abre o banco especificado - fecha conexao anterior se existir.

        Args:
            db_path: Caminho para .accdb/.mdb, .sqlite/.sqlite3/.db ou .duckdb
            progress: chamado (feitas, total, tabela) durante a conversao do Access
            work_dir: onde criar a pasta do SQLite convertido do Access (padrao: pasta temporaria do sistema)
        """
        # !T: Close existing connection to avoid resource leak
        self.release()

        # Valida caminho do banco
        # !T: Prevent path traversal and validate file extension
        validated_path = self._validate_database_path(db_path)
        suffix = Path(validated_path).suffix.lower()
        if suffix == ".db":
            # .db e usado pelos dois formatos: decide pelo cabecalho do arquivo
            with open(validated_path, "rb") as handle:
                suffix = ".sqlite" if handle.read(16) == b"SQLite format 3\x00" else ".duckdb"

        # read_only / READ_ONLY: o arquivo de origem nunca e modificado
        if suffix in DUCKDB_EXT:
            self.conn = duckdb.connect(validated_path, read_only=True)
            self.reader = "DuckDB"
            tables = self.conn.execute(
                "SELECT table_name FROM information_schema.tables WHERE table_type = 'BASE TABLE'"
                " AND table_catalog = current_database() AND table_schema = current_schema()"
            ).fetchall()
            self._keyed = {name: f"SELECT rowid AS {MARK_KEY}, * FROM {quote(name)}" for (name,) in tables}
        else:
            sqlite_path = validated_path
            if suffix in ACCESS_EXT:
                # uma conversao so, para um arquivo SQLite numa pasta propria (o nome e o do Access)
                folder = Path(tempfile.mkdtemp(prefix="conv-", dir=work_dir))
                self.converted = folder / f"{Path(validated_path).stem}.sqlite"
                try:
                    self.reader = convert_access(Path(validated_path), self.converted, progress)
                except BaseException:
                    self.release()
                    raise
                sqlite_path = str(self.converted)
            else:
                self.reader = "SQLite"
            try:
                self.conn = self._open_sqlite(sqlite_path)
            except BaseException:
                self.release()
                raise
            self.sqlite_file = sqlite_path
        self.current_db = validated_path

    def _open_sqlite(self, path: str) -> duckdb.DuckDBPyConnection:
        conn = duckdb.connect(":memory:")
        try:
            load_sqlite_extension(conn)
            conn.execute(f"ATTACH {sql_string(path)} AS source_db (TYPE sqlite, READ_ONLY)")
            for name, select, keyed in sqlite_views(path):
                conn.execute(f"CREATE VIEW {quote(name)} AS {select}")
                if keyed:
                    self._keyed[name] = keyed
        except BaseException:
            conn.close()
            raise
        return conn

    def _validate_database_path(self, db_path: str) -> str:
        """
        Valida caminho do banco de dados contra path traversal.
        !T: Prevents path traversal and validates file extension.

        Raises:
            ValueError: Se extensao nao suportada
            FileNotFoundError: Se arquivo nao existe
        """
        # Converte para caminho absoluto
        abs_path = Path(db_path).resolve()

        # Valida extensao do arquivo
        if abs_path.suffix.lower() not in SUPPORTED_EXT:
            raise ValueError(tr("error.extension", suffix=abs_path.suffix or "-"))

        # Verifica se arquivo existe
        if not abs_path.exists():
            raise FileNotFoundError(tr("error.not_found", name=abs_path.name))

        return str(abs_path)

    @contextmanager
    def cursor(self) -> Iterator[duckdb.DuckDBPyConnection]:
        # !T: A DuckDB connection must not be shared between threads; a cursor is a new connection to the same db.
        # !T: Tracked so close() interrupts it and never pulls the connection from under a query in another thread
        with self._idle:
            if not self.conn:
                raise RuntimeError(tr("error.no_database"))
            cursor = self.conn.cursor()
            self._cursors.add(cursor)
        try:
            yield cursor
        finally:
            with self._idle:
                cursor.close()
                self._cursors.discard(cursor)
                self._idle.notify_all()

    def list_tables(self) -> List[str]:
        """
        Retorna lista de nomes de tabelas no banco atual.
        """
        if not self.conn:
            return []

        # lida uma vez por conexao: no SQLite anexado cada SHOW TABLES custa dezenas de ms
        if self._tables is None:
            with self.cursor() as cursor:
                self._tables = [row[0] for row in cursor.execute("SHOW TABLES").fetchall()]
        return list(self._tables)

    def _validate_table_name(self, table_name: str) -> None:
        """
        Valida se tableName existe no banco.
        !T: Prevents SQL injection by checking against known tables.
        """
        tables = self.list_tables()
        if table_name not in tables:
            raise ValueError(tr("error.table_not_found", name=table_name))

    def get_table_schema(self, table_name: str) -> List[Dict[str, Any]]:
        """
        Retorna schema de uma tabela (colunas, tipos, nullable).
        """
        if not self.conn:
            return []

        # Valida tableName contra lista de tabelas
        # !T: Prevent SQL injection by validating input
        self._validate_table_name(table_name)

        # PRAGMA table_info retorna metadata sem varrer dados
        # !T: PRAGMA returns: cid, name, type, notnull, dflt_value, pk
        with self.cursor() as cursor:
            result = cursor.execute(f"PRAGMA table_info({sql_string(table_name)})").fetchall()
        return [
            {
                "column_name": row[1],  # name
                "column_type": row[2],  # type
                "null": "NO" if row[3] == 1 else "YES",  # notnull
            }
            for row in result
        ]

    def _where(self, table_name: str, filters: Filters, search: str) -> tuple[str, list[Any]]:
        columns = [column["column_name"] for column in self.get_table_schema(table_name)] if search.split() else []
        return where_clause(filters, columns, search)

    def keyed_table(self, table_name: str) -> str:
        """SELECT da tabela com a identidade de cada linha na coluna MARK_KEY (linhas marcadas): o rowid do motor
        quando a tabela tem um (tabela DuckDB; tabela SQLite, tambem a do Access convertido); numa view ou tabela
        SQLite WITHOUT ROWID, o texto da linha inteira (linhas iguais tem a mesma identidade e marcam juntas)."""
        self._validate_table_name(table_name)
        return self._keyed.get(table_name) or f"SELECT CAST(q AS VARCHAR) AS {MARK_KEY}, q.* FROM {quote(table_name)} q"

    def select_table(
        self, table_name: str, filters: Filters = (), search: str = "", keyed: bool = False
    ) -> tuple[str, list[Any]]:
        """SELECT da tabela inteira com os filtros e a pesquisa (o que a grade mostra) e os parametros; keyed: com a
        identidade da linha na coluna MARK_KEY."""
        self._validate_table_name(table_name)
        where, params = self._where(table_name, filters, search)
        source = f"({self.keyed_table(table_name)}) t" if keyed else quote(table_name)
        return f"SELECT * FROM {source}{where}", params

    def marked_query(self, table_name: str, keys: Sequence[Any], keyed: bool = False) -> tuple[str, list[Any]]:
        """SELECT das linhas marcadas (identidades `keys`), na ordem da tabela; sem keyed, so as colunas da tabela."""
        columns = "*" if keyed else f"* EXCLUDE ({MARK_KEY})"
        return (f"SELECT {columns} FROM ({self.keyed_table(table_name)}) t WHERE {MARK_KEY} IN (SELECT unnest(?))",
                [list(keys)])

    def fetch_rows(self, query: str, params: Sequence[Any] = (), limit: Optional[int] = None) -> List[Dict[str, Any]]:
        """Linhas (dicts por coluna) de uma consulta do proprio app, ate limit."""
        # !T: Plain Python values, not pandas: DECIMAL(10,0) stays 1 (pandas would show 1.0) and NULL stays None
        with self.cursor() as cursor:
            cursor.execute(query if limit is None else f"{query} LIMIT {int(limit)}", list(params))
            columns = [column[0] for column in cursor.description]
            return [dict(zip(columns, row)) for row in cursor.fetchall()]

    def query_table(
        self, table_name: str, limit: int = 100, filters: Filters = (), search: str = "", keyed: bool = False
    ) -> List[Dict[str, Any]]:
        """
        Executa SELECT na tabela e retorna ate limit linhas (so as que passam nos filtros e na pesquisa).
        """
        if not self.conn:
            return []

        # SELECT com LIMIT para nao carregar tabela inteira
        select, params = self.select_table(table_name, filters, search, keyed)
        return self.fetch_rows(select, params, limit)

    def table_columns(self) -> Dict[str, List[str]]:
        """Colunas de cada tabela, na ordem, numa consulta so (PRAGMA por tabela: ~2.5 s nas 287 do DB4)."""
        with self.cursor() as cursor:
            columns = cursor.execute(
                "SELECT table_name, column_name FROM information_schema.columns WHERE table_catalog = current_database()"
                " AND table_schema = current_schema() ORDER BY ordinal_position"
            ).fetchall()
        by_table: Dict[str, List[str]] = {}
        for table, column in columns:
            by_table.setdefault(table, []).append(column)
        return by_table

    def execute_query(self, query: str, limit: int = 1000) -> tuple[List[str], List[Dict[str, Any]], bool]:
        """
        Executa SQL livre, so de leitura; devolve (colunas, ate limit linhas, ha mais linhas).

        Comando que nao e de leitura e recusado antes de rodar (PermissionError): o banco, a copia convertida e a
        memoria nunca mudam.
        """
        if not self.conn:
            return [], [], False
        if not reads_only(query):
            raise PermissionError(tr("error.sql_read_only"))

        with self.cursor() as cursor:
            # !T: The cursor is closed after the query, which rolls this transaction back (temporary objects too)
            cursor.execute("BEGIN TRANSACTION READ ONLY")
            try:
                cursor.execute(query)
            except duckdb.TransactionException as exc:  # o motor recusou uma escrita
                raise PermissionError(tr("error.sql_read_only")) from exc
            if cursor.description is None:  # comando sem resultado (SET, CREATE ...)
                return [], [], False
            columns: list[str] = []
            for name in (column[0] for column in cursor.description):
                # nomes repetidos (SELECT a, a) viram a, a_2: as linhas sao dicts por nome
                unique, n = name, 2
                while unique in columns:
                    unique, n = f"{name}_{n}", n + 1
                columns.append(unique)
            rows = cursor.fetchmany(limit + 1)
        return columns, [dict(zip(columns, row)) for row in rows[:limit]], len(rows) > limit

    def search_tables(self, search: str, stop: Callable[[], bool] = lambda: False) -> List[tuple[str, int]]:
        """(tabela, linhas encontradas) de cada tabela com a pesquisa; so as que tem alguma.

        !T: Exactly the table search rule (search_where over every column as text: every word in one cell, no case or
        !T: accents), so the count listed is the count the opened table shows. `stop` is checked between tables so
        !T: a newer search ends this one
        """
        by_table = self.table_columns()
        found = []
        for table in self.list_tables():
            if stop():
                break
            where, params = search_where(by_table.get(table, []), search)
            if not where:  # pesquisa vazia: nenhuma tabela entra
                continue
            with self.cursor() as cursor:
                count = cursor.execute(f"SELECT COUNT(*) FROM {quote(table)} WHERE {where}", params).fetchone()[0]
            if count:
                found.append((table, count))
        return found

    def table_counts(self) -> Dict[str, Optional[int]]:
        """Linhas de cada tabela (lista de tabelas com a contagem, igual nas 4 versoes); None se nao deu para contar.

        !T: A SQLite file (also the one converted from Access) is counted by sqlite3 straight from the file: through
        !T: the attached DuckDB views the 287 tables of DB4 took 5.9 s, sqlite3 0.3 s. DuckDB files count in one
        !T: UNION ALL query (0.16 s); a table that fails is counted alone and becomes None
        """
        tables = self.list_tables()
        if self.sqlite_file is not None:
            lite = sqlite3.connect(Path(self.sqlite_file).as_uri() + "?mode=ro", uri=True)
            try:
                return {table: self._count_or_none(lambda t=table: lite.execute(f"SELECT COUNT(*) FROM {quote(t)}"))
                        for table in tables}
            finally:
                lite.close()
        with self.cursor() as cursor:
            try:
                union = " UNION ALL ".join(f"SELECT {i}, COUNT(*) FROM {quote(t)}" for i, t in enumerate(tables))
                counts = dict(cursor.execute(union).fetchall()) if tables else {}
                return {table: counts.get(i) for i, table in enumerate(tables)}
            except duckdb.Error:
                return {table: self._count_or_none(lambda t=table: cursor.execute(f"SELECT COUNT(*) FROM {quote(t)}"))
                        for table in tables}

    @staticmethod
    def _count_or_none(run: Callable[[], Any]) -> Optional[int]:
        try:
            return run().fetchone()[0]
        except (sqlite3.Error, duckdb.Error):
            return None

    def get_row_count(self, table_name: str, filters: Filters = (), search: str = "") -> int:
        """
        Retorna numero total de linhas em uma tabela (com filtros/pesquisa: so as que passam neles).
        """
        if not self.conn:
            return 0

        self._validate_table_name(table_name)

        where, params = self._where(table_name, filters, search)
        with self.cursor() as cursor:
            result = cursor.execute(f"SELECT COUNT(*) FROM {quote(table_name)}{where}", params).fetchone()
        return result[0] if result else 0

    def close(self) -> None:
        """
        Fecha conexao com o banco - sempre chame ao finalizar uso.
        """
        with self._idle:
            # consultas de outras threads (tabela, contagem, busca global, SQL) sao interrompidas, nao esperadas ate o
            # fim: quem fecha ja descarta o resultado delas (uma contagem longa travava a tela ~1,5 s)
            # !T: Repeated: an interrupt that lands between two queries of a worker would be lost
            while self._cursors:
                for cursor in self._cursors:
                    cursor.interrupt()
                self._idle.wait(0.05)
            if self.conn:
                # !T: Explicitly close connection to release file handle
                self.conn.close()
            self.conn = None
        self.current_db = None
        self.reader = ""
        self.sqlite_file = None
        self._tables = None
        self._keyed = {}

    def release(self) -> None:
        """Fecha; o SQLite convertido do Access e apagado (com a pasta dele)."""
        self.close()
        converted, self.converted = self.converted, None
        if converted is not None:
            shutil.rmtree(converted.parent, ignore_errors=True)

    def __enter__(self):
        # Suporte a context manager (with statement)
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        # Fecha conexao automaticamente ao sair do with (e apaga o SQLite convertido)
        # !T: Context manager is the reliable way to manage resources
        self.release()
