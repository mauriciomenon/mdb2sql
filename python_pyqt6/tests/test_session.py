# 1.3.0: Access convertido para SQLite (salvar/apagar ao fechar), painel Log, idiomas e textos so nos catalogos
import json
import re
import shutil
from pathlib import Path

import pytest
from PyQt6.QtCore import QSettings, Qt
from PyQt6.QtGui import QAction, QFontDatabase
from PyQt6.QtWidgets import QAbstractButton, QApplication, QDockWidget, QLabel, QLineEdit, QMenu, QTabWidget

from backend import access
from shared import i18n
from ui import main_window as mw
from ui.main_window import MainWindow

SAMPLE = Path(__file__).with_name("data") / "sample.mdb"
SRC = Path(__file__).resolve().parents[1] / "src"
needs_mdbtools = pytest.mark.skipif(access.mdbtools_dir() is None, reason="sem .tools/mdbtools")


@pytest.fixture
def access_window(qtbot, tmp_path: Path, monkeypatch) -> MainWindow:
    monkeypatch.setenv("MDB2SQL_ACCESS_READER", "mdbtools")  # o caminho sem nada instalado
    copy = tmp_path / "sample.mdb"
    shutil.copy2(SAMPLE, copy)
    win = MainWindow()
    qtbot.addWidget(win)
    win.show()
    win.open_database(copy)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=60000)
    return win


def _converted_files(win: MainWindow) -> list[Path]:
    return sorted(win.session.path.rglob("*.sqlite"))


@needs_mdbtools
def test_access_opens_through_one_sqlite_conversion(access_window: MainWindow) -> None:
    win = access_window
    assert win.status_label.text() == "Loaded: sample.mdb (2 tables) via mdbtools, converted to SQLite"
    assert [win.table_list.item(i).text() for i in range(2)] == ["empty table", "points"]
    assert [p.name for p in _converted_files(win)] == ["sample.sqlite"]


@needs_mdbtools
def test_close_asks_and_deletes_or_saves_or_cancels(qtbot, access_window: MainWindow, tmp_path: Path, monkeypatch):
    win = access_window
    source = win.current_db_path
    answers = [(mw.CANCEL, False), (mw.SAVE, False)]
    asked = []
    monkeypatch.setattr(win, "ask_converted", lambda path: asked.append(path) or answers.pop(0))
    target = tmp_path / "kept" / "sample.sqlite"
    target.parent.mkdir()
    monkeypatch.setattr(win, "ask_converted_target", lambda path: target)

    win.close_db_action.trigger()  # Cancelar: continua aberto
    assert win.manager is not None and len(_converted_files(win)) == 1

    win.close_db_action.trigger()  # Salvar: vai para a pasta escolhida, nada fica no temporario
    assert asked == [source, source]
    assert win.manager is None and win.stack.currentWidget() is win.empty_label
    assert target.is_file() and _converted_files(win) == []
    assert win.status_label.text() == f"SQLite saved: {target}"

    # Apagar, lembrado nesta sessao: a proxima vez nao pergunta
    win.open_database(source)
    qtbot.waitUntil(lambda: win.manager is not None and win._busy == 0, timeout=60000)
    monkeypatch.setattr(win, "ask_converted", lambda path: asked.append(path) or (mw.DELETE, True))
    assert win.release_database() and _converted_files(win) == []
    win.open_database(source)
    qtbot.waitUntil(lambda: win.manager is not None and win._busy == 0, timeout=60000)
    assert win.release_database() and _converted_files(win) == []
    assert len(asked) == 3 and win.converted_choice == mw.DELETE
    assert "SQLite converted from sample.mdb deleted" in win.log_view.toPlainText()


@needs_mdbtools
def test_quit_can_be_cancelled_and_cleans_the_session(qtbot, access_window: MainWindow, monkeypatch) -> None:
    win = access_window
    monkeypatch.setattr(win, "ask_converted", lambda path: (mw.CANCEL, False))
    win.close()
    assert win.isVisible() and win.manager is not None

    monkeypatch.setattr(win, "ask_converted", lambda path: (mw.DELETE, False))
    win.close()
    assert not win.isVisible() and not win.session.path.exists()  # nada orfao na pasta temporaria


@needs_mdbtools
def test_open_another_file_asks_first(qtbot, access_window: MainWindow, people_db: Path, monkeypatch) -> None:
    win = access_window
    monkeypatch.setattr(mw.QFileDialog, "getOpenFileName", lambda *a: (str(people_db), ""))
    monkeypatch.setattr(win, "ask_converted", lambda path: (mw.CANCEL, False))
    win.choose_database()
    assert win.current_db_path.name == "sample.mdb"  # Cancelar: nada muda

    monkeypatch.setattr(win, "ask_converted", lambda path: (mw.DELETE, False))
    win.choose_database()
    qtbot.waitUntil(lambda: win.current_db_path == people_db and win._busy == 0, timeout=30000)
    assert _converted_files(win) == []


