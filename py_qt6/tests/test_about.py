import re
import sys

from PyQt6.QtWidgets import QMessageBox

from shared import about
from ui.main_window import MainWindow


def test_about_lines() -> None:
    lines = about.about_lines()

    assert lines[0] == "MDB2SQL (Python + PyQt6)"
    assert lines[1] == "Versao 1.0.1"
    assert lines[2] == (
        "Visualizador de bancos DuckDB convertidos de Microsoft Access: tabelas, esquema, dados e consultas."
    )
    assert re.fullmatch(r"Python [\d.]+\S*, PyQt6 [\d.]+, Qt [\d.]+, DuckDB [\d.]+\S*", lines[3])
    assert lines[4:] == ["Autor: Mauricio Menon", "Codigo: https://github.com/mauriciomenon/mdb2sql"]
    assert "@" not in "".join(lines)


def test_version_from_frozen_bundle(tmp_path, monkeypatch) -> None:
    (tmp_path / "VERSION").write_text("9.9.9\n", encoding="utf-8")
    monkeypatch.setattr(sys, "_MEIPASS", str(tmp_path), raising=False)

    assert about.app_version() == "9.9.9"


def test_help_menu_opens_about(qtbot) -> None:
    win = MainWindow()
    qtbot.addWidget(win)
    win.show_about()

    box = win.findChild(QMessageBox)
    assert box.windowTitle() == "Sobre"
    assert "Versao 1.0.1" in box.text()
    box.close()
