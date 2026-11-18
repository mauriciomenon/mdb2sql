# -*- mode: python ; coding: utf-8 -*-
# Dois produtos do mesmo Analysis (use build_w11_amd64.ps1, que tambem testa, varre e empacota):
#   build/dist/mdb2sql-pyqt.exe   exe unico (onefile)
#   build/dist/mdb2sql/           pasta do app (mdb2sql.exe + _internal), base do .zip e do instalador
import subprocess
import tomllib
from datetime import date
from pathlib import Path

root = Path(SPECPATH)
# fonte unica da versao: pyproject.toml; o exe leva o numero (VERSION) e o build (BUILD: numero de commits e data)
version = tomllib.loads((root / "pyproject.toml").read_text(encoding="utf-8"))["project"]["version"]
commits = subprocess.run(["git", "rev-list", "--count", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
(root / "build").mkdir(exist_ok=True)
(root / "build" / "VERSION").write_text(version, encoding="utf-8")
(root / "build" / "BUILD").write_text(f"{commits} {date.today().isoformat()}", encoding="utf-8")

# extensao sqlite do DuckDB e mdbtools baixados por scripts/setup_tools.ps1 (sha256 conferido)
bundled = [".tools/duckdb_ext/sqlite_scanner.duckdb_extension"] + [
    f".tools/mdbtools/{name}"
    for name in ("mdb-tables.exe", "mdb-schema.exe", "mdb-export.exe", "COPYING", "COPYING.LIB", "VERSION.txt")
]
missing = [path for path in bundled if not (root / path).is_file()]
if missing:
    raise SystemExit(f"faltam {missing}: rode scripts/setup_tools.ps1")

a = Analysis(
    ["src/main.py"],
    pathex=["src"],
    datas=[("build/VERSION", "."), ("build/BUILD", "."), ("src/resources/mdb2sql.ico", "resources"),
           ("src/resources/mdb2sql.png", "resources"), ("src/resources/i18n", "resources/i18n")] + [(path, Path(path).parent.name) for path in bundled],
    # pandas importa pytest so em pandas.testing; ferramenta de teste nao vai no exe
    excludes=["pytest", "_pytest", "pygments", "openpyxl"],
)
pyz = PYZ(a.pure)

onefile = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    name="mdb2sql-pyqt",
    icon="src/resources/mdb2sql.ico",
    console=False,
    upx=False,
)

onedir = EXE(
    pyz,
    a.scripts,
    exclude_binaries=True,
    name="mdb2sql",
    icon="src/resources/mdb2sql.ico",
    console=False,
    upx=False,
)
COLLECT(onedir, a.binaries, a.datas, name="mdb2sql", upx=False)
