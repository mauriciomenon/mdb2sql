import re
import sys
import tomllib
from pathlib import Path

from PyQt6.QtCore import Qt
from PyQt6.QtTest import QTest
from PyQt6.QtWidgets import QLabel, QPushButton

from shared import about, i18n
from shared.bundle import bundled
from shared.display import decide
from ui.dialogs import AboutDialog, ChoiceBox, ColumnsDialog, DisplayWarning
from ui.main_window import MainWindow

GITHUB = "https://github.com/mauriciomenon/mdb2sql"
GITLAB = "https://gitlab.com/mauricio.menon/mdb2sql"
ROOT = Path(__file__).resolve().parents[1]


def test_license_is_gpl2_or_later() -> None:
    text = (ROOT / "LICENSE").read_text(encoding="utf-8")
    assert text.split()[:5] == ["GNU", "GENERAL", "PUBLIC", "LICENSE", "Version"] and text.split()[5] == "2,"
    project = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))["project"]
    assert project["license"] == "GPL-2.0-or-later"
    assert about.about_lines()[-1] == "License: GPLv2"  # so isso no Sobre (BRIEF 18 b)
    i18n.set_language("pt_BR")
    assert about.about_lines()[-1] == "Licença: GPLv2"
    i18n.set_language("en")
    # o pacote (zip e instalador) leva o LICENSE
    assert "'LICENSE'" in (ROOT / "scripts" / "package_w11.ps1").read_text(encoding="utf-8")


def test_title_is_short_and_uses_the_single_version_source() -> None:
    assert about.app_version() == "1.3.0"
    assert about.app_title() == "mdb2sql 1.3.0 - Python"


def test_about_lines_are_the_same_in_the_four_versions() -> None:
    # BRIEF 18 b: so estas linhas, nesta ordem, texto tecnico; nada de Build N, Stack, Janela, Bancos, Leitura, Gravacao
    lines = about.about_lines()
    mdbtools = about.mdbtools_version()
    assert mdbtools == ("1.0.1" if (bundled("mdbtools") / "VERSION.txt").is_file() else "")
    tools = r"Tools: SQLite [\d.]+, DuckDB [\d.]+\S*" + (rf", mdbtools {re.escape(mdbtools)}" if mdbtools else "")
    patterns = [r"MDB2SQL \(Python\)", r"Version 1\.3\.0 - dev", r"Python [\d.]+\S*, PyQt6 [\d.]+ \(Qt [\d.]+\)", tools,
                r"ODBC driver support, if installed\.", r"Author: Mauricio Menon", r"License: GPLv2"]
    assert len(lines) == len(patterns) and all(re.fullmatch(p, line) for p, line in zip(patterns, lines)), lines
    assert about.LINKS == (("GitHub", GITHUB), ("GitLab", GITLAB))
    assert "@" not in "".join(lines)
    i18n.set_language("es")
    assert about.about_lines()[3].startswith("Herramientas: SQLite ")
    assert about.about_lines()[4] == "Soporte del controlador ODBC, si está instalado."
    i18n.set_language("en")


def test_version_from_frozen_bundle(tmp_path, monkeypatch) -> None:
    (tmp_path / "VERSION").write_text("9.9.9\n", encoding="utf-8")
    monkeypatch.setattr(sys, "_MEIPASS", str(tmp_path), raising=False)

    assert about.app_version() == "9.9.9"
    assert about.app_title() == "mdb2sql 9.9.9 - Python"
    assert about.about_lines()[1] == "Version 9.9.9 - dev"  # exe sem BUILD
    commit = "0123456789abcdef0123456789abcdef01234567"
    (tmp_path / "BUILD").write_text(f"{commit} 2026-11-26\n", encoding="utf-8")
    assert about.about_lines()[1] == f"Version 9.9.9 - commit {commit} - 2026-11-26"  # o hash completo
    (tmp_path / "BUILD").write_text("123 2026-11-15\n", encoding="utf-8")  # formato antigo: dev, nunca "Build 123"
    assert about.about_lines()[1] == "Version 9.9.9 - dev"
    # o spec grava o commit completo (git rev-parse HEAD), nao o numero de commits
    spec = (ROOT / "mdb2sql.spec").read_text(encoding="utf-8")
    assert '"rev-parse", "HEAD"' in spec and "rev-list" not in spec


def test_boxes_with_several_buttons_have_one_button_size_in_every_language(qtbot) -> None:
    # dono 26/11: todos os botoes da caixa com a mesma largura e altura, a do maior texto nos 3 idiomas
    from pathlib import Path

    win = MainWindow()
    qtbot.addWidget(win)
    sizes: dict[str, set] = {}
    for code in i18n.LANGUAGES:
        i18n.set_language(code)
        boxes = {"exit": win.exit_box(Path("db.accdb")), "export": win.export_running_box("x.csv"),
                 "found": win.found_rows_box(3)[0], "overwrite": win.overwrite_box(2),
                 "columns": ColumnsDialog("t", ["a"], set())}
        for name, box in boxes.items():
            buttons = box.findChildren(QPushButton)
            assert len(buttons) > 1, name
            one = {(b.minimumSize().width(), b.minimumSize().height(), b.maximumSize().width()) for b in buttons}
            assert len(one) == 1, (code, name, one)
            sizes.setdefault(name, set()).update(one)
            box.deleteLater()
    i18n.set_language("en")
    # a caixa nao muda de tamanho com o idioma (Sim/Nao do Qt: so o idioma atual, sempre abaixo do minimo)
    assert {name: len(found) for name, found in sizes.items()} == dict.fromkeys(sizes, 1)


def test_every_dialog_has_an_explicit_default_button_and_esc_closes(qtbot) -> None:
    # REGRA_VISUAL: botao explicito (OK/Fechar), Enter = botao padrao, Esc = fechar; nunca so o X
    _, notice = decide({"WAYLAND_DISPLAY": "wayland-0"}, "ID=debian\n", [])
    for dialog, label in ((AboutDialog(), "OK"), (ColumnsDialog("t", ["a"], set()), "Close"),
                          (DisplayWarning(notice), "OK"),
                          (ChoiceBox("t", "q", {"s": "Save"}, {"b": "Back", "e": "Exit"}, "s", "b"), "Save")):
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
    assert box.title.text() == "MDB2SQL (Python)" and box.title.font() == box.font()  # uma fonte so (18 e)
    assert [label.text() for label in box.lines] == about.about_lines()
    assert not any(label.text().endswith(":") for label in box.findChildren(QLabel))  # sem rotulos de formulario
    # GitHub / GitLab numa linha, os dois links abrem no navegador padrao (openExternalLinks) e aceitam teclado
    assert [link.text() for link in box.links] == [f'<a href="{GITHUB}">GitHub</a> / <a href="{GITLAB}">GitLab</a>']
    for link in box.links:
        assert link.openExternalLinks()
        assert link.textInteractionFlags() & Qt.TextInteractionFlag.LinksAccessibleByMouse
    box.close()
