from pathlib import Path

import pytest
from PyQt6.QtCore import QSettings, QSize, Qt
from PyQt6.QtGui import QGuiApplication, QTextCursor
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

    assert win.status_label.text() == f"File not found: {tmp_path / 'nope.duckdb'}"
    assert win.current_db_path is None
    win.open_database(tmp_path)  # uma pasta (o Go dava o texto do sistema, GetFileAttributesEx)
    assert win.status_label.text() == f"File not found: {tmp_path}" and win.current_db_path is None


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
    assert window.info_label.text() == "empty_table: 0 rows"
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
    assert window.info_label.text() == "people: rows 1 to 3 of 3"
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
    assert window.info_label.text() == "people: row 1 of 1 found"

    window.data_table.selectAll()
    window.copy_selection()
    assert QApplication.clipboard().text() == "10\tcarla\t7.25"


def test_top_bar_path_open_and_drop(qtbot, window: MainWindow, people_db: Path, tmp_path: Path) -> None:
    # linha de cima igual nas 4 versoes: caminho do arquivo aberto, Abrir... / Exportar... (BRIEF 14)
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
    assert window.current_db_path == people_db
    assert window.status_label.text() == f"File not found: {tmp_path / 'missing.duckdb'}"
    window.path_edit.setText(f'"{other}"')  # aspas do "Copiar como caminho" do Windows
    window.open_typed_action.trigger()  # Arquivo > Abrir o caminho digitado
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


def test_open_button_and_empty_enter_ask_for_the_file(window: MainWindow, people_db: Path, monkeypatch) -> None:
    # BRIEF 14: Abrir... = a caixa de escolher arquivo (Ctrl+O); Procurar... saiu; relativo nunca abre
    asked = []
    monkeypatch.setattr(QFileDialog, "getOpenFileName", lambda *a: asked.append(a) or ("", ""))
    top = [b.text() for b in window.top_bar.findChildren(QAbstractButton) if b.isVisible()]
    assert top == ["Open...", "Export..."] and window.open_button.toolTip().endswith("(Ctrl+O)")
    window.open_button.click()
    window.path_edit.setText("  ")
    window.path_edit.returnPressed.emit()
    assert len(asked) == 2 and window.current_db_path == people_db
    for typed in ("data", "people.duckdb"):  # nem a pasta do exe nem a de trabalho resolvem um caminho relativo
        window.path_edit.setText(typed)
        window.path_edit.returnPressed.emit()
        assert window.status_label.text() == f"File not found: {typed}"
        assert window.log_view.toPlainText().splitlines()[-1].endswith(f"File not found: {typed}")
    assert len(asked) == 2 and window.current_db_path == people_db
    window.release_database()
    window.reload_action.trigger()  # F5 sem banco aberto: a caixa, nunca um banco padrao
    assert len(asked) == 3 and window.current_db_path is None


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
              + window.limit_combo.parentWidget().sizeHint().width() + window.columns_button.sizeHint().width()
              + 3 * spacing + 12)
    wrapped = window.columns_button.y() > window.search_edit.geometry().bottom()
    assert wrapped == (needed > window.data_page.width())
    window.resize(1600, 800)  # mais largura: a mesma barra volta para uma linha so
    qtbot.waitUntil(lambda: window.columns_button.y() < window.search_edit.geometry().bottom(), timeout=3000)
    assert needed <= window.data_page.width()
    for toolbar in window.findChildren(QToolBar):  # nada escondido no "»" da barra de cima
        extension = toolbar.findChild(QAbstractButton, "qt_toolbar_ext_button")
        assert extension is None or not extension.isVisible()


