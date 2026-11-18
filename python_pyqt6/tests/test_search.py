import sqlite3
from pathlib import Path

import duckdb
import pytest

from backend.database_tasks import load_table_payload
from backend.db_manager import DBManager, search_where

DESCRIPTIONS = ["EXCITACIÓN TENSIÓN DE CAMPO", "Excitação", "CORRENTE DE CAMPO", "it's 50% off_x"]


def test_search_where_binds_every_word_and_quotes_columns() -> None:
    where, params = search_where(['de"sc', "unit"], "tension  campo")
    assert where.count("contains(") == 4 and '"de""sc"' in where
    assert params == ["tension", "campo", "tension", "campo"]
    assert search_where(["a"], "   ") == ("", [])


@pytest.fixture(params=["duckdb", "sqlite"])
def manager(request, tmp_path: Path) -> DBManager:
    # 300 linhas: os textos procurados ficam so depois das 100 primeiras (alem do limite "Rows")
    rows = [(i, "filler", "kV") for i in range(200)] + [
        (200 + i, DESCRIPTIONS[i % 4], "Tensão nominal" if i % 4 == 1 else "kV") for i in range(100)
    ]
    if request.param == "duckdb":
        db_file = tmp_path / "s.duckdb"
        with duckdb.connect(str(db_file)) as conn:
            conn.execute("CREATE TABLE t (id INTEGER, \"desc\" VARCHAR, unit VARCHAR)")
            conn.executemany("INSERT INTO t VALUES (?, ?, ?)", rows)
    else:
        db_file = tmp_path / "s.sqlite"
        with sqlite3.connect(db_file) as conn:
            conn.execute('CREATE TABLE t (id INTEGER, "desc" TEXT, unit TEXT)')
            conn.executemany("INSERT INTO t VALUES (?, ?, ?)", rows)
        conn.close()
    with DBManager(str(db_file)) as opened:
        yield opened


def _found(manager: DBManager, query: str) -> tuple[int, set[str]]:
    payload = load_table_payload(manager, "t", limit=100, search=query)
    return payload["matched_rows"], {row["desc"] for row in payload["rows"]}


def test_search_runs_over_the_whole_table(manager: DBManager) -> None:
    # todas as palavras, qualquer ordem, mesma celula, sem caixa nem acento; so existem alem da linha 200
    assert _found(manager, "tension de campo") == (25, {"EXCITACIÓN TENSIÓN DE CAMPO"})
    assert _found(manager, "CAMPO tensión") == (25, {"EXCITACIÓN TENSIÓN DE CAMPO"})
    assert _found(manager, "tensao") == (25, {"Excitação"})  # "Tensão nominal" (coluna unit)
    assert _found(manager, "excitacao nominal") == (0, set())  # palavras em celulas diferentes nao acham
    assert _found(manager, "excitac")[0] == 50
    assert _found(manager, "50% off_x") == (25, {"it's 50% off_x"})  # % e _ sao texto, nao curinga
    assert _found(manager, "203")[0] == 1  # numeros tambem (id)
    payload = load_table_payload(manager, "t", limit=100, search="")
    assert payload["matched_rows"] == payload["total_rows"] == 300 and len(payload["rows"]) == 100


def test_search_and_value_filter_add_up(manager: DBManager) -> None:
    payload = load_table_payload(manager, "t", limit=100, filters=[("unit", "kV")], search="campo")
    assert payload["matched_rows"] == 50 and payload["total_rows"] == 300
