# 1.3.0: Access convertido para SQLite (salvar/apagar ao fechar), painel Log, idiomas e textos so nos catalogos
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
from PyQt6.QtCore import QSettings, Qt, QTimer
from PyQt6.QtTest import QTest
from PyQt6.QtGui import QAction, QFontDatabase
from PyQt6.QtWidgets import QAbstractButton, QApplication, QDockWidget, QLabel, QLineEdit, QMenu, QTabWidget

from backend import access
from shared import i18n
from ui import main_window as mw
from ui.main_window import MainWindow

SAMPLE = Path(__file__).with_name("data") / "sample.mdb"
SRC = Path(__file__).resolve().parents[1] / "src"
needs_mdbtools = pytest.mark.skipif(access.mdbtools_dir() is None, reason="sem .tools/mdbtools")
REAL_ASK = MainWindow.ask_exit  # a pergunta de verdade (o conftest troca por "Sair" em cada teste)


@pytest.mark.parametrize(("key", "expected"), [("esc", mw.BACK), ("x", mw.BACK), ("enter", mw.SAVE)])
def test_exit_prompt_has_save_on_the_left_and_esc_or_x_go_back(qtbot, monkeypatch, key, expected) -> None:
    # item 27: "Salvar" a esquerda; "Voltar" e "Sair" a direita, lado a lado; sem "Lembrar nesta sessao"
    monkeypatch.setattr(MainWindow, "ask_exit", REAL_ASK)
    win = MainWindow()
    qtbot.addWidget(win)
    seen = []

    def answer() -> None:
        box = QApplication.activeModalWidget()
        save, back, leave = (box.buttons[k] for k in (mw.SAVE, mw.BACK, mw.EXIT))
        seen.append((box.windowTitle(), box.text.text(), [b.text() for b in (save, back, leave)], save.isDefault(),
                     len(box.findChildren(QAbstractButton))))
        # a folga fica entre Salvar e os dois da direita
        assert back.x() - save.geometry().right() > leave.x() - back.geometry().right() >= 0
        if key == "esc":
            QTest.keyClick(box, Qt.Key.Key_Escape)
        elif key == "x":
            box.close()  # o X da caixa
        else:
            QTest.keyClick(box, Qt.Key.Key_Return)

    QTimer.singleShot(0, answer)
    assert win.ask_exit(Path("db.accdb")) == expected
    assert seen == [("Converted SQLite file", "The database converted from db.accdb was not saved. Save before exiting?",
                     ["Save", "Back", "Exit"], True, 3)]


def test_exit_during_an_export_asks_first_and_exit_cancels_it(qtbot, people_db: Path, monkeypatch) -> None:
    # antes de tudo: "Voltar" mantem a exportacao; "Sair" cancela (nada gravado pela metade) e fecha
    from backend.export import Cancelled

    win = MainWindow()
    qtbot.addWidget(win)
    win.show()
    win.open_database(people_db)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=30000)
    out = people_db.parent / "slow.csv"

    def slow(_report, cancel):
        cancel.wait(60)
        raise Cancelled()

    win._start_export(out, slow, "rows")
    box = win.export_running_box(out.name)
    assert (box.windowTitle(), box.text.text()) == ("Export in progress", "Exiting cancels the export of slow.csv.")
    assert [b.text() for b in box.buttons.values()] == ["Back", "Exit"] and box.buttons[mw.BACK].isDefault()
    # exportando: a janela nao aceita mais nada, mas sair continua valendo (Ctrl+Q tambem com o menu desabilitado)
    assert not win.menuBar().isEnabled() and not win.centralWidget().isEnabled() and win.isEnabled()
    assert win.quit_action in win.actions()
    answers = [mw.BACK, mw.EXIT]
    monkeypatch.setattr(win, "ask_export_running", lambda name: answers.pop(0))
    win.close()
    assert win.isVisible() and win._job is not None and answers == [mw.EXIT]
    win.close()
    assert not win.isVisible() and answers == [] and not out.exists()


