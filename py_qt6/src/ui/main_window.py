# Janela principal da aplicacao com menu, toolbar, status bar
# !T: QMainWindow provides standard app structure with slots/signals pattern

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

# !T: QMainWindow provides standard app structure
# !T: Slots/signals pattern for event handling


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        # Inicializa manager de banco de dados
        self.db_manager = DBManager()
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
        self.data_table = QTableWidget()
        # !T: Stretch columns to fill width
        self.data_table.horizontalHeader().setSectionResizeMode(
            QHeaderView.ResizeMode.Stretch
        )
        main_layout.addWidget(self.data_table)

        # Label rodape com info
        self.info_label = QLabel("Ready")
        main_layout.addWidget(self.info_label)

    def load_database(self):
        # Carrega banco DuckDB usando env var ou caminho default
        # !T: Check env var or use default path

        # Tenta variavel de ambiente primeiro
        import os
        env_path = os.getenv("MDB2SQL_DB_PATH")

        if env_path:
            db_path = Path(env_path)
        else:
            # Caminho do banco sample relativo ao projeto
            db_path = Path(__file__).parent.parent.parent.parent / "data" / "sample.duckdb"

        if not db_path.exists():
            self.status_label.setText("Error: sample.duckdb not found")
            self.status_label.setStyleSheet("color: red;")
            return

        try:
            # Conecta ao banco
            self.db_manager.connect(str(db_path))

            # Lista tabelas disponiveis
            tables = self.db_manager.list_tables()

            # Popula ComboBox com nomes das tabelas
            self.table_combo.clear()
            self.table_combo.addItems(tables)

            self.status_label.setText(f"Loaded: {db_path.name} ({len(tables)} tables)")
            self.status_label.setStyleSheet("color: green;")

            # Carrega primeira tabela automaticamente
            if tables:
                self.on_table_selected(tables[0])

        except Exception as e:
            self.status_label.setText(f"Error: {str(e)}")
            self.status_label.setStyleSheet("color: red;")

    def on_table_selected(self, table_name: str):
        # Chamado quando usuario seleciona tabela no ComboBox
        # !T: Loads table data and displays in QTableWidget

        if not table_name or not self.db_manager.conn:
            return

        try:
            # Busca dados da tabela com limit de 100 linhas
            rows = self.db_manager.query_table(table_name, limit=100)

            if not rows:
                self.info_label.setText(f"{table_name}: 0 rows")
                self.data_table.setRowCount(0)
                self.data_table.setColumnCount(0)
                return

            # Pega nomes das colunas do primeiro row
            columns = list(rows[0].keys())

            # Configura tabela
            self.data_table.setRowCount(len(rows))
            self.data_table.setColumnCount(len(columns))
            self.data_table.setHorizontalHeaderLabels(columns)

            # Preenche celulas com dados
            for row_idx, row_data in enumerate(rows):
                for col_idx, col_name in enumerate(columns):
                    value = row_data[col_name]
                    # !T: Convert to string, handle None
                    item = QTableWidgetItem(str(value) if value is not None else "")
                    self.data_table.setItem(row_idx, col_idx, item)

            # Atualiza info rodape
            total_rows = self.db_manager.get_row_count(table_name)
            self.info_label.setText(
                f"{table_name}: Showing {len(rows)} of {total_rows} rows"
            )

        except Exception as e:
            self.info_label.setText(f"Error loading table: {str(e)}")
            self.info_label.setStyleSheet("color: red;")
