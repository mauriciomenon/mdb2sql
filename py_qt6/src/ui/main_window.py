# NIVEL BASICO: Janela principal da aplicacao
# QMainWindow e o template padrao para apps com menu, toolbar, status bar

from pathlib import Path
from PyQt6.QtWidgets import (
    QMainWindow,
    QWidget,
    QVBoxLayout,
    QHBoxLayout,
    QComboBox,
    QPushButton,
    QLabel,
    QTableWidget,
    QTableWidgetItem,
    QHeaderView,
)
from PyQt6.QtCore import Qt
from backend.db_manager import DBManager

# NIVEL TECNICO: QMainWindow provides standard app structure
# Slots/signals pattern for event handling


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        # NIVEL BASICO: Inicializa manager de banco de dados
        self.db_manager = DBManager()
        self.init_ui()

    def init_ui(self):
        # NIVEL BASICO: Configura janela principal
        self.setWindowTitle("MDB2SQL - Database Viewer")
        self.setGeometry(100, 100, 1200, 800)

        # NIVEL BASICO: Widget central
        central_widget = QWidget()
        self.setCentralWidget(central_widget)

        main_layout = QVBoxLayout(central_widget)

        # NIVEL BASICO: Titulo
        title = QLabel("MDB2SQL - Feature 1: Load and Display Table")
        title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        title.setStyleSheet("font-size: 18px; font-weight: bold; margin: 10px;")
        main_layout.addWidget(title)

        # NIVEL BASICO: Layout horizontal para controles
        controls_layout = QHBoxLayout()

        # NIVEL BASICO: ComboBox para selecionar tabela
        controls_layout.addWidget(QLabel("Table:"))
        self.table_combo = QComboBox()
        self.table_combo.setMinimumWidth(300)
        # NIVEL TECNICO: Signal emitido quando usuario seleciona outra tabela
        self.table_combo.currentTextChanged.connect(self.on_table_selected)
        controls_layout.addWidget(self.table_combo)

        # NIVEL BASICO: Botao para carregar banco
        self.load_button = QPushButton("Load Database")
        self.load_button.clicked.connect(self.load_database)
        controls_layout.addWidget(self.load_button)

        # NIVEL BASICO: Label status
        self.status_label = QLabel("No database loaded")
        controls_layout.addWidget(self.status_label)

        controls_layout.addStretch()
        main_layout.addLayout(controls_layout)

        # NIVEL BASICO: Tabela para exibir dados
        self.data_table = QTableWidget()
        # NIVEL TECNICO: Stretch columns to fill width
        self.data_table.horizontalHeader().setSectionResizeMode(
            QHeaderView.ResizeMode.Stretch
        )
        main_layout.addWidget(self.data_table)

        # NIVEL BASICO: Label rodape com info
        self.info_label = QLabel("Ready")
        main_layout.addWidget(self.info_label)

    def load_database(self):
        # NIVEL BASICO: Carrega banco sample.duckdb
        # NIVEL TECNICO: Hardcoded path for Feature 1, will be file dialog later

        # NIVEL BASICO: Caminho do banco sample (relativo ao projeto)
        db_path = Path(__file__).parent.parent.parent.parent / "data" / "sample.duckdb"

        if not db_path.exists():
            self.status_label.setText("Error: sample.duckdb not found")
            self.status_label.setStyleSheet("color: red;")
            return

        try:
            # NIVEL BASICO: Conecta ao banco
            self.db_manager.connect(str(db_path))

            # NIVEL BASICO: Lista tabelas disponiveis
            tables = self.db_manager.list_tables()

            # NIVEL BASICO: Popula ComboBox com nomes das tabelas
            self.table_combo.clear()
            self.table_combo.addItems(tables)

            self.status_label.setText(f"Loaded: {db_path.name} ({len(tables)} tables)")
            self.status_label.setStyleSheet("color: green;")

            # NIVEL BASICO: Carrega primeira tabela automaticamente
            if tables:
                self.on_table_selected(tables[0])

        except Exception as e:
            self.status_label.setText(f"Error: {str(e)}")
            self.status_label.setStyleSheet("color: red;")

    def on_table_selected(self, table_name: str):
        # NIVEL BASICO: Chamado quando usuario seleciona tabela no ComboBox
        # Carrega dados da tabela e exibe na QTableWidget

        if not table_name or not self.db_manager.conn:
            return

        try:
            # NIVEL BASICO: Busca dados da tabela (limit 100 linhas)
            rows = self.db_manager.query_table(table_name, limit=100)

            if not rows:
                self.info_label.setText(f"{table_name}: 0 rows")
                self.data_table.setRowCount(0)
                self.data_table.setColumnCount(0)
                return

            # NIVEL BASICO: Pega nomes das colunas do primeiro row
            columns = list(rows[0].keys())

            # NIVEL BASICO: Configura tabela
            self.data_table.setRowCount(len(rows))
            self.data_table.setColumnCount(len(columns))
            self.data_table.setHorizontalHeaderLabels(columns)

            # NIVEL BASICO: Preenche celulas com dados
            for row_idx, row_data in enumerate(rows):
                for col_idx, col_name in enumerate(columns):
                    value = row_data[col_name]
                    # NIVEL TECNICO: Convert to string, handle None
                    item = QTableWidgetItem(str(value) if value is not None else "")
                    self.data_table.setItem(row_idx, col_idx, item)

            # NIVEL BASICO: Atualiza info rodape
            total_rows = self.db_manager.get_row_count(table_name)
            self.info_label.setText(
                f"{table_name}: Showing {len(rows)} of {total_rows} rows"
            )

        except Exception as e:
            self.info_label.setText(f"Error loading table: {str(e)}")
            self.info_label.setStyleSheet("color: red;")