def test_a_finished_job_gives_the_window_back(qtbot, people_db: Path) -> None:
    win = MainWindow()
    qtbot.addWidget(win)
    win.show()
    win.open_database(people_db)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=30000)
    done = []
    win._start_export(people_db.parent / "x.csv", lambda _report, _cancel: 3, "rows", lambda: done.append(1))
    qtbot.waitUntil(lambda: win._job is None, timeout=30000)
    assert done == [1] and win.menuBar().isEnabled() and win.centralWidget().isEnabled()
    assert win.status_label.text().startswith("Exported 3 rows to ")


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
    assert win.status_label.text() == "Loaded: sample.mdb (2 tables)"
    assert win.reader_label.text() == "Opened via mdbtools, converted to SQLite"
    assert win.table_names() == ["empty table", "points"]
    assert [p.name for p in _converted_files(win)] == ["sample.sqlite"]


@needs_mdbtools
def test_without_a_temp_folder_the_conversion_goes_next_to_the_file_and_leaves_nothing(qtbot, tmp_path: Path,
                                                                                       monkeypatch) -> None:
    # item 29: pasta temporaria do usuario, senao a do sistema e so por ultimo a pasta do arquivo aberto
    from backend import temp_store

    monkeypatch.setenv("MDB2SQL_ACCESS_READER", "mdbtools")
    blocked = tmp_path / "no temp"
    blocked.write_text("x", encoding="utf-8")
    monkeypatch.setattr(temp_store, "temp_folders", lambda: [blocked])
    folder = tmp_path / "source"
    folder.mkdir()
    copy = folder / "sample.mdb"
    shutil.copy2(SAMPLE, copy)
    # sobra de uma sessao que caiu nessa pasta: sai ao abrir o arquivo, com a linha do Log
    stale = folder / temp_store.NAME / "dead"
    stale.mkdir(parents=True)
    (stale / "old.sqlite").write_bytes(b"x")
    crashed = ("import os, sys; from PyQt6.QtCore import QLockFile; lock = QLockFile(sys.argv[1]);"
               "assert lock.tryLock(0); os._exit(0)")  # trava gravada, processo morto sem soltar
    subprocess.run([sys.executable, "-c", crashed, str(stale.with_suffix(".lock"))], check=True)
    win = MainWindow()
    qtbot.addWidget(win)
    assert win.session is None
    win.open_database(copy)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=60000)

    assert win.session.path.parent == folder / temp_store.NAME and not stale.exists()
    assert [p.name for p in _converted_files(win)] == ["sample.sqlite"]
    assert "Removed 1 converted file left by a previous session" in win.log_view.toPlainText()
    win.close()
    assert [p.name for p in folder.iterdir()] == ["sample.mdb"]  # nada fica na pasta do original


def test_settings_file_from_the_environment_replaces_the_registry(qtbot, tmp_path: Path, monkeypatch) -> None:
    # MDB2SQL_SETTINGS=<arquivo.ini>: capturas e testes do exe nunca tocam nas configuracoes do usuario
    ini = tmp_path / "isolated.ini"
    monkeypatch.setenv("MDB2SQL_SETTINGS", str(ini))
    win = MainWindow()
    qtbot.addWidget(win)
    win.set_default_scope("all")
    win.settings.sync()
    assert "search_scope=all" in ini.read_text(encoding="utf-8")
    assert QSettings().value("search_scope") is None and mw.app_settings().value("search_scope") == "all"


def _reopen(qtbot, win: MainWindow, source: Path) -> None:
    win.open_database(source)
    qtbot.waitUntil(lambda: win.manager is not None and win.loaded_table is not None and win._busy == 0, timeout=120000)


def _save(qtbot, win: MainWindow, monkeypatch, target: Path, picked: str = "", save_as: bool = False) -> list:
    """Arquivo > Salvar com a caixa respondendo `target` (e o tipo `picked`); devolve o que a caixa recebeu."""
    asked = []
    monkeypatch.setattr(mw.QFileDialog, "getSaveFileName", lambda *a: asked.append(a[1:]) or (str(target), picked))
    (win.save_as_action if save_as else win.save_action).trigger()
    qtbot.waitUntil(lambda: win._job is None and win._busy == 0, timeout=120000)
    return asked


