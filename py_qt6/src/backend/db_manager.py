# NIVEL BASICO: Gerenciador de conexoes DuckDB
# Responsavel por carregar bancos, listar tabelas, executar queries

import duckdb
from pathlib import Path
from typing import Optional, List, Dict, Any

# NIVEL TECNICO: DuckDB connection manager with read-only mode
# Handles multiple database attachments and metadata caching


class DBManager:
    """
    NIVEL BASICO: Classe que gerencia acesso aos bancos DuckDB convertidos.

    Funcionalidades:
    - Conectar ao banco principal (ultimo convertido)
    - Listar tabelas disponiveis
    - Executar queries e retornar resultados como lista de dicts
    - Fechar conexao de forma segura
    """

    def __init__(self, db_path: Optional[str] = None):
        # NIVEL BASICO: Inicializa manager sem conectar
        # db_path pode ser None (conecta ao ultimo banco depois)
        self.conn: Optional[duckdb.DuckDBPyConnection] = None
        self.current_db: Optional[str] = None

        if db_path:
            self.connect(db_path)

    def connect(self, db_path: str) -> None:
        """
        NIVEL BASICO: Conecta ao banco DuckDB especificado.
        Se ja existe conexao aberta, fecha antes.

        Args:
            db_path: Caminho para arquivo .duckdb
        """
        # NIVEL TECNICO: Close existing connection to avoid resource leak
        if self.conn:
            self.conn.close()

        # NIVEL BASICO: Verifica se arquivo existe
        if not Path(db_path).exists():
            raise FileNotFoundError(f"Database not found: {db_path}")

        # NIVEL BASICO: Abre conexao read-only (nao modifica dados)
        # NIVEL TECNICO: read_only=True prevents accidental writes
        self.conn = duckdb.connect(db_path, read_only=True)
        self.current_db = db_path

    def list_tables(self) -> List[str]:
        """
        NIVEL BASICO: Retorna lista de nomes de tabelas no banco atual.

        Returns:
            Lista de strings com nomes das tabelas
        """
        if not self.conn:
            return []

        # NIVEL BASICO: Query SHOW TABLES retorna DataFrame
        # NIVEL TECNICO: DuckDB returns pandas DataFrame by default
        result = self.conn.execute("SHOW TABLES").df()

        # NIVEL BASICO: Converte coluna 'name' para lista Python
        return result["name"].tolist()

    def _validate_table_name(self, table_name: str) -> None:
        """
        NIVEL BASICO: Valida se tableName existe no banco.
        NIVEL TECNICO: Prevents SQL injection by checking against known tables.

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
        NIVEL BASICO: Retorna schema (colunas e tipos) de uma tabela.

        Args:
            table_name: Nome da tabela

        Returns:
            Lista de dicts com column_name, column_type, null
        """
        if not self.conn:
            return []

        # NIVEL BASICO: Valida tableName contra lista de tabelas
        # NIVEL TECNICO: Prevent SQL injection by validating input
        self._validate_table_name(table_name)

        # NIVEL BASICO: PRAGMA table_info retorna metadata sem varrer dados
        # NIVEL TECNICO: More efficient than DESCRIBE SELECT *
        result = self.conn.execute(
            f'PRAGMA table_info("{table_name}")'
        ).fetchall()

        # NIVEL BASICO: Converte tuplas em lista de dicts
        # NIVEL TECNICO: PRAGMA returns: cid, name, type, notnull, dflt_value, pk
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
        NIVEL BASICO: Executa SELECT na tabela e retorna resultados.

        Args:
            table_name: Nome da tabela
            limit: Numero maximo de linhas (padrao 100)

        Returns:
            Lista de dicts, cada dict = uma linha
        """
        if not self.conn:
            return []

        # NIVEL BASICO: Valida tableName contra lista de tabelas
        # NIVEL TECNICO: Prevent SQL injection by validating input
        self._validate_table_name(table_name)

        # NIVEL BASICO: SELECT com LIMIT para nao carregar tabela inteira
        # NIVEL TECNICO: Table name validated, safe to use in query
        query = f'SELECT * FROM "{table_name}" LIMIT {limit}'
        result = self.conn.execute(query).df()

        # NIVEL BASICO: Converte DataFrame pandas para lista de dicts
        # NIVEL TECNICO: to_dict('records') returns list of row dicts
        return result.to_dict("records")

    def execute_query(self, query: str) -> List[Dict[str, Any]]:
        """
        NIVEL BASICO: Executa query SQL customizada.

        Args:
            query: Query SQL completa

        Returns:
            Lista de dicts com resultados
        """
        if not self.conn:
            return []

        # NIVEL TECNICO: Execute arbitrary SQL and return as records
        result = self.conn.execute(query).df()
        return result.to_dict("records")

    def get_row_count(self, table_name: str) -> int:
        """
        NIVEL BASICO: Retorna numero total de linhas em uma tabela.

        Args:
            table_name: Nome da tabela

        Returns:
            Numero de linhas (int)
        """
        if not self.conn:
            return 0

        # NIVEL BASICO: Valida tableName contra lista de tabelas
        # NIVEL TECNICO: Prevent SQL injection by validating input
        self._validate_table_name(table_name)

        # NIVEL BASICO: COUNT(*) retorna total de linhas
        # NIVEL TECNICO: Table name validated, safe to use in query
        query = f'SELECT COUNT(*) as count FROM "{table_name}"'
        result = self.conn.execute(query).fetchone()

        return result[0] if result else 0

    def close(self) -> None:
        """
        NIVEL BASICO: Fecha conexao com o banco.
        Sempre chame este metodo ao finalizar uso.
        """
        if self.conn:
            # NIVEL TECNICO: Explicitly close connection to release file handle
            self.conn.close()
            self.conn = None
            self.current_db = None

    def __enter__(self):
        # NIVEL BASICO: Suporte a context manager (with statement)
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        # NIVEL BASICO: Fecha conexao automaticamente ao sair do with
        # NIVEL TECNICO: Context manager is the reliable way to manage resources
        self.close()
