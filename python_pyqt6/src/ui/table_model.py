# Modelo de tabela somente leitura para linhas vindas do DuckDB (lista de dicts)
# !T: Read-only table model; exposes display text, numeric alignment/font and a typed sort role

import unicodedata
from decimal import Decimal
from typing import Any

import pandas as pd
from PyQt6.QtCore import QAbstractTableModel, QModelIndex, QSortFilterProxyModel, Qt
from PyQt6.QtGui import QFontDatabase

# !T: Role read by QSortFilterProxyModel so numbers sort as numbers, not as text
SORT_ROLE = Qt.ItemDataRole.UserRole

_INT64_MAX = 2**63 - 1
# !T: str.split() treats \x1f as whitespace, so no search word holds it and none matches across two cells
CELL_SEP = "\x1f"


def is_missing(value: Any) -> bool:
    # !T: pandas turns SQL NULL into None, NaN, NaT or NA depending on the column type
    return (
        value is None
        or value is pd.NaT
        or value is pd.NA
        or (isinstance(value, float) and value != value)
    )


def is_number(value: Any) -> bool:
    return isinstance(value, (int, float, Decimal)) and not isinstance(value, bool)


def display_text(value: Any) -> str:
    return "" if is_missing(value) else str(value)


def sort_key(value: Any) -> int | float | str | None:
    if is_missing(value):
        return None
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
    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.rows: list[dict[str, Any]] = []
        self.columns: list[str] = []
        self.column_tips: list[str] = []
        self.numeric: list[bool] = []
        self._search_rows: list[str] | None = None  # texto de busca de cada linha (fold), feito na 1a busca
        self._fixed_font = QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont)

    def rowCount(self, parent: QModelIndex = QModelIndex()) -> int:
        return 0 if parent.isValid() else len(self.rows)

    def columnCount(self, parent: QModelIndex = QModelIndex()) -> int:
        return 0 if parent.isValid() else len(self.columns)

    def data(self, index: QModelIndex, role: int = Qt.ItemDataRole.DisplayRole) -> Any:
        if not index.isValid():
            return None

        column = index.column()
        if role == Qt.ItemDataRole.TextAlignmentRole:
            side = Qt.AlignmentFlag.AlignRight if self.numeric[column] else Qt.AlignmentFlag.AlignLeft
            return side | Qt.AlignmentFlag.AlignVCenter
        if role == Qt.ItemDataRole.FontRole:
            return self._fixed_font if self.numeric[column] else None
        if role == Qt.ItemDataRole.ToolTipRole:
            # coluna limitada a MAX_COLUMN_WIDTH: texto longo cortado na grade aparece inteiro na dica
            text = display_text(self.rows[index.row()].get(self.columns[column]))
            return text if len(text) > 40 else None
        if role not in (Qt.ItemDataRole.DisplayRole, SORT_ROLE):
            return None

        value = self.rows[index.row()].get(self.columns[column])
        return display_text(value) if role == Qt.ItemDataRole.DisplayRole else sort_key(value)

    def headerData(
        self,
        section: int,
        orientation: Qt.Orientation,
        role: int = Qt.ItemDataRole.DisplayRole,
    ) -> Any:
        if orientation == Qt.Orientation.Vertical:
            return str(section + 1) if role == Qt.ItemDataRole.DisplayRole else None
        if not 0 <= section < len(self.columns):
            return None
        if role == Qt.ItemDataRole.DisplayRole:
            return self.columns[section]
        if role == Qt.ItemDataRole.ToolTipRole and self.column_tips:
            return self.column_tips[section]
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
        self._search_rows = None
        self.endResetModel()

    def search_text(self, row: int) -> str:
        # !T: Folded once per load, not per keystroke: the cells of a row joined by CELL_SEP
        if self._search_rows is None:
            self._search_rows = [
                fold(CELL_SEP.join([display_text(r.get(c)) for c in self.columns])) for r in self.rows
            ]
        return self._search_rows[row]

    def _is_numeric_column(self, name: str) -> bool:
        values = [v for v in (row.get(name) for row in self.rows) if not is_missing(v)]
        return bool(values) and all(is_number(v) for v in values)


class SearchProxyModel(QSortFilterProxyModel):
    """Mostra a linha quando uma celula tem todas as palavras da busca, em qualquer ordem, sem caixa nem acento."""

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.words: list[str] = []

    def set_query(self, query: str) -> None:
        self.words = search_words(query)
        self.invalidateRowsFilter()

    def filterAcceptsRow(self, source_row: int, source_parent: QModelIndex) -> bool:
        if not self.words:
            return True
        text = self.sourceModel().search_text(source_row)
        words = self.words
        # rejeita rapido a linha sem todas as palavras; so depois confere celula por celula
        if not all(word in text for word in words):
            return False
        if len(words) == 1:
            return True  # uma palavra nunca atravessa CELL_SEP: ja esta numa celula so
        return any(all(word in cell for word in words) for cell in text.split(CELL_SEP))