def test_data_tab_has_one_line_then_filters_grid_and_table_line(qtbot, window: MainWindow) -> None:
    # aba Dados igual nas 4 (item 24): busca | Esta tabela | Todas as tabelas | Linhas | Colunas... numa linha so
    # (1280 px), a linha dos filtros so com filtro, a grade e a linha da tabela embaixo; nada mais
    _select_table(qtbot, window, "people")
    window.resize(1280, 800)
    QApplication.processEvents()
    line = [window.search_edit, *window.scope_buttons, window.limit_label, window.limit_combo, window.columns_button]
    xs = [w.mapTo(window.data_page, w.rect().topLeft()).x() for w in line]
    centers = {w.mapTo(window.data_page, w.rect().center()).y() // 8 for w in line}
    assert xs == sorted(xs) and len(centers) == 1  # nesta ordem, na mesma linha
    assert window.tabs.cornerWidget(Qt.Corner.TopRightCorner) is None  # Linhas nao fica mais ao lado das abas
    page = window.data_page.layout()
    widgets = [page.itemAt(i).widget() or page.itemAt(i).layout() for i in range(page.count())]
    assert widgets[1:] == [window.filters_bar, window.data_stack, window.info_row]
    # a linha da tabela, as paginas ◀ ▶ (13 h) e, so com marcadas, "So as marcadas"
    assert [window.info_row.itemAt(i).widget() for i in range(4)] == [window.info_label, *window.page_buttons,
                                                                     window.only_marked_box]
    assert window.filters_bar.isHidden()
    _reloaded(qtbot, window, lambda: window.add_filter("name", "Ana"))
    assert not window.filters_bar.isHidden()
    assert window.info_label.text() == "people: row 1 of 1 found"


def test_long_bottom_bar_message_wraps_instead_of_being_cut(qtbot, window: MainWindow) -> None:
    # janela estreita: a mensagem longa (caminho sem espacos) quebra a linha e a barra cresce so o necessario;
    # Copiar e os testes leem o texto como ele e
    long = r"1 linha exportada para C:\Users\x\Downloads\Temp\mdb2sql_pendencias_2026-11-24\padrao\export\found.csv"
    window.resize(720, 800)
    qtbot.waitUntil(lambda: window.width() == 720, timeout=3000)
    window._set_message(window.status_label, "Loaded: people.duckdb (2 tables)")
    QApplication.processEvents()
    one_line = window.status_label.height()
    window._set_message(window.status_label, long)
    qtbot.waitUntil(lambda: window.status_label.height() > one_line, timeout=3000)
    label = window.status_label
    assert label.text() == long and label.toolTip() == long
    lines = label.fontMetrics().boundingRect(0, 0, label.width(), 10**5, Qt.TextFlag.TextWordWrap.value,
                                             label.text().replace(chr(92), chr(92) + chr(0x200b))).height()
    assert label.height() == lines > one_line  # as linhas que o texto pede, sem sobra
    window._set_message(window.status_label, "Loaded: people.duckdb (2 tables)")
    qtbot.waitUntil(lambda: window.status_label.height() == one_line, timeout=3000)


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

    assert window.info_label.text() == "people: rows 1 to 3 of 3"


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


def _tree(menu) -> list:
    """Itens de um menu: '-' (separador), 'texto Atalho' ou ('submenu', [itens]); sem os & dos atalhos de letra."""
    items: list = []
    for action in menu.actions():
        text = action.text().replace("&", "")
        if action.isSeparator():
            items.append("-")
        elif action.menu():
            items.append((text, _tree(action.menu())))
        else:
            items.append(f"{text} {action.shortcut().toString()}".strip())
    return items


def test_menu_tree_is_the_same_in_the_four_versions(window: MainWindow) -> None:
    # secao 4 do brief 27-33: todo botao tem menu; arvore igual nas 4 versoes, nesta ordem
    titles = [a.text() for a in window.menuBar().actions()]
    assert titles == ["&File", "&Edit", "&View", "&Settings", "&Help"]
    formats = ["CSV...", "Excel (.xlsx)..."]
    export = [("Current table", formats), ("Marked rows", formats), ("Current table schema", formats),
              ("Database schema", formats), "All tables to CSV (one file per table)...", ("SQL result", formats),
              "All-tables search result (Excel)...",
              ("Advanced Search report", ["Excel (.xlsx)...", "CSV...", "SQLite (.sqlite)...", "DuckDB (.duckdb)..."])]
    assert _tree(_menu(window, "&File")) == [
        "Open... Ctrl+O", "Open the typed path", "Reopen F5", "-", "Save Ctrl+S", "Save as... Ctrl+Shift+S",
        ("Export", export), "-", "Close Ctrl+W", "-", "Exit Ctrl+Q"]
    assert _tree(window.export_menu) == export  # o botao Exportar... abre o mesmo menu
    assert _tree(_menu(window, "&Edit")) == [
        "Copy value Ctrl+C", "Copy row Ctrl+Shift+C", "Copy row with header", "Copy the whole log", "-",
        "Search Ctrl+F", "Filter by this value", "Clear filters", "-", "Mark or unmark row Space", "Unmark all rows"]
    assert _tree(_menu(window, "&View")) == [
        "Data Ctrl+1", "Schema Ctrl+2", "SQL Ctrl+3", "Advanced Search Ctrl+4", "-", ("Rows", ["100", "500", "1000"]),
        "Columns...", ("Search in", ["This table", "All tables"]), "Only marked rows", "Go to the table list Ctrl+T",
        "Favorite or unfavorite table Ctrl+D", "-", "Run SQL Ctrl+Enter", "Search terms Ctrl+Enter", "-", "Log Ctrl+L"]
    assert _tree(_menu(window, "&Settings")) == [
        ("Theme", ["System", "Light", "Dark"]), ("Language", ["English", "Português (Brasil)", "Español"]),
        ("Default search scope", ["This table", "All tables"]), ("Term matching", ["Whole value", "Contains"]),
        "Show NULL"]
    assert _tree(_menu(window, "&Help")) == ["About mdb2sql"]
    # sai o "Painel de tabelas" (Ctrl+B) e o X do painel: ele nao fecha
    from PyQt6.QtWidgets import QDockWidget

    assert window.tables_dock.features() == QDockWidget.DockWidgetFeature.NoDockWidgetFeatures
    assert window.export_button.isEnabled()


def test_schema_tab_is_called_schema_in_every_language(window: MainWindow) -> None:
    # 13 c): "Schema" nos 3 idiomas: a aba, Exibir e os dois itens de Exportar; nenhum "Esquema" na tela
    from shared import i18n

    for code, table_schema, db_schema in (("pt_BR", "Schema da tabela atual", "Schema do banco"),
                                          ("es", "Schema de la tabla actual", "Schema de la base de datos"),
                                          ("en", "Current table schema", "Database schema")):
        window.set_language(code)
        assert window.tabs.tabText(1) == "Schema" and window.schema_tab_action.text().replace("&", "") == "Schema"
        assert {table_schema, db_schema} <= {a.text() for a in window.export_menu.actions()}
        assert not [key for key, text in i18n.catalog(code).items() if "squema" in text.lower()]


def test_terms_tab_is_called_advanced_search_in_every_language(window: MainWindow) -> None:
    # 13 d): a aba, Exibir (Ctrl+4) e Exportar > Relatorio; o botao da aba e "Pesquisar" (BRIEF 21)
    for code, tab, report, button in (("pt_BR", "Pesquisa Avançada", "Relatório da Pesquisa Avançada", "Pesquisar"),
                                      ("es", "Búsqueda Avanzada", "Informe de la Búsqueda Avanzada", "Buscar"),
                                      ("en", "Advanced Search", "Advanced Search report", "Search")):
        window.set_language(code)
        assert window.tabs.tabText(3) == tab == window.terms_tab_action.text().replace("&", "")
        assert window.terms_tab_action.shortcut().toString() == "Ctrl+4"
        assert report in {a.text() for a in window.export_menu.actions()} and window.terms_run_button.text() == button


def test_terms_box_background_text_has_the_example_in_separate_lines(window: MainWindow) -> None:
    # 13 e): o texto de fundo da caixa de termos, com texto1 / texto2 / texto3 em linhas separadas
    window.set_language("pt_BR")
    assert window.terms_edit.placeholderText().split("\n") == [
        "Cole os termos, um por linha (por exemplo, uma coluna do Excel). Exemplo:", "texto1", "texto2", "texto3",
        "pesquisa os 3 termos em todas as tabelas ou só na tabela selecionada."]
    window.set_language("en")
    assert window.terms_edit.placeholderText().split("\n")[1:4] == ["text1", "text2", "text3"]
    # cabem as 5 linhas: a caixa tem ~8 linhas de altura
    assert window.terms_edit.height() >= 5 * window.terms_edit.fontMetrics().lineSpacing()


def test_advanced_search_layout(qtbot, window: MainWindow) -> None:
    # BRIEF 21: abaixo da caixa "N linhas de entrada" a esquerda; a direita Valor inteiro | Contem, linha fina, Esta
    # tabela | Todas as tabelas, linha fina, Pesquisar (por ultimo, encostado a direita); o resumo e a 1a linha da area
    # do resultado; barra de saida embaixo a direita: Copiar linhas, Salvar/Exportar..., Limpar
    from PyQt6.QtWidgets import QFrame, QToolButton

    window.resize(1280, 800)
    window.tabs.setCurrentWidget(window.terms_page)
    window.terms_edit.setPlainText("a\nb\nA\n")
    QApplication.processEvents()
    page = window.terms_page
    assert window.terms_count.text() == "3 input lines" and window.terms_run_button.text() == "Search"
    buttons = [next(b for b in page.findChildren(QToolButton) if b.defaultAction() is a)
               for a in (*window.match_actions.values(), *window.terms_scope_actions.values())]
    line = [window.terms_count, *buttons, window.terms_run_button]
    xs = [w.mapTo(page, w.rect().topLeft()).x() for w in line]
    assert xs == sorted(xs) and len({w.mapTo(page, w.rect().center()).y() // 8 for w in line}) == 1
    run = window.terms_run_button
    assert run.mapTo(page, run.rect().topRight()).x() >= page.width() - 12  # Pesquisar encostado a direita
    lines = [f for f in page.findChildren(QFrame) if f.frameShape() == QFrame.Shape.VLine and f.isVisible()]
    assert len(lines) == 2
    box = window.terms_summary.parentWidget()
    assert isinstance(box, QFrame)  # o resumo e os nao encontrados dentro da area do resultado (como nas outras 3)
    assert window.not_found_edit.parentWidget() is box and window.not_found_title.parentWidget() is box
    out = [window.terms_copy_rows_button, window.terms_export_button]
    assert [b.text() for b in out] == ["Copy rows", "Save/Export..."] and not any(b.isEnabled() for b in out)
    assert window.terms_export_button.menu() is window.terms_report_menu


def test_enter_searches_and_ctrl_enter_breaks_the_line_in_the_terms_box(qtbot, window: MainWindow,
                                                                        monkeypatch) -> None:
    # BRIEF 21 (dono 26/11): Enter pesquisa; Ctrl+Enter quebra a linha
    from PyQt6.QtTest import QTest

    runs = []
    monkeypatch.setattr(window, "run_terms", lambda: runs.append(1))
    window.tabs.setCurrentWidget(window.terms_page)
    window.terms_edit.setFocus()
    window.terms_edit.setPlainText("a")
    window.terms_edit.moveCursor(QTextCursor.MoveOperation.End)
    QTest.keyClick(window.terms_edit, Qt.Key.Key_Return, Qt.KeyboardModifier.ControlModifier)
    assert window.terms_edit.toPlainText() == "a\n" and runs == []
    QTest.keyClick(window.terms_edit, Qt.Key.Key_Return)
    assert runs == [1] and window.terms_edit.toPlainText() == "a\n"


def test_buttons_of_a_row_have_one_height_and_do_not_touch_the_boxes(qtbot, window: MainWindow) -> None:
    # 13 f): numa linha, todos os botoes da mesma altura (o Pesquisar termos e o Executar eram maiores); nenhum encosta
    # na caixa de cima ou de baixo
    from PyQt6.QtWidgets import QToolButton

    window.resize(1280, 800)
    for page in (window.data_page, window.terms_page, window.sql_page):
        window.tabs.setCurrentWidget(page)
        QApplication.processEvents()
        buttons = [b for b in page.findChildren(QAbstractButton) if b.isVisible() and b.text()]
        assert buttons and all(isinstance(b, QToolButton) for b in buttons), page
        rows: dict[int, set[int]] = {}
        for button in buttons:
            center = button.mapTo(page, button.rect().center()).y()
            rows.setdefault(center // 6, set()).add(button.height())
        assert all(len(heights) == 1 for heights in rows.values()), rows
    window.tabs.setCurrentWidget(window.terms_page)
    QApplication.processEvents()

    def top(widget) -> int:
        return widget.mapTo(window.terms_page, widget.rect().topLeft()).y()

    assert top(window.terms_run_button) > top(window.terms_edit) + window.terms_edit.height()
    window.tabs.setCurrentWidget(window.sql_page)
    QApplication.processEvents()
    run = next(b for b in window.sql_page.findChildren(QToolButton) if b.isVisible())
    edit_bottom = window.sql_edit.mapTo(window.sql_page, window.sql_edit.rect().bottomLeft()).y()
    assert run.mapTo(window.sql_page, run.rect().topLeft()).y() > edit_bottom


def test_copy_the_whole_log_in_spanish_says_log(window: MainWindow) -> None:
    # 13 g): "Copiar todo el log" (a aba se chama Log nos 3 idiomas)
    window.set_language("es")
    assert window.copy_log_action.text().replace("&", "") == "Copiar todo el log"
    assert window.log_action.text().replace("&", "") == "Log"


def test_menu_items_are_disabled_like_their_buttons(qtbot, window: MainWindow) -> None:
    # Linhas do menu = lista Linhas da aba Dados; Pesquisar em = Esta tabela | Todas as tabelas
    window.rows_actions[2].trigger()
    assert window.limit_combo.currentData() == 1000
    window.limit_combo.setCurrentIndex(0)
    assert window.rows_actions[0].isChecked()
    assert window.scope_actions["table"].isChecked()
    # sem consulta SQL, marcas, busca em todas as tabelas ou termos: os submenus e itens ficam desabilitados
    disabled = [a.text().replace("&", "") for a in window.export_menu.actions() if not a.isEnabled()]
    assert disabled == ["Marked rows", "SQL result", "All-tables search result (Excel)...", "Advanced Search report"]
    window.scope_actions["all"].trigger()
    window.search_edit.setText("ana")
    qtbot.waitUntil(lambda: window.found_list.count() == 1 and window._busy == 0, timeout=30000)
    assert window.export_search_action.isEnabled()
    window.log("line one")
    window.copy_log_action.trigger()
    assert QApplication.clipboard().text().endswith("line one")
    window.release_database()  # sem banco: so Abrir, Abrir o caminho digitado, Reabrir e Sair
    assert not window.export_button.isEnabled() and not any(a.isEnabled() for a in window.export_menu.actions())
    assert window.open_typed_action.isEnabled() and not window.save_action.isEnabled()


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


def test_selected_cell_text_uses_the_highlighted_text_color(window: MainWindow) -> None:
    # windows11 escrevia a celula selecionada com a cor de texto (preto sobre azul escuro no tema claro): as grades
    # usam a cor de texto destacado da paleta na celula selecionada, legivel nos dois temas
    from PyQt6.QtGui import QColor, QPalette
    from PyQt6.QtWidgets import QStyle, QStyleOptionViewItem

    for view in (window.data_table, window.schema_table, window.sql_table):
        delegate = view.itemDelegate()
        option = QStyleOptionViewItem()
        option.palette = QPalette(QApplication.palette())
        option.palette.setColor(QPalette.ColorRole.Text, QColor("#000000"))
        option.palette.setColor(QPalette.ColorRole.HighlightedText, QColor("#ffffff"))
        option.state |= QStyle.StateFlag.State_Selected
        delegate.initStyleOption(option, window.table_model.index(0, 0))
        for group in (QPalette.ColorGroup.Active, QPalette.ColorGroup.Inactive):
            assert option.palette.color(group, QPalette.ColorRole.Text).name() == "#ffffff"
        option.state &= ~QStyle.StateFlag.State_Selected  # sem selecao: a cor de texto normal
        option.palette.setColor(QPalette.ColorRole.Text, QColor("#000000"))
        delegate.initStyleOption(option, window.table_model.index(0, 0))
        assert option.palette.color(QPalette.ColorRole.Text).name() == "#000000"


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
    assert window.info_label.text() == "people: row 1 of 1 found"

    # sem resultado: lista vazia; escopo padrao em Configuracoes, gravado e ja valendo na tela
    window.default_scope_actions["all"].trigger()
    assert QSettings().value("search_scope") == "all" and window.scope_actions["all"].isChecked()
    window.search_edit.setText("zzz")
    qtbot.waitUntil(lambda: window.info_label.text() == '0 tables with rows matching "zzz"', timeout=30000)
    assert window.found_list.count() == 0
    again = MainWindow()
    qtbot.addWidget(again)
    assert again.scope_actions["all"].isChecked() and again.default_scope_actions["all"].isChecked()


def test_data_search_starts_in_all_tables(qtbot, tmp_path: Path) -> None:
    # BRIEF 18 a: sem nada gravado, a busca da aba Dados comeca em Todas as tabelas: o texto que so existe em outras
    # tabelas aparece com a 1a tabela aberta, sem mexer em nada (com Esta tabela o dono nao achava nada)
    import duckdb

    QSettings().remove("search_scope")  # o padrao de fabrica
    db_file = tmp_path / "plant.duckdb"
    with duckdb.connect(str(db_file)) as conn:
        conn.execute("CREATE TABLE accu AS SELECT 'MEDICION ENERGIA' AS pntnam")
        conn.execute("CREATE TABLE soeqid AS SELECT * FROM (VALUES ('GENERADOR CGS 1'), ('GENERADOR CGS 1 B'))"
                     " t(pntnam)")
        conn.execute("CREATE TABLE sostat AS SELECT * FROM (VALUES (50, 'GENERADOR CGS 1'), (50, 'GENERADOR CGS 1'),"
                     " (50, 'OTRO')) t(rtuno, pntnam)")
    win = MainWindow()
    qtbot.addWidget(win)
    win.open_database(db_file)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=30000)
    assert win.loaded_table[0] == "accu" and win.scope_actions["all"].isChecked()
    assert win.default_scope_actions["all"].isChecked()
    win.search_edit.setText("GENERADOR CGS 1")
    qtbot.waitUntil(lambda: win.found_list.count() == 2 and win._busy == 0, timeout=30000)
    assert [win.found_list.item(row).text() for row in range(2)] == ["soeqid (2)", "sostat (2)"]


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
    assert window.info_label.text() == "a: 0 rows" and not window.progress.isVisible()


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


def test_sql_tab_refuses_a_command_that_is_not_a_read(qtbot, window: MainWindow) -> None:
    # so leitura nas 4 versoes: a recusa aparece como esta (sem o prefixo de erro do banco) e a grade velha sai
    window.sql_edit.setPlainText("SELECT name FROM people")
    window.run_sql()
    qtbot.waitUntil(lambda: window.sql_model.rowCount() == 3 and window._busy == 0, timeout=30000)
    window.sql_edit.setPlainText("CREATE TABLE made AS SELECT 1 AS a")
    window.run_sql()
    refused = "The SQL tab only reads the database: this command is not allowed"
    qtbot.waitUntil(lambda: window._busy == 0 and window.sql_info.text() == refused, timeout=30000)
    assert window.status_label.text() == refused and window.sql_model.rowCount() == 0 and window.sql_query is None
    assert "made" not in window.manager.list_tables()
    window.sql_edit.setPlainText("SELECT * FROM made")
    window.run_sql()
    qtbot.waitUntil(lambda: window._busy == 0 and "made" in window.sql_info.text(), timeout=30000)
    assert window.sql_info.text().startswith("SQL query error:")  # a tabela nao foi criada


def test_save_and_export_actions_write_files_next_to_source(qtbot, window: MainWindow, people_db: Path, monkeypatch) -> None:
    asked, picked = [], []

    def fake_save(_parent, title, suggested, types, chosen):
        asked.append((title, Path(suggested), types, chosen))
        if picked:  # Salvar: o nome sugerido como veio e o tipo escolhido na caixa
            return suggested, picked[0]
        return str(people_db.parent / f"out{Path(suggested).suffix}"), ""

    monkeypatch.setattr(QFileDialog, "getSaveFileName", fake_save)
    _select_table(qtbot, window, "people")
    assert not any(a.isEnabled() for a in window.export_sql_actions)  # sem consulta SQL ainda
    window.sql_edit.setPlainText("SELECT name FROM people")
    window.run_sql()
    qtbot.waitUntil(lambda: window.sql_model.rowCount() == 3 and window._busy == 0, timeout=30000)

    def done() -> None:
        qtbot.waitUntil(lambda: window.status_label.text().startswith("Export") and window._job is None, timeout=60000)
        assert window.status_label.text().startswith("Exported"), window.status_label.text()
        window.status_label.setText("")

    # Arquivo > Salvar (item 28): o banco inteiro em SQLite, DuckDB ou Excel; o tipo do aberto (DuckDB) ja marcado e
    # o proprio arquivo aberto nunca sugerido
    types = ["SQLite database (*.sqlite)", "DuckDB database (*.duckdb)", "Excel workbook (*.xlsx)"]
    assert window.save_action.shortcut().toString() == "Ctrl+S" and window.save_as_action.shortcut().toString() == "Ctrl+Shift+S"
    # o primeiro Salvar como... (nenhuma pasta usada ainda) abre na pasta do original, nao na pasta de trabalho
    picked[:] = [types[1]]
    window.save_as_action.trigger()
    done()
    assert asked == [("Save as SQLite, DuckDB or Excel (.mdb and .accdb files cannot be written)",
                      people_db.parent / "people (copy).duckdb", ";;".join(types), types[1])]
    asked.clear()
    for kind in types:
        picked[:] = [kind]
        window.save_action.trigger()
        done()
    assert asked == [("Save as SQLite, DuckDB or Excel (.mdb and .accdb files cannot be written)",
                      people_db.parent / "people (copy).duckdb", ";;".join(types), types[1])] * 3
    assert sorted(p.name for p in people_db.parent.glob("people (copy).*")) == [
        "people (copy).duckdb", "people (copy).sqlite", "people (copy).xlsx"]
    # Salvar sobre o proprio arquivo aberto: recusado
    monkeypatch.setattr(QFileDialog, "getSaveFileName", lambda *_a: (str(people_db), ""))
    window.save_action.trigger()
    qtbot.waitUntil(lambda: window.status_label.text().startswith("Export failed") and window._job is None, timeout=60000)
    assert window.status_label.text() == "Export failed: The output file is the open database; choose another name"
    window.set_log_visible(True)  # erro lido: a barra volta a mostrar a ultima acao
    window.set_log_visible(False)
    monkeypatch.setattr(QFileDialog, "getSaveFileName", fake_save)

    # Exportar: tabela atual e resultado do SQL, para CSV e Excel (os 3 "Banco para ..." sairam: sao o Salvar)
    asked.clear()
    picked.clear()
    actions = window.export_table_actions + window.export_sql_actions
    assert [a.text().replace("&", "") for a in actions] == ["CSV...", "Excel (.xlsx)..."] * 2
    for action in actions:
        action.trigger()
        done()

    # pasta sugerida = pasta do banco aberto; resultado SQL = query.csv (nas 4)
    assert [a[1].parent for a in asked] == [people_db.parent] * 4
    assert [a[1].name for a in asked] == ["people.csv", "people.xlsx", "query.csv", "query.xlsx"]
    assert sorted(p.name for p in people_db.parent.glob("out.*")) == ["out.csv", "out.xlsx"]
    assert QSettings().value("last_dir") == str(people_db.parent)
    # cada exportacao fecha e apaga o seu dialogo "Export": nenhum fica acumulado na janela
    qtbot.waitUntil(lambda: not window.findChildren(QProgressDialog), timeout=5000)


def test_schema_all_tables_csv_and_search_result_exports(qtbot, window: MainWindow, people_db: Path,
                                                         monkeypatch) -> None:
    # Exportar: esquema da tabela (<tabela>_schema), do banco (<banco>_schema), todas as tabelas em CSV (pasta, uma
    # pergunta para os que ja existem) e o resultado da busca em todas as tabelas (<banco>_busca.xlsx)
    import openpyxl

    out_dir = people_db.parent
    asked = []
    monkeypatch.setattr(QFileDialog, "getSaveFileName",
                        lambda *a: asked.append((a[1], Path(a[2]).name)) or (str(out_dir / Path(a[2]).name), ""))
    _select_table(qtbot, window, "people")

    def exported(action) -> None:
        action.trigger()
        qtbot.waitUntil(lambda: window._job is None and window._busy == 0, timeout=30000)

    exported(window.export_table_schema_actions[0])
    exported(window.export_db_schema_actions[1])
    assert asked == [("Current table schema", "people_schema.csv"), ("Database schema", "people_schema.xlsx")]
    assert (out_dir / "people_schema.csv").read_text(encoding="utf-8-sig").splitlines()[:2] == [
        "Column,Type,Nullable", "id,INTEGER,No"]
    book = openpyxl.load_workbook(out_dir / "people_schema.xlsx", read_only=True)
    assert next(book.active.iter_rows(values_only=True)) == ("Table", "Column", "Type", "Nullable")
    book.close()

    folder = out_dir / "all"
    folder.mkdir()
    (folder / "people.csv").write_text("old", encoding="utf-8")
    monkeypatch.setattr(QFileDialog, "getExistingDirectory", lambda *a: str(folder))
    counts = []
    monkeypatch.setattr(window, "ask_overwrite_many", lambda count: counts.append(count) or True)
    exported(window.export_all_csv_action)
    assert counts == [1] and sorted(p.name for p in folder.iterdir()) == ["empty_table.csv", "people.csv"]
    assert (folder / "people.csv").read_text(encoding="utf-8-sig").startswith("id,name,score")

    window.scope_actions["all"].trigger()
    window.search_edit.setText("ana")
    qtbot.waitUntil(lambda: window.found_list.count() == 1 and window._busy == 0, timeout=30000)
    exported(window.export_search_action)
    assert asked[-1] == ("All-tables search result (Excel)", "people_busca.xlsx")
    book = openpyxl.load_workbook(out_dir / "people_busca.xlsx", read_only=True)
    assert book.sheetnames == ["people"]
    assert list(book["people"].iter_rows(values_only=True)) == [("id", "name", "score"), (1, "Ana", 9.5)]
    book.close()


def test_overwrite_many_question_has_the_right_plural(qtbot, window: MainWindow) -> None:
    from PyQt6.QtCore import QTimer
    from PyQt6.QtWidgets import QMessageBox

    seen = []

    def answer() -> None:
        box = QApplication.activeModalWidget()
        seen.append(box.text())
        box.button(QMessageBox.StandardButton.No).click()

    for count in (1, 3):
        QTimer.singleShot(0, answer)
        assert window.ask_overwrite_many(count) is False
    assert seen == ["1 file already exists in this folder. Replace it?",
                    "3 files already exist in this folder. Replace them?"]


def test_favorite_tables_go_to_the_top_in_alphabetical_order(qtbot, tmp_path: Path) -> None:
    # item 34: clique direito / Exibir (Ctrl+D); "★ " no nome; favoritas no topo, alfabeticas; filtro vale; pelo nome,
    # so na memoria (outro arquivo e F5 mantem; nome ausente nao aparece)
    import duckdb

    first, second = tmp_path / "a.duckdb", tmp_path / "b.duckdb"
    with duckdb.connect(str(first)) as conn:
        for name in ("t_c", "t_a", "t_d", "t_b"):
            conn.execute(f"CREATE TABLE {name} (x INTEGER)")
    with duckdb.connect(str(second)) as conn:
        for name in ("t_b", "other"):
            conn.execute(f"CREATE TABLE {name} (x INTEGER)")
    win = MainWindow()
    qtbot.addWidget(win)
    win.show()
    win.open_database(first)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=30000)

    def shown() -> list[str]:
        return [win.table_list.topLevelItem(i).text(0) for i in range(win.table_list.topLevelItemCount())]

    assert shown() == ["t_a", "t_b", "t_c", "t_d"] and win.loaded_table[0] == "t_a"
    request = win._table_request
    menu = win.tables_menu("t_d")  # clique direito numa tabela
    assert [a.text() for a in menu.actions()] == ["Add to favorites"]
    menu.actions()[0].trigger()
    win.toggle_favorite("t_b")
    assert shown() == ["★ t_b", "★ t_d", "t_a", "t_c"] and win.table_names() == ["t_b", "t_d", "t_a", "t_c"]
    # a tabela atual continua a atual, sem recarregar a grade
    assert win._table_of(win.table_list.currentItem()) == "t_a" and win._table_request == request
    assert not win.table_load_timer.isActive()
    assert [a.text() for a in win.tables_menu("t_b").actions()] == ["Remove from favorites"]
    assert win.favorite_action.shortcut().toString() == "Ctrl+D"
    win.favorite_action.trigger()  # Exibir > Favoritar ou desfavoritar tabela: a tabela atual
    assert shown() == ["★ t_a", "★ t_b", "★ t_d", "t_c"]
    win.table_filter.setText("d")  # o filtro olha o nome (sem a estrela) e vale para as favoritas
    win._filter_tables_now()
    assert [win.table_list.topLevelItem(i).isHidden() for i in range(4)] == [True, True, False, True]

    win.open_database(second)  # outro arquivo: as favoritas pelo nome; t_a e t_d nao existem nele
    qtbot.waitUntil(lambda: win.current_db_path == second and win.loaded_table is not None and win._busy == 0,
                    timeout=30000)
    assert shown() == ["★ t_b", "other"] and win.loaded_table[0] == "t_b"  # a primeira da lista abre
    win.reload_action.trigger()  # F5 mantem
    qtbot.waitUntil(lambda: win._busy == 0 and win.loaded_table is not None, timeout=30000)
    assert shown() == ["★ t_b", "other"]
    win.release_database()
    win.open_database(first)
    qtbot.waitUntil(lambda: win.current_db_path == first and win.loaded_table is not None and win._busy == 0,
                    timeout=30000)
    assert shown() == ["★ t_a", "★ t_b", "★ t_d", "t_c"]
    assert not [key for key in QSettings().allKeys() if "fav" in key.lower()]  # nada nas configuracoes


def test_data_tab_pages_with_previous_and_next(qtbot, tmp_path: Path) -> None:
    # 13 h): paginas do tamanho de Linhas; ◀ ▶ desabilitados na ponta; ultima pagina incompleta; busca e filtro em
    # todas as paginas; trocar a busca volta a pagina 1; as marcadas no topo de toda pagina
    import duckdb

    db_file = tmp_path / "big.duckdb"
    with duckdb.connect(str(db_file)) as conn:
        conn.execute("CREATE TABLE big AS SELECT i AS id, CASE WHEN i % 2 = 0 THEN 'even' ELSE 'odd' END AS kind"
                     " FROM range(2550) r(i) ORDER BY i")
    win = MainWindow()
    qtbot.addWidget(win)
    win.show()
    win.open_database(db_file)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=30000)
    previous, following = win.page_buttons
    assert [previous.text(), following.text()] == ["◀", "▶"] and previous.toolTip() == "Previous page"
    _reloaded(qtbot, win, lambda: win.limit_combo.setCurrentIndex(2))  # 1000 linhas por pagina

    def state() -> tuple[str, str, int, bool, bool]:
        return (win.info_label.text(), win.data_proxy.index(0, 0).data(), win.data_proxy.rowCount(),
                previous.isEnabled(), following.isEnabled())

    assert state() == ("big: rows 1 to 1,000 of 2,550", "0", 1000, False, True)
    _reloaded(qtbot, win, following.click)
    assert state() == ("big: rows 1,001 to 2,000 of 2,550", "1000", 1000, True, True)
    _reloaded(qtbot, win, following.click)
    assert state() == ("big: rows 2,001 to 2,550 of 2,550", "2000", 550, True, False)  # a ultima, incompleta
    win.data_table.setCurrentIndex(win.data_proxy.index(549, 0))  # id 2549
    win.mark_action.trigger()
    _reloaded(qtbot, win, previous.click)
    assert state() == ("big: rows 1,001 to 2,000 of 2,550, 1 marked", "2549", 1001, True, True)  # marcada no topo
    assert win.data_proxy.index(1, 0).data() == "1000"

    win.search_edit.setText("odd")  # busca nova: pagina 1, em todas as paginas
    _reloaded(qtbot, win, win.search_timer.timeout.emit)
    assert state() == ("big: rows 1 to 1,000 of 1,275 found, 1 marked", "2549", 1001, False, True)
    _reloaded(qtbot, win, following.click)
    assert state() == ("big: rows 1,001 to 1,275 of 1,275 found, 1 marked", "2549", 275, True, False)
    _reloaded(qtbot, win, lambda: win.limit_combo.setCurrentIndex(0))  # trocar Linhas tambem volta a pagina 1
    assert state()[0] == "big: rows 1 to 100 of 1,275 found, 1 marked" and not previous.isEnabled()


def test_marked_rows_stay_on_top_during_other_searches(qtbot, tmp_path: Path, monkeypatch) -> None:
    # item 31, o exemplo do dono: busca kkk, marca 1 de 3; busca jjj (a de kkk no topo), marca 1; busca hhh, marca 1:
    # 3 marcadas no topo, na ordem da tabela
    import csv

    import duckdb

    db_file = tmp_path / "marks.duckdb"
    with duckdb.connect(str(db_file)) as conn:
        conn.execute("CREATE TABLE t AS SELECT i AS id, ['kkk', 'jjj', 'hhh', 'zzz'][i % 4 + 1] AS word"
                     " FROM range(12) r(i) ORDER BY i")
        conn.execute("CREATE TABLE u (x INTEGER)")
    win = MainWindow()
    qtbot.addWidget(win)
    win.show()
    win.open_database(db_file)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=30000)
    _select_table(qtbot, win, "t")
    mark = win.table_model.mark_column()
    header = win.data_table.horizontalHeader()
    # caixa de marcar primeiro, estreita, sem titulo, com a dica; as colunas da tabela na ordem
    assert [header.logicalIndex(v) for v in range(3)] == [mark, 0, 1] and win.data_table.columnWidth(mark) < 40
    assert win.table_model.headerData(mark, Qt.Orientation.Horizontal) is None
    assert win.table_model.headerData(mark, Qt.Orientation.Horizontal, Qt.ItemDataRole.ToolTipRole) == "Mark rows"
    assert win.mark_action.shortcut().toString() == "Space"
    assert win.mark_action.shortcutContext() == Qt.ShortcutContext.WidgetWithChildrenShortcut
    assert not win.unmark_all_action.isEnabled() and win.only_marked_box.isHidden()

    def search(text: str) -> list[str]:
        win.search_edit.setText(text)
        _reloaded(qtbot, win, win.search_timer.timeout.emit)
        return _column(win, 0)

    def checked() -> list[bool]:
        proxy = win.data_proxy
        return [proxy.index(r, mark).data(Qt.ItemDataRole.CheckStateRole) == Qt.CheckState.Checked
                for r in range(proxy.rowCount())]

    assert search("kkk") == ["0", "4", "8"]
    assert win.data_proxy.setData(win.data_proxy.index(1, mark), Qt.CheckState.Checked.value,
                                  Qt.ItemDataRole.CheckStateRole)  # clique na caixa
    assert checked() == [False, True, False]
    assert win.info_label.text() == "t: rows 1 to 3 of 3 found, 1 marked" and not win.only_marked_box.isHidden()
    assert search("jjj") == ["4", "1", "5", "9"]
    win.data_table.setCurrentIndex(win.data_proxy.index(2, 0))
    win.mark_action.trigger()  # Espaco / Editar / menu da celula
    assert search("hhh") == ["4", "5", "2", "6", "10"]
    win.data_table.setCurrentIndex(win.data_proxy.index(3, 1))
    win.mark_action.trigger()
    assert search("hhh") == ["4", "5", "6", "2", "10"] and checked() == [True, True, True, False, False]
    assert win.info_label.text() == "t: rows 1 to 3 of 3 found, 3 marked"

    # So as marcadas (caixa ao lado da linha = Exibir > So as linhas marcadas)
    _reloaded(qtbot, win, win.only_marked_box.click)
    assert _column(win, 0) == ["4", "5", "6"] and win.only_marked_action.isChecked()
    assert win.info_label.text() == "t: rows 1 to 3 of 3, 3 marked"

    # copiar a linha nao leva a caixa; exportar: as marcadas, todas as colunas, ordem da tabela, <tabela>_marcadas
    win.data_table.selectRow(0)
    win.copy_row_action.trigger()
    assert QApplication.clipboard().text() == "4\tkkk"
    out = tmp_path / "out.csv"
    asked = []
    monkeypatch.setattr(QFileDialog, "getSaveFileName", lambda *a: asked.append(Path(a[2]).name) or (str(out), ""))
    win.export_marked_actions[0].trigger()
    qtbot.waitUntil(lambda: win._job is None and out.exists(), timeout=30000)
    with open(out, encoding="utf-8-sig", newline="") as handle:
        assert list(csv.reader(handle)) == [["id", "word"], ["4", "kkk"], ["5", "jjj"], ["6", "hhh"]]
    assert asked == ["t_marcadas.csv"]

    # marcas por tabela; "So as marcadas" vale so na tabela em que foi ligado; a coluna oculta "word" (posicao 1)
    # nao esconde a caixa de marcar de "u" (tambem na posicao 1)
    win.set_hidden_columns({"word"})
    _select_table(qtbot, win, "u")
    assert win.marks["t"] and not win.marks.get("u") and win.only_marked_box.isHidden()
    assert not win.only_marked_action.isChecked() and not win.data_table.isColumnHidden(win.table_model.mark_column())
    _select_table(qtbot, win, "t")
    _reloaded(qtbot, win, win.only_marked_box.click)
    # a coluna 1 era a caixa de marcar de "u" (estreita, fixa): em "t" volta a ser uma coluna comum, no lugar dela
    from PyQt6.QtWidgets import QHeaderView

    assert [header.logicalIndex(v) for v in range(3)] == [2, 0, 1]
    assert [header.sectionResizeMode(c) for c in range(3)] == [QHeaderView.ResizeMode.Interactive] * 2 + [
        QHeaderView.ResizeMode.Fixed]
    _reloaded(qtbot, win, win.unmark_all_action.trigger)
    assert _column(win, 0) == ["2", "6", "10"] and not win.only_marked_action.isChecked()
    assert win.only_marked_box.isHidden() and not win.export_marked_actions[0].isEnabled()

    # reabrir (F5) limpa as marcas
    win.data_table.setCurrentIndex(win.data_proxy.index(0, 0))
    win.mark_action.trigger()
    assert win.marks["t"]
    win.reload_action.trigger()
    qtbot.waitUntil(lambda: win._busy == 0 and win.loaded_table is not None, timeout=30000)
    assert win.marks.get("t", set()) == set() and win.table_model.marks == set()


