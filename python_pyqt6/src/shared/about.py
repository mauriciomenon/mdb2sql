# Dados do dialogo Sobre: nome, versao (fonte unica: pyproject.toml), numero e data do build, funcao, stack,
# leitor de Access, autor, licenca e links do codigo
# !T: The version comes from pyproject.toml; the frozen exe carries it in VERSION and the build number/date in
# !T: BUILD (both written by mdb2sql.spec); outside the exe the build is "dev"

import platform
import sqlite3
import sys
import tomllib
from pathlib import Path

import duckdb
import xlsxwriter
from PyQt6.QtCore import PYQT_VERSION_STR, qVersion

from backend.access import odbc_available
from shared.bundle import bundled
from shared.i18n import tr

APP_NAME = "mdb2sql"
STACK = "Python"  # nome curto, usado no titulo da janela; a stack completa fica no Sobre
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
    # o leitor em uso: o driver ODBC e opcional (so aparece quando existe); o mdbtools vai dentro do pacote
    if odbc_available():
        return tr("about.reader_odbc")
    return tr("about.reader_mdbtools") if (bundled("mdbtools") / "VERSION.txt").is_file() else tr("about.mdbtools_missing")


def pyodbc_version() -> str:
    # Linux sem unixODBC (libodbc) nao carrega o pyodbc; o Access vai pelo mdbtools
    try:
        import pyodbc
    except ImportError:
        return "-"
    return pyodbc.version


def about_fields() -> list[tuple[str, str]]:
    """Linhas (rotulo, valor) do Sobre, na ordem em que aparecem."""
    libraries = (
        f"SQLite {sqlite3.sqlite_version}, DuckDB {duckdb.__version__}, XlsxWriter {xlsxwriter.__version__},"
        f" pyodbc {pyodbc_version()}"
    )
    return [
        (tr("about.build"), build_info().removeprefix("build ")),
        ("Stack", f"Python {platform.python_version()} + PyQt6 {PYQT_VERSION_STR} (Qt {qVersion()})"),
        (tr("about.libraries"), libraries),
        (tr("about.access"), access_engine()),
        (tr("about.author"), "Mauricio Menon"),
        (tr("about.license"), tr("about.license_text")),
    ]


def link_html(url: str) -> str:
    return f'<a href="{url}">{url}</a>'
