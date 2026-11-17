# Dialogos da janela principal: Sobre (Ajuda > Sobre) e Colunas (ocultar/mostrar varias colunas de uma vez)
# !T: Both are opened with open() by the caller: no nested event loop, so tests and UI Automation do not block

from PyQt6.QtCore import Qt
from PyQt6.QtGui import QPixmap
from PyQt6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QFrame,
    QHBoxLayout,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from shared.about import APP_NAME, LINKS, SUMMARY, about_fields, app_version, link_html
from shared.bundle import resource

EXPORT_NOTE = "Exportar continua exportando todas as colunas."


class AboutDialog(QDialog):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Sobre")

        icon = QLabel()
        icon.setPixmap(
            QPixmap(str(resource("mdb2sql.png"))).scaled(
                72, 72, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation
            )
        )
        self.title = QLabel(f"{APP_NAME} {app_version()}")
        font = self.title.font()
        font.setPointSizeF(font.pointSizeF() * 1.4)  # destaque discreto, mesma familia do app
        font.setBold(True)
        self.title.setFont(font)
        summary = QLabel(SUMMARY)
        summary.setWordWrap(True)
        heading = QVBoxLayout()
        heading.addWidget(self.title)
        heading.addWidget(summary)
        top = QHBoxLayout()
        top.setSpacing(16)
        top.addWidget(icon, 0, Qt.AlignmentFlag.AlignTop)
        top.addLayout(heading, 1)

        line = QFrame()
        line.setFrameShape(QFrame.Shape.HLine)
        line.setFrameShadow(QFrame.Shadow.Sunken)

        self.form = QFormLayout()
        self.form.setLabelAlignment(Qt.AlignmentFlag.AlignRight)
        self.form.setHorizontalSpacing(16)
        self.form.setVerticalSpacing(6)
        for label, value in about_fields():
            text = QLabel(value)
            text.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
            self.form.addRow(f"{label}:", text)
        self.links: list[QLabel] = []
        for label, url in LINKS:
            link = QLabel(link_html(url))
            link.setOpenExternalLinks(True)  # abre no navegador padrao
            link.setTextInteractionFlags(Qt.TextInteractionFlag.TextBrowserInteraction)  # tambem por Tab + Enter
            link.setAccessibleName(f"{label} {url}")
            self.links.append(link)
            self.form.addRow(f"{label}:", link)

        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok)
        buttons.accepted.connect(self.accept)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(20, 20, 20, 16)
        layout.setSpacing(14)
        layout.addLayout(top)
        layout.addWidget(line)
        layout.addLayout(self.form)
        layout.addWidget(buttons)
        self.setMinimumWidth(560)


class ColumnsDialog(QDialog):
    """Lista com uma caixa por coluna (marcada = visivel); so vale ao confirmar com OK."""

    def __init__(self, columns: list[str], hidden: set[str], parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Colunas")

        self.list = QListWidget()
        self.list.setAccessibleName("Colunas visiveis")
        self.list.setSelectionMode(QListWidget.SelectionMode.ExtendedSelection)
        for name in columns:
            item = QListWidgetItem(name)
            item.setFlags(item.flags() | Qt.ItemFlag.ItemIsUserCheckable)
            item.setCheckState(Qt.CheckState.Unchecked if name in hidden else Qt.CheckState.Checked)
            self.list.addItem(item)
        self.list.itemChanged.connect(self._check_selected)

        show_all = QPushButton("Mostrar todas")
        show_all.clicked.connect(lambda: self.set_all(True))
        hide_all = QPushButton("Ocultar todas")
        hide_all.clicked.connect(lambda: self.set_all(False))
        bulk = QHBoxLayout()
        bulk.addWidget(show_all)
        bulk.addWidget(hide_all)
        bulk.addStretch(1)

        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)

        self.list.setToolTip(f"Marcada = visivel. Com varias linhas selecionadas, marcar uma marca todas.\n{EXPORT_NOTE}")
        layout = QVBoxLayout(self)
        layout.addLayout(bulk)
        layout.addWidget(self.list, 1)
        layout.addWidget(buttons)
        self.resize(360, 520)

    def _check_selected(self, changed: QListWidgetItem) -> None:
        # varias linhas selecionadas (Shift/Ctrl + clique): marcar uma aplica o mesmo estado a todas
        if not changed.isSelected():
            return
        self.list.blockSignals(True)
        for item in self.list.selectedItems():
            item.setCheckState(changed.checkState())
        self.list.blockSignals(False)

    def set_all(self, visible: bool) -> None:
        state = Qt.CheckState.Checked if visible else Qt.CheckState.Unchecked
        self.list.blockSignals(True)
        for row in range(self.list.count()):
            self.list.item(row).setCheckState(state)
        self.list.blockSignals(False)

    def hidden(self) -> set[str]:
        items = (self.list.item(row) for row in range(self.list.count()))
        return {item.text() for item in items if item.checkState() == Qt.CheckState.Unchecked}