def test_terms_tab_lists_hits_in_list_order_copies_and_reports(qtbot, tmp_path: Path, monkeypatch) -> None:
    # item 32: lista colada, Valor inteiro, Todas as tabelas; tabelas com acerto, grade, nao encontrados, copiar,
    # relatorio
    import duckdb
    import openpyxl

    db_file = tmp_path / "pts.duckdb"
    with duckdb.connect(str(db_file)) as conn:
        conn.execute("CREATE TABLE pts (RTUNO INTEGER, PNTNO INTEGER, SUBNAM VARCHAR, PNTNAM VARCHAR)")
        conn.execute("INSERT INTO pts VALUES (50, 238, 'U9A', ' GENERADOR CGS '), (50, 242, 'U9A', 'turbina cgi'),"
                     " (51, 7, 'U18A', 'Generador cgs x'), (52, 8, 'u9a', NULL)")
        conn.execute("CREATE TABLE other AS SELECT * FROM (VALUES ('turbina CGI'), ('nada')) v(txt)")
        conn.execute("CREATE TABLE blank (txt VARCHAR)")
    win = MainWindow()
    qtbot.addWidget(win)
    win.show()
    win.open_database(db_file)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=30000)
    assert win.tabs.tabText(3) == "Advanced Search" and win.terms_tab_action.shortcut().toString() == "Ctrl+4"
    win.terms_tab_action.trigger()
    assert win.tabs.currentWidget() is win.terms_page
    # Ctrl+Enter na aba Termos pesquisa os termos; o do SQL so vale fora dela
    # o menu mostra Ctrl+Enter; Ctrl com o Enter principal (Return) tambem vale
    for action in (win.run_terms_action, win.run_sql_action):
        assert [k.toString() for k in action.shortcuts()] == ["Ctrl+Enter", "Ctrl+Return"]
    assert not win.run_sql_action.isEnabled() and not win.run_terms_action.isEnabled()  # caixa vazia
    win.terms_edit.setPlainText("PNTNAM\nu9a\n\n turbina cgi \nU9A\n")
    assert win.terms_count.text() == "4 input lines"  # linhas nao vazias, a repetida incluida (BRIEF 18 c)
    assert win.run_terms_action.isEnabled() and win.terms_run_button.isEnabled()
    assert win.match_actions["whole"].isChecked() and win.match_actions["whole"].toolTip().startswith("Whole value:")
    win.terms_scope_actions["all"].trigger()
    win.run_terms_action.trigger()
    qtbot.waitUntil(lambda: win._job is None and win._busy == 0 and win.terms_model.rowCount() > 0, timeout=30000)

    # cada linha achada conta uma vez (a 242 achada por u9a e por turbina cgi: uma linha so)
    assert [win.terms_found.item(i).text() for i in range(win.terms_found.count())] == ["other (1)", "pts (3)"]
    assert win.terms_summary.text() == "2 of 3 terms found: 4 rows in 2 tables"
    assert win.not_found_title.text() == "Not found (1)" and win.not_found_edit.toPlainText() == "PNTNAM"
    assert win.terms_found.currentRow() == 0 and win.terms_model.columns == ["txt"]  # a primeira escolhida
    # UI Automation seleciona o item sem torna-lo o atual: a grade segue a selecao
    from PyQt6.QtCore import QItemSelectionModel

    win.terms_found.selectionModel().select(win.terms_found.model().index(1, 0),
                                            QItemSelectionModel.SelectionFlag.ClearAndSelect)
    qtbot.waitUntil(lambda: win._busy == 0 and win.terms_model.columns[:1] == ["RTUNO"], timeout=30000)
    proxy = win.terms_proxy
    # so as colunas da tabela (sem Termo: BRIEF 19 d), cada linha uma vez, na ordem do 1o termo que a achou
    assert win.terms_model.columns == ["RTUNO", "PNTNO", "SUBNAM", "PNTNAM"]
    assert [proxy.index(r, 1).data() for r in range(proxy.rowCount())] == ["238", "242", "8"]
    assert win.terms_info.text() == "pts: showing 3 of 3 rows"

    # copiar: as linhas achadas com cabecalho, as colunas da tabela
    clipboard = QApplication.clipboard()
    win.copy_hits_action.trigger()
    assert clipboard.text() == ("RTUNO\tPNTNO\tSUBNAM\tPNTNAM\n50\t238\tU9A\t GENERADOR CGS \n50\t242\tU9A\tturbina cgi\n"
                                "52\t8\tu9a\t")
    win.terms_table.selectRow(1)
    win.copy_row_action.trigger()
    assert clipboard.text() == "50\t242\tU9A\tturbina cgi"
    assert win.copy_hits_action in win.terms_table.actions()
    assert win.terms_table.actions()[-1].menu() is win.terms_report_menu

    # relatorio: Excel ("<banco> - Advanced Search", BRIEF 19 e) e CSV (pasta; os que ja existem: uma pergunta so)
    asked = []
    monkeypatch.setattr(QFileDialog, "getSaveFileName",
                        lambda *a: asked.append(Path(a[2]).name) or (str(tmp_path / "rep.xlsx"), ""))
    win.export_terms_actions[0].trigger()
    qtbot.waitUntil(lambda: win._job is None and (tmp_path / "rep.xlsx").exists(), timeout=30000)
    assert asked == ["pts - Advanced Search.xlsx"]
    book = openpyxl.load_workbook(tmp_path / "rep.xlsx", read_only=True)
    assert book.sheetnames == ["other", "pts"]  # uma aba por tabela, sem "Resultado Filtro" (BRIEF 19 d)
    assert next(book["pts"].values) == ("RTUNO", "PNTNO", "SUBNAM", "PNTNAM")
    book.close()
    folder = tmp_path / "csv"
    folder.mkdir()
    (folder / "pts.csv").write_text("old", encoding="utf-8")
    monkeypatch.setattr(QFileDialog, "getExistingDirectory", lambda *a: str(folder))
    answers = [False, True]
    monkeypatch.setattr(win, "ask_overwrite_many", lambda count: answers.pop(0) if count == 1 else None)
    win.export_terms_actions[1].trigger()
    assert sorted(p.name for p in folder.iterdir()) == ["pts.csv"]  # nao: nada gravado
    win.export_terms_actions[1].trigger()
    qtbot.waitUntil(lambda: win._job is None and len(list(folder.iterdir())) == 2, timeout=30000)
    assert (folder / "pts.csv").read_text(encoding="utf-8-sig").startswith("RTUNO,PNTNO")

    # Configuracoes > Comparacao dos termos: Contem (gravado, ja vale na aba); "cgs" acha 2 linhas em pts
    win.default_match_actions["contains"].trigger()
    assert win.match_actions["contains"].isChecked() and QSettings().value("terms_match") == "contains"
    win.terms_edit.setPlainText("cgs")
    win.run_terms_action.trigger()
    qtbot.waitUntil(lambda: win._job is None and win._busy == 0 and win.terms_result is not None, timeout=30000)
    assert win.terms_summary.text() == "1 of 1 term found: 2 rows in 1 table"
    assert win.not_found_title.text() == "Not found (0)" and win.not_found_edit.toPlainText() == ""
    # outro arquivo: o resultado sai, a lista colada fica
    win.open_database(db_file)
    qtbot.waitUntil(lambda: win._busy == 0 and win.terms_result is None, timeout=30000)
    assert win.terms_found.count() == 0 and win.terms_edit.toPlainText() == "cgs"
    assert not win.export_terms_actions[0].isEnabled()


