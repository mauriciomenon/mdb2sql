from pathlib import Path

import duckdb
from PyQt6.QtCore import QItemSelectionModel, Qt
from PyQt6.QtWidgets import QApplication

from shared.tsv import rows_to_tsv, tsv_field
from ui.main_window import MainWindow


def test_tsv_field_escapes_tab_newline_and_quote() -> None:
    assert tsv_field("plain text") == "plain text"
    assert tsv_field(None) == ""
    assert tsv_field(7.25) == "7.25"
    assert tsv_field("a\tb") == '"a\tb"'
    assert tsv_field("line1\nline2") == '"line1\nline2"'
    assert tsv_field('say "hi"') == '"say ""hi"""'


def test_rows_to_tsv_with_and_without_header() -> None:
    rows = [[1, "Ana"], [2, "a\tb"]]

    assert rows_to_tsv(rows) == '1\tAna\n2\t"a\tb"'
    assert rows_to_tsv(rows, ["id", "name"]) == 'id\tname\n1\tAna\n2\t"a\tb"'


def _open(qtbot, db_file: Path) -> MainWindow:
    win = MainWindow()
    qtbot.addWidget(win)
    win.show()
    win.open_database(db_file)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=30000)
    return win


def test_copy_value_and_row(qtbot, tmp_path: Path) -> None:
    db_file = tmp_path / "notes.duckdb"
    conn = duckdb.connect(str(db_file))
    conn.execute("CREATE TABLE notes (id INTEGER, note VARCHAR)")
    conn.execute("INSERT INTO notes VALUES (1, 'a\tb'), (2, 'plain')")
    conn.close()
    win = _open(qtbot, db_file)
    clipboard = QApplication.clipboard()

    # menu de contexto (clique direito) da grade igual nas 4 versoes (Go): na aba Data primeiro os filtros por valor,
    # depois copiar valor / linha / linha com cabecalho; nas outras grades so copiar
    assert win.data_table.contextMenuPolicy() == Qt.ContextMenuPolicy.ActionsContextMenu
    copy_texts = ["&Copy value", "Copy &row", "Copy row with &header"]
    assert [action.text() for action in win.data_table.actions()] == [
        "&Filter by this value",
        "C&lear filters",
        "",  # separador
        *copy_texts,
    ]
    assert [action.text() for action in win.sql_table.actions()] == copy_texts
    assert [action.text() for action in win.schema_table.actions()] == copy_texts

    win.data_table.setCurrentIndex(win.data_proxy.index(0, 1))
    win.copy_action.trigger()
    assert clipboard.text() == "a\tb"  # valor puro

    win.copy_row_action.trigger()
    assert clipboard.text() == '1\t"a\tb"'

    win.data_table.selectionModel().select(win.data_proxy.index(1, 0), QItemSelectionModel.SelectionFlag.Select)
    win.copy_row_header_action.trigger()
    assert clipboard.text() == 'id\tnote\n1\t"a\tb"\n2\tplain'


def test_selection_without_current_loads_table(qtbot, people_db: Path) -> None:
    # UI Automation seleciona o item sem torna-lo o item atual
    win = _open(qtbot, people_db)
    item = win.table_list.findItems("people", Qt.MatchFlag.MatchExactly)[0]
    win.table_list.selectionModel().select(
        win.table_list.indexFromItem(item), QItemSelectionModel.SelectionFlag.ClearAndSelect
    )

    qtbot.waitUntil(lambda: win.loaded_table is not None and win.loaded_table[0] == "people", timeout=30000)
