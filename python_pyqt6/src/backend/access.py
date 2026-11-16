# Leitura de .mdb/.accdb para um DuckDB em memoria: ODBC "Microsoft Access Driver" se instalado, senao o
# mdbtools estatico que vai dentro do exe. MDB2SQL_ACCESS_READER=odbc|mdbtools forca um dos dois.
# !T: Both paths create the DuckDB tables with types read from the Access schema, then fill them

import os
import re
import shutil
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
from pathlib import Path
from typing import Callable

import duckdb
import pandas as pd

from shared.bundle import FROZEN, bundled

ODBC_DRIVER = "Microsoft Access Driver (*.mdb, *.accdb)"
MDBTOOLS = ("mdb-tables.exe", "mdb-schema.exe", "mdb-export.exe")
READERS = {"odbc": "Access ODBC", "mdbtools": "mdbtools"}
NO_READER = (
    "Nenhum leitor de Access disponivel. Instale o Microsoft Access Database Engine 2016 Redistributable "
    "(64 bits, https://www.microsoft.com/download/details.aspx?id=54920) ou use o exe de release, que traz "
    "o mdbtools embutido."
)
NULL = "\x01NULL\x01"  # nao aparece em texto real: separa NULL da string vazia no CSV do mdb-export
TIMESTAMP = "%Y-%m-%d %H:%M:%S"
CHUNK = 10_000

Progress = Callable[[int, int, str], None]

# tipos do ODBC (TYPE_NAME de SQLColumns) e do mdb-schema (backend access) para DuckDB
ODBC_TYPES = {
    "BIT": "BOOLEAN", "BYTE": "UTINYINT", "SMALLINT": "SMALLINT", "INTEGER": "INTEGER", "COUNTER": "INTEGER",
    "BIGINT": "BIGINT", "REAL": "FLOAT", "DOUBLE": "DOUBLE", "CURRENCY": "DECIMAL(19,4)",
    "DATETIME": "TIMESTAMP", "GUID": "VARCHAR", "LONGBINARY": "BLOB", "VARBINARY": "BLOB", "BINARY": "BLOB",
}
MDB_TYPES = {
    "Boolean": "BOOLEAN", "Byte": "UTINYINT", "Integer": "SMALLINT", "Long Integer": "INTEGER",
    "Big Integer": "BIGINT", "Single": "FLOAT", "Double": "DOUBLE", "Currency": "DECIMAL(19,4)",
    "DateTime": "TIMESTAMP", "Replication ID": "VARCHAR", "OLE": "BLOB", "Binary": "BLOB",
}


