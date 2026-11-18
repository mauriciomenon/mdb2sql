from pathlib import Path

import pytest
from PyQt6.QtCore import QSettings, QSize, Qt
from PyQt6.QtGui import QGuiApplication
from PyQt6.QtWidgets import QAbstractButton, QApplication, QFileDialog, QProgressDialog, QWidget

from ui.dialogs import ColumnsDialog, grid_columns
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
    assert win.windowTitle() == "mdb2sql 1.3.0 - Python"
    assert win.empty_label.text() == "No database loaded" and win.status_label.text() == ""
    assert win.progress.isHidden()


def test_app_icon_loads(qtbot) -> None:
    from PyQt6.QtGui import QIcon

    from shared.bundle import resource

    icon = QIcon(str(resource("mdb2sql.ico")))
    assert 16 in {size.width() for size in icon.availableSizes()}  # .ico com varios tamanhos, lido pelo Qt


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
    assert window.windowTitle() == "people.duckdb - mdb2sql 1.3.0 - Python"
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
    assert window.info_label.text() == "people: Showing 1 of 1 matching rows (3 rows in table)"

    window.data_table.selectAll()
    window.copy_selection()
    assert QApplication.clipboard().text() == "10\tcarla\t7.25"


def test_table_filter_hides_non_matching(window: MainWindow) -> None:
    window.table_filter.setText("peo")

    hidden = {window.table_list.item(i).text(): window.table_list.item(i).isHidden() for i in range(2)}
    assert hidden == {"empty_table": True, "people": False}
    window.table_filter.setText("TABLE Émpty")  # todas as palavras, qualquer ordem, sem caixa nem acento
    assert [window.table_list.item(i).isHidden() for i in range(2)] == [False, True]


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
    assert Path(asked[1]).name == "people_export.duckdb"
    assert Path(asked[3]).name == "people.csv"
    assert sorted(p.name for p in people_db.parent.glob("out.*")) == ["out.csv", "out.duckdb", "out.sqlite", "out.xlsx"]
    assert QSettings().value("last_dir") == str(people_db.parent)
    # cada exportacao fecha e apaga o seu dialogo "Export": nenhum fica acumulado na janela
    qtbot.waitUntil(lambda: not window.findChildren(QProgressDialog), timeout=5000)


def _texts(items) -> list[str]:
    return [item.text().replace("&", "") for item in items if item.text()]


def _menu_texts(menu) -> list[str]:
    # textos de um menu e dos submenus, na ordem; cada item aparece uma vez na arvore inteira
    texts = []
    for action in menu.actions():
        if action.menu():
            texts += [action.text().replace("&", "")] + _menu_texts(action.menu())
        elif not action.isSeparator():
            texts.append(action.text().replace("&", ""))
    return texts


def _repeated(texts: list[str]) -> list[str]:
    return sorted({text for text in texts if texts.count(text) > 1})


