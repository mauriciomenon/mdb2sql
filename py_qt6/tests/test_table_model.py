from decimal import Decimal

import pandas as pd
from PyQt6.QtCore import Qt

from ui.table_model import SORT_ROLE, TableModel, display_text, is_missing, is_number, sort_key


def test_missing_values_show_as_empty_text() -> None:
    for value in (None, float("nan"), pd.NaT, pd.NA):
        assert is_missing(value)
        assert display_text(value) == ""
        assert sort_key(value) is None
    assert not is_missing(0)
    assert display_text(0) == "0"


def test_numbers_keep_their_type_for_sorting() -> None:
    assert is_number(3) and is_number(2.5) and is_number(Decimal("1.5"))
    assert not is_number(True) and not is_number("3")
    assert sort_key(10) == 10
    assert sort_key(Decimal("1.5")) == 1.5
    assert sort_key(2**70) == float(2**70)
    assert sort_key(pd.Timestamp("2026-07-14")) == "2026-07-14 00:00:00"


def test_model_roles(qtbot) -> None:
    model = TableModel()
    model.set_rows([{"id": 1, "name": "Ana"}, {"id": 10, "name": None}])

    assert (model.rowCount(), model.columnCount()) == (2, 2)
    assert model.numeric == [True, False]
    assert model.data(model.index(1, 0)) == "10"
    assert model.data(model.index(1, 0), SORT_ROLE) == 10
    assert model.data(model.index(1, 1)) == ""
    assert model.data(model.index(0, 0), Qt.ItemDataRole.TextAlignmentRole) & Qt.AlignmentFlag.AlignRight
    assert model.data(model.index(0, 1), Qt.ItemDataRole.TextAlignmentRole) & Qt.AlignmentFlag.AlignLeft
    assert model.data(model.index(0, 0), Qt.ItemDataRole.FontRole) is not None
    assert model.data(model.index(0, 1), Qt.ItemDataRole.FontRole) is None
    assert model.headerData(1, Qt.Orientation.Horizontal) == "name"


def test_model_keeps_columns_for_empty_table(qtbot) -> None:
    model = TableModel()
    model.set_rows([], ["code", "label"], ["code: INTEGER", "label: VARCHAR"])

    assert (model.rowCount(), model.columnCount()) == (0, 2)
    assert model.numeric == [False, False]
    assert model.headerData(0, Qt.Orientation.Horizontal, Qt.ItemDataRole.ToolTipRole) == "code: INTEGER"
