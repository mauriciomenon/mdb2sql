# Pecas da janela principal: campo do caminho que mostra o fim do caminho longo e a barra que quebra a linha
# !T: PathEdit elides on the left when it has no focus (the file name stays visible, like Zig's ElideLeft);
# !T: FlowLayout wraps its items to the next line when the width is short, and gives the spare width of each line to
# !T: its horizontally expanding items (the search field), like the Go/Wails flex bar

from PyQt6.QtCore import QPoint, QRect, QSize, Qt
from PyQt6.QtGui import QPainter, QPalette
from PyQt6.QtWidgets import QLayout, QLayoutItem, QLineEdit, QSizePolicy, QStyle, QStyleOptionFrame, QWidget


class PathEdit(QLineEdit):
    """Caminho do arquivo: sem foco e maior que o campo, mostra o fim (nome do arquivo) com "..." no comeco."""

    def paintEvent(self, event) -> None:  # noqa: N802 (Qt)
        text = self.text()
        option = QStyleOptionFrame()
        self.initStyleOption(option)
        style = self.style()
        rect = style.subElementRect(QStyle.SubElement.SE_LineEditContents, option, self)
        margins = self.textMargins()
        # !T: QLineEdit keeps 2 px between the contents rect and the text on each side
        rect = rect.adjusted(margins.left() + 2, margins.top(), -margins.right() - 2, -margins.bottom())
        metrics = self.fontMetrics()
        if self.hasFocus() or not text or metrics.horizontalAdvance(text) <= rect.width():
            super().paintEvent(event)
            return
        painter = QPainter(self)
        style.drawPrimitive(QStyle.PrimitiveElement.PE_PanelLineEdit, option, painter, self)
        painter.setPen(self.palette().color(QPalette.ColorRole.Text))
        elided = metrics.elidedText(text, Qt.TextElideMode.ElideLeft, rect.width())
        painter.drawText(rect, int(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter), elided)

    def shown_text(self) -> str:
        """O texto como aparece sem foco (para os testes)."""
        option = QStyleOptionFrame()
        self.initStyleOption(option)
        rect = self.style().subElementRect(QStyle.SubElement.SE_LineEditContents, option, self)
        width = rect.width() - self.textMargins().left() - self.textMargins().right() - 4
        return self.fontMetrics().elidedText(self.text(), Qt.TextElideMode.ElideLeft, width)


class FlowLayout(QLayout):
    """Itens lado a lado; o que nao cabe vai para a linha de baixo. A sobra de cada linha vai para os itens que
    esticam na horizontal (campo de busca), que nunca ficam menores que a largura minima deles."""

    def __init__(self, parent: QWidget | None = None, spacing: int = 6) -> None:
        super().__init__(parent)
        self._items: list[QLayoutItem] = []
        self.setSpacing(spacing)
        self.setContentsMargins(0, 0, 0, 0)

    def addItem(self, item: QLayoutItem) -> None:  # noqa: N802 (Qt)
        self._items.append(item)

    def count(self) -> int:
        return len(self._items)

    def itemAt(self, index: int) -> QLayoutItem | None:  # noqa: N802 (Qt)
        return self._items[index] if 0 <= index < len(self._items) else None

    def takeAt(self, index: int) -> QLayoutItem | None:  # noqa: N802 (Qt)
        return self._items.pop(index) if 0 <= index < len(self._items) else None

    def expandingDirections(self) -> Qt.Orientation:  # noqa: N802 (Qt)
        return Qt.Orientation(0)

    def hasHeightForWidth(self) -> bool:  # noqa: N802 (Qt)
        return True

    def heightForWidth(self, width: int) -> int:  # noqa: N802 (Qt)
        return self._arrange(QRect(0, 0, width, 0), apply=False)

    def setGeometry(self, rect: QRect) -> None:  # noqa: N802 (Qt)
        super().setGeometry(rect)
        self._arrange(rect, apply=True)

    def sizeHint(self) -> QSize:  # noqa: N802 (Qt)
        # tudo numa linha so
        width = sum(self._width(item) for item in self._shown()) + self.spacing() * max(0, len(self._shown()) - 1)
        height = max((item.sizeHint().height() for item in self._shown()), default=0)
        margins = self.contentsMargins()
        return QSize(width + margins.left() + margins.right(), height + margins.top() + margins.bottom())

    def minimumSize(self) -> QSize:  # noqa: N802 (Qt)
        # o item mais largo sozinho numa linha
        size = QSize()
        for item in self._shown():
            size = size.expandedTo(QSize(self._width(item), item.minimumSize().height()))
        margins = self.contentsMargins()
        return size + QSize(margins.left() + margins.right(), margins.top() + margins.bottom())

    def _shown(self) -> list[QLayoutItem]:
        return [item for item in self._items if not item.isEmpty()]

    @staticmethod
    def _expands(item: QLayoutItem) -> bool:
        widget = item.widget()
        return widget is not None and bool(widget.sizePolicy().horizontalPolicy() & QSizePolicy.PolicyFlag.ExpandFlag)

    def _width(self, item: QLayoutItem) -> int:
        # quem estica entra com a largura minima; os outros com a largura que pedem
        if self._expands(item):
            return max(item.minimumSize().width(), item.widget().minimumWidth())
        return item.sizeHint().width()

    def _arrange(self, rect: QRect, apply: bool) -> int:
        margins = self.contentsMargins()
        area = rect.adjusted(margins.left(), margins.top(), -margins.right(), -margins.bottom())
        spacing = self.spacing()
        lines: list[list[QLayoutItem]] = [[]]
        used = 0
        for item in self._shown():
            width = self._width(item)
            if lines[-1] and used + spacing + width > area.width():
                lines.append([])
                used = 0
            used += (spacing if lines[-1] else 0) + width
            lines[-1].append(item)
        y = area.y()
        for line in lines:
            if not line:
                continue
            height = max(item.sizeHint().height() for item in line)
            if apply:
                widths = [self._width(item) for item in line]
                spare = area.width() - sum(widths) - spacing * (len(line) - 1)
                growing = [i for i, item in enumerate(line) if self._expands(item)]
                for n, i in enumerate(growing):  # a sobra dividida entre os que esticam
                    widths[i] += max(0, spare) // len(growing) + (1 if n < max(0, spare) % len(growing) else 0)
                x = area.x()
                for item, width in zip(line, widths):
                    item_height = min(height, item.sizeHint().height())
                    item.setGeometry(QRect(QPoint(x, y + (height - item_height) // 2), QSize(width, item_height)))
                    x += width + spacing
            y += height + spacing
        return y - spacing - rect.y() + margins.bottom() if y > area.y() else margins.top() + margins.bottom()
