# Conversao de .mdb/.accdb para um arquivo SQLite, feita uma vez ao abrir: o app le dali. Leitor: ODBC "Microsoft
# Access Driver" se instalado (mais rapido), senao o mdbtools que vai dentro do pacote (nada instalado na maquina).
# MDB2SQL_ACCESS_READER=odbc|mdbtools forca um dos dois.
# !T: Both readers create the SQLite tables with declared types read from the Access schema (INTEGER, DOUBLE,
# !T: DECIMAL(p,s), BOOLEAN, DATETIME, TEXT, BLOB); the reader (db_manager) casts DECIMAL and BOOLEAN back

import csv
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path
from typing import Callable, Iterator

from shared.bundle import FROZEN, bundled
from shared.i18n import tr

ODBC_DRIVER = "Microsoft Access Driver (*.mdb, *.accdb)"
EXE = ".exe" if os.name == "nt" else ""
MDBTOOLS = tuple(f"{name}{EXE}" for name in ("mdb-tables", "mdb-schema", "mdb-export"))
READERS = {"odbc": "Access ODBC", "mdbtools": "mdbtools"}
NULL = "\x01NULL\x01"  # nao aparece em texto real: separa NULL da string vazia no CSV do mdb-export
TIMESTAMP = "%Y-%m-%d %H:%M:%S"
INVALID_DATE = "1900-01-00"  # data que o mdbtools 1.0.1 do Linux nao converte (fora de ~1900-9999)
CHUNK = 10_000
# versao da conversao: vai junto do convertido lembrado entre execucoes; um salvo por versao antiga e convertido de
# novo. 2: Numeric(p,0) como inteiro (BRIEF 19 a, b)
CONVERTER_VERSION = 2
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)  # so existe no Windows: exe GUI sem janela de console

Progress = Callable[[int, int, str], None]

# tipos do ODBC (TYPE_NAME de SQLColumns) e do mdb-schema (backend access) -> tipo declarado no SQLite
ODBC_TYPES = {
    "BIT": "BOOLEAN", "BYTE": "TINYINT", "SMALLINT": "SMALLINT", "INTEGER": "INTEGER", "COUNTER": "INTEGER",
    "BIGINT": "BIGINT", "REAL": "REAL", "DOUBLE": "DOUBLE", "CURRENCY": "DECIMAL(19,4)",
    "DATETIME": "DATETIME", "LONGBINARY": "BLOB", "VARBINARY": "BLOB", "BINARY": "BLOB",
}
MDB_TYPES = {
    "Boolean": "BOOLEAN", "Byte": "TINYINT", "Integer": "SMALLINT", "Long Integer": "INTEGER",
    "Big Integer": "BIGINT", "Single": "REAL", "Double": "DOUBLE", "Currency": "DECIMAL(19,4)",
    "DateTime": "DATETIME", "OLE": "BLOB", "Binary": "BLOB",
}


