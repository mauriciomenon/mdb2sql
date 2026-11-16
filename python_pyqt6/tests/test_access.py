import os
import shutil
import sqlite3
from pathlib import Path

import pytest

from backend import access
from backend.db_manager import DBManager

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


def test_mdb_schema_tables_maps_access_types() -> None:
    tables = access.mdb_schema_tables(SCHEMA)

    assert list(tables) == ["RANGER_SOSTAT", "OTHER"]
    assert tables["RANGER_SOSTAT"] == [
        ("RTUNO", "DECIMAL(10,0)"),
        ("SUBNAM", "VARCHAR"),
        ("VALUE", "DOUBLE"),
        ("WHEN", "TIMESTAMP"),
        ("NOTE", "VARCHAR"),
        ("FLAG", "BOOLEAN"),
        ("ID", "INTEGER"),
        ("SMALL", "SMALLINT"),
        ("PIC", "BLOB"),
    ]
    assert tables["OTHER"] == [("A", "DECIMAL(19,4)")]


def test_odbc_types() -> None:
    assert access._odbc_type("DECIMAL", 10, 0) == "DECIMAL(10,0)"
    assert access._odbc_type("COUNTER", 10, 0) == "INTEGER"
    assert access._odbc_type("LONGCHAR", 1073741823, None) == "VARCHAR"
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
    with pytest.raises(RuntimeError, match="Access Database Engine"):
        access.access_reader()
    monkeypatch.setenv("MDB2SQL_ACCESS_READER", "jet")
    with pytest.raises(ValueError):
        access.access_reader()


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


# Banco Access real (copia): MDB2SQL_TEST_ACCDB=<copia.accdb>; sem ela o teste e pulado (.accdb nao vai no git)
REAL_ACCDB = os.environ.get("MDB2SQL_TEST_ACCDB")


@pytest.mark.skipif(not REAL_ACCDB, reason="MDB2SQL_TEST_ACCDB nao definido")
def test_real_access_same_data_by_odbc_and_mdbtools(monkeypatch, tmp_path) -> None:
    copy = tmp_path / "copy.accdb"
    shutil.copy2(REAL_ACCDB, copy)
    results = {}
    for reader in ("odbc", "mdbtools"):
        monkeypatch.setenv("MDB2SQL_ACCESS_READER", reader)
        with DBManager(str(copy)) as manager:
            tables = manager.list_tables()
            results[reader] = (
                manager.reader,
                {t: manager.get_row_count(t) for t in tables},
                manager.cursor().execute(f"SELECT * FROM {access.quote(tables[-1])} ORDER BY ALL").fetchall(),
            )
    assert results["odbc"][0] == "Access ODBC" and results["mdbtools"][0] == "mdbtools"
    assert results["odbc"][1:] == results["mdbtools"][1:]
