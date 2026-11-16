from pathlib import Path

import pytest

from backend.database_tasks import load_table_payload, open_database


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
    assert payload["schema"] == [
        {"column_name": "id", "column_type": "INTEGER", "null": "NO"},
        {"column_name": "name", "column_type": "VARCHAR", "null": "YES"},
        {"column_name": "score", "column_type": "DOUBLE", "null": "YES"},
    ]


def test_load_table_payload_respects_limit(people) -> None:
    payload = load_table_payload(people[0], "people", limit=2)

    assert len(payload["rows"]) == 2
    assert payload["total_rows"] == 3
