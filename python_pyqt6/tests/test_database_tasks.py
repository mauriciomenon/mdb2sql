from pathlib import Path

import pytest

from backend.database_tasks import load_table_payload, open_database
from backend.db_manager import MARK_KEY


@pytest.fixture
def people(people_db: Path):
    manager, tables = open_database(people_db)
    yield manager, tables
    manager.close()


def test_open_database_returns_manager_and_names(people) -> None:
    manager, tables = people
    assert tables == ["empty_table", "people"]
    assert manager.reader == "DuckDB"


def test_load_table_payload_default_limit_and_schema(people) -> None:
    payload = load_table_payload(people[0], "people")

    assert payload["table_name"] == "people"
    assert payload["total_rows"] == 3
    assert [row["name"] for row in payload["rows"]] == ["Ana", "Bruno", "carla"]
    assert payload["rows"][1] == {MARK_KEY: 1, "id": 2, "name": "Bruno", "score": None}  # com a identidade (rowid)
    assert payload["shown"] == 3
    assert payload["schema"] == [
        {"column_name": "id", "column_type": "INTEGER", "null": "NO"},
        {"column_name": "name", "column_type": "VARCHAR", "null": "YES"},
        {"column_name": "score", "column_type": "DOUBLE", "null": "YES"},
    ]


def test_load_table_payload_respects_limit(people) -> None:
    payload = load_table_payload(people[0], "people", limit=2)

    assert len(payload["rows"]) == 2
    assert payload["total_rows"] == 3


def test_marked_rows_stay_on_top_whatever_the_search(people) -> None:
    # item 31: as marcadas no topo, na ordem da tabela, sem repetir; "So as marcadas": so elas
    manager = people[0]
    payload = load_table_payload(manager, "people", search="ana", marked=[2, 0])
    assert [row["name"] for row in payload["rows"]] == ["Ana", "carla"] and payload["shown"] == 1
    payload = load_table_payload(manager, "people", search="bruno", marked=[2, 0])
    assert [row["name"] for row in payload["rows"]] == ["Ana", "carla", "Bruno"] and payload["matched_rows"] == 1
    payload = load_table_payload(manager, "people", search="bruno", marked=[2], only_marked=True)
    assert [row["name"] for row in payload["rows"]] == ["carla"] and payload["shown"] == 1
