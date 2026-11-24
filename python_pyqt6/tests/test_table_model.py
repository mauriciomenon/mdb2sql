from decimal import Decimal

import pandas as pd
from PyQt6.QtCore import Qt

from ui.table_model import (
    COPY_ROLE,
    SORT_ROLE,
    TableModel,
    display_text,
    fold,
    is_missing,
    is_number,
    sort_key,
)


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


def test_whole_doubles_show_without_decimal_part_but_copy_the_real_value(qtbot) -> None:
    # paridade com as outras stacks: RTUNO 2.0 aparece 2, PNTNO 2316.0 aparece 2316; 2.5, NaN e DECIMAL nao mudam
    model = TableModel()
    values = [2.0, 2316.0, -0.0, 2.5, 1e20, float("nan"), None, Decimal("1.50"), 7]
    model.set_rows([{"v": v} for v in values])
    shown = [model.data(model.index(r, 0)) for r in range(len(values))]
    assert shown == ["2", "2316", "0", "2.5", "1e+20", "", "", "1.50", "7"]
    copied = [model.data(model.index(r, 0), COPY_ROLE) for r in range(len(values))]
    assert copied[:2] == ["2.0", "2316.0"] and copied[3] == "2.5"  # copia o valor real
    assert model.data(model.index(1, 0), SORT_ROLE) == 2316.0
    assert model.rows[1]["v"] == 2316.0  # o filtro por valor usa o valor tipado da linha


def test_null_text_is_display_only(qtbot) -> None:
    # Configuracoes > Exibir NULL: a grade mostra "NULL"; texto vazio continua vazio; copiar continua vazio
    model = TableModel()
    model.set_rows([{"v": None}, {"v": float("nan")}, {"v": ""}, {"v": 2.0}])
    changed = []
    model.dataChanged.connect(lambda first, last, _roles: changed.append((first.row(), last.row())))
    model.set_null_text("NULL")
    assert [model.data(model.index(r, 0)) for r in range(4)] == ["NULL", "NULL", "", "2"]
    assert model.data(model.index(0, 0), COPY_ROLE) == "" and changed == [(0, 3)]  # a vista redesenha na hora
    assert model.longest_texts(0, 1) == ["NULL"]  # a largura da coluna conta o texto que aparece
    model.set_null_text("")
    assert model.data(model.index(0, 0)) == ""


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
    # cabecalho alinhado como a coluna: numeros a direita, texto a esquerda
    align = Qt.ItemDataRole.TextAlignmentRole
    assert model.headerData(0, Qt.Orientation.Horizontal, align) & Qt.AlignmentFlag.AlignRight
    assert model.headerData(1, Qt.Orientation.Horizontal, align) & Qt.AlignmentFlag.AlignLeft
    model.set_rows([{"note": "x" * 50}, {"note": "short"}])
    assert model.data(model.index(0, 0), Qt.ItemDataRole.ToolTipRole) == "x" * 50
    assert model.data(model.index(1, 0), Qt.ItemDataRole.ToolTipRole) is None


def test_model_keeps_columns_for_empty_table(qtbot) -> None:
    model = TableModel()
    model.set_rows([], ["code", "label"], ["code: INTEGER", "label: VARCHAR"])

    assert (model.rowCount(), model.columnCount()) == (0, 2)
    assert model.numeric == [False, False]
    assert model.headerData(0, Qt.Orientation.Horizontal, Qt.ItemDataRole.ToolTipRole) == "code: INTEGER"


def test_fold_drops_case_and_accents() -> None:
    assert fold("EXCITAÇÃO TENSÃO") == "excitacao tensao"
    assert fold("Ñandú çÇ") == "nandu cc"

