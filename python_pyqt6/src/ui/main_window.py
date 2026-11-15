# Janela principal: barra de ferramentas, painel de tabelas, abas Data/Schema e barra de status
# !T: QMainWindow with toolbar + table sidebar + data/schema views; DuckDB work runs on QThreadPool

from pathlib import Path
from typing import Callable

from PyQt6.QtCore import (
    QObject,
    QRunnable,
    QSortFilterProxyModel,
    Qt,
    QThreadPool,
    QTimer,
    pyqtSignal,
)
from PyQt6.QtGui import QAction, QGuiApplication, QKeySequence
from PyQt6.QtWidgets import (
    QComboBox,
    QDockWidget,
    QFileDialog,
    QLabel,
    QLineEdit,
    QListWidget,
    QMainWindow,
    QMessageBox,
    QProgressBar,
    QSizePolicy,
    QStackedWidget,
    QTableView,
    QTabWidget,
    QToolBar,
    QVBoxLayout,
    QWidget,
)

from backend.database_tasks import (
    TablePayload,
    database_path_from_env,
    list_tables,
    load_table_payload,
)
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
    "Open a DuckDB file with File > Open Database (Ctrl+O),\n"
    "or set MDB2SQL_DB_PATH and press F5."
)


class _WorkerSignals(QObject):
    success = pyqtSignal(int, object)
    error = pyqtSignal(int, str)
    finished = pyqtSignal()


class _DatabaseWorker(QRunnable):
    # request_id volta junto com o resultado para descartar respostas antigas
    def __init__(self, request_id: int, task: Callable[[], object]):
        super().__init__()
        self.request_id = request_id
        self.task = task
        self.signals = _WorkerSignals()

    def run(self) -> None:
        try:
            result = self.task()
        except Exception as exc:
            self.signals.error.emit(self.request_id, str(exc))
        else:
            self.signals.success.emit(self.request_id, result)
        finally:
            self.signals.finished.emit()


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.current_db_path: Path | None = None
        self.pending_table_name: str | None = None
        self.loaded_table: tuple[str, int] | None = None  # (name, total rows in the table)
        self._table_request = 0
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

        # Ordem do Tab: filtro de tabelas, lista, busca, dados
        QWidget.setTabOrder(self.table_filter, self.table_list)
        QWidget.setTabOrder(self.table_list, self.search_edit)
        QWidget.setTabOrder(self.search_edit, self.data_table)

    def _create_actions(self) -> None:
        self.open_action = QAction("&Open Database...", self)
        self.open_action.setShortcut(QKeySequence.StandardKey.Open)
        self.open_action.setToolTip("Open a DuckDB database file (Ctrl+O)")
        self.open_action.triggered.connect(self.choose_database)

        self.reload_action = QAction("&Reload", self)
        self.reload_action.setShortcut(QKeySequence("F5"))
        self.reload_action.setToolTip("Reload the database and its table list (F5)")
        self.reload_action.triggered.connect(self.load_database)

        self.quit_action = QAction("&Quit", self)
        self.quit_action.setShortcut(QKeySequence("Ctrl+Q"))
        self.quit_action.triggered.connect(self.close)

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

    def _create_central(self) -> None:
        self.table_model = TableModel(self)
        self.data_proxy, self.data_table = self._create_table_view(self.table_model, "Table data")
        self.schema_model = TableModel(self)
        self.schema_proxy, self.schema_table = self._create_table_view(self.schema_model, "Table schema")

        self.tabs = QTabWidget()
        self.tabs.setDocumentMode(True)
        self.tabs.addTab(self.data_table, "Data")
        self.tabs.addTab(self.schema_table, "Schema")
        # !T: On the tabs for the shortcut scope, on each view for its right-click menu
        copy_actions = [self.copy_action, self.copy_row_action, self.copy_row_header_action]
        self.tabs.addActions(copy_actions)
        for view in (self.data_table, self.schema_table):
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
        toolbar.addSeparator()

        self.limit_combo = QComboBox()
        self.limit_combo.setAccessibleName("Rows to load")
        self.limit_combo.setToolTip("Maximum number of rows loaded from the selected table")
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

        help_menu = menu_bar.addMenu("&Help")
        help_menu.addAction("&Sobre", self.show_about)

    def show_about(self) -> None:
        # !T: open() instead of exec(): no nested event loop, so tests and UI Automation do not block
        box = QMessageBox(QMessageBox.Icon.NoIcon, "Sobre", about_html(), QMessageBox.StandardButton.Ok, self)
        box.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        box.open()

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
        task: Callable[[], object],
        on_success: Callable[[int, object], None],
        on_error: Callable[[int, str], None],
    ) -> None:
        worker = _DatabaseWorker(request_id, task)
        worker.signals.success.connect(on_success)
        worker.signals.error.connect(on_error)
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

    def _filter_tables(self, text: str) -> None:
        needle = text.strip().lower()
        for row in range(self.table_list.count()):
            item = self.table_list.item(row)
            item.setHidden(needle not in item.text().lower())

    def copy_selection(self) -> None:
        # Copia o valor da celula; com varias celulas selecionadas, texto separado por TAB
        view = self.tabs.currentWidget()
        if not isinstance(view, QTableView):
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
        view = self.tabs.currentWidget()
        if not isinstance(view, QTableView):
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

    def choose_database(self) -> None:
        start_dir = str(self.current_db_path.parent) if self.current_db_path else str(Path.home())
        file_name, _ = QFileDialog.getOpenFileName(
            self, "Open Database", start_dir, "DuckDB databases (*.duckdb *.db);;All files (*)"
        )
        if file_name:
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
        self._run(0, lambda: list_tables(db_path), self._on_database_loaded, self._on_database_error)

    def _on_database_loaded(self, _request_id: int, result: object) -> None:
        db_path, tables = result  # type: ignore[misc]
        previous = self.table_list.currentItem().text() if self.table_list.currentItem() else None
        self.current_db_path = db_path
        self.setWindowTitle(f"{db_path.name} - {APP_TITLE}")
        self.stack.setCurrentWidget(self.tabs)

        self.table_list.blockSignals(True)
        self.table_list.clear()
        self.table_list.addItems(tables)
        self.table_list.blockSignals(False)
        self._filter_tables(self.table_filter.text())

        self._set_message(self.status_label, f"Loaded: {db_path.name} ({len(tables)} tables)")
        self.open_action.setEnabled(True)
        self.reload_action.setEnabled(True)

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
        if not table_name or self.current_db_path is None:
            return

        self.pending_table_name = table_name
        self._set_message(self.info_label, f"Loading {table_name}...")
        self.table_load_timer.start()

    def _start_table_worker(self) -> None:
        if self.current_db_path is None or not self.pending_table_name:
            return

        db_path = self.current_db_path
        table_name = self.pending_table_name
        limit = self.limit_combo.currentData()
        self.pending_table_name = None
        self._table_request += 1
        self._run(
            self._table_request,
            lambda: load_table_payload(db_path, table_name, limit),
            self._on_table_loaded,
            self._on_table_error,
        )

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
            view.sortByColumn(-1, Qt.SortOrder.AscendingOrder)  # volta para a ordem do backend
            view.resizeColumnsToContents()
            for column in range(view.model().columnCount()):
                if view.columnWidth(column) > MAX_COLUMN_WIDTH:
                    view.setColumnWidth(column, MAX_COLUMN_WIDTH)
        self._apply_search()

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
