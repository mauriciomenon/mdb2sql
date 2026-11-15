import os
from pathlib import Path

import duckdb
import pytest

# !T: Qt tests need no display (CI); set before any QApplication exists
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")


@pytest.fixture
def people_db(tmp_path: Path) -> Path:
    db_file = tmp_path / "people.duckdb"
    conn = duckdb.connect(str(db_file))
    conn.execute("CREATE TABLE people (id INTEGER NOT NULL, name VARCHAR, score DOUBLE)")
    conn.execute("INSERT INTO people VALUES (1, 'Ana', 9.5), (2, 'Bruno', NULL), (10, 'carla', 7.25)")
    conn.execute("CREATE TABLE empty_table (code INTEGER, label VARCHAR)")
    conn.close()
    return db_file
