from pathlib import Path

import pytest
from PyQt6.QtCore import QSettings, QSize, Qt
from PyQt6.QtGui import QGuiApplication
from PyQt6.QtWidgets import QAbstractButton, QApplication, QFileDialog, QLabel, QProgressDialog, QWidget

from ui.dialogs import ColumnsDialog, grid_columns
from ui.main_window import MainWindow


@pytest.fixture
def window(qtbot, people_db: Path) -> MainWindow:
    win = MainWindow()
    qtbot.addWidget(win)
    win.show()
    win.open_database(people_db)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=30000)
    return win


def _select_table(qtbot, win: MainWindow, name: str) -> None:
    win.table_list.setCurrentItem(win.table_list.findItems(name, Qt.MatchFlag.MatchExactly)[0])
    qtbot.waitUntil(lambda: win.loaded_table is not None and win.loaded_table[0] == name, timeout=30000)


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


def test_window_has_app_icon_without_main(qtbot) -> None:
    # a janela aberta sem main.py (testes, codigo) tambem leva o icone: .ico com varios tamanhos, lido pelo Qt
    win = MainWindow()
    qtbot.addWidget(win)
    assert 16 in {size.width() for size in win.windowIcon().availableSizes()}


def test_missing_database_reports_error(qtbot, tmp_path: Path) -> None:
    win = MainWindow()
    qtbot.addWidget(win)
    win.open_database(tmp_path / "nope.duckdb")

    assert win.status_label.text() == "Error: nope.duckdb not found"
    assert win.current_db_path is None


def test_open_lists_tables_and_loads_first(window: MainWindow) -> None:
    names = window.table_names()

    assert names == ["empty_table", "people"]
    # lista de tabelas com a contagem de linhas ao lado (igual nas 4 versoes): Tabela | Linhas, numero a direita
    header = window.table_list.headerItem()
    assert [header.text(0), header.text(1)] == ["Table", "Rows"]
    assert [window.table_list.topLevelItem(i).text(1) for i in range(2)] == ["0", "3"]
    assert window.table_list.topLevelItem(1).textAlignment(1) & Qt.AlignmentFlag.AlignRight
    assert window.status_label.text() == "Loaded: people.duckdb (2 tables)"
    assert window.reader_label.text() == "Opened via DuckDB"  # fixo a direita da barra de baixo
    assert window.windowTitle() == "people.duckdb - mdb2sql 1.3.0 - Python"
    assert window.stack.currentWidget() is window.tabs
    # tabela vazia ainda mostra as colunas do schema
    assert window.info_label.text() == "empty_table: showing 0 of 0 rows"
    assert window.table_model.columns == ["code", "label"]
    assert window.progress.isHidden()


def test_table_list_shows_name_and_count_without_scrolling(qtbot, tmp_path: Path) -> None:
    # nomes como os do DB4 e contagem de milhares: o painel abre com as duas colunas inteiras (a coluna Linhas
    # nao fica cortada atras de uma rolagem horizontal)
    import duckdb

    db_file = tmp_path / "db4like.duckdb"
    with duckdb.connect(str(db_file)) as conn:
        for name in ("RANGER_SOACCU", "RANGER_SOANLG", "RANGER_SOM_AIN_DAY", "RANGER_SOSTAT"):
            conn.execute(f"CREATE TABLE {name} AS SELECT i FROM range(4460) r(i)")
    win = MainWindow()
    qtbot.addWidget(win)
    win.resize(1280, 800)
    win.show()
    win.open_database(db_file)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=30000)
    tree = win.table_list
    qtbot.waitUntil(lambda: tree.horizontalScrollBar().maximum() == 0, timeout=3000)
    assert tree.topLevelItem(0).text(1) == "4,460"
    assert tree.columnWidth(1) >= tree.sizeHintForColumn(1)
    assert tree.columnWidth(0) >= tree.sizeHintForColumn(0)


def test_select_sort_search_and_copy(qtbot, window: MainWindow) -> None:
    _select_table(qtbot, window, "people")
    assert window.info_label.text() == "people: showing 3 of 3 rows"
    assert _column(window, 0) == ["1", "2", "10"]
    assert window.schema_model.rowCount() == 3
    # Schema: titulos e nulidade traduzidos (nao as chaves nem o YES/NO do backend), igual nas 4 versoes
    schema = window.schema_model
    assert [schema.headerData(c, Qt.Orientation.Horizontal) for c in range(3)] == ["Column", "Type", "Nullable"]
    assert [schema.index(r, 2).data() for r in range(3)] == ["No", "Yes", "Yes"]
    # 6 px a mais de cada lado do texto, nas celulas e no cabecalho do Schema (as outras grades nao mudam)
    from PyQt6.QtWidgets import QStyle

    def margins(view):
        return [view.style().pixelMetric(m, None, view) for m in (QStyle.PixelMetric.PM_FocusFrameHMargin,
                                                                  QStyle.PixelMetric.PM_HeaderMargin)]
    grid, header = margins(window.data_table), margins(window.schema_table)
    assert [b - a for a, b in zip(grid, header)] == [6, 6]
    assert window.schema_table.horizontalHeader().style() is window.schema_table.style()

    # numeros ordenam como numeros (10 > 2), nao como texto
    window.data_table.sortByColumn(0, Qt.SortOrder.DescendingOrder)
    assert _column(window, 0) == ["10", "2", "1"]

    window.search_edit.setText("CARLA")
    # 300 ms depois da ultima tecla a consulta sai na hora: sem os 150 ms da navegacao pela lista (eram ~470 ms)
    request = window._table_request
    window.search_timer.timeout.emit()
    assert window._table_request == request + 1 and not window.table_load_timer.isActive()
    qtbot.waitUntil(lambda: window.data_proxy.rowCount() == 1, timeout=5000)
    assert _column(window, 1) == ["carla"]
    assert window.info_label.text() == "people: showing 1 of 1 row matching (3 in the table)"

    window.data_table.selectAll()
    window.copy_selection()
    assert QApplication.clipboard().text() == "10\tcarla\t7.25"


