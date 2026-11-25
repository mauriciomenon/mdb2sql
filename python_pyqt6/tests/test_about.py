import re
import sys
import tomllib
from pathlib import Path

from PyQt6.QtCore import Qt
from PyQt6.QtTest import QTest
from PyQt6.QtWidgets import QLabel, QPushButton

from backend.access import odbc_available
from shared import about, i18n
from shared.bundle import bundled
from shared.display import decide
from ui.dialogs import AboutDialog, ColumnsDialog, DisplayWarning
from ui.main_window import MainWindow

GITHUB = "https://github.com/mauriciomenon/mdb2sql"
GITLAB = "https://gitlab.com/mauricio.menon/mdb2sql"
ROOT = Path(__file__).resolve().parents[1]


def test_license_is_gpl2_or_later() -> None:
    text = (ROOT / "LICENSE").read_text(encoding="utf-8")
    assert text.split()[:5] == ["GNU", "GENERAL", "PUBLIC", "LICENSE", "Version"] and text.split()[5] == "2,"
    project = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))["project"]
    assert project["license"] == "GPL-2.0-or-later"
    assert dict(about.about_fields())["License"] == "GPL v2 or later"
    i18n.set_language("pt_BR")
    assert dict(about.about_fields())["Licença"] == "GPL v2 ou posterior"
    # o pacote (zip e instalador) leva o LICENSE
    assert "'LICENSE'" in (ROOT / "scripts" / "package_w11.ps1").read_text(encoding="utf-8")


def test_title_is_short_and_uses_the_single_version_source() -> None:
    assert about.app_version() == "1.3.0"
    assert about.app_title() == "mdb2sql 1.3.0 - Python"


def test_about_fields() -> None:
    fields = dict(about.about_fields())

    # as linhas do Sobre do Rust, igual nas 4 versoes
    assert list(fields) == ["Build", "Stack", "Window", "Databases", "Access reading", "Author", "License"]
    assert fields["Build"] == "dev"
    assert re.fullmatch(r"Python [\d.]+\S* \+ PyQt6 [\d.]+", fields["Stack"])
    assert re.fullmatch(r"Qt [\d.]+", fields["Window"])
    assert re.fullmatch(r"SQLite [\d.]+, DuckDB [\d.]+\S*", fields["Databases"])
    # como o Access e lido; o driver ODBC e opcional e nunca aparece como "nao instalado"
    mdbtools = about.mdbtools_version()
    assert mdbtools == ("1.0.1" if (bundled("mdbtools") / "VERSION.txt").is_file() else "")
    if odbc_available():
        expected = f"Access ODBC driver (installed); fallback: embedded mdbtools {mdbtools}" if mdbtools else (
            "Access ODBC driver (installed)")
    else:
        expected = f"Embedded mdbtools {mdbtools}" if mdbtools else "mdbtools not bundled (source run)"
    assert fields["Access reading"] == expected and "not installed" not in fields["Access reading"]
    assert fields["Author"] == "Mauricio Menon"
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


def test_every_dialog_has_an_explicit_default_button_and_esc_closes(qtbot) -> None:
    # REGRA_VISUAL: botao explicito (OK/Fechar), Enter = botao padrao, Esc = fechar; nunca so o X
    _, notice = decide({"WAYLAND_DISPLAY": "wayland-0"}, "ID=debian\n", [])
    for dialog, label in ((AboutDialog(), "OK"), (ColumnsDialog("t", ["a"], set()), "Close"),
                          (DisplayWarning(notice), "OK")):
        qtbot.addWidget(dialog)
        dialog.show()
        defaults = [b.text() for b in dialog.findChildren(QPushButton) if b.isDefault()]
        assert defaults == [label], type(dialog).__name__  # visivel, e o que o Enter aciona
        QTest.keyClick(dialog, Qt.Key.Key_Escape)
        assert not dialog.isVisible(), type(dialog).__name__


def test_help_menu_opens_about_with_clickable_links(qtbot) -> None:
    win = MainWindow()
    qtbot.addWidget(win)
    win.show_about()

    box = win.findChild(AboutDialog)
    assert box.windowTitle() == "About mdb2sql"  # titulo do Zig, igual nas 4 versoes
    assert box.title.text() == "mdb2sql 1.3.0"
    texts = [label.text() for label in box.findChildren(QLabel)]
    assert "Build:" in texts and "dev" in texts and "License:" in texts
    # os dois links abrem no navegador padrao (openExternalLinks) e aceitam teclado
    assert [link.text() for link in box.links] == [f'<a href="{url}">{url}</a>' for url in (GITHUB, GITLAB)]
    for link in box.links:
        assert link.openExternalLinks()
        assert link.textInteractionFlags() & Qt.TextInteractionFlag.LinksAccessibleByMouse
    box.close()
