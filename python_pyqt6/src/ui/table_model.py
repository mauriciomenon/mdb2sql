# Modelo de tabela somente leitura para linhas vindas do DuckDB (lista de dicts)
# !T: Read-only table model; exposes display text, numeric alignment and a typed sort role. Every cell uses the base
# !T: font (Segoe UI 14 px like the other stacks; its digits have one width, so right-aligned numbers line up)

import heapq
import unicodedata
from decimal import Decimal
from typing import Any

import pandas as pd
from PyQt6.QtCore import QAbstractTableModel, QModelIndex, Qt, pyqtSignal

from backend.db_manager import MARK_KEY

# !T: Role read by QSortFilterProxyModel so numbers sort as numbers, not as text
SORT_ROLE = Qt.ItemDataRole.UserRole
COPY_ROLE = Qt.ItemDataRole.UserRole + 1  # texto copiado: o valor real (2316.0), nao o da grade (2316)

_INT64_MAX = 2**63 - 1


def is_missing(value: Any) -> bool:
    # !T: SQL NULL only: the rows are plain Python values (NULL is None); a DOUBLE NaN is a value and shows as nan
    return value is None or value is pd.NaT or value is pd.NA


def is_number(value: Any) -> bool:
    return isinstance(value, (int, float, Decimal)) and not isinstance(value, bool)


def display_text(value: Any) -> str:
    return "" if is_missing(value) else str(value)


def grid_text(value: Any, null_text: str = "") -> str:
    """Texto da grade: DOUBLE inteiro sem '.0' (2316.0 -> 2316), igual as outras stacks; NULL vira null_text.

    !T: Display only: copy (COPY_ROLE), the value filter (typed value) and exports keep the real value
    """
    if isinstance(value, float) and value.is_integer() and abs(value) < 1e16:
        return str(int(value))
    return null_text if is_missing(value) else str(value)


def sort_key(value: Any) -> int | float | str | None:
    if is_missing(value) or (isinstance(value, float) and value != value):
        return None  # !T: NaN has no order (every comparison is false): it sorts with the NULLs
    if is_number(value):
        # !T: Qt variants hold 64-bit ints and doubles only
        if isinstance(value, Decimal) or (isinstance(value, int) and abs(value) > _INT64_MAX):
            return float(value)
        return value
    return str(value)


def fold(text: str) -> str:
    """Minusculas e sem acentos: 'TENSÃO' -> 'tensao', 'ç' -> 'c', 'ñ' -> 'n'."""
    text = text.lower()
    if text.isascii():
        return text  # caminho rapido: a maioria das celulas
    return "".join(c for c in unicodedata.normalize("NFD", text) if not unicodedata.combining(c))


def search_words(query: str) -> list[str]:
    return fold(query).split()