def test_top_bar_path_open_and_drop(qtbot, window: MainWindow, people_db: Path, tmp_path: Path) -> None:
    # linha de cima igual nas 4 versoes (Zig): caminho do arquivo aberto, Procurar... / Abrir / Exportar...
    from PyQt6.QtCore import QMimeData, QPointF, QUrl
    from PyQt6.QtGui import QDropEvent

    assert window.path_edit.text() == str(people_db)
    assert window.findChild(type(window.path_edit)) is window.path_edit
    # caminho maior que o campo, sem foco: mostra o fim (o nome do arquivo), com "..." no comeco
    window.path_edit.resize(200, window.path_edit.height())
    shown = window.path_edit.shown_text()
    assert shown.startswith("…") and str(people_db).endswith(shown[1:]) and len(shown) > 5
    # o desenho sem foco passa pelo caminho que corta o comeco (e nao pelo do QLineEdit): pinta sem erro
    painted = []
    original = type(window.path_edit).paintEvent

    def spy(edit, event):
        painted.append(not edit.hasFocus() and edit.fontMetrics().horizontalAdvance(edit.text()) > 150)
        original(edit, event)

    from unittest import mock

    with mock.patch.object(type(window.path_edit), "paintEvent", spy):
        window.path_edit.grab()
    assert painted and painted[-1]

    # caminho digitado + Enter abre; caminho que nao existe: erro e o aberto continua
    import duckdb

    other = tmp_path / "other.duckdb"
    with duckdb.connect(str(other)) as conn:
        conn.execute("CREATE TABLE b AS SELECT 1 AS x")
    window.path_edit.setText(str(tmp_path / "missing.duckdb"))
    window.path_edit.returnPressed.emit()
    assert window.current_db_path == people_db and window.status_label.text().startswith("Error:")
    window.path_edit.setText(f'"{other}"')  # aspas do "Copiar como caminho" do Windows
    window.open_button.click()
    qtbot.waitUntil(lambda: window.current_db_path == other and window._busy == 0, timeout=30000)

    # arquivo arrastado para a janela ou para um campo de texto dela abre como o Abrir
    # !T: QApplication.sendEvent does not deliver a Drop outside a real drag: the handlers are called directly
    for target in (window, window.search_edit):
        data = QMimeData()
        data.setUrls([QUrl.fromLocalFile(str(people_db if target is window else other))])
        drop = QDropEvent(QPointF(5, 5), Qt.DropAction.CopyAction, data, Qt.MouseButton.LeftButton,
                          Qt.KeyboardModifier.NoModifier)
        drop.ignore()
        if target is window:
            window.dropEvent(drop)
        else:
            assert window.eventFilter(target, drop)  # tratado pela janela, nao vira texto do campo
        assert drop.isAccepted()
        expected = people_db if target is window else other
        qtbot.waitUntil(lambda: window.current_db_path == expected and window._busy == 0, timeout=30000)
    assert window.search_edit.text() == ""  # o arquivo nao virou texto da pesquisa


def test_narrow_window_wraps_the_data_bar_and_the_search_stretches(qtbot, window: MainWindow) -> None:
    # janela estreita (720 px) igual ao Go: a barra quebra a linha, nada cortado nem num menu "»"; o campo de busca
    # estica sem maximo (eram 420 px)
    from PyQt6.QtWidgets import QToolBar

    def inside(widget) -> bool:
        right = widget.mapTo(window.data_page, widget.rect().topRight()).x()
        return widget.isVisible() and 0 <= widget.mapTo(window.data_page, widget.rect().topLeft()).x() and \
            right < window.data_page.width()

    window.resize(1600, 800)
    qtbot.waitUntil(lambda: window.search_edit.width() > 420, timeout=3000)
    assert window.search_edit.maximumWidth() > 10_000
    window.resize(720, 800)
    qtbot.waitUntil(lambda: window.width() == 720, timeout=3000)
    QApplication.processEvents()
    for widget in (window.search_edit, window.columns_button, *window.scope_buttons):
        assert inside(widget), widget
    assert window.search_edit.width() >= 160
    # quebra a linha exatamente quando a barra inteira nao cabe na largura da aba Data
    spacing = 6
    needed = (window.search_edit.minimumWidth() + window.scope_buttons[0].parentWidget().sizeHint().width()
              + window.columns_button.sizeHint().width() + 2 * spacing + 12)
    wrapped = window.columns_button.y() > window.search_edit.geometry().bottom()
    assert wrapped == (needed > window.data_page.width())
    window.resize(1600, 800)  # mais largura: a mesma barra volta para uma linha so
    qtbot.waitUntil(lambda: window.columns_button.y() < window.search_edit.geometry().bottom(), timeout=3000)
    assert needed <= window.data_page.width()
    for toolbar in window.findChildren(QToolBar):  # nada escondido no "»" da barra de cima
        extension = toolbar.findChild(QAbstractButton, "qt_toolbar_ext_button")
        assert extension is None or not extension.isVisible()


def test_flow_layout_wraps_and_gives_the_spare_width_to_the_search(qtbot) -> None:
    from PyQt6.QtWidgets import QLineEdit, QPushButton, QSizePolicy

    from ui.widgets import FlowLayout

    host = QWidget()
    qtbot.addWidget(host)
    layout = FlowLayout(host)
    search = QLineEdit()
    search.setMinimumWidth(160)
    search.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
    buttons = [QPushButton(text) for text in ("one", "two")]
    for button in buttons:
        button.setFixedWidth(100)
    for widget in (search, *buttons):
        layout.addWidget(widget)
    host.show()
    host.resize(600, 200)
    QApplication.processEvents()
    assert search.width() == 600 - 200 - 2 * layout.spacing() and buttons[0].y() < search.geometry().bottom()  # 1 linha
    host.resize(250, 200)  # 160 + 6 + 100 nao cabe
    QApplication.processEvents()
    assert search.width() == 250 and buttons[0].y() > search.geometry().bottom()  # quebrou: o campo fica sozinho
    assert buttons[1].x() > buttons[0].x() and buttons[1].y() == buttons[0].y()
    assert layout.heightForWidth(250) > layout.heightForWidth(600)