def test_column_headers_and_table_names_are_not_cut(qtbot, tmp_path: Path) -> None:
    import duckdb

    long_name = "CIM_PROGRESS_START_DATE_" + "x" * 25  # nome mais largo que o conteudo (1, 2, 3)
    table = "RANGER_TABLE_WITH_A_VERY_LONG_NAME_FOR_THE_PANEL_" + "Y" * 30
    # valor de 70 caracteres so na ultima das 99 linhas (alem das que o Qt mede sozinho) e um de 400 (> 1200 px)
    value70 = "SUPERV/CONTR UN PREPARACION DE PARTIDA ACCIONADO COMPLETA LADO B 12345"
    assert len(value70) == 70
    db_file = tmp_path / "wide.duckdb"
    with duckdb.connect(str(db_file)) as conn:
        conn.execute(
            f'CREATE TABLE "{table}" AS SELECT 1 AS A, 2 AS CIM_PROGRESS_START_DATE, 3 AS "{long_name}",'
            f" '{'z' * 400}' AS T, CASE WHEN i = 98 THEN '{value70}' ELSE 'short' END AS PNTNAM"
            " FROM range(99) r(i) ORDER BY i"
        )
    win = MainWindow()
    qtbot.addWidget(win)
    win.show()
    win.open_database(db_file)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=10000)

    header = win.data_table.horizontalHeader()
    metrics = header.fontMetrics()
    for column, name in enumerate(win.table_model.columns[:3]):
        # largura da secao >= largura do nome da coluna (o valor 1 e curto: so o nome define a largura)
        assert win.data_table.columnWidth(column) >= metrics.horizontalAdvance(name), name
        assert win.table_model.headerData(column, Qt.Orientation.Horizontal, Qt.ItemDataRole.ToolTipRole).startswith(name)
    # valor de 70 caracteres inteiro (sem "..."): largura >= texto + margens da celula
    cell_metrics = win.data_table.fontMetrics()
    assert win.data_table.columnWidth(4) >= cell_metrics.horizontalAdvance(value70) + 6
    assert win.data_table.columnWidth(3) == 1200  # so acima de 1200 px corta (texto inteiro na dica)
    assert win.table_list.item(0).toolTip() == table
    # nome de tabela nunca vira "...": o painel cabe o nome mais longo do DB4 inteiro; acima de 35% da janela,
    # rolagem horizontal na lista (o nome continua inteiro)
    assert win.table_list.textElideMode() == Qt.TextElideMode.ElideNone
    list_metrics = win.table_list.fontMetrics()
    for name in ("RANGER_SOSTAT", "RANGER_SOM_AIN_DAY"):
        assert win.tables_panel_width([name]) >= list_metrics.horizontalAdvance(name) + 40
    qtbot.waitUntil(lambda: win.tables_dock.width() >= round(win.width() * 0.35) - 8, timeout=3000)
    assert list_metrics.horizontalAdvance(table) > win.tables_dock.width()  # nome maior que o limite
    qtbot.waitUntil(lambda: win.table_list.horizontalScrollBar().maximum() > 0, timeout=3000)
    assert win.info_label.toolTip() == win.info_label.text()


def test_results_of_the_previous_database_are_dropped(qtbot, window: MainWindow, people_db: Path, monkeypatch) -> None:
    # auditoria externa item 3: consulta pendente do banco A nao pode aparecer depois de abrir o banco B
    import duckdb

    from backend.database_tasks import load_table_payload, open_database

    _select_table(qtbot, window, "people")
    window.sql_edit.setPlainText("SELECT * FROM people")
    window.run_sql()
    qtbot.waitUntil(lambda: window.sql_model.rowCount() == 3, timeout=10000)
    stale_table = (window._table_request, load_table_payload(window.manager, "people"))
    stale_open = (people_db, *open_database(people_db))  # abertura lenta de A que termina depois de B

    other = people_db.parent / "other.duckdb"
    with duckdb.connect(str(other)) as conn:
        conn.execute("CREATE TABLE b_only AS SELECT 1 AS x")
    monkeypatch.setattr(window.table_load_timer, "start", lambda *_a: None)  # B ainda nao carregou a tabela
    window.open_database(other)
    qtbot.waitUntil(lambda: window.current_db_path == other and window._busy == 0, timeout=10000)

    assert window.sql_model.rowCount() == 0 and window.sql_query is None  # resultado SQL de A some
    window._on_table_loaded(*stale_table)
    assert window.loaded_table is None and window.table_model.rowCount() == 0  # tabela de A descartada
    window._on_database_loaded(0, stale_open)
    assert window.current_db_path == other and window.windowTitle().startswith("other.duckdb")