class TableModel(QAbstractTableModel):
    """Linhas (dicts por coluna) e, na grade de Dados, a caixa de marcar de cada linha: uma coluna a mais, a ultima
    (a janela a mostra primeiro), ligada as identidades marcadas da tabela (`marks`, a chave MARK_KEY da linha)."""

    marksChanged = pyqtSignal()

    def __init__(self, parent=None, markable: bool = False) -> None:
        super().__init__(parent)
        self.rows: list[dict[str, Any]] = []
        self.columns: list[str] = []
        self.column_tips: list[str] = []
        self.numeric: list[bool] = []
        self.null_text = ""  # texto da celula NULL na grade: "NULL" ou vazio (Configuracoes > Exibir NULL)
        self.marks: set[Any] | None = set() if markable else None
        self.mark_tip = ""

    def mark_column(self) -> int:
        """Coluna da caixa de marcar (-1: sem ela)."""
        return len(self.columns) if self.marks is not None and self.columns else -1

    def toggle_mark(self, row: int) -> None:
        # linhas iguais (identidade pelo texto da linha) marcam e desmarcam juntas
        assert self.marks is not None
        key = self.rows[row].get(MARK_KEY)
        if key in self.marks:
            self.marks.discard(key)
        else:
            self.marks.add(key)
        self.marks_reset()

    def marks_reset(self) -> None:
        """As marcas mudaram: a coluna das caixas e redesenhada."""
        column = self.mark_column()
        if column >= 0 and self.rows:
            self.dataChanged.emit(self.index(0, column), self.index(len(self.rows) - 1, column),
                                  [Qt.ItemDataRole.CheckStateRole])
        self.marksChanged.emit()

    def flags(self, index: QModelIndex) -> Qt.ItemFlag:
        flags = super().flags(index)
        if index.isValid() and index.column() == self.mark_column():
            flags |= Qt.ItemFlag.ItemIsUserCheckable
        return flags

    def setData(self, index: QModelIndex, value: Any, role: int = Qt.ItemDataRole.EditRole) -> bool:  # noqa: N802 (Qt)
        if role != Qt.ItemDataRole.CheckStateRole or not index.isValid() or index.column() != self.mark_column():
            return False
        self.toggle_mark(index.row())
        return True

    def set_null_text(self, text: str) -> None:
        self.null_text = text
        if self.rows and self.columns:
            last = self.index(len(self.rows) - 1, len(self.columns) - 1)
            self.dataChanged.emit(self.index(0, 0), last, [Qt.ItemDataRole.DisplayRole])

    def longest_texts(self, column: int, count: int = 3) -> list[str]:
        """Os textos mais longos (em caracteres) da coluna, como aparecem na grade: candidatos para medir a largura."""
        # shortcut: runs in the UI thread, ~0.14 s for 1000 rows x 123 columns (the largest "Rows" choice);
        # move it to the table worker if larger "Rows" limits are added
        name = self.columns[column]
        return heapq.nlargest(count, (grid_text(row.get(name), self.null_text) for row in self.rows), key=len)

    def rowCount(self, parent: QModelIndex = QModelIndex()) -> int:
        return 0 if parent.isValid() else len(self.rows)

    def columnCount(self, parent: QModelIndex = QModelIndex()) -> int:
        return 0 if parent.isValid() else len(self.columns) + (self.mark_column() >= 0)

    def data(self, index: QModelIndex, role: int = Qt.ItemDataRole.DisplayRole) -> Any:
        if not index.isValid():
            return None

        column = index.column()
        if column == self.mark_column():
            if role != Qt.ItemDataRole.CheckStateRole:
                return None
            marked = self.rows[index.row()].get(MARK_KEY) in self.marks  # type: ignore[operator]
            return Qt.CheckState.Checked if marked else Qt.CheckState.Unchecked
        if role == Qt.ItemDataRole.TextAlignmentRole:
            side = Qt.AlignmentFlag.AlignRight if self.numeric[column] else Qt.AlignmentFlag.AlignLeft
            return side | Qt.AlignmentFlag.AlignVCenter
        if role == Qt.ItemDataRole.ToolTipRole:
            # texto longo inteiro na dica (na grade so corta acima de MAX_COLUMN_WIDTH, 1200 px)
            text = display_text(self.rows[index.row()].get(self.columns[column]))
            return text if len(text) > 40 else None
        if role not in (Qt.ItemDataRole.DisplayRole, SORT_ROLE, COPY_ROLE):
            return None

        value = self.rows[index.row()].get(self.columns[column])
        if role == Qt.ItemDataRole.DisplayRole:
            return grid_text(value, self.null_text)
        return display_text(value) if role == COPY_ROLE else sort_key(value)

    def headerData(
        self,
        section: int,
        orientation: Qt.Orientation,
        role: int = Qt.ItemDataRole.DisplayRole,
    ) -> Any:
        if orientation == Qt.Orientation.Vertical:
            return str(section + 1) if role == Qt.ItemDataRole.DisplayRole else None
        if section == self.mark_column():  # caixa de marcar: sem titulo, so a dica
            return self.mark_tip if role == Qt.ItemDataRole.ToolTipRole else None
        if not 0 <= section < len(self.columns):
            return None
        if role == Qt.ItemDataRole.DisplayRole:
            return self.columns[section]
        if role == Qt.ItemDataRole.ToolTipRole:  # nome inteiro mesmo se a coluna ficar estreita
            return self.column_tips[section] if self.column_tips else self.columns[section]
        if role == Qt.ItemDataRole.TextAlignmentRole:  # cabecalho alinhado como a coluna: numeros a direita
            return self.data(self.index(0, section), role) if self.rows else None
        return None

    def set_rows(
        self,
        rows: list[dict[str, Any]],
        columns: list[str] | None = None,
        column_tips: list[str] | None = None,
    ) -> None:
        # columns: nomes vindos do schema, para mostrar o cabecalho mesmo com 0 linhas
        self.beginResetModel()
        self.rows = rows
        self.columns = list(columns) if columns else (list(rows[0].keys()) if rows else [])
        self.column_tips = list(column_tips) if column_tips else []
        self.numeric = [self._is_numeric_column(name) for name in self.columns]
        self.endResetModel()

    def _is_numeric_column(self, name: str) -> bool:
        values = [v for v in (row.get(name) for row in self.rows) if not is_missing(v)]
        return bool(values) and all(is_number(v) for v in values)