def test_table_filter_hides_non_matching(qtbot, window: MainWindow) -> None:
    # filtro da lista e pesquisa da aba Data: 300 ms depois da ultima tecla, igual nas 4 versoes
    assert window.table_filter_timer.interval() == window.search_timer.interval() == 300
    window.table_filter.setText("peo")
    assert not window.table_list.topLevelItem(0).isHidden() and window.table_filter_timer.isActive()  # ainda esperando

    qtbot.waitUntil(lambda: window.table_list.topLevelItem(0).isHidden(), timeout=2000)
    hidden = {window.table_list.topLevelItem(i).text(0): window.table_list.topLevelItem(i).isHidden() for i in range(2)}
    assert hidden == {"empty_table": True, "people": False}
    window.table_filter.setText("TABLE Émpty")  # todas as palavras, qualquer ordem, sem caixa nem acento
    qtbot.waitUntil(lambda: [window.table_list.topLevelItem(i).isHidden() for i in range(2)] == [False, True], timeout=2000)


def test_enter_applies_the_filter_and_the_search_at_once(qtbot, window: MainWindow) -> None:
    # Enter nao espera os 300 ms (igual nas 4 versoes): filtro da lista e pesquisa da aba Data
    from PyQt6.QtTest import QTest

    window.table_filter.setText("peo")
    QTest.keyClick(window.table_filter, Qt.Key.Key_Return)
    assert window.table_list.topLevelItem(0).isHidden() and not window.table_filter_timer.isActive()

    _select_table(qtbot, window, "people")
    request = window._table_request
    window.search_edit.setText("carla")
    QTest.keyClick(window.search_edit, Qt.Key.Key_Return)
    assert window._table_request == request + 1 and not window.search_timer.isActive()
    qtbot.waitUntil(lambda: window.data_proxy.rowCount() == 1 and window._busy == 0, timeout=5000)


def test_row_limit_reloads_table(qtbot, window: MainWindow) -> None:
    _select_table(qtbot, window, "people")
    request = window._table_request
    window.limit_combo.setCurrentIndex(1)
    qtbot.waitUntil(lambda: window._table_request > request and window._busy == 0, timeout=30000)

    assert window.info_label.text() == "people: showing 3 of 3 rows"


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
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=30000)

    assert _column(win, 0) == ["1"] and _column(win, 1) == ["2.50"]
    assert win.table_model.numeric == [True, True]


def test_menus_have_export_and_settings_theme(window: MainWindow) -> None:
    titles = [a.text() for a in window.menuBar().actions()]
    assert titles == ["&File", "&Edit", "&View", "&Settings", "&Help"]  # Exportar fica dentro de File
    # Arquivo igual nas 4 versoes (Zig): Abrir... (Ctrl+O), Exportar >, Fechar, Sair (Ctrl+Q)
    from PyQt6.QtGui import QKeySequence

    file_menu = _menu(window, "&File")
    close_key = QKeySequence.keyBindings(QKeySequence.StandardKey.Close)[0].toString()  # Ctrl+F4 / Ctrl+W
    assert [(a.text(), a.shortcut().toString()) for a in file_menu.actions() if not a.isSeparator()] == [
        ("&Open...", "Ctrl+O"), ("&Export", ""), ("&Close", close_key), ("E&xit", "Ctrl+Q")
    ]
    assert file_menu.actions()[1].menu() is window.export_menu
    # F5 (recarregar) continua valendo como atalho da janela, fora dos menus
    assert window.reload_action in window.actions() and window.reload_action.shortcut().toString() == "F5"
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


def test_theme_change_restyles_the_table_list_and_the_alerts(qtbot, window: MainWindow, monkeypatch) -> None:
    # trocar escuro <-> claro muda tudo (a lista de tabelas ficava escura no claro: a folha de estilo guardava a
    # paleta antiga); o erro destacado troca para a cor legivel no tema novo
    from PyQt6.QtGui import QColor, QPalette

    def scheme(dark: bool) -> QPalette:
        palette = QPalette(QApplication.palette())
        for role, color in ((QPalette.ColorRole.Window, "#202020" if dark else "#f3f3f3"),
                            (QPalette.ColorRole.Base, "#2d2d2d" if dark else "#ffffff")):
            palette.setColor(role, QColor(color))
        return palette

    original = QApplication.palette()
    restyled = []
    real = window.table_list.setStyleSheet
    monkeypatch.setattr(window.table_list, "setStyleSheet", lambda sheet: restyled.append(sheet) or real(sheet))
    try:
        QApplication.setPalette(scheme(dark=True))
        window._set_message(window.status_label, "Error: boom", error=True)
        qtbot.waitUntil(lambda: "#ff8a80" in window.status_label.styleSheet(), timeout=3000)
        restyled.clear()
        QApplication.setPalette(scheme(dark=False))
        qtbot.waitUntil(lambda: "#b3261e" in window.status_label.styleSheet(), timeout=3000)
        assert restyled[-1] == mw_tables_style()
    finally:
        QApplication.setPalette(original)


def mw_tables_style() -> str:
    from ui.main_window import TABLES_STYLE

    return TABLES_STYLE


