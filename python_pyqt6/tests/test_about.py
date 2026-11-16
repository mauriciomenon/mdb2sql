import re
import sys

from PyQt6.QtWidgets import QMessageBox

from shared import about
from ui.main_window import MainWindow


def test_about_lines() -> None:
    lines = about.about_lines()

    assert lines[0] == "MDB2SQL (Python + PyQt6)"
    assert lines[1] == "Versao 1.1.1 - build dev"
    assert lines[2] == "Abre bancos Access (.mdb/.accdb), SQLite e DuckDB e exporta para DuckDB, SQLite, Excel e CSV."
    assert re.fullmatch(
        r"Python [\d.]+\S*, PyQt6 [\d.]+, Qt [\d.]+, DuckDB [\d.]+\S*, XlsxWriter [\d.]+, pyodbc [\d.]+", lines[3]
    )
    assert lines[4:] == ["Autor: Mauricio Menon", "Codigo: https://github.com/mauriciomenon/mdb2sql"]
    assert "@" not in "".join(lines)


def test_version_from_frozen_bundle(tmp_path, monkeypatch) -> None:
    (tmp_path / "VERSION").write_text("9.9.9\n", encoding="utf-8")
    monkeypatch.setattr(sys, "_MEIPASS", str(tmp_path), raising=False)

    assert about.app_version() == "9.9.9"
    assert about.build_info() == "build dev"  # exe sem BUILD
    (tmp_path / "BUILD").write_text("123 2026-11-15\n", encoding="utf-8")
    assert about.build_info() == "build 123 (2026-11-15)"


def test_help_menu_opens_about(qtbot) -> None:
    win = MainWindow()
    qtbot.addWidget(win)
    win.show_about()

    box = win.findChild(QMessageBox)
    assert box.windowTitle() == "Sobre"
    assert "Versao 1.1.1 - build dev" in box.text()
    box.close()
