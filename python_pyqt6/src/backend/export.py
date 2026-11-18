# Exportacao: banco inteiro para .duckdb, .sqlite ou .xlsx (uma aba por tabela) e tabela/consulta para .csv ou .xlsx
# !T: Runs in a worker thread; progress(done, total, text) reports, cancel (threading.Event) stops between chunks
# !T: and only the temporary file is deleted; the target is replaced only when the export finished

import csv
import os
import re
import shutil
import threading
import uuid
from contextlib import contextmanager
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from pathlib import Path
from typing import Callable, Iterable, Iterator

import xlsxwriter

from backend.access import quote
from backend.db_manager import DBManager, load_sqlite_extension, sql_string
from shared.i18n import num, tr

Progress = Callable[[int, int, str], None]
MAX_SHEET_ROWS = 1_048_575  # linhas de dados por aba: 1.048.576 do Excel menos o cabecalho
MAX_SHEET_NAME = 31
CHUNK = 5_000
_BAD_SHEET_CHARS = re.compile(r"[\[\]:*?/\\]")
_EXCEL_TYPES = (str, int, float, Decimal, bool, datetime, date, time, timedelta)
DATABASE_FORMATS = (".duckdb", ".sqlite", ".xlsx")
RESULT_FORMATS = (".csv", ".xlsx")


class Cancelled(Exception):
    pass


def sheet_name(table: str, part: int, used: set[str]) -> str:
    """Nome de aba valido e unico (sem diferenciar maiusculas): ate 31 caracteres, part > 1 vira '<nome> (part)'."""
    base = _BAD_SHEET_CHARS.sub("_", table).strip("'") or "Sheet"
    suffix = f" ({part})" if part > 1 else ""
    tag, n = "", 1
    while True:
        stem = base[: MAX_SHEET_NAME - len(suffix) - len(tag)].rstrip("'")
        name = stem + tag + suffix
        if name.lower() not in used:
            used.add(name.lower())
            return name
        n += 1
        tag = f"~{n}"


def default_save_dir(source: Path | None, last_dir: str | None) -> Path:
    """Pasta padrao do dialogo de salvar: a do arquivo aberto; sem ele, a ultima usada; senao a pasta do usuario."""
    if source is not None and source.parent.is_dir():
        return source.parent
    if last_dir and Path(last_dir).is_dir():
        return Path(last_dir)
    return Path.home()


def _check(cancel: threading.Event | None) -> None:
    if cancel is not None and cancel.is_set():
        raise Cancelled()


def _remove(path: Path) -> None:
    for leftover in (path, path.with_name(path.name + ".wal")):
        leftover.unlink(missing_ok=True)


@contextmanager
def _staged(out: Path, cancel: threading.Event | None) -> Iterator[Path]:
    """Grava num arquivo temporario so desta exportacao e so no sucesso troca o destino.

    !T: Error or cancel removes only the temporary file: an existing file with the target name is kept. The
    !T: cancel check after the work makes a cancel during the last table/chunk count as a cancel
    """
    temp = out.with_name(f"{out.stem}.{uuid.uuid4().hex[:12]}.partial{out.suffix}")
    try:
        yield temp
        _check(cancel)
        os.replace(temp, out)
    finally:
        _remove(temp)


def export_database(
    manager: DBManager, out: Path, progress: Progress, cancel: threading.Event | None = None
) -> int:
    """Grava todas as tabelas em out (.duckdb, .sqlite ou .xlsx); devolve o numero de tabelas."""
    suffix = out.suffix.lower()
    if suffix not in DATABASE_FORMATS:
        raise ValueError(tr("error.export_format", suffix=suffix))
    if manager.current_db and out.resolve() == Path(manager.current_db).resolve():
        raise ValueError(tr("error.export_self"))
    tables = manager.list_tables()
    with _staged(out, cancel) as temp:
        if suffix == ".xlsx":
            _database_to_xlsx(manager, tables, temp, progress, cancel)
        elif suffix == ".sqlite" and manager.converted is not None:
            shutil.copyfile(manager.converted, temp)  # Access: o SQLite ja convertido, com os tipos declarados
        else:
            _database_to_db(manager, tables, temp, progress, cancel)
    progress(len(tables), len(tables), "")
    return len(tables)