def test_search_all_tables_and_open_one(qtbot, window: MainWindow) -> None:
    # controle de duas opcoes junto ao campo; padrao: esta tabela
    scope_texts = ("This table", "All tables")
    buttons = [b for b in window.findChildren(QAbstractButton) if b.isVisible() and b.text() in scope_texts]
    assert sorted(b.text() for b in buttons) == ["All tables", "This table"] and all(b.isCheckable() for b in buttons)
    assert window.scope_actions["table"].isChecked() and window.data_stack.currentWidget() is window.data_table

    window.scope_actions["all"].trigger()
    window.search_edit.setText("ANA")  # 300 ms depois: lista das tabelas com linhas encontradas no lugar da grade
    qtbot.waitUntil(lambda: window.found_list.count() == 1, timeout=30000)
    assert window.data_stack.currentWidget() is window.found_list
    assert window.found_list.item(0).text() == "people (1)"
    assert window.info_label.text() == '1 table with rows matching "ANA"'

    # escolher uma abre a tabela na aba Data com a mesma pesquisa; o escopo volta para esta tabela
    window.found_list.itemClicked.emit(window.found_list.item(0))
    qtbot.waitUntil(lambda: window.loaded_table is not None and window.loaded_table[0] == "people"
                    and window._busy == 0, timeout=30000)
    assert window.scope_actions["table"].isChecked() and window.data_stack.currentWidget() is window.data_table
    assert _column(window, 1) == ["Ana"]
    assert window.info_label.text() == "people: showing 1 of 1 row matching (3 in the table)"

    # sem resultado: lista vazia; escopo padrao em Configuracoes, gravado e ja valendo na tela
    window.default_scope_actions["all"].trigger()
    assert QSettings().value("search_scope") == "all" and window.scope_actions["all"].isChecked()
    window.search_edit.setText("zzz")
    qtbot.waitUntil(lambda: window.info_label.text() == '0 tables with rows matching "zzz"', timeout=30000)
    assert window.found_list.count() == 0
    again = MainWindow()
    qtbot.addWidget(again)
    assert again.scope_actions["all"].isChecked() and again.default_scope_actions["all"].isChecked()


def test_search_all_tables_never_shows_an_old_result_and_reports_failure(qtbot, window: MainWindow, tmp_path: Path):
    # igual nas 4 versoes: apagar o termo descarta a busca que ainda roda (o resultado dela chegaria antes dos 300 ms)
    window.scope_actions["all"].trigger()
    window.search_edit.setText("ANA")
    window.search_timer.timeout.emit()  # a busca de "ANA" sai agora
    window.search_edit.clear()
    qtbot.waitUntil(lambda: window._busy == 0, timeout=30000)
    assert window.found_list.count() == 0

    # falha (view que da erro ao ler): o erro vai para a barra e o "Searching" sai
    import duckdb

    bad = tmp_path / "bad.duckdb"
    with duckdb.connect(str(bad)) as conn:
        conn.execute("CREATE TABLE a (s VARCHAR)")
        conn.execute("CREATE VIEW z AS SELECT CAST(error('broken view') AS VARCHAR) AS s")
    window.open_database(bad)
    qtbot.waitUntil(lambda: window.current_db_path == bad and window.loaded_table is not None
                    and window._busy == 0, timeout=30000)
    window.scope_actions["all"].trigger()
    window.search_edit.setText("foo")
    qtbot.waitUntil(lambda: "broken view" in window.status_label.text() and window._busy == 0, timeout=30000)
    assert window.status_label.text() == "Error: broken view"
    assert window.info_label.text() == "a: showing 0 of 0 rows" and not window.progress.isVisible()


def test_opening_a_found_table_clears_its_value_filters(qtbot, window: MainWindow) -> None:
    # igual nas 4 versoes: a lista diz "people (1)" e a grade mostra 1, mesmo com o filtro id = 2 (Bruno) antes
    _select_table(qtbot, window, "people")
    _reloaded(qtbot, window, lambda: window.add_filter("id", 2))
    window.scope_actions["all"].trigger()
    window.search_edit.setText("ANA")
    qtbot.waitUntil(lambda: window.found_list.count() == 1, timeout=30000)
    window.found_list.itemClicked.emit(window.found_list.item(0))
    qtbot.waitUntil(lambda: window.loaded_search == "ANA" and window._busy == 0, timeout=30000)

    assert window.filters == [] and _chips(window) == [] and window.filters_bar.isHidden()
    assert window.matched_rows == 1 and _column(window, 1) == ["Ana"]


def test_show_null_setting(qtbot, window: MainWindow) -> None:
    # Configuracoes > Exibir NULL: desligado por padrao (sem a chave gravada = celula vazia, como antes); ligado
    # mostra o texto NULL so na grade; gravado
    _select_table(qtbot, window, "people")
    settings_menu = _menu(window, "&Settings")
    assert window.show_null_action in settings_menu.actions() and not window.show_null_action.isChecked()
    assert _column(window, 2) == ["9.5", "", "7.25"]

    window.show_null_action.trigger()
    assert _column(window, 2) == ["9.5", "NULL", "7.25"]
    assert QSettings().value("show_null") in (True, "true")
    window.data_table.setCurrentIndex(window.data_proxy.index(1, 2))
    window.copy_selection()
    assert QApplication.clipboard().text() == ""  # copiar continua com o valor real
    again = MainWindow()  # proxima abertura: ligado
    qtbot.addWidget(again)
    assert again.show_null_action.isChecked() and again.table_model.null_text == "NULL"
    window.show_null_action.trigger()
    assert _column(window, 2) == ["9.5", "", "7.25"]


def test_sql_tab_runs_query_and_copies(qtbot, window: MainWindow) -> None:
    window.sql_edit.setPlainText("SELECT id, name AS n, name AS n FROM people ORDER BY id DESC")
    window.run_sql()
    qtbot.waitUntil(lambda: window.sql_model.rowCount() == 3, timeout=30000)

    assert window.sql_model.columns == ["id", "n", "n_2"]
    assert window.sql_info.text() == "SQL result: 3 rows"
    window.sql_table.setCurrentIndex(window.sql_proxy.index(0, 1))
    window.copy_action.trigger()
    assert QApplication.clipboard().text() == "carla"
    assert window.sql_query.startswith("SELECT id") and all(a.isEnabled() for a in window.export_sql_actions)

    window.sql_edit.setPlainText("SELECT * FROM missing_table")
    window.run_sql()
    qtbot.waitUntil(lambda: window.status_label.text().startswith("SQL query error"), timeout=30000)
    # a mesma mensagem nunca aparece duas vezes na barra de status: so a esquerda; a direita, o estado da tabela
    shown = [w.text() for w in window.statusBar().findChildren(QLabel) if "SQL query error" in w.text()]
    assert len(shown) == 1 and window.sql_info.text().startswith("SQL query error")  # e na linha do botao

    # erro do motor: uma linha na barra (sem "Parser Error:"), o texto inteiro (LINE 1, ^) no log e na dica
    window.sql_edit.setPlainText("selec 1")
    window.run_sql()
    qtbot.waitUntil(lambda: 'near "selec"' in window.status_label.text(), timeout=30000)
    assert window.status_label.text() == 'SQL query error: syntax error at or near "selec"'
    assert "LINE 1: selec 1" in window.status_label.toolTip() and "LINE 1: selec 1" in window.log_view.toPlainText()
    assert [w.text() for w in window.statusBar().findChildren(QLabel)].count(window.status_label.text()) == 1


