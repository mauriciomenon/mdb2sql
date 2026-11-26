# Janela principal: barra de ferramentas, painel de tabelas, abas Data/Schema/SQL, painel Log e barra de status
# !T: QMainWindow with toolbar + table sidebar + data/schema/SQL views; database work runs on QThreadPool.
# !T: Every visible text comes from the language catalog (shared.i18n.tr)

import json
import os
import re
import threading
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

from PyQt6.QtCore import (
    QCoreApplication,
    QEvent,
    QLibraryInfo,
    QLocale,
    QObject,
    QPoint,
    QRunnable,
    QSettings,
    QSortFilterProxyModel,
    Qt,
    QThreadPool,
    QTimer,
    QTranslator,
    pyqtSignal,
)
from PyQt6.QtGui import QAction, QActionGroup, QFontDatabase, QGuiApplication, QIcon, QKeySequence
from PyQt6.QtWidgets import (
    QAbstractButton,
    QApplication,
    QCheckBox,
    QComboBox,
    QDockWidget,
    QFileDialog,
    QHBoxLayout,
    QHeaderView,
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
    QProxyStyle,
    QPushButton,
    QSizePolicy,
    QSplitter,
    QStackedWidget,
    QStyle,
    QStyleFactory,
    QTableView,
    QTabWidget,
    QToolBar,
    QToolButton,
    QTreeWidget,
    QTreeWidgetItem,
    QVBoxLayout,
    QWidget,
)

from backend.database_tasks import (
    TablePayload,
    load_table_payload,
    open_database,
)
from backend.db_manager import ACCESS_EXT, DBManager, sql_string, unique_names
from backend.export import (
    Cancelled,
    Sheet,
    csv_name,
    database_schema_query,
    default_save_dir,
    export_csv_folder,
    export_database,
    export_result,
    export_sheets,
    table_schema_query,
)
from backend.access import quote
from backend import temp_store
from backend.terms import not_found, parse_terms, report_sheets, search_terms, table_hits
from shared import i18n
from shared.about import app_title
from shared.bundle import resource
from shared.i18n import every_language, num, tr
from shared.tsv import rows_to_tsv
from ui.dialogs import AboutDialog, ChoiceBox, ColumnsDialog, same_size
from ui.table_model import COPY_ROLE, SORT_ROLE, TableModel, fold, search_words
from ui.widgets import FlowLayout, PathEdit, SelectionTextDelegate, WrapLabel

# linhas carregadas da tabela e do resultado SQL: 100 / 500 / 1000 nas 4 versoes (a pesquisa e os filtros vao no
# banco, alem delas; ordenar e medir as colunas rodam na thread da tela sobre as carregadas)
ROW_LIMITS = (100, 500, 1000)
MAX_COLUMN_WIDTH = 1200  # trava de seguranca: abaixo disso nenhum valor nem nome de coluna e cortado
LOG_LINES = 5000
SEARCH_DELAY_MS = 300
# grade do Schema: 6 px a mais de cada lado do texto, nas celulas e no cabecalho (igual nas 4 versoes)
SCHEMA_PAD = 6
# onde a pesquisa da aba Data procura (valor gravado em QSettings "search_scope" -> texto)
SCOPES = {"table": "scope.table", "all": "scope.all"}
# comparacao da pesquisa de termos (valor gravado em QSettings "terms_match" -> texto)
MATCHES = {"whole": "terms.whole", "contains": "terms.contains"}
# Configuracoes > Tema: valor gravado em QSettings -> esquema de cores do Qt
THEMES = {"system": Qt.ColorScheme.Unknown, "light": Qt.ColorScheme.Light, "dark": Qt.ColorScheme.Dark}
# lista de tabelas: linha selecionada com o destaque da paleta (claro e escuro)
TABLES_STYLE = "QTreeView::item:selected { background: palette(highlight); color: palette(highlighted-text); }"
# respostas das perguntas ao sair (SQLite convertido do Access nao salvo; exportacao em andamento)
SAVE, BACK, EXIT = "save", "back", "exit"


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


def app_settings() -> QSettings:
    """Configuracoes do usuario (no Windows, o registro); MDB2SQL_SETTINGS=<arquivo.ini> usa esse arquivo no lugar."""
    path = os.environ.get("MDB2SQL_SETTINGS")
    return QSettings(path, QSettings.Format.IniFormat) if path else QSettings()


_qt_texts: QTranslator | None = None


def load_qt_texts(language: str) -> None:
    """Textos do proprio Qt (menu de contexto dos campos, botoes de dialogo) no idioma escolhido; ingles sem arquivo."""
    global _qt_texts
    app = QCoreApplication.instance()
    if app is None:
        return
    if _qt_texts is not None:
        app.removeTranslator(_qt_texts)
    _qt_texts = QTranslator(app)
    if _qt_texts.load(QLocale(language), "qtbase", "_", QLibraryInfo.path(QLibraryInfo.LibraryPath.TranslationsPath)):
        app.installTranslator(_qt_texts)


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


def path_key(path: Path) -> str:
    """Chave do arquivo nas configuracoes: caminho absoluto, sem diferenca de maiusculas (Windows)."""
    return str(path.resolve()).lower()


def file_key(path: Path) -> str:
    """Versao do arquivo: tamanho e data de modificacao ('' se nao der para ler)."""
    try:
        info = path.stat()
    except OSError:
        return ""
    return f"{info.st_size}|{info.st_mtime_ns}"


def counted(key: str, count: int, **values: object) -> str:
    """Texto com o plural certo: a chave '<key>_one' quando count == 1 ('1 tabela'), '<key>' nos outros casos."""
    return tr(f"{key}_one" if count == 1 else key, count=num(count), **values)