def test_terms_grid_and_copy_with_a_table_column_named_like_the_term_column(qtbot, tmp_path: Path) -> None:
    # revisao B2: a coluna "Term" da tabela e uma coluna como as outras (a grade nao tem coluna Termo: BRIEF 19 d)
    import duckdb

    db_file = tmp_path / "g.duckdb"
    with duckdb.connect(str(db_file)) as conn:
        conn.execute('CREATE TABLE g ("Term" VARCHAR, other VARCHAR)')
        conn.execute("INSERT INTO g VALUES ('alpha', 'x'), ('beta', 'alpha')")
    win = MainWindow()
    qtbot.addWidget(win)
    win.show()
    win.open_database(db_file)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=30000)
    win.terms_tab_action.trigger()
    win.terms_edit.setPlainText("alpha")
    win.run_terms_action.trigger()
    qtbot.waitUntil(lambda: win._job is None and win._busy == 0 and win.terms_model.rowCount() == 2, timeout=30000)
    assert win.terms_model.columns == ["Term", "other"]
    proxy = win.terms_proxy
    assert [[proxy.index(r, c).data() for c in range(2)] for r in range(2)] == [["alpha", "x"], ["beta", "alpha"]]
    win.copy_hits_action.trigger()
    assert QApplication.clipboard().text() == "Term\tother\nalpha\tx\nbeta\talpha"


