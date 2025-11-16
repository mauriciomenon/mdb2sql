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

        # NIVEL BASICO: DESCRIBE retorna info das colunas
        # NIVEL TECNICO: Returns column metadata (name, type, nullable)
        result = self.conn.execute(
            f'DESCRIBE SELECT * FROM "{table_name}"'
        ).fetchall()

        # NIVEL BASICO: Converte tuplas em lista de dicts
        return [
            {
                "column_name": row[0],
                "column_type": row[1],
                "null": row[2],
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

        # NIVEL BASICO: SELECT com LIMIT para nao carregar tabela inteira
        # NIVEL TECNICO: Parameterized table name via quotes to prevent SQL injection
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

        # NIVEL BASICO: COUNT(*) retorna total de linhas
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

    def __del__(self):
        # NIVEL BASICO: Destrutor garante que conexao seja fechada
        # NIVEL TECNICO: Cleanup on garbage collection
        self.close()

    def __enter__(self):
        # NIVEL BASICO: Suporte a context manager (with statement)
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        # NIVEL BASICO: Fecha conexao automaticamente ao sair do with
        self.close()