def test_log_panel_keeps_the_messages_and_copies(qtbot, people_db: Path) -> None:
    win = MainWindow()
    qtbot.addWidget(win)
    win.show()
    win.open_database(people_db)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=30000)

    view_menu = next(a.menu() for a in win.menuBar().actions() if a.text() == "&View")
    assert win.log_action in view_menu.actions() and win.log_dock.isHidden()
    win.log_action.trigger()
    assert win.log_dock.isVisible()
    lines = win.log_view.toPlainText().splitlines()
    assert re.fullmatch(r"\d\d:\d\d:\d\d  Loading: people\.duckdb", lines[0])
    assert lines[1].endswith("Loaded: people.duckdb (2 tables) via DuckDB")
    assert win.log_view.isReadOnly()  # selecionavel; Ctrl+C do proprio campo

    win.log_copy_button.click()  # Copiar tudo
    assert QApplication.clipboard().text() == win.log_view.toPlainText()

    # barra de status: clique direito > Copiar (texto inteiro) e o mesmo Log
    menu = win.status_menu(win.status_label)
    assert [a.text() for a in menu.actions()] == ["&Copy", "&Log"]
    menu.actions()[0].trigger()
    assert QApplication.clipboard().text() == "Loaded: people.duckdb (2 tables) via DuckDB"


def test_log_panel_collapsed_shows_the_most_important_line(qtbot) -> None:
    win = MainWindow()
    qtbot.addWidget(win)
    win.show()
    # recolhido por padrao; Ctrl+L, Exibir > Log e as setas (barra de status e cabecalho do painel)
    assert win.log_dock.isHidden() and win.log_action.shortcut().toString() == "Ctrl+L"
    assert win.tables_action.shortcut().toString() == "Ctrl+T"
    assert win.log_toggle.arrowType() == Qt.ArrowType.UpArrow and win.log_unread.isHidden()
    # fonte monoespacada um passo menor que a base; minimo de 3 linhas
    assert win.log_view.font().family() == QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont).family()
    assert win.log_view.font().pointSizeF() == max(8.0, win.font().pointSizeF() - 1)
    assert win.log_view.minimumHeight() >= 3 * win.log_view.fontMetrics().lineSpacing()

    # erro > aviso > ultima acao: com o painel recolhido, o erro fica na barra (destacado) mesmo depois de outra acao
    win._set_message(win.info_label, "SQL error: boom", error=True)
    win._set_message(win.info_label, "Export cancelled: x.csv not written", warning=True)
    win._set_message(win.status_label, "Loaded: a.duckdb (1 tables) via DuckDB")
    assert win.status_label.text() == "SQL error: boom" and "color" in win.status_label.styleSheet()
    assert win.log_unread.text() == "(2)" and not win.log_unread.isHidden()

    # clique na mensagem reexibe o log e zera os nao lidos; a seta do cabecalho recolhe; estado lembrado
    qtbot.mouseClick(win.status_label, Qt.MouseButton.LeftButton)
    assert not win.log_dock.isHidden() and win.log_unread.isHidden() and QSettings().value("log_visible") in (True, "true")
    assert win.log_toggle.arrowType() == Qt.ArrowType.DownArrow
    assert "SQL error: boom" in win.log_view.toPlainText()
    assert win.log_dock.maximumHeight() <= max(round(win.height() * 0.25), win.log_view.minimumHeight() + 32)
    win.log_collapse.click()
    assert win.log_dock.isHidden() and QSettings().value("log_visible") in (False, "false")
    win.log_toggle.click()
    assert not win.log_dock.isHidden()
    again = MainWindow()  # proxima abertura: como ficou
    qtbot.addWidget(again)
    assert not again.log_dock.isHidden()


def test_language_is_saved_and_applies_on_next_start(qtbot) -> None:
    win = MainWindow()
    qtbot.addWidget(win)
    settings_menu = win.settings_menu.actions()[1].menu()
    assert [a.text() for a in settings_menu.actions()] == ["English", "Português (Brasil)", "Español"]
    assert win.language_actions["en"].isChecked()

    win.language_actions["pt_BR"].trigger()
    assert QSettings().value("language") == "pt_BR"
    assert win.status_label.text() == "O idioma muda ao reabrir o mdb2sql"  # aviso ja no idioma escolhido

    i18n.set_language(str(QSettings().value("language")))  # o que main() faz ao abrir
    again = MainWindow()
    qtbot.addWidget(again)
    assert [a.text() for a in again.menuBar().actions()] == [
        "&Arquivo", "&Editar", "E&xibir", "&Configurações", "Aj&uda"
    ]
    assert again.language_actions["pt_BR"].isChecked() and again.empty_label.text() == "Nenhum banco aberto"
    assert again.limit_combo.itemText(2) == "10.000"


