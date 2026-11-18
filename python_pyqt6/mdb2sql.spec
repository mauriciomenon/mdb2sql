# -*- mode: python ; coding: utf-8 -*-
# Dois produtos do mesmo Analysis (use build_w11_amd64.ps1, que tambem testa, varre e empacota):
#   build/dist/mdb2sql-pyqt.exe   exe unico (onefile)
#   build/dist/mdb2sql/           pasta do app (mdb2sql.exe + _internal), base do .zip e do instalador
import subprocess
import sys
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

# extensao sqlite do DuckDB e mdbtools (programas, bibliotecas no Linux, licencas e versao) baixados com sha256
# conferido: scripts/setup_tools.ps1 (Windows) ou scripts/setup_tools_linux.sh (Debian)
exe = ".exe" if sys.platform == "win32" else ""
required = [".tools/duckdb_ext/sqlite_scanner.duckdb_extension"] + [
    f".tools/mdbtools/{name}" for name in (f"mdb-tables{exe}", f"mdb-schema{exe}", f"mdb-export{exe}", "VERSION.txt")
]
missing = [path for path in required if not (root / path).is_file()]
if missing:
    raise SystemExit(f"faltam {missing}: rode scripts/setup_tools.ps1 (Windows) ou scripts/setup_tools_linux.sh")
tools = sorted(p for p in (root / ".tools" / "mdbtools").iterdir() if p.is_file() and p.name != ".sha256")
bundled = required[:1] + [str(p.relative_to(root)) for p in tools]

# Linux: o _sysconfigdata do Python do uv guarda o caminho de instalacao (pasta do usuario de build) e o pandas o
# importa; vai no pacote uma copia com essa pasta trocada por /build (build/sysconfig, antes da stdlib no pathex)
pathex = ["src"]
if not exe:
    import importlib
    import pprint
    import sysconfig

    name = sysconfig._get_sysconfigdata_name()
    data = importlib.import_module(name).build_time_vars
    clean = {k: v.replace(str(root), "/build") if isinstance(v, str) else v for k, v in data.items()}
    (root / "build" / "sysconfig").mkdir(parents=True, exist_ok=True)
    (root / "build" / "sysconfig" / f"{name}.py").write_text(f"build_time_vars = {pprint.pformat(clean)}\n")
    pathex.insert(0, str(root / "build" / "sysconfig"))

a = Analysis(
    ["src/main.py"],
    pathex=pathex,
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
