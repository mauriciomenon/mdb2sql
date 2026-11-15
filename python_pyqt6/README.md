# MDB2SQL (Python + PyQt6)

Desktop viewer for DuckDB databases converted from Microsoft Access: table list with filter, Data and
Schema tabs, row limit, search across the loaded columns, copy of a value or of whole rows as
TAB-separated text. DuckDB work runs off the UI thread; light/dark follows the system; Help > Sobre
shows the version and runtimes.

## Stack and versions

| Part | Version | Fixed by |
| --- | --- | --- |
| Python | 3.12.16 | `.python-version` |
| PyQt6 | 6.10.0 | `uv.lock` |
| DuckDB (Python) | 2.0.0 | `uv.lock` |
| PyInstaller | 6.22.3 | `uv.lock` |
| pytest / pytest-qt | 9.0.3 / 4.5.0 | `uv.lock` |

The version of the app has one source, `version` in `pyproject.toml`. The spec writes it to a `VERSION`
file inside the exe and `src/shared/about.py` reads it.

## Run and test

```bash
uv run --python 3.12 python src/main.py [database.duckdb]   # or set MDB2SQL_DB_PATH
QT_QPA_PLATFORM=offscreen uv run --python 3.12 pytest -q
```

System prerequisite: [uv](https://docs.astral.sh/uv/) in PATH. It downloads everything else.

## Build

```powershell
pwsh -NoProfile -File build_w11_amd64.ps1   # -> dist\w11\amd64\mdb2sql-<version>-w11-amd64-python-pyqt6.exe
```

Commands, products, work folders and cleaning: [README-BUILD.txt](README-BUILD.txt).

## Layout

- `src/main.py` - entry point; `src/ui/` - window and table model; `src/backend/` - DuckDB access and
  background tasks; `src/shared/` - About text and TAB-separated copy.
- `tests/` - pytest + pytest-qt.
- `mdb2sql.spec` - PyInstaller spec of the single-file exe.
- `scripts/` - build steps called by `build_w11_amd64.ps1`; `scripts/scan_exe.py` opens the exe and fails
  the build if it finds a path or name of the build machine.
- `docs/PythonConceptsGuide.md` - Python concepts used in this code.
