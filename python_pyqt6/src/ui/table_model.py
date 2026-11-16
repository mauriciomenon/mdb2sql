# Modelo de tabela somente leitura para linhas vindas do DuckDB (lista de dicts)
# !T: Read-only table model; exposes display text, numeric alignment/font and a typed sort role

from decimal import Decimal
from typing import Any

import pandas as pd
from PyQt6.QtCore import QAbstractTableModel, QModelIndex, Qt
from PyQt6.QtGui import QFontDatabase

# !T: Role read by QSortFilterProxyModel so numbers sort as numbers, not as text
SORT_ROLE = Qt.ItemDataRole.UserRole

_INT64_MAX = 2**63 - 1


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


class TableModel(QAbstractTableModel):
    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.rows: list[dict[str, Any]] = []
        self.columns: list[str] = []
        self.column_tips: list[str] = []
        self.numeric: list[bool] = []
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
        self.endResetModel()

    def _is_numeric_column(self, name: str) -> bool:
        values = [v for v in (row.get(name) for row in self.rows) if not is_missing(v)]
        return bool(values) and all(is_number(v) for v in values)
