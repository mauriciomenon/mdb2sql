#!/usr/bin/env python3
# -*- coding: utf-8 -*-

# NIVEL BASICO: Entry point da aplicacao PyQt6
# Este arquivo cria a janela principal e inicia o event loop

import sys
from PyQt6.QtWidgets import QApplication
from ui.main_window import MainWindow

# NIVEL TECNICO: sys.argv permite passar argumentos via linha de comando
# QApplication gerencia event loop, temas, recursos do sistema


def main():
    # NIVEL BASICO: Cria aplicacao Qt
    # Cada app PyQt6 precisa exatamente 1 QApplication
    app = QApplication(sys.argv)

    # NIVEL BASICO: Define metadados da aplicacao
    app.setApplicationName("MDB2SQL")
    app.setOrganizationName("MDB2SQL")
    app.setOrganizationDomain("mdb2sql.local")

    # NIVEL BASICO: Cria e mostra janela principal
    window = MainWindow()
    window.show()

    # NIVEL BASICO: Inicia event loop (app fica rodando ate fechar janela)
    # sys.exit() garante cleanup correto ao encerrar
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
