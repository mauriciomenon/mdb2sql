from pathlib import Path

import duckdb
import pytest

from backend.db_manager import DBManager


def _create_duckdb_file(path: Path) -> None:
    conn = duckdb.connect(str(path), read_only=False)
    conn.close()


@pytest.fixture
def sample_database_path() -> Path:
    return (Path(__file__).resolve().parents[2] / "data" / "sample.duckdb").resolve()


def test_validate_database_path_allows_duckdb(tmp_path: Path) -> None:
    db_file = tmp_path / "sample.duckdb"
    _create_duckdb_file(db_file)

    manager = DBManager()
    manager.connect(str(db_file))
    assert manager.current_db == str(db_file.resolve())


@pytest.mark.parametrize("suffix", [".txt", ".csv", ".xlsx"])
def test_validate_database_path_rejects_bad_ext(tmp_path: Path, suffix: str) -> None:
    bad_file = tmp_path / f"invalid{suffix}"
    bad_file.touch()

    manager = DBManager()
    with pytest.raises(ValueError):
        manager.connect(str(bad_file))


def test_validate_database_path_missing_file_raises(tmp_path: Path) -> None:
    missing = tmp_path / "not_exists.duckdb"
    manager = DBManager()
    with pytest.raises(FileNotFoundError):
        manager.connect(str(missing))


def test_connect_sets_current_db_and_closes_previous(tmp_path: Path) -> None:
    first = tmp_path / "first.duckdb"
    second = tmp_path / "second.duckdb"
    _create_duckdb_file(first)
    _create_duckdb_file(second)

    manager = DBManager()
    manager.connect(str(first))
    first_conn = manager.conn
    assert manager.current_db == str(first.resolve())

    # connect to second should close and reopen
    manager.connect(str(second))
    assert manager.current_db == str(second.resolve())
    assert manager.conn is not first_conn
    assert first_conn is not None
    with pytest.raises(duckdb.ConnectionException):
        first_conn.execute("SHOW TABLES")


def test_close_interrupts_a_running_query(people_db: Path) -> None:
    # fechar o arquivo durante uma consulta longa (busca global, contagem) nao espera o fim dela: a tela nao trava
    import threading
    import time

    manager = DBManager(str(people_db))
    errors: list[Exception] = []

    def run() -> None:
        try:
            manager.execute_query("SELECT sum(i % 7) FROM range(1000000000) r(i)")  # ~7 s sem interromper
        except duckdb.Error as exc:
            errors.append(exc)

    worker = threading.Thread(target=run)
    worker.start()
    deadline = time.monotonic() + 10
    while not manager._cursors and time.monotonic() < deadline:
        time.sleep(0.01)
    time.sleep(0.2)  # a consulta ja esta rodando
    start = time.monotonic()
    manager.close()
    elapsed = time.monotonic() - start
    worker.join(10)

    assert errors and isinstance(errors[0], duckdb.InterruptException), errors
    assert elapsed < 2 and manager.conn is None


def test_duckdb_real_query_sample(sample_database_path: Path) -> None:
    if not sample_database_path.exists():
        pytest.skip("sample.duckdb not found")

    manager = DBManager()

    manager.connect(str(sample_database_path))
    try:
        tables = manager.list_tables()
        assert {"RANGER_SOACCU", "RANGER_SOGEN", "RANGER_SOVARS"}.issubset(set(tables))

        rows = manager.query_table("RANGER_SOACCU", limit=5)
        assert len(rows) > 0
        count = manager.get_row_count("RANGER_SOACCU")
        assert count >= len(rows)
    finally:
        manager.close()
