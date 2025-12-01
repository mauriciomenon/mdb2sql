from importlib import reload
import importlib.util
from pathlib import Path
import sys
from types import SimpleNamespace

import pytest

# Ensure src/ is on path when installed in editable mode
ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

# Provide a lightweight duckdb stub only when import fails (keeps real module if available)
if importlib.util.find_spec("duckdb") is None:  # pragma: no cover - only when duckdb missing
    class _DummyConn:
        def __init__(self, path: str):
            self.path = path

        def execute(self, *_args, **_kwargs):  # minimal API for tests
            raise AttributeError("duckdb stub has no execute; install duckdb for integration tests")

        def close(self) -> None:
            return None

    def _connect(path: str, read_only: bool = True) -> _DummyConn:  # noqa: ARG001
        return _DummyConn(path)

    sys.modules["duckdb"] = SimpleNamespace(connect=_connect)

import backend.db_manager as db_mod  # noqa: E402
from backend.db_manager import DBManager  # noqa: E402


def test_validate_database_path_allows_duckdb(tmp_path: Path) -> None:
    db_file = tmp_path / "sample.duckdb"
    db_file.touch()

    manager = DBManager()
    validated = manager._validate_database_path(str(db_file))
    assert validated == str(db_file.resolve())


@pytest.mark.parametrize("suffix", [".txt", ".sqlite", ".mdb"])
def test_validate_database_path_rejects_bad_ext(tmp_path: Path, suffix: str) -> None:
    bad_file = tmp_path / f"invalid{suffix}"
    bad_file.touch()

    manager = DBManager()
    with pytest.raises(ValueError):
        manager._validate_database_path(str(bad_file))


def test_validate_database_path_missing_file_raises(tmp_path: Path) -> None:
    missing = tmp_path / "not_exists.duckdb"
    manager = DBManager()
    with pytest.raises(FileNotFoundError):
        manager._validate_database_path(str(missing))


def test_connect_sets_current_db_and_closes_previous(tmp_path: Path) -> None:
    first = tmp_path / "first.duckdb"
    second = tmp_path / "second.duckdb"
    first.touch()
    second.touch()

    manager = DBManager()
    manager.connect(str(first))
    assert manager.current_db == str(first.resolve())

    # connect to second should close and reopen
    manager.connect(str(second))
    assert manager.current_db == str(second.resolve())


def test_duckdb_real_query_sample(monkeypatch: pytest.MonkeyPatch) -> None:
    duckdb = pytest.importorskip("duckdb")  # real module required
    if isinstance(duckdb, SimpleNamespace) or getattr(duckdb, "__file__", None) is None:
        pytest.skip("real duckdb not installed; skipping integration")
    sample = (Path(__file__).resolve().parents[2] / "data" / "sample.duckdb").resolve()
    if not sample.exists():
        pytest.skip("sample.duckdb not found")

    # ensure we use real duckdb module, not the stub
    monkeypatch.setitem(sys.modules, "duckdb", duckdb)
    reload(db_mod)  # reload to bind real duckdb
    manager = db_mod.DBManager()

    manager.connect(str(sample))
    try:
        tables = manager.list_tables()
        assert {"RANGER_SOACCU", "RANGER_SOGEN", "RANGER_SOVARS"}.issubset(set(tables))

        rows = manager.query_table("RANGER_SOACCU", limit=5)
        assert len(rows) > 0
        count = manager.get_row_count("RANGER_SOACCU")
        assert count >= len(rows)
    finally:
        manager.close()