@needs_mdbtools
def test_close_open_another_and_reopen_do_not_ask_and_log_the_discarded_conversion(qtbot, access_window: MainWindow,
                                                                                    people_db: Path, monkeypatch):
    # item 27: so sair do programa pergunta; o convertido nao salvo e apagado e o Log diz qual
    win = access_window
    source = win.current_db_path
    monkeypatch.setattr(win, "ask_exit", lambda path: pytest.fail("asked"))
    discarded = "SQLite converted from sample.mdb discarded"

    win.close_db_action.trigger()  # Fechar
    assert win.manager is None and win.stack.currentWidget() is win.empty_label and _converted_files(win) == []
    assert win.log_view.toPlainText().count(discarded) == 1

    _reopen(qtbot, win, source)
    win.reload_action.trigger()  # Reabrir (F5): a conversao nova troca a anterior
    qtbot.waitUntil(lambda: win.log_view.toPlainText().count(discarded) == 2 and win._busy == 0, timeout=120000)
    assert win.manager is not None and len(_converted_files(win)) == 1

    monkeypatch.setattr(mw.QFileDialog, "getOpenFileName", lambda *a: (str(people_db), ""))
    win.choose_database()  # abrir outro
    qtbot.waitUntil(lambda: win.current_db_path == people_db and win._busy == 0, timeout=30000)
    assert win.log_view.toPlainText().count(discarded) == 3 and _converted_files(win) == []


@needs_mdbtools
def test_exit_asks_only_for_an_unsaved_conversion_and_save_closes_after_writing(qtbot, access_window: MainWindow,
                                                                                tmp_path: Path, monkeypatch) -> None:
    win = access_window
    source = win.current_db_path
    target = tmp_path / "kept" / "sample.sqlite"
    target.parent.mkdir()
    answers = [mw.BACK, mw.SAVE, mw.BACK, mw.SAVE]
    asked = []
    monkeypatch.setattr(win, "ask_exit", lambda path: asked.append(path) or answers.pop(0))
    dialog = [("", ""), (str(target), "")]  # a caixa de salvar: cancelada, depois o arquivo
    monkeypatch.setattr(mw.QFileDialog, "getSaveFileName", lambda *a: dialog.pop(0))

    win.close()  # Voltar: nada muda
    assert win.isVisible() and win.manager is not None and len(_converted_files(win)) == 1
    win.close()  # Salvar com a caixa cancelada: a pergunta volta (Voltar)
    assert win.isVisible() and answers == [mw.SAVE] and asked == [source] * 3
    win.close()  # Salvar: grava e so entao fecha
    qtbot.waitUntil(lambda: not win.isVisible(), timeout=120000)
    assert asked == [source] * 4 and target.is_file() and not win.session.path.exists()
    assert win.saved_conversion(source) == target  # o mesmo Access, sem mudanca, abre o salvo


@needs_mdbtools
def test_exit_of_an_unsaved_conversion_deletes_the_temporary_file(qtbot, access_window: MainWindow, monkeypatch):
    win = access_window
    asked = []
    monkeypatch.setattr(win, "ask_exit", lambda path: asked.append(path) or mw.EXIT)
    win.close()
    assert not win.isVisible() and len(asked) == 1 and not win.session.path.exists()  # nada orfao no temporario


