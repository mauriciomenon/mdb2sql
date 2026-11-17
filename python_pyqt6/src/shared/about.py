# Dados do dialogo Sobre: nome, versao (fonte unica: pyproject.toml), numero e data do build, funcao, stack,
# leitor de Access, autor, licenca e links do codigo
# !T: The version comes from pyproject.toml; the frozen exe carries it in VERSION and the build number/date in
# !T: BUILD (both written by mdb2sql.spec); outside the exe the build is "dev"

import platform
import re
import sys
import tomllib
from pathlib import Path

import duckdb
import pyodbc
import xlsxwriter
from PyQt6.QtCore import PYQT_VERSION_STR, qVersion

from backend.access import odbc_available
from shared.bundle import bundled

APP_NAME = "mdb2sql"
STACK = "Python"  # nome curto, usado no titulo da janela; a stack completa fica no Sobre
SUMMARY = "Abre bancos Access (.mdb/.accdb), SQLite e DuckDB e exporta para DuckDB, SQLite, Excel e CSV."
LINKS = (
    ("GitHub", "https://github.com/mauriciomenon/mdb2sql"),
    ("GitLab", "https://gitlab.com/mauricio.menon/mdb2sql"),
)


def _bundle() -> Path | None:
    bundle = getattr(sys, "_MEIPASS", None)  # pasta temporaria do exe do PyInstaller
    return Path(bundle) if bundle else None


def app_version() -> str:
    bundle = _bundle()
    if bundle:
        return (bundle / "VERSION").read_text(encoding="utf-8").strip()
    with open(Path(__file__).resolve().parents[2] / "pyproject.toml", "rb") as handle:
        return tomllib.load(handle)["project"]["version"]


def app_title() -> str:
    """Titulo curto da janela: 'mdb2sql <versao> - Python'."""
    return f"{APP_NAME} {app_version()} - {STACK}"


def build_info() -> str:
    """'build <N> (<AAAA-MM-DD>)' no exe (N = git rev-list --count HEAD); 'build dev' fora dele."""
    bundle = _bundle()
    if bundle and (bundle / "BUILD").is_file():
        number, day = (bundle / "BUILD").read_text(encoding="utf-8").split()
        return f"build {number} ({day})"
    return "build dev"


def access_engine() -> str:
    # os dois leitores de Access, na ordem em que sao tentados, e se estao disponiveis nesta maquina
    version_file = bundled("mdbtools") / "VERSION.txt"
    found = re.search(r"\d+(\.\d+)+", version_file.read_text(encoding="utf-8")) if version_file.is_file() else None
    mdbtools = f"mdbtools {found.group()} embutido" if found else "mdbtools (so no exe de release)"
    return f"ODBC Microsoft Access Driver ({'instalado' if odbc_available() else 'nao instalado'}) ou {mdbtools}"


def about_fields() -> list[tuple[str, str]]:
    """Linhas (rotulo, valor) do Sobre, na ordem em que aparecem."""
    return [
        ("Build", build_info().removeprefix("build ")),
        ("Stack", f"Python {platform.python_version()} + PyQt6 {PYQT_VERSION_STR} (Qt {qVersion()})"),
        ("Bibliotecas", f"DuckDB {duckdb.__version__}, XlsxWriter {xlsxwriter.__version__}, pyodbc {pyodbc.version}"),
        ("Leitura do Access", access_engine()),
        ("Autor", "Mauricio Menon"),
        ("Licenca", "GPL v2 ou posterior"),
    ]


def link_html(url: str) -> str:
    return f'<a href="{url}">{url}</a>'
