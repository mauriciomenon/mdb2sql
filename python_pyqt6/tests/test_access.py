import os
import shutil
import sqlite3
import subprocess
import sys
from datetime import datetime
from decimal import Decimal
from pathlib import Path

import pytest

from backend import access
from backend.db_manager import DBManager, column_expr
from backend.temp_store import NAME, open_session, remove_stale, temp_folders

SCHEMA = """-- That file uses encoding ISO-8859-1

CREATE TABLE [RANGER_SOSTAT]
 (
\t[RTUNO]\t\t\tNumeric (10, 0),
\t[SUBNAM]\t\t\tText (8),
\t[VALUE]\t\t\tDouble,
\t[WHEN]\t\t\tDateTime,
\t[NOTE]\t\t\tMemo/Hyperlink,
\t[FLAG]\t\t\tBoolean,
\t[ID]\t\t\tLong Integer,
\t[SMALL]\t\t\tInteger,
\t[PIC]\t\t\tOLE
);

CREATE TABLE [OTHER]
 (
\t[A]\t\t\tCurrency
);
"""


def test_csv_rows_null_binary_and_dates_mdbtools_cannot_convert(tmp_path: Path) -> None:
    # 1900-01-00: o mdbtools 1.0.1 do Linux para datas fora de ~1900-9999 (o do Windows ja manda vazio = NULL)
    csv_path = tmp_path / "t.csv"
    csv_path.write_bytes(  # bytes: a quebra de linha do campo fica LF (write_text poria CRLF no Windows)
        (
            f'id,when,bin,note\n1,"2021-12-02 00:00:00","00FF","a, ""b"""\n'
            f'2,"1900-01-00 00:00:00",{access.NULL},"line 1\nline 2"\n3,{access.NULL},"",""\n'
        ).encode("utf-8")
    )
    assert list(access._csv_rows(csv_path, [2], [1])) == [
        ["1", "2021-12-02 00:00:00", b"\x00\xff", 'a, "b"'],
        ["2", None, None, "line 1\nline 2"],
        ["3", None, b"", ""],
    ]


def test_mdb_schema_tables_maps_access_types() -> None:
    tables = access.mdb_schema_tables(SCHEMA)

    assert list(tables) == ["RANGER_SOSTAT", "OTHER"]
    assert tables["RANGER_SOSTAT"] == [
        ("RTUNO", "DECIMAL(10,0)"),
        ("SUBNAM", "TEXT"),
        ("VALUE", "DOUBLE"),
        ("WHEN", "DATETIME"),
        ("NOTE", "TEXT"),
        ("FLAG", "BOOLEAN"),
        ("ID", "INTEGER"),
        ("SMALL", "SMALLINT"),
        ("PIC", "BLOB"),
    ]
    assert tables["OTHER"] == [("A", "DECIMAL(19,4)")]


def test_odbc_types() -> None:
    assert access._odbc_type("DECIMAL", 10, 0) == "DECIMAL(10,0)"
    assert access._odbc_type("COUNTER", 10, 0) == "INTEGER"
    assert access._odbc_type("LONGCHAR", 1073741823, None) == "TEXT"
    assert access._odbc_type("NUMERIC", 60, 2) == "DECIMAL(38,2)"


@pytest.mark.parametrize(
    ("forced", "odbc", "mdbtools", "expected"),
    [
        ("", True, True, "odbc"),
        ("", False, True, "mdbtools"),
        ("mdbtools", True, True, "mdbtools"),
        ("ODBC", False, True, "odbc"),  # forcado: o erro de driver ausente aparece ao abrir
    ],
)
def test_access_reader_order(monkeypatch, tmp_path, forced, odbc, mdbtools, expected) -> None:
    monkeypatch.setenv("MDB2SQL_ACCESS_READER", forced)
    monkeypatch.setattr(access, "odbc_available", lambda: odbc)
    monkeypatch.setattr(access, "mdbtools_dir", lambda: tmp_path if mdbtools else None)

    assert access.access_reader() == expected