@needs_mdbtools
def test_save_offers_sqlite_duckdb_and_excel_and_remembers_the_access_conversion(qtbot, access_window: MainWindow,
                                                                                 tmp_path: Path, monkeypatch) -> None:
    # item 28: a caixa abre na pasta do original com o nome dele e o tipo do aberto (Access -> SQLite) ja marcado
    import os

    win = access_window
    source = win.current_db_path
    monkeypatch.setattr(win, "ask_exit", lambda path: pytest.fail("asked"))
    types = "SQLite database (*.sqlite);;DuckDB database (*.duckdb);;Excel workbook (*.xlsx)"
    title = "Save as SQLite, DuckDB or Excel (.mdb and .accdb files cannot be written)"

    # Excel: a pergunta ao sair some, mas a conversao nao fica lembrada
    book = tmp_path / "sample.xlsx"
    asked = _save(qtbot, win, monkeypatch, book)
    assert asked == [(title, str(source.with_suffix(".sqlite")), types, "SQLite database (*.sqlite)")]
    assert book.is_file() and win.converted_saved and win.saved_conversion(source) is None
    assert win.status_label.text() == f"Exported 2 tables to {book}"

    # DuckDB escolhido no tipo, com o nome sugerido como veio: grava .duckdb; fica lembrado
    _reopen(qtbot, win, source)
    assert not win.converted_saved
    duck = tmp_path / "sample.duckdb"
    _save(qtbot, win, monkeypatch, source.with_suffix(".sqlite"), "DuckDB database (*.duckdb)")
    assert duck.is_file() and not source.with_suffix(".sqlite").exists() and win.saved_conversion(source) == duck
    # o temporario nunca e o destino: recusado com a mensagem de exportar sobre o aberto
    _save(qtbot, win, monkeypatch, win.manager.converted)
    assert win.status_label.text() == "Export failed: The output file is the open database; choose another name"

    # o mesmo Access, sem mudanca, abre o DuckDB salvo (sem converter); Salvar nunca sugere o arquivo aberto
    _reopen(qtbot, win, source)
    assert win.manager.converted is None and win.manager.reader == "DuckDB" and _converted_files(win) == []
    assert win.windowTitle().startswith("sample.mdb - ")
    # 13 b): o formato real do arquivo salvo, lido do arquivo (aqui DuckDB; abaixo SQLite)
    assert f"sample.mdb: opened the DuckDB saved from it ({duck})" in win.log_view.toPlainText()
    assert "opened the SQLite saved" not in win.log_view.toPlainText()
    lite = tmp_path / "other" / "sample.sqlite"
    lite.parent.mkdir()
    assert _save(qtbot, win, monkeypatch, lite)[0][1:] == (str(source.with_suffix(".sqlite")), types,
                                                         "SQLite database (*.sqlite)")
    assert win.saved_conversion(source) == lite
    # Salvar como...: comeca na ultima pasta em que o usuario salvou
    assert _save(qtbot, win, monkeypatch, lite, save_as=True)[0][1] == str(lite.parent / "sample.sqlite")
    _reopen(qtbot, win, source)
    assert f"sample.mdb: opened the SQLite saved from it ({lite})" in win.log_view.toPlainText()
    again = MainWindow()  # proxima execucao: lembrado nas configuracoes
    qtbot.addWidget(again)
    assert again.saved_conversion(source) == lite
    win.close()
    assert not win.isVisible()  # nada a salvar: nao pergunta

    # o arquivo salvo mudou: converte de novo; o Access mudou: tambem
    os.utime(lite, ns=(lite.stat().st_atime_ns, lite.stat().st_mtime_ns + 10**9))
    assert again.saved_conversion(source) is None
    os.utime(source, ns=(source.stat().st_atime_ns, source.stat().st_mtime_ns + 10**9))
    assert again.saved_conversion(source) is None


@needs_mdbtools
def test_saved_key_is_the_one_read_when_the_access_file_opened(qtbot, access_window: MainWindow, tmp_path: Path,
                                                               monkeypatch) -> None:
    # o Access mudou enquanto estava aberto: o SQLite salvo tem o conteudo antigo e nao e reaproveitado
    import os

    win = access_window
    source = win.current_db_path
    target = tmp_path / "kept.sqlite"
    os.utime(source, ns=(source.stat().st_atime_ns, source.stat().st_mtime_ns + 10**9))
    _save(qtbot, win, monkeypatch, target)
    assert target.is_file() and win.saved_conversion(source) is None


@needs_mdbtools
def test_close_during_a_reopen_keeps_no_database(qtbot, access_window: MainWindow) -> None:
    # F5 ainda convertendo e Fechar: o banco aberto fecha e a conversao em andamento e descartada quando termina
    win = access_window
    win.load_database()
    win.release_database()
    qtbot.waitUntil(lambda: win._busy == 0, timeout=120000)
    assert win.manager is None and _converted_files(win) == [] and win.loaded_schema == []


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
    assert re.fullmatch(r"\d\d:\d\d:\d\d  Opening: people\.duckdb", lines[0])
    assert lines[1].endswith("Loaded: people.duckdb (2 tables)")
    assert win.log_view.isReadOnly()  # selecionavel; Ctrl+C do proprio campo

    win.log_copy_button.click()  # Copiar tudo
    assert QApplication.clipboard().text() == win.log_view.toPlainText()

    # barra de status: clique direito > Copiar (texto inteiro) e o mesmo Log
    menu = win.status_menu(win.status_label)
    assert [a.text() for a in menu.actions()] == ["&Copy", "&Log"]
    menu.actions()[0].trigger()
    assert QApplication.clipboard().text() == "Loaded: people.duckdb (2 tables)"


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
    win._set_message(win.status_label, "SQL error: boom", error=True)
    win._set_message(win.status_label, "Export cancelled: x.csv not written", warning=True)
    for n in range(40):  # historico maior que o painel: ao abrir, o fim (a linha mais nova) fica visivel
        win.log(f"line {n}")
    win._set_message(win.status_label, "Loaded: a.duckdb (1 table)")
    assert win.status_label.text() == "SQL error: boom" and "color" in win.status_label.styleSheet()
    assert win.log_unread.text() == "(2)" and not win.log_unread.isHidden()
    # o contador fica a direita, a mensagem a esquerda (barra de baixo igual ao Go)
    assert win.log_unread.x() > win.status_label.x()

    # clique na mensagem reexibe o log e zera os nao lidos; a seta do cabecalho recolhe; estado lembrado
    qtbot.mouseClick(win.status_label, Qt.MouseButton.LeftButton)
    assert not win.log_dock.isHidden() and win.log_unread.isHidden() and QSettings().value("log_visible") in (True, "true")
    assert win.log_toggle.arrowType() == Qt.ArrowType.DownArrow
    assert "SQL error: boom" in win.log_view.toPlainText()
    bar = win.log_view.verticalScrollBar()
    qtbot.waitUntil(lambda: bar.maximum() > 0 and bar.value() == bar.maximum(), timeout=5000)
    assert win.log_dock.maximumHeight() <= max(round(win.height() * 0.25), win.log_view.minimumHeight() + 32)
    win.log_collapse.click()
    assert win.log_dock.isHidden() and QSettings().value("log_visible") in (False, "false")
    win.log_toggle.click()
    assert not win.log_dock.isHidden()
    again = MainWindow()  # proxima abertura: como ficou
    qtbot.addWidget(again)
    assert not again.log_dock.isHidden()


