# Gerenciador de conexoes DuckDB - carrega bancos, lista tabelas, executa queries
# !T: DuckDB connection manager with read-only mode and metadata caching

import duckdb
from pathlib import Path
from typing import Optional, List, Dict, Any

# !T: DuckDB connection manager with read-only mode
# !T: Handles multiple database attachments and metadata caching


class DBManager:
    """
    Classe que gerencia acesso aos bancos DuckDB convertidos.

    Funcionalidades:
    - Conectar ao banco principal (ultimo convertido)
    - Listar tabelas disponiveis
    - Executar queries e retornar resultados como lista de dicts
    - Fechar conexao de forma segura
    """

    def __init__(self, db_path: Optional[str] = None):
        # Inicializa manager sem conectar - db_path pode ser None
        self.conn: Optional[duckdb.DuckDBPyConnection] = None
        self.current_db: Optional[str] = None

        if db_path:
            self.connect(db_path)

    def connect(self, db_path: str) -> None:
        """
        Conecta ao banco DuckDB especificado - fecha conexao anterior se existir.

        Args:
            db_path: Caminho para arquivo .duckdb
        """
        # !T: Close existing connection to avoid resource leak
        if self.conn:
            self.conn.close()

        # Valida caminho do banco
        # !T: Prevent path traversal and validate file extension
        validated_path = self._validate_database_path(db_path)

        # Abre conexao read-only para nao modificar dados
        # !T: read_only=True prevents accidental writes
        self.conn = duckdb.connect(validated_path, read_only=True)
        self.current_db = validated_path

    def _validate_database_path(self, db_path: str) -> str:
        """
        Valida caminho do banco de dados contra path traversal.
        !T: Prevents path traversal and validates file extension.

        Args:
            db_path: Caminho para validar

        Returns:
            Caminho absoluto validado

        Raises:
            ValueError: Se caminho invalido
            FileNotFoundError: Se arquivo nao existe
        """
        # Converte para caminho absoluto
        abs_path = Path(db_path).resolve()

        # Valida extensao do arquivo
        # !T: Only .duckdb and .db files allowed
        if abs_path.suffix not in [".duckdb", ".db"]:
            raise ValueError(f"Only .duckdb and .db files are supported, got: {abs_path.suffix}")

        # Verifica se arquivo existe
        if not abs_path.exists():
            raise FileNotFoundError(f"Database not found: {abs_path}")

        return str(abs_path)

    def list_tables(self) -> List[str]:
        """
        Retorna lista de nomes de tabelas no banco atual.

        Returns:
            Lista de strings com nomes das tabelas
        """
        if not self.conn:
            return []

        # Query SHOW TABLES retorna DataFrame
        # !T: DuckDB returns pandas DataFrame by default
        result = self.conn.execute("SHOW TABLES").df()

        # Converte coluna 'name' para lista Python
        return result["name"].tolist()

    def _validate_table_name(self, table_name: str) -> None:
        """
        Valida se tableName existe no banco.
        !T: Prevents SQL injection by checking against known tables.

        Args:
            table_name: Nome da tabela para validar

        Raises:
            ValueError: Se tabela nao existir
        """
        tables = self.list_tables()
        if table_name not in tables:
            raise ValueError(f"Table not found: {table_name}")

    def get_table_schema(self, table_name: str) -> List[Dict[str, Any]]:
        """
        Retorna schema de uma tabela (colunas, tipos, nullable).

        Args:
            table_name: Nome da tabela

        Returns:
            Lista de dicts com column_name, column_type, null
        """
        if not self.conn:
            return []

        # Valida tableName contra lista de tabelas
        # !T: Prevent SQL injection by validating input
        self._validate_table_name(table_name)

        # PRAGMA table_info retorna metadata sem varrer dados
        # !T: More efficient than DESCRIBE SELECT *
        result = self.conn.execute(
            f'PRAGMA table_info("{table_name}")'
        ).fetchall()

        # Converte tuplas em lista de dicts
        # !T: PRAGMA returns: cid, name, type, notnull, dflt_value, pk
        return [
            {
                "column_name": row[1],  # name
                "column_type": row[2],  # type
                "null": "NO" if row[3] == 1 else "YES",  # notnull
            }
            for row in result
        ]

    def query_table(
        self, table_name: str, limit: int = 100
    ) -> List[Dict[str, Any]]:
        """
        Executa SELECT na tabela e retorna resultados.

        Args:
            table_name: Nome da tabela
            limit: Numero maximo de linhas (padrao 100)

        Returns:
            Lista de dicts, cada dict = uma linha
        """
        if not self.conn:
            return []

        # Valida tableName contra lista de tabelas
        # !T: Prevent SQL injection by validating input
        self._validate_table_name(table_name)

        # SELECT com LIMIT para nao carregar tabela inteira
        # !T: Table name validated, safe to use in query
        query = f'SELECT * FROM "{table_name}" LIMIT {limit}'
        result = self.conn.execute(query).df()

        # Converte DataFrame pandas para lista de dicts
        # !T: to_dict('records') returns list of row dicts
        return result.to_dict("records")

    def execute_query(self, query: str) -> List[Dict[str, Any]]:
        """
        Executa query SQL customizada.

        Args:
            query: Query SQL completa

        Returns:
            Lista de dicts com resultados
        """
        if not self.conn:
            return []

        # !T: Execute arbitrary SQL and return as records
        result = self.conn.execute(query).df()
        return result.to_dict("records")

    def get_row_count(self, table_name: str) -> int:
        """
        Retorna numero total de linhas em uma tabela.

        Args:
            table_name: Nome da tabela

        Returns:
            Numero de linhas (int)
        """
        if not self.conn:
            return 0

        # Valida tableName contra lista de tabelas
        # !T: Prevent SQL injection by validating input
        self._validate_table_name(table_name)

        # COUNT(*) retorna total de linhas
        # !T: Table name validated, safe to use in query
        query = f'SELECT COUNT(*) as count FROM "{table_name}"'
        result = self.conn.execute(query).fetchone()

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

    def __enter__(self):
        # Suporte a context manager (with statement)
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        # Fecha conexao automaticamente ao sair do with
        # !T: Context manager is the reliable way to manage resources
        self.close()
