# Gerenciador de conexoes DuckDB - abre .duckdb/.db, .sqlite/.sqlite3 e .mdb/.accdb, lista tabelas, executa queries
# !T: Every format ends up in one DuckDB connection: DuckDB file read-only, SQLite attached read-only through the
# !T: bundled sqlite extension, Access copied into an in-memory database. Each call uses its own cursor (threads)

from pathlib import Path
from typing import Any, Dict, List, Optional

import duckdb

from backend.access import Progress, load_access, quote
from shared.bundle import bundled

DUCKDB_EXT = {".duckdb", ".db"}
SQLITE_EXT = {".sqlite", ".sqlite3"}
ACCESS_EXT = {".mdb", ".accdb"}
SUPPORTED_EXT = DUCKDB_EXT | SQLITE_EXT | ACCESS_EXT
SQLITE_EXTENSION = "duckdb_ext/sqlite_scanner.duckdb_extension"


def sql_string(text: str) -> str:
    return "'" + text.replace("'", "''") + "'"


def load_sqlite_extension(conn: duckdb.DuckDBPyConnection) -> None:
    # extensao embutida no exe (offline); fora dele, a de .tools\ ou a instalada no DuckDB do usuario
    path = bundled(SQLITE_EXTENSION)
    conn.execute(f"LOAD {sql_string(path.as_posix()) if path.is_file() else 'sqlite'}")


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
        self.reader = ""  # caminho usado para abrir: DuckDB, SQLite, Access ODBC ou mdbtools
        self._catalog: Optional[str] = None  # banco anexado (SQLite) que cada cursor usa
        self._tables: Optional[List[str]] = None

        if db_path:
            self.connect(db_path)

    def connect(self, db_path: str, progress: Optional[Progress] = None) -> None:
        """
        Abre o banco especificado - fecha conexao anterior se existir.

        Args:
            db_path: Caminho para .duckdb/.db, .sqlite/.sqlite3 ou .mdb/.accdb
            progress: chamado (feitas, total, tabela) durante a conversao do Access
        """
        # !T: Close existing connection to avoid resource leak
        self.close()

        # Valida caminho do banco
        # !T: Prevent path traversal and validate file extension
        validated_path = self._validate_database_path(db_path)
        suffix = Path(validated_path).suffix.lower()
        if suffix == ".db":
            # .db e usado pelos dois formatos: decide pelo cabecalho do arquivo
            with open(validated_path, "rb") as handle:
                if handle.read(16) == b"SQLite format 3\x00":
                    suffix = ".sqlite"

        # read_only / READ_ONLY: o arquivo de origem nunca e modificado
        if suffix in DUCKDB_EXT:
            conn = duckdb.connect(validated_path, read_only=True)
            self.reader = "DuckDB"
        else:
            conn = duckdb.connect(":memory:")
            try:
                if suffix in SQLITE_EXT:
                    load_sqlite_extension(conn)
                    conn.execute(f"ATTACH {sql_string(validated_path)} AS source_db (TYPE sqlite, READ_ONLY)")
                    self._catalog = "source_db"
                    self.reader = "SQLite"
                else:
                    self.reader = load_access(Path(validated_path), conn, progress)
            except Exception:
                conn.close()
                raise
        self.conn = conn
        self.current_db = validated_path

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
            raise ValueError(
                f"Only {', '.join(sorted(SUPPORTED_EXT))} files are supported, got: {abs_path.suffix}"
            )

        # Verifica se arquivo existe
        if not abs_path.exists():
            raise FileNotFoundError(f"Database not found: {abs_path}")

        return str(abs_path)

    def cursor(self) -> duckdb.DuckDBPyConnection:
        # !T: A DuckDB connection must not be shared between threads; a cursor is a new connection to the same db
        if not self.conn:
            raise RuntimeError("No database open")
        cursor = self.conn.cursor()
        if self._catalog:
            cursor.execute(f"USE {self._catalog}")
        return cursor

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
            raise ValueError(f"Table not found: {table_name}")

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

    def query_table(self, table_name: str, limit: int = 100) -> List[Dict[str, Any]]:
        """
        Executa SELECT na tabela e retorna ate limit linhas.
        """
        if not self.conn:
            return []

        self._validate_table_name(table_name)

        # SELECT com LIMIT para nao carregar tabela inteira
        # !T: to_dict('records') returns list of row dicts
        with self.cursor() as cursor:
            result = cursor.execute(f"SELECT * FROM {quote(table_name)} LIMIT {int(limit)}").df()
        return result.to_dict("records")

    def execute_query(self, query: str, limit: int = 1000) -> tuple[List[str], List[Dict[str, Any]], bool]:
        """
        Executa SQL livre; devolve (colunas, ate limit linhas, ha mais linhas).
        """
        if not self.conn:
            return [], [], False

        with self.cursor() as cursor:
            cursor.execute(query)
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

    def get_row_count(self, table_name: str) -> int:
        """
        Retorna numero total de linhas em uma tabela.
        """
        if not self.conn:
            return 0

        self._validate_table_name(table_name)

        with self.cursor() as cursor:
            result = cursor.execute(f"SELECT COUNT(*) FROM {quote(table_name)}").fetchone()
        return result[0] if result else 0

    def close(self) -> None:
        """
        Fecha conexao com o banco - sempre chame ao finalizar uso.
        """
        if self.conn:
            # !T: Explicitly close connection to release file handle
            self.conn.close()
        self.conn = None
        self.current_db = None
        self.reader = ""
        self._catalog = None
        self._tables = None

    def __enter__(self):
        # Suporte a context manager (with statement)
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        # Fecha conexao automaticamente ao sair do with
        # !T: Context manager is the reliable way to manage resources
        self.close()