def test_nothing_duplicated(qtbot, points_window: MainWindow) -> None:
    # estado mais cheio da tela: tabela, filtro ativo (botao do filtro + Limpar filtros) e coluna oculta
    win = points_window
    _reloaded(qtbot, win, lambda: win.add_filter("sigla", "U18A"))
    win.set_hidden_columns({"id"})

    buttons = _texts(b for b in win.findChildren(QAbstractButton) if b.isVisible())
    assert _repeated(buttons) == []
    assert buttons.count("Export") == 1 and buttons.count("Columns...") == 1 and buttons.count("Clear Filters") == 1
    assert _repeated(_menu_texts(win.menuBar())) == []
    assert _menu_texts(win.menuBar()).count("Export") == 1
    assert _repeated(_texts(win.data_table.actions())) == []
    assert _repeated(_texts(win.header_menu(0).actions())) == []
    # botao e menu usam a mesma acao (uma acao so, nao duas copias)
    assert win.columns_button.defaultAction() is win.columns_action
    assert win.clear_filters_button.defaultAction() is win.clear_filters_action
    assert win.header_menu(0).actions()[1] is win.columns_action
    assert win.export_button.menu() is win.export_menu


# ------------------------------------------------------------ 1.2.0: colunas ocultas e filtro por valor


def _hidden(win: MainWindow) -> list[bool]:
    return [win.data_table.isColumnHidden(c) for c in range(win.table_model.columnCount())]


def _reloaded(qtbot, win: MainWindow, action) -> None:
    request = win._table_request
    action()
    qtbot.waitUntil(lambda: win._table_request > request and win._busy == 0, timeout=10000)


def test_columns_dialog_hides_several_at_once(qtbot, window: MainWindow) -> None:
    _select_table(qtbot, window, "people")
    assert window.columns_button.toolTip() == "Exports always write every column"

    window.columns_button.click()
    dialog = window.findChild(ColumnsDialog)
    assert [dialog.list.item(i).text() for i in range(3)] == ["id", "name", "score"]
    dialog.set_all(False)  # "Ocultar todas": vale na hora
    assert _hidden(window) == [True, True, True]
    dialog.list.item(1).setCheckState(Qt.CheckState.Checked)
    dialog.accept()  # Fechar

    assert _hidden(window) == [True, False, True]
    assert window.hidden_columns == {"id", "score"}
    assert window.info_label.text() == "people: Showing 3 of 3 rows - 2 hidden columns"
    # a pesquisa continua olhando todas as colunas (7.25 esta na coluna oculta) e exportar leva todas
    window.search_edit.setText("7.25")
    qtbot.waitUntil(lambda: window.data_proxy.rowCount() == 1, timeout=5000)
    assert window.info_label.text() == "people: Showing 1 of 1 matching rows (3 rows in table) - 2 hidden columns"
    assert window.current_result() == ('SELECT * FROM "people"', "people")
    window.search_edit.clear()

    # recarregar a mesma tabela (limite) mantem; o dialogo abre com o estado atual; "Mostrar todas" volta
    _reloaded(qtbot, window, lambda: window.limit_combo.setCurrentIndex(1))
    assert _hidden(window) == [True, False, True]
    window.choose_columns()
    dialog = [d for d in window.findChildren(ColumnsDialog) if d.isVisible()][-1]
    assert dialog.hidden() == {"id", "score"}
    dialog.set_all(True)
    dialog.accept()
    assert _hidden(window) == [False, False, False]
    assert window.info_label.text() == "people: Showing 3 of 3 rows"


def test_columns_dialog_checks_all_selected_rows(qtbot) -> None:
    dialog = ColumnsDialog(["a", "b", "c", "d"], {"d"})
    qtbot.addWidget(dialog)
    for row in (0, 1, 2):
        dialog.list.item(row).setSelected(True)
    dialog.list.item(1).setCheckState(Qt.CheckState.Unchecked)  # desmarcar uma das selecionadas desmarca as tres

    assert dialog.hidden() == {"a", "b", "c", "d"}
    dialog.list.clearSelection()
    dialog.list.item(3).setCheckState(Qt.CheckState.Checked)
    assert dialog.hidden() == {"a", "b", "c"}

    # busca no topo: Mostrar todas so marca as encontradas
    dialog.search.setText("B")
    assert [dialog.list.item(r).isHidden() for r in range(4)] == [True, False, True, True]
    dialog.set_all(True)
    assert dialog.hidden() == {"a", "c"}


