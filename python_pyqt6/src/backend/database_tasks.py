import os
from pathlib import Path
from typing import Any, TypedDict

from backend.access import Progress
from backend.db_manager import DBManager, Filters


class TablePayload(TypedDict):
    table_name: str
    rows: list[dict[str, Any]]
    total_rows: int  # linhas na tabela inteira
    matched_rows: int  # linhas que passam nos filtros (= total_rows sem filtros)
    schema: list[dict[str, Any]]


def default_database_path() -> Path:
    return Path(__file__).resolve().parents[3] / "data" / "sample.duckdb"


def database_path_from_env() -> Path:
    env_path = os.getenv("MDB2SQL_DB_PATH")
    if env_path:
        return Path(env_path).expanduser()
    return default_database_path()


def open_database(db_path: Path, progress: Progress | None = None) -> tuple[DBManager, list[str]]:
    # o manager fica aberto (o Access vive so na memoria dele); quem chama fecha com close()
    manager = DBManager()
    manager.connect(str(db_path), progress)
    try:
        return manager, manager.list_tables()
    except Exception:
        manager.close()
        raise


def load_table_payload(manager: DBManager, table_name: str, limit: int = 100, filters: Filters = ()) -> TablePayload:
    rows = manager.query_table(table_name, limit=limit, filters=filters)
    total_rows = manager.get_row_count(table_name)
    matched_rows = manager.get_row_count(table_name, filters) if filters else total_rows
    schema = manager.get_table_schema(table_name)
    return {
        "table_name": table_name,
        "rows": rows,
        "total_rows": total_rows,
        "matched_rows": matched_rows,
        "schema": schema,
    }
