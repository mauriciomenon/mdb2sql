import threading
from pathlib import Path

import duckdb
import openpyxl
import pytest

from backend import export
from backend.db_manager import DBManager
from backend.export import Cancelled, default_save_dir, export_database, export_result, sheet_name


def _noop(*_args) -> None:
    pass


def test_sheet_name_rules() -> None:
    used = {"history"}
    long_name = "RANGER_SOSTAT_WITH_A_VERY_LONG_TABLE_NAME"

    assert sheet_name("a/b:c*d?e[f]g\\h", 1, used) == "a_b_c_d_e_f_g_h"
    assert sheet_name(long_name, 1, used) == long_name[:31]
    assert sheet_name(long_name, 2, used) == long_name[:27] + " (2)"
    # mesmo nome depois de cortar (ou so com maiusculas diferentes): ganha ~2, ~3 sem passar de 31
    assert sheet_name(long_name.lower(), 1, used) == long_name.lower()[:29] + "~2"
    assert sheet_name(long_name, 1, used) == long_name[:29] + "~3"
    assert sheet_name("History", 1, used) == "History~2"
    assert sheet_name("'quoted'", 1, used) == "quoted"
    assert all(len(name) <= 31 for name in used)


def test_default_save_dir(tmp_path: Path) -> None:
    source = tmp_path / "db" / "base.accdb"
    source.parent.mkdir()
    last = tmp_path / "last"
    last.mkdir()

    assert default_save_dir(source, str(last)) == source.parent
    assert default_save_dir(None, str(last)) == last
    assert default_save_dir(None, str(tmp_path / "gone")) == Path.home()
    assert default_save_dir(None, None) == Path.home()


@pytest.fixture
def manager(people_db: Path):
    with DBManager(str(people_db)) as opened:
        yield opened


@pytest.mark.parametrize("suffix", [".duckdb", ".sqlite"])
def test_export_database_keeps_tables_and_rows(manager: DBManager, tmp_path: Path, suffix: str) -> None:
    out = tmp_path / f"copy{suffix}"
    steps = []

    assert export_database(manager, out, lambda *a: steps.append(a)) == 2
    assert steps[-1] == (2, 2, "")
    with DBManager(str(out)) as copy:
        assert copy.list_tables() == ["empty_table", "people"]
        assert copy.get_row_count("people") == 3
        assert copy.execute_query("SELECT name, score FROM people ORDER BY id")[1][2] == {
            "name": "carla",
            "score": 7.25,
        }
    # o ATTACH da exportacao nao fica preso ao banco aberto
    with manager.cursor() as cursor:
        assert "export_db" not in {row[0] for row in cursor.execute("SHOW DATABASES").fetchall()}


def test_export_database_xlsx_one_sheet_per_table_and_split(
    manager: DBManager, tmp_path: Path, monkeypatch
) -> None:
    monkeypatch.setattr(export, "MAX_SHEET_ROWS", 2)  # 3 linhas de people viram 2 abas
    out = tmp_path / "all.xlsx"

    export_database(manager, out, _noop)

    book = openpyxl.load_workbook(out, read_only=True)
    assert book.sheetnames == ["empty_table", "people", "people (2)"]
    rows = {name: list(book[name].iter_rows(values_only=True)) for name in book.sheetnames}
    assert rows["empty_table"] == [("code", "label")]
    assert rows["people"] == [("id", "name", "score"), (1, "Ana", 9.5), (2, "Bruno", None)]
    assert rows["people (2)"] == [("id", "name", "score"), (10, "carla", 7.25)]
    book.close()


def test_export_result_csv_utf8_bom(manager: DBManager, tmp_path: Path) -> None:
    out = tmp_path / "people.csv"

    assert export_result(manager, "SELECT id, name FROM people ORDER BY id", "people", out, _noop) == 3
    data = out.read_bytes()
    assert data.startswith(b"\xef\xbb\xbf")
    assert data.decode("utf-8-sig").splitlines() == ["id,name", "1,Ana", "2,Bruno", "10,carla"]


