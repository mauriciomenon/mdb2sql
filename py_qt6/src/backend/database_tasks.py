import os
from pathlib import Path
from typing import Any, TypedDict

from backend.db_manager import DBManager


class TablePayload(TypedDict):
    table_name: str
    rows: list[dict[str, Any]]
    total_rows: int


def default_database_path() -> Path:
    return Path(__file__).resolve().parents[3] / "data" / "sample.duckdb"


def database_path_from_env() -> Path:
    env_path = os.getenv("MDB2SQL_DB_PATH")
    if env_path:
        return Path(env_path).expanduser()
    return default_database_path()


def list_tables(db_path: Path) -> tuple[Path, list[str]]:
    with DBManager(str(db_path)) as manager:
        return db_path, manager.list_tables()


def load_table_payload(db_path: Path, table_name: str) -> TablePayload:
    with DBManager(str(db_path)) as manager:
        rows = manager.query_table(table_name, limit=100)
        total_rows = manager.get_row_count(table_name)

    return {"table_name": table_name, "rows": rows, "total_rows": total_rows}
