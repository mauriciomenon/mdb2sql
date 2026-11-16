# Arquivos que vao dentro do exe (extensao sqlite do DuckDB, mdbtools): no exe ficam na pasta do PyInstaller,
# no desenvolvimento em .tools\ (baixados e conferidos por scripts\setup_tools.ps1)

import sys
from pathlib import Path

FROZEN = hasattr(sys, "_MEIPASS")
ROOT = Path(__file__).resolve().parents[2]  # pasta python_pyqt6 (so vale fora do exe)


def bundled(name: str) -> Path:
    return Path(sys._MEIPASS) / name if FROZEN else ROOT / ".tools" / name


def resource(name: str) -> Path:
    # icone do app: src\resources no codigo, pasta resources dentro do exe (mdb2sql.spec)
    return (Path(sys._MEIPASS) if FROZEN else ROOT / "src") / "resources" / name
