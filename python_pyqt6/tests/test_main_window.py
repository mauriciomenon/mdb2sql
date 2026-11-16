from pathlib import Path

import pytest
from PyQt6.QtCore import QSettings, Qt
from PyQt6.QtGui import QGuiApplication
from PyQt6.QtWidgets import QApplication, QFileDialog

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
    assert window.status_label.text() == "Loaded: people.duckdb (2 tables) via DuckDB"
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


def _menu(win: MainWindow, title: str):
    return next(a.menu() for a in win.menuBar().actions() if a.text() == title)


def test_decimal_without_scale_shows_as_integer(qtbot, tmp_path: Path) -> None:
    import duckdb

    db_file = tmp_path / "dec.duckdb"
    with duckdb.connect(str(db_file)) as conn:
        conn.execute("CREATE TABLE t AS SELECT 1::DECIMAL(10,0) AS rtuno, 2.50::DECIMAL(10,2) AS v")
    win = MainWindow()
    qtbot.addWidget(win)
    win.open_database(db_file)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=10000)

    assert _column(win, 0) == ["1"] and _column(win, 1) == ["2.50"]
    assert win.table_model.numeric == [True, True]


def test_menus_have_export_and_settings_theme(window: MainWindow) -> None:
    titles = [a.text() for a in window.menuBar().actions()]
    assert titles == ["&File", "&Edit", "&View", "&Settings", "&Help"]  # Exportar fica dentro de File
    file_items = [a.text() for a in _menu(window, "&File").actions()]
    assert "&Export" in file_items
    theme = _menu(window, "&Settings").actions()[0].menu()
    assert [a.text() for a in theme.actions()] == ["&System", "&Light", "&Dark"]
    assert window.export_button.isEnabled()


def test_theme_is_saved(qtbot, window: MainWindow, monkeypatch) -> None:
    # a plataforma offscreen ignora setColorScheme: confere o esquema pedido ao Qt
    applied = []
    monkeypatch.setattr(QGuiApplication.styleHints(), "setColorScheme", applied.append, raising=False)
    window.theme_actions["dark"].trigger()
    assert QSettings().value("theme") == "dark"
    assert applied == [Qt.ColorScheme.Dark]

    again = MainWindow()  # nova execucao le o tema gravado
    qtbot.addWidget(again)
    assert again.theme_actions["dark"].isChecked()
    window.theme_actions["system"].trigger()
    assert QSettings().value("theme") == "system"


def test_sql_tab_runs_query_and_copies(qtbot, window: MainWindow) -> None:
    window.sql_edit.setPlainText("SELECT id, name AS n, name AS n FROM people ORDER BY id DESC")
    window.run_sql()
    qtbot.waitUntil(lambda: window.sql_model.rowCount() == 3, timeout=10000)

    assert window.sql_model.columns == ["id", "n", "n_2"]
    assert window.info_label.text() == "SQL: 3 rows"
    window.sql_table.setCurrentIndex(window.sql_proxy.index(0, 1))
    window.copy_action.trigger()
    assert QApplication.clipboard().text() == "carla"
    assert window.current_result() == (window.sql_query, "SQL")

    window.sql_edit.setPlainText("SELECT * FROM missing_table")
    window.run_sql()
    qtbot.waitUntil(lambda: window.info_label.text().startswith("SQL error"), timeout=10000)


def test_export_actions_write_files_next_to_source(qtbot, window: MainWindow, people_db: Path, monkeypatch) -> None:
    asked = []

    def fake_save(_parent, _title, suggested, _filter):
        asked.append(suggested)
        return str(people_db.parent / f"out{Path(suggested).suffix}"), ""

    monkeypatch.setattr(QFileDialog, "getSaveFileName", fake_save)
    _select_table(qtbot, window, "people")

    for action in window.export_db_actions + window.export_result_actions:
        action.trigger()
        qtbot.waitUntil(lambda: window.info_label.text().startswith("Export"), timeout=20000)
        assert window.info_label.text().startswith("Exported"), window.info_label.text()
        window.info_label.setText("")

    # pasta sugerida = pasta do banco aberto; o proprio banco nunca e sugerido
    assert [Path(s).parent for s in asked] == [people_db.parent] * 5
    assert Path(asked[0]).name == "people_export.duckdb"
    assert Path(asked[3]).name == "people.csv"
    assert sorted(p.name for p in people_db.parent.glob("out.*")) == ["out.csv", "out.duckdb", "out.sqlite", "out.xlsx"]
    assert QSettings().value("last_dir") == str(people_db.parent)