def test_access_reader_none_available(monkeypatch) -> None:
    monkeypatch.setattr(access, "odbc_available", lambda: False)
    monkeypatch.setattr(access, "mdbtools_dir", lambda: None)
    with pytest.raises(RuntimeError, match="No Access reader"):
        access.access_reader()
    monkeypatch.setenv("MDB2SQL_ACCESS_READER", "jet")
    with pytest.raises(ValueError):
        access.access_reader()


@pytest.mark.skipif(os.name != "nt", reason="copia por versao so no exe do Windows; o Linux usa a pasta do pacote")
def test_frozen_mdbtools_copied_to_one_cache_per_version(monkeypatch, tmp_path) -> None:
    bundle = tmp_path / "bundle"
    bundle.mkdir()
    for exe in access.MDBTOOLS:
        (bundle / exe).write_bytes(b"exe")
    local = tmp_path / "local"
    old = local / "mdb2sql" / "python-pyqt6-0.9.0"
    other_stack = local / "mdb2sql" / "go-wails-react-1.1.0"
    old.mkdir(parents=True)
    other_stack.mkdir()
    monkeypatch.setattr(access, "FROZEN", True)
    monkeypatch.setattr(access, "bundled", lambda name: bundle)
    monkeypatch.setenv("LOCALAPPDATA", str(local))

    tools = access.mdbtools_dir()

    assert tools.parent.name.startswith("python-pyqt6-") and tools.parent.name != old.name
    assert sorted(p.name for p in tools.iterdir()) == sorted(access.MDBTOOLS)
    assert not old.exists() and other_stack.exists()  # so as versoes velhas deste app


@pytest.mark.parametrize("name", ["people.sqlite", "people.db"])  # .db com conteudo SQLite tambem
def test_sqlite_opens_read_only(tmp_path: Path, name: str) -> None:
    db_file = tmp_path / name
    with sqlite3.connect(db_file) as conn:
        conn.execute("CREATE TABLE people (id INTEGER, name TEXT)")
        conn.execute("INSERT INTO people VALUES (1, 'Ana'), (2, 'Bruno')")
    conn.close()

    with DBManager(str(db_file)) as manager:
        assert manager.reader == "SQLite"
        assert manager.list_tables() == ["people"]
        assert manager.get_row_count("people") == 2
        with pytest.raises(Exception):
            manager.execute_query("INSERT INTO people VALUES (3, 'x')")


def test_sqlite_declared_decimal_and_boolean_keep_their_type(tmp_path: Path) -> None:
    # o DuckDB le DECIMAL(p,s) como DOUBLE e BOOLEAN como BIGINT: a view devolve o tipo declarado
    db_file = tmp_path / "typed.sqlite"
    with sqlite3.connect(db_file) as conn:
        conn.execute('CREATE TABLE t ("price" DECIMAL(19,4), "rtuno" NUMERIC(10, 0), "ok" BOOLEAN, "x" REAL)')
        conn.execute("INSERT INTO t VALUES (12.5, 50, 1, 2316.0), (NULL, NULL, 0, NULL)")
    conn.close()
    assert column_expr("ok", "boolean") == 'CAST("ok" AS BOOLEAN) AS "ok"'
    assert column_expr("x", "REAL") == '"x"'

    with DBManager(str(db_file)) as manager:
        assert manager.query_table("t") == [
            {"price": Decimal("12.5000"), "rtuno": Decimal("50"), "ok": True, "x": 2316.0},
            {"price": None, "rtuno": None, "ok": False, "x": None},
        ]


SAMPLE = Path(__file__).with_name("data") / "sample.mdb"  # gerado por tests/data/make_sample_mdb.py
SAMPLE_ROWS = [
    (1, "U9A", "EXCITACIÓN TENSIÓN DE CAMPO", 2316.0, Decimal("18.0000"), 7, 200, True,
     datetime(2026, 7, 14, 10, 11, 12), b"\x00\x01\xff", "a"),
    (2, "U18A", 'linha 1\nlinha 2, "aspas"', 1.5, Decimal("12.3456"), -3, 0, False,
     datetime(1999, 12, 31, 23, 59, 59), None, None),
    (3, None, None, None, None, None, None, False, None, b"", None),  # binario vazio nao e NULL
    (4, None, "ação ñandú", -0.001, Decimal("-1.0000"), 32767, 255, True, datetime(2000, 2, 29), b"\x10", "x y"),
]
READERS = [
    pytest.param("mdbtools", marks=pytest.mark.skipif(access.mdbtools_dir() is None, reason="sem .tools/mdbtools")),
    pytest.param("odbc", marks=pytest.mark.skipif(not access.odbc_available(), reason="sem driver ODBC do Access")),
]


