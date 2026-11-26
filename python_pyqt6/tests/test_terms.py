import sqlite3
from pathlib import Path

import duckdb
import openpyxl
import pytest

from backend.db_manager import MARK_KEY, DBManager
from backend.export import csv_name, export_csv_folder, export_sheets
from backend.terms import not_found, parse_terms, report_sheets, search_terms, table_hits


def _noop(*_args) -> None:
    pass


@pytest.fixture(params=[".duckdb", ".sqlite"])
def points(request, tmp_path: Path):
    # a mesma tabela em DuckDB e em SQLite (o Access convertido tambem e lido como SQLite)
    rows = [(50, 238, "U9A", " GENERADOR CGS "), (50, 242, "U9A", "turbina cgi"), (51, 7, "U18A", "Generador cgs x"),
            (52, 8, "u9a", None)]
    path = tmp_path / f"points{request.param}"
    if request.param == ".duckdb":
        with duckdb.connect(str(path)) as conn:
            conn.execute("CREATE TABLE pts (RTUNO INTEGER, PNTNO INTEGER, SUBNAM VARCHAR, PNTNAM VARCHAR)")
            conn.executemany("INSERT INTO pts VALUES (?, ?, ?, ?)", rows)
            conn.execute("CREATE TABLE other (txt VARCHAR)")
            conn.execute("INSERT INTO other VALUES ('turbina CGI'), ('nada')")
    else:
        with sqlite3.connect(path) as conn:
            conn.execute("CREATE TABLE pts (RTUNO INTEGER, PNTNO INTEGER, SUBNAM TEXT, PNTNAM TEXT)")
            conn.executemany("INSERT INTO pts VALUES (?, ?, ?, ?)", rows)
            conn.execute("CREATE TABLE other (txt TEXT)")
            conn.executemany("INSERT INTO other VALUES (?)", [("turbina CGI",), ("nada",)])
        conn.close()
    with DBManager(str(path)) as manager:
        yield manager


def test_parse_terms_trims_skips_empty_and_counts_repeated() -> None:
    # a 1a linha colada do Excel (cabecalho) e um termo como os outros; repetidos sem diferenciar maiusculas
    text = "PNTNAM\r\n  generador cgs  \n\n\tU9A\nGENERADOR CGS\nu9a \n"
    assert parse_terms(text) == (["PNTNAM", "generador cgs", "U9A"], 2)
    assert parse_terms(" \n\n") == ([], 0)


def test_whole_value_ignores_case_and_spaces_and_keeps_the_list_order(points: DBManager) -> None:
    terms = ["u9a", "nothing", "generador cgs", "238"]
    result = search_terms(points, terms, False, points.list_tables(), _noop)
    # numeros como texto; espacos nas pontas da celula e maiusculas nao contam
    assert result["hits"] == [("pts", {0: 3, 2: 1, 3: 1})]
    rows = points.fetch_rows(*table_hits(result, "pts"))
    assert [(r["Term"], r["PNTNO"]) for r in rows] == [("u9a", 238), ("u9a", 242), ("u9a", 8),
                                                        ("generador cgs", 238), ("238", 238)]
    assert list(rows[0]) == ["Term", "RTUNO", "PNTNO", "SUBNAM", "PNTNAM"]
    assert not_found(result) == ["nothing"]


def test_contains_finds_part_of_the_cell_in_every_table(points: DBManager) -> None:
    result = search_terms(points, ["CGI", "generador"], True, points.list_tables(), _noop)
    assert result["hits"] == [("other", {0: 1}), ("pts", {0: 1, 1: 2})]
    assert [r["PNTNO"] for r in points.fetch_rows(*table_hits(result, "pts"))] == [242, 238, 7]


def test_columns_named_like_our_own_do_not_clash_and_a_late_cancel_cancels(tmp_path: Path) -> None:
    import threading

    from backend.export import Cancelled

    path = tmp_path / "odd.duckdb"
    with duckdb.connect(str(path)) as conn:
        conn.execute("CREATE TABLE t (IDX INTEGER, TERM VARCHAR, mdb2sql_q VARCHAR, q VARCHAR)")
        conn.execute("INSERT INTO t VALUES (1, 'abc', 'x', 'same'), (2, 'zabcz', 'y', 'same')")
        conn.execute("CREATE VIEW v AS SELECT * FROM t")
    with DBManager(str(path)) as manager:
        for contains, rows in ((False, 1), (True, 2)):
            result = search_terms(manager, ["ABC"], contains, ["t"], _noop)
            assert result["hits"] == [("t", {0: rows})]
            assert [r["IDX"] for r in manager.fetch_rows(*table_hits(result, "t"))] == [1, 2][:rows]
        # a view com uma coluna q: a identidade e a linha inteira, nao a coluna q
        keys = [r[MARK_KEY] for r in manager.fetch_rows(*manager.select_table("v", keyed=True))]
        assert keys[0] != keys[1]
        # Cancelar durante a ultima (ou unica) tabela: nada de resultado
        cancel = threading.Event()
        with pytest.raises(Cancelled):
            search_terms(manager, ["abc"], False, ["t"], lambda *_a: cancel.set(), cancel)


