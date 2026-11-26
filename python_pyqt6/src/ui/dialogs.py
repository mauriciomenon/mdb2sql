# Dialogos da janela principal: Sobre (Ajuda > Sobre), Colunas (ocultar/mostrar varias colunas de uma vez) e a
# pergunta com botoes proprios (sair com o SQLite convertido nao salvo, sair com exportacao em andamento)
# !T: About and Columns are opened with open() by the caller: no nested event loop, so tests and UI Automation do
# !T: not block

from PyQt6.QtCore import QSize, Qt, pyqtSignal
from PyQt6.QtGui import QGuiApplication, QPixmap
from PyQt6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QPushButton,
    QStyle,
    QVBoxLayout,
    QWidget,
)

from shared.about import APP_NAME, LINKS, about_fields, app_version, link_html
from shared.bundle import resource
from shared.display import HELP, Notice
from shared.i18n import every_language, tr


def same_size(buttons: list, texts: list[str]) -> None:
    """Os botoes de uma caixa com a mesma largura e altura: as do maior texto de `texts` (os 3 idiomas), entao a caixa
    nao muda com o idioma nem com o texto de cada botao."""
    probe = QPushButton()  # !T: same style and font as the dialog buttons (no style sheet on them)
    size = QSize()
    for text in texts:
        probe.setText(text)
        size = size.expandedTo(probe.sizeHint())
    for button in buttons:
        button.setFixedSize(size)


class AboutDialog(QDialog):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle(tr("about.title"))

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
        summary = QLabel(tr("about.summary"))
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
            self.form.addRow(tr("about.label", label=label), text)
        self.links: list[QLabel] = []
        for label, url in LINKS:
            link = QLabel(link_html(url))
            link.setOpenExternalLinks(True)  # abre no navegador padrao
            link.setTextInteractionFlags(Qt.TextInteractionFlag.TextBrowserInteraction)  # tambem por Tab + Enter
            link.setAccessibleName(f"{label} {url}")
            self.links.append(link)
            self.form.addRow(tr("about.label", label=label), link)

        buttons = QDialogButtonBox()
        buttons.addButton(tr("button.ok"), QDialogButtonBox.ButtonRole.AcceptRole).setDefault(True)  # Enter
        buttons.accepted.connect(self.accept)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(20, 20, 20, 16)
        layout.setSpacing(14)
        layout.addLayout(top)
        layout.addWidget(line)
        layout.addLayout(self.form)
        layout.addWidget(buttons)
        self.setMinimumWidth(560)


