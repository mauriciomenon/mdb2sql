#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# Entry point da aplicacao PyQt6 - cria janela e inicia event loop
# !T: sys.argv allows CLI args, QApplication manages event loop and system resources

import sys
from pathlib import Path

from PyQt6.QtCore import QSettings
from PyQt6.QtWidgets import QApplication

from backend.database_tasks import database_path_from_env
from ui.main_window import MainWindow, apply_theme

# !T: sys.argv permite passar argumentos via linha de comando
# !T: QApplication gerencia event loop, temas, recursos do sistema


def main():
    # Cria aplicacao Qt - cada app PyQt6 precisa exatamente 1 QApplication
    app = QApplication(sys.argv)

    # Define metadados da aplicacao
    app.setApplicationName("MDB2SQL")
    app.setOrganizationName("MDB2SQL")
    app.setOrganizationDomain("mdb2sql.local")
    # Tema claro/escuro segue o sistema pelo estilo nativo (windows11, macOS, Fusion)
    # !T: The Windows 10 style ("windowsvista") has no dark mode; Fusion follows the system scheme
    if app.style().objectName() == "windowsvista":
        app.setStyle("Fusion")
    # Configuracoes > Tema gravado na execucao anterior (sistema, claro ou escuro)
    apply_theme(str(QSettings().value("theme", "system")))

    # Cria e mostra janela principal
    window = MainWindow()
    window.show()

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