def test_export_result_xlsx_keeps_text_that_looks_like_formula(tmp_path: Path) -> None:
    db_file = tmp_path / "f.duckdb"
    with duckdb.connect(str(db_file)) as conn:
        conn.execute(
            "CREATE TABLE t AS SELECT '=1+1' AS formula, 'http://x' AS url, TIMESTAMP '2026-07-14 01:02:03' AS ts, "
            "'\\x00\\x01'::BLOB AS bin, TIMESTAMP '1800-01-02 03:04:05' AS old, 1.5::DECIMAL(10,2) AS dec"
        )
    with DBManager(str(db_file)) as manager:
        export_result(manager, "SELECT * FROM t", "t", tmp_path / "t.xlsx", _noop)
        export_result(manager, "SELECT bin FROM t", "t", tmp_path / "t.csv", _noop)
    sheet = openpyxl.load_workbook(tmp_path / "t.xlsx")["t"]
    assert [c.value for c in sheet[2]][:2] == ["=1+1", "http://x"]
    assert sheet["A2"].data_type == "s"
    assert str(sheet["C2"].value) == "2026-07-14 01:02:03"
    # binario em hex e data que o Excel nao representa como texto, em vez de erro ou numero negativo
    assert [c.value for c in sheet[2]][3:] == ["0001", "1800-01-02 03:04:05", 1.5]
    assert (tmp_path / "t.csv").read_text(encoding="utf-8-sig").splitlines() == ["bin", "0001"]


def test_cancel_removes_partial_file(manager: DBManager, tmp_path: Path) -> None:
    cancel = threading.Event()
    cancel.set()
    for out in (tmp_path / "c.duckdb", tmp_path / "c.xlsx"):
        with pytest.raises(Cancelled):
            export_database(manager, out, _noop, cancel)
        assert not out.exists()
    with pytest.raises(Cancelled):
        export_result(manager, "SELECT * FROM people", "people", tmp_path / "c.csv", _noop, cancel)
    assert not (tmp_path / "c.csv").exists()


OLD = b"previous export, must survive"


def _previous(path: Path) -> Path:
    path.write_bytes(OLD)
    return path


def test_failed_or_cancelled_export_keeps_previous_file(manager: DBManager, tmp_path: Path) -> None:
    # auditoria externa item 1: erro ou cancelamento nao pode apagar o arquivo que ja existia com esse nome
    cancel = threading.Event()
    cancel.set()
    for suffix in (".duckdb", ".sqlite", ".xlsx"):
        out = _previous(tmp_path / f"db{suffix}")
        with pytest.raises(Cancelled):
            export_database(manager, out, _noop, cancel)
        assert out.read_bytes() == OLD
    for suffix in (".csv", ".xlsx"):
        out = _previous(tmp_path / f"r{suffix}")
        with pytest.raises(Cancelled):
            export_result(manager, "SELECT * FROM people", "people", out, _noop, cancel)
        assert out.read_bytes() == OLD
        with pytest.raises(duckdb.Error):
            export_result(manager, "SELECT * FROM missing_table", "x", out, _noop)
        assert out.read_bytes() == OLD
    # nenhum temporario sobra; o sucesso troca o arquivo antigo pelo novo
    assert [p.name for p in tmp_path.iterdir() if "partial" in p.name or p.suffix == ".wal"] == []
    export_result(manager, "SELECT * FROM people", "people", tmp_path / "r.csv", _noop)
    assert (tmp_path / "r.csv").read_text(encoding="utf-8-sig").startswith("id,name,score")


def test_cancel_during_last_table_or_chunk_is_a_cancel(manager: DBManager, tmp_path: Path) -> None:
    # auditoria externa item 9: Cancelar durante a ultima tabela terminava como sucesso
    for suffix in (".duckdb", ".sqlite", ".xlsx"):
        cancel = threading.Event()
        out = _previous(tmp_path / f"last{suffix}")

        def on_last_table(_done, _total, table, cancel=cancel) -> None:
            if table == "people":  # ultima tabela (empty_table, people)
                cancel.set()

        with pytest.raises(Cancelled):
            export_database(manager, out, on_last_table, cancel)
        assert out.read_bytes() == OLD
    for suffix in (".csv", ".xlsx"):
        cancel = threading.Event()
        out = _previous(tmp_path / f"last_r{suffix}")
        with pytest.raises(Cancelled):  # cancelado depois do ultimo bloco de linhas
            export_result(manager, "SELECT * FROM people", "people", out, lambda *_a, c=cancel: c.set(), cancel)
        assert out.read_bytes() == OLD


def test_export_refuses_to_overwrite_open_database(manager: DBManager) -> None:
    with pytest.raises(ValueError, match="is the open database"):
        export_database(manager, Path(manager.current_db), _noop)
    assert Path(manager.current_db).exists()
