# Janela principal da aplicacao com layout central customizado
# !T: QMainWindow hosts the central widget and signal-driven interactions

from pathlib import Path
from typing import Any, Callable, cast
from PyQt6.QtWidgets import (
    QMainWindow,
    QWidget,
    QVBoxLayout,
    QHBoxLayout,
    QComboBox,
    QPushButton,
    QLabel,
    QTableView,
    QHeaderView,
)
from PyQt6.QtCore import (
    QAbstractTableModel,
    QModelIndex,
    QObject,
    QRunnable,
    Qt,
    QThreadPool,
    QTimer,
    pyqtSignal,
)
from backend.database_tasks import (
    TablePayload,
    database_path_from_env,
    list_tables,
    load_table_payload,
)

# !T: QMainWindow provides standard app structure
# !T: Slots/signals pattern for event handling


class _WorkerSignals(QObject):
    success = pyqtSignal(object)
    error = pyqtSignal(str)


class _DatabaseWorker(QRunnable):
    def __init__(self, task: Callable[[], object]):
        super().__init__()
        self.task = task
        self.signals = _WorkerSignals()

    def run(self) -> None:
        try:
            result = self.task()
        except Exception as exc:
            self.signals.error.emit(str(exc))
            return

        self.signals.success.emit(result)


class _TableModel(QAbstractTableModel):
    def __init__(self) -> None:
        super().__init__()
        self.rows: list[dict[str, Any]] = []
        self.columns: list[str] = []

    def rowCount(self, parent: QModelIndex | None = None) -> int:
        if parent is not None and parent.isValid():
            return 0
        return len(self.rows)

    def columnCount(self, parent: QModelIndex | None = None) -> int:
        if parent is not None and parent.isValid():
            return 0
        return len(self.columns)

    def data(self, index: QModelIndex, role: int = Qt.ItemDataRole.DisplayRole) -> str | None:
        if not index.isValid() or role != Qt.ItemDataRole.DisplayRole:
            return None

        value = self.rows[index.row()][self.columns[index.column()]]
        return str(value) if value is not None else ""

    def headerData(
        self,
        section: int,
        orientation: Qt.Orientation,
        role: int = Qt.ItemDataRole.DisplayRole,
    ) -> str | None:
        if role != Qt.ItemDataRole.DisplayRole:
            return None

        if orientation == Qt.Orientation.Horizontal and 0 <= section < len(self.columns):
            return self.columns[section]

        return str(section + 1) if orientation == Qt.Orientation.Vertical else None

    def set_rows(self, rows: list[dict[str, Any]]) -> None:
        self.beginResetModel()
        self.rows = rows
        self.columns = list(rows[0].keys()) if rows else []
        self.endResetModel()


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.current_db_path: Path | None = None
        self.pending_table_name: str | None = None
        self.thread_pool: QThreadPool = QThreadPool.globalInstance() or QThreadPool(self)
        self.table_load_timer = QTimer(self)
        self.table_load_timer.setSingleShot(True)
        self.table_load_timer.timeout.connect(self._start_table_worker)
        self.init_ui()

    def init_ui(self):
        # Configura janela principal
        self.setWindowTitle("MDB2SQL - Database Viewer")
        self.setGeometry(100, 100, 1200, 800)

        # Widget central
        central_widget = QWidget()
        self.setCentralWidget(central_widget)

        main_layout = QVBoxLayout(central_widget)

        # Titulo
        title = QLabel("MDB2SQL - Feature 1: Load and Display Table")
        title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        title.setStyleSheet("font-size: 18px; font-weight: bold; margin: 10px;")
        main_layout.addWidget(title)

        # Layout horizontal para controles
        controls_layout = QHBoxLayout()

        # ComboBox para selecionar tabela
        controls_layout.addWidget(QLabel("Table:"))
        self.table_combo = QComboBox()
        self.table_combo.setMinimumWidth(300)
        # !T: Signal emitido quando usuario seleciona outra tabela
        self.table_combo.currentTextChanged.connect(self.on_table_selected)
        controls_layout.addWidget(self.table_combo)

        # Botao para carregar banco
        self.load_button = QPushButton("Load Database")
        self.load_button.clicked.connect(self.load_database)
        controls_layout.addWidget(self.load_button)

        # Label status
        self.status_label = QLabel("No database loaded")
        controls_layout.addWidget(self.status_label)

        controls_layout.addStretch()
        main_layout.addLayout(controls_layout)

        # Tabela para exibir dados
        self.table_model = _TableModel()
        self.data_table = QTableView()
        self.data_table.setModel(self.table_model)
        # !T: Stretch columns to fill width
        header = self.data_table.horizontalHeader()
        if header is not None:
            header.setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
        main_layout.addWidget(self.data_table)

        # Label rodape com info
        self.info_label = QLabel("Ready")
        main_layout.addWidget(self.info_label)

    def load_database(self):
        # Carrega banco DuckDB usando env var ou caminho default
        # !T: Check env var or use default path
        db_path = database_path_from_env()

        if not db_path.exists():
            self.status_label.setText(f"Error: {db_path.name} not found")
            self.status_label.setStyleSheet("color: red;")
            return

        self.load_button.setEnabled(False)
        self.status_label.setText(f"Loading: {db_path.name}")
        worker = _DatabaseWorker(lambda: list_tables(db_path))
        worker.signals.success.connect(self._on_database_loaded)
        worker.signals.error.connect(self._on_database_error)
        self.thread_pool.start(worker)

    def _on_database_loaded(self, result: object) -> None:
        db_path, tables = cast(tuple[Path, list[str]], result)
        self.current_db_path = db_path

        self.table_combo.blockSignals(True)
        self.table_combo.clear()
        self.table_combo.addItems(tables)
        if tables:
            self.table_combo.setCurrentIndex(0)
        self.table_combo.blockSignals(False)

        self.status_label.setText(f"Loaded: {db_path.name} ({len(tables)} tables)")
        self.status_label.setStyleSheet("color: green;")
        self.load_button.setEnabled(True)

        if tables:
            self.on_table_selected(tables[0])

    def _on_database_error(self, message: str) -> None:
        self.status_label.setText(f"Error: {message}")
        self.status_label.setStyleSheet("color: red;")
        self.load_button.setEnabled(True)

    def on_table_selected(self, table_name: str):
        # Chamado quando usuario seleciona tabela no ComboBox
        # !T: Loads table data and displays in QTableView

        if not table_name or self.current_db_path is None:
            return

        self.pending_table_name = table_name
        self.info_label.setStyleSheet("")
        self.info_label.setText(f"Loading {table_name}...")
        self.table_load_timer.start(150)

    def _start_table_worker(self) -> None:
        if self.current_db_path is None or not self.pending_table_name:
            return

        db_path = self.current_db_path
        table_name = self.pending_table_name
        self.pending_table_name = None
        self.info_label.setText(f"Loading {table_name}...")
        worker = _DatabaseWorker(lambda: load_table_payload(db_path, table_name))
        worker.signals.success.connect(self._on_table_loaded)
        worker.signals.error.connect(self._on_table_error)
        self.thread_pool.start(worker)

    def _on_table_loaded(self, result: object) -> None:
        payload = cast(TablePayload, result)
        table_name = payload["table_name"]
        if table_name != self.table_combo.currentText():
            return

        rows = payload["rows"]
        if not rows:
            self.info_label.setText(f"{table_name}: 0 rows")
            self.info_label.setStyleSheet("")
            self.table_model.set_rows([])
            return

        self.table_model.set_rows(rows)
        self.info_label.setText(
            f"{table_name}: Showing {len(rows)} of {payload['total_rows']} rows"
        )
        self.info_label.setStyleSheet("")

    def _on_table_error(self, message: str) -> None:
        self.info_label.setText(f"Error loading table: {message}")
        self.info_label.setStyleSheet("color: red;")