class PaddedStyle(QProxyStyle):
    """Estilo do app com `pad` px a mais de cada lado do texto das celulas e do cabecalho (grade do Schema).

    !T: Item views place the text PM_FocusFrameHMargin + 1 from each cell edge and headers PM_HeaderMargin from each
    !T: section edge; raising both moves the text and widens the size hints (fit to contents) on both sides
    """

    def __init__(self, pad: int) -> None:
        super().__init__(QStyleFactory.create(QApplication.style().name()))
        self.pad = pad

    def pixelMetric(self, metric, option=None, widget=None) -> int:  # noqa: N802 (Qt)
        value = super().pixelMetric(metric, option, widget)
        if metric in (QStyle.PixelMetric.PM_FocusFrameHMargin, QStyle.PixelMetric.PM_HeaderMargin):
            return value + self.pad
        return value


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
        self.settings = app_settings()
        # textos fixos da tela (aplicar, chave, sem &): Configuracoes > Idioma troca todos na hora
        self._texts: list[tuple[Callable[[str], object], str, bool]] = []
        self.manager: DBManager | None = None
        self.current_db_path: Path | None = None
        self.current_db_key = ""  # tamanho|data do arquivo aberto, lidos ao abrir (Access salvo como SQLite)
        self.pending_table_name: str | None = None
        self.loaded_table: tuple[str, int] | None = None  # (name, total rows in the table)
        self.loaded_schema: list[dict[str, Any]] = []  # schema da tabela carregada, como o backend devolve
        self.table_counts: dict[str, int | None] = {}  # linhas de cada tabela (lista de tabelas)
        self.table_order: list[str] = []  # tabelas na ordem do arquivo
        self.favorites: set[str] = set()  # tabelas favoritas, pelo nome, enquanto o programa estiver aberto
        self.sql_query: str | None = None  # ultima consulta da aba SQL que deu certo (para exportar)
        # filtros coluna = valor (clique direito) e colunas ocultas: valem para view_table, ate trocar de tabela
        self.view_table: str | None = None
        self.filters: list[tuple[str, Any]] = []
        self.hidden_columns: set[str] = set()
        # linhas marcadas da aba Dados: tabela -> identidades (MARK_KEY), enquanto o arquivo estiver aberto
        self.marks: dict[str, set[Any]] = {}
        self.loaded_shown = 0  # linhas da consulta na grade (sem as marcadas que vieram so por estarem marcadas)
        self.loaded_only_marked = False  # a grade carregada mostra so as marcadas
        # paginas da aba Dados: o comeco da pagina pedida e o da pagina carregada (tamanho = a lista Linhas)
        self.page_offset = 0
        self.loaded_offset = 0
        self.matched_rows = 0  # linhas da tabela que passam nos filtros e na pesquisa
        self.loaded_search = ""  # pesquisa usada na consulta da tabela carregada
        self.loaded_filters: list[tuple[str, Any]] = []  # filtros usados na consulta da tabela carregada
        self.converted_saved = False  # o banco aberto ja foi gravado por Salvar: nada a perguntar ao sair
        # trabalho longo em andamento (_start_job): o que o cancela e, numa exportacao, o nome do arquivo
        self._job: tuple[threading.Event, str] | None = None
        self._table_request = 0
        self._sql_request = 0
        self._db_request = 0
        self._found_request = 0  # pesquisa em todas as tabelas
        self._terms_request = 0  # grade da aba Termos
        self.terms_result: dict[str, Any] | None = None  # ultima pesquisa de termos (backend.terms.search_terms)
        self._busy = 0
        self.thread_pool: QThreadPool = QThreadPool.globalInstance() or QThreadPool(self)
        # pasta temporaria da sessao (SQLite convertidos): a do usuario, senao a do sistema; sem nenhuma das duas, a
        # do arquivo Access, ao abrir. As sobras de uma sessao anterior que caiu sao apagadas
        folders = temp_store.temp_folders()
        stale = sum(temp_store.remove_stale(folder) for folder in folders)
        self.session = temp_store.open_session(folders)

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
        self._log_stale(stale)

    # ------------------------------------------------------------------ UI

    def init_ui(self):
        self.setWindowTitle(app_title())
        self.resize(1200, 800)

        self._create_actions()
        self._create_central()
        self._create_sidebar()
        self._create_log()
        self._create_top_bar()
        self._create_menus()
        self._create_status_bar()
        self._update_export_actions()

        # Ordem do Tab: filtro de tabelas, lista, busca, dados
        QWidget.setTabOrder(self.table_filter, self.table_list)
        QWidget.setTabOrder(self.table_list, self.search_edit)
        QWidget.setTabOrder(self.search_edit, self.data_table)

    def _t(self, apply: Callable[[str], object], key: str, plain: bool = False) -> None:
        """Texto fixo da tela pelo catalogo (plain: sem o & do atalho), lembrado para o idioma trocar na hora."""
        self._texts.append((apply, key, plain))
        text = tr(key)
        apply(text.replace("&", "") if plain else text)

    def _action(self, key: str, slot: Callable, shortcut: QKeySequence | str | None = None,
                checkable: bool = False) -> QAction:
        action = QAction(self, checkable=checkable)
        self._t(action.setText, key)
        if shortcut is not None:
            action.setShortcut(QKeySequence(shortcut))
        action.triggered.connect(slot)
        return action

    def _create_actions(self) -> None:
        self.open_action = self._action("action.open", self.choose_database, QKeySequence.StandardKey.Open)
        self._t(self.open_action.setToolTip, "tip.open")
        self.open_typed_action = self._action("action.open_typed", self.open_typed_path)  # = Enter no caminho
        self._t(self.open_typed_action.setToolTip, "tip.open_path")
        self.reload_action = self._action("action.reload", self.load_database, "F5")
        self._t(self.reload_action.setToolTip, "tip.reload")
        self.close_db_action = self._action("action.close", self.release_database, "Ctrl+W")
        self.quit_action = self._action("action.quit", self.close, "Ctrl+Q")

        # Salvar / Salvar como...: o banco inteiro em SQLite, DuckDB ou Excel (uma aba por tabela), com qualquer
        # banco aberto; Exportar fica com o que e mais especifico
        self.save_action = self._action("action.save", lambda: self.save_database(), QKeySequence.StandardKey.Save)
        self.save_as_action = self._action("action.save_as", lambda: self.save_database(save_as=True), "Ctrl+Shift+S")

        def formats(slot: Callable[[str], None]) -> list[QAction]:
            # CSV... / Excel (.xlsx)... de um submenu de Exportar
            return [self._action(key, lambda _c=False, s=suffix: slot(s))
                    for suffix, key in ((".csv", "export.csv"), (".xlsx", "export.xlsx"))]

        self.export_table_actions = formats(self.export_table_as)
        self.export_marked_actions = formats(self.export_marked_as)
        self.export_table_schema_actions = formats(self.export_table_schema_as)
        self.export_db_schema_actions = formats(self.export_db_schema_as)
        self.export_all_csv_action = self._action("export.all_csv", self.export_all_csv)
        self.export_sql_actions = formats(self.export_sql_as)
        self.export_search_action = self._action("export.search_all", self.export_search_all)
        self.copy_log_action = self._action(
            "action.copy_log", lambda: QGuiApplication.clipboard().setText(self.log_view.toPlainText())
        )

        # linhas marcadas (aba Dados): Espaco na grade, Editar e o menu da celula marcam/desmarcam a linha atual
        self.mark_action = self._action("action.mark", self.toggle_current_mark, "Space")
        self.mark_action.setShortcutContext(Qt.ShortcutContext.WidgetWithChildrenShortcut)
        self.unmark_all_action = self._action("action.unmark_all", self.unmark_all)
        self.only_marked_action = self._action("action.only_marked", self.set_only_marked, checkable=True)

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
        self._t(self.columns_action.setIconText, "action.columns")  # !T: The default iconText drops the "..."
        self._t(self.columns_action.setToolTip, "tip.columns")

        self.find_action = self._action("action.find", self._focus_search, QKeySequence.StandardKey.Find)
        self.tables_action = self._action("action.go_tables", self._focus_tables, "Ctrl+T")
        self.favorite_action = self._action("action.fav_toggle", lambda: self.toggle_favorite(), "Ctrl+D")
        self.data_tab_action = self._action("tab.data_menu", lambda: self.tabs.setCurrentIndex(0), "Ctrl+1")
        self.schema_tab_action = self._action("tab.schema_menu", lambda: self.tabs.setCurrentIndex(1), "Ctrl+2")
        self.sql_tab_action = self._action("tab.sql_menu", self._focus_sql, "Ctrl+3")
        self.run_sql_action = self._action("action.run_sql", self.run_sql, "Ctrl+Return")
        self._t(self.run_sql_action.setToolTip, "tip.run_sql")
        # aba Termos (Ctrl+4); Ctrl+Enter nela pesquisa os termos (a acao do SQL fica desabilitada na aba Termos e a
        # dos termos fora dela: um atalho so valendo de cada vez)
        self.terms_tab_action = self._action("tab.terms_menu", self._focus_terms, "Ctrl+4")
        self.run_terms_action = self._action("terms.run", self.run_terms)
        # o menu mostra "Ctrl+Enter" (o texto das 4 versoes); Ctrl com o Enter principal (Return) tambem vale
        for action in (self.run_sql_action, self.run_terms_action):
            action.setShortcuts([QKeySequence("Ctrl+Enter"), QKeySequence("Ctrl+Return")])
        self.copy_hits_action = self._action("terms.copy_hits", self.copy_term_hits)
        self.export_terms_actions = []
        for suffix, key in ((".xlsx", "export.xlsx"), (".csv", "export.csv"), (".sqlite", "export.sqlite"),
                            (".duckdb", "export.duckdb")):
            self.export_terms_actions.append(self._action(key, lambda _c=False, s=suffix: self.export_terms_as(s)))
        # Valor inteiro | Contem na aba Termos; o padrao em Configuracoes > Comparacao dos termos (gravado)
        match = self.default_match()
        self.match_group = QActionGroup(self)
        self.match_actions: dict[str, QAction] = {}
        self.default_match_group = QActionGroup(self)
        self.default_match_actions: dict[str, QAction] = {}
        for name, key in MATCHES.items():
            action = self._action(key, lambda _checked=False: None, checkable=True)
            self._t(action.setToolTip, "terms.match_tip")
            action.setChecked(name == match)
            self.match_group.addAction(action)
            self.match_actions[name] = action
            default = self._action(key, lambda _checked=False, n=name: self.set_default_match(n), checkable=True)
            default.setChecked(name == match)
            self.default_match_group.addAction(default)
            self.default_match_actions[name] = default

        # Configuracoes > Tema: Sistema, Claro, Escuro (gravado entre execucoes)
        self.theme_group = QActionGroup(self)
        self.theme_actions: dict[str, QAction] = {}
        saved = str(self.settings.value("theme", "system"))
        for name in THEMES:
            action = self._action(f"theme.{name}", lambda _checked=False, n=name: self.set_theme(n), checkable=True)
            action.setChecked(name == saved)
            self.theme_group.addAction(action)
            self.theme_actions[name] = action

        # Configuracoes > Idioma: English (padrao), Portugues (Brasil), Espanol; vale na hora (igual nas 4 versoes)
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
        # o mesmo par na Pesquisa Avancada, sempre comecando em Todas as tabelas (BRIEF 17: o padrao da aba Dados,
        # Esta tabela, fazia a lista colada procurar so na tabela aberta e parecer que os termos nao existiam)
        self.terms_scope_group = QActionGroup(self)
        self.terms_scope_actions: dict[str, QAction] = {}
        for name, key in SCOPES.items():
            action = self._action(key, lambda _checked=False: self._search_now(), checkable=True)
            action.setChecked(name == scope)
            self.scope_group.addAction(action)
            self.scope_actions[name] = action
            terms = self._action(key, lambda _checked=False: None, checkable=True)
            terms.setChecked(name == "all")
            self.terms_scope_group.addAction(terms)
            self.terms_scope_actions[name] = terms
            default = self._action(key, lambda _checked=False, n=name: self.set_default_scope(n), checkable=True)
            default.setChecked(name == scope)
            self.default_scope_group.addAction(default)
            self.default_scope_actions[name] = default

        # Configuracoes > Exibir NULL (padrao desligado = celula vazia, como antes; gravado entre execucoes)
        self.show_null_action = QAction(self, checkable=True)
        self._t(self.show_null_action.setText, "settings.show_null")
        self.show_null_action.setChecked(self.settings.value("show_null", False, type=bool))
        self.show_null_action.toggled.connect(self.set_show_null)

    def _create_central(self) -> None:
        self.table_model = TableModel(self, markable=True)
        self._t(lambda text: setattr(self.table_model, "mark_tip", text), "mark.tip")
        self.table_model.marksChanged.connect(self._marks_changed)
        self.data_proxy, self.data_table = self._create_table_view(self.table_model, "a11y.data")
        self.schema_model = TableModel(self)
        self.schema_proxy, self.schema_table = self._create_table_view(self.schema_model, "a11y.schema")
        self.schema_style = PaddedStyle(SCHEMA_PAD)  # !T: setStyle does not take ownership: kept on the window
        self.schema_style.setParent(self)
        self.schema_table.setStyle(self.schema_style)
        self.schema_table.horizontalHeader().setStyle(self.schema_style)
        self.sql_model = TableModel(self)
        self.sql_proxy, self.sql_table = self._create_table_view(self.sql_model, "a11y.sql_result")
        self.set_show_null(self.show_null_action.isChecked())

        self.sql_edit = QPlainTextEdit()
        self.sql_edit.setAccessibleName("SQL")
        self.sql_edit.setPlaceholderText("SELECT * FROM ...")
        sql_font = QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont)
        sql_font.setPointSizeF(self.font().pointSizeF())  # monoespacada no tamanho da base (14 px), nao nos 9 pt
        self.sql_edit.setFont(sql_font)
        self.sql_edit.addAction(self.run_sql_action)
        # botao do mesmo tipo dos outros das abas (QToolButton): mesma altura e preenchimento numa linha (13 f)
        run_button = QToolButton()
        self._t(run_button.setText, "button.run")
        self._t(run_button.setAccessibleName, "action.run_sql", plain=True)
        self._t(run_button.setToolTip, "tip.run_sql")
        run_button.clicked.connect(self.run_sql)
        # linha do botao: resultado (linhas) ou erro da ultima consulta
        self.sql_info = QLabel()
        self.sql_info.setContentsMargins(6, 0, 0, 0)
        self.sql_info.setWordWrap(True)
        self._copy_menu_on(self.sql_info)
        sql_bar = QHBoxLayout()
        sql_bar.addWidget(self.sql_info, 1)
        sql_bar.addWidget(run_button)
        editor = QWidget()
        editor_layout = QVBoxLayout(editor)
        editor_layout.setContentsMargins(0, 0, 0, 4)
        editor_layout.setSpacing(6)  # o botao Executar nao encosta na caixa do SQL
        editor_layout.addWidget(self.sql_edit)
        editor_layout.addLayout(sql_bar)
        self.sql_page = QSplitter(Qt.Orientation.Vertical)
        self.sql_page.addWidget(editor)
        self.sql_page.addWidget(self.sql_table)
        self.sql_page.setSizes([160, 480])

        self.tabs = QTabWidget()
        self.tabs.setDocumentMode(True)
        self.tabs.addTab(self._create_data_page(), "")
        self.tabs.addTab(self.schema_table, "")
        self._t(lambda text: self.tabs.setTabText(0, text), "tab.data")
        self._t(lambda text: self.tabs.setTabText(1, text), "tab.schema")
        self.tabs.addTab(self.sql_page, "SQL")
        self.tabs.addTab(self._create_terms_page(), "")
        self._t(lambda text: self.tabs.setTabText(3, text), "tab.terms")
        self.tabs.currentChanged.connect(lambda _index: self._update_run_actions())
        # !T: On the tabs for the shortcut scope, on each view for its right-click menu
        copy_actions = [self.copy_action, self.copy_row_action, self.copy_row_header_action]
        self.tabs.addActions(copy_actions)
        # grade da aba Termos: os 3 copiar (sem a coluna Termo nas linhas), copiar os acertos e o relatorio
        self.terms_report_menu = QMenu(self)
        self._t(self.terms_report_menu.setTitle, "export.terms")
        self.terms_report_menu.addActions(self.export_terms_actions)
        separator = QAction(self)
        separator.setSeparator(True)
        self.terms_table.setContextMenuPolicy(Qt.ContextMenuPolicy.ActionsContextMenu)
        self.terms_table.addActions([*copy_actions, self.copy_hits_action, separator,
                                     self.terms_report_menu.menuAction()])
        # menu da celula igual nas 4 versoes (Go): na aba Data primeiro os filtros por valor, depois copiar e as linhas
        # marcadas
        separators = [QAction(self) for _ in range(2)]
        for separator in separators:
            separator.setSeparator(True)
        self.data_table.addActions([self.filter_value_action, self.clear_filters_action, separators[0]])
        for view in (self.data_table, self.schema_table, self.sql_table):
            view.setContextMenuPolicy(Qt.ContextMenuPolicy.ActionsContextMenu)
            view.addActions(copy_actions)
        self.marked_menu = QMenu(self)  # "Exportar linhas marcadas >" (as acoes de Exportar > Linhas marcadas)
        self._t(self.marked_menu.setTitle, "mark.export")
        self.marked_menu.addActions(self.export_marked_actions)
        self.data_table.addActions([separators[1], self.mark_action, self.unmark_all_action,
                                    self.marked_menu.menuAction()])
        for view in (self.data_table, self.sql_table):
            view.horizontalHeader().setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
            # !T: The slot must not hold the header itself: header wrapper <-> slot is a cycle only the GC sees, and
            # !T: after a gc.collect() the slot was gone (no menu) or freed (crash on right-click, 1.3.0)
            view.horizontalHeader().customContextMenuRequested.connect(
                lambda pos, v=view: self._popup_header_menu(v, pos)
            )

        self.empty_label = QLabel()
        self._t(self.empty_label.setText, "status.empty")
        self.empty_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.empty_label.setEnabled(False)  # texto esmaecido pela paleta do sistema

        self.stack = QStackedWidget()
        self.stack.addWidget(self.empty_label)
        self.stack.addWidget(self.tabs)
        self.setCentralWidget(self.stack)

    def _create_data_page(self) -> QWidget:
        # aba Dados igual nas 4 versoes, de cima para baixo: uma linha so com a pesquisa (Ctrl+F, estica), Esta
        # tabela | Todas as tabelas, Linhas e Colunas...; a linha dos filtros por valor (so com filtro); a grade; a
        # linha da tabela embaixo dela. Nada mais
        self.search_edit = QLineEdit()
        self._t(self.search_edit.setPlaceholderText, "search.placeholder")
        self._t(self.search_edit.setToolTip, "tip.search")
        self.search_edit.setClearButtonEnabled(True)
        self._t(self.search_edit.setAccessibleName, "search.name")
        self._fit_search_minimum()
        self.search_edit.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self.search_edit.textChanged.connect(self._search_edited)
        self.search_edit.returnPressed.connect(self._search_now)  # Enter: na hora, sem os 300 ms
        scope = QWidget()  # dois botoes de alternar juntos, um marcado
        self._t(scope.setAccessibleName, "scope.name")
        scope_row = QHBoxLayout(scope)
        scope_row.setContentsMargins(0, 0, 0, 0)
        scope_row.setSpacing(0)
        self.scope_buttons = []
        for action in self.scope_actions.values():
            button = QToolButton()
            button.setDefaultAction(action)
            scope_row.addWidget(button)
            self.scope_buttons.append(button)
        # Linhas carregadas da tabela (e do resultado SQL): 100 / 500 / 1000
        self.limit_combo = QComboBox()
        self._t(self.limit_combo.setAccessibleName, "rows.name")
        self._t(self.limit_combo.setToolTip, "tip.rows")
        for limit in ROW_LIMITS:
            self.limit_combo.addItem(str(limit), limit)  # 100 / 500 / 1000, sem separador (igual nas 4 versoes)
        self.limit_combo.currentIndexChanged.connect(self.reload_table)
        self.limit_label = QLabel()
        self._t(self.limit_label.setText, "rows.label")
        self.limit_label.setBuddy(self.limit_combo)
        rows = QWidget()  # rotulo e lista juntos: a linha nunca quebra entre os dois
        rows_row = QHBoxLayout(rows)
        rows_row.setContentsMargins(0, 0, 0, 0)
        rows_row.addWidget(self.limit_label)
        rows_row.addWidget(self.limit_combo)
        self.columns_button = QToolButton()
        self.columns_button.setDefaultAction(self.columns_action)
        # janela estreita (720 px) igual ao Go: a barra quebra a linha, nada cortado nem escondido; o campo de busca
        # estica (sem maximo) e nunca fica menor que 160 px
        bar = FlowLayout()
        bar.setContentsMargins(6, 4, 6, 0)
        bar.addWidget(self.search_edit)
        bar.addWidget(scope)
        bar.addWidget(rows)
        bar.addWidget(self.columns_button)

        # filtros ativos (um botao por filtro, clique remove) e Limpar filtros, numa linha que so aparece com filtro
        # (tambem quebra a linha)
        self.clear_filters_button = QToolButton()
        self.clear_filters_button.setDefaultAction(self.clear_filters_action)
        self.filters_bar = QWidget()
        self.filter_chips = FlowLayout(self.filters_bar)
        self.filter_chips.setContentsMargins(6, 0, 6, 0)
        self.filter_chips.addWidget(self.clear_filters_button)
        self.filters_bar.hide()

        # pesquisa em todas as tabelas: lista "TABELA (linhas encontradas)" no lugar da grade; escolher uma abre
        # essa tabela com a mesma pesquisa
        self.found_list = QListWidget()
        self._t(self.found_list.setAccessibleName, "search.found_name")
        self.found_list.itemClicked.connect(self.open_found_table)
        self.found_list.itemActivated.connect(self.open_found_table)  # Enter
        self.data_stack = QStackedWidget()
        self.data_stack.addWidget(self.data_table)
        self.data_stack.addWidget(self.found_list)

        self.data_page = QWidget()
        layout = QVBoxLayout(self.data_page)
        layout.setContentsMargins(0, 0, 0, 0)
        # barra da tabela, embaixo da grade (como o Go): linhas mostradas / encontradas / na tabela, ou a pesquisa em
        # todas as tabelas
        self.info_label = QLabel()
        self.info_label.setContentsMargins(6, 0, 6, 2)
        self.info_label.setWordWrap(True)  # janela estreita: quebra a linha, nada cortado
        self._copy_menu_on(self.info_label)
        # a direita, so com linhas marcadas: "So as marcadas" (= Exibir > So as linhas marcadas)
        self.only_marked_box = QCheckBox()
        self._t(self.only_marked_box.setText, "mark.only")
        self.only_marked_box.setContentsMargins(0, 0, 6, 2)
        self.only_marked_box.toggled.connect(self.set_only_marked)
        self.only_marked_box.hide()
        # paginas: ◀ ▶ (Anterior / Proxima), desabilitados na ponta, botoes como os outros da aba
        self.page_buttons: list[QToolButton] = []
        for text, key, step in (("◀", "page.prev", -1), ("▶", "page.next", 1)):
            button = QToolButton()
            button.setText(text)
            self._t(button.setToolTip, key)
            self._t(button.setAccessibleName, key)
            button.clicked.connect(lambda _checked=False, s=step: self.go_page(s))
            button.setEnabled(False)
            self.page_buttons.append(button)
        self.info_row = QHBoxLayout()
        self.info_row.addWidget(self.info_label, 1)
        for button in self.page_buttons:
            self.info_row.addWidget(button)
        self.info_row.addWidget(self.only_marked_box)

        layout.setSpacing(4)
        layout.addLayout(bar)
        layout.addWidget(self.filters_bar)
        layout.addWidget(self.data_stack)
        layout.addLayout(self.info_row)
        return self.data_page

    def _toggle_pair(self, actions: dict[str, QAction], name_key: str) -> QWidget:
        # dois botoes de alternar juntos, um marcado (como Esta tabela | Todas as tabelas da aba Dados)
        pair = QWidget()
        self._t(pair.setAccessibleName, name_key, plain=True)
        row = QHBoxLayout(pair)
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(0)
        for action in actions.values():
            button = QToolButton()
            button.setDefaultAction(action)
            row.addWidget(button)
        return pair

    def _create_terms_page(self) -> QWidget:
        # aba Termos (item 32), de cima para baixo: a caixa dos termos; Valor inteiro | Contem, Esta tabela | Todas as
        # tabelas, Pesquisar termos e a contagem; o resumo; as tabelas com acerto e a grade da escolhida; os nao
        # encontrados
        self.terms_edit = QPlainTextEdit()
        self._t(self.terms_edit.setPlaceholderText, "terms.hint")
        self._t(self.terms_edit.setAccessibleName, "tab.terms")
        lines = self.terms_edit.fontMetrics().lineSpacing()
        self.terms_edit.setFixedHeight(8 * lines + 2 * self.terms_edit.frameWidth() + 8)  # ~8 linhas, com rolagem
        self.terms_edit.textChanged.connect(self._count_terms)
        self.terms_edit.addAction(self.run_terms_action)  # Ctrl+Enter na caixa

        self.terms_run_button = QToolButton()  # como as alternancias da mesma linha: mesma altura (13 f)
        self._t(self.terms_run_button.setText, "terms.run")
        self.terms_run_button.clicked.connect(self.run_terms)
        self.terms_count = QLabel()
        bar = FlowLayout()
        bar.addWidget(self._toggle_pair(self.match_actions, "menu.terms_match"))
        bar.addWidget(self._toggle_pair(self.terms_scope_actions, "scope.name"))
        bar.addWidget(self.terms_run_button)
        bar.addWidget(self.terms_count)

        self.terms_summary = QLabel()
        self.terms_summary.setWordWrap(True)
        self._copy_menu_on(self.terms_summary)
        # tabelas com acerto "tabela (n)" (como a busca em todas as tabelas) e a grade da escolhida
        self.terms_found = QListWidget()
        self._t(self.terms_found.setAccessibleName, "search.found_name")
        self.terms_found.currentItemChanged.connect(
            lambda item, _previous: self._show_term_table(item.data(Qt.ItemDataRole.UserRole) if item else "")
        )
        self.terms_found.itemSelectionChanged.connect(self._sync_term_table)
        self.terms_model = TableModel(self)
        self.terms_proxy, self.terms_table = self._create_table_view(self.terms_model, "a11y.terms")
        self.terms_info = QLabel()
        self.terms_info.setContentsMargins(6, 0, 6, 2)
        self._copy_menu_on(self.terms_info)
        grid = QWidget()
        grid_layout = QVBoxLayout(grid)
        grid_layout.setContentsMargins(0, 0, 0, 0)
        grid_layout.addWidget(self.terms_table)
        grid_layout.addWidget(self.terms_info)
        results = QSplitter(Qt.Orientation.Horizontal)
        results.addWidget(self.terms_found)
        results.addWidget(grid)
        results.setStretchFactor(1, 1)
        results.setSizes([260, 900])
        self.limit_combo.currentIndexChanged.connect(lambda _index: self._show_term_table(self._term_table()))

        # nao encontrados: texto so leitura, copiavel, um termo por linha, na ordem colada
        self.not_found_title = QLabel()
        copy = QToolButton()
        self._t(copy.setText, "action.copy", plain=True)
        copy.clicked.connect(lambda: QGuiApplication.clipboard().setText(self.not_found_edit.toPlainText()))
        title_row = QHBoxLayout()
        title_row.addWidget(self.not_found_title, 1)
        title_row.addWidget(copy)
        self.not_found_edit = QPlainTextEdit()
        self.not_found_edit.setReadOnly(True)
        self.not_found_edit.setFixedHeight(4 * lines + 2 * self.not_found_edit.frameWidth() + 8)

        self.terms_page = QWidget()
        layout = QVBoxLayout(self.terms_page)
        layout.setContentsMargins(6, 6, 6, 4)
        layout.setSpacing(6)
        layout.addWidget(self.terms_edit)
        layout.addLayout(bar)
        layout.addWidget(self.terms_summary)
        layout.addWidget(results, 1)
        layout.addLayout(title_row)
        layout.addWidget(self.not_found_edit)
        self._clear_terms()
        return self.terms_page

    def _fit_search_minimum(self) -> None:
        # nunca menor que a dica inteira (nada cortado) nem que 160 px; acima disso estica com a janela
        metrics = self.search_edit.fontMetrics()
        self.search_edit.setMinimumWidth(max(160, metrics.horizontalAdvance(self.search_edit.placeholderText()) + 40))

    def _create_table_view(self, model: TableModel, name: str) -> tuple[QSortFilterProxyModel, QTableView]:
        # name: chave do catalogo do nome acessivel
        proxy = QSortFilterProxyModel(self)  # so ordena; a pesquisa vai no banco
        proxy.setSourceModel(model)
        proxy.setSortRole(SORT_ROLE)
        proxy.setSortCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)

        view = QTableView()
        self._t(view.setAccessibleName, name)
        view.setModel(proxy)
        view.setAlternatingRowColors(True)
        view.setItemDelegate(SelectionTextDelegate(view))  # celula selecionada legivel no tema claro e no escuro
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
        self._t(self.table_filter.setPlaceholderText, "tables.filter")
        self.table_filter.setClearButtonEnabled(True)
        self._t(self.table_filter.setAccessibleName, "tables.filter")
        self._t(self.table_filter.setToolTip, "tip.words")
        self.table_filter.textChanged.connect(lambda _text: self.table_filter_timer.start())
        self.table_filter.returnPressed.connect(self._filter_tables_now)  # Enter: na hora, sem os 300 ms

        # lista de tabelas com a contagem de linhas ao lado (igual nas 4 versoes, como o Zig): Tabela | Linhas
        self.table_list = QTreeWidget()
        self._t(self.table_list.setAccessibleName, "tables.title")
        self.table_list.setColumnCount(2)
        self._t(lambda text: self.table_list.headerItem().setText(0, text), "tables.column_table")
        self._t(lambda text: self.table_list.headerItem().setText(1, text), "tables.column_rows")
        self.table_list.headerItem().setTextAlignment(1, Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        self.table_list.setRootIsDecorated(False)
        self.table_list.setUniformRowHeights(True)
        self.table_list.setAllColumnsShowFocus(True)
        # selecao como faixa de destaque comum na linha inteira (o estilo windows11 desenha um cinza quase igual ao
        # fundo); cores da paleta: vale para claro e escuro
        self.table_list.setStyleSheet(TABLES_STYLE)
        header = self.table_list.header()
        header.setSectionsMovable(False)
        # nome na largura dele; Linhas ocupa o resto ate a borda (a faixa da selecao vai na linha inteira)
        # !T: Not stretchLastSection: that last section never went below 100 px, wider than the counts, which made
        # !T: a horizontal scroll and cut the Rows column with the DB4 names
        header.setStretchLastSection(False)
        header.setMinimumSectionSize(16)
        header.setSectionResizeMode(0, QHeaderView.ResizeMode.ResizeToContents)
        header.setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        # nome de tabela nunca vira "...": o painel cresce ate o nome mais longo (limite: rolagem horizontal)
        self.table_list.setTextElideMode(Qt.TextElideMode.ElideNone)
        self.table_list.setHorizontalScrollMode(QTreeWidget.ScrollMode.ScrollPerPixel)
        # !T: Signal emitido quando usuario seleciona outra tabela
        self.table_list.currentItemChanged.connect(
            lambda current, _previous: self.on_table_selected(self._table_of(current) if current is not None else "")
        )
        self.table_list.itemSelectionChanged.connect(self._sync_current_table)
        self.table_list.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.table_list.customContextMenuRequested.connect(self._popup_tables_menu)

        panel = QWidget()
        layout = QVBoxLayout(panel)
        layout.setContentsMargins(6, 6, 6, 6)
        layout.addWidget(self.table_filter)
        layout.addWidget(self.table_list)

        self.tables_dock = QDockWidget(self)
        self._t(self.tables_dock.setWindowTitle, "tables.title")
        self.tables_dock.setObjectName("tablesDock")
        # o painel de tabelas nao fecha (igual nas 4 versoes: sem o X)
        self.tables_dock.setFeatures(QDockWidget.DockWidgetFeature.NoDockWidgetFeatures)
        self.tables_dock.setWidget(panel)
        self.addDockWidget(Qt.DockWidgetArea.LeftDockWidgetArea, self.tables_dock)
        self.resizeDocks([self.tables_dock], [260], Qt.Orientation.Horizontal)

    def _create_log(self) -> None:
        # Painel Log embaixo: mensagens da sessao (hora + texto), selecionaveis, Ctrl+C e "Copiar tudo";
        # recolhido por padrao (estado lembrado); recolhido, a barra de status mostra erro > aviso > ultima acao
        self.log_view = QPlainTextEdit()
        self.log_view.setReadOnly(True)
        self._t(self.log_view.setAccessibleName, "log.title")
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
        self._t(copy_all.setText, "log.copy_all")
        copy_all.setAutoRaise(True)
        copy_all.clicked.connect(lambda: QGuiApplication.clipboard().setText(self.log_view.toPlainText()))
        self.log_collapse = QToolButton()
        self.log_collapse.setArrowType(Qt.ArrowType.DownArrow)
        self.log_collapse.setAutoRaise(True)
        self._t(self.log_collapse.setToolTip, "log.toggle_tip")
        self._t(self.log_collapse.setAccessibleName, "log.hide")
        self.log_collapse.clicked.connect(lambda: self.set_log_visible(False))
        header = QWidget()
        header_layout = QHBoxLayout(header)
        header_layout.setContentsMargins(8, 2, 4, 2)
        title = QLabel()
        self._t(title.setText, "log.title")
        header_layout.addWidget(title)
        header_layout.addStretch(1)
        header_layout.addWidget(copy_all)
        header_layout.addWidget(self.log_collapse)

        self.log_dock = QDockWidget(self)
        self._t(self.log_dock.setWindowTitle, "log.title")
        self.log_dock.setObjectName("logDock")
        self.log_dock.setFeatures(QDockWidget.DockWidgetFeature.NoDockWidgetFeatures)
        self.log_dock.setTitleBarWidget(header)
        self.log_dock.setWidget(panel)
        self.addDockWidget(Qt.DockWidgetArea.BottomDockWidgetArea, self.log_dock)
        self.log_dock.hide()
        self.log_action = QAction(self, checkable=True)
        self._t(self.log_action.setText, "menu.log")
        self.log_action.setShortcut(QKeySequence("Ctrl+L"))
        self.log_action.triggered.connect(self.set_log_visible)
        self._latest = {"error": "", "warning": ""}  # ultimo erro e ultimo aviso da sessao
        self._unread = {"error": 0, "warning": 0}  # chegaram com o painel recolhido
        self._sql_error, self._sql_error_unread = "", False  # erro da ultima consulta SQL (sai quando outra da certo)
        self._found_summary: tuple[int, str] | None = None  # pesquisa em todas as tabelas: (tabelas, termo)

    def log(self, text: str, level: str = "info") -> None:
        """Linha do painel Log; level 'error' ou 'warning' entra na barra de status quando o painel esta recolhido."""
        self.log_view.appendPlainText(f"{datetime.now():%H:%M:%S}  {text}")
        if level in self._latest:
            self._latest[level] = text
            if self.log_dock.isHidden():
                self._unread[level] += 1
        self._refresh_log_status()

    def set_log_visible(self, visible: bool) -> None:
        self.log_action.setChecked(bool(visible))
        self.log_dock.setVisible(bool(visible))
        if visible:
            self._unread = {"error": 0, "warning": 0}
            self._sql_error_unread = False
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
            if self._unread[level] and self._latest[level]:
                text = self._latest[level]
                self.status_label.setText(status_line(text))
                self.status_label.setToolTip(text)
                self.status_label.setStyleSheet(f"color: {self._alert_color(level)};")
                self.status_label.setProperty("alert", level)
                return

    def _alert_color(self, level: str) -> str:
        # !T: Colors that stay readable on the current (light or dark) system palette
        dark = self.palette().window().color().lightness() < 128
        if level == "error":
            return "#ff8a80" if dark else "#b3261e"
        return "#ffd180" if dark else "#8a5300"

    def changeEvent(self, event) -> None:  # noqa: N802 (Qt)
        super().changeEvent(event)
        # tema trocado (Configuracoes > Tema ou o do sistema): tudo acompanha, igual nas 4 versoes
        if event.type() in (QEvent.Type.PaletteChange, QEvent.Type.ApplicationPaletteChange):
            # !T: After Qt finished applying the new palette; a child timer dies with the window (a pending call on a
            # !T: deleted window would raise inside the event loop)
            if not hasattr(self, "_restyle_timer"):
                self._restyle_timer = QTimer(self)
                self._restyle_timer.setSingleShot(True)
                self._restyle_timer.setInterval(0)
                self._restyle_timer.timeout.connect(self._restyle)
            self._restyle_timer.start()

    def _restyle(self) -> None:
        # !T: A widget style sheet keeps the palette it was polished with: with the windows11 style the table list
        # !T: stayed dark after Dark -> Light. Setting it again polishes it with the new palette
        self.table_list.setStyleSheet("")
        self.table_list.setStyleSheet(TABLES_STYLE)
        # erro/aviso destacados na cor legivel no tema novo
        for label in (self.status_label, self.info_label, self.sql_info):
            level = label.property("alert")
            if level in ("error", "warning"):
                label.setStyleSheet(f"color: {self._alert_color(level)};")

    def resizeEvent(self, event) -> None:  # noqa: N802 (Qt)
        super().resizeEvent(event)
        self.log_dock.setMaximumHeight(max(self.log_view.minimumHeight() + 32, round(self.height() * 0.25)))

    def eventFilter(self, watched, event) -> bool:  # noqa: N802 (Qt)
        # !T: Checks the event type first: an exception here aborts the process, and the filter already runs while
        # !T: the window is still being built (status_label does not exist yet)
        # clique na mensagem da barra de status reexibe o log
        if event.type() == QEvent.Type.MouseButtonRelease and watched is getattr(self, "status_label", None):
            if event.button() == Qt.MouseButton.LeftButton and self.log_dock.isHidden():
                self.set_log_visible(True)
        # !T: Text fields take drops of text only; a dragged file over them opens like a drop on the window
        drag = (QEvent.Type.DragEnter, QEvent.Type.DragMove, QEvent.Type.Drop)
        if event.type() in drag and self.dropped_file(event) is not None:
            if event.type() == QEvent.Type.Drop:
                self.dropEvent(event)
            else:
                event.acceptProposedAction()
            return True
        return super().eventFilter(watched, event)

    def _create_top_bar(self) -> None:
        # linha de cima igual nas 4 versoes (Zig): caminho do arquivo ocupando a linha (longo: mostra o fim) e
        # Abrir... (a caixa de escolher arquivo, = Ctrl+O) / Exportar... a direita; o caminho digitado abre com Enter
        # (BRIEF 14); arrastar um arquivo para a janela tambem abre
        self.path_edit = PathEdit()
        self._t(self.path_edit.setPlaceholderText, "path.hint")
        self._t(self.path_edit.setAccessibleName, "path.name")
        self.path_edit.setMinimumWidth(120)
        self.path_edit.returnPressed.connect(self.open_typed_path)
        self.open_button = QPushButton()
        self._t(self.open_button.setText, "button.open")
        self._t(self.open_button.setToolTip, "tip.open")
        self.open_button.clicked.connect(self.choose_database)

        # Exportar... abre o mesmo menu de Arquivo > Exportar, logo abaixo do botao. Lista fixa, igual nas 4 versoes;
        # o que nao se aplica fica desabilitado
        self.export_menu = QMenu(self)
        self._t(self.export_menu.setTitle, "menu.export")
        self.export_submenus: list[QMenu] = []
        for key, actions in (("export.table", self.export_table_actions), ("export.marked", self.export_marked_actions),
                             ("export.table_schema", self.export_table_schema_actions),
                             ("export.db_schema", self.export_db_schema_actions), ("", [self.export_all_csv_action]),
                             ("export.sql", self.export_sql_actions), ("", [self.export_search_action])):
            if not key:
                self.export_menu.addActions(actions)
                continue
            submenu = self.export_menu.addMenu("")
            self._t(submenu.setTitle, key)
            submenu.addActions(actions)
            self.export_submenus.append(submenu)
        self.export_menu.addMenu(self.terms_report_menu)
        self.export_submenus.append(self.terms_report_menu)
        self.export_button = QPushButton()
        self._t(self.export_button.setText, "button.export")
        self._t(self.export_button.setToolTip, "tip.export")
        self.export_button.clicked.connect(
            lambda: self.export_menu.popup(self.export_button.mapToGlobal(QPoint(0, self.export_button.height())))
        )

        bar = QWidget()
        bar.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        row = QHBoxLayout(bar)
        row.setContentsMargins(6, 4, 6, 4)
        row.addWidget(self.path_edit, 1)
        for button in (self.open_button, self.export_button):
            row.addWidget(button)
        self.top_bar = toolbar = QToolBar(self)
        self._t(toolbar.setWindowTitle, "toolbar.main")
        toolbar.setObjectName("mainToolbar")
        toolbar.setMovable(False)
        toolbar.setFloatable(False)
        toolbar.toggleViewAction().setVisible(False)  # a linha de cima nao some pelo menu de contexto
        toolbar.addWidget(bar)
        self.addToolBar(toolbar)

        # arquivo arrastado para a janela (ou para um campo de texto dela) abre como o Abrir
        self.setAcceptDrops(True)
        for edit in (self.path_edit, self.search_edit, self.table_filter, self.sql_edit.viewport()):
            edit.installEventFilter(self)

    @staticmethod
    def dropped_file(event) -> Path | None:
        """O arquivo local arrastado (um so), ou None."""
        urls = event.mimeData().urls() if event.mimeData() is not None else []
        if len(urls) == 1 and urls[0].isLocalFile():
            return Path(urls[0].toLocalFile())
        return None

    def dragEnterEvent(self, event) -> None:  # noqa: N802 (Qt)
        if self.dropped_file(event) is not None and self._job is None:  # exportando: nada abre
            event.acceptProposedAction()

    def dropEvent(self, event) -> None:  # noqa: N802 (Qt)
        path = self.dropped_file(event)
        if path is not None:
            event.acceptProposedAction()
            self.path_edit.setText(str(path))
            QTimer.singleShot(0, self.open_typed_path)  # !T: after the drag ends: the open may ask (Access SQLite)

    def open_typed_path(self) -> None:
        """O caminho do campo (Enter, Abrir o caminho digitado, arquivo arrastado); vazio, a caixa de abrir."""
        text = self.path_edit.text().strip().strip('"')
        if not text:
            self.choose_database()
            return
        path = Path(text).expanduser()
        # relativo nunca vale (seria contra a pasta de trabalho, a do exe); o banco aberto continua aberto
        if not path.is_absolute() or not path.is_file():
            self._set_message(self.status_label, tr("status.not_found", path=text), error=True)
            return
        self._open_chosen(path)

    def _set_opening(self, opening: bool) -> None:
        # abrindo um arquivo: Abrir..., Ctrl+O e F5 esperam
        for item in (self.open_action, self.open_typed_action, self.reload_action, self.open_button):
            item.setEnabled(not opening)

    def _open_chosen(self, path: Path) -> None:
        self.release_database()
        self._remember_dir(path)
        self.open_database(path)

    def _create_menus(self) -> None:
        # arvore igual nas 4 versoes (todo botao tem menu); None = separador
        menu_bar = self.menuBar()
        file_menu = menu_bar.addMenu("")
        self._t(file_menu.setTitle, "menu.file")
        for item in (self.open_action, self.open_typed_action, self.reload_action, None, self.save_action,
                     self.save_as_action, self.export_menu, None, self.close_db_action, None, self.quit_action):
            self._add_item(file_menu, item)
        # !T: Also on the window: Ctrl+Q still works while a job disables the menu bar (closeEvent asks first)
        self.addAction(self.quit_action)

        edit_menu = menu_bar.addMenu("")
        self._t(edit_menu.setTitle, "menu.edit")
        for item in (self.copy_action, self.copy_row_action, self.copy_row_header_action, self.copy_log_action, None,
                     self.find_action, self.filter_value_action, self.clear_filters_action, None, self.mark_action,
                     self.unmark_all_action):
            self._add_item(edit_menu, item)

        # Exibir > Linhas: as mesmas 100 / 500 / 1000 da aba Dados
        self.rows_group = QActionGroup(self)
        self.rows_actions: list[QAction] = []
        for index, limit in enumerate(ROW_LIMITS):
            action = QAction(str(limit), self, checkable=True)
            action.triggered.connect(lambda _checked=False, i=index: self.limit_combo.setCurrentIndex(i))
            self.rows_group.addAction(action)
            self.rows_actions.append(action)
        self.rows_actions[self.limit_combo.currentIndex()].setChecked(True)
        self.limit_combo.currentIndexChanged.connect(lambda index: self.rows_actions[index].setChecked(True))
        view_menu = menu_bar.addMenu("")
        self._t(view_menu.setTitle, "menu.view")
        rows_menu, scope_menu = QMenu(self), QMenu(self)
        self._t(rows_menu.setTitle, "rows.label")
        rows_menu.addActions(self.rows_actions)
        self._t(scope_menu.setTitle, "scope.name")
        scope_menu.addActions(list(self.scope_actions.values()))
        for item in (self.data_tab_action, self.schema_tab_action, self.sql_tab_action, self.terms_tab_action, None,
                     rows_menu, self.columns_action, scope_menu, self.only_marked_action, self.tables_action,
                     self.favorite_action, None,
                     self.run_sql_action, self.run_terms_action, None, self.log_action):
            self._add_item(view_menu, item)

        self.settings_menu = menu_bar.addMenu("")
        self._t(self.settings_menu.setTitle, "menu.settings")
        for key, actions in (("menu.theme", self.theme_actions), ("menu.language", self.language_actions),
                             ("menu.search_scope", self.default_scope_actions),
                             ("menu.terms_match", self.default_match_actions)):
            submenu = self.settings_menu.addMenu("")
            self._t(submenu.setTitle, key)
            submenu.addActions(list(actions.values()))
        self.settings_menu.addAction(self.show_null_action)

        help_menu = menu_bar.addMenu("")
        self._t(help_menu.setTitle, "menu.help")
        self._t(help_menu.addAction("", self.show_about).setText, "menu.about")

    @staticmethod
    def _add_item(menu: QMenu, item: QAction | QMenu | None) -> None:
        if item is None:
            menu.addSeparator()
        elif isinstance(item, QMenu):
            menu.addMenu(item)
        else:
            menu.addAction(item)

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
        # padrao Todas as tabelas (BRIEF 18 a): com Esta tabela, a busca com a 1a tabela aberta nao achava nada
        scope = str(self.settings.value("search_scope", "all"))
        return scope if scope in SCOPES else "all"

    def set_default_scope(self, name: str) -> None:
        # grava o padrao e ja vale na aba Dados (a Pesquisa Avancada nao segue: BRIEF 17)
        self.settings.setValue("search_scope", name)
        self.default_scope_actions[name].setChecked(True)
        self.scope_actions[name].setChecked(True)
        self._search_now()

    def default_match(self) -> str:
        match = str(self.settings.value("terms_match", "whole"))
        return match if match in MATCHES else "whole"

    def set_default_match(self, name: str) -> None:
        # Configuracoes > Comparacao dos termos: grava e ja vale na aba Termos
        self.settings.setValue("terms_match", name)
        self.default_match_actions[name].setChecked(True)
        self.match_actions[name].setChecked(True)

    def set_show_null(self, show: bool) -> None:
        # so a grade: ligado mostra o texto NULL, desligado a celula fica vazia; copiar, filtrar e exportar nao mudam
        self.settings.setValue("show_null", bool(show))
        for model in (self.table_model, self.schema_model, self.sql_model):
            model.set_null_text(tr("grid.null") if show else "")

    def set_language(self, code: str) -> None:
        # vale na hora, igual nas 4 versoes: textos, menus, dicas, as barras e os textos do proprio Qt
        self.settings.setValue("language", code)
        self.language_actions[code].setChecked(True)
        i18n.set_language(code)
        load_qt_texts(code)
        self.retranslate()

    def retranslate(self) -> None:
        """Textos da tela no idioma atual (as mensagens ja mostradas na barra e no Log ficam como estao)."""
        for apply, key, plain in self._texts:
            text = tr(key)
            apply(text.replace("&", "") if plain else text)
        self._fit_search_minimum()  # a dica tem outro tamanho
        for row in range(self.table_list.topLevelItemCount()):
            item = self.table_list.topLevelItem(row)
            count = self.table_counts.get(self._table_of(item))
            item.setText(1, num(count) if count is not None else "")
        if self.loaded_schema:
            self._show_schema()
            self._fit_columns(self.schema_table)
        self._refresh_filter_bar()
        self._show_reader()
        self._apply_search()
        self._count_terms()
        self._show_terms_summary()
        self._show_term_table(self._term_table())  # coluna Termo e "mostrando X de Y" no idioma novo
        if self.manager is not None and not self.table_list.topLevelItemCount():
            self._set_message(self.info_label, tr("status.no_tables"), log=False)
        if self.data_stack.currentWidget() is self.found_list and self._found_summary is not None:
            count, search = self._found_summary
            self._set_message(self.info_label, counted("status.found", count, search=search), log=False)

    def _copy_menu_on(self, label: QLabel) -> None:
        # !T: A long message must not widen the window or squeeze the tables panel: the label takes the width it gets
        # !T: (the full text is in the tooltip, the log and the Copy menu)
        label.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
        # clique direito > Copiar (o texto inteiro), e o painel Log com o historico
        label.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        label.customContextMenuRequested.connect(lambda pos, lbl=label: self.status_menu(lbl).popup(lbl.mapToGlobal(pos)))

    def _create_status_bar(self) -> None:
        # barra de baixo igual nas 4 versoes (Go): a esquerda a seta do Log e a mensagem; a direita o contador de nao
        # lidos do Log, as colunas ocultas e como o arquivo foi lido (fixo enquanto ele estiver aberto)
        # janela estreita: a mensagem longa quebra a linha (a barra cresce so o necessario), nada cortado
        self.status_label = WrapLabel()  # o centro da janela ja diz "No database loaded"
        self._copy_menu_on(self.status_label)
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)  # indeterminado: o backend nao informa percentual
        self.progress.setTextVisible(False)
        self.progress.setFixedWidth(120)
        self.progress.hide()

        # seta que recolhe/reexibe o painel Log e o contador de erros/avisos nao lidos (so com o painel recolhido)
        self.log_toggle = QToolButton()
        self.log_toggle.setAutoRaise(True)
        self._t(self.log_toggle.setToolTip, "log.toggle_tip")
        self._t(self.log_toggle.setAccessibleName, "menu.log", plain=True)
        self.log_toggle.clicked.connect(lambda: self.set_log_visible(self.log_dock.isHidden()))
        self.log_unread = QLabel()
        self._t(self.log_unread.setToolTip, "log.unread_tip")
        self.status_label.installEventFilter(self)  # clique na mensagem reexibe o log
        self.hidden_label = QLabel()  # "2 colunas ocultas" da tabela aberta na aba Data
        self.hidden_label.hide()
        self.reader_label = QLabel()  # "Aberto via Access ODBC, convertido para SQLite"
        self._t(self.reader_label.setToolTip, "status.reader_tip")

        status_bar = self.statusBar()
        status_bar.addWidget(self.log_toggle)
        status_bar.addWidget(self.status_label, 1)
        status_bar.addPermanentWidget(self.progress)
        status_bar.addPermanentWidget(self.log_unread)
        status_bar.addPermanentWidget(self.hidden_label)
        status_bar.addPermanentWidget(self.reader_label)
        self.set_log_visible(False)  # sempre recolhido ao abrir, nas 4 versoes (BRIEF 18 d)

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
        label.setText(status_line(text))
        label.setToolTip(text)  # texto inteiro (erro do motor com LINE 1 e ^^^) na dica e no Log
        label.setStyleSheet("" if level == "info" else f"color: {self._alert_color(level)};")
        label.setProperty("alert", level)  # a cor volta a ser calculada quando o tema muda
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
        for row in range(self.table_list.topLevelItemCount()):
            item = self.table_list.topLevelItem(row)
            name = fold(self._table_of(item))  # o nome, sem a estrela da favorita
            item.setHidden(not all(word in name for word in words))

    @staticmethod
    def _table_of(item: QTreeWidgetItem) -> str:
        """O nome da tabela de um item da lista (o texto mostrado leva "★ " nas favoritas)."""
        return item.data(0, Qt.ItemDataRole.UserRole)

    def _table_item(self, name: str | None) -> QTreeWidgetItem | None:
        for row in range(self.table_list.topLevelItemCount()):
            item = self.table_list.topLevelItem(row)
            if self._table_of(item) == name:
                return item
        return None

    def table_names(self) -> list[str]:
        """Nomes da lista de tabelas, na ordem (as favoritas primeiro)."""
        return [self._table_of(self.table_list.topLevelItem(row)) for row in range(self.table_list.topLevelItemCount())]

    def _fill_tables(self, tables: list[str], counts: dict[str, int | None]) -> None:
        # Tabela | Linhas (numero a direita, com o separador de milhar do idioma; vazio se nao deu para contar);
        # favoritas primeiro, em ordem alfabetica, com "★ " antes do nome; as demais na ordem do arquivo
        self.table_order, self.table_counts = list(tables), counts
        favorites = sorted((name for name in tables if name in self.favorites), key=str.casefold)
        items = []
        for name in favorites + [name for name in tables if name not in self.favorites]:
            count = counts.get(name)
            item = QTreeWidgetItem([f"★ {name}" if name in self.favorites else name,
                                    num(count) if count is not None else ""])
            item.setData(0, Qt.ItemDataRole.UserRole, name)
            item.setToolTip(0, name)  # nome inteiro tambem na dica
            item.setTextAlignment(1, Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
            items.append(item)
        self.table_list.blockSignals(True)
        self.table_list.clear()
        self.table_list.addTopLevelItems(items)
        self.table_list.blockSignals(False)

    # ------------------------------------------------------ tabelas favoritas

    def toggle_favorite(self, name: str | None = None) -> None:
        """Favoritar ou desfavoritar a tabela `name` (sem ela, a tabela atual). Guardadas pelo nome, so na memoria:
        fechar, abrir outro arquivo e F5 mantem; nome que nao existe no arquivo aberto nao aparece."""
        name = name or (self.loaded_table[0] if self.loaded_table else None)
        if not name or self.manager is None:
            return
        self.favorites ^= {name}
        current = self.table_list.currentItem()
        current_name = self._table_of(current) if current is not None else None
        self._fill_tables(self.table_order, self.table_counts)
        self._filter_tables(self.table_filter.text())
        item = self._table_item(current_name)
        if item is not None:  # a mesma tabela continua a atual, sem recarregar
            self.table_list.blockSignals(True)
            self.table_list.setCurrentItem(item)
            self.table_list.blockSignals(False)

    def _popup_tables_menu(self, pos) -> None:
        # clique direito numa tabela da lista: Favoritar / Desfavoritar
        item = self.table_list.itemAt(pos)
        if item is None:
            return
        self.tables_menu(self._table_of(item)).popup(self.table_list.viewport().mapToGlobal(pos))

    def tables_menu(self, name: str) -> QMenu:
        menu = QMenu(self)
        menu.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        key = "fav.remove" if name in self.favorites else "fav.add"
        menu.addAction(tr(key), lambda: self.toggle_favorite(name))
        return menu

    def _current_view(self) -> QTableView | None:
        page = self.tabs.currentWidget()
        if page is self.sql_page:
            return self.sql_table
        if page is self.data_page:
            return self.data_table
        if page is self.terms_page:
            return self.terms_table
        return page if isinstance(page, QTableView) else None

    def copy_selection(self) -> None:
        # Copia o valor da celula; com varias celulas selecionadas, texto separado por TAB
        view = self._current_view()
        if view is None:
            return
        columns = len(view.model().sourceModel().columns)  # sem a caixa de marcar
        indexes = sorted((i for i in view.selectedIndexes() if i.column() < columns), key=lambda i: (i.row(), i.column()))
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
        # sem a caixa de marcar; na grade de Termos, sem a coluna Termo
        columns = range(1 if view is self.terms_table else 0, len(model.sourceModel().columns))
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
        if file_name:
            self._open_chosen(Path(file_name))

    def load_database(self):
        # Reabrir (F5): o banco aberto de novo; sem banco aberto, a caixa de escolher arquivo, nunca um banco padrao
        if self.current_db_path is None:
            self.choose_database()
            return
        self.open_database(self.current_db_path)

    def open_database(self, db_path: Path) -> None:
        if not db_path.is_file():  # uma pasta tambem: o motor daria o texto do sistema
            self._set_message(self.status_label, tr("status.not_found", path=str(db_path)), error=True)
            return

        self._set_opening(True)
        self._set_message(self.status_label, tr("status.loading", name=db_path.name))

        def progress(done: int, total: int, table: str) -> None:
            if total and table:
                text = tr("status.converting", name=db_path.name, done=num(done + 1), total=num(total), table=table)
                self._set_message(self.status_label, text, log=False)  # uma linha por tabela: fora do log

        self._db_request += 1  # abrir outro arquivo invalida a abertura anterior ainda em andamento
        if db_path.suffix.lower() in ACCESS_EXT:
            # a pasta do arquivo e o ultimo lugar do SQLite convertido: sobra de uma sessao que caiu sai agora, e
            # a sessao fica nela so quando nenhuma pasta temporaria deixou criar arquivo
            self._log_stale(temp_store.remove_stale(db_path.parent))
            self.session = self.session or temp_store.open_session([db_path.parent])
        work_dir = self.session.path if self.session else None
        # o mesmo Access (caminho, tamanho, data) ja convertido e salvo: abre o arquivo salvo (SQLite ou DuckDB), sem
        # converter de novo
        saved = self.saved_conversion(db_path)
        def task(report):
            source_key = file_key(db_path)  # a versao do arquivo que vai ser lida (lembrada se o SQLite for salvo)
            manager, tables = open_database(saved or db_path, report, work_dir)
            try:  # linhas de cada tabela para a lista; sem elas a lista abre do mesmo jeito
                counts = manager.table_counts()
            except Exception:  # noqa: BLE001 (a contagem e so informativa)
                counts = {}
            return db_path, saved, manager, tables, counts, source_key

        self._run(self._db_request, task, self._on_database_loaded, self._on_database_error, progress)

    def _log_stale(self, count: int) -> None:
        if count:
            self.log(counted("log.stale_removed", count))

    # --------------------------------- Access convertido e salvo: lembrado entre execucoes (igual nas 4 versoes)

    def _saved_conversions(self) -> dict[str, dict[str, str]]:
        try:
            saved = json.loads(str(self.settings.value("converted_files", "{}")))
        except ValueError:
            return {}
        return saved if isinstance(saved, dict) else {}

    def saved_conversion(self, source: Path) -> Path | None:
        """Arquivo salvo (SQLite ou DuckDB) deste Access, se nenhum dos dois mudou desde entao (caminho + tamanho +
        data)."""
        if source.suffix.lower() not in (".accdb", ".mdb"):
            return None
        entry = self._saved_conversions().get(path_key(source))
        if not isinstance(entry, dict) or not file_key(source) or entry.get("source") != file_key(source):
            return None
        dest = Path(str(entry.get("dest", "")))
        return dest if entry.get("dest_key") and file_key(dest) == entry.get("dest_key") else None

    def _remember_conversion(self, source: Path, source_key: str, dest: Path) -> None:
        saved = {k: v for k, v in self._saved_conversions().items()
                 if isinstance(v, dict) and Path(str(v.get("dest", ""))).is_file()}  # sem os apagados
        saved[path_key(source)] = {"source": source_key, "dest": str(dest), "dest_key": file_key(dest)}
        self.settings.setValue("converted_files", json.dumps(saved))

    def _on_database_loaded(self, request_id: int, result: object) -> None:
        db_path, saved, manager, tables, counts, source_key = result  # type: ignore[misc]
        if request_id != self._db_request:
            manager.release()  # abertura antiga terminou depois de outra mais nova: descarta (e o SQLite dela)
            return
        if saved is not None:
            # o formato do arquivo salvo (SQLite ou DuckDB), como o leitor o reconheceu ao abrir
            self.log(tr("log.reused", name=db_path.name, format=manager.reader, path=saved))
        previous = self._table_of(self.table_list.currentItem()) if self.table_list.currentItem() else None
        if db_path != self.current_db_path:
            self._reset_view(None)  # outro arquivo: filtros e colunas ocultas nao valem mais
            # nem a pesquisa da aba Data e o filtro da lista; o escopo volta ao padrao de Configuracoes (4 versoes)
            self.search_edit.clear()
            self.table_filter.clear()
            self.search_timer.stop()
            self.table_filter_timer.stop()
            self.scope_actions[self.default_scope()].setChecked(True)
            self.loaded_table = None
            self.loaded_schema = []
            self.table_model.set_rows([])
            self.schema_model.set_rows([])
        # consultas de tabela e SQL ainda pendentes sao do banco anterior: descartar o que elas devolverem
        self._table_request += 1
        self._sql_request += 1
        # reabrir (F5) o mesmo arquivo: o anterior fecha agora; o SQLite convertido dele, se nao foi salvo, e
        # descartado (Log) e substituido pelo novo, sem pergunta
        self._drop_manager()
        self._reset_marks()
        self.page_offset = 0  # reabrir (F5) tambem volta para a pagina 1
        self._clear_terms()  # a lista colada fica; o resultado era do banco anterior
        self.manager = manager
        self.current_db_path = db_path
        self.current_db_key = source_key
        self.converted_saved = False
        self.sql_query = None
        self.sql_model.set_rows([])
        self.sql_info.clear()
        self.setWindowTitle(f"{db_path.name} - {app_title()}")
        self.path_edit.setText(str(db_path))
        self.stack.setCurrentWidget(self.tabs)

        self._fill_tables(tables, counts)
        self._fit_tables_panel(tables)
        self._filter_tables(self.table_filter.text())

        # "Aberto: <arquivo> (N tabelas)"; como foi lido (Access ODBC, mdbtools, SQLite, DuckDB) fica fixo a direita
        self._set_message(self.status_label, counted("status.loaded", len(tables), name=db_path.name))
        self._show_reader()
        self._set_opening(False)
        self._update_export_actions()

        if tables:
            # !T: Keep the selected table across a reload; setCurrentItem triggers on_table_selected
            self.table_list.setCurrentItem(self._table_item(previous) or self.table_list.topLevelItem(0))
        else:
            self.loaded_table = None
            self.loaded_schema = []
            self.table_model.set_rows([])
            self.schema_model.set_rows([])
            self._set_message(self.info_label, tr("status.no_tables"), log=False)
        if self.data_stack.currentWidget() is self.found_list:
            self._search_now()  # lista de todas as tabelas: refeita no banco aberto agora

    def _show_reader(self) -> None:
        manager = self.manager
        if manager is None:
            self.reader_label.clear()
            return
        key = "status.reader_converted" if manager.converted else "status.reader"
        self.reader_label.setText(tr(key, reader=manager.reader))

    def _on_database_error(self, request_id: int, message: str) -> None:
        if request_id != self._db_request:
            return
        self._set_message(self.status_label, tr("status.error", message=message), error=True)
        self._set_opening(False)

    # ------------------------------------------- fechar e sair: SQLite convertido do Access

    def unsaved_conversion(self) -> bool:
        """O banco aberto e um Access convertido que ainda nao foi gravado por Salvar."""
        return self.manager is not None and self.manager.converted is not None and not self.converted_saved

    def _drop_manager(self) -> None:
        # fechar, abrir outro e reabrir (F5) nao perguntam: o convertido que nao foi salvo e apagado, com a linha no
        # Log
        manager, source, discarded = self.manager, self.current_db_path, self.unsaved_conversion()
        if manager is None:
            return
        manager.release()
        if discarded and source is not None:
            self.log(tr("log.discarded", name=source.name))

    def release_database(self) -> None:
        """Fecha o banco aberto, sem perguntar."""
        self._drop_manager()
        self._clear_database()

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
        self.converted_saved = False
        self._reset_marks()
        self._clear_terms()
        self.loaded_table = None
        self.loaded_schema = []
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
        self.sql_info.clear()
        self._apply_search()  # sem tabela: barra da tabela e colunas ocultas vazias
        self._show_reader()
        self._set_opening(False)
        self._update_export_actions()

    def exit_box(self, source: Path) -> ChoiceBox:
        """A pergunta ao sair com o SQLite convertido nao salvo (sem abrir): Salvar a esquerda; Voltar e Sair a
        direita. Esc e o X da caixa: Voltar."""
        return ChoiceBox(tr("converted.title"), tr("exit.text", name=source.name), {SAVE: tr("button.save")},
                         {BACK: tr("button.back"), EXIT: tr("button.exit")}, SAVE, BACK, self,
                         every_language("button.save") + every_language("button.back") + every_language("button.exit"))

    def ask_exit(self, source: Path) -> str:
        box = self.exit_box(source)
        box.exec()
        return box.choice

    def export_running_box(self, name: str) -> ChoiceBox:
        """A pergunta ao sair com uma exportacao em andamento (sem abrir): Voltar ou Sair (cancela a exportacao)."""
        return ChoiceBox(tr("export.run_title"), tr("export.run_text", name=name), {},
                         {BACK: tr("button.back"), EXIT: tr("button.exit")}, BACK, BACK, self,
                         every_language("button.back") + every_language("button.exit"))

    def ask_export_running(self, name: str) -> str:
        box = self.export_running_box(name)
        box.exec()
        return box.choice

    def closeEvent(self, event) -> None:  # noqa: N802 (Qt)
        # sair do programa (X, Arquivo > Sair, Ctrl+Q, Alt+F4). Antes de tudo, a exportacao em andamento: Sair
        # cancela (o arquivo parcial e apagado); a pesquisa de termos em andamento e cancelada sem perguntar
        if self._job is not None:
            cancel, exporting = self._job
            if exporting and self.ask_export_running(exporting) != EXIT:
                event.ignore()
                return
            # !T: No wait here: release_database() below interrupts the query still running (a long table would
            # !T: freeze the window until it ended) and the cancelled export removes its temporary file
            cancel.set()
        # so com Access convertido e nao salvo: Salvar abre a caixa de salvar (cancelada, a pergunta volta) e o
        # programa fecha depois de gravar; Sair apaga o temporario
        while self.unsaved_conversion() and self.current_db_path is not None:
            choice = self.ask_exit(self.current_db_path)
            if choice == EXIT:
                break
            if choice == BACK or self.save_database(then=self.close):
                event.ignore()
                return
        self.release_database()
        # sobra da sessao (conversao ainda em andamento) some quando as threads terminam
        self.thread_pool.waitForDone()
        if self.session is not None:
            self.session.close()
        super().closeEvent(event)

    # --------------------------------------------------------------- table

    def reload_table(self) -> None:
        # limite, filtro e pesquisa: consulta na hora (a pesquisa ja esperou os 300 ms); os 150 ms de
        # table_load_timer sao so da navegacao pela lista com as setas. Volta para a pagina 1
        self.page_offset = 0
        item = self.table_list.currentItem()
        if item is not None:
            self.on_table_selected(self._table_of(item))
            self._start_table_worker()

    def go_page(self, step: int) -> None:
        """◀ / ▶: a pagina anterior ou a proxima da tabela aberta (mesma pesquisa, filtros e marcadas no topo)."""
        item = self.table_list.currentItem()
        if item is None or self.loaded_table is None:
            return
        self.page_offset = max(0, self.loaded_offset + step * int(self.limit_combo.currentData()))
        self.on_table_selected(self._table_of(item))
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
        self._found_summary = None
        everywhere =self.scope_actions["all"].isChecked() and bool(self.search_edit.text().split())
        self.data_stack.setCurrentWidget(self.found_list if everywhere else self.data_table)
        self._update_export_actions()  # Exportar > Resultado da busca em todas as tabelas: so com a lista
        if everywhere:  # a lista de tabelas nao tem paginas
            for button in self.page_buttons:
                button.setEnabled(False)
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
        search = self.search_edit.text().strip()
        self._found_summary = (len(found), search)  # refeito no idioma novo se o idioma mudar
        self._set_message(self.info_label, counted("status.found", len(found), search=search), log=False)
        self._update_export_actions()

    def _on_found_error(self, request_id: int, message: str) -> None:
        if request_id == self._found_request:
            self._set_message(self.status_label, tr("status.error", message=message), error=True)
            self._apply_search()  # sai o "Pesquisando": a barra da tabela volta para a tabela aberta

    def open_found_table(self, item: QListWidgetItem) -> None:
        # a tabela escolhida abre na aba Data com a mesma pesquisa e sem filtros por valor (a grade mostra o numero
        # listado, igual nas 4 versoes); o escopo volta para esta tabela
        self.scope_actions["table"].setChecked(True)
        self.filters.clear()
        self._refresh_filter_bar()
        found = self._table_item(item.data(Qt.ItemDataRole.UserRole))
        if found is not None:
            self.table_list.setCurrentItem(found)
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
        marked = list(self.marks.get(table_name, ()))
        only_marked = self.only_marked_action.isChecked() and bool(marked)
        offset = self.page_offset
        self.pending_table_name = None
        self._table_request += 1
        self._run(
            self._table_request,
            lambda _report: (only_marked, load_table_payload(manager, table_name, limit, filters, search, marked,
                                                             only_marked, offset)),
            self._on_table_loaded,
            self._on_table_error,
        )

    def tables_panel_width(self, tables: list[str]) -> int:
        """Largura do painel para o nome mais longo e a contagem caberem inteiros: 260..35% da janela (acima disso,
        rolagem)."""
        tree = self.table_list
        metrics = tree.fontMetrics()
        # o nome com a estrela de favorita, se for uma
        longest = max((metrics.horizontalAdvance(f"★ {name}" if name in self.favorites else name) for name in tables),
                      default=0)
        # margens do item no estilo atual, medidas na propria lista (o windows11 poe mais que o Fusion)
        listed = [tree.topLevelItem(i).text(0) for i in range(tree.topLevelItemCount())]
        shown = max((metrics.horizontalAdvance(name) for name in listed), default=0)
        padding = tree.sizeHintForColumn(0) - shown if listed else 16
        rows = max(tree.sizeHintForColumn(1), tree.header().sectionSizeHint(1))  # contagem ou o titulo Linhas
        scrollbar = self.style().pixelMetric(QStyle.PixelMetric.PM_ScrollBarExtent)
        # colunas + barra de rolagem + moldura da lista + margens do painel (6 + 6) + folga
        needed = longest + padding + rows + scrollbar + 2 * tree.frameWidth() + 12 + 4
        return max(260, min(needed, round(self.width() * 0.35)))

    def _fit_tables_panel(self, tables: list[str]) -> None:
        # o separador do painel continua arrastavel; so ajusta na abertura do arquivo
        self.resizeDocks([self.tables_dock], [self.tables_panel_width(tables)], Qt.Orientation.Horizontal)

    def _fit_columns(self, view: QTableView, columns: list[int] | None = None) -> None:
        """Largura das colunas (todas sem `columns`) pelo texto mais longo: cabecalho ou valor de qualquer linha."""
        model: TableModel = view.model().sourceModel()
        # margem do texto pelo estilo da grade (no Schema, 6 px a mais de cada lado: PaddedStyle)
        padding = 2 * (view.style().pixelMetric(QStyle.PixelMetric.PM_FocusFrameHMargin, None, view) + 1) + 8
        for column in range(len(model.columns)) if columns is None else columns:
            view.resizeColumnToContents(column)  # !T: Qt takes the larger of the header text and the content
            # !T: Qt measures only the first rows (resize precision); the longest texts of all loaded rows are
            # !T: measured here so no value is cut with "..."; only above MAX_COLUMN_WIDTH (tooltip has the full text)
            metrics = view.fontMetrics()
            longest = max((metrics.horizontalAdvance(text) for text in model.longest_texts(column)), default=0)
            width = max(view.columnWidth(column), longest + padding)
            view.setColumnWidth(column, min(width, MAX_COLUMN_WIDTH))

    def _on_table_loaded(self, request_id: int, result: object) -> None:
        if request_id != self._table_request:
            return  # resposta de uma selecao antiga

        payload: TablePayload
        self.loaded_only_marked, payload = result  # type: ignore[misc]
        schema = payload["schema"]
        self.table_model.marks = self.marks.setdefault(payload["table_name"], set())
        self.table_model.set_rows(
            payload["rows"],
            [column["column_name"] for column in schema],
            [f"{column['column_name']}: {column['column_type']}" for column in schema],
        )
        self.loaded_schema = schema
        self._show_schema()
        self.loaded_table = (payload["table_name"], payload["total_rows"])
        self.loaded_shown = payload["shown"]
        self.loaded_offset = payload["offset"]
        self.matched_rows = payload["matched_rows"]
        self.loaded_filters = list(payload["filters"])  # os da consulta que deu esta contagem
        self.loaded_search = payload["search"]

        for view in (self.data_table, self.schema_table):
            view.sortByColumn(-1, Qt.SortOrder.AscendingOrder)  # volta para a ordem do backend
            self._fit_columns(view)
        self._place_mark_column()
        self._apply_hidden_columns()  # o reset do modelo mostra todas: oculta de novo as escolhidas
        self._apply_search()
        self._update_export_actions()

    def _show_schema(self) -> None:
        # titulos e nulidade traduzidos (Coluna / Tipo / Aceita nulo; Sim / Nao): as chaves e o YES/NO do backend nao
        # vao para a tela
        titles = {"column_name": tr("schema.column"), "column_type": tr("schema.type"), "null": tr("schema.nullable")}
        answer = {"YES": tr("schema.yes"), "NO": tr("schema.no")}
        rows = [{titles[k]: answer.get(v, v) if k == "null" else v for k, v in column.items()}
                for column in self.loaded_schema]
        self.schema_model.set_rows(rows, list(titles.values()))

    def _on_table_error(self, request_id: int, message: str) -> None:
        if request_id == self._table_request:
            self._set_message(self.status_label, tr("status.table_error", message=message), error=True)
            self._apply_search()  # sai o "Carregando": a barra da tabela volta para a tabela que esta na grade

    def _apply_search(self) -> None:
        # barra da tabela (aba Data) e colunas ocultas (barra de baixo); pesquisa e filtros ja vieram aplicados da
        # consulta ao banco
        hidden = sum(name in self.hidden_columns for name in self.table_model.columns)
        self.hidden_label.setText(counted("status.hidden", hidden) if hidden else "")
        self.hidden_label.setVisible(bool(hidden))
        if self.loaded_table is None:
            self.info_label.clear()
            self.only_marked_box.hide()
            for button in self.page_buttons:
                button.setEnabled(False)
            return

        # "{tabela}: linhas 1 a 100 de 36.804" (com busca ou filtro: "... de N encontradas"); so as marcadas: elas
        table, total_rows = self.loaded_table
        narrowed = (self.loaded_filters or self.loaded_search.split()) and not self.loaded_only_marked
        count = self.loaded_shown if self.loaded_only_marked else self.matched_rows if narrowed else total_rows
        first, last = self.loaded_offset + 1, self.loaded_offset + self.loaded_shown
        values = {"table": table, "first": num(first), "last": num(last), "count": num(count)}
        message = tr("page.none" if not self.loaded_shown else "page.row" if first == last else "page.rows", **values)
        if narrowed:
            message += counted("page.found", count)
        marked = len(self.marks.get(table, ()))
        if marked:
            message += counted("mark.count", marked)
        self._set_message(self.info_label, message, log=False)
        self.only_marked_box.setVisible(bool(marked))
        # ◀ desabilitado na primeira pagina; ▶ na ultima (e as duas com "So as marcadas", que nao tem paginas)
        self.page_buttons[0].setEnabled(self.loaded_offset > 0 and not self.loaded_only_marked)
        self.page_buttons[1].setEnabled(last < count and not self.loaded_only_marked)

    # ----------------------------------------------------- linhas marcadas

    def _place_mark_column(self) -> None:
        # a caixa de marcar e a ultima coluna do modelo, mostrada primeiro, estreita, e as colunas da tabela na ordem
        # dela
        # !T: A model reset keeps the visual order and the resize mode of the sections that still exist: with another
        # !T: column count the previous move would shuffle the table columns and leave a table column Fixed, so every
        # !T: section is put back in place and made Interactive (user resizable) again
        column = self.table_model.mark_column()
        if column < 0:
            return
        header = self.data_table.horizontalHeader()
        for visual, logical in enumerate([column, *range(column)]):
            header.moveSection(header.visualIndex(logical), visual)
            header.setSectionResizeMode(logical, QHeaderView.ResizeMode.Interactive)
        header.setSectionResizeMode(column, QHeaderView.ResizeMode.Fixed)
        self.data_table.setColumnHidden(column, False)  # nem a coluna oculta de outra tabela na mesma posicao
        indicator = self.data_table.style().pixelMetric(QStyle.PixelMetric.PM_IndicatorWidth, None, self.data_table)
        self.data_table.setColumnWidth(column, indicator + 16)

    def toggle_current_mark(self) -> None:
        """Marca ou desmarca a linha atual da grade de Dados (Espaco, Editar, menu da celula)."""
        if self.loaded_table is None or self.data_stack.currentWidget() is not self.data_table:
            return
        index = self.data_table.currentIndex()
        selected = self.data_table.selectedIndexes()
        if selected and index not in selected:
            index = selected[0]  # !T: UI Automation / screen readers select a cell without making it current
        index = self.data_proxy.mapToSource(index)
        if index.isValid():
            self.table_model.toggle_mark(index.row())

    def unmark_all(self) -> None:
        """Desmarca todas as linhas da tabela atual (as marcas sao por tabela)."""
        if self.table_model.marks:
            self.table_model.marks.clear()
            self.table_model.marks_reset()

    def _marks_changed(self) -> None:
        # a linha marcada ou desmarcada fica onde esta ate a proxima consulta (nada pula na grade); sem marcas, "So as
        # marcadas" desliga e a grade volta para a pesquisa
        if not self.table_model.marks and self.only_marked_action.isChecked():
            self.set_only_marked(False)
        self._apply_search()
        self._update_export_actions()

    def set_only_marked(self, checked: bool) -> None:
        """Exibir > So as linhas marcadas e a caixa ao lado da linha da tabela: a grade so com as marcadas."""
        self._check_only_marked(checked)
        self.reload_table()

    def _check_only_marked(self, checked: bool) -> None:
        for control in (self.only_marked_action, self.only_marked_box):
            control.blockSignals(True)
            control.setChecked(bool(checked))
            control.blockSignals(False)

    def _reset_marks(self) -> None:
        # fechar, abrir outro arquivo e reabrir limpam as marcas
        self.marks = {}
        self.table_model.marks = set()
        self._check_only_marked(False)

    def export_marked_as(self, suffix: str) -> None:
        # as marcadas da tabela atual, todas as colunas, na ordem da tabela: <tabela>_marcadas
        if self.manager is None or self.loaded_table is None or not self.marks.get(self.loaded_table[0]):
            return
        table, manager = self.loaded_table[0], self.manager
        query, params = manager.marked_query(table, list(self.marks[table]))
        out = self._ask_save_path(tr("export.marked"), f"{table}_marcadas", (suffix,))
        if out is not None:
            self._start_export(
                out, lambda report, cancel: export_result(manager, query, table, out, report, cancel, params), "rows"
            )

    # ----------------------------------------------- filtros e colunas ocultas

    def _reset_view(self, table_name: str | None) -> None:
        self.view_table = table_name
        self.filters.clear()
        self.hidden_columns.clear()
        self._check_only_marked(False)  # "So as marcadas" vale para a tabela em que foi ligado (marcas por tabela)
        self.page_offset = 0  # outra tabela (ou outro arquivo): pagina 1
        self._refresh_filter_bar()

    def filter_by_current_cell(self) -> None:
        # celula atual da aba Data (o clique direito e o Shift+F10 agem sobre ela): valor Python lido do banco
        index = self.data_table.currentIndex()
        selected = self.data_table.selectedIndexes()
        if selected and index not in selected:
            index = selected[0]  # !T: UI Automation / screen readers select a cell without making it current
        index = self.data_proxy.mapToSource(index)
        if index.isValid() and index.column() < len(self.table_model.columns):  # nao a caixa de marcar
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
        while self.filter_chips.count():  # rotulo e botoes dos filtros; o Limpar filtros volta no fim
            widget = self.filter_chips.takeAt(0).widget()
            if widget is not self.clear_filters_button:
                widget.deleteLater()
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
        self.filter_chips.addWidget(self.clear_filters_button)
        self.filters_bar.setVisible(bool(self.filters))
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
        table = self.loaded_table[0] if self.loaded_table else ""
        dialog = ColumnsDialog(table, self.table_model.columns, self.hidden_columns, self)
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
        # sem coluna oculta nao ha o que mostrar (igual nas 4 versoes)
        menu.addAction(tr("columns.show_all_columns"), lambda: self._set_hidden(view, set())).setEnabled(bool(hidden))
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
        self._set_message(self.sql_info, tr("status.sql_running"), log=False)
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
            message = counted("status.sql_first" if more else "status.sql_rows", len(rows))
        # deu certo: o erro da consulta anterior sai da linha do botao e da barra de baixo (igual nas 4 versoes)
        if self._sql_error:
            if self._latest["error"] == self._sql_error:
                self._latest["error"] = ""
            if self._sql_error_unread:
                self._unread["error"] = max(0, self._unread["error"] - 1)
            self._sql_error = ""
        self._set_message(self.sql_info, message, log=False)
        self._set_message(self.status_label, message)
        self._update_export_actions()

    def _on_sql_error(self, request_id: int, message: str) -> None:
        if request_id != self._sql_request:
            return
        # o erro limpa a grade da consulta anterior (e o que exportar); o texto do banco vai como vem, depois do
        # prefixo traduzido
        self.sql_model.set_rows([])
        self.sql_query = None
        self._update_export_actions()
        # comando que nao e de leitura: a recusa vai como esta, sem o prefixo de erro do banco
        text = message if message == tr("error.sql_read_only") else tr("status.sql_error", message=message)
        self._sql_error, self._sql_error_unread = text, self.log_dock.isHidden()
        self._set_message(self.sql_info, text, error=True, log=False)  # na linha do botao Executar
        self._set_message(self.status_label, text, error=True)

    # ---------------------------------------------------- pesquisa de termos

    def _focus_terms(self) -> None:
        self.tabs.setCurrentWidget(self.terms_page)
        self.terms_edit.setFocus()

    def _count_terms(self) -> None:
        # "8 termos, 2 repetidos" enquanto o texto muda
        terms, repeated = parse_terms(self.terms_edit.toPlainText())
        text = counted("terms.count", len(terms)) if terms else ""
        if repeated:
            text += counted("terms.repeated", repeated)
        self.terms_count.setText(text)
        self._update_run_actions()

    def _update_run_actions(self) -> None:
        # Ctrl+Enter: na aba Termos pesquisa os termos, nas outras roda o SQL
        terms_tab = self.tabs.currentWidget() is self.terms_page
        ready = self.manager is not None and bool(parse_terms(self.terms_edit.toPlainText())[0])
        self.run_sql_action.setEnabled(not terms_tab)
        self.run_terms_action.setEnabled(terms_tab and ready)
        self.terms_run_button.setEnabled(ready)

    def run_terms(self) -> None:
        """Pesquisar termos: cada termo da caixa em todas as colunas das tabelas do escopo, no motor, com progresso e
        Cancelar; o resultado anterior sai na hora (nunca aparece um resultado velho)."""
        terms, _repeated = parse_terms(self.terms_edit.toPlainText())
        if self.manager is None or not terms or self._job is not None:
            return
        only = None if self.terms_scope_actions["all"].isChecked() else self.loaded_table[0] if self.loaded_table else ""
        if only is None:
            tables = [table for table in self.table_names() if self.table_counts.get(table) != 0]  # vazias: nada
        else:
            tables = [only] if only else []
        self._clear_terms()
        self._update_export_actions()  # sem resultado (cancelada ou com erro): relatorio e copiar desabilitados
        if not tables:
            return
        manager, contains = self.manager, self.match_actions["contains"].isChecked()

        def progress(report):
            return lambda done, total, table: report(done, total, tr(
                "terms.progress", done=num(done + 1), total=num(total), table=table) if table else "")

        self._start_job(tr("terms.run"), tr("terms.progress", done=num(1), total=num(len(tables)), table=tables[0]),
                        lambda report, cancel: {**search_terms(manager, terms, contains, tables, progress(report), cancel),
                                                "only": only},
                        self._on_terms_done, "")

    def _on_terms_done(self, result: object) -> None:
        self.terms_result = result  # type: ignore[assignment]
        for table, counts in self.terms_result["hits"]:  # type: ignore[index]
            item = QListWidgetItem(tr("search.found_item", table=table, count=num(sum(counts.values()))))
            item.setData(Qt.ItemDataRole.UserRole, table)
            self.terms_found.addItem(item)
        self._show_terms_summary()
        self._update_export_actions()
        if self.terms_found.count():
            self.terms_found.setCurrentRow(0)  # a primeira ja escolhida

    def _show_terms_summary(self) -> None:
        result = self.terms_result
        if result is None:
            self.terms_summary.clear()
            self.not_found_title.setText(tr("terms.not_found", count=num(0)))
            return
        missing = not_found(result)
        rows = sum(sum(counts.values()) for _table, counts in result["hits"])
        found = counted("terms.found", len(result["terms"]), found=num(len(result["terms"]) - len(missing)))
        summary = tr("terms.summary", found=found, rows=counted("terms.rows", rows),
                     tables=counted("terms.tables", len(result["hits"])))
        if result.get("only"):  # Esta tabela: diz onde pesquisou, para o termo nunca parecer ausente do banco
            summary = tr("terms.summary_only", summary=summary, table=result["only"])
        self.terms_summary.setText(summary)
        self.not_found_title.setText(tr("terms.not_found", count=num(len(missing))))
        self.not_found_edit.setPlainText("\n".join(missing))

    def _clear_terms(self) -> None:
        # sem resultado: lista, grade, resumo e nao encontrados vazios (a caixa dos termos fica)
        self.terms_result = None
        self._terms_request += 1
        self.terms_found.blockSignals(True)
        self.terms_found.clear()
        self.terms_found.blockSignals(False)
        self.terms_model.set_rows([])
        self.terms_info.clear()
        self.not_found_edit.clear()
        self._show_terms_summary()

    def _sync_term_table(self) -> None:
        # !T: UI Automation / screen readers select an item without making it current; follow the selection
        items = self.terms_found.selectedItems()
        if items and items[0] is not self.terms_found.currentItem():
            self.terms_found.setCurrentItem(items[0])

    def _term_table(self) -> str:
        item = self.terms_found.currentItem()
        return item.data(Qt.ItemDataRole.UserRole) if item is not None else ""

    def _show_term_table(self, table: str) -> None:
        # a grade da tabela escolhida, limitada como a aba Dados (Linhas 100/500/1000); copiar e o relatorio usam todas
        if self.manager is None or self.terms_result is None or not table:
            return
        query, params = table_hits(self.terms_result, table)
        manager, limit = self.manager, self.limit_combo.currentData()
        self._terms_request += 1
        self._run(self._terms_request, lambda _report: (table, manager.fetch_rows(query, params, limit)),
                  self._on_term_rows, self._on_term_rows_error)

    def _on_term_rows(self, request_id: int, result: object) -> None:
        if request_id != self._terms_request or self.terms_result is None:
            return
        table, rows = result  # type: ignore[misc]
        # os nomes que a consulta devolve: uma coluna da tabela com o nome da coluna Termo vem como Termo_2
        columns = list(rows[0]) if rows else unique_names([tr("terms.column"), *self.terms_result["columns"][table]])
        self.terms_model.set_rows(rows, columns)
        self.terms_table.sortByColumn(-1, Qt.SortOrder.AscendingOrder)
        self._fit_columns(self.terms_table)
        total = dict(self.terms_result["hits"])[table]
        self._set_message(self.terms_info, counted("status.showing", sum(total.values()), table=table,
                                                   loaded=num(len(rows))), log=False)

    def _on_term_rows_error(self, request_id: int, message: str) -> None:
        if request_id == self._terms_request:
            self._set_message(self.status_label, tr("status.error", message=message), error=True)

    def copy_term_hits(self) -> None:
        """Todas as linhas achadas da tabela escolhida, com cabecalho, separadas por TAB, sem a coluna Termo: colar no
        Excel da exatamente as linhas achadas."""
        table = self._term_table()
        if self.manager is None or self.terms_result is None or not table:
            return
        # shortcut: reads all hits in the UI thread (a few thousand rows at most in the real tables); move to a worker
        # if a table with hundreds of thousands of hits shows up
        rows = self.manager.fetch_rows(*table_hits(self.terms_result, table))
        columns = self.terms_result["columns"][table]
        QGuiApplication.clipboard().setText(rows_to_tsv([list(row.values())[1:] for row in rows], columns))

    def export_terms_as(self, suffix: str) -> None:
        # o relatorio: Resumo, uma aba por tabela com acerto e Nao encontrados; CSV = uma pasta, um arquivo por aba
        if self.manager is None or self.terms_result is None or self.current_db_path is None:
            return
        manager, sheets = self.manager, report_sheets(self.terms_result)
        if suffix == ".csv":
            self._export_csv_folder(tr("export.terms"), sheets)
            return
        out = self._ask_save_path(tr("export.terms"), f"{self.current_db_path.stem}_termos", (suffix,))
        if out is not None:
            self._start_export(out, lambda report, cancel: export_sheets(manager, sheets, out, report, cancel), "tables")

    def overwrite_box(self, count: int) -> QMessageBox:
        """A pergunta dos arquivos que ja existem na pasta (sem abrir): Sim / Nao do proprio Qt, do mesmo tamanho."""
        box = QMessageBox(QMessageBox.Icon.Question, tr("export.title"), counted("export.overwrite_many", count),
                          QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No, self)
        buttons = box.buttons()
        # shortcut: Qt translates Yes/No, so only the texts of the current language are measured; they are shorter
        # than the minimum button width in the 3 languages (Sim/Nao, Yes/No, Si/No)
        same_size(buttons, [button.text() for button in buttons])
        return box

    def ask_overwrite_many(self, count: int) -> bool:
        """Uma pergunta so para os arquivos que ja existem na pasta escolhida: substituir (True) ou nao gravar nada."""
        box = self.overwrite_box(count)
        box.exec()
        return box.clickedButton() is box.button(QMessageBox.StandardButton.Yes)

    def _export_csv_folder(self, title: str, sheets: list[Sheet]) -> None:
        # seletor de PASTA nativo; um <nome>.csv por item; os que ja existem: uma pergunta so
        if self.manager is None:
            return
        start = default_save_dir(self.current_db_path, self.settings.value("last_dir"))
        chosen = QFileDialog.getExistingDirectory(self, title, str(start))
        if not chosen:
            return
        folder, manager = Path(chosen), self.manager
        existing = sum((folder / csv_name(name)).exists() for name, _query, _params in sheets)
        if existing and not self.ask_overwrite_many(existing):
            return
        self.settings.setValue("last_dir", str(folder))
        self.settings.setValue("save_dir", str(folder))
        self._start_export(folder, lambda report, cancel: export_csv_folder(manager, sheets, folder, report, cancel),
                           "tables")

    # -------------------------------------------------------------- export

    def _update_export_actions(self) -> None:
        opened = self.manager is not None
        for action in (self.save_action, self.save_as_action, *self.export_db_schema_actions):
            action.setEnabled(opened)
        self.export_all_csv_action.setEnabled(opened and bool(self.table_list.topLevelItemCount()))
        for action in (*self.export_table_actions, *self.export_table_schema_actions):
            action.setEnabled(opened and self.loaded_table is not None)
        for action in self.export_sql_actions:
            action.setEnabled(opened and self.sql_query is not None)
        # a lista da busca em todas as tabelas na tela, com alguma tabela
        self.export_search_action.setEnabled(
            opened and self.data_stack.currentWidget() is self.found_list and bool(self.found_list.count())
        )
        marked = self.manager is not None and self.loaded_table is not None and bool(self.marks.get(self.loaded_table[0]))
        for action in (*self.export_marked_actions, self.unmark_all_action, self.only_marked_action):
            action.setEnabled(marked)
        self.marked_menu.setEnabled(marked)
        self.mark_action.setEnabled(self.manager is not None and self.loaded_table is not None)
        self.favorite_action.setEnabled(self.manager is not None and self.loaded_table is not None)
        report = self.manager is not None and self.terms_result is not None
        for action in (*self.export_terms_actions, self.copy_hits_action):
            action.setEnabled(report)
        for submenu in self.export_submenus:  # submenu sem nenhum item valendo: desabilitado
            submenu.setEnabled(any(action.isEnabled() for action in submenu.actions()))
        self._update_run_actions()
        self.export_button.setEnabled(self.manager is not None)
        self.close_db_action.setEnabled(self.manager is not None)

    def found_rows_box(self, count: int) -> tuple[QMessageBox, QAbstractButton, QAbstractButton]:
        """A pergunta da exportacao (tabela inteira, so as `count` encontradas, Cancelar), sem abrir."""
        one = "_one" if count == 1 else ""
        box = QMessageBox(QMessageBox.Icon.NoIcon, tr("export.title"), tr(f"export.ask{one}", count=num(count)),
                          QMessageBox.StandardButton.NoButton, self)
        whole = box.addButton(tr("export.whole_table"), QMessageBox.ButtonRole.AcceptRole)
        found = box.addButton(tr(f"export.found_rows{one}", count=num(count)), QMessageBox.ButtonRole.AcceptRole)
        cancel = box.addButton(tr("button.cancel"), QMessageBox.ButtonRole.RejectRole)
        box.setDefaultButton(whole)
        box.setEscapeButton(cancel)
        same_size([whole, found, cancel], every_language("export.whole_table")
                  + every_language(f"export.found_rows{one}", count=num(count)) + every_language("button.cancel"))
        return box, whole, found

    def ask_found_rows(self, count: int) -> bool | None:
        """A grade mostra parte da tabela (pesquisa ou filtro por valor): exportar a tabela inteira (False) ou so as
        `count` linhas encontradas (True)? None = Cancelar. Igual nas 4 versoes."""
        box, whole, found = self.found_rows_box(count)
        box.exec()
        return {whole: False, found: True}.get(box.clickedButton())

    def _ask_save_path(self, title: str, name: str, suffixes: tuple[str, ...], chosen: str = "",
                       folder: Path | None = None) -> Path | None:
        """Caixa de salvar nativa: os tipos de `suffixes` com `chosen` ja marcado (o primeiro, sem ele) e o nome
        sugerido em `folder` (a pasta do arquivo aberto; sem ele, a ultima usada). None = cancelada."""
        chosen = chosen or suffixes[0]
        folder = folder or default_save_dir(self.current_db_path, self.settings.value("last_dir"))
        target = folder / f"{name}{chosen}"
        reading = {self.current_db_path, Path(self.manager.current_db) if self.manager and self.manager.current_db else None}
        if target in reading:
            target = folder / (tr("save.copy_name", name=name) + chosen)  # nunca sugerir o proprio banco aberto
        types = {file_type(suffix): suffix for suffix in suffixes}
        while True:
            file_name, picked = QFileDialog.getSaveFileName(self, title, str(target), ";;".join(types), file_type(chosen))
            if not file_name:
                return None
            path = Path(file_name)
            picked = types.get(picked, chosen)
            if path.suffix.lower() not in suffixes:
                path = path.with_name(path.name + picked)
            elif path.suffix.lower() == chosen != picked:
                # !T: The Windows dialog renames the file when the type changes; Qt's own dialog (Linux) keeps the
                # !T: suggested extension, and the type the user picked is the one that counts
                path = path.with_suffix(picked)
            if path == Path(file_name) or not path.exists():
                break
            target = path  # o nome mudou para um arquivo que ja existe: a caixa pergunta de novo, com ele
        self._remember_dir(path)
        self.settings.setValue("save_dir", str(path.parent))
        return path

    def save_database(self, save_as: bool = False, then: Callable[[], object] | None = None) -> bool:
        """Arquivo > Salvar / Salvar como...: o banco aberto inteiro em SQLite, DuckDB ou Excel (uma aba por tabela),
        ja marcado o tipo do aberto. Salvar comeca na pasta do arquivo original; Salvar como... na ultima pasta em que
        o usuario salvou ou exportou. `then` roda depois de gravado. False = caixa cancelada."""
        manager, source, source_key = self.manager, self.current_db_path, self.current_db_key
        if manager is None or source is None:
            return False
        access = source.suffix.lower() in ACCESS_EXT
        chosen = ".duckdb" if manager.reader == "DuckDB" and not access else ".sqlite"
        last = str(self.settings.value("save_dir", "") or "")  # sem ela: "" (Path("") seria a pasta de trabalho)
        folder = Path(last) if save_as and last and Path(last).is_dir() else default_save_dir(source, None)
        out = self._ask_save_path(tr("save.title"), source.stem, (".sqlite", ".duckdb", ".xlsx"), chosen, folder)
        if out is None:
            return False

        def saved() -> None:
            # Access gravado: nada mais a perguntar ao sair; em SQLite ou DuckDB, o mesmo Access sem mudanca abre
            # direto o arquivo salvo (nesta e nas proximas execucoes)
            if manager is self.manager:
                self.converted_saved = True
            if access and out.suffix.lower() != ".xlsx" and out.is_file():
                self._remember_conversion(source, source_key, out)
            if then is not None:
                then()

        self._start_export(out, lambda report, cancel: export_database(manager, out, report, cancel), "tables", saved)
        return True

    def export_table_as(self, suffix: str) -> None:
        # a tabela atual inteira; com a grade mostrando parte dela (pesquisa ou filtro por valor) pergunta: inteira ou
        # so as linhas encontradas (pesquisa e filtros, o que a grade conta)
        if self.manager is None or self.loaded_table is None:
            return
        # o que a grade conta, lido antes da pergunta (a tela pode mudar enquanto ela esta aberta)
        table, filters, search = self.loaded_table[0], list(self.loaded_filters), self.loaded_search
        found = self.ask_found_rows(self.matched_rows) if search.split() or filters else False
        if found is None:
            return
        if not found:
            filters, search = [], ""
        out = self._ask_save_path(tr("export.table"), table, (suffix,))
        if out is not None:
            manager = self.manager

            def task(report, cancel):
                query, params = manager.select_table(table, filters, search)
                return export_result(manager, query, table, out, report, cancel, params)

            self._start_export(out, task, "rows")

    def export_sql_as(self, suffix: str) -> None:
        # o resultado inteiro da ultima consulta da aba SQL que deu certo, em query.csv / query.xlsx (nas 4 versoes)
        if self.manager is None or self.sql_query is None:
            return
        query = self.sql_query
        out = self._ask_save_path(tr("export.sql"), "query", (suffix,))
        if out is not None:
            manager = self.manager
            self._start_export(
                out, lambda report, cancel: export_result(manager, query, "query", out, report, cancel), "rows"
            )

    def export_table_schema_as(self, suffix: str) -> None:
        # Coluna, Tipo, Aceita nulo (como a aba Schema): <tabela>_schema
        if self.manager is None or self.loaded_table is None:
            return
        table, manager = self.loaded_table[0], self.manager
        query, params = table_schema_query(table)
        out = self._ask_save_path(tr("export.table_schema"), f"{table}_schema", (suffix,))
        if out is not None:
            self._start_export(out, lambda report, cancel: export_result(
                manager, query, f"{table}_schema", out, report, cancel, params), "rows")

    def export_db_schema_as(self, suffix: str) -> None:
        # Tabela, Coluna, Tipo, Aceita nulo de todas as tabelas: <banco>_schema
        if self.manager is None or self.current_db_path is None:
            return
        manager, name = self.manager, f"{self.current_db_path.stem}_schema"
        query, params = database_schema_query(self.table_names())
        out = self._ask_save_path(tr("export.db_schema"), name, (suffix,))
        if out is not None:
            self._start_export(out, lambda report, cancel: export_result(
                manager, query, name, out, report, cancel, params), "rows")

    def export_all_csv(self) -> None:
        # seletor de PASTA; <tabela>.csv de cada tabela inteira
        sheets: list[Sheet] = [(table, f"SELECT * FROM {quote(table)}", ()) for table in self.table_names()]
        self._export_csv_folder(self.export_all_csv_action.text().replace("&", "").removesuffix("..."), sheets)

    def export_search_all(self) -> None:
        # uma aba por tabela com acerto da busca em todas as tabelas, as linhas que a busca acha, todas as colunas
        if self.manager is None or self.current_db_path is None or self._found_summary is None:
            return
        manager, search = self.manager, self._found_summary[1]
        tables = [self.found_list.item(i).data(Qt.ItemDataRole.UserRole) for i in range(self.found_list.count())]
        sheets: list[Sheet] = [(table, *manager.select_table(table, (), search)) for table in tables]
        out = self._ask_save_path(self.export_search_action.text().replace("&", "").removesuffix("..."),
                                  f"{self.current_db_path.stem}_busca", (".xlsx",))
        if out is not None:
            self._start_export(out, lambda report, cancel: export_sheets(manager, sheets, out, report, cancel), "tables")

    def _start_export(self, out: Path, task: Callable, unit: str, done: Callable[[], object] | None = None) -> None:
        # task(report, cancel) grava em out (arquivo ou pasta) e devolve quantas tabelas ou linhas (unit); done()
        # roda depois de gravado
        def run(report, cancel):
            return task(lambda count, total, item: report(
                count, total, tr("export.running_item", name=out.name, item=item) if item else ""), cancel)

        def finished(count: object) -> None:
            self._set_message(self.status_label, counted(f"export.done_{unit}", count, path=out))  # type: ignore[arg-type]
            if done is not None:
                done()

        self._start_job(tr("export.title"), tr("export.running", name=out.name), run, finished,
                        tr("export.cancelled", name=out.name), "export.failed", exporting=out.name)

    def _start_job(self, title: str, label: str, task: Callable, done: Callable[[object], None], cancelled: str,
                   failed: str = "status.error", exporting: str = "") -> None:
        """Trabalho longo em thread, com dialogo de progresso e Cancelar. task(report, cancel) devolve o resultado
        entregue a done(); Cancelled (o Cancelar do dialogo) mostra `cancelled`, erro mostra o texto de `failed`.

        Enquanto ele roda a janela nao aceita mais nada, menos sair (X, Alt+F4, Ctrl+Q): closeEvent pergunta antes
        quando e uma exportacao (`exporting` = nome do arquivo)."""
        cancel = threading.Event()
        dialog = QProgressDialog(label, tr("button.cancel"), 0, 0, self)
        dialog.setWindowTitle(title)
        dialog.setMinimumDuration(0)
        dialog.setAutoClose(False)
        dialog.setAutoReset(False)
        dialog.canceled.connect(cancel.set)
        dialog.show()
        job = self._job = (cancel, exporting)
        self._set_working(True)

        def progress(count: int, total: int, text: str) -> None:
            if total:
                dialog.setRange(0, total)
                dialog.setValue(count)
            if text:
                dialog.setLabelText(text)

        def close_dialog() -> None:
            if self._job is job:  # nao o de um trabalho mais novo (Salvar pedido ao sair, logo depois de cancelar)
                self._job = None
                self._set_working(False)
            dialog.canceled.disconnect(cancel.set)
            dialog.close()
            dialog.deleteLater()  # nao acumula dialogos escondidos

        def succeeded(_request_id: int, result: object) -> None:
            close_dialog()
            if result is None:
                if cancelled:
                    self._set_message(self.status_label, cancelled, warning=True)
            else:
                done(result)

        def errored(_request_id: int, message: str) -> None:
            close_dialog()
            self._set_message(self.status_label, tr(failed, message=message), error=True)

        def run(report):
            try:
                return task(report, cancel)
            except Cancelled:
                return None

        self._run(0, run, succeeded, errored, progress)

    def _set_working(self, working: bool) -> None:
        for widget in (self.menuBar(), self.top_bar, self.centralWidget(), self.tables_dock, self.log_dock):
            widget.setEnabled(not working)