def _database_to_db(
    manager: DBManager, tables: list[str], out: Path, progress: Progress, cancel: threading.Event | None
) -> None:
    with manager.cursor() as cursor:
        if out.suffix.lower() == ".sqlite":
            load_sqlite_extension(cursor)
            cursor.execute(f"ATTACH {sql_string(str(out))} AS export_db (TYPE sqlite, READ_WRITE)")
        else:
            cursor.execute(f"ATTACH {sql_string(str(out))} AS export_db (READ_WRITE)")
        try:
            for done, table in enumerate(tables):
                _check(cancel)
                progress(done, len(tables), table)
                cursor.execute(f"CREATE TABLE export_db.{quote(table)} AS SELECT * FROM {quote(table)}")
        finally:
            # o ATTACH vale para todos os cursores do banco: soltar o arquivo mesmo em erro/cancelamento
            cursor.execute("DETACH export_db")


def _excel_value(value: object) -> object:
    # binario em hex; data antes de 1900 (o Excel nao representa) como texto ISO; resto que o Excel nao tem, texto
    if isinstance(value, (bytes, bytearray, memoryview)):
        return bytes(value).hex()
    if isinstance(value, date) and value.year < 1900:
        return value.isoformat(sep=" ") if isinstance(value, datetime) else value.isoformat()
    return value if value is None or isinstance(value, _EXCEL_TYPES) else str(value)


def _workbook(out: Path) -> xlsxwriter.Workbook:
    # constant_memory: cada linha vai para o disco; texto nunca vira formula nem link
    return xlsxwriter.Workbook(
        str(out),
        {
            "constant_memory": True,
            "strings_to_formulas": False,
            "strings_to_urls": False,
            "strings_to_numbers": False,
            "nan_inf_to_errors": True,
            "remove_timezone": True,
            "default_date_format": "yyyy-mm-dd hh:mm:ss",
        },
    )


def _write_sheets(
    book: xlsxwriter.Workbook,
    title: str,
    header: list[str],
    chunks: Iterable[list[tuple]],
    used: set[str],
    cancel: threading.Event | None,
) -> int:
    # tabela maior que uma aba continua em '<nome> (2)', '<nome> (3)', ...
    part, row, written = 1, 0, 0
    sheet = book.add_worksheet(sheet_name(title, part, used))
    sheet.write_row(0, 0, header)
    for chunk in chunks:
        _check(cancel)
        for values in chunk:
            if row == MAX_SHEET_ROWS:
                part, row = part + 1, 0
                sheet = book.add_worksheet(sheet_name(title, part, used))
                sheet.write_row(0, 0, header)
            row += 1
            sheet.write_row(row, 0, [_excel_value(v) for v in values])
        written += len(chunk)
    return written


def _chunks(cursor) -> Iterable[list[tuple]]:
    while rows := cursor.fetchmany(CHUNK):
        yield rows


def _database_to_xlsx(
    manager: DBManager, tables: list[str], out: Path, progress: Progress, cancel: threading.Event | None
) -> None:
    book = _workbook(out)
    used: set[str] = {"history"}  # nome reservado pelo Excel
    try:
        with manager.cursor() as cursor:
            for done, table in enumerate(tables):
                _check(cancel)
                progress(done, len(tables), table)
                cursor.execute(f"SELECT * FROM {quote(table)}")
                _write_sheets(book, table, [c[0] for c in cursor.description], _chunks(cursor), used, cancel)
    finally:
        book.close()


def export_result(
    manager: DBManager,
    query: str,
    title: str,
    out: Path,
    progress: Progress,
    cancel: threading.Event | None = None,
) -> int:
    """Grava o resultado de query (tabela atual ou SQL) em out (.csv UTF-8 com BOM ou .xlsx); devolve as linhas."""
    suffix = out.suffix.lower()
    if suffix not in RESULT_FORMATS:
        raise ValueError(tr("error.export_format", suffix=suffix))
    written = 0
    with _staged(out, cancel) as temp, manager.cursor() as cursor:
        cursor.execute(query)
        if cursor.description is None:
            raise ValueError(tr("error.no_rows"))
        header = [c[0] for c in cursor.description]

        def counted() -> Iterable[list[tuple]]:
            nonlocal written
            for rows in _chunks(cursor):
                yield rows
                written += len(rows)
                progress(written, 0, tr("export.rows", count=num(written)))

        if suffix == ".csv":
            # utf-8-sig: BOM para o Excel reconhecer UTF-8
            with open(temp, "w", encoding="utf-8-sig", newline="") as handle:
                writer = csv.writer(handle)
                writer.writerow(header)
                for rows in counted():
                    _check(cancel)
                    writer.writerows([[v.hex() if isinstance(v, bytes) else v for v in r] for r in rows])
        else:
            book = _workbook(temp)
            try:
                _write_sheets(book, title, header, counted(), {"history"}, cancel)
            finally:
                book.close()
    return written