def test_advanced_search_starts_in_all_tables_whatever_the_data_tab_scope(qtbot, tmp_path: Path) -> None:
    # BRIEF 17: o dono colou do Excel (CRLF) termos que estao em 2 tabelas, com a 1a tabela aberta e a aba Dados em
    # Esta tabela (o padrao), e Pesquisar termos sem mexer em nada nao achava nada (so a 1a tabela era pesquisada)
    import duckdb

    db_file = tmp_path / "plant.duckdb"
    with duckdb.connect(str(db_file)) as conn:
        conn.execute("CREATE TABLE accu AS SELECT 'MEDICION ENERGIA' AS pntnam")
        conn.execute("CREATE TABLE soeqid AS SELECT * FROM (VALUES ('GENERADOR CGS 1'), ('TURBINA CGI 2')) t(pntnam)")
        conn.execute("CREATE TABLE sostat AS SELECT * FROM (VALUES (50, 'GENERADOR CGS 1'), (50, 'TURBINA CGI 2'),"
                     " (50, 'OTRO')) t(rtuno, pntnam)")
    win = MainWindow()
    qtbot.addWidget(win)
    win.default_scope_actions["table"].trigger()  # Configuracoes > Escopo padrao da busca: nao vale para ela
    win.open_database(db_file)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=30000)
    assert win.loaded_table[0] == "accu" and win.scope_actions["table"].isChecked()
    assert win.terms_scope_actions["all"].isChecked()
    win.terms_edit.setPlainText("GENERADOR CGS 1\r\nTURBINA CGI 2\r\n")
    win.terms_run_button.click()
    qtbot.waitUntil(lambda: win._job is None and win._busy == 0 and win.terms_result is not None, timeout=30000)
    assert [(t, sum(c.values())) for t, c in win.terms_result["hits"]] == [("soeqid", 2), ("sostat", 2)]
    assert win.terms_summary.text() == "2 of 2 terms found: 4 rows in 2 tables"
    # Esta tabela: o resumo diz onde pesquisou
    win.terms_scope_actions["table"].trigger()
    win.terms_run_button.click()
    qtbot.waitUntil(lambda: win._job is None and win._busy == 0 and win.terms_result is not None, timeout=30000)
    assert win.terms_summary.text() == "0 of 2 terms found: 0 rows in 0 tables (only in accu)"


