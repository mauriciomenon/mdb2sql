# Dados do dialogo Sobre (as linhas do Rust): nome, versao (fonte unica: pyproject.toml), build, stack, janela,
# bancos, leitura do Access, autor, licenca e links do codigo
# !T: The version comes from pyproject.toml; the frozen exe carries it in VERSION and the build number/date in
# !T: BUILD (both written by mdb2sql.spec); outside the exe the build is "dev"

import platform
import re
import sqlite3
import sys
import tomllib
from pathlib import Path

import duckdb
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


def mdbtools_version() -> str:
    """Versao do mdbtools que vai no pacote (primeira linha de VERSION.txt: 'mdbtools 1.0.1 ...'); '' sem ele."""
    version = bundled("mdbtools") / "VERSION.txt"
    if not version.is_file():
        return ""
    found = re.search(r"mdbtools\s+([\w.]+)", version.read_text(encoding="utf-8", errors="replace"))
    return found[1] if found else "?"


def access_engine() -> str:
    # como o Access e lido (textos do Rust): o driver ODBC e opcional (so aparece quando existe); o mdbtools vai
    # dentro do pacote
    mdbtools = mdbtools_version()
    if odbc_available():
        return tr("about.access_odbc", version=mdbtools) if mdbtools else tr("about.access_odbc_only")
    return tr("about.access_mdbtools", version=mdbtools) if mdbtools else tr("about.mdbtools_missing")


def about_fields() -> list[tuple[str, str]]:
    """Linhas (rotulo, valor) do Sobre, na ordem em que aparecem (igual nas 4 versoes: as do Rust)."""
    return [
        (tr("about.build"), build_info().removeprefix("build ")),
        (tr("about.stack"), f"Python {platform.python_version()} + PyQt6 {PYQT_VERSION_STR}"),
        (tr("about.window"), f"Qt {qVersion()}"),
        (tr("about.databases"), f"SQLite {sqlite3.sqlite_version}, DuckDB {duckdb.__version__}"),
        (tr("about.access"), access_engine()),
        (tr("about.write"), tr("about.write_text")),
        (tr("about.author"), "Mauricio Menon"),
        (tr("about.license"), tr("about.license_text")),
    ]


def link_html(url: str, text: str = "") -> str:
    return f'<a href="{url}">{text or url}</a>'
