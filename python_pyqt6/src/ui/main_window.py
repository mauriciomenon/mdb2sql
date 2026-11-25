# Janela principal: barra de ferramentas, painel de tabelas, abas Data/Schema/SQL, painel Log e barra de status
# !T: QMainWindow with toolbar + table sidebar + data/schema/SQL views; database work runs on QThreadPool.
# !T: Every visible text comes from the language catalog (shared.i18n.tr)

import re
import threading
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

from PyQt6.QtCore import (
    QEvent,
    QObject,
    QRunnable,
    QSettings,
    QSortFilterProxyModel,
    Qt,
    QThreadPool,
    QTimer,
    pyqtSignal,
)
from PyQt6.QtGui import QAction, QActionGroup, QFontDatabase, QGuiApplication, QIcon, QKeySequence
from PyQt6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDockWidget,
    QFileDialog,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
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
    QStyle,
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
from backend.db_manager import DBManager, sql_string
from backend.export import Cancelled, default_save_dir, export_database, export_result
from backend.temp_store import SessionDir
from shared import i18n
from shared.about import app_title
from shared.bundle import resource
from shared.i18n import num, tr
from shared.tsv import rows_to_tsv
from ui.dialogs import AboutDialog, ColumnsDialog
from ui.table_model import COPY_ROLE, SORT_ROLE, TableModel, fold, search_words

# linhas carregadas da tabela e do resultado SQL: 100 / 500 / 1000 nas 4 versoes (a pesquisa e os filtros vao no
# banco, alem delas; ordenar e medir as colunas rodam na thread da tela sobre as carregadas)
ROW_LIMITS = (100, 500, 1000)
MAX_COLUMN_WIDTH = 1200  # trava de seguranca: abaixo disso nenhum valor nem nome de coluna e cortado
LOG_LINES = 5000
SEARCH_DELAY_MS = 300
# grade do Schema: 12 px a mais em cada coluna (texto e cabecalho continuam alinhados a esquerda, juntos)
SCHEMA_GAP = 12
# onde a pesquisa da aba Data procura (valor gravado em QSettings "search_scope" -> texto)
SCOPES = {"table": "scope.table", "all": "scope.all"}
# Configuracoes > Tema: valor gravado em QSettings -> esquema de cores do Qt
THEMES = {"system": Qt.ColorScheme.Unknown, "light": Qt.ColorScheme.Light, "dark": Qt.ColorScheme.Dark}
# resposta da pergunta sobre o SQLite convertido do Access
SAVE, DELETE, CANCEL = "save", "delete", "cancel"


def open_filter() -> str:
    # Access primeiro, SQLite segundo, DuckDB por ultimo
    return ";;".join(
        (
            tr("filter.databases") + " (*.accdb *.mdb *.sqlite *.sqlite3 *.db *.duckdb)",
            "Access (*.accdb *.mdb)",
            "SQLite (*.sqlite *.sqlite3 *.db)",
            "DuckDB (*.duckdb)",
            tr("filter.all") + " (*)",
        )
    )


def file_type(suffix: str) -> str:
    return tr(f"filter{suffix}") + f" (*{suffix})"


def apply_theme(name: str) -> None:
    # !T: Unknown = follow the system; Qt 6.8+ restyles every window when the scheme changes
    QGuiApplication.styleHints().setColorScheme(THEMES.get(name, Qt.ColorScheme.Unknown))


def filter_text(column: str, value: Any) -> str:
    """Texto do filtro ativo na tela: SIGLA = 'U9A', RTUNO = 9, OBS IS NULL (a consulta usa parametro)."""
    if value is None:
        return f"{column} IS NULL"
    return f"{column} = {sql_string(value) if isinstance(value, str) else value}"


def status_line(text: str) -> str:
    """Uma linha para a barra de status: a primeira do texto, sem o tipo do erro do motor ('Parser Error: ').

    !T: 'SQL query error: Parser Error: syntax error at or near "selec"\\n\\nLINE 1: ...' becomes
    !T: 'SQL query error: syntax error at or near "selec"'; the full text stays in the log and the tooltip
    """
    first = text.splitlines()[0] if text else ""
    return re.sub(r": (?:[A-Z][a-z]+ )+Error: ", ": ", first, count=1)