def quote(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def decimal_type(precision: int | None, scale: int | None) -> str:
    # Numeric(p,0) do Access e inteiro (RTUNO, PNTNO): INTEGER ate 9 digitos, BIGINT ate 18 (BRIEF 19 a); com casas
    # decimais, DECIMAL(p,s). O DuckDB (que le o SQLite) guarda ate 38 digitos
    precision, scale = min(precision or 18, 38), min(scale or 0, 38)
    if scale == 0 and precision <= 18:
        return "INTEGER" if precision <= 9 else "BIGINT"
    return f"DECIMAL({precision},{scale})"


def mdbtools_dir() -> Path | None:
    # exe do Windows: copia unica por versao em %LOCALAPPDATA%\mdb2sql\python-pyqt6-<versao>\mdbtools (apaga
    # versoes velhas); Linux e codigo-fonte usam a pasta do pacote
    source = bundled("mdbtools")
    if not all((source / exe).is_file() for exe in MDBTOOLS):
        return None
    if not FROZEN or os.name != "nt":
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
        raise ValueError(tr("error.reader_var", value=forced))
    if forced == "odbc" or (not forced and odbc_available()):
        return "odbc"
    if mdbtools_dir() is not None:
        return "mdbtools"
    raise RuntimeError(tr("error.no_reader"))


def odbc_available() -> bool:
    try:
        import pyodbc
    except ImportError:
        return False
    return ODBC_DRIVER in pyodbc.drivers()


def convert_access(path: Path, out: Path, progress: Progress | None = None) -> str:
    """Grava todas as tabelas do Access no SQLite out (arquivo novo); devolve o nome do leitor usado."""
    reader = access_reader()
    lite = sqlite3.connect(out)
    try:
        # arquivo de trabalho: sem diario (um erro descarta o arquivo inteiro); uma transacao so, commit no fim
        lite.execute("PRAGMA journal_mode = OFF")
        lite.execute("PRAGMA synchronous = OFF")
        load = _load_odbc if reader == "odbc" else _load_mdbtools
        load(path, lite, out.parent, progress or (lambda *_: None))
        lite.commit()
    finally:
        lite.close()
    return READERS[reader]


def _create(lite: sqlite3.Connection, table: str, columns: list[tuple[str, str]]) -> str:
    """CREATE TABLE com os tipos declarados; devolve o INSERT com um ? por coluna."""
    lite.execute(f"CREATE TABLE {quote(table)} ({', '.join(f'{quote(n)} {t}' for n, t in columns)})")
    return f"INSERT INTO {quote(table)} VALUES ({', '.join('?' * len(columns))})"


def number_value(value: Decimal) -> int | float:
    """Decimal para o SQLite: inteiro como INTEGER, com casas como REAL (CAST para DOUBLE antes de gravar); nunca
    texto (BRIEF 19 h: um texto com mais de 15 digitos ficaria TEXT mesmo numa coluna DECIMAL)."""
    return int(value) if value.is_finite() and value == value.to_integral_value() else float(value)


def _odbc_value(value: object) -> object:
    # Decimal: number_value; data no mesmo formato do mdbtools
    if isinstance(value, Decimal):
        return number_value(value)
    if isinstance(value, datetime):
        return value.strftime(TIMESTAMP)
    if isinstance(value, date):
        return value.isoformat()
    return value


def _load_odbc(path: Path, lite: sqlite3.Connection, _work: Path, progress: Progress) -> None:
    import pyodbc

    if not odbc_available():
        raise RuntimeError(tr("error.no_odbc", driver=ODBC_DRIVER))
    acc = pyodbc.connect(f"Driver={{{ODBC_DRIVER}}};DBQ={path};ReadOnly=1;", readonly=True)
    try:
        tables = sorted(row.table_name for row in acc.cursor().tables(tableType="TABLE"))
        for done, table in enumerate(tables):
            progress(done, len(tables), table)
            columns = [
                (c.column_name, _odbc_type(c.type_name, c.column_size, c.decimal_digits))
                for c in acc.cursor().columns(table=table)
            ]
            insert = _create(lite, table, columns)
            cursor = acc.cursor().execute(f"SELECT * FROM [{table}]")
            while rows := cursor.fetchmany(CHUNK):
                lite.executemany(insert, [tuple(_odbc_value(v) for v in row) for row in rows])
        progress(len(tables), len(tables), "")
    finally:
        acc.close()


def _odbc_type(type_name: str, size: int | None, digits: int | None) -> str:
    name = type_name.upper()
    if name in ("DECIMAL", "NUMERIC"):
        return decimal_type(size, digits)
    return ODBC_TYPES.get(name, "TEXT")


def _tool_env(tools: Path) -> dict[str, str] | None:
    # Linux: as bibliotecas do mdbtools (libmdb) vao na mesma pasta dos programas
    if os.name == "nt":
        return None
    paths = [str(tools), os.environ.get("LD_LIBRARY_PATH", "")]
    return {**os.environ, "LD_LIBRARY_PATH": os.pathsep.join(p for p in paths if p)}


def _run(tools: Path, exe: str, *args: str) -> str:
    done = subprocess.run(
        [str(tools / exe), *args], capture_output=True, check=True, creationflags=NO_WINDOW, env=_tool_env(tools)
    )
    return done.stdout.decode("utf-8")


def mdb_schema_tables(schema: str) -> dict[str, list[tuple[str, str]]]:
    """Tabela -> colunas e tipos SQLite, a partir do DDL do mdb-schema (backend access) do banco inteiro."""
    blocks = re.finditer(r"^CREATE TABLE \[([^\]]+)\]\s*\((.*?)^\);", schema, re.MULTILINE | re.DOTALL)
    return {match[1]: mdb_columns(match[2]) for match in blocks}


def mdb_columns(schema: str) -> list[tuple[str, str]]:
    """Colunas e tipos SQLite a partir das linhas '[coluna] Tipo [NOT NULL],' de uma tabela do mdb-schema."""
    columns = []
    for match in re.finditer(r"^\s*\[([^\]]+)\]\s+(.+?)\s*,?\s*$", schema, re.MULTILINE):
        name, access_type = match.groups()
        access_type = access_type.removesuffix(" NOT NULL")
        numeric = re.fullmatch(r"Numeric \((\d+), (\d+)\)", access_type)
        if numeric:
            columns.append((name, decimal_type(int(numeric[1]), int(numeric[2]))))
        else:
            columns.append((name, MDB_TYPES.get(re.sub(r" \(\d+\)$", "", access_type), "TEXT")))
    return columns


def _csv_rows(csv_path: Path, blobs: list[int], dates: list[int], decimals: list[int] | None = None
              ) -> Iterator[list[object]]:
    """Linhas do CSV do mdb-export (sem o cabecalho): NULL vira None, binario (hex) vira bytes, DECIMAL vira numero
    (number_value).

    !T: mdbtools 1.0.1 cannot convert dates outside ~1900-9999: Windows prints them empty (NULL), Linux prints the
    !T: invalid 1900-01-00, which would make the whole table unreadable; it becomes NULL too (README: known limits)
    """
    with open(csv_path, encoding="utf-8", newline="") as handle:
        rows = csv.reader(handle)
        next(rows, None)
        for row in rows:
            values: list[object] = [None if v == NULL else v for v in row]
            for index in blobs:
                if values[index] is not None:
                    values[index] = bytes.fromhex(values[index])
            for index in dates:
                if isinstance(values[index], str) and values[index].startswith(INVALID_DATE):
                    values[index] = None
            for index in decimals or ():
                if values[index]:
                    values[index] = number_value(Decimal(values[index]))
            yield values


def _load_mdbtools(path: Path, lite: sqlite3.Connection, work: Path, progress: Progress) -> None:
    tools = mdbtools_dir()
    if tools is None:
        raise RuntimeError(tr("error.no_reader"))
    tables = sorted(_run(tools, MDBTOOLS[0], "-1", str(path)).splitlines())
    schema = mdb_schema_tables(_run(tools, MDBTOOLS[1], "--no-indexes", "--no-relations", str(path), "access"))
    missing = [table for table in tables if table not in schema]
    if missing:
        raise RuntimeError(tr("error.schema_missing", tables=", ".join(missing[:5])))
    csv.field_size_limit(2**31 - 1)  # Memo e OLE (hex) passam do limite padrao de 128 KiB por campo

    # CSV de trabalho ao lado do SQLite (pasta da sessao): se o app cair, a limpeza da sessao leva junto
    with tempfile.TemporaryDirectory(prefix="csv-", dir=work) as tmp:

        def export(index: int, table: str) -> Path:
            csv_path = Path(tmp) / f"{index}.csv"
            with open(csv_path, "wb") as out:
                subprocess.run(
                    [str(tools / MDBTOOLS[2]), "-0", NULL, "-D", TIMESTAMP, "-T", TIMESTAMP, "-b", "hex",
                     str(path), table],
                    stdout=out, stderr=subprocess.PIPE, check=True, creationflags=NO_WINDOW, env=_tool_env(tools),
                )
            return csv_path

        # o mdb-export de uma tabela grande domina o tempo (DB4: RANGER_SOSTAT, 123 colunas, ~27 s): as mais largas
        # (proxy de tamanho) comecam primeiro, num nucleo a menos que a maquina (max. 6), e cada CSV pronto e
        # gravado no SQLite assim que termina, sem esperar as anteriores
        order = sorted(tables, key=lambda name: -len(schema[name]))
        with ThreadPoolExecutor(max_workers=max(1, min((os.cpu_count() or 2) - 1, 6))) as pool:
            exports = {pool.submit(export, index, table): table for index, table in enumerate(order)}
            try:
                for done, future in enumerate(as_completed(exports)):
                    table = exports[future]
                    progress(done, len(tables), table)
                    columns = schema[table]
                    insert = _create(lite, table, columns)
                    csv_path = future.result()
                    blobs = [index for index, (_, kind) in enumerate(columns) if kind == "BLOB"]
                    dates = [index for index, (_, kind) in enumerate(columns) if kind == "DATETIME"]
                    decimals = [index for index, (_, kind) in enumerate(columns) if kind.startswith("DECIMAL")]
                    lite.executemany(insert, _csv_rows(csv_path, blobs, dates, decimals))
                    csv_path.unlink()
            except BaseException:
                for future in exports:
                    future.cancel()
                raise
        progress(len(tables), len(tables), "")