def test_report_in_every_format(points: DBManager, tmp_path: Path) -> None:
    result = search_terms(points, ["U9A", "zzz", "turbina cgi"], False, points.list_tables(), _noop)
    sheets = report_sheets(result)
    assert [name for name, _query, _params in sheets] == ["Summary", "other", "pts", "Not found"]
    summary = points.fetch_rows(sheets[0][1], sheets[0][2])
    assert [tuple(r.values()) for r in summary] == [
        ("U9A", "Found", "pts", 3), ("zzz", "Not found", None, 0),
        ("turbina cgi", "Found", "other", 1), ("turbina cgi", "Found", "pts", 1)]
    assert list(summary[0]) == ["Term", "Status", "Table", "Rows"]

    assert export_sheets(points, sheets, tmp_path / "r.xlsx", _noop) == 4
    book = openpyxl.load_workbook(tmp_path / "r.xlsx", read_only=True)
    assert book.sheetnames == ["Summary", "other", "pts", "Not found"]
    assert list(book["Not found"].iter_rows(values_only=True)) == [("Term",), ("zzz",)]
    book.close()
    for suffix in (".sqlite", ".duckdb"):
        export_sheets(points, sheets, tmp_path / f"r{suffix}", _noop)
        with DBManager(str(tmp_path / f"r{suffix}")) as saved:
            assert saved.list_tables() == ["Not found", "Summary", "other", "pts"]
            assert saved.get_row_count("pts") == 4
    folder = tmp_path / "csv"
    folder.mkdir()
    assert export_csv_folder(points, sheets, folder, _noop) == 4
    assert sorted(p.name for p in folder.iterdir()) == ["Not found.csv", "Summary.csv", "other.csv", "pts.csv"]
    assert (folder / "pts.csv").read_text(encoding="utf-8-sig").splitlines()[1] == "U9A,50,238,U9A, GENERADOR CGS "


def test_csv_name_replaces_what_windows_refuses() -> None:
    assert csv_name('a/b:c*d?"e<f>|g') == "a_b_c_d__e_f__g.csv"
    assert csv_name("Não encontrados") == "Não encontrados.csv"


def test_row_identity_is_the_rowid_or_the_whole_row(tmp_path: Path) -> None:
    # tabela: rowid do motor (DuckDB e SQLite); view e tabela SQLite WITHOUT ROWID: o texto da linha inteira
    lite = tmp_path / "k.sqlite"
    with sqlite3.connect(lite) as conn:
        conn.execute("CREATE TABLE t (a INTEGER, b TEXT)")
        conn.executemany("INSERT INTO t VALUES (?, ?)", [(1, "x"), (2, "y"), (1, "x")])
        conn.execute("DELETE FROM t WHERE a = 2")
        conn.execute("INSERT INTO t VALUES (3, 'z')")
        conn.execute("CREATE TABLE w (k TEXT PRIMARY KEY, v INT) WITHOUT ROWID")
        conn.execute("INSERT INTO w VALUES ('k1', 1)")
        conn.execute("CREATE VIEW v AS SELECT * FROM t")
    conn.close()
    with DBManager(str(lite)) as manager:
        rows = manager.fetch_rows(*manager.select_table("t", keyed=True))
        assert [r[MARK_KEY] for r in rows] == [1, 3, 4]  # o rowid do SQLite (a linha 2 foi apagada)
        assert [r[MARK_KEY] for r in manager.fetch_rows(*manager.select_table("w", keyed=True))] == ["{'k': k1, 'v': 1}"]
        view = [r[MARK_KEY] for r in manager.fetch_rows(*manager.select_table("v", keyed=True))]
        assert view[0] == view[1] != view[2]  # linhas iguais tem a mesma identidade
        # marcadas: na ordem da tabela, so as colunas da tabela
        assert manager.fetch_rows(*manager.marked_query("t", [4, 1])) == [{"a": 1, "b": "x"}, {"a": 3, "b": "z"}]
        assert len(manager.fetch_rows(*manager.marked_query("v", [view[0]]))) == 2
    duck = tmp_path / "k.duckdb"
    with duckdb.connect(str(duck)) as conn:
        conn.execute("CREATE TABLE t AS SELECT * FROM (VALUES (1, 'x'), (2, 'y')) v(a, b)")
        # revisao P1: tabela grande (varios grupos de linhas, varredura paralela) e uma view sobre ela
        conn.execute("CREATE TABLE big AS SELECT i AS id FROM range(1000000) r(i)")
        conn.execute("CREATE VIEW big_v AS SELECT id, id % 7 AS m FROM big")
    with DBManager(str(duck)) as manager:
        assert [r[MARK_KEY] for r in manager.fetch_rows(*manager.select_table("t", keyed=True))] == [0, 1]
        marked = [999_000, 500_123, 10, 250_000, 750_000, 130_000]
        assert [r["id"] for r in manager.fetch_rows(*manager.marked_query("big", marked))] == sorted(marked)
        keys = [r[MARK_KEY] for r in manager.fetch_rows(f"SELECT * FROM ({manager.keyed_table('big_v')}) t"
                                                         " WHERE id IN (999000, 10, 600000)")]
        assert [r["id"] for r in manager.fetch_rows(*manager.marked_query("big_v", keys))] == [10, 600_000, 999_000]