def _placeholders(text: str) -> set[str]:
    return set(re.findall(r"{(\w+)}", text))


def test_catalogs_have_the_same_keys_and_placeholders() -> None:
    catalogs = {code: i18n.catalog(code) for code in i18n.LANGUAGES}
    keys = set(catalogs["en"])
    for code, catalog in catalogs.items():
        assert set(catalog) == keys, code
        for key, text in catalog.items():
            assert _placeholders(text) == _placeholders(catalogs["en"][key]), (code, key)
    # toda chave usada no codigo existe (as montadas com f-string conferidas pelos prefixos)
    used = set()
    for path in (p for p in SRC.rglob("*.py") if p.name != "i18n.py"):
        used |= set(re.findall(r'tr\("([\w.]+)"', path.read_text(encoding="utf-8")))
    assert used - keys == set()
    for prefix, names in (("theme.", mw.THEMES), ("language.", i18n.LANGUAGES), ("filter.", ("sqlite", "duckdb",
                                                                                             "xlsx", "csv")),
                          ("export.done_", ("tables", "rows"))):
        assert {prefix + name for name in names} <= keys
    assert json.loads((SRC / "resources" / "i18n" / "en.json").read_text(encoding="utf-8")) == catalogs["en"]


# textos que nao sao traduzidos: nomes de produto, codigo SQL e numeros
# (Sobre: versoes, autor, links; botoes internos do Qt, traduzidos pelo qtbase_<idioma>.qm)
NOT_TEXT = re.compile(r"(SQL|SELECT \* FROM \.\.\.|[\d,.]+|mdb2sql [\d.]+( - Python)?|GitHub|GitLab|Stack|"
                      r"Python .*|SQLite [\d.]+, DuckDB .*|dev|Mauricio Menon|(GitHub |GitLab )?https://\S+|"
                      r"<a href=.*|Scroll Left|Scroll Right|Float|Close)")


def test_no_ui_text_outside_the_catalogs(qtbot, people_db: Path, monkeypatch) -> None:
    # cada texto do catalogo ingles marcado com [[...]]: um texto de tela sem a marca veio de fora do catalogo
    marked = {key: f"[[{text}]]" for key, text in i18n.catalog("en").items()}
    marked["number.thousands"] = ","
    monkeypatch.setattr(i18n, "_catalog", marked)
    win = MainWindow()
    qtbot.addWidget(win)
    win.show()
    win.open_database(people_db)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=30000)
    win.add_filter("name", "Ana")
    qtbot.waitUntil(lambda: win._busy == 0, timeout=30000)
    win.log_dock.show()
    win.show_about()
    win.choose_columns()

    texts: list[tuple[str, str]] = []
    for widget in QApplication.topLevelWidgets():
        if not widget.isVisible():
            continue
        texts.append(("title", widget.windowTitle().removeprefix("people.duckdb - ")))
        for child in [widget, *widget.findChildren(QLabel), *widget.findChildren(QAbstractButton),
                      *widget.findChildren(QLineEdit), *widget.findChildren(QDockWidget)]:
            texts.append(("tip", child.toolTip()))
            texts.append(("name", child.accessibleName()))
            if isinstance(child, (QLabel, QAbstractButton)):
                texts.append(("text", child.text()))
            if isinstance(child, QLineEdit):
                texts.append(("placeholder", child.placeholderText()))
            if isinstance(child, QDockWidget):
                texts.append(("dock", child.windowTitle()))
        for tabs in widget.findChildren(QTabWidget):
            texts += [("tab", tabs.tabText(i)) for i in range(tabs.count())]
        for action in widget.findChildren(QAction):
            texts += [("action", action.text()), ("action tip", action.toolTip())]
        for menu in widget.findChildren(QMenu):
            texts.append(("menu", menu.title()))
    texts += [("status menu", a.text()) for a in win.status_menu(win.info_label).actions()]
    texts += [("header menu", a.text()) for a in win.header_menu(0).actions()]

    outside = []
    for kind, text in texts:
        bare = text.replace("&", "")
        while (inner := re.sub(r"\[\[[^\[\]]*\]\]", "", bare)) != bare:  # marcas aninhadas: "[[[[Build]]:]]"
            bare = inner
        # o que sobra fora das marcas so pode ser dado (nome de tabela/coluna/arquivo, valor) ou nome de produto
        leftover = re.sub(r"people\.duckdb|people|empty_table|name = 'Ana'|×|via DuckDB|[\s:;()\-]", "", bare)
        if leftover and not NOT_TEXT.fullmatch(text.replace("&", "").strip()):
            outside.append((kind, text))
    assert outside == [], "\n".join(map(repr, outside))
