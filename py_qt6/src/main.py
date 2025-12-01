#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# Entry point da aplicacao PyQt6 - cria janela e inicia event loop
# !T: sys.argv allows CLI args, QApplication manages event loop and system resources

import sys
from PyQt6.QtWidgets import QApplication
from ui.main_window import MainWindow

# !T: sys.argv permite passar argumentos via linha de comando
# !T: QApplication gerencia event loop, temas, recursos do sistema


def main():
    # Cria aplicacao Qt - cada app PyQt6 precisa exatamente 1 QApplication
    app = QApplication(sys.argv)

    # Define metadados da aplicacao
    app.setApplicationName("MDB2SQL")
    app.setOrganizationName("MDB2SQL")
    app.setOrganizationDomain("mdb2sql.local")

    # Cria e mostra janela principal
    window = MainWindow()
    window.show()

    # Inicia event loop - app fica rodando ate fechar janela
    # !T: sys.exit() ensures proper cleanup on shutdown
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