def hidden_text(count: int) -> str:
    return "" if not count else tr("status.hidden_one") if count == 1 else tr("status.hidden_many", count=count)


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
        # icone da barra de titulo, da barra de tarefas e dos dialogos, de onde quer que a janela seja aberta (exe,
        # codigo, testes): .ico com varios tamanhos + PNG 1024 para telas de DPI alto
        icon = QIcon(str(resource("mdb2sql.ico")))
        icon.addFile(str(resource("mdb2sql.png")))
        QGuiApplication.setWindowIcon(icon)
        self.settings = QSettings()
        self.manager: DBManager | None = None
        self.current_db_path: Path | None = None
        self.pending_table_name: str | None = None
        self.loaded_table: tuple[str, int] | None = None  # (name, total rows in the table)
        self.sql_query: str | None = None  # ultima consulta da aba SQL que deu certo (para exportar)
        # filtros coluna = valor (clique direito) e colunas ocultas: valem para view_table, ate trocar de tabela
        self.view_table: str | None = None
        self.filters: list[tuple[str, Any]] = []
        self.hidden_columns: set[str] = set()
        self.matched_rows = 0  # linhas da tabela que passam nos filtros e na pesquisa
        self.loaded_search = ""  # pesquisa usada na consulta da tabela carregada
        self.converted_choice: str | None = None  # "Lembrar nesta sessao" da pergunta do SQLite convertido
        self._table_request = 0
        self._sql_request = 0
        self._db_request = 0
        self._found_request = 0  # pesquisa em todas as tabelas
        self._busy = 0
        self.thread_pool: QThreadPool = QThreadPool.globalInstance() or QThreadPool(self)
        # pasta temporaria da sessao (SQLite convertidos); apaga a de uma sessao anterior que caiu
        self.session = SessionDir()

        # !T: Debounce so arrow-key navigation in the table list does not start one query per row
        self.table_load_timer = QTimer(self)
        self.table_load_timer.setSingleShot(True)
        self.table_load_timer.setInterval(150)
        self.table_load_timer.timeout.connect(self._start_table_worker)

        # pesquisa da aba Data e filtro da lista de tabelas: 300 ms depois da ultima tecla (igual nas 4 versoes)
        self.search_timer = QTimer(self)
        self.search_timer.setSingleShot(True)
        self.search_timer.setInterval(SEARCH_DELAY_MS)
        self.search_timer.timeout.connect(self._search_now)
        self.table_filter_timer = QTimer(self)
        self.table_filter_timer.setSingleShot(True)
        self.table_filter_timer.setInterval(SEARCH_DELAY_MS)
        self.table_filter_timer.timeout.connect(self._filter_tables_now)

        self.init_ui()
        if self.session.removed:
            self.log(tr("log.orphans_removed", count=len(self.session.removed)))

    # ------------------------------------------------------------------ UI

    def init_ui(self):
        self.setWindowTitle(app_title())
        self.resize(1200, 800)

        self._create_actions()
        self._create_central()
        self._create_sidebar()
        self._create_log()
        self._create_toolbar()
        self._create_menus()
        self._create_status_bar()
        self._update_export_actions()

        # Ordem do Tab: filtro de tabelas, lista, busca, dados
        QWidget.setTabOrder(self.table_filter, self.table_list)
        QWidget.setTabOrder(self.table_list, self.search_edit)
        QWidget.setTabOrder(self.search_edit, self.data_table)

    def _action(self, key: str, slot: Callable, shortcut: QKeySequence | str | None = None) -> QAction:
        action = QAction(tr(key), self)
        if shortcut is not None:
            action.setShortcut(QKeySequence(shortcut))
        action.triggered.connect(slot)
        return action

    def _create_actions(self) -> None:
        self.open_action = self._action("action.open", self.choose_database, QKeySequence.StandardKey.Open)
        self.open_action.setToolTip(tr("tip.open"))
        self.reload_action = self._action("action.reload", self.load_database, "F5")
        self.reload_action.setToolTip(tr("tip.reload"))
        self.close_db_action = self._action("action.close", self.close_database, QKeySequence.StandardKey.Close)
        self.quit_action = self._action("action.quit", self.close, "Ctrl+Q")

        # Exportar: banco inteiro (.sqlite, .duckdb, .xlsx com uma aba por tabela) e tabela/resultado atual
        self.export_db_actions = []
        for suffix, key in ((".sqlite", "export.db_sqlite"), (".duckdb", "export.db_duckdb"), (".xlsx", "export.db_xlsx")):
            self.export_db_actions.append(self._action(key, lambda _c=False, s=suffix: self.export_database_as(s)))
        self.export_result_actions = []
        for suffix, key in ((".csv", "export.result_csv"), (".xlsx", "export.result_xlsx")):
            self.export_result_actions.append(self._action(key, lambda _c=False, s=suffix: self.export_result_as(s)))

        self.copy_action = self._action("action.copy_value", self.copy_selection, QKeySequence.StandardKey.Copy)
        # !T: Scoped to the tables so Ctrl+C keeps working in the text fields
        self.copy_action.setShortcutContext(Qt.ShortcutContext.WidgetWithChildrenShortcut)
        self.copy_row_action = self._action("action.copy_row", lambda: self.copy_rows(), "Ctrl+Shift+C")
        self.copy_row_action.setShortcutContext(Qt.ShortcutContext.WidgetWithChildrenShortcut)
        self.copy_row_header_action = self._action("action.copy_row_header", lambda: self.copy_rows(header=True))

        # clique direito numa celula da aba Data: filtro coluna = valor feito na consulta ao banco
        self.filter_value_action = self._action("action.filter_value", self.filter_by_current_cell)
        self.clear_filters_action = self._action("action.clear_filters", self.clear_filters)
        self.clear_filters_action.setEnabled(False)
        # uma acao so para o botao da aba Data e o menu do cabecalho (nada duplicado)
        self.columns_action = self._action("action.columns", self.choose_columns)
        self.columns_action.setIconText(tr("action.columns"))  # !T: The default iconText drops the "..."
        self.columns_action.setToolTip(tr("tip.columns"))

        self.find_action = self._action("action.find", self._focus_search, QKeySequence.StandardKey.Find)
        self.tables_action = self._action("action.go_tables", self._focus_tables, "Ctrl+T")
        self.data_tab_action = self._action("tab.data_menu", lambda: self.tabs.setCurrentIndex(0), "Ctrl+1")
        self.schema_tab_action = self._action("tab.schema_menu", lambda: self.tabs.setCurrentIndex(1), "Ctrl+2")
        self.sql_tab_action = self._action("tab.sql_menu", self._focus_sql, "Ctrl+3")
        self.run_sql_action = self._action("action.run_sql", self.run_sql, "Ctrl+Return")
        self.run_sql_action.setToolTip(tr("tip.run_sql"))

        # Configuracoes > Tema: Sistema, Claro, Escuro (gravado entre execucoes)
        self.theme_group = QActionGroup(self)
        self.theme_actions: dict[str, QAction] = {}
        saved = str(self.settings.value("theme", "system"))
        for name in THEMES:
            action = QAction(tr(f"theme.{name}"), self, checkable=True)
            action.setChecked(name == saved)
            action.triggered.connect(lambda _checked=False, n=name: self.set_theme(n))
            self.theme_group.addAction(action)
            self.theme_actions[name] = action

        # Configuracoes > Idioma: English (padrao), Portugues (Brasil), Espanol; vale ao reabrir
        self.language_group = QActionGroup(self)
        self.language_actions: dict[str, QAction] = {}
        for code in i18n.LANGUAGES:
            action = QAction(tr(f"language.{code}"), self, checkable=True)
            action.setChecked(code == i18n.language())
            action.triggered.connect(lambda _checked=False, c=code: self.set_language(c))
            self.language_group.addAction(action)
            self.language_actions[code] = action

        # pesquisa da aba Data: Esta tabela | Todas as tabelas junto ao campo; o escopo inicial vem de
        # Configuracoes > Escopo padrao da busca (gravado entre execucoes)
        scope = self.default_scope()
        self.scope_group = QActionGroup(self)
        self.scope_actions: dict[str, QAction] = {}
        self.default_scope_group = QActionGroup(self)
        self.default_scope_actions: dict[str, QAction] = {}
        for name, key in SCOPES.items():
            action = QAction(tr(key), self, checkable=True)
            action.setChecked(name == scope)
            action.triggered.connect(lambda _checked=False: self._search_now())
            self.scope_group.addAction(action)
            self.scope_actions[name] = action
            default = QAction(tr(key), self, checkable=True)
            default.setChecked(name == scope)
            default.triggered.connect(lambda _checked=False, n=name: self.set_default_scope(n))
            self.default_scope_group.addAction(default)
            self.default_scope_actions[name] = default

        # Configuracoes > Exibir NULL (padrao desligado = celula vazia, como antes; gravado entre execucoes)
        self.show_null_action = QAction(tr("settings.show_null"), self, checkable=True)
        self.show_null_action.setChecked(self.settings.value("show_null", False, type=bool))
        self.show_null_action.toggled.connect(self.set_show_null)

    def _create_central(self) -> None:
        self.table_model = TableModel(self)
        self.data_proxy, self.data_table = self._create_table_view(self.table_model, tr("a11y.data"))
        self.schema_model = TableModel(self)
        self.schema_proxy, self.schema_table = self._create_table_view(self.schema_model, tr("a11y.schema"))
        self.sql_model = TableModel(self)
        self.sql_proxy, self.sql_table = self._create_table_view(self.sql_model, tr("a11y.sql_result"))
        self.set_show_null(self.show_null_action.isChecked())

        self.sql_edit = QPlainTextEdit()
        self.sql_edit.setAccessibleName("SQL")
        self.sql_edit.setPlaceholderText("SELECT * FROM ...")
        sql_font = QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont)
        sql_font.setPointSizeF(self.font().pointSizeF())  # monoespacada no tamanho da base (14 px), nao nos 9 pt
        self.sql_edit.setFont(sql_font)
        self.sql_edit.addAction(self.run_sql_action)
        run_button = QPushButton(tr("button.run"))
        run_button.setAccessibleName(tr("action.run_sql").replace("&", ""))
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
        self.tabs.addTab(self._create_data_page(), tr("tab.data"))
        self.tabs.addTab(self.schema_table, tr("tab.schema"))
        self.tabs.addTab(self.sql_page, "SQL")
        # !T: On the tabs for the shortcut scope, on each view for its right-click menu
        copy_actions = [self.copy_action, self.copy_row_action, self.copy_row_header_action]
        self.tabs.addActions(copy_actions)
        for view in (self.data_table, self.schema_table, self.sql_table):
            view.setContextMenuPolicy(Qt.ContextMenuPolicy.ActionsContextMenu)
            view.addActions(copy_actions)
        separator = QAction(self)
        separator.setSeparator(True)
        self.data_table.addActions([separator, self.filter_value_action, self.clear_filters_action])
        for view in (self.data_table, self.sql_table):
            view.horizontalHeader().setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
            # !T: The slot must not hold the header itself: header wrapper <-> slot is a cycle only the GC sees, and
            # !T: after a gc.collect() the slot was gone (no menu) or freed (crash on right-click, 1.3.0)
            view.horizontalHeader().customContextMenuRequested.connect(
                lambda pos, v=view: self._popup_header_menu(v, pos)
            )

        self.empty_label = QLabel(tr("status.empty"))
        self.empty_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.empty_label.setEnabled(False)  # texto esmaecido pela paleta do sistema

        self.stack = QStackedWidget()
        self.stack.addWidget(self.empty_label)
        self.stack.addWidget(self.tabs)
        self.setCentralWidget(self.stack)

    def _create_data_page(self) -> QWidget:
        # barra da aba Data: botao Colunas..., filtros ativos (um botao por filtro, clique remove) e Limpar filtros
        self.columns_button = QToolButton()
        self.columns_button.setDefaultAction(self.columns_action)
        self.filter_chips = QHBoxLayout()
        self.clear_filters_button = QToolButton()
        self.clear_filters_button.setDefaultAction(self.clear_filters_action)
        self.clear_filters_button.hide()
        bar = QHBoxLayout()
        bar.setContentsMargins(6, 4, 6, 0)
        bar.addWidget(self.columns_button)
        bar.addLayout(self.filter_chips)
        bar.addStretch(1)
        bar.addWidget(self.clear_filters_button)

        # pesquisa em todas as tabelas: lista "TABELA (linhas encontradas)" no lugar da grade; escolher uma abre
        # essa tabela com a mesma pesquisa
        self.found_list = QListWidget()
        self.found_list.setAccessibleName(tr("search.found_name"))
        self.found_list.itemClicked.connect(self.open_found_table)
        self.found_list.itemActivated.connect(self.open_found_table)  # Enter
        self.data_stack = QStackedWidget()
        self.data_stack.addWidget(self.data_table)
        self.data_stack.addWidget(self.found_list)

        self.data_page = QWidget()
        layout = QVBoxLayout(self.data_page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(4)
        layout.addLayout(bar)
        layout.addWidget(self.data_stack)
        return self.data_page

    def _create_table_view(self, model: TableModel, name: str) -> tuple[QSortFilterProxyModel, QTableView]:
        proxy = QSortFilterProxyModel(self)  # so ordena; a pesquisa vai no banco
        proxy.setSourceModel(model)
        proxy.setSortRole(SORT_ROLE)
        proxy.setSortCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)

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
        header.setResizeContentsPrecision(50)  # Qt mede poucas linhas; _fit_columns mede o texto mais longo de todas
        # !T: A third click on a header returns to the order the backend gave
        header.setSortIndicatorClearable(True)
        header.setSortIndicator(-1, Qt.SortOrder.AscendingOrder)
        view.setSortingEnabled(True)

        view.verticalHeader().setDefaultSectionSize(view.fontMetrics().height() + 8)
        return proxy, view

    def _create_sidebar(self) -> None:
        self.table_filter = QLineEdit()
        self.table_filter.setPlaceholderText(tr("tables.filter"))
        self.table_filter.setClearButtonEnabled(True)
        self.table_filter.setAccessibleName(tr("tables.filter"))
        self.table_filter.setToolTip(tr("tip.words"))
        self.table_filter.textChanged.connect(lambda _text: self.table_filter_timer.start())
        self.table_filter.returnPressed.connect(self._filter_tables_now)  # Enter: na hora, sem os 300 ms

        self.table_list = QListWidget()
        self.table_list.setAccessibleName(tr("tables.title"))
        self.table_list.setUniformItemSizes(True)
        # selecao como faixa de destaque comum (o estilo windows11 desenha so uma barrinha antes do nome, que parece
        # um cursor de texto); cores da paleta: vale para claro e escuro
        self.table_list.setStyleSheet(
            "QListWidget::item:selected { background: palette(highlight); color: palette(highlighted-text); }"
        )
        # nome de tabela nunca vira "...": o painel cresce ate o nome mais longo (limite: rolagem horizontal)
        self.table_list.setTextElideMode(Qt.TextElideMode.ElideNone)
        self.table_list.setHorizontalScrollMode(QListWidget.ScrollMode.ScrollPerPixel)
        # !T: Signal emitido quando usuario seleciona outra tabela
        self.table_list.currentTextChanged.connect(self.on_table_selected)
        self.table_list.itemSelectionChanged.connect(self._sync_current_table)

        panel = QWidget()
        layout = QVBoxLayout(panel)
        layout.setContentsMargins(6, 6, 6, 6)
        layout.addWidget(self.table_filter)
        layout.addWidget(self.table_list)

        self.tables_dock = QDockWidget(tr("tables.title"), self)
        self.tables_dock.setObjectName("tablesDock")
        self.tables_dock.setFeatures(QDockWidget.DockWidgetFeature.DockWidgetClosable)
        self.tables_dock.setWidget(panel)
        self.addDockWidget(Qt.DockWidgetArea.LeftDockWidgetArea, self.tables_dock)
        self.resizeDocks([self.tables_dock], [260], Qt.Orientation.Horizontal)

    def _create_log(self) -> None:
        # Painel Log embaixo: mensagens da sessao (hora + texto), selecionaveis, Ctrl+C e "Copiar tudo";
        # recolhido por padrao (estado lembrado); recolhido, a barra de status mostra erro > aviso > ultima acao
        self.log_view = QPlainTextEdit()
        self.log_view.setReadOnly(True)
        self.log_view.setAccessibleName(tr("log.title"))
        self.log_view.setMaximumBlockCount(LOG_LINES)
        self.log_view.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        font = QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont)
        font.setPointSizeF(max(8.0, self.font().pointSizeF() - 1))  # um passo menor que a base, legivel
        self.log_view.setFont(font)
        self.log_view.setMinimumHeight(3 * self.log_view.fontMetrics().lineSpacing() + 10)  # minimo: 3 linhas
        panel = QWidget()
        layout = QVBoxLayout(panel)
        layout.setContentsMargins(6, 0, 6, 4)
        layout.addWidget(self.log_view)

        # cabecalho do painel: titulo, "Copiar tudo" e a seta que recolhe (sem botoes de flutuar/fechar)
        self.log_copy_button = copy_all = QToolButton()
        copy_all.setText(tr("log.copy_all"))
        copy_all.setAutoRaise(True)
        copy_all.clicked.connect(lambda: QGuiApplication.clipboard().setText(self.log_view.toPlainText()))
        self.log_collapse = QToolButton()
        self.log_collapse.setArrowType(Qt.ArrowType.DownArrow)
        self.log_collapse.setAutoRaise(True)
        self.log_collapse.setToolTip(tr("log.toggle_tip"))
        self.log_collapse.setAccessibleName(tr("log.hide"))
        self.log_collapse.clicked.connect(lambda: self.set_log_visible(False))
        header = QWidget()
        header_layout = QHBoxLayout(header)
        header_layout.setContentsMargins(8, 2, 4, 2)
        header_layout.addWidget(QLabel(tr("log.title")))
        header_layout.addStretch(1)
        header_layout.addWidget(copy_all)
        header_layout.addWidget(self.log_collapse)

        self.log_dock = QDockWidget(tr("log.title"), self)
        self.log_dock.setObjectName("logDock")
        self.log_dock.setFeatures(QDockWidget.DockWidgetFeature.NoDockWidgetFeatures)
        self.log_dock.setTitleBarWidget(header)
        self.log_dock.setWidget(panel)
        self.addDockWidget(Qt.DockWidgetArea.BottomDockWidgetArea, self.log_dock)
        self.log_dock.hide()
        self.log_action = QAction(tr("menu.log"), self, checkable=True)
        self.log_action.setShortcut(QKeySequence("Ctrl+L"))
        self.log_action.triggered.connect(self.set_log_visible)
        self._latest = {"error": "", "warning": ""}  # ultimo erro e ultimo aviso da sessao
        self._unread = {"error": 0, "warning": 0}  # chegaram com o painel recolhido

    def log(self, text: str, level: str = "info") -> None:
        """Linha do painel Log; level 'error' ou 'warning' entra na barra de status quando o painel esta recolhido."""
        self.log_view.appendPlainText(f"{datetime.now():%H:%M:%S}  {text}")
        if level in self._latest:
            self._latest[level] = text
            if self.log_dock.isHidden():
                self._unread[level] += 1
        self._refresh_log_status()

    def set_log_visible(self, visible: bool) -> None:
        self.settings.setValue("log_visible", bool(visible))
        self.log_action.setChecked(bool(visible))
        self.log_dock.setVisible(bool(visible))
        if visible:
            self._unread = {"error": 0, "warning": 0}
            # ~10% da altura (minimo 3 linhas; maximo 25%, em resizeEvent); a borda continua arrastavel
            self.resizeDocks([self.log_dock], [max(self.log_view.minimumHeight() + 32, round(self.height() * 0.10))],
                             Qt.Orientation.Vertical)
            # abre no fim: a ultima linha (o erro que a barra de status mostrava) fica visivel; depois do layout
            bar = self.log_view.verticalScrollBar()
            QTimer.singleShot(0, lambda: bar.setValue(bar.maximum()))
        self._refresh_log_status()

    def _refresh_log_status(self) -> None:
        if not hasattr(self, "log_toggle"):
            return  # ainda montando a janela
        visible = not self.log_dock.isHidden()
        self.log_toggle.setArrowType(Qt.ArrowType.DownArrow if visible else Qt.ArrowType.UpArrow)
        unread = self._unread["error"] + self._unread["warning"]
        self.log_unread.setText(f"({unread})" if unread else "")
        self.log_unread.setVisible(bool(unread))
        # recolhido: a linha mais importante ainda nao lida (erro destacado > aviso > ultima acao, que ja esta la)
        for level in ("error", "warning"):
            if self._unread[level]:
                text = self._latest[level]
                self.status_label.setText(status_line(text))
                self.status_label.setToolTip(text)
                self.status_label.setStyleSheet(f"color: {self._alert_color(level)};")
                return

    def _alert_color(self, level: str) -> str:
        # !T: Colors that stay readable on the current (light or dark) system palette
        dark = self.palette().window().color().lightness() < 128
        if level == "error":
            return "#ff8a80" if dark else "#b3261e"
        return "#ffd180" if dark else "#8a5300"

    def resizeEvent(self, event) -> None:  # noqa: N802 (Qt)
        super().resizeEvent(event)
        self.log_dock.setMaximumHeight(max(self.log_view.minimumHeight() + 32, round(self.height() * 0.25)))

    def eventFilter(self, watched, event) -> bool:  # noqa: N802 (Qt)
        # clique na mensagem da barra de status reexibe o log
        if watched is self.status_label and event.type() == QEvent.Type.MouseButtonRelease:
            if event.button() == Qt.MouseButton.LeftButton and self.log_dock.isHidden():
                self.set_log_visible(True)
        return super().eventFilter(watched, event)

    def _create_toolbar(self) -> None:
        toolbar = QToolBar(tr("toolbar.main"), self)
        toolbar.setObjectName("mainToolbar")
        toolbar.setMovable(False)
        toolbar.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextOnly)
        self.addToolBar(toolbar)

        toolbar.addAction(self.open_action)
        toolbar.addAction(self.reload_action)

        # botao Exportar com o mesmo menu de Arquivo > Exportar
        self.export_menu = QMenu(tr("menu.export"), self)  # o mesmo menu fica em File > Export
        self.export_menu.addActions(self.export_db_actions)
        self.export_menu.addSeparator()
        self.export_menu.addActions(self.export_result_actions)
        self.export_button = QToolButton()
        self.export_button.setText(tr("menu.export").replace("&", ""))
        self.export_button.setAccessibleName(self.export_button.text())
        self.export_button.setToolTip(tr("tip.export"))
        self.export_button.setMenu(self.export_menu)
        self.export_button.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        toolbar.addWidget(self.export_button)
        toolbar.addSeparator()

        self.limit_combo = QComboBox()
        self.limit_combo.setAccessibleName(tr("rows.name"))
        self.limit_combo.setToolTip(tr("tip.rows"))
        for limit in ROW_LIMITS:
            self.limit_combo.addItem(str(limit), limit)  # 100 / 500 / 1000, sem separador (igual nas 4 versoes)
        self.limit_combo.currentIndexChanged.connect(self.reload_table)
        limit_label = QLabel(f" {tr('rows.label')} ")
        limit_label.setBuddy(self.limit_combo)
        toolbar.addWidget(limit_label)
        toolbar.addWidget(self.limit_combo)

        spacer = QWidget()
        spacer.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred)
        toolbar.addWidget(spacer)

        self.search_edit = QLineEdit()
        self.search_edit.setPlaceholderText(tr("search.placeholder"))
        self.search_edit.setToolTip(tr("tip.words"))
        self.search_edit.setClearButtonEnabled(True)
        self.search_edit.setAccessibleName(tr("search.name"))
        self.search_edit.setMinimumWidth(280)
        self.search_edit.setMaximumWidth(420)
        self.search_edit.textChanged.connect(self._search_edited)
        self.search_edit.returnPressed.connect(self._search_now)  # Enter: na hora, sem os 300 ms
        toolbar.addActions(list(self.scope_actions.values()))  # dois botoes de alternar, um marcado
        toolbar.addWidget(self.search_edit)

    def _create_menus(self) -> None:
        menu_bar = self.menuBar()
        file_menu = menu_bar.addMenu(tr("menu.file"))
        file_menu.addActions([self.open_action, self.reload_action, self.close_db_action])
        file_menu.addSeparator()
        file_menu.addMenu(self.export_menu)
        file_menu.addSeparator()
        file_menu.addAction(self.quit_action)

        edit_menu = menu_bar.addMenu(tr("menu.edit"))
        edit_menu.addActions([self.copy_action, self.copy_row_action, self.copy_row_header_action, self.find_action])
        edit_menu.addSeparator()
        edit_menu.addActions([self.filter_value_action, self.clear_filters_action])

        view_menu = menu_bar.addMenu(tr("menu.view"))
        toggle_tables = self.tables_dock.toggleViewAction()
        toggle_tables.setText(tr("menu.tables_panel"))
        toggle_tables.setShortcut(QKeySequence("Ctrl+B"))
        view_menu.addActions([toggle_tables, self.log_action, self.tables_action])
        view_menu.addSeparator()
        view_menu.addActions([self.data_tab_action, self.schema_tab_action, self.sql_tab_action, self.run_sql_action])

        self.settings_menu = menu_bar.addMenu(tr("menu.settings"))
        self.settings_menu.addMenu(tr("menu.theme")).addActions(list(self.theme_actions.values()))
        self.settings_menu.addMenu(tr("menu.language")).addActions(list(self.language_actions.values()))
        self.settings_menu.addMenu(tr("menu.search_scope")).addActions(list(self.default_scope_actions.values()))
        self.settings_menu.addAction(self.show_null_action)

        help_menu = menu_bar.addMenu(tr("menu.help"))
        help_menu.addAction(tr("menu.about"), self.show_about)

    def show_about(self) -> None:
        # !T: open() instead of exec(): no nested event loop, so tests and UI Automation do not block
        box = AboutDialog(self)
        box.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        box.open()

    def set_theme(self, name: str) -> None:
        self.settings.setValue("theme", name)
        self.theme_actions[name].setChecked(True)
        apply_theme(name)

    def default_scope(self) -> str:
        scope = str(self.settings.value("search_scope", "table"))
        return scope if scope in SCOPES else "table"

    def set_default_scope(self, name: str) -> None:
        # grava o padrao e ja vale na tela
        self.settings.setValue("search_scope", name)
        self.default_scope_actions[name].setChecked(True)
        self.scope_actions[name].setChecked(True)
        self._search_now()

    def set_show_null(self, show: bool) -> None:
        # so a grade: ligado mostra o texto NULL, desligado a celula fica vazia; copiar, filtrar e exportar nao mudam
        self.settings.setValue("show_null", bool(show))
        for model in (self.table_model, self.schema_model, self.sql_model):
            model.set_null_text(tr("grid.null") if show else "")

    def set_language(self, code: str) -> None:
        self.settings.setValue("language", code)
        self.language_actions[code].setChecked(True)
        # aviso no idioma escolhido: os textos trocam ao reabrir o app
        notice = i18n.catalog(code)["status.language_restart"]
        self._set_message(self.status_label, notice)

    def _create_status_bar(self) -> None:
        self.status_label = QLabel()  # o centro da janela ja diz "No database loaded"
        self.info_label = QLabel(tr("status.ready"))
        for label in (self.status_label, self.info_label):
            # clique direito > Copiar (o texto inteiro), e o painel Log com o historico
            label.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
            label.customContextMenuRequested.connect(
                lambda pos, lbl=label: self.status_menu(lbl).popup(lbl.mapToGlobal(pos))
            )
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)  # indeterminado: o backend nao informa percentual
        self.progress.setTextVisible(False)
        self.progress.setFixedWidth(120)
        self.progress.hide()

        # seta que recolhe/reexibe o painel Log e o contador de erros/avisos nao lidos (so com o painel recolhido)
        self.log_toggle = QToolButton()
        self.log_toggle.setAutoRaise(True)
        self.log_toggle.setToolTip(tr("log.toggle_tip"))
        self.log_toggle.setAccessibleName(tr("menu.log").replace("&", ""))
        self.log_toggle.clicked.connect(lambda: self.set_log_visible(self.log_dock.isHidden()))
        self.log_unread = QLabel()
        self.log_unread.setToolTip(tr("log.unread_tip"))
        self.status_label.installEventFilter(self)  # clique na mensagem reexibe o log

        status_bar = self.statusBar()
        status_bar.addWidget(self.log_toggle)
        status_bar.addWidget(self.log_unread)
        status_bar.addWidget(self.status_label, 1)
        status_bar.addPermanentWidget(self.progress)
        status_bar.addPermanentWidget(self.info_label)
        self.set_log_visible(self.settings.value("log_visible", False, type=bool))  # padrao: recolhido

    def status_menu(self, label: QLabel) -> QMenu:
        menu = QMenu(self)
        menu.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        copy = menu.addAction(tr("action.copy"), lambda: QGuiApplication.clipboard().setText(label.text()))
        copy.setEnabled(bool(label.text()))
        menu.addAction(self.log_action)
        return menu

    # ------------------------------------------------------------- helpers

    def _set_message(
        self, label: QLabel, text: str, error: bool = False, log: bool = True, warning: bool = False
    ) -> None:
        level = "error" if error else "warning" if warning else "info"
        if level != "info" and label is self.info_label:
            # erro/aviso so a esquerda (seta, contador, linha mais importante): a mesma mensagem nunca aparece duas
            # vezes; a direita volta para o estado da tabela (linhas, colunas ocultas)
            label = self.status_label
            if self.loaded_table is not None:
                self._apply_search()
            else:
                self.info_label.clear()
        label.setText(status_line(text))
        label.setToolTip(text)  # texto inteiro (erro do motor com LINE 1 e ^^^) na dica e no Log
        label.setStyleSheet("" if level == "info" else f"color: {self._alert_color(level)};")
        if log and text:
            self.log(text, level)  # depois do texto: com o Log recolhido, um erro nao lido continua na barra

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

    def _filter_tables_now(self) -> None:
        self.table_filter_timer.stop()
        self._filter_tables(self.table_filter.text())

    def _filter_tables(self, text: str) -> None:
        words = search_words(text)
        for row in range(self.table_list.count()):
            item = self.table_list.item(row)
            name = fold(item.text())
            item.setHidden(not all(word in name for word in words))

    def _current_view(self) -> QTableView | None:
        page = self.tabs.currentWidget()
        if page is self.sql_page:
            return self.sql_table
        if page is self.data_page:
            return self.data_table
        return page if isinstance(page, QTableView) else None

    def copy_selection(self) -> None:
        # Copia o valor da celula; com varias celulas selecionadas, texto separado por TAB
        view = self._current_view()
        if view is None:
            return
        indexes = sorted(view.selectedIndexes(), key=lambda i: (i.row(), i.column()))
        if len(indexes) == 1:
            QGuiApplication.clipboard().setText(str(indexes[0].data(COPY_ROLE) or ""))  # valor puro, sem aspas de TSV
            return
        lines: dict[int, list[object]] = {}
        for index in indexes:
            lines.setdefault(index.row(), []).append(index.data(COPY_ROLE))
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
            rows_to_tsv([[model.index(row, c).data(COPY_ROLE) for c in columns] for row in rows], titles)
        )

    # ------------------------------------------------------------ database

    def _remember_dir(self, path: Path) -> None:
        self.settings.setValue("last_dir", str(path.parent))

    def choose_database(self) -> None:
        start_dir = default_save_dir(self.current_db_path, self.settings.value("last_dir"))
        file_name, _ = QFileDialog.getOpenFileName(self, tr("dialog.open"), str(start_dir), open_filter())
        if file_name and self.release_database():
            self._remember_dir(Path(file_name))
            self.open_database(Path(file_name))

    def load_database(self):
        # Recarrega o banco atual; sem banco aberto usa a env var ou o caminho default
        # !T: Check env var or use default path
        self.open_database(self.current_db_path or database_path_from_env())

    def open_database(self, db_path: Path) -> None:
        if not db_path.exists():
            self._set_message(self.status_label, tr("status.not_found", name=db_path.name), error=True)
            return

        self.open_action.setEnabled(False)
        self.reload_action.setEnabled(False)
        self._set_message(self.status_label, tr("status.loading", name=db_path.name))

        def progress(done: int, total: int, table: str) -> None:
            if total and table:
                text = tr("status.converting", name=db_path.name, done=num(done + 1), total=num(total), table=table)
                self._set_message(self.status_label, text, log=False)  # uma linha por tabela: fora do log

        self._db_request += 1  # abrir outro arquivo invalida a abertura anterior ainda em andamento
        work_dir = self.session.path
        self._run(
            self._db_request,
            lambda report: (db_path, *open_database(db_path, report, work_dir)),
            self._on_database_loaded,
            self._on_database_error,
            progress,
        )

    def _on_database_loaded(self, request_id: int, result: object) -> None:
        db_path, manager, tables = result  # type: ignore[misc]
        if request_id != self._db_request:
            manager.release()  # abertura antiga terminou depois de outra mais nova: descarta (e o SQLite dela)
            return
        previous = self.table_list.currentItem().text() if self.table_list.currentItem() else None
        if db_path != self.current_db_path:
            self._reset_view(None)  # outro arquivo: filtros e colunas ocultas nao valem mais
            # nem a pesquisa da aba Data e o filtro da lista; o escopo volta ao padrao de Configuracoes (4 versoes)
            self.search_edit.clear()
            self.table_filter.clear()
            self.search_timer.stop()
            self.table_filter_timer.stop()
            self.scope_actions[self.default_scope()].setChecked(True)
            self.loaded_table = None
            self.table_model.set_rows([])
            self.schema_model.set_rows([])
        # consultas de tabela e SQL ainda pendentes sao do banco anterior: descartar o que elas devolverem
        self._table_request += 1
        self._sql_request += 1
        if self.manager is not None:
            # recarregar (F5) o mesmo arquivo: o anterior fecha depois das consultas em andamento; o SQLite
            # convertido dele e substituido pelo novo, sem pergunta
            self.manager.release()
        self.manager = manager
        self.current_db_path = db_path
        self.sql_query = None
        self.sql_model.set_rows([])
        self.setWindowTitle(f"{db_path.name} - {app_title()}")
        self.stack.setCurrentWidget(self.tabs)

        self.table_list.blockSignals(True)
        self.table_list.clear()
        self.table_list.addItems(tables)
        for row in range(self.table_list.count()):  # nome inteiro tambem na dica
            self.table_list.item(row).setToolTip(self.table_list.item(row).text())
        self.table_list.blockSignals(False)
        self._fit_tables_panel(tables)
        self._filter_tables(self.table_filter.text())

        # o caminho usado para abrir (Access ODBC, mdbtools, SQLite, DuckDB) fica visivel na barra de status
        key = "status.loaded_access" if manager.converted else "status.loaded"
        self._set_message(self.status_label, tr(key, name=db_path.name, count=num(len(tables)), reader=manager.reader))
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
            self._set_message(self.info_label, tr("status.no_tables"))
        if self.data_stack.currentWidget() is self.found_list:
            self._search_now()  # lista de todas as tabelas: refeita no banco aberto agora

    def _on_database_error(self, request_id: int, message: str) -> None:
        if request_id != self._db_request:
            return
        self._set_message(self.status_label, tr("status.error", message=message), error=True)
        self.open_action.setEnabled(True)
        self.reload_action.setEnabled(True)

    # ------------------------------------------- fechar: SQLite convertido do Access

    def ask_converted(self, source: Path) -> tuple[str, bool]:
        """Pergunta o que fazer com o SQLite convertido: (SAVE | DELETE | CANCEL, lembrar nesta sessao)."""
        box = QMessageBox(QMessageBox.Icon.Question, tr("converted.title"), tr("converted.text", name=source.name),
                          QMessageBox.StandardButton.NoButton, self)
        save = box.addButton(tr("converted.save"), QMessageBox.ButtonRole.AcceptRole)
        delete = box.addButton(tr("converted.delete"), QMessageBox.ButtonRole.DestructiveRole)
        cancel = box.addButton(tr("button.cancel"), QMessageBox.ButtonRole.RejectRole)
        box.setDefaultButton(save)
        box.setEscapeButton(cancel)
        remember = QCheckBox(tr("converted.remember"))
        box.setCheckBox(remember)
        box.exec()
        choice = {save: SAVE, delete: DELETE}.get(box.clickedButton(), CANCEL)
        return choice, remember.isChecked() and choice != CANCEL

    def ask_converted_target(self, source: Path) -> Path | None:
        # padrao: ao lado do arquivo de origem, <origem>.sqlite
        file_name, _ = QFileDialog.getSaveFileName(
            self, tr("converted.save_title"), str(source.with_suffix(".sqlite")), file_type(".sqlite")
        )
        if not file_name:
            return None
        path = Path(file_name)
        return path if path.suffix.lower() == ".sqlite" else path.with_name(path.name + ".sqlite")

    def release_database(self) -> bool:
        """Fecha o banco aberto. Com SQLite convertido do Access, pergunta: salvar, apagar ou cancelar (False)."""
        manager = self.manager
        if manager is None:
            return True
        target = None
        if manager.converted is not None and self.current_db_path is not None:
            choice = self.converted_choice
            while True:
                if choice is None:
                    choice, remember = self.ask_converted(self.current_db_path)  # Esc e o X da janela: Cancelar
                    if remember:
                        self.converted_choice = choice
                if choice == CANCEL:
                    return False
                if choice == DELETE:
                    break
                target = self.ask_converted_target(self.current_db_path)
                if target is not None:
                    break
                choice = None  # cancelou o dialogo de salvar: volta para a pergunta
        source = self.current_db_path
        self._clear_database()
        try:
            manager.release(target)
        except OSError as exc:
            self._set_message(self.status_label, tr("status.error", message=exc), error=True)
            return True
        if target is not None:
            self._set_message(self.status_label, tr("status.converted_saved", path=target))
        elif source is not None and source.suffix.lower() in (".accdb", ".mdb"):
            self.log(tr("log.converted_deleted", name=source.name))
        return True

    def _clear_database(self) -> None:
        # tela vazia; respostas pendentes do banco fechado sao descartadas
        self._db_request += 1
        self._table_request += 1
        self._sql_request += 1
        self._found_request += 1
        self.found_list.clear()
        self.table_load_timer.stop()
        self.manager = None
        self.current_db_path = None
        self.loaded_table = None
        self.sql_query = None
        self._reset_view(None)
        for model in (self.table_model, self.schema_model, self.sql_model):
            model.set_rows([])
        self.table_list.blockSignals(True)
        self.table_list.clear()
        self.table_list.blockSignals(False)
        self.stack.setCurrentWidget(self.empty_label)
        self.setWindowTitle(app_title())
        self.status_label.clear()
        self.info_label.clear()
        self.open_action.setEnabled(True)
        self.reload_action.setEnabled(True)
        self._update_export_actions()

    def close_database(self) -> None:
        self.release_database()

    def closeEvent(self, event) -> None:  # noqa: N802 (Qt)
        if not self.release_database():
            event.ignore()  # Cancelar: o app continua aberto
            return
        # sobra da sessao (conversao ainda em andamento) some quando as threads terminam
        self.thread_pool.waitForDone()
        self.session.close()
        super().closeEvent(event)

    # --------------------------------------------------------------- table

    def reload_table(self) -> None:
        # limite, filtro e pesquisa: consulta na hora (a pesquisa ja esperou os 300 ms); os 150 ms de
        # table_load_timer sao so da navegacao pela lista com as setas
        item = self.table_list.currentItem()
        if item is not None:
            self.on_table_selected(item.text())
            self._start_table_worker()

    def _search_edited(self) -> None:
        # o termo mudou: a busca em todas as tabelas ainda rodando para na proxima tabela e o resultado dela nao
        # aparece (chegaria antes dos 300 ms); a nova sai 300 ms depois da ultima tecla
        self._found_request += 1
        self.search_timer.start()

    def _search_now(self) -> None:
        """Pesquisa da aba Data (300 ms depois da ultima tecla, ou ao trocar o escopo): na tabela aberta, no banco
        (tabela inteira), ou em todas as tabelas (lista no lugar da grade)."""
        self.search_timer.stop()
        self._found_request += 1  # pesquisa em todas as tabelas ainda rodando: o resultado dela e descartado
        self.found_list.clear()
        everywhere = self.scope_actions["all"].isChecked() and bool(self.search_edit.text().split())
        self.data_stack.setCurrentWidget(self.found_list if everywhere else self.data_table)
        if everywhere:
            self._search_all_tables()
        else:
            self.reload_table()

    def _search_all_tables(self) -> None:
        if self.manager is None:
            return
        manager, search, request = self.manager, self.search_edit.text(), self._found_request
        self._set_message(self.info_label, tr("status.found_running"), log=False)
        self._run(
            request,
            lambda _report: manager.search_tables(search, lambda: request != self._found_request),
            self._on_found,
            self._on_found_error,
        )

    def _on_found(self, request_id: int, result: object) -> None:
        if request_id != self._found_request:
            return  # pesquisa antiga (outra tecla, outro escopo, outro banco)
        found: list[tuple[str, int]] = result  # type: ignore[assignment]
        for table, count in found:
            item = QListWidgetItem(tr("search.found_item", table=table, count=num(count)))
            item.setData(Qt.ItemDataRole.UserRole, table)
            self.found_list.addItem(item)
        self._set_message(self.info_label, tr("status.found", count=num(len(found))), log=False)

    def _on_found_error(self, request_id: int, message: str) -> None:
        if request_id == self._found_request:
            self._set_message(self.info_label, tr("status.error", message=message), error=True)

    def open_found_table(self, item: QListWidgetItem) -> None:
        # a tabela escolhida abre na aba Data com a mesma pesquisa e sem filtros por valor (a grade mostra o numero
        # listado, igual nas 4 versoes); o escopo volta para esta tabela
        self.scope_actions["table"].setChecked(True)
        self.filters.clear()
        self._refresh_filter_bar()
        found = self.table_list.findItems(item.data(Qt.ItemDataRole.UserRole), Qt.MatchFlag.MatchExactly)
        if found:
            self.table_list.setCurrentItem(found[0])
        self._search_now()

    def on_table_selected(self, table_name: str):
        # Chamado quando usuario seleciona tabela na lista
        # !T: Loads table data and displays in QTableView
        if not table_name or self.manager is None:
            return

        if table_name != self.view_table:
            self._reset_view(table_name)  # trocar de tabela limpa os filtros e mostra todas as colunas
        self.pending_table_name = table_name
        self._set_message(self.info_label, tr("status.loading_table", table=table_name), log=False)
        self.table_load_timer.start()

    def _start_table_worker(self) -> None:
        self.table_load_timer.stop()
        if self.manager is None or not self.pending_table_name:
            return

        manager = self.manager
        table_name = self.pending_table_name
        limit = self.limit_combo.currentData()
        filters = list(self.filters)
        search = self.search_edit.text()
        self.pending_table_name = None
        self._table_request += 1
        self._run(
            self._table_request,
            lambda _report: load_table_payload(manager, table_name, limit, filters, search),
            self._on_table_loaded,
            self._on_table_error,
        )

    def tables_panel_width(self, tables: list[str]) -> int:
        """Largura do painel para o nome mais longo caber inteiro: 260..35% da janela (acima disso, rolagem)."""
        metrics = self.table_list.fontMetrics()
        longest = max((metrics.horizontalAdvance(name) for name in tables), default=0)
        scrollbar = self.style().pixelMetric(QStyle.PixelMetric.PM_ScrollBarExtent)
        needed = longest + scrollbar + 2 * self.table_list.frameWidth() + 12 + 16  # item, lista e margens do painel
        return max(260, min(needed, round(self.width() * 0.35)))

    def _fit_tables_panel(self, tables: list[str]) -> None:
        # o separador do painel continua arrastavel; so ajusta na abertura do arquivo
        self.resizeDocks([self.tables_dock], [self.tables_panel_width(tables)], Qt.Orientation.Horizontal)

    def _fit_columns(self, view: QTableView, columns: list[int] | None = None) -> None:
        """Largura das colunas (todas sem `columns`) pelo texto mais longo: cabecalho ou valor de qualquer linha."""
        model: TableModel = view.model().sourceModel()
        padding = 2 * (view.style().pixelMetric(QStyle.PixelMetric.PM_FocusFrameHMargin, None, view) + 1) + 8
        gap = SCHEMA_GAP if view is self.schema_table else 0
        for column in range(model.columnCount()) if columns is None else columns:
            view.resizeColumnToContents(column)  # !T: Qt takes the larger of the header text and the content
            # !T: Qt measures only the first rows (resize precision); the longest texts of all loaded rows are
            # !T: measured here so no value is cut with "..."; only above MAX_COLUMN_WIDTH (tooltip has the full text)
            metrics = view.fontMetrics()
            longest = max((metrics.horizontalAdvance(text) for text in model.longest_texts(column)), default=0)
            width = max(view.columnWidth(column), longest + padding)
            view.setColumnWidth(column, min(width + gap, MAX_COLUMN_WIDTH))

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
        # titulos do Schema traduzidos: as chaves do backend (column_name, column_type, null) nao vao para a tela
        titles = {"column_name": tr("schema.column"), "column_type": tr("schema.type"), "null": tr("schema.nullable")}
        self.schema_model.set_rows([{titles[k]: v for k, v in column.items()} for column in schema],
                                   list(titles.values()))
        self.loaded_table = (payload["table_name"], payload["total_rows"])
        self.matched_rows = payload["matched_rows"]
        self.loaded_search = payload["search"]

        for view in (self.data_table, self.schema_table):
            view.sortByColumn(-1, Qt.SortOrder.AscendingOrder)  # volta para a ordem do backend
            self._fit_columns(view)
        self._apply_hidden_columns()  # o reset do modelo mostra todas: oculta de novo as escolhidas
        self._apply_search()
        self._update_export_actions()

    def _on_table_error(self, request_id: int, message: str) -> None:
        if request_id == self._table_request:
            self._set_message(self.info_label, tr("status.table_error", message=message), error=True)

    def _apply_search(self) -> None:
        # linha da barra de status da aba Data; pesquisa e filtros ja vieram aplicados da consulta ao banco
        if self.loaded_table is None:
            return

        table, total_rows = self.loaded_table
        loaded = self.table_model.rowCount()
        total = num(total_rows)
        if self.filters or self.loaded_search.split():  # contagem feita no banco, alem das linhas carregadas
            message = tr("status.showing_matched", table=table, loaded=num(loaded), matched=num(self.matched_rows),
                         total=total)
        elif not loaded:
            message = tr("status.zero_rows", table=table)
        else:
            message = tr("status.showing", table=table, loaded=num(loaded), total=total)
        hidden = sum(name in self.hidden_columns for name in self.table_model.columns)
        self._set_message(self.info_label, message + hidden_text(hidden), log=False)

    # ----------------------------------------------- filtros e colunas ocultas

    def _reset_view(self, table_name: str | None) -> None:
        self.view_table = table_name
        self.filters.clear()
        self.hidden_columns.clear()
        self._refresh_filter_bar()

    def filter_by_current_cell(self) -> None:
        # celula atual da aba Data (o clique direito e o Shift+F10 agem sobre ela): valor Python lido do banco
        index = self.data_table.currentIndex()
        selected = self.data_table.selectedIndexes()
        if selected and index not in selected:
            index = selected[0]  # !T: UI Automation / screen readers select a cell without making it current
        index = self.data_proxy.mapToSource(index)
        if index.isValid():
            column = self.table_model.columns[index.column()]
            self.add_filter(column, self.table_model.rows[index.row()].get(column))

    def add_filter(self, column: str, value: Any) -> None:
        if (column, value) not in self.filters:
            self.filters.append((column, value))
            self._filters_changed()

    def remove_filter(self, position: int) -> None:
        del self.filters[position]
        self._filters_changed()

    def clear_filters(self) -> None:
        if self.filters:
            self.filters.clear()
            self._filters_changed()

    def _filters_changed(self) -> None:
        self._refresh_filter_bar()
        self.reload_table()  # o filtro vai na consulta: acha linhas alem das carregadas

    def _refresh_filter_bar(self) -> None:
        while self.filter_chips.count():
            self.filter_chips.takeAt(0).widget().deleteLater()
        if self.filters:
            self.filter_chips.addWidget(QLabel(tr("filters.many" if len(self.filters) > 1 else "filters.one")))
        for position, (column, value) in enumerate(self.filters):
            text = filter_text(column, value)
            chip = QToolButton()
            chip.setText(f"{text}  ×")
            chip.setAccessibleName(tr("filters.remove_name", filter=text))
            chip.setToolTip(tr("filters.remove"))
            chip.clicked.connect(lambda _checked=False, p=position: self.remove_filter(p))
            self.filter_chips.addWidget(chip)
        self.clear_filters_button.setVisible(bool(self.filters))
        self.clear_filters_action.setEnabled(bool(self.filters))

    def _apply_hidden_columns(self) -> None:
        for column, name in enumerate(self.table_model.columns):
            self.data_table.setColumnHidden(column, name in self.hidden_columns)

    def set_hidden_columns(self, names: set[str]) -> None:
        self.hidden_columns = set(names)
        self._apply_hidden_columns()
        self._apply_search()  # atualiza "N colunas ocultas" na barra de status

    def _set_hidden(self, view: QTableView, names: set[str]) -> None:
        if view is self.data_table:
            self.set_hidden_columns(names)  # aba Data: vale ate trocar de tabela, contada na barra de status
            return
        for column, name in enumerate(view.model().sourceModel().columns):  # resultado SQL: ate a proxima consulta
            view.setColumnHidden(column, name in names)

    def choose_columns(self) -> None:
        for open_dialog in self.findChildren(ColumnsDialog):
            if open_dialog.isVisible():  # um dialogo so, mesmo com pedido repetido
                open_dialog.raise_()
                return
        dialog = ColumnsDialog(self.table_model.columns, self.hidden_columns, self)
        dialog.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        dialog.hiddenChanged.connect(self.set_hidden_columns)  # vale na hora; Fechar so fecha
        dialog.open()

    def _popup_header_menu(self, view: QTableView, pos) -> None:
        header = view.horizontalHeader()
        self.header_menu(header.logicalIndexAt(pos), view).popup(header.mapToGlobal(pos))

    def header_menu(self, column: int, view: QTableView | None = None) -> QMenu:
        """Clique direito no cabecalho das grades Data e SQL (column = -1 fora de uma coluna): ajustar a largura e
        ocultar/mostrar colunas; a lista marca as visiveis (clique alterna) e a ultima visivel nao sai."""
        view = view or self.data_table
        names = view.model().sourceModel().columns
        hidden = {name for c, name in enumerate(names) if view.isColumnHidden(c)}
        last = len(names) - len(hidden) <= 1
        on_column = 0 <= column < len(names)
        menu = QMenu(self)
        menu.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        menu.addAction(tr("columns.fit"), lambda: self._fit_columns(view, [column])).setEnabled(on_column)
        menu.addAction(tr("columns.fit_all"), lambda: self._fit_columns(view))
        menu.addSeparator()
        hide = menu.addAction(tr("columns.hide_this"), lambda: self._set_hidden(view, hidden | {names[column]}))
        hide.setEnabled(on_column and not last)
        if view is self.data_table:
            menu.addAction(self.columns_action)
        menu.addAction(tr("columns.show_all_columns"), lambda: self._set_hidden(view, set()))
        menu.addSeparator()
        for name in names:
            # "&" no nome da coluna e texto, nao atalho
            toggle = menu.addAction(name.replace("&", "&&"), lambda _c=False, n=name: self._set_hidden(view, hidden ^ {n}))
            toggle.setCheckable(True)
            toggle.setChecked(name not in hidden)
            toggle.setEnabled(name in hidden or not last)
        return menu

    # ----------------------------------------------------------------- SQL

    def run_sql(self) -> None:
        query = self.sql_edit.toPlainText().strip()
        if self.manager is None or not query:
            return
        manager = self.manager
        limit = self.limit_combo.currentData()
        self._sql_request += 1
        self.tabs.setCurrentWidget(self.sql_page)
        self._set_message(self.info_label, tr("status.sql_running"), log=False)
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
        for column in range(len(columns)):
            self.sql_table.setColumnHidden(column, False)  # o cabecalho guarda as ocultas por posicao: outro resultado
        self.sql_table.sortByColumn(-1, Qt.SortOrder.AscendingOrder)  # volta para a ordem do backend
        self._fit_columns(self.sql_table)
        self.sql_query = query if columns else None
        if not columns:
            message = tr("status.sql_done")
        else:
            message = tr("status.sql_first" if more else "status.sql_rows", count=num(len(rows)))
        self._set_message(self.info_label, message)
        self._update_export_actions()

    def _on_sql_error(self, request_id: int, message: str) -> None:
        if request_id == self._sql_request:
            self._set_message(self.info_label, tr("status.sql_error", message=message), error=True)

    # -------------------------------------------------------------- export

    def _update_export_actions(self) -> None:
        for action in self.export_db_actions:
            action.setEnabled(self.manager is not None)
        for action in self.export_result_actions:
            action.setEnabled(self.manager is not None and (self.loaded_table is not None or self.sql_query is not None))
        self.export_button.setEnabled(self.manager is not None)
        self.close_db_action.setEnabled(self.manager is not None)

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
        file_name, _ = QFileDialog.getSaveFileName(self, title, str(target), file_type(suffix))
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
        out = self._ask_save_path(tr("dialog.export_db"), self.current_db_path.stem, suffix)
        if out is not None:
            manager = self.manager
            self._start_export(out, lambda report, cancel: export_database(manager, out, report, cancel), "tables")

    def export_result_as(self, suffix: str) -> None:
        current = self.current_result()
        if self.manager is None or current is None:
            return
        query, title = current
        name = title if title != "SQL" else f"{self.current_db_path.stem}_sql" if self.current_db_path else "sql"
        out = self._ask_save_path(tr("dialog.export_result"), name, suffix)
        if out is not None:
            manager = self.manager
            self._start_export(
                out, lambda report, cancel: export_result(manager, query, title, out, report, cancel), "rows"
            )

    def _start_export(self, out: Path, task: Callable, unit: str) -> None:
        # exportacao em thread: dialogo modal com progresso e Cancelar (apaga o arquivo parcial)
        cancel = threading.Event()
        dialog = QProgressDialog(tr("export.running", name=out.name), tr("button.cancel"), 0, 0, self)
        dialog.setWindowTitle(tr("export.title"))
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
                dialog.setLabelText(tr("export.running_item", name=out.name, item=text))

        def finished(message: str, error: bool = False, warning: bool = False) -> None:
            dialog.canceled.disconnect(cancel.set)
            dialog.close()
            dialog.deleteLater()  # nao acumula dialogos "Export" escondidos
            self._set_message(self.info_label, message, error=error, warning=warning)

        def cancelled_or_done(_request_id: int, count: object) -> None:
            if count is None:
                finished(tr("export.cancelled", name=out.name), warning=True)
            else:
                finished(tr(f"export.done_{unit}", count=num(count), path=out))  # type: ignore[arg-type]

        def run(report):
            try:
                return task(report, cancel)
            except Cancelled:
                return None

        failed = lambda _id, message: finished(tr("export.failed", message=message), True)  # noqa: E731
        self._run(0, run, cancelled_or_done, failed, progress)
