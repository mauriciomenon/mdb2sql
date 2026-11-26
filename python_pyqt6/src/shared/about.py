# Dados do dialogo Sobre, iguais nas 4 versoes (BRIEF 18 b): nome, versao com o commit, runtime, ferramentas, ODBC,
# autor, licenca e os links do codigo
# !T: The version comes from pyproject.toml; the frozen exe carries it in VERSION and the full commit hash and the
# !T: build date in BUILD (both written by mdb2sql.spec); outside the exe the version line ends in "dev"

import platform
import re
import sqlite3
import sys
import tomllib
from pathlib import Path

import duckdb
from PyQt6.QtCore import PYQT_VERSION_STR, qVersion

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


def build_stamp() -> tuple[str, str] | None:
    """(commit de 40 digitos, AAAA-MM-DD do build) no exe; None fora dele (ou com um BUILD de outro formato)."""
    bundle = _bundle()
    if bundle and (bundle / "BUILD").is_file():
        parts = (bundle / "BUILD").read_text(encoding="utf-8").split()
        if len(parts) == 2 and re.fullmatch(r"[0-9a-f]{40}", parts[0]):
            return parts[0], parts[1]
    return None


def mdbtools_version() -> str:
    """Versao do mdbtools que vai no pacote (primeira linha de VERSION.txt: 'mdbtools 1.0.1 ...'); '' sem ele."""
    version = bundled("mdbtools") / "VERSION.txt"
    if not version.is_file():
        return ""
    found = re.search(r"mdbtools\s+([\w.]+)", version.read_text(encoding="utf-8", errors="replace"))
    return found[1] if found else "?"


def about_lines() -> list[str]:
    """As linhas do Sobre, nesta ordem, so texto tecnico (os links vem depois, numa linha propria)."""
    stamp = build_stamp()
    version = (tr("about.version", version=app_version(), commit=stamp[0], date=stamp[1]) if stamp
               else tr("about.version_dev", version=app_version()))
    tools = [f"SQLite {sqlite3.sqlite_version}", f"DuckDB {duckdb.__version__}"]
    if mdbtools_version():  # o mdbtools vai no pacote; rodando do codigo sem .tools nao ha versao a mostrar
        tools.append(f"mdbtools {mdbtools_version()}")
    return [
        f"MDB2SQL ({STACK})",
        version,
        f"Python {platform.python_version()}, PyQt6 {PYQT_VERSION_STR} (Qt {qVersion()})",
        tr("about.tools", tools=", ".join(tools)),
        tr("about.odbc"),
        tr("about.author", name="Mauricio Menon"),
        tr("about.license", license="GPLv2"),
    ]


def link_html(url: str, text: str = "") -> str:
    return f'<a href="{url}">{text or url}</a>'
