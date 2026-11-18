import os
from pathlib import Path

import duckdb
import pytest
from PyQt6.QtCore import QSettings

from backend import temp_store
from shared import i18n

# !T: Qt tests need no display (CI); set before any QApplication exists
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")


@pytest.fixture(autouse=True)
def isolated_settings(tmp_path_factory, monkeypatch):
    # QSettings em arquivo .ini temporario: os testes nao tocam no registro do usuario
    QSettings.setDefaultFormat(QSettings.Format.IniFormat)
    QSettings.setPath(QSettings.Format.IniFormat, QSettings.Scope.UserScope, str(tmp_path_factory.mktemp("settings")))
    monkeypatch.delenv("MDB2SQL_ACCESS_READER", raising=False)
    # pasta temporaria das sessoes (SQLite convertidos) dentro do tmp do teste; textos em ingles (padrao)
    monkeypatch.setattr(temp_store, "BASE", tmp_path_factory.mktemp("sessions"))
    i18n.set_language("en")
    # a pergunta do SQLite convertido e modal (exec): nos testes responde "Apagar", salvo quando o teste troca
    from ui.main_window import DELETE, MainWindow

    monkeypatch.setattr(MainWindow, "ask_converted", lambda _self, _source: (DELETE, False))


@pytest.fixture
def people_db(tmp_path: Path) -> Path:
    db_file = tmp_path / "people.duckdb"
    conn = duckdb.connect(str(db_file))
    conn.execute("CREATE TABLE people (id INTEGER NOT NULL, name VARCHAR, score DOUBLE)")
    conn.execute("INSERT INTO people VALUES (1, 'Ana', 9.5), (2, 'Bruno', NULL), (10, 'carla', 7.25)")
    conn.execute("CREATE TABLE empty_table (code INTEGER, label VARCHAR)")
    conn.close()
    return db_file