def quote(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def decimal_type(precision: int | None, scale: int | None) -> str:
    # DuckDB guarda ate 38 digitos
    return f"DECIMAL({min(precision or 18, 38)},{min(scale or 0, 38)})"


def mdbtools_dir() -> Path | None:
    # no exe: copia unica por versao em %LOCALAPPDATA%\mdb2sql\python-pyqt6-<versao>\mdbtools (apaga versoes velhas)
    source = bundled("mdbtools")
    if not all((source / exe).is_file() for exe in MDBTOOLS):
        return None
    if not FROZEN:
        return source
    from shared.about import app_version

    base = Path(os.environ.get("LOCALAPPDATA") or tempfile.gettempdir()) / "mdb2sql"
    target = base / f"python-pyqt6-{app_version()}" / "mdbtools"
    if not all((target / exe).is_file() for exe in MDBTOOLS):
        shutil.copytree(source, target, dirs_exist_ok=True)
    for old in base.glob("python-pyqt6-*"):
        if old != target.parent:
            shutil.rmtree(old, ignore_errors=True)
    return target


def access_reader() -> str:
    forced = os.environ.get("MDB2SQL_ACCESS_READER", "").strip().lower()
    if forced and forced not in READERS:
        raise ValueError(f"MDB2SQL_ACCESS_READER={forced}: use odbc ou mdbtools")
    if forced == "odbc" or (not forced and odbc_available()):
        return "odbc"
    if mdbtools_dir() is not None:
        return "mdbtools"
    raise RuntimeError(NO_READER)


def odbc_available() -> bool:
    try:
        import pyodbc
    except ImportError:
        return False
    return ODBC_DRIVER in pyodbc.drivers()


def load_access(path: Path, conn: duckdb.DuckDBPyConnection, progress: Progress | None = None) -> str:
    """Copia todas as tabelas do Access para conn; devolve o nome do caminho usado."""
    reader = access_reader()
    (_load_odbc if reader == "odbc" else _load_mdbtools)(path, conn, progress or (lambda *_: None))
    return READERS[reader]


def _create(conn: duckdb.DuckDBPyConnection, table: str, columns: list[tuple[str, str]]) -> None:
    conn.execute(f"CREATE TABLE {quote(table)} ({', '.join(f'{quote(n)} {t}' for n, t in columns)})")


def _load_odbc(path: Path, conn: duckdb.DuckDBPyConnection, progress: Progress) -> None:
    import pyodbc

    if not odbc_available():
        raise RuntimeError(f"Driver ODBC '{ODBC_DRIVER}' nao instalado (64 bits). {NO_READER}")
    acc = pyodbc.connect(f"Driver={{{ODBC_DRIVER}}};DBQ={path};ReadOnly=1;", readonly=True)
    try:
        tables = sorted(row.table_name for row in acc.cursor().tables(tableType="TABLE"))
        for done, table in enumerate(tables):
            progress(done, len(tables), table)
            columns = [
                (c.column_name, _odbc_type(c.type_name, c.column_size, c.decimal_digits))
                for c in acc.cursor().columns(table=table)
            ]
            _create(conn, table, columns)
            cursor = acc.cursor().execute(f"SELECT * FROM [{table}]")
            names = [c[0] for c in cursor.description]
            while rows := cursor.fetchmany(CHUNK):
                # Decimal como texto: o DuckDB deduziria a precisao de uma amostra do bloco e estouraria
                rows = [tuple(str(v) if isinstance(v, Decimal) else v for v in r) for r in rows]
                chunk = pd.DataFrame.from_records(rows, columns=names)
                conn.register("chunk", chunk)
                conn.execute(f"INSERT INTO {quote(table)} SELECT * FROM chunk")
                conn.unregister("chunk")
        progress(len(tables), len(tables), "")
    finally:
        acc.close()


def _odbc_type(type_name: str, size: int | None, digits: int | None) -> str:
    name = type_name.upper()
    if name in ("DECIMAL", "NUMERIC"):
        return decimal_type(size, digits)
    return ODBC_TYPES.get(name, "VARCHAR")


def _run(tools: Path, exe: str, *args: str) -> str:
    # CREATE_NO_WINDOW: o exe e GUI; sem isso cada chamada abre uma janela de console
    done = subprocess.run(
        [str(tools / exe), *args], capture_output=True, check=True, creationflags=subprocess.CREATE_NO_WINDOW
    )
    return done.stdout.decode("utf-8")


def mdb_schema_tables(schema: str) -> dict[str, list[tuple[str, str]]]:
    """Tabela -> colunas e tipos DuckDB, a partir do DDL do mdb-schema (backend access) do banco inteiro."""
    blocks = re.finditer(r"^CREATE TABLE \[([^\]]+)\]\s*\((.*?)^\);", schema, re.MULTILINE | re.DOTALL)
    return {match[1]: mdb_columns(match[2]) for match in blocks}


def mdb_columns(schema: str) -> list[tuple[str, str]]:
    """Colunas e tipos DuckDB a partir das linhas '[coluna] Tipo,' de uma tabela do mdb-schema."""
    columns = []
    for match in re.finditer(r"^\s*\[([^\]]+)\]\s+(.+?)\s*,?\s*$", schema, re.MULTILINE):
        name, access_type = match.groups()
        numeric = re.fullmatch(r"Numeric \((\d+), (\d+)\)", access_type)
        if numeric:
            columns.append((name, decimal_type(int(numeric[1]), int(numeric[2]))))
        else:
            columns.append((name, MDB_TYPES.get(re.sub(r" \(\d+\)$", "", access_type), "VARCHAR")))
    return columns


def _load_mdbtools(path: Path, conn: duckdb.DuckDBPyConnection, progress: Progress) -> None:
    tools = mdbtools_dir()
    if tools is None:
        raise RuntimeError(f"mdbtools nao encontrado. {NO_READER}")
    tables = sorted(_run(tools, "mdb-tables.exe", "-1", str(path)).splitlines())
    schema = mdb_schema_tables(_run(tools, "mdb-schema.exe", "--no-indexes", "--no-relations", str(path), "access"))
    missing = [table for table in tables if table not in schema]
    if missing:
        raise RuntimeError(f"mdb-schema sem as tabelas: {', '.join(missing[:5])}")

    with tempfile.TemporaryDirectory(prefix="mdb2sql-") as tmp:

        def export(index: int, table: str) -> Path:
            csv_path = Path(tmp) / f"{index}.csv"
            with open(csv_path, "wb") as out:
                subprocess.run(
                    [str(tools / "mdb-export.exe"), "-0", NULL, "-D", TIMESTAMP, "-T", TIMESTAMP, "-b", "hex",
                     str(path), table],
                    stdout=out, stderr=subprocess.PIPE, check=True, creationflags=subprocess.CREATE_NO_WINDOW,
                )
            return csv_path

        # o mdb-export leva ~20 s numa tabela grande: varios processos em paralelo, carga no DuckDB em ordem
        with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
            exports = [pool.submit(export, index, table) for index, table in enumerate(tables)]
            try:
                for done, (table, future) in enumerate(zip(tables, exports)):
                    progress(done, len(tables), table)
                    columns = schema[table]
                    _create(conn, table, columns)
                    csv_path = future.result()
                    # tudo lido como texto e convertido pelo INSERT para os tipos do schema; binario vem em hex
                    values = ", ".join(f"unhex({quote(n)})" if t == "BLOB" else quote(n) for n, t in columns)
                    conn.execute(
                        f"INSERT INTO {quote(table)} SELECT {values} FROM read_csv(?, header = true, "
                        "all_varchar = true, nullstr = ?, quote = '\"', escape = '\"', delim = ',', names = ?)",
                        [str(csv_path), NULL, [n for n, _ in columns]],
                    )
                    csv_path.unlink()
            except BaseException:
                for future in exports:
                    future.cancel()
                raise
        progress(len(tables), len(tables), "")