def test_export_of_a_subset_asks_whole_table_or_found_rows(qtbot, window: MainWindow, people_db: Path,
                                                           monkeypatch) -> None:
    # igual nas 4 versoes: a grade mostra parte da tabela (pesquisa ou filtro por valor): "Tabela inteira" ou "So as N
    # linhas encontradas" (Cancelar nao grava)
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

    assert len(exported()) == 3 and asked == []  # a grade mostra a tabela toda: nao pergunta
    # so filtro por valor, sem pesquisa: pergunta tambem
    _reloaded(qtbot, window, lambda: window.add_filter("name", "Bruno"))
    answers[:] = [True]
    assert exported() == [["2", "Bruno", ""]] and asked == [1]
    window.filters.clear()
    answers[:] = [False]
    assert len(exported()) == 3 and asked == [1, 1]
    window.filters.clear()
    _reloaded(qtbot, window, window.reload_table)  # a grade volta para a tabela toda
    asked.clear()
    # so pesquisa
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
    assert "Open..." in buttons and "Browse..." not in buttons  # linha de cima: Abrir... / Exportar... (BRIEF 14)
    # nenhum item repetido dentro de um menu (os formatos CSV... / Excel (.xlsx)... se repetem em submenus diferentes)
    menus = [a.menu() for a in win.menuBar().actions()]
    while menus:
        menu = menus.pop()
        assert _repeated(_texts(a for a in menu.actions() if not a.isSeparator())) == [], menu.title()
        menus += [a.menu() for a in menu.actions() if a.menu()]
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
    return [win.data_table.isColumnHidden(c) for c in range(len(win.table_model.columns))]  # sem a caixa de marcar


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
    assert window.info_label.text() == "people: rows 1 to 3 of 3"
    assert window.hidden_label.text() == "2 hidden columns" and not window.hidden_label.isHidden()  # barra de baixo
    # a pesquisa continua olhando todas as colunas (7.25 esta na coluna oculta) e exportar leva todas
    window.search_edit.setText("7.25")
    qtbot.waitUntil(lambda: window.data_proxy.rowCount() == 1, timeout=5000)
    assert window.info_label.text() == "people: row 1 of 1 found"
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
    assert window.info_label.text() == "people: rows 1 to 3 of 3" and window.hidden_label.isHidden()


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
    assert win.info_label.text() == "points: rows 1 to 100 of 300"
    menu = [a.text() for a in win.data_table.actions() if not a.isSeparator()]
    assert menu[:2] == ["&Filter by this value", "C&lear filters"] and "&Copy value" in menu
    assert not win.clear_filters_action.isEnabled() and win.filters_bar.isHidden()

    # U18A nao esta nas 100 linhas carregadas: o filtro vai na consulta e acha as 50
    _reloaded(qtbot, win, lambda: win.add_filter("sigla", "U18A"))
    assert win.info_label.text() == "points: rows 1 to 50 of 50 found"
    assert set(_column(win, 1)) == {"U18A"}
    assert _chips(win) == ["Filter:", "sigla = 'U18A'  ×"]

    # clique direito na celula: a celula atual (NULL) vira "obs IS NULL" e soma com o primeiro filtro
    win.data_table.setCurrentIndex(win.data_proxy.index(0, 2))
    _reloaded(qtbot, win, win.filter_value_action.trigger)
    assert win.filters == [("sigla", "U18A"), ("obs", None)]
    assert win.info_label.text() == "points: rows 1 to 25 of 25 found"
    assert _chips(win) == ["Filters:", "sigla = 'U18A'  ×", "obs IS NULL  ×"]
    assert win.clear_filters_action.isEnabled() and not win.filters_bar.isHidden()

    # a pesquisa de palavras combina com o filtro, nas linhas carregadas
    win.search_edit.setText("298")
    qtbot.waitUntil(lambda: win.data_proxy.rowCount() == 1, timeout=5000)
    assert win.info_label.text() == "points: row 1 of 1 found"
    _reloaded(qtbot, win, win.search_edit.clear)  # a pesquisa vai no banco: limpar recarrega a tabela

    # remover um a um (botao do filtro) e limpar
    _reloaded(qtbot, win, win.filter_chips.itemAt(1).widget().click)
    assert win.filters == [("obs", None)]
    assert win.info_label.text() == "points: rows 1 to 100 of 150 found"  # limite Rows vale
    _reloaded(qtbot, win, win.clear_filters_button.click)
    assert win.filters == [] and _chips(win) == []
    assert win.info_label.text() == "points: rows 1 to 100 of 300"


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