def test_language_applies_at_once_and_is_saved(qtbot, people_db: Path) -> None:
    # igual nas 4 versoes: Configuracoes > Idioma troca os textos na hora (antes so ao reabrir), e fica gravado
    win = MainWindow()
    qtbot.addWidget(win)
    win.show()
    win.open_database(people_db)
    qtbot.waitUntil(lambda: win.loaded_table is not None and win._busy == 0, timeout=30000)
    settings_menu = win.settings_menu.actions()[1].menu()
    assert [a.text() for a in settings_menu.actions()] == ["English", "Português (Brasil)", "Español"]
    assert win.language_actions["en"].isChecked()

    try:
        win.language_actions["pt_BR"].trigger()
        assert QSettings().value("language") == "pt_BR"
        assert [a.text() for a in win.menuBar().actions()] == ["&Arquivo", "&Editar", "E&xibir", "&Configurações",
                                                               "Aj&uda"]
        assert win.open_action.text() == "&Abrir..." and win.browse_button.text() == "Procurar..."
        assert win.tabs.tabText(0) == "Dados" and win.tables_dock.windowTitle() == "Tabelas"
        assert win.table_list.headerItem().text(1) == "Linhas" and win.limit_label.text() == "&Linhas"
        assert win.search_edit.placeholderText() == "Pesquisar na tabela inteira"
        assert win.info_label.text() == "empty_table: 0 linhas"  # a barra da tabela tambem
        assert win.reader_label.text() == "Aberto via DuckDB"
        assert [win.schema_model.headerData(c, Qt.Orientation.Horizontal) for c in range(3)] == [
            "Coluna", "Tipo", "Aceita nulo"]
        assert [a.text() for a in win.header_menu(0).actions()][:2] == ["Ajustar coluna", "Ajustar todas as colunas"]
        assert [win.limit_combo.itemText(i) for i in range(3)] == ["100", "500", "1000"]  # o mesmo texto nas 4

        i18n.set_language(str(QSettings().value("language")))  # o que main() faz ao abrir: lembrado
        again = MainWindow()
        qtbot.addWidget(again)
        assert again.language_actions["pt_BR"].isChecked() and again.empty_label.text() == "Nenhum banco aberto"
        win.language_actions["es"].trigger()
        assert win.menuBar().actions()[0].text() == "&Archivo" and win.tabs.tabText(0) == "Datos"
        # o separador de milhar da contagem da lista e as larguras do Schema tambem acompanham
        win._fill_tables(["big", "empty_table", "people"], {"big": 1234, "empty_table": 0, "people": 3})
        win.language_actions["en"].trigger()
        assert win.table_list.topLevelItem(0).text(1) == "1,234"
        win.language_actions["pt_BR"].trigger()
        assert win.table_list.topLevelItem(0).text(1) == "1.234"
        header = win.schema_table.horizontalHeader()
        assert win.schema_table.columnWidth(2) >= header.fontMetrics().horizontalAdvance("Aceita nulo")
        win._fill_tables([], {})  # arquivo sem tabelas: "Nenhuma tabela" tambem troca
        win.language_actions["es"].trigger()
        assert win.info_label.text() == "Ninguna tabla"
    finally:
        win.set_language("en")  # os textos do Qt (qtbase) voltam ao ingles para os outros testes
    assert win.menuBar().actions()[0].text() == "&File" and win.info_label.text() == "No tables"


