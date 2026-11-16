# Texto do dialogo Sobre: nome, versao (fonte unica: pyproject.toml), numero e data do build, funcao, runtimes,
# autor, codigo
# !T: The version comes from pyproject.toml; the frozen exe carries it in VERSION and the build number/date in
# !T: BUILD (both written by mdb2sql.spec); outside the exe the build is "dev"

import platform
import sys
import tomllib
from pathlib import Path

import duckdb
import pyodbc
import xlsxwriter
from PyQt6.QtCore import PYQT_VERSION_STR, qVersion

APP_NAME = "MDB2SQL (Python + PyQt6)"
SOURCE_URL = "https://github.com/mauriciomenon/mdb2sql"


def _bundle() -> Path | None:
    bundle = getattr(sys, "_MEIPASS", None)  # pasta temporaria do exe do PyInstaller
    return Path(bundle) if bundle else None


def app_version() -> str:
    bundle = _bundle()
    if bundle:
        return (bundle / "VERSION").read_text(encoding="utf-8").strip()
    with open(Path(__file__).resolve().parents[2] / "pyproject.toml", "rb") as handle:
        return tomllib.load(handle)["project"]["version"]


def build_info() -> str:
    """'build <N> (<AAAA-MM-DD>)' no exe (N = git rev-list --count HEAD); 'build dev' fora dele."""
    bundle = _bundle()
    if bundle and (bundle / "BUILD").is_file():
        number, day = (bundle / "BUILD").read_text(encoding="utf-8").split()
        return f"build {number} ({day})"
    return "build dev"


def about_lines() -> list[str]:
    return [
        APP_NAME,
        f"Versao {app_version()} - {build_info()}",
        "Abre bancos Access (.mdb/.accdb), SQLite e DuckDB e exporta para DuckDB, SQLite, Excel e CSV.",
        f"Python {platform.python_version()}, PyQt6 {PYQT_VERSION_STR}, Qt {qVersion()}, DuckDB {duckdb.__version__}, "
        f"XlsxWriter {xlsxwriter.__version__}, pyodbc {pyodbc.version}",
        "Autor: Mauricio Menon",
        f"Codigo: {SOURCE_URL}",
    ]


def about_html() -> str:
    name, *rest = about_lines()
    body = "<br>".join(rest).replace(SOURCE_URL, f'<a href="{SOURCE_URL}">{SOURCE_URL}</a>')
    return f"<h3>{name}</h3><p>{body}</p>"
