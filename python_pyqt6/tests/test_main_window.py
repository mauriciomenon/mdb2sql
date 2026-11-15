from pathlib import Path

import pytest
from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import QApplication

from ui.main_window import MainWindow


@pytest.fixture
def window(qtbot, people_db: Path) -> MainWindow:
    win = MainWindow()
    qtbot.addWidget(win)
    win.show()
    win.open_database(people_db)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=10000)
    return win


def _select_table(qtbot, win: MainWindow, name: str) -> None:
    win.table_list.setCurrentItem(win.table_list.findItems(name, Qt.MatchFlag.MatchExactly)[0])
    qtbot.waitUntil(lambda: win.loaded_table is not None and win.loaded_table[0] == name, timeout=10000)


def _column(win: MainWindow, column: int) -> list[str]:
    proxy = win.data_proxy
    return [proxy.index(row, column).data() for row in range(proxy.rowCount())]


def test_starts_empty(qtbot) -> None:
    win = MainWindow()
    qtbot.addWidget(win)

    assert win.stack.currentWidget() is win.empty_label
    assert win.status_label.text() == "No database loaded"
    assert win.progress.isHidden()


def test_missing_database_reports_error(qtbot, tmp_path: Path) -> None:
    win = MainWindow()
    qtbot.addWidget(win)
    win.open_database(tmp_path / "nope.duckdb")

    assert win.status_label.text() == "Error: nope.duckdb not found"
    assert win.current_db_path is None


def test_open_lists_tables_and_loads_first(window: MainWindow) -> None:
    names = [window.table_list.item(i).text() for i in range(window.table_list.count())]

    assert names == ["empty_table", "people"]
    assert window.status_label.text() == "Loaded: people.duckdb (2 tables)"
    assert window.stack.currentWidget() is window.tabs
    # tabela vazia ainda mostra as colunas do schema
    assert window.info_label.text() == "empty_table: 0 rows"
    assert window.table_model.columns == ["code", "label"]
    assert window.progress.isHidden()


def test_select_sort_search_and_copy(qtbot, window: MainWindow) -> None:
    _select_table(qtbot, window, "people")
    assert window.info_label.text() == "people: Showing 3 of 3 rows"
    assert _column(window, 0) == ["1", "2", "10"]
    assert window.schema_model.rowCount() == 3

    # numeros ordenam como numeros (10 > 2), nao como texto
    window.data_table.sortByColumn(0, Qt.SortOrder.DescendingOrder)
    assert _column(window, 0) == ["10", "2", "1"]

    window.search_edit.setText("CARLA")
    qtbot.waitUntil(lambda: window.data_proxy.rowCount() == 1, timeout=5000)
    assert _column(window, 1) == ["carla"]
    assert window.info_label.text() == "people: 1 of 3 loaded rows match (3 rows in table)"

    window.data_table.selectAll()
    window.copy_selection()
    assert QApplication.clipboard().text() == "10\tcarla\t7.25"


def test_table_filter_hides_non_matching(window: MainWindow) -> None:
    window.table_filter.setText("peo")

    hidden = {window.table_list.item(i).text(): window.table_list.item(i).isHidden() for i in range(2)}
    assert hidden == {"empty_table": True, "people": False}


def test_row_limit_reloads_table(qtbot, window: MainWindow) -> None:
    _select_table(qtbot, window, "people")
    request = window._table_request
    window.limit_combo.setCurrentIndex(1)
    qtbot.waitUntil(lambda: window._table_request > request and window._busy == 0, timeout=10000)

    assert window.info_label.text() == "people: Showing 3 of 3 rows"
