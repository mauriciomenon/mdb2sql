# NIVEL BASICO: Janela principal da aplicacao
# QMainWindow e o template padrao para apps com menu, toolbar, status bar

from PyQt6.QtWidgets import (
    QMainWindow,
    QWidget,
    QVBoxLayout,
    QHBoxLayout,
    QLineEdit,
    QPushButton,
    QLabel,
)
from PyQt6.QtCore import Qt

# NIVEL TECNICO: QMainWindow provides standard app structure
# Slots/signals pattern for event handling


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.init_ui()

    def init_ui(self):
        # NIVEL BASICO: Configura janela principal
        self.setWindowTitle("MDB2SQL")
        self.setGeometry(100, 100, 1200, 800)

        # NIVEL BASICO: Widget central (obrigatorio em QMainWindow)
        central_widget = QWidget()
        self.setCentralWidget(central_widget)

        # NIVEL BASICO: Layout vertical organiza widgets de cima para baixo
        main_layout = QVBoxLayout(central_widget)

        # NIVEL BASICO: Titulo
        title = QLabel("MDB2SQL")
        title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        # NIVEL TECNICO: Inline style, preparando para theme system futuro
        title.setStyleSheet("font-size: 24px; font-weight: bold; margin: 20px;")
        main_layout.addWidget(title)

        # NIVEL BASICO: Layout horizontal para input e botao lado a lado
        input_layout = QHBoxLayout()

        # NIVEL BASICO: Campo de texto
        self.name_input = QLineEdit()
        self.name_input.setPlaceholderText("Enter your name")
        # NIVEL TECNICO: returnPressed signal emitido quando user aperta Enter
        self.name_input.returnPressed.connect(self.greet)

        # NIVEL BASICO: Botao
        self.greet_button = QPushButton("Greet")
        # NIVEL TECNICO: clicked signal conectado ao slot (metodo) greet
        self.greet_button.clicked.connect(self.greet)

        input_layout.addWidget(self.name_input)
        input_layout.addWidget(self.greet_button)

        main_layout.addLayout(input_layout)

        # NIVEL BASICO: Label para mostrar resultado
        self.result_label = QLabel("")
        self.result_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.result_label.setStyleSheet(
            "font-weight: bold; color: #0066cc; margin-top: 20px;"
        )
        main_layout.addWidget(self.result_label)

        # NIVEL TECNICO: Stretch para empurrar conteudo para o topo
        main_layout.addStretch()

    def greet(self):
        # NIVEL BASICO: Slot que responde ao click do botao
        # Pega texto do input e exibe mensagem
        name = self.name_input.text()
        if name:
            message = f"Hello {name}! Welcome to MDB2SQL (Python backend)"
            self.result_label.setText(message)
        else:
            self.result_label.setText("")