def _all_rows(manager: DBManager, table: str) -> list[tuple]:
    with manager.cursor() as cursor:
        return cursor.execute(f"SELECT * FROM {access.quote(table)} ORDER BY ALL").fetchall()


@pytest.mark.parametrize("reader", READERS)
def test_sample_mdb_converts_once_to_a_typed_sqlite_file(monkeypatch, tmp_path: Path, reader: str) -> None:
    monkeypatch.setenv("MDB2SQL_ACCESS_READER", reader)
    copy = tmp_path / "sample.mdb"
    shutil.copy2(SAMPLE, copy)
    manager = DBManager()
    manager.connect(str(copy), work_dir=tmp_path)

    assert manager.reader == access.READERS[reader]
    assert manager.current_db == str(copy) and manager.converted.name == "sample.sqlite"
    assert manager.list_tables() == ["empty table", "points"]
    assert manager.get_row_count("empty table") == 0
    rows = SAMPLE_ROWS
    if reader == "odbc":  # limite do mdb-export: texto vazio ("") sai como NULL; o ODBC mantem ""
        rows = [*rows[:2], (3, "", *rows[2][2:10], ""), rows[3]]
    assert _all_rows(manager, "points") == rows
    # o arquivo convertido guarda os tipos declarados (outros programas tambem os veem)
    lite = sqlite3.connect(manager.converted)
    declared = {row[1]: row[2] for row in lite.execute('PRAGMA table_info("points")')}
    stored = lite.execute("SELECT typeof(id), typeof(preco), typeof(ativo), typeof(quando), typeof(bin) FROM points"
                          " WHERE id = 2").fetchone()
    lite.close()
    assert declared["preco"] == "DECIMAL(19,4)" and declared["ativo"] == "BOOLEAN"
    assert declared["quando"] == "DATETIME" and declared["bin"] == "BLOB" and declared["id"] == "INTEGER"
    assert stored == ("integer", "real", "integer", "text", "null")  # 12.3456 em REAL; NULL continua NULL

    folder = manager.converted.parent
    manager.release()  # Apagar: a pasta do SQLite convertido some
    assert not folder.exists() and copy.exists()


def test_saving_an_access_file_as_sqlite_copies_the_converted_file(monkeypatch, tmp_path: Path) -> None:
    from backend.export import export_database

    if access.mdbtools_dir() is None:
        pytest.skip("sem .tools/mdbtools")
    monkeypatch.setenv("MDB2SQL_ACCESS_READER", "mdbtools")
    manager = DBManager()
    manager.connect(str(SAMPLE), work_dir=tmp_path)
    target = tmp_path / "out" / "sample.sqlite"
    target.parent.mkdir()
    target.write_bytes(b"old")  # o dialogo de salvar ja confirmou a troca
    converted = manager.converted

    assert export_database(manager, target, lambda *_a: None) == 2
    assert target.read_bytes() == converted.read_bytes()  # a copia, com os tipos declarados
    with pytest.raises(ValueError, match="open database"):  # o temporario nunca e o destino
        export_database(manager, converted, lambda *_a: None)
    manager.release()
    assert not converted.parent.exists() and manager.converted is None
    with DBManager(str(target)) as saved:  # o salvo abre como SQLite comum, com os mesmos dados
        assert saved.reader == "SQLite" and _all_rows(saved, "points") == SAMPLE_ROWS


