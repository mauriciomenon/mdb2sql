# Janela principal: barra de ferramentas, painel de tabelas, abas Data/Schema/SQL e barra de status
# !T: QMainWindow with toolbar + table sidebar + data/schema/SQL views; database work runs on QThreadPool

import threading
from pathlib import Path
from typing import Callable

from PyQt6.QtCore import (
    QObject,
    QRunnable,
    QSettings,
    QSortFilterProxyModel,
    Qt,
    QThreadPool,
    QTimer,
    pyqtSignal,
)
from PyQt6.QtGui import QAction, QActionGroup, QFontDatabase, QGuiApplication, QKeySequence
from PyQt6.QtWidgets import (
    QComboBox,
    QDockWidget,
    QFileDialog,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QMainWindow,
    QMenu,
    QMessageBox,
    QPlainTextEdit,
    QProgressBar,
    QProgressDialog,
    QPushButton,
    QSizePolicy,
    QSplitter,
    QStackedWidget,
    QTableView,
    QTabWidget,
    QToolBar,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from backend.access import quote
from backend.database_tasks import (
    TablePayload,
    database_path_from_env,
    load_table_payload,
    open_database,
)
from backend.db_manager import DBManager
from backend.export import Cancelled, default_save_dir, export_database, export_result
from shared.about import about_html
from shared.tsv import rows_to_tsv
from ui.table_model import SORT_ROLE, TableModel

APP_TITLE = "MDB2SQL - Database Viewer"
# shortcut: search and sort run in the UI thread over the loaded rows, so the limit stops at 10 000;
# move search to SQL in the backend when bigger limits are needed
ROW_LIMITS = (100, 1_000, 10_000)
MAX_COLUMN_WIDTH = 320
EMPTY_HINT = (
    "No database loaded.\n\n"
    "Open a DuckDB, SQLite or Access file with File > Open Database (Ctrl+O),\n"
    "or set MDB2SQL_DB_PATH and press F5."
)
OPEN_FILTER = (
    "Databases (*.duckdb *.db *.sqlite *.sqlite3 *.mdb *.accdb);;DuckDB (*.duckdb *.db);;"
    "SQLite (*.sqlite *.sqlite3);;Access (*.mdb *.accdb);;All files (*)"
)
FILE_TYPES = {
    ".duckdb": "DuckDB database (*.duckdb)",
    ".sqlite": "SQLite database (*.sqlite)",
    ".xlsx": "Excel workbook (*.xlsx)",
    ".csv": "CSV UTF-8 (*.csv)",
}
# Configuracoes > Tema: valor gravado em QSettings -> esquema de cores do Qt
THEMES = {"system": Qt.ColorScheme.Unknown, "light": Qt.ColorScheme.Light, "dark": Qt.ColorScheme.Dark}


def apply_theme(name: str) -> None:
    # !T: Unknown = follow the system; Qt 6.8+ restyles every window when the scheme changes
    QGuiApplication.styleHints().setColorScheme(THEMES.get(name, Qt.ColorScheme.Unknown))


class _WorkerSignals(QObject):
    success = pyqtSignal(int, object)
    error = pyqtSignal(int, str)
    progress = pyqtSignal(int, int, str)
    finished = pyqtSignal()


class _DatabaseWorker(QRunnable):
    # request_id volta junto com o resultado para descartar respostas antigas
    # task recebe a funcao de progresso (feitas, total, texto), que chega a UI por sinal
    def __init__(self, request_id: int, task: Callable[[Callable[[int, int, str], None]], object]):
        super().__init__()
        self.request_id = request_id
        self.task = task
        self.signals = _WorkerSignals()

    def run(self) -> None:
        try:
            result = self.task(self.signals.progress.emit)
        except Exception as exc:
            self.signals.error.emit(self.request_id, str(exc) or type(exc).__name__)
        else:
            self.signals.success.emit(self.request_id, result)
        finally:
            self.signals.finished.emit()


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.settings = QSettings()
        self.manager: DBManager | None = None
        self.current_db_path: Path | None = None
        self.pending_table_name: str | None = None
        self.loaded_table: tuple[str, int] | None = None  # (name, total rows in the table)
        self.sql_query: str | None = None  # ultima consulta da aba SQL que deu certo (para exportar)
        self._table_request = 0
        self._sql_request = 0
        self._busy = 0
        self.thread_pool: QThreadPool = QThreadPool.globalInstance() or QThreadPool(self)

        # !T: Debounce so arrow-key navigation in the table list does not start one query per row
        self.table_load_timer = QTimer(self)
        self.table_load_timer.setSingleShot(True)
        self.table_load_timer.setInterval(150)
        self.table_load_timer.timeout.connect(self._start_table_worker)

        self.search_timer = QTimer(self)
        self.search_timer.setSingleShot(True)
        self.search_timer.setInterval(200)
        self.search_timer.timeout.connect(self._apply_search)

        self.init_ui()

    # ------------------------------------------------------------------ UI

    def init_ui(self):
        self.setWindowTitle(APP_TITLE)
        self.resize(1200, 800)

        self._create_actions()
        self._create_central()
        self._create_sidebar()
        self._create_toolbar()
        self._create_menus()
        self._create_status_bar()
        self._update_export_actions()

        # Ordem do Tab: filtro de tabelas, lista, busca, dados
        QWidget.setTabOrder(self.table_filter, self.table_list)
        QWidget.setTabOrder(self.table_list, self.search_edit)
        QWidget.setTabOrder(self.search_edit, self.data_table)

    def _create_actions(self) -> None:
        self.open_action = QAction("&Open Database...", self)
        self.open_action.setShortcut(QKeySequence.StandardKey.Open)
        self.open_action.setToolTip("Open a DuckDB, SQLite or Access database file (Ctrl+O)")
        self.open_action.triggered.connect(self.choose_database)

        self.reload_action = QAction("&Reload", self)
        self.reload_action.setShortcut(QKeySequence("F5"))
        self.reload_action.setToolTip("Reload the database and its table list (F5)")
        self.reload_action.triggered.connect(self.load_database)

        self.quit_action = QAction("&Quit", self)
        self.quit_action.setShortcut(QKeySequence("Ctrl+Q"))
        self.quit_action.triggered.connect(self.close)

        # Exportar: banco inteiro (.duckdb, .sqlite, .xlsx com uma aba por tabela) e tabela/resultado atual
        self.export_db_actions = []
        for suffix, text in (
            (".duckdb", "Database to &DuckDB..."),
            (".sqlite", "Database to &SQLite..."),
            (".xlsx", "Database to &Excel (one sheet per table)..."),
        ):
            action = QAction(text, self)
            action.triggered.connect(lambda _checked=False, s=suffix: self.export_database_as(s))
            self.export_db_actions.append(action)
        self.export_result_actions = []
        for suffix, text in ((".csv", "Current Table/Result to &CSV..."), (".xlsx", "Current Table/Result to E&xcel...")):
            action = QAction(text, self)
            action.triggered.connect(lambda _checked=False, s=suffix: self.export_result_as(s))
            self.export_result_actions.append(action)

        self.copy_action = QAction("&Copy Value", self)
        self.copy_action.setShortcut(QKeySequence.StandardKey.Copy)
        # !T: Scoped to the tables so Ctrl+C keeps working in the text fields
        self.copy_action.setShortcutContext(Qt.ShortcutContext.WidgetWithChildrenShortcut)
        self.copy_action.triggered.connect(self.copy_selection)

        self.copy_row_action = QAction("Copy &Row", self)
        self.copy_row_action.setShortcut(QKeySequence("Ctrl+Shift+C"))
        self.copy_row_action.setShortcutContext(Qt.ShortcutContext.WidgetWithChildrenShortcut)
        self.copy_row_action.triggered.connect(lambda: self.copy_rows())

        self.copy_row_header_action = QAction("Copy Row with &Header", self)
        self.copy_row_header_action.triggered.connect(lambda: self.copy_rows(header=True))

        self.find_action = QAction("&Find in Rows", self)
        self.find_action.setShortcut(QKeySequence.StandardKey.Find)
        self.find_action.triggered.connect(self._focus_search)

        self.tables_action = QAction("Go to &Table List", self)
        self.tables_action.setShortcut(QKeySequence("Ctrl+L"))
        self.tables_action.triggered.connect(self._focus_tables)

        self.data_tab_action = QAction("&Data", self)
        self.data_tab_action.setShortcut(QKeySequence("Ctrl+1"))
        self.data_tab_action.triggered.connect(lambda: self.tabs.setCurrentIndex(0))

        self.schema_tab_action = QAction("&Schema", self)
        self.schema_tab_action.setShortcut(QKeySequence("Ctrl+2"))
        self.schema_tab_action.triggered.connect(lambda: self.tabs.setCurrentIndex(1))

        self.sql_tab_action = QAction("S&QL", self)
        self.sql_tab_action.setShortcut(QKeySequence("Ctrl+3"))
        self.sql_tab_action.triggered.connect(self._focus_sql)

        self.run_sql_action = QAction("&Run SQL", self)
        self.run_sql_action.setShortcut(QKeySequence("Ctrl+Return"))
        self.run_sql_action.setToolTip("Run the SQL of the SQL tab (Ctrl+Enter)")
        self.run_sql_action.triggered.connect(self.run_sql)

        # Configuracoes > Tema: Sistema, Claro, Escuro (gravado entre execucoes)
        self.theme_group = QActionGroup(self)
        self.theme_actions: dict[str, QAction] = {}
        saved = str(self.settings.value("theme", "system"))
        for name, text in (("system", "&System"), ("light", "&Light"), ("dark", "&Dark")):
            action = QAction(text, self, checkable=True)
            action.setChecked(name == saved)
            action.triggered.connect(lambda _checked=False, n=name: self.set_theme(n))
            self.theme_group.addAction(action)
            self.theme_actions[name] = action

    def _create_central(self) -> None:
        self.table_model = TableModel(self)
        self.data_proxy, self.data_table = self._create_table_view(self.table_model, "Table data")
        self.schema_model = TableModel(self)
        self.schema_proxy, self.schema_table = self._create_table_view(self.schema_model, "Table schema")
        self.sql_model = TableModel(self)
        self.sql_proxy, self.sql_table = self._create_table_view(self.sql_model, "SQL result")

        self.sql_edit = QPlainTextEdit()
        self.sql_edit.setAccessibleName("SQL")
        self.sql_edit.setPlaceholderText("SELECT * FROM ...   (Ctrl+Enter runs; read-only database)")
        self.sql_edit.setFont(QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont))
        self.sql_edit.addAction(self.run_sql_action)
        run_button = QPushButton("Run")
        run_button.setAccessibleName("Run SQL")
        run_button.setToolTip(self.run_sql_action.toolTip())
        run_button.clicked.connect(self.run_sql)
        sql_bar = QHBoxLayout()
        sql_bar.addStretch(1)
        sql_bar.addWidget(run_button)
        editor = QWidget()
        editor_layout = QVBoxLayout(editor)
        editor_layout.setContentsMargins(0, 0, 0, 0)
        editor_layout.addWidget(self.sql_edit)
        editor_layout.addLayout(sql_bar)
        self.sql_page = QSplitter(Qt.Orientation.Vertical)
        self.sql_page.addWidget(editor)
        self.sql_page.addWidget(self.sql_table)
        self.sql_page.setSizes([160, 480])

        self.tabs = QTabWidget()
        self.tabs.setDocumentMode(True)
        self.tabs.addTab(self.data_table, "Data")
        self.tabs.addTab(self.schema_table, "Schema")
        self.tabs.addTab(self.sql_page, "SQL")
        # !T: On the tabs for the shortcut scope, on each view for its right-click menu
        copy_actions = [self.copy_action, self.copy_row_action, self.copy_row_header_action]
        self.tabs.addActions(copy_actions)
        for view in (self.data_table, self.schema_table, self.sql_table):
            view.setContextMenuPolicy(Qt.ContextMenuPolicy.ActionsContextMenu)
            view.addActions(copy_actions)

        self.empty_label = QLabel(EMPTY_HINT)
        self.empty_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.empty_label.setEnabled(False)  # texto esmaecido pela paleta do sistema

        self.stack = QStackedWidget()
        self.stack.addWidget(self.empty_label)
        self.stack.addWidget(self.tabs)
        self.setCentralWidget(self.stack)

    def _create_table_view(self, model: TableModel, name: str) -> tuple[QSortFilterProxyModel, QTableView]:
        proxy = QSortFilterProxyModel(self)
        proxy.setSourceModel(model)
        proxy.setSortRole(SORT_ROLE)
        proxy.setSortCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)
        proxy.setFilterCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)
        proxy.setFilterKeyColumn(-1)  # busca em todas as colunas

        view = QTableView()
        view.setAccessibleName(name)
        view.setModel(proxy)
        view.setAlternatingRowColors(True)
        view.setWordWrap(False)
        view.setHorizontalScrollMode(QTableView.ScrollMode.ScrollPerPixel)

        header = view.horizontalHeader()
        header.setStretchLastSection(True)
        header.setHighlightSections(False)
        header.setDefaultAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter)
        header.setResizeContentsPrecision(200)  # mede so as primeiras linhas: rapido em tabelas grandes
        # !T: A third click on a header returns to the order the backend gave
        header.setSortIndicatorClearable(True)
        header.setSortIndicator(-1, Qt.SortOrder.AscendingOrder)
        view.setSortingEnabled(True)

        view.verticalHeader().setDefaultSectionSize(view.fontMetrics().height() + 8)
        return proxy, view

    def _create_sidebar(self) -> None:
        self.table_filter = QLineEdit()
        self.table_filter.setPlaceholderText("Filter tables")
        self.table_filter.setClearButtonEnabled(True)
        self.table_filter.setAccessibleName("Filter tables")
        self.table_filter.textChanged.connect(self._filter_tables)

        self.table_list = QListWidget()
        self.table_list.setAccessibleName("Tables")
        self.table_list.setUniformItemSizes(True)
        # !T: Signal emitido quando usuario seleciona outra tabela
        self.table_list.currentTextChanged.connect(self.on_table_selected)
        self.table_list.itemSelectionChanged.connect(self._sync_current_table)

        panel = QWidget()
        layout = QVBoxLayout(panel)
        layout.setContentsMargins(6, 6, 6, 6)
        layout.addWidget(self.table_filter)
        layout.addWidget(self.table_list)

        self.tables_dock = QDockWidget("Tables", self)
        self.tables_dock.setObjectName("tablesDock")
        self.tables_dock.setFeatures(QDockWidget.DockWidgetFeature.DockWidgetClosable)
        self.tables_dock.setWidget(panel)
        self.addDockWidget(Qt.DockWidgetArea.LeftDockWidgetArea, self.tables_dock)
        self.resizeDocks([self.tables_dock], [260], Qt.Orientation.Horizontal)

    def _create_toolbar(self) -> None:
        toolbar = QToolBar("Main toolbar", self)
        toolbar.setObjectName("mainToolbar")
        toolbar.setMovable(False)
        toolbar.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextOnly)
        self.addToolBar(toolbar)

        toolbar.addAction(self.open_action)
        toolbar.addAction(self.reload_action)

        # botao Exportar com o mesmo menu de Arquivo > Exportar
        self.export_menu = QMenu("&Export", self)  # o mesmo menu fica em File > Export
        self.export_menu.addActions(self.export_db_actions)
        self.export_menu.addSeparator()
        self.export_menu.addActions(self.export_result_actions)
        self.export_button = QToolButton()
        self.export_button.setText("Export")
        self.export_button.setAccessibleName("Export")
        self.export_button.setToolTip("Export the database, the current table or the SQL result")
        self.export_button.setMenu(self.export_menu)
        self.export_button.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        toolbar.addWidget(self.export_button)
        toolbar.addSeparator()

        self.limit_combo = QComboBox()
        self.limit_combo.setAccessibleName("Rows to load")
        self.limit_combo.setToolTip("Maximum number of rows loaded from the selected table or SQL result")
        for limit in ROW_LIMITS:
            self.limit_combo.addItem(f"{limit:,}", limit)
        self.limit_combo.currentIndexChanged.connect(self.reload_table)
        limit_label = QLabel(" &Rows: ")
        limit_label.setBuddy(self.limit_combo)
        toolbar.addWidget(limit_label)
        toolbar.addWidget(self.limit_combo)

        spacer = QWidget()
        spacer.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred)
        toolbar.addWidget(spacer)

        self.search_edit = QLineEdit()
        self.search_edit.setPlaceholderText("Search loaded rows (Ctrl+F)")
        self.search_edit.setClearButtonEnabled(True)
        self.search_edit.setAccessibleName("Search loaded rows")
        self.search_edit.setMaximumWidth(320)
        self.search_edit.textChanged.connect(lambda _text: self.search_timer.start())
        toolbar.addWidget(self.search_edit)

    def _create_menus(self) -> None:
        menu_bar = self.menuBar()
        file_menu = menu_bar.addMenu("&File")
        file_menu.addAction(self.open_action)
        file_menu.addAction(self.reload_action)
        file_menu.addSeparator()
        file_menu.addMenu(self.export_menu)
        file_menu.addSeparator()
        file_menu.addAction(self.quit_action)

        edit_menu = menu_bar.addMenu("&Edit")
        edit_menu.addAction(self.copy_action)
        edit_menu.addAction(self.copy_row_action)
        edit_menu.addAction(self.copy_row_header_action)
        edit_menu.addAction(self.find_action)

        view_menu = menu_bar.addMenu("&View")
        toggle_tables = self.tables_dock.toggleViewAction()
        toggle_tables.setText("&Tables Panel")
        toggle_tables.setShortcut(QKeySequence("Ctrl+B"))
        view_menu.addAction(toggle_tables)
        view_menu.addAction(self.tables_action)
        view_menu.addSeparator()
        view_menu.addAction(self.data_tab_action)
        view_menu.addAction(self.schema_tab_action)
        view_menu.addAction(self.sql_tab_action)
        view_menu.addAction(self.run_sql_action)

        self.settings_menu = menu_bar.addMenu("&Settings")
        theme_menu = self.settings_menu.addMenu("&Theme")
        theme_menu.addActions(list(self.theme_actions.values()))

        help_menu = menu_bar.addMenu("&Help")
        help_menu.addAction("&Sobre", self.show_about)

    def show_about(self) -> None:
        # !T: open() instead of exec(): no nested event loop, so tests and UI Automation do not block
        box = QMessageBox(QMessageBox.Icon.NoIcon, "Sobre", about_html(), QMessageBox.StandardButton.Ok, self)
        box.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        box.open()

    def set_theme(self, name: str) -> None:
        self.settings.setValue("theme", name)
        self.theme_actions[name].setChecked(True)
        apply_theme(name)

    def _create_status_bar(self) -> None:
        self.status_label = QLabel("No database loaded")
        self.info_label = QLabel("Ready")
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)  # indeterminado: o backend nao informa percentual
        self.progress.setTextVisible(False)
        self.progress.setFixedWidth(120)
        self.progress.hide()

        status_bar = self.statusBar()
        status_bar.addWidget(self.status_label, 1)
        status_bar.addPermanentWidget(self.progress)
        status_bar.addPermanentWidget(self.info_label)

    # ------------------------------------------------------------- helpers

    def _set_message(self, label: QLabel, text: str, error: bool = False) -> None:
        label.setText(text)
        if not error:
            label.setStyleSheet("")
            return
        # !T: Pick a red that stays readable on the current (light or dark) system palette
        dark = self.palette().window().color().lightness() < 128
        label.setStyleSheet(f"color: {'#ff8a80' if dark else '#b3261e'};")

    def _run(
        self,
        request_id: int,
        task: Callable[[Callable[[int, int, str], None]], object],
        on_success: Callable[[int, object], None],
        on_error: Callable[[int, str], None],
        on_progress: Callable[[int, int, str], None] | None = None,
    ) -> None:
        worker = _DatabaseWorker(request_id, task)
        worker.signals.success.connect(on_success)
        worker.signals.error.connect(on_error)
        if on_progress is not None:
            worker.signals.progress.connect(on_progress)
        worker.signals.finished.connect(self._on_worker_finished)
        self._busy += 1
        self.progress.show()
        self.thread_pool.start(worker)

    def _on_worker_finished(self) -> None:
        self._busy -= 1
        if self._busy == 0:
            self.progress.hide()

    def _sync_current_table(self) -> None:
        # !T: UI Automation / screen readers select an item without making it current; follow the selection
        items = self.table_list.selectedItems()
        if items and items[0] is not self.table_list.currentItem():
            self.table_list.setCurrentItem(items[0])

    def _focus_search(self) -> None:
        self.search_edit.setFocus()
        self.search_edit.selectAll()

    def _focus_tables(self) -> None:
        self.tables_dock.show()
        self.table_list.setFocus()

    def _focus_sql(self) -> None:
        self.tabs.setCurrentWidget(self.sql_page)
        self.sql_edit.setFocus()

    def _filter_tables(self, text: str) -> None:
        needle = text.strip().lower()
        for row in range(self.table_list.count()):
            item = self.table_list.item(row)
            item.setHidden(needle not in item.text().lower())

    def _current_view(self) -> QTableView | None:
        page = self.tabs.currentWidget()
        if page is self.sql_page:
            return self.sql_table
        return page if isinstance(page, QTableView) else None

    def copy_selection(self) -> None:
        # Copia o valor da celula; com varias celulas selecionadas, texto separado por TAB
        view = self._current_view()
        if view is None:
            return
        indexes = sorted(view.selectedIndexes(), key=lambda i: (i.row(), i.column()))
        if len(indexes) == 1:
            QGuiApplication.clipboard().setText(str(indexes[0].data() or ""))  # valor puro, sem aspas de TSV
            return
        lines: dict[int, list[object]] = {}
        for index in indexes:
            lines.setdefault(index.row(), []).append(index.data())
        if lines:
            QGuiApplication.clipboard().setText(rows_to_tsv(list(lines.values())))

    def copy_rows(self, header: bool = False) -> None:
        # Copia as linhas inteiras das celulas selecionadas (todas as colunas), separadas por TAB
        view = self._current_view()
        if view is None:
            return
        model = view.model()
        columns = range(model.columnCount())
        rows = sorted({index.row() for index in view.selectedIndexes()})
        if not rows:
            return
        titles = [model.headerData(c, Qt.Orientation.Horizontal) for c in columns] if header else None
        QGuiApplication.clipboard().setText(
            rows_to_tsv([[model.index(row, c).data() for c in columns] for row in rows], titles)
        )

    # ------------------------------------------------------------ database

    def _remember_dir(self, path: Path) -> None:
        self.settings.setValue("last_dir", str(path.parent))

    def choose_database(self) -> None:
        start_dir = default_save_dir(self.current_db_path, self.settings.value("last_dir"))
        file_name, _ = QFileDialog.getOpenFileName(self, "Open Database", str(start_dir), OPEN_FILTER)
        if file_name:
            self._remember_dir(Path(file_name))
            self.open_database(Path(file_name))

    def load_database(self):
        # Recarrega o banco atual; sem banco aberto usa a env var ou o caminho default
        # !T: Check env var or use default path
        self.open_database(self.current_db_path or database_path_from_env())

    def open_database(self, db_path: Path) -> None:
        if not db_path.exists():
            self._set_message(self.status_label, f"Error: {db_path.name} not found", error=True)
            return

        self.open_action.setEnabled(False)
        self.reload_action.setEnabled(False)
        self._set_message(self.status_label, f"Loading: {db_path.name}")

        def progress(done: int, total: int, table: str) -> None:
            if total and table:
                self._set_message(self.status_label, f"Converting {db_path.name}: table {done + 1} of {total} ({table})")

        self._run(
            0,
            lambda report: (db_path, *open_database(db_path, report)),
            self._on_database_loaded,
            self._on_database_error,
            progress,
        )

    def _on_database_loaded(self, _request_id: int, result: object) -> None:
        db_path, manager, tables = result  # type: ignore[misc]
        previous = self.table_list.currentItem().text() if self.table_list.currentItem() else None
        # !T: No close() on the old manager: a table/SQL worker may still use it; the last reference closes it
        self.manager = manager
        self.current_db_path = db_path
        self.sql_query = None
        self.setWindowTitle(f"{db_path.name} - {APP_TITLE}")
        self.stack.setCurrentWidget(self.tabs)

        self.table_list.blockSignals(True)
        self.table_list.clear()
        self.table_list.addItems(tables)
        self.table_list.blockSignals(False)
        self._filter_tables(self.table_filter.text())

        # o caminho usado para abrir (DuckDB, SQLite, Access ODBC, mdbtools) fica visivel na barra de status
        self._set_message(self.status_label, f"Loaded: {db_path.name} ({len(tables)} tables) via {manager.reader}")
        self.open_action.setEnabled(True)
        self.reload_action.setEnabled(True)
        self._update_export_actions()

        if tables:
            # !T: Keep the selected table across a reload; setCurrentRow triggers on_table_selected
            self.table_list.setCurrentRow(tables.index(previous) if previous in tables else 0)
        else:
            self.loaded_table = None
            self.table_model.set_rows([])
            self.schema_model.set_rows([])
            self._set_message(self.info_label, "No tables")

    def _on_database_error(self, _request_id: int, message: str) -> None:
        self._set_message(self.status_label, f"Error: {message}", error=True)
        self.open_action.setEnabled(True)
        self.reload_action.setEnabled(True)

    # --------------------------------------------------------------- table

    def reload_table(self) -> None:
        item = self.table_list.currentItem()
        if item is not None:
            self.on_table_selected(item.text())

    def on_table_selected(self, table_name: str):
        # Chamado quando usuario seleciona tabela na lista
        # !T: Loads table data and displays in QTableView
        if not table_name or self.manager is None:
            return

        self.pending_table_name = table_name
        self._set_message(self.info_label, f"Loading {table_name}...")
        self.table_load_timer.start()

    def _start_table_worker(self) -> None:
        if self.manager is None or not self.pending_table_name:
            return

        manager = self.manager
        table_name = self.pending_table_name
        limit = self.limit_combo.currentData()
        self.pending_table_name = None
        self._table_request += 1
        self._run(
            self._table_request,
            lambda _report: load_table_payload(manager, table_name, limit),
            self._on_table_loaded,
            self._on_table_error,
        )

    def _fit_columns(self, view: QTableView) -> None:
        view.sortByColumn(-1, Qt.SortOrder.AscendingOrder)  # volta para a ordem do backend
        view.resizeColumnsToContents()
        for column in range(view.model().columnCount()):
            if view.columnWidth(column) > MAX_COLUMN_WIDTH:
                view.setColumnWidth(column, MAX_COLUMN_WIDTH)

    def _on_table_loaded(self, request_id: int, result: object) -> None:
        if request_id != self._table_request:
            return  # resposta de uma selecao antiga

        payload: TablePayload = result  # type: ignore[assignment]
        schema = payload["schema"]
        self.table_model.set_rows(
            payload["rows"],
            [column["column_name"] for column in schema],
            [f"{column['column_name']}: {column['column_type']}" for column in schema],
        )
        self.schema_model.set_rows(schema)
        self.loaded_table = (payload["table_name"], payload["total_rows"])

        for view in (self.data_table, self.schema_table):
            self._fit_columns(view)
        self._apply_search()
        self._update_export_actions()

    def _on_table_error(self, request_id: int, message: str) -> None:
        if request_id == self._table_request:
            self._set_message(self.info_label, f"Error loading table: {message}", error=True)

    def _apply_search(self) -> None:
        text = self.search_edit.text()
        self.data_proxy.setFilterFixedString(text)
        if self.loaded_table is None:
            return

        table_name, total_rows = self.loaded_table
        loaded = self.table_model.rowCount()
        if not loaded:
            message = f"{table_name}: 0 rows"
        elif text:
            message = (
                f"{table_name}: {self.data_proxy.rowCount():,} of {loaded:,} loaded rows match"
                f" ({total_rows:,} rows in table)"
            )
        else:
            message = f"{table_name}: Showing {loaded:,} of {total_rows:,} rows"
        self._set_message(self.info_label, message)

    # ----------------------------------------------------------------- SQL

    def run_sql(self) -> None:
        query = self.sql_edit.toPlainText().strip()
        if self.manager is None or not query:
            return
        manager = self.manager
        limit = self.limit_combo.currentData()
        self._sql_request += 1
        self.tabs.setCurrentWidget(self.sql_page)
        self._set_message(self.info_label, "Running SQL...")
        self._run(
            self._sql_request,
            lambda _report: (query, *manager.execute_query(query, limit)),
            self._on_sql_done,
            self._on_sql_error,
        )

    def _on_sql_done(self, request_id: int, result: object) -> None:
        if request_id != self._sql_request:
            return
        query, columns, rows, more = result  # type: ignore[misc]
        self.sql_model.set_rows(rows, columns)
        self._fit_columns(self.sql_table)
        self.sql_query = query if columns else None
        shown = f"first {len(rows):,} rows shown" if more else f"{len(rows):,} rows"
        self._set_message(self.info_label, f"SQL: {shown}" if columns else "SQL: done (no result rows)")
        self._update_export_actions()

    def _on_sql_error(self, request_id: int, message: str) -> None:
        if request_id == self._sql_request:
            self._set_message(self.info_label, f"SQL error: {message}", error=True)

    # -------------------------------------------------------------- export

    def _update_export_actions(self) -> None:
        for action in self.export_db_actions:
            action.setEnabled(self.manager is not None)
        for action in self.export_result_actions:
            action.setEnabled(self.manager is not None and (self.loaded_table is not None or self.sql_query is not None))
        self.export_button.setEnabled(self.manager is not None)

    def current_result(self) -> tuple[str, str] | None:
        """(consulta, titulo) do que esta na tela: o resultado da aba SQL ou a tabela atual inteira."""
        if self.tabs.currentWidget() is self.sql_page and self.sql_query:
            return self.sql_query, "SQL"
        if self.loaded_table is not None:
            return f"SELECT * FROM {quote(self.loaded_table[0])}", self.loaded_table[0]
        if self.sql_query:
            return self.sql_query, "SQL"
        return None

    def _ask_save_path(self, title: str, name: str, suffix: str) -> Path | None:
        # pasta padrao: a do arquivo aberto; sem ele, a ultima pasta usada
        folder = default_save_dir(self.current_db_path, self.settings.value("last_dir"))
        target = folder / f"{name}{suffix}"
        if self.current_db_path is not None and target == self.current_db_path:
            target = folder / f"{name}_export{suffix}"  # nunca sugerir o proprio banco aberto
        file_name, _ = QFileDialog.getSaveFileName(self, title, str(target), FILE_TYPES[suffix])
        if not file_name:
            return None
        path = Path(file_name)
        if path.suffix.lower() != suffix:
            path = path.with_name(path.name + suffix)
        self._remember_dir(path)
        return path

    def export_database_as(self, suffix: str) -> None:
        if self.manager is None or self.current_db_path is None:
            return
        out = self._ask_save_path("Export Database", self.current_db_path.stem, suffix)
        if out is not None:
            manager = self.manager
            self._start_export(out, lambda report, cancel: export_database(manager, out, report, cancel), "tables")

    def export_result_as(self, suffix: str) -> None:
        current = self.current_result()
        if self.manager is None or current is None:
            return
        query, title = current
        name = title if title != "SQL" else f"{self.current_db_path.stem}_sql" if self.current_db_path else "sql"
        out = self._ask_save_path("Export Current Table/Result", name, suffix)
        if out is not None:
            manager = self.manager
            self._start_export(
                out, lambda report, cancel: export_result(manager, query, title, out, report, cancel), "rows"
            )

    def _start_export(self, out: Path, task: Callable, unit: str) -> None:
        # exportacao em thread: dialogo modal com progresso e Cancelar (apaga o arquivo parcial)
        cancel = threading.Event()
        dialog = QProgressDialog(f"Exporting to {out.name}...", "Cancel", 0, 0, self)
        dialog.setWindowTitle("Export")
        dialog.setWindowModality(Qt.WindowModality.WindowModal)
        dialog.setMinimumDuration(0)
        dialog.setAutoClose(False)
        dialog.setAutoReset(False)
        dialog.canceled.connect(cancel.set)
        dialog.show()
        self.export_dialog = dialog

        def progress(done: int, total: int, text: str) -> None:
            if total:
                dialog.setRange(0, total)
                dialog.setValue(done)
            if text:
                dialog.setLabelText(f"Exporting to {out.name}: {text}")

        def finished(message: str, error: bool = False) -> None:
            dialog.canceled.disconnect(cancel.set)
            dialog.close()
            self._set_message(self.info_label, message, error=error)

        def cancelled_or_done(_request_id: int, count: object) -> None:
            if count is None:
                finished(f"Export cancelled: {out.name} not written")
            else:
                finished(f"Exported {count:,} {unit} to {out}")

        def run(report):
            try:
                return task(report, cancel)
            except Cancelled:
                return None

        self._run(0, run, cancelled_or_done, lambda _id, message: finished(f"Export failed: {message}", True), progress)