def test_columns_dialog_grid_is_proportional(qtbot) -> None:
    assert [grid_columns(w, 170) for w in (100, 170, 700, 5000)] == [1, 1, 4, 6]
    parent = QWidget()
    qtbot.addWidget(parent)
    names = ["RTUNO", "PNTNO", "SUBNAM", "PNTNAM", "CTLOPS"] + [f"COL{i:03}" for i in range(118)]  # 123 colunas

    # tamanho padrao do app e maximizada; no Windows (Segoe UI 9) da 4 e 5 colunas, conferido nas capturas
    # !T: The offscreen test platform has a wider fallback font, so the count is checked against the formula
    shown = []
    for size in (QSize(1200, 800), QSize(1920, 1040)):
        parent.resize(size)
        dialog = ColumnsDialog(names, set(), parent)
        dialog.show()
        qtbot.waitExposed(dialog)
        assert 420 <= dialog.width() <= 900 and dialog.width() == min(900, round(size.width() * 0.65))
        assert dialog.height() <= round(size.height() * 0.7)
        assert dialog.columns_shown == grid_columns(dialog.list.viewport().width() - 4, dialog.cell)
        shown.append(dialog.columns_shown)
        assert dialog.list.font().pointSizeF() == QApplication.font().pointSizeF()  # fonte base, nao encolhe
        assert dialog.list.horizontalScrollBarPolicy() == Qt.ScrollBarPolicy.ScrollBarAlwaysOff
        dialog.close()
    assert shown[0] <= shown[1]

    dialog = ColumnsDialog(names, set(), parent)
    dialog.show()
    dialog.resize(420, 400)  # redimensionar recalcula a grade
    qtbot.waitUntil(lambda: dialog.columns_shown <= 2, timeout=2000)
    dialog.close()


def test_header_menu_hides_one_column_and_table_switch_resets(qtbot, window: MainWindow) -> None:
    _select_table(qtbot, window, "people")
    menu = window.header_menu(2)
    assert [a.text() for a in menu.actions()] == ["Hide this column", "Columns...", "Show all"]
    menu.actions()[0].trigger()
    assert _hidden(window) == [False, False, True]
    assert window.info_label.text() == "people: Showing 3 of 3 rows - 1 hidden column"
    assert not window.header_menu(-1).actions()[0].isEnabled()  # clique fora de uma coluna

    window.header_menu(0).actions()[2].trigger()  # Mostrar todas
    assert _hidden(window) == [False, False, False]

    window.set_hidden_columns({"name"})
    _select_table(qtbot, window, "empty_table")
    assert window.hidden_columns == set() and _hidden(window) == [False, False]


@pytest.fixture
def points_window(qtbot, tmp_path: Path) -> MainWindow:
    # 300 linhas, 100 carregadas: as 50 de sigla U18A ficam alem do limite "Rows"
    import duckdb

    db_file = tmp_path / "points.duckdb"
    with duckdb.connect(str(db_file)) as conn:
        conn.execute(
            "CREATE TABLE points AS SELECT i AS id, CASE WHEN i < 250 THEN 'U9A' ELSE 'U18A' END AS sigla,"
            " CASE WHEN i % 2 = 0 THEN NULL ELSE 'it''s' END AS obs FROM range(300) t(i) ORDER BY i"
        )
        conn.execute("CREATE TABLE other (x INTEGER)")
    win = MainWindow()
    qtbot.addWidget(win)
    win.show()
    win.open_database(db_file)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=10000)
    _select_table(qtbot, win, "points")
    return win


