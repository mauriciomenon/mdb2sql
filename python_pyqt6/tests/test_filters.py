# Filtro "coluna = valor" do clique direito: SQL montado com nome citado e valor por parametro, nos tres motores
import datetime
import os
import shutil
import sqlite3
from decimal import Decimal
from pathlib import Path

import duckdb
import pytest

from backend import access
from backend.database_tasks import load_table_payload
from backend.db_manager import DBManager, filter_where

QUOTES = """O'Brien "B4" ''"""
INJECTION = "' OR 1=1 --"
# coluna com espaco e com aspas no nome: so funciona se o nome for citado e as aspas dobradas
CREATE = 'CREATE TABLE pts (sigla {text}, "rtu no" INTEGER, "o""bs" {text})'
ROWS = [("U9A", 9, None), ("U18A", 18, "x"), (QUOTES, 9, "x"), (INJECTION, 1, None), ("9", 2, "")]


def test_filter_where_quotes_names_and_binds_values() -> None:
    assert filter_where([]) == ("", [])
    where, params = filter_where([("a", 1), ('b"c', None), ("d", INJECTION)])

    assert where == ' WHERE "a" = ? AND "b""c" IS NULL AND "d" = ?'
    assert params == [1, INJECTION]  # o valor nunca entra no texto do SQL; NULL nao vira parametro
    assert INJECTION not in where


@pytest.fixture(params=["duckdb", "sqlite"])
def manager(request, tmp_path: Path):
    if request.param == "duckdb":
        path = tmp_path / "pts.duckdb"
        with duckdb.connect(str(path)) as conn:
            conn.execute(CREATE.format(text="VARCHAR"))
            conn.executemany("INSERT INTO pts VALUES (?, ?, ?)", ROWS)
    else:
        path = tmp_path / "pts.sqlite"
        conn = sqlite3.connect(path)
        conn.execute(CREATE.format(text="TEXT"))
        conn.executemany("INSERT INTO pts VALUES (?, ?, ?)", ROWS)
        conn.commit()
        conn.close()
    with DBManager(str(path)) as opened:
        yield opened


def _siglas(manager: DBManager, *filters) -> list[str]:
    rows = manager.query_table("pts", 100, filters)
    assert manager.get_row_count("pts", filters) == len(rows)
    return sorted(row["sigla"] for row in rows)


def test_text_integer_and_null(manager: DBManager) -> None:
    assert _siglas(manager, ("sigla", "U9A")) == ["U9A"]
    assert _siglas(manager, ("rtu no", 9)) == sorted([QUOTES, "U9A"])  # inteiro comparado como inteiro
    assert _siglas(manager, ("sigla", "9")) == ["9"]  # texto "9" nao e o inteiro 9
    assert _siglas(manager, ('o"bs', None)) == sorted([INJECTION, "U9A"])  # IS NULL; a string vazia nao entra
    assert _siglas(manager, ('o"bs', "")) == ["9"]


def test_value_with_quotes_is_data_not_sql(manager: DBManager) -> None:
    assert _siglas(manager, ("sigla", QUOTES)) == [QUOTES]
    assert _siglas(manager, ("sigla", INJECTION)) == [INJECTION]  # nao vira "OR 1=1": uma linha so
    assert manager.get_row_count("pts") == len(ROWS)


def test_filters_add_up_and_keep_the_limit(manager: DBManager) -> None:
    assert _siglas(manager, ("rtu no", 9), ('o"bs', None)) == ["U9A"]
    assert _siglas(manager, ("rtu no", 9), ("sigla", "U18A")) == []

    payload = load_table_payload(manager, "pts", limit=1, filters=[("rtu no", 9)])
    assert (len(payload["rows"]), payload["matched_rows"], payload["total_rows"]) == (1, 2, 5)
    assert load_table_payload(manager, "pts")["matched_rows"] == 5


def test_unknown_column_is_an_error_not_a_string(manager: DBManager) -> None:
    with pytest.raises(duckdb.Error):
        manager.query_table("pts", 100, [("nope", 1)])


def _round_trip(manager: DBManager, table: str) -> None:
    # filtrar pelo valor lido de cada celula da primeira linha tem de trazer essa linha de volta
    row = manager.query_table(table, 1)[0]
    for column, value in row.items():
        if isinstance(value, float) and value != value:
            continue  # NaN
        found = manager.query_table(table, 10_000, [(column, value)])
        assert row in found, (column, value)
        assert manager.get_row_count(table, [(column, value)]) >= 1


def test_access_types_compare_in_the_column_type() -> None:
    # caminho do Access: as tabelas vivem num DuckDB em memoria com os tipos mapeados por backend.access
    manager = DBManager()
    manager.conn = duckdb.connect(":memory:")
    columns = [("RTUNO", "DECIMAL(10,0)"), ("SUBNAM", "VARCHAR"), ("VALUE", "DOUBLE"), ("WHEN", "TIMESTAMP"),
               ("FLAG", "BOOLEAN"), ("ID", "INTEGER"), ("COST", "DECIMAL(19,4)"), ("NOTE", "VARCHAR")]
    access._create(manager.conn, "SOSTAT", columns)
    when = datetime.datetime(2026, 7, 14, 8, 30, 0)
    manager.conn.executemany(
        'INSERT INTO "SOSTAT" VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
            (9, "U9A", 0.1, when, True, 1, Decimal("12.3400"), None),
            (18, "U18A", 2.5, when, False, 2, Decimal("1"), "x"),
        ],
    )
    with manager:
        _round_trip(manager, "SOSTAT")
        assert [r["SUBNAM"] for r in manager.query_table("SOSTAT", 10, [("RTUNO", Decimal(9))])] == ["U9A"]
        assert [r["SUBNAM"] for r in manager.query_table("SOSTAT", 10, [("WHEN", when), ("FLAG", False)])] == ["U18A"]
        assert [r["SUBNAM"] for r in manager.query_table("SOSTAT", 10, [("NOTE", None)])] == ["U9A"]


def test_round_trip_duckdb_and_sqlite(manager: DBManager) -> None:
    _round_trip(manager, "pts")


REAL_ACCDB = os.environ.get("MDB2SQL_TEST_ACCDB")


@pytest.mark.skipif(not REAL_ACCDB, reason="MDB2SQL_TEST_ACCDB nao definido")
@pytest.mark.parametrize("reader", ["odbc", "mdbtools"])
def test_real_access_filter_round_trip(monkeypatch, tmp_path, reader: str) -> None:
    copy = tmp_path / "copy.accdb"
    shutil.copy2(REAL_ACCDB, copy)
    monkeypatch.setenv("MDB2SQL_ACCESS_READER", reader)
    with DBManager(str(copy)) as manager:
        tables = [t for t in manager.list_tables() if manager.get_row_count(t)]
        for table in tables[:5]:
            _round_trip(manager, table)
