# py_qt6

Python/PyQt6 implementation of the DuckDB desktop viewer.

This file exists so the package metadata in `pyproject.toml` can be built by
standard Python tooling.

## Run and test

```bash
uv run python src/main.py [database.duckdb]   # or set MDB2SQL_DB_PATH
QT_QPA_PLATFORM=offscreen uv run pytest -q
```

## Windows release build

```powershell
pwsh -NoProfile -File setup_tools.ps1    # once: Python 3.12.16 into .tools/python
pwsh -NoProfile -File build_windows.ps1  # dist/mdb2sql-pyqt.exe
```

- `setup_tools.ps1` installs the Python pinned in `.python-version` with `uv python install` into
  `.tools/python` (gitignored; no shim in `~/.local/bin`, no registry entry). uv checks the sha256 of the
  download.
- `build_windows.ps1` uses `.tools/python` when it exists, syncs the versions fixed in `uv.lock`
  (PyInstaller 6.22.3, PyQt6 6.10.0, DuckDB 2.0.0), builds the single-file exe from `mdb2sql.spec`
  and runs `scan_exe.py`, which unpacks the exe and fails the build if it finds a path or name of the
  build machine.
- The exe carries Python, Qt and DuckDB; nothing to install on the target machine.
- The version has one source, `pyproject.toml`. The spec writes it to a `VERSION` file inside the exe and
  `src/shared/about.py` reads it for Help > Sobre.

System prerequisite: [uv](https://docs.astral.sh/uv/) in PATH. It is the tool that downloads everything
else, so it cannot come from `.tools/`.