def _chips(win: MainWindow) -> list[str]:
    layout = win.filter_chips
    return [layout.itemAt(i).widget().text() for i in range(layout.count())]


def test_right_click_filter_runs_in_the_database(qtbot, points_window: MainWindow) -> None:
    win = points_window
    assert win.info_label.text() == "points: Showing 100 of 300 rows"
    menu = [a.text() for a in win.data_table.actions() if not a.isSeparator()]
    assert menu[-2:] == ["&Filter by This Value", "C&lear Filters"] and "&Copy Value" in menu
    assert not win.clear_filters_action.isEnabled() and win.clear_filters_button.isHidden()

    # U18A nao esta nas 100 linhas carregadas: o filtro vai na consulta e acha as 50
    _reloaded(qtbot, win, lambda: win.add_filter("sigla", "U18A"))
    assert win.info_label.text() == "points: Showing 50 of 50 matching rows (300 rows in table)"
    assert set(_column(win, 1)) == {"U18A"}
    assert _chips(win) == ["Filter:", "sigla = 'U18A'  ×"]

    # clique direito na celula: a celula atual (NULL) vira "obs IS NULL" e soma com o primeiro filtro
    win.data_table.setCurrentIndex(win.data_proxy.index(0, 2))
    _reloaded(qtbot, win, win.filter_value_action.trigger)
    assert win.filters == [("sigla", "U18A"), ("obs", None)]
    assert win.info_label.text() == "points: Showing 25 of 25 matching rows (300 rows in table)"
    assert _chips(win) == ["Filters:", "sigla = 'U18A'  ×", "obs IS NULL  ×"]
    assert win.clear_filters_action.isEnabled() and not win.clear_filters_button.isHidden()

    # a pesquisa de palavras combina com o filtro, nas linhas carregadas
    win.search_edit.setText("298")
    qtbot.waitUntil(lambda: win.data_proxy.rowCount() == 1, timeout=5000)
    assert win.info_label.text() == "points: Showing 1 of 1 matching rows (300 rows in table)"
    win.search_edit.clear()

    # remover um a um (botao do filtro) e limpar
    _reloaded(qtbot, win, win.filter_chips.itemAt(1).widget().click)
    assert win.filters == [("obs", None)]
    assert win.info_label.text() == "points: Showing 100 of 150 matching rows (300 rows in table)"  # limite Rows vale
    _reloaded(qtbot, win, win.clear_filters_button.click)
    assert win.filters == [] and _chips(win) == []
    assert win.info_label.text() == "points: Showing 100 of 300 rows"


def test_filter_integer_and_quoted_text_from_cell(qtbot, points_window: MainWindow) -> None:
    win = points_window
    win.data_table.sortByColumn(0, Qt.SortOrder.DescendingOrder)  # a celula vem do proxy ordenado: id 99
    win.data_table.setCurrentIndex(win.data_proxy.index(0, 0))
    _reloaded(qtbot, win, win.filter_by_current_cell)
    assert win.filters == [("id", 99)] and _column(win, 0) == ["99"]
    assert _chips(win)[1] == "id = 99  ×"

    win.data_table.setCurrentIndex(win.data_proxy.index(0, 2))
    _reloaded(qtbot, win, win.filter_by_current_cell)
    assert win.filters[1] == ("obs", "it's") and win.data_proxy.rowCount() == 1
    assert _chips(win)[2] == "obs = 'it''s'  ×"
    win.filter_by_current_cell()  # o mesmo filtro de novo nao duplica
    assert len(win.filters) == 2


def test_table_switch_clears_filters(qtbot, points_window: MainWindow) -> None:
    win = points_window
    _reloaded(qtbot, win, lambda: win.add_filter("sigla", "U18A"))
    win.set_hidden_columns({"id"})
    _select_table(qtbot, win, "other")

    assert win.filters == [] and _chips(win) == [] and win.hidden_columns == set()
    assert win.info_label.text() == "other: 0 rows"