def test_sql_error_clears_the_grid_and_success_clears_the_error(qtbot, window: MainWindow) -> None:
    # igual nas 4 versoes: o erro limpa a grade velha; a consulta seguinte que da certo tira o erro da linha do botao
    # e da barra de baixo (com o Log recolhido o erro nao lido ficava na barra)
    window.sql_edit.setPlainText("SELECT name FROM people")
    window.run_sql()
    qtbot.waitUntil(lambda: window.sql_model.rowCount() == 3 and window._busy == 0, timeout=30000)
    assert window.log_dock.isHidden()

    window.sql_edit.setPlainText("SELEC 1")
    window.run_sql()
    qtbot.waitUntil(lambda: window._busy == 0 and window.sql_info.text().startswith("SQL query error"), timeout=30000)
    assert window.sql_model.rowCount() == 0 and window.sql_query is None
    assert not any(a.isEnabled() for a in window.export_sql_actions)
    assert window.status_label.text() == window.sql_info.text() and "color" in window.status_label.styleSheet()
    assert window.log_unread.text() == "(1)"

    window.sql_edit.setPlainText("SELECT 1 AS um")
    window.run_sql()
    qtbot.waitUntil(lambda: window._busy == 0 and window.sql_model.rowCount() == 1, timeout=30000)
    assert window.sql_info.text() == window.status_label.text() == "SQL result: 1 row"
    assert window.sql_info.styleSheet() == window.status_label.styleSheet() == ""
    assert window.log_unread.isHidden()
    window.log("next action")  # o erro resolvido nao volta para a barra
    assert window.status_label.text() == "SQL result: 1 row"

    # erro SQL ja visto no Log: a consulta que da certo depois nao desconta outro erro ainda nao lido
    window.sql_edit.setPlainText("SELEC 2")
    window.run_sql()
    qtbot.waitUntil(lambda: window._busy == 0 and window.sql_info.text().startswith("SQL query error"), timeout=30000)
    window.set_log_visible(True)
    window.set_log_visible(False)
    window._set_message(window.status_label, "Error: other", error=True)
    window.sql_edit.setPlainText("SELECT 2")
    window.run_sql()
    qtbot.waitUntil(lambda: window._busy == 0 and window.sql_info.text() == "SQL result: 1 row", timeout=30000)
    assert window.log_unread.text() == "(1)" and window.status_label.text() == "Error: other"


def test_export_actions_write_files_next_to_source(qtbot, window: MainWindow, people_db: Path, monkeypatch) -> None:
    asked = []

    def fake_save(_parent, _title, suggested, _filter):
        asked.append(suggested)
        return str(people_db.parent / f"out{Path(suggested).suffix}"), ""

    monkeypatch.setattr(QFileDialog, "getSaveFileName", fake_save)
    _select_table(qtbot, window, "people")
    assert not any(a.isEnabled() for a in window.export_sql_actions)  # sem consulta SQL ainda
    window.sql_edit.setPlainText("SELECT name FROM people")
    window.run_sql()
    qtbot.waitUntil(lambda: window.sql_model.rowCount() == 3 and window._busy == 0, timeout=30000)

    # os itens do Rust, nesta ordem (igual nas 4 versoes): banco SQLite, DuckDB, Excel; tabela CSV, Excel; SQL CSV, Excel
    actions = window.export_db_actions + window.export_table_actions + window.export_sql_actions
    assert [a.text().replace("&", "") for a in actions] == [
        "Database to SQLite (.sqlite)...", "Database to DuckDB (.duckdb)...",
        "Database to Excel (.xlsx, one sheet per table)...", "Current table to CSV...", "Current table to Excel (.xlsx)...",
        "SQL result to CSV...", "SQL result to Excel (.xlsx)...",
    ]
    for action in actions:
        action.trigger()
        qtbot.waitUntil(lambda: window.status_label.text().startswith("Export"), timeout=60000)
        assert window.status_label.text().startswith("Exported"), window.status_label.text()
        window.status_label.setText("")

    # pasta sugerida = pasta do banco aberto; o proprio banco nunca e sugerido; resultado SQL = query.csv (nas 4)
    assert [Path(s).parent for s in asked] == [people_db.parent] * 7
    assert [Path(s).name for s in asked] == ["people.sqlite", "people_export.duckdb", "people.xlsx", "people.csv",
                                             "people.xlsx", "query.csv", "query.xlsx"]
    assert sorted(p.name for p in people_db.parent.glob("out.*")) == ["out.csv", "out.duckdb", "out.sqlite", "out.xlsx"]
    assert QSettings().value("last_dir") == str(people_db.parent)
    # cada exportacao fecha e apaga o seu dialogo "Export": nenhum fica acumulado na janela
    qtbot.waitUntil(lambda: not window.findChildren(QProgressDialog), timeout=5000)


