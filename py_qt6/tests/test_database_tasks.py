from pathlib import Path

from backend.database_tasks import list_tables, load_table_payload


def test_list_tables_returns_path_and_names(people_db: Path) -> None:
    assert list_tables(people_db) == (people_db, ["empty_table", "people"])


def test_load_table_payload_default_limit_and_schema(people_db: Path) -> None:
    payload = load_table_payload(people_db, "people")

    assert payload["table_name"] == "people"
    assert payload["total_rows"] == 3
    assert [row["name"] for row in payload["rows"]] == ["Ana", "Bruno", "carla"]
    assert payload["schema"] == [
        {"column_name": "id", "column_type": "INTEGER", "null": "NO"},
        {"column_name": "name", "column_type": "VARCHAR", "null": "YES"},
        {"column_name": "score", "column_type": "DOUBLE", "null": "YES"},
    ]


def test_load_table_payload_respects_limit(people_db: Path) -> None:
    payload = load_table_payload(people_db, "people", limit=2)

    assert len(payload["rows"]) == 2
    assert payload["total_rows"] == 3
