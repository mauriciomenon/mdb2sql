# Texto do dialogo Sobre: nome, versao (fonte unica: pyproject.toml), funcao, runtimes, autor, codigo
# !T: The version comes from pyproject.toml; the frozen exe carries it as a VERSION file (see mdb2sql.spec)

import platform
import sys
import tomllib
from pathlib import Path

import duckdb
from PyQt6.QtCore import PYQT_VERSION_STR, qVersion

APP_NAME = "MDB2SQL (Python + PyQt6)"
SOURCE_URL = "https://github.com/mauriciomenon/mdb2sql"


def app_version() -> str:
    bundle = getattr(sys, "_MEIPASS", None)  # pasta temporaria do exe do PyInstaller
    if bundle:
        return (Path(bundle) / "VERSION").read_text(encoding="utf-8").strip()
    with open(Path(__file__).resolve().parents[2] / "pyproject.toml", "rb") as handle:
        return tomllib.load(handle)["project"]["version"]


def about_lines() -> list[str]:
    return [
        APP_NAME,
        f"Versao {app_version()}",
        "Visualizador de bancos DuckDB convertidos de Microsoft Access: tabelas, esquema, dados e consultas.",
        f"Python {platform.python_version()}, PyQt6 {PYQT_VERSION_STR}, Qt {qVersion()}, DuckDB {duckdb.__version__}",
        "Autor: Mauricio Menon",
        f"Codigo: {SOURCE_URL}",
    ]


def about_html() -> str:
    name, *rest = about_lines()
    body = "<br>".join(rest).replace(SOURCE_URL, f'<a href="{SOURCE_URL}">{SOURCE_URL}</a>')
    return f"<h3>{name}</h3><p>{body}</p>"