def test_export_with_active_search_asks_whole_table_or_found_rows(qtbot, window: MainWindow, people_db: Path,
                                                                  monkeypatch) -> None:
    # igual nas 4 versoes: com pesquisa ativa, "Tabela inteira" ou "So as N linhas encontradas" (Cancelar nao grava)
    import csv

    out = people_db.parent / "found.csv"
    monkeypatch.setattr(QFileDialog, "getSaveFileName", lambda *_a: (str(out), ""))
    _select_table(qtbot, window, "people")
    answers, asked = [], []

    def ask(count: int):
        asked.append(count)
        # a tela muda enquanto a pergunta esta aberta (outro filtro): grava o que a grade contava ao perguntar
        window.filters.append(("id", 99))
        return answers.pop(0)

    monkeypatch.setattr(window, "ask_found_rows", ask)

    def exported() -> list[list[str]]:
        window.status_label.setText("")
        window.export_table_actions[0].trigger()
        qtbot.waitUntil(lambda: window.status_label.text().startswith("Export"), timeout=60000)
        with open(out, encoding="utf-8-sig", newline="") as handle:
            return list(csv.reader(handle))[1:]

    assert len(exported()) == 3  # sem pesquisa: nao pergunta, a tabela inteira
    _reloaded(qtbot, window, lambda: window.search_edit.setText("ana"))
    answers[:] = [True]
    assert exported() == [["1", "Ana", "9.5"]] and answers == [] and asked == [1]
    window.filters.clear()
    answers[:] = [False]
    assert len(exported()) == 3
    window.filters.clear()
    answers[:] = [None]  # Cancelar
    out.unlink()
    window.export_table_actions[0].trigger()
    assert not out.exists() and answers == []

    # o texto da pergunta no plural certo: 1 linha
    from PyQt6.QtCore import QTimer

    seen = []

    def answer() -> None:
        box = QApplication.activeModalWidget()
        seen.extend([box.text(), *(b.text() for b in box.buttons())])
        box.reject()

    monkeypatch.undo()
    QTimer.singleShot(0, answer)
    assert window.ask_found_rows(1) is None  # fechar a pergunta = Cancelar
    assert seen[0] == "Export the whole table or only the 1 row found?"
    assert sorted(seen[1:]) == sorted(["Whole table", "Only the 1 row found", "Cancel"])


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
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=30000)

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
    assert win.table_list.topLevelItem(0).toolTip(0) == table
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
    qtbot.waitUntil(lambda: window.sql_model.rowCount() == 3, timeout=30000)
    stale_table = (window._table_request, load_table_payload(window.manager, "people"))
    stale_open = (people_db, None, *open_database(people_db), {}, "")  # abertura lenta de A que termina depois de B

    other = people_db.parent / "other.duckdb"
    with duckdb.connect(str(other)) as conn:
        conn.execute("CREATE TABLE b_only AS SELECT 1 AS x")
    monkeypatch.setattr(window.table_load_timer, "start", lambda *_a: None)  # B ainda nao carregou a tabela
    window.open_database(other)
    qtbot.waitUntil(lambda: window.current_db_path == other and window._busy == 0, timeout=30000)

    assert window.sql_model.rowCount() == 0 and window.sql_query is None  # resultado SQL de A some
    window._on_table_loaded(*stale_table)
    assert window.loaded_table is None and window.table_model.rowCount() == 0  # tabela de A descartada
    window._on_database_loaded(0, stale_open)
    assert window.current_db_path == other and window.windowTitle().startswith("other.duckdb")


def test_another_file_starts_without_search_and_with_the_default_scope(qtbot, window: MainWindow, tmp_path: Path):
    # igual nas 4 versoes: a pesquisa "Ana" de A nao roda em B e o filtro "empty" da lista nao esconde a tabela de B
    import duckdb

    other = tmp_path / "other.duckdb"
    with duckdb.connect(str(other)) as conn:
        conn.execute("CREATE TABLE People (name VARCHAR)")
    window.scope_actions["all"].trigger()
    window.search_edit.setText("Ana")
    window.table_filter.setText("empty")
    window.open_database(other)
    qtbot.waitUntil(lambda: window.current_db_path == other and window.loaded_table is not None
                    and window._busy == 0, timeout=30000)

    assert window.search_edit.text() == "" and window.table_filter.text() == ""
    assert window.scope_actions["table"].isChecked() and window.data_stack.currentWidget() is window.data_table
    assert not window.table_list.topLevelItem(0).isHidden() and window.loaded_search == ""


def test_nothing_duplicated(qtbot, points_window: MainWindow) -> None:
    # estado mais cheio da tela: tabela, filtro ativo (botao do filtro + Limpar filtros) e coluna oculta
    win = points_window
    _reloaded(qtbot, win, lambda: win.add_filter("sigla", "U18A"))
    win.set_hidden_columns({"id"})

    buttons = _texts(b for b in win.findChildren(QAbstractButton) if b.isVisible())
    assert _repeated(buttons) == []
    assert buttons.count("Export...") == 1 and buttons.count("Columns...") == 1 and buttons.count("Clear filters") == 1
    assert {"Browse...", "Open"} <= set(buttons)  # linha de cima igual ao Zig
    assert _repeated(_menu_texts(win.menuBar())) == []
    assert _menu_texts(win.menuBar()).count("Export") == 1
    assert _repeated(_texts(win.data_table.actions())) == []
    assert _repeated(_texts(win.header_menu(0).actions())) == []
    # botao e menu usam a mesma acao (uma acao so, nao duas copias)
    assert win.columns_button.defaultAction() is win.columns_action
    assert win.clear_filters_button.defaultAction() is win.clear_filters_action
    assert win.columns_action in win.header_menu(0).actions()
    win.export_button.click()  # Exportar... abre o mesmo menu de Arquivo > Exportar
    assert win.export_menu.isVisible()
    win.export_menu.close()


# ------------------------------------------------------------ 1.2.0: colunas ocultas e filtro por valor


def _hidden(win: MainWindow) -> list[bool]:
    return [win.data_table.isColumnHidden(c) for c in range(win.table_model.columnCount())]


def _reloaded(qtbot, win: MainWindow, action) -> None:
    request = win._table_request
    action()
    qtbot.waitUntil(lambda: win._table_request > request and win._busy == 0, timeout=30000)