# nomes proprios e siglas que podem vir com maiuscula no meio da frase
PROPER = {"SQLite", "DuckDB", "Excel", "CSV", "UTF-8", "Access", "ODBC", "SQL", "NULL", "X11", "Wayland", "DISPLAY",
          "WAYLAND_DISPLAY", "GPL", "Ctrl+O", "Ctrl+F", "Ctrl+L", "Ctrl+Enter", "Enter", "F5", "Windows", "Brasil",
          "MDB2SQL_ACCESS_READER", "Log", "X", "Microsoft",
          # nome da aba Pesquisa Avancada (13 d), como o dono escreveu
          "Search", "Pesquisa", "Avançada", "Búsqueda", "Avanzada",
          # nome da aba do relatorio (13 i), como o dono escreveu
          "Result", "Filtro"}


def test_texts_have_no_title_case() -> None:
    # igual nas 4 versoes (redacao do Go): so a primeira palavra de cada frase com maiuscula ("Abrir banco", nao
    # "Abrir Banco")
    title_case = []
    for code in i18n.LANGUAGES:
        for key, text in i18n.catalog(code).items():
            for sentence in re.split(r"(?<=[.?!]) ", text.replace("&", "")):
                words = [w.rstrip(".") for w in re.findall(r"[\w+./-]+", sentence) if w.rstrip(".")]
                capitals = [w for w in words[1:] if w[0].isupper() and w not in PROPER and not w.isupper()]
                if capitals and not key.startswith("language."):
                    title_case.append((code, key, text))
    assert title_case == []


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
    used, plural = set(), set()
    for path in (p for p in SRC.rglob("*.py") if p.name != "i18n.py"):
        used |= set(re.findall(r'tr\("([\w.]+)"', path.read_text(encoding="utf-8")))
        plural |= set(re.findall(r'counted\(\s*"([\w.]+)"', path.read_text(encoding="utf-8")))
    assert used - keys == set()
    # plural certo: "1 tabela" / "2 tabelas" (counted escolhe <chave>_one quando o numero e 1)
    assert plural and {f"{key}_one" for key in plural} | plural <= keys | {"status.sql_first_one"}
    for prefix, names in (("theme.", mw.THEMES), ("language.", i18n.LANGUAGES), ("filter.", ("sqlite", "duckdb",
                                                                                             "xlsx", "csv")),
                          ("export.done_", ("tables", "rows"))):
        assert {prefix + name for name in names} <= keys
    assert set(mw.SCOPES.values()) <= keys
    assert json.loads((SRC / "resources" / "i18n" / "en.json").read_text(encoding="utf-8")) == catalogs["en"]


# textos que nao sao traduzidos: nomes de produto, codigo SQL e numeros
# (Sobre: versoes, autor, links; botoes internos do Qt, traduzidos pelo qtbase_<idioma>.qm)
NOT_TEXT = re.compile(r"(SQL|SELECT \* FROM \.\.\.|[\d,.]+|mdb2sql [\d.]+( - Python)?|GitHub|GitLab|"
                      r"Python .*|Qt [\d.]+|SQLite [\d.]+, DuckDB .*|dev|Mauricio Menon|(GitHub |GitLab )?https://\S+|"
                      r"<a href=.*|Scroll Left|Scroll Right|Float|Close|◀|▶)")  # setas das paginas (13 h): sinais, nao texto


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
    win.add_filter("label", "Ana")  # coluna da tabela aberta (empty_table): o filtro recarrega na hora, sem erro
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
        # (o menu do cabecalho lista as colunas da tabela aberta: code, label)
        leftover = re.sub(r"people\.duckdb|people|empty_table|label = 'Ana'|code|label|×|[\s:;()\-]", "", bare)
        if leftover and not NOT_TEXT.fullmatch(text.replace("&", "").strip()):
            outside.append((kind, text))
    assert outside == [], "\n".join(map(repr, outside))
