import os
from pathlib import Path
from typing import Any, Sequence, TypedDict

from backend.access import Progress
from backend.db_manager import MARK_KEY, DBManager, Filters


class TablePayload(TypedDict):
    table_name: str
    search: str  # pesquisa de palavras usada na consulta
    rows: list[dict[str, Any]]  # as marcadas primeiro, depois as da consulta sem repetir; MARK_KEY = identidade
    shown: int  # linhas da consulta na grade (so as marcadas: quantas marcadas)
    total_rows: int  # linhas na tabela inteira
    matched_rows: int  # linhas que passam nos filtros e na pesquisa (= total_rows sem eles)
    filters: list[tuple[str, Any]]  # filtros coluna = valor usados na consulta
    schema: list[dict[str, Any]]


def default_database_path() -> Path:
    return Path(__file__).resolve().parents[3] / "data" / "sample.duckdb"


def database_path_from_env() -> Path:
    env_path = os.getenv("MDB2SQL_DB_PATH")
    if env_path:
        return Path(env_path).expanduser()
    return default_database_path()


def open_database(
    db_path: Path, progress: Progress | None = None, work_dir: Path | None = None
) -> tuple[DBManager, list[str]]:
    # o manager fica aberto; quem chama fecha com release() (que tambem apaga o SQLite convertido do Access)
    manager = DBManager()
    manager.connect(str(db_path), progress, work_dir)
    try:
        return manager, manager.list_tables()
    except Exception:
        manager.release()
        raise


def load_table_payload(
    manager: DBManager, table_name: str, limit: int = 100, filters: Filters = (), search: str = "",
    marked: Sequence[Any] = (), only_marked: bool = False,
) -> TablePayload:
    # as marcadas (identidades `marked`) ficam sempre no topo, na ordem da tabela, qualquer que seja a pesquisa ou o
    # filtro; so_marcadas: a grade so com elas
    found = [] if only_marked else manager.query_table(table_name, limit, filters, search, keyed=True)
    on_top = manager.fetch_rows(*manager.marked_query(table_name, marked, keyed=True)) if marked else []
    keys = {row[MARK_KEY] for row in on_top}
    rows = on_top + [row for row in found if row[MARK_KEY] not in keys]
    total_rows = manager.get_row_count(table_name)
    narrowed = filters or search.split()
    matched_rows = manager.get_row_count(table_name, filters, search) if narrowed else total_rows
    schema = manager.get_table_schema(table_name)
    return {
        "table_name": table_name,
        "search": search,
        "rows": rows,
        "shown": len(on_top) if only_marked else len(found),
        "total_rows": total_rows,
        "matched_rows": matched_rows,
        "filters": list(filters),
        "schema": schema,
    }