def test_columns_dialog_hides_several_at_once(qtbot, window: MainWindow) -> None:
    _select_table(qtbot, window, "people")
    assert window.columns_button.toolTip() == "Search and export use every column"

    window.columns_button.click()
    dialog = window.findChild(ColumnsDialog)
    assert dialog.windowTitle() == "Columns of people"  # "Colunas de <tabela>" nas 4 versoes
    assert [dialog.list.item(i).text() for i in range(3)] == ["id", "name", "score"]
    dialog.set_all(False)  # "Ocultar todas": vale na hora; a primeira fica (sempre ao menos uma visivel)
    assert _hidden(window) == [False, True, True]
    dialog.list.item(1).setCheckState(Qt.CheckState.Checked)
    dialog.list.item(0).setCheckState(Qt.CheckState.Unchecked)
    dialog.accept()  # Fechar

    assert _hidden(window) == [True, False, True]
    assert window.hidden_columns == {"id", "score"}
    assert window.info_label.text() == "people: showing 3 of 3 rows"
    assert window.hidden_label.text() == "2 hidden columns" and not window.hidden_label.isHidden()  # barra de baixo
    # a pesquisa continua olhando todas as colunas (7.25 esta na coluna oculta) e exportar leva todas
    window.search_edit.setText("7.25")
    qtbot.waitUntil(lambda: window.data_proxy.rowCount() == 1, timeout=5000)
    assert window.info_label.text() == "people: showing 1 of 1 row matching (3 in the table)"
    assert window.manager.select_table("people") == ('SELECT * FROM "people"', [])  # exportar: todas as colunas
    _reloaded(qtbot, window, window.search_edit.clear)

    # recarregar a mesma tabela (limite) mantem; o dialogo abre com o estado atual; "Mostrar todas" volta
    _reloaded(qtbot, window, lambda: window.limit_combo.setCurrentIndex(1))
    assert _hidden(window) == [True, False, True]
    window.choose_columns()
    dialog = [d for d in window.findChildren(ColumnsDialog) if d.isVisible()][-1]
    assert dialog.hidden() == {"id", "score"}
    dialog.set_all(True)
    dialog.accept()
    assert _hidden(window) == [False, False, False]
    assert window.info_label.text() == "people: showing 3 of 3 rows" and window.hidden_label.isHidden()


def test_columns_dialog_checks_all_selected_rows(qtbot) -> None:
    dialog = ColumnsDialog("t", ["a", "b", "c", "d"], {"d"})
    qtbot.addWidget(dialog)
    for row in (0, 1):
        dialog.list.item(row).setSelected(True)
    dialog.list.item(1).setCheckState(Qt.CheckState.Unchecked)  # desmarcar uma das selecionadas desmarca as duas

    assert dialog.hidden() == {"a", "b", "d"}
    dialog.list.clearSelection()
    dialog.list.item(3).setCheckState(Qt.CheckState.Checked)
    assert dialog.hidden() == {"a", "b"}

    # busca no topo: Mostrar todas so marca as encontradas
    dialog.search.setText("B")
    assert [dialog.list.item(r).isHidden() for r in range(4)] == [True, False, True, True]
    dialog.set_all(True)
    assert dialog.hidden() == {"a"}


def test_columns_dialog_keeps_one_column_visible(qtbot) -> None:
    # igual nas 4 versoes: nenhum caminho deixa a grade sem colunas
    dialog = ColumnsDialog("t", ["only"], set())
    qtbot.addWidget(dialog)
    dialog.set_all(False)  # "Ocultar todas" numa tabela de uma coluna
    assert dialog.hidden() == set()

    dialog = ColumnsDialog("t", ["a", "b", "c"], set())
    qtbot.addWidget(dialog)
    dialog.set_all(False)
    assert dialog.hidden() == {"b", "c"}  # a primeira listada fica
    dialog.list.item(0).setCheckState(Qt.CheckState.Unchecked)  # desmarcar a ultima visivel nao vale
    assert dialog.hidden() == {"b", "c"}
    dialog.set_all(True)
    dialog.list.selectAll()
    dialog.list.item(2).setCheckState(Qt.CheckState.Unchecked)  # as tres selecionadas: a desmarcada fica
    assert dialog.hidden() == {"a", "b"}


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
        dialog = ColumnsDialog("t", names, set(), parent)
        dialog.show()
        qtbot.waitExposed(dialog)
        assert 420 <= dialog.width() <= 900 and dialog.width() == min(900, round(size.width() * 0.65))
        assert dialog.height() <= round(size.height() * 0.7)
        assert dialog.columns_shown == grid_columns(dialog.available_width(), dialog.cell)
        assert dialog.available_width() <= dialog.list.viewport().width() - 4  # cabe com ou sem barra vertical
        shown.append(dialog.columns_shown)
        assert dialog.list.font().pointSizeF() == QApplication.font().pointSizeF()  # fonte base, nao encolhe
        assert dialog.list.horizontalScrollBarPolicy() == Qt.ScrollBarPolicy.ScrollBarAlwaysOff
        dialog.close()
    assert shown[0] <= shown[1]

    dialog = ColumnsDialog("t", names, set(), parent)
    dialog.show()
    dialog.resize(420, 400)  # redimensionar recalcula a grade
    qtbot.waitUntil(lambda: dialog.columns_shown <= 2, timeout=2000)
    dialog.close()


def _header_action(win: MainWindow, column: int, text: str, view=None):
    return next(a for a in win.header_menu(column, view).actions() if a.text() == text)


