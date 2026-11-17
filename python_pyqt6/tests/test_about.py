import re
import sys

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import QLabel

from shared import about
from ui.dialogs import AboutDialog
from ui.main_window import MainWindow

GITHUB = "https://github.com/mauriciomenon/mdb2sql"
GITLAB = "https://gitlab.com/mauricio.menon/mdb2sql"


def test_title_is_short_and_uses_the_single_version_source() -> None:
    assert about.app_version() == "1.2.0"
    assert about.app_title() == "mdb2sql 1.2.0 - Python"


def test_about_fields() -> None:
    fields = dict(about.about_fields())

    assert list(fields) == ["Build", "Stack", "Bibliotecas", "Leitura do Access", "Autor", "Licenca"]
    assert fields["Build"] == "dev"
    assert re.fullmatch(r"Python [\d.]+\S* \+ PyQt6 [\d.]+ \(Qt [\d.]+\)", fields["Stack"])
    assert re.fullmatch(r"DuckDB [\d.]+\S*, XlsxWriter [\d.]+, pyodbc [\d.]+", fields["Bibliotecas"])
    assert re.fullmatch(
        r"ODBC Microsoft Access Driver \((nao )?instalado\) ou mdbtools( [\d.]+ embutido| \(so no exe de release\))",
        fields["Leitura do Access"],
    )
    assert fields["Autor"] == "Mauricio Menon"
    assert about.LINKS == (("GitHub", GITHUB), ("GitLab", GITLAB))
    assert "@" not in "".join(fields.values())


def test_version_from_frozen_bundle(tmp_path, monkeypatch) -> None:
    (tmp_path / "VERSION").write_text("9.9.9\n", encoding="utf-8")
    monkeypatch.setattr(sys, "_MEIPASS", str(tmp_path), raising=False)

    assert about.app_version() == "9.9.9"
    assert about.app_title() == "mdb2sql 9.9.9 - Python"
    assert about.build_info() == "build dev"  # exe sem BUILD
    (tmp_path / "BUILD").write_text("123 2026-11-15\n", encoding="utf-8")
    assert about.build_info() == "build 123 (2026-11-15)"
    assert dict(about.about_fields())["Build"] == "123 (2026-11-15)"


def test_help_menu_opens_about_with_clickable_links(qtbot) -> None:
    win = MainWindow()
    qtbot.addWidget(win)
    win.show_about()

    box = win.findChild(AboutDialog)
    assert box.windowTitle() == "Sobre"
    assert box.title.text() == "mdb2sql 1.2.0"
    texts = [label.text() for label in box.findChildren(QLabel)]
    assert "Build:" in texts and "dev" in texts and "Licenca:" in texts
    # os dois links abrem no navegador padrao (openExternalLinks) e aceitam teclado
    assert [link.text() for link in box.links] == [f'<a href="{url}">{url}</a>' for url in (GITHUB, GITLAB)]
    for link in box.links:
        assert link.openExternalLinks()
        assert link.textInteractionFlags() & Qt.TextInteractionFlag.LinksAccessibleByMouse
    box.close()
