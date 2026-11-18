#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# Entry point da aplicacao PyQt6 - cria janela e inicia event loop
# !T: sys.argv allows CLI args, QApplication manages event loop and system resources

import os
import sys
from pathlib import Path

from PyQt6.QtCore import QCoreApplication, QLibraryInfo, QLocale, QSettings, Qt, QTranslator
from PyQt6.QtGui import QIcon
from PyQt6.QtWidgets import QApplication, QMessageBox

from backend.database_tasks import database_path_from_env
from shared import i18n
from shared.bundle import resource
from shared.display import HELP, linux_choice
from shared.i18n import tr
from ui.main_window import MainWindow, apply_theme

# !T: sys.argv permite passar argumentos via linha de comando
# !T: QApplication gerencia event loop, temas, recursos do sistema


def show_display_warning(window: MainWindow, text: str) -> QMessageBox:
    box = QMessageBox(QMessageBox.Icon.Warning, tr("display.title"), text, QMessageBox.StandardButton.NoButton, window)
    box.addButton(tr("button.ok"), QMessageBox.ButtonRole.AcceptRole)
    box.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)  # texto copiavel (comando, link)
    box.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
    window.log(text)
    box.open()
    return box


def main():
    # Define metadados da aplicacao (antes do QApplication: o idioma gravado decide o texto do aviso de tela)
    QCoreApplication.setApplicationName("MDB2SQL")
    QCoreApplication.setOrganizationName("MDB2SQL")
    QCoreApplication.setOrganizationDomain("mdb2sql.local")
    # Configuracoes > Idioma (padrao ingles)
    language = i18n.set_language(str(QSettings().value("language", i18n.DEFAULT)))

    # Linux: X11 primeiro, Wayland so como reserva (com aviso); sem nenhum dos dois, erro no stderr
    display_warning, ours = None, False
    if sys.platform.startswith("linux"):
        platform, display_warning = linux_choice(os.environ)
        if platform == "":
            print(display_warning, file=sys.stderr)
            sys.exit(1)
        if platform:
            os.environ["QT_QPA_PLATFORM"], ours = platform, True

    # Cria aplicacao Qt - cada app PyQt6 precisa exatamente 1 QApplication
    app = QApplication(sys.argv)
    # icone da barra de titulo e da barra de tarefas: .ico com varios tamanhos + PNG 1024 para telas de DPI alto
    icon = QIcon(str(resource("mdb2sql.ico")))
    icon.addFile(str(resource("mdb2sql.png")))
    app.setWindowIcon(icon)
    # Tema claro/escuro segue o sistema pelo estilo nativo (windows11, macOS, Fusion)
    # !T: The Windows 10 style ("windowsvista") has no dark mode; Fusion follows the system scheme
    if app.style().objectName() == "windowsvista":
        app.setStyle("Fusion")
    # Configuracoes > Tema gravado na execucao anterior (sistema, claro ou escuro)
    apply_theme(str(QSettings().value("theme", "system")))
    # os textos do proprio Qt (menu de contexto dos campos) no idioma escolhido
    qt_texts = QTranslator(app)
    if qt_texts.load(QLocale(language), "qtbase", "_", QLibraryInfo.path(QLibraryInfo.LibraryPath.TranslationsPath)):
        app.installTranslator(qt_texts)

    # Cria e mostra janela principal
    window = MainWindow()
    window.show()
    if ours and app.platformName() != "xcb":
        # o Qt caiu no Wayland (reserva): aviso a cada abertura enquanto o X11 nao servir; texto copiavel e no Log
        show_display_warning(window, display_warning or tr("display.body_other", missing="xcb", link=HELP))

    # Abre o banco passado na linha de comando; sem argumento usa MDB2SQL_DB_PATH ou o default
    # !T: app.arguments() has the Qt-specific options already removed
    arguments = app.arguments()[1:]
    if arguments:
        window.open_database(Path(arguments[0]))
    elif database_path_from_env().exists():
        window.load_database()

    # Inicia event loop - app fica rodando ate fechar janela
    # !T: sys.exit() ensures proper cleanup on shutdown
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