def test_header_menu_fits_hides_and_shows_columns(qtbot, window: MainWindow) -> None:
    _select_table(qtbot, window, "people")
    menu = window.header_menu(2)
    assert [a.text() for a in menu.actions() if not a.isSeparator()] == [
        "Size column to fit", "Size all columns to fit", "Hide this column", "Columns...", "Show all columns",
        "id", "name", "score",
    ]
    assert all(a.isCheckable() and a.isChecked() for a in menu.actions()[-3:])  # marca = visivel
    assert not _header_action(window, -1, "Size column to fit").isEnabled()  # clique fora de uma coluna
    assert not _header_action(window, -1, "Hide this column").isEnabled()
    assert not _header_action(window, 2, "Show all columns").isEnabled()  # nenhuma oculta (igual nas 4)

    # ajustar uma e todas: largura volta ao texto mais longo; a ordenacao escolhida fica
    table = window.data_table
    fitted = [table.columnWidth(c) for c in range(2)]
    window.data_table.sortByColumn(0, Qt.SortOrder.DescendingOrder)
    table.setColumnWidth(0, 20)
    table.setColumnWidth(1, 20)
    _header_action(window, 0, "Size column to fit").trigger()
    assert [table.columnWidth(c) for c in range(2)] == [fitted[0], 20]
    _header_action(window, 0, "Size all columns to fit").trigger()
    assert [table.columnWidth(c) for c in range(2)] == fitted
    assert _column(window, 0) == ["10", "2", "1"]

    # a lista alterna; ocultar desta coluna; a ultima visivel nao pode sair
    _header_action(window, 0, "score").trigger()
    assert _hidden(window) == [False, False, True]
    assert window.hidden_label.text() == "1 hidden column"
    _header_action(window, 0, "Hide this column").trigger()
    assert _hidden(window) == [True, False, True]
    assert not _header_action(window, 1, "name").isEnabled()
    assert not _header_action(window, 1, "Hide this column").isEnabled()
    assert _header_action(window, 1, "Show all columns").isEnabled()
    _header_action(window, 1, "id").trigger()  # clicar numa oculta mostra de novo
    assert _hidden(window) == [False, False, True]
    _header_action(window, 0, "Show all columns").trigger()
    assert _hidden(window) == [False, False, False]

    window.set_hidden_columns({"name"})
    _select_table(qtbot, window, "empty_table")  # trocar de tabela mostra todas (nada vai para disco)
    assert window.hidden_columns == set() and _hidden(window) == [False, False]


def test_header_right_click_still_works_after_gc(window: MainWindow) -> None:
    # 1.3.0: a conexao do clique direito segurava o proprio cabecalho; depois de um gc.collect() o menu sumia ou o
    # app caia (access violation) no clique direito
    import gc

    from PyQt6.QtCore import QPoint
    from PyQt6.QtWidgets import QMenu

    gc.collect()
    for view in (window.data_table, window.sql_table):
        view.horizontalHeader().customContextMenuRequested.emit(QPoint(5, 5))
        menus = [m for m in window.findChildren(QMenu) if m.isVisible()]
        assert len(menus) == 1
        assert (window.columns_action in menus[0].actions()) == (view is window.data_table)
        menus[0].close()


def test_sql_header_menu_hides_until_the_next_query(qtbot, window: MainWindow) -> None:
    window.sql_edit.setPlainText("SELECT id, name FROM people")
    window.run_sql()
    qtbot.waitUntil(lambda: window.sql_model.rowCount() == 3, timeout=30000)
    texts = [a.text() for a in window.header_menu(0, window.sql_table).actions() if not a.isSeparator()]
    assert texts == ["Size column to fit", "Size all columns to fit", "Hide this column", "Show all columns",
                     "id", "name"]  # sem "Colunas...": o dialogo e da aba Data

    _header_action(window, 0, "id", window.sql_table).trigger()
    assert window.sql_table.isColumnHidden(0) and not window.sql_table.isColumnHidden(1)
    window.run_sql()
    qtbot.waitUntil(lambda: not window.sql_table.isColumnHidden(0), timeout=30000)


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
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=30000)
    _select_table(qtbot, win, "points")
    return win


def _chips(win: MainWindow) -> list[str]:
    # rotulo e botoes dos filtros (o Limpar filtros fica no fim da mesma linha)
    layout = win.filter_chips
    widgets = [layout.itemAt(i).widget() for i in range(layout.count())]
    assert widgets[-1] is win.clear_filters_button
    return [widget.text() for widget in widgets[:-1]]


def test_right_click_filter_runs_in_the_database(qtbot, points_window: MainWindow) -> None:
    win = points_window
    assert win.info_label.text() == "points: showing 100 of 300 rows"
    menu = [a.text() for a in win.data_table.actions() if not a.isSeparator()]
    assert menu[:2] == ["&Filter by this value", "C&lear filters"] and "&Copy value" in menu
    assert not win.clear_filters_action.isEnabled() and win.filters_bar.isHidden()

    # U18A nao esta nas 100 linhas carregadas: o filtro vai na consulta e acha as 50
    _reloaded(qtbot, win, lambda: win.add_filter("sigla", "U18A"))
    assert win.info_label.text() == "points: showing 50 of 50 rows matching (300 in the table)"
    assert set(_column(win, 1)) == {"U18A"}
    assert _chips(win) == ["Filter:", "sigla = 'U18A'  ×"]

    # clique direito na celula: a celula atual (NULL) vira "obs IS NULL" e soma com o primeiro filtro
    win.data_table.setCurrentIndex(win.data_proxy.index(0, 2))
    _reloaded(qtbot, win, win.filter_value_action.trigger)
    assert win.filters == [("sigla", "U18A"), ("obs", None)]
    assert win.info_label.text() == "points: showing 25 of 25 rows matching (300 in the table)"
    assert _chips(win) == ["Filters:", "sigla = 'U18A'  ×", "obs IS NULL  ×"]
    assert win.clear_filters_action.isEnabled() and not win.filters_bar.isHidden()

    # a pesquisa de palavras combina com o filtro, nas linhas carregadas
    win.search_edit.setText("298")
    qtbot.waitUntil(lambda: win.data_proxy.rowCount() == 1, timeout=5000)
    assert win.info_label.text() == "points: showing 1 of 1 row matching (300 in the table)"
    _reloaded(qtbot, win, win.search_edit.clear)  # a pesquisa vai no banco: limpar recarrega a tabela

    # remover um a um (botao do filtro) e limpar
    _reloaded(qtbot, win, win.filter_chips.itemAt(1).widget().click)
    assert win.filters == [("obs", None)]
    assert win.info_label.text() == "points: showing 100 of 150 rows matching (300 in the table)"  # limite Rows vale
    _reloaded(qtbot, win, win.clear_filters_button.click)
    assert win.filters == [] and _chips(win) == []
    assert win.info_label.text() == "points: showing 100 of 300 rows"


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
    assert win.info_label.text() == "other: showing 0 of 0 rows"
