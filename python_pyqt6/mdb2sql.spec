# -*- mode: python ; coding: utf-8 -*-
# Exe unico do Windows (build/dist/mdb2sql-pyqt.exe). Use build_w11_amd64.ps1, que tambem testa e varre o resultado.
import tomllib
from pathlib import Path

root = Path(SPECPATH)
# fonte unica da versao: pyproject.toml; o exe leva so o numero (shared/about.py le VERSION)
version = tomllib.loads((root / "pyproject.toml").read_text(encoding="utf-8"))["project"]["version"]
(root / "build").mkdir(exist_ok=True)
(root / "build" / "VERSION").write_text(version, encoding="utf-8")

a = Analysis(
    ["src/main.py"],
    pathex=["src"],
    datas=[("build/VERSION", ".")],
    # pandas importa pytest so em pandas.testing; ferramenta de teste nao vai no exe
    excludes=["pytest", "_pytest", "pygments"],
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    name="mdb2sql-pyqt",
    console=False,
    upx=False,
)