class ChoiceBox(QDialog):
    """Pergunta sem icone com botoes proprios (chave -> texto): os de `left` a esquerda e os de `right` a direita,
    lado a lado, como OK/Cancelar. Depois de exec(), `choice` e a chave do botao clicado; Esc e o X da caixa deixam
    `escape`. Enter aciona `default`. Todos os botoes com o tamanho do maior texto de `sizes` (os textos deles nos 3
    idiomas; sem `sizes`, os textos de agora)."""

    def __init__(self, title: str, text: str, left: dict[str, str], right: dict[str, str], default: str, escape: str,
                 parent: QWidget | None = None, sizes: list[str] | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle(title)
        self.choice = escape
        self.text = QLabel(text)
        self.buttons: dict[str, QPushButton] = {}
        row = QHBoxLayout()
        for side in (left, right):
            for key, caption in side.items():
                button = self.buttons[key] = QPushButton(caption)
                button.setDefault(key == default)
                button.clicked.connect(lambda _checked=False, k=key: self._pick(k))
                row.addWidget(button)
            if side is left:
                row.addStretch(1)
        same_size(list(self.buttons.values()), sizes or [*left.values(), *right.values()])
        layout = QVBoxLayout(self)
        layout.setContentsMargins(20, 20, 20, 16)
        layout.setSpacing(18)
        layout.addWidget(self.text)
        layout.addLayout(row)
        self.buttons[default].setFocus()

    def _pick(self, key: str) -> None:
        self.choice = key
        self.accept()


class DisplayWarning(QDialog):
    """Linux sem X11: 'X11 indisponivel; usando Wayland.', 'Falta: ...', '<distro>: <comando>' (selecionavel, Copiar)
    e o link Ajuda (abre o navegador)."""

    def __init__(self, notice: Notice, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle(tr("display.title"))
        icon = QLabel()
        size = self.style().pixelMetric(QStyle.PixelMetric.PM_MessageBoxIconSize)
        icon.setPixmap(self.style().standardIcon(QStyle.StandardPixmap.SP_MessageBoxWarning).pixmap(size, size))
        text = QLabel("\n".join(notice.lines))
        text.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        lines = QVBoxLayout()
        lines.addWidget(text)
        self.command = QLineEdit(notice.command or "")
        if notice.command:
            self.command.setReadOnly(True)
            self.command.setMinimumWidth(self.command.fontMetrics().horizontalAdvance(notice.command) + 24)
            copy = QPushButton(tr("display.copy"))
            copy.clicked.connect(lambda: QGuiApplication.clipboard().setText(notice.command))
            row = QHBoxLayout()
            row.addWidget(QLabel(f"{notice.distro}:"))
            row.addWidget(self.command, 1)
            row.addWidget(copy)
            lines.addLayout(row)
        top = QHBoxLayout()
        top.setSpacing(16)
        top.addWidget(icon, 0, Qt.AlignmentFlag.AlignTop)
        top.addLayout(lines, 1)

        self.help = QLabel(link_html(HELP, tr("display.help")))
        self.help.setOpenExternalLinks(True)  # abre no navegador padrao
        self.help.setTextInteractionFlags(Qt.TextInteractionFlag.TextBrowserInteraction)
        ok = QPushButton(tr("button.ok"))
        ok.setDefault(True)
        ok.clicked.connect(self.accept)
        if notice.command:
            same_size([copy, ok], every_language("display.copy") + every_language("button.ok"))
        bottom = QHBoxLayout()
        bottom.addWidget(self.help)
        bottom.addStretch(1)
        bottom.addWidget(ok)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(20, 20, 20, 16)
        layout.setSpacing(14)
        layout.addLayout(top)
        layout.addLayout(bottom)


def grid_columns(available: int, cell: int) -> int:
    """Colunas da grade de caixas: quantas celulas cabem na largura, de 1 a 6."""
    return max(1, min(6, available // max(1, cell)))


class ColumnsDialog(QDialog):
    """Caixas em grade (marcada = visivel); cada mudanca vale na hora (hiddenChanged), Fechar so fecha."""

    hiddenChanged = pyqtSignal(object)  # set[str] com as colunas ocultas

    def __init__(self, table: str, columns: list[str], hidden: set[str], parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle(tr("columns.title", table=table))  # "Colunas de <tabela>" nas 4 versoes

        self.search = QLineEdit()
        self.search.setPlaceholderText(tr("columns.search"))
        self.search.setClearButtonEnabled(True)
        self.search.setAccessibleName(tr("columns.search"))
        self.search.textChanged.connect(self._filter)

        # !T: Wrapping LeftToRight list: a responsive grid with vertical scroll only; the font stays the base font
        self.list = QListWidget()
        self.list.setAccessibleName(tr("columns.visible"))
        self.list.setSelectionMode(QListWidget.SelectionMode.ExtendedSelection)
        self.list.setFlow(QListWidget.Flow.LeftToRight)
        self.list.setWrapping(True)
        self.list.setResizeMode(QListWidget.ResizeMode.Adjust)
        self.list.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.list.setTextElideMode(Qt.TextElideMode.ElideNone)  # nome inteiro: a celula ja cabe o mais longo
        for name in columns:
            item = QListWidgetItem(name)
            item.setToolTip(name)
            item.setFlags(item.flags() | Qt.ItemFlag.ItemIsUserCheckable)
            item.setCheckState(Qt.CheckState.Unchecked if name in hidden else Qt.CheckState.Checked)
            self.list.addItem(item)
        self.list.itemChanged.connect(self._item_changed)

        # celula da grade: nome mais longo + caixa + espaco, nunca menor que ~24 caracteres medios
        metrics = self.list.fontMetrics()
        indicator = self.style().pixelMetric(QStyle.PixelMetric.PM_IndicatorWidth)
        longest = max((metrics.horizontalAdvance(name) for name in columns), default=0)
        self.cell = max(longest + indicator + 24, metrics.averageCharWidth() * 24)
        self.row_height = metrics.height() + 10

        show_all = QPushButton(tr("columns.show_all"))
        show_all.clicked.connect(lambda: self.set_all(True))
        hide_all = QPushButton(tr("columns.hide_all"))
        hide_all.clicked.connect(lambda: self.set_all(False))
        close = QPushButton(tr("button.close"))
        close.setDefault(True)
        close.clicked.connect(self.accept)
        same_size([show_all, hide_all, close], [text for key in ("columns.show_all", "columns.hide_all", "button.close")
                                                for text in every_language(key)])
        buttons = QHBoxLayout()
        buttons.addWidget(show_all)
        buttons.addWidget(hide_all)
        buttons.addStretch(1)
        buttons.addWidget(close)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(16, 16, 16, 12)
        layout.setSpacing(10)
        layout.addWidget(self.search)
        layout.addWidget(self.list, 1)
        layout.addLayout(buttons)

        # ~65% da janela principal (420..900 px) e altura ate 70% dela; sem janela, o tamanho padrao do app
        base = parent.window().size() if parent else QSize(1200, 800)
        width = max(420, min(900, round(base.width() * 0.65)))
        columns_here = grid_columns(width - 60, self.cell)
        rows = -(-len(columns) // columns_here)
        wanted = rows * self.row_height + 140  # busca, botoes e margens
        self.resize(width, max(300, min(round(base.height() * 0.7), wanted)))
        self.setMinimumSize(420, 300)

    def resizeEvent(self, event) -> None:  # noqa: N802 (Qt)
        super().resizeEvent(event)
        self._layout_grid()

    def available_width(self) -> int:
        # largura da lista menos a barra vertical, apareca ela ou nao: a grade nao muda quando a barra surge depois
        scrollbar = self.style().pixelMetric(QStyle.PixelMetric.PM_ScrollBarExtent)
        return self.list.width() - 2 * self.list.frameWidth() - scrollbar - 4

    def _layout_grid(self) -> None:
        # redimensionar recalcula a grade: as colunas dividem a largura por igual
        available = self.available_width()
        self.columns_shown = grid_columns(available, self.cell)
        self.list.setGridSize(QSize(available // self.columns_shown, self.row_height))

    def _filter(self, text: str) -> None:
        words = text.casefold().split()
        for row in range(self.list.count()):
            item = self.list.item(row)
            item.setHidden(not all(word in item.text().casefold() for word in words))

    def _item_changed(self, changed: QListWidgetItem) -> None:
        # varias selecionadas (Shift/Ctrl + clique): marcar uma aplica o mesmo estado a todas
        self.list.blockSignals(True)
        if changed.isSelected():
            for item in self.list.selectedItems():
                item.setCheckState(changed.checkState())
        self._keep_one(changed)
        self.list.blockSignals(False)
        self.hiddenChanged.emit(self.hidden())

    def set_all(self, visible: bool) -> None:
        state = Qt.CheckState.Checked if visible else Qt.CheckState.Unchecked
        listed = [self.list.item(row) for row in range(self.list.count()) if not self.list.item(row).isHidden()]
        self.list.blockSignals(True)
        for item in listed:
            item.setCheckState(state)
        if listed:
            self._keep_one(listed[0])  # Ocultar todas: a primeira listada fica (como no Zig)
        self.list.blockSignals(False)
        self.hiddenChanged.emit(self.hidden())

    def _keep_one(self, item: QListWidgetItem) -> None:
        # sempre fica ao menos uma coluna visivel (igual nas 4 versoes): sem nenhuma marcada, `item` volta
        if len(self.hidden()) == self.list.count():
            item.setCheckState(Qt.CheckState.Checked)

    def hidden(self) -> set[str]:
        items = (self.list.item(row) for row in range(self.list.count()))
        return {item.text() for item in items if item.checkState() == Qt.CheckState.Unchecked}