def test_failed_conversion_leaves_no_temporary_file(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setattr(access, "access_reader", lambda: "mdbtools")
    monkeypatch.setattr(access, "_load_mdbtools", lambda *_a: (_ for _ in ()).throw(RuntimeError("broken")))
    with pytest.raises(RuntimeError, match="broken"):
        DBManager().connect(str(SAMPLE), work_dir=tmp_path)
    assert list(tmp_path.iterdir()) == []


def test_stale_sessions_are_removed_and_their_converted_files_counted(tmp_path: Path) -> None:
    base = tmp_path / NAME
    alive = open_session([tmp_path])  # outra janela aberta: fica
    # sessao de um processo que caiu: trava gravada, processo morto sem soltar (2 conversoes ficaram)
    crashed = (
        "import os, sys; from pathlib import Path; from PyQt6.QtCore import QLockFile;"
        "base = Path(sys.argv[1]); (base / 'dead' / 'conv-1').mkdir(parents=True);"
        "(base / 'dead' / 'conv-1' / 'x.sqlite').write_bytes(b'x'); (base / 'dead' / 'y.sqlite').write_bytes(b'y');"
        "lock = QLockFile(str(base / 'dead.lock')); assert lock.tryLock(0); os._exit(0)"
    )
    subprocess.run([sys.executable, "-c", crashed, str(base)], check=True)
    assert (base / "dead.lock").exists()

    assert remove_stale(tmp_path) == 2  # os arquivos convertidos, como a linha do Log conta
    assert not (base / "dead").exists() and alive.path.is_dir()
    assert remove_stale(tmp_path) == 0 and remove_stale(tmp_path / "no such folder") == 0
    alive.close()
    assert list(tmp_path.iterdir()) == []  # sem sessao, a pasta do app tambem sai


def test_session_goes_to_the_first_folder_where_a_file_can_be_created(tmp_path: Path) -> None:
    # pasta temporaria do usuario, senao a do sistema, por ultimo a do arquivo aberto
    blocked = tmp_path / "user temp"
    blocked.write_text("a file: no folder can be created inside it", encoding="utf-8")
    session = open_session([blocked, tmp_path / "system temp", tmp_path / "source"])
    assert session.path.parent == tmp_path / "system temp" / NAME and session.path.is_dir()
    session.close()
    assert not (tmp_path / "system temp" / NAME).exists() and not (tmp_path / "source").exists()
    assert open_session([blocked]) is None
    folders = temp_folders()
    assert len(folders) == len(set(folders)) >= 1 and all(folder.is_absolute() for folder in folders)


# Bancos Access reais (copias): MDB2SQL_TEST_ACCDB=<copia.accdb> e, opcional, MDB2SQL_TEST_REFERENCE=<referencia.sqlite>
# (conversao do mesmo .accdb por outro programa). Sem elas o teste e pulado (.accdb nao vai no git)
REAL_ACCDB = os.environ.get("MDB2SQL_TEST_ACCDB")
REFERENCE = os.environ.get("MDB2SQL_TEST_REFERENCE")


@pytest.mark.skipif(not REAL_ACCDB, reason="MDB2SQL_TEST_ACCDB nao definido")
def test_real_access_counts_match_reference_and_readers_agree(monkeypatch, tmp_path) -> None:
    copy = tmp_path / "copy.accdb"
    shutil.copy2(REAL_ACCDB, copy)
    results = {}
    readers = ["mdbtools"] + (["odbc"] if access.odbc_available() else [])
    for reader in readers:
        monkeypatch.setenv("MDB2SQL_ACCESS_READER", reader)
        with DBManager() as manager:
            manager.connect(str(copy), work_dir=tmp_path)
            tables = manager.list_tables()
            counts = {t: manager.get_row_count(t) for t in tables}
            results[reader] = (counts, [_all_rows(manager, t) for t in tables])
    if REFERENCE:
        ref = sqlite3.connect(Path(REFERENCE).resolve().as_uri() + "?mode=ro", uri=True)
        names = [r[0] for r in ref.execute("SELECT name FROM sqlite_master WHERE type = 'table'")]
        expected = {t: ref.execute(f"SELECT COUNT(*) FROM {access.quote(t)}").fetchone()[0] for t in names}
        ref.close()
        assert results["mdbtools"][0] == expected
    if "odbc" in results:  # os dois leitores dao as mesmas tabelas, contagens e celulas
        assert results["odbc"] == results["mdbtools"]
