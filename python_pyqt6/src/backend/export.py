# Exportacao: banco inteiro ou uma lista de consultas para .duckdb, .sqlite ou .xlsx (uma tabela/aba por item) ou
# para uma pasta de .csv; tabela/consulta para .csv ou .xlsx
# !T: Runs in a worker thread; progress(done, total, text) reports, cancel (threading.Event) stops between chunks
# !T: and only the temporary file is deleted; the target is replaced only when the export finished

import csv
import os
import re
import shutil
import sqlite3
import threading
import uuid
from contextlib import contextmanager
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from pathlib import Path
from typing import Any, Callable, Iterable, Iterator, Sequence

import xlsxwriter

from backend.access import quote
from backend.db_manager import DBManager, sql_string
from shared.i18n import num, tr

Progress = Callable[[int, int, str], None]
Sheet = tuple[str, str, Sequence[Any]]  # (nome da aba, da tabela ou do arquivo; consulta; parametros)
MAX_SHEET_ROWS = 1_048_575  # linhas de dados por aba: 1.048.576 do Excel menos o cabecalho
MAX_SHEET_NAME = 31
MAX_COLUMN_WIDTH = 80  # caracteres: um Memo longo nao vira uma coluna da largura da tela inteira
CHUNK = 5_000
_BAD_SHEET_CHARS = re.compile(r"[\[\]:*?/\\]")
_BAD_FILE_CHARS = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
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


def _refuse_open(manager: DBManager, out: Path) -> None:
    # nunca por cima do arquivo aberto nem do SQLite temporario convertido do Access
    reading = [Path(path).resolve() for path in (manager.current_db, manager.converted) if path]
    if out.resolve() in reading:
        raise ValueError(tr("error.export_self"))


def export_database(
    manager: DBManager, out: Path, progress: Progress, cancel: threading.Event | None = None
) -> int:
    """Grava todas as tabelas em out (.duckdb, .sqlite ou .xlsx); devolve o numero de tabelas."""
    tables = manager.list_tables()
    if out.suffix.lower() != ".sqlite" or manager.converted is None:
        return export_sheets(manager, [(t, f"SELECT * FROM {quote(t)}", ()) for t in tables], out, progress, cancel)
    _refuse_open(manager, out)
    with _staged(out, cancel) as temp:
        shutil.copyfile(manager.converted, temp)  # Access: o SQLite ja convertido, com os tipos declarados
    progress(len(tables), len(tables), "")
    return len(tables)


def export_sheets(
    manager: DBManager, sheets: Sequence[Sheet], out: Path, progress: Progress, cancel: threading.Event | None = None
) -> int:
    """Grava o resultado de cada (nome, consulta, parametros) em out: .xlsx (uma aba por item), .sqlite ou .duckdb
    (uma tabela por item); devolve o numero de itens."""
    suffix = out.suffix.lower()
    if suffix not in DATABASE_FORMATS:
        raise ValueError(tr("error.export_format", suffix=suffix))
    _refuse_open(manager, out)
    with _staged(out, cancel) as temp:
        if suffix == ".xlsx":
            _sheets_to_xlsx(manager, sheets, temp, progress, cancel)
        else:
            _sheets_to_db(manager, sheets, temp, progress, cancel)
    progress(len(sheets), len(sheets), "")
    return len(sheets)


def csv_name(name: str) -> str:
    """Nome do arquivo .csv de uma tabela ou aba (caracteres que o Windows nao aceita viram _)."""
    return _BAD_FILE_CHARS.sub("_", name).rstrip(". ") + ".csv"


def export_csv_folder(
    manager: DBManager, sheets: Sequence[Sheet], folder: Path, progress: Progress,
    cancel: threading.Event | None = None,
) -> int:
    """Um <nome>.csv por item em folder (cada um so troca o existente quando termina); devolve o numero de itens."""
    for done, (name, query, params) in enumerate(sheets):
        _check(cancel)
        progress(done, len(sheets), name)
        export_result(manager, query, name, folder / csv_name(name), lambda *_args: None, cancel, params)
    progress(len(sheets), len(sheets), "")
    return len(sheets)


def table_schema_query(table: str) -> tuple[str, list[Any]]:
    """Schema da tabela como na aba Schema: Coluna, Tipo, Aceita nulo (Sim/Nao no idioma da tela)."""
    names = [quote(tr(key)) for key in ("schema.column", "schema.type", "schema.nullable")]
    return (f'SELECT name AS {names[0]}, type AS {names[1]}, CASE WHEN "notnull" THEN ? ELSE ? END AS {names[2]}'
            " FROM pragma_table_info(?)", [tr("schema.no"), tr("schema.yes"), table])


def database_schema_query(tables: Sequence[str]) -> tuple[str, list[Any]]:
    """Schema do banco: Tabela, Coluna, Tipo, Aceita nulo, na ordem da lista de tabelas e das colunas."""
    names = [quote(tr(key)) for key in ("tables.column_table", "schema.column", "schema.type", "schema.nullable")]
    return (f"SELECT table_name AS {names[0]}, column_name AS {names[1]}, data_type AS {names[2]},"
            f" CASE WHEN is_nullable = 'YES' THEN ? ELSE ? END AS {names[3]} FROM information_schema.columns"
            " WHERE table_catalog = current_database() AND table_schema = current_schema()"
            " ORDER BY list_position(?, table_name), ordinal_position", [tr("schema.yes"), tr("schema.no"), list(tables)])


def _sheets_to_db(
    manager: DBManager, sheets: Sequence[Sheet], out: Path, progress: Progress, cancel: threading.Event | None
) -> None:
    if out.suffix.lower() == ".sqlite":
        _sheets_to_sqlite(manager, sheets, out, progress, cancel)
        return
    with manager.cursor() as cursor:
        cursor.execute(f"ATTACH {sql_string(str(out))} AS export_db (READ_WRITE)")
        try:
            for done, (name, query, params) in enumerate(sheets):
                _check(cancel)
                progress(done, len(sheets), name)
                cursor.execute(f"CREATE TABLE export_db.{quote(name)} AS SELECT * FROM ({query})", list(params))
        finally:
            # o ATTACH vale para todos os cursores do banco: soltar o arquivo mesmo em erro/cancelamento
            cursor.execute("DETACH export_db")


_SQLITE_KEPT = re.compile(r"(?:U?(?:TINY|SMALL|BIG|HUGE)?INT(?:EGER)?|DOUBLE|FLOAT|REAL|BOOLEAN|DATE|TIME|BLOB"
                          r"|DECIMAL\(\d+,\d+\))")


def _sqlite_type(kind: str) -> str:
    """Tipo declarado no SQLite para um tipo do DuckDB, como o Access convertido (BRIEF 19 c): o leitor do app (e
    outros programas) le de volta o mesmo tipo. O DuckDB gravaria DECIMAL e TIMESTAMP como texto e BOOLEAN como
    BIGINT."""
    kind = kind.upper()
    if _SQLITE_KEPT.fullmatch(kind):
        return kind
    return "DATETIME" if kind.startswith("TIMESTAMP") else "TEXT"


def _sqlite_value(value: object) -> object:
    # Decimal inteiro como int, com casas como texto exato (a coluna DECIMAL tem afinidade numerica); data e hora no
    # formato do Access convertido; o que o SQLite nao guarda (lista, intervalo, uuid...) como texto
    if isinstance(value, Decimal):
        return int(value) if value.is_finite() and value == value.to_integral_value() else str(value)
    if isinstance(value, datetime):
        return value.strftime("%Y-%m-%d %H:%M:%S")
    if isinstance(value, (date, time)):
        return value.isoformat()
    if isinstance(value, int) and not -(2**63) <= value < 2**63:
        return str(value)  # HUGEINT alem do inteiro do SQLite: texto exato
    if value is None or isinstance(value, (str, int, float, bytes)):
        return value
    return str(value)


def _sheets_to_sqlite(
    manager: DBManager, sheets: Sequence[Sheet], out: Path, progress: Progress, cancel: threading.Event | None
) -> None:
    # cada tabela com os tipos declarados da origem e os valores nas classes do SQLite (sqlite3 do Python, como a
    # conversao do Access)
    lite = sqlite3.connect(out)
    try:
        lite.execute("PRAGMA journal_mode = OFF")
        lite.execute("PRAGMA synchronous = OFF")
        with manager.cursor() as cursor:
            for done, (name, query, params) in enumerate(sheets):
                _check(cancel)
                progress(done, len(sheets), name)
                cursor.execute(query, list(params))
                columns = ", ".join(f"{quote(c[0])} {_sqlite_type(str(c[1]))}" for c in cursor.description)
                lite.execute(f"CREATE TABLE {quote(name)} ({columns})")
                insert = f"INSERT INTO {quote(name)} VALUES ({', '.join('?' * len(cursor.description))})"
                for rows in _chunks(cursor):
                    _check(cancel)
                    lite.executemany(insert, [tuple(_sqlite_value(v) for v in row) for row in rows])
        lite.commit()
    finally:
        lite.close()


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


def _cell_width(value: object) -> int:
    """Largura do texto da celula em caracteres, como o Excel mostra (data e hora: 19; numero: os digitos)."""
    if isinstance(value, str):
        return len(value)
    if isinstance(value, datetime):
        return 19
    if isinstance(value, date):
        return 10
    if isinstance(value, float):
        return min(len(repr(value)), 12)  # o formato Geral mostra no maximo ~11 digitos
    return 0 if value is None else len(str(value))


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
    sheets = [sheet]
    sheet.write_row(0, 0, header)
    # largura de cada coluna pelo conteudo (best fit, BRIEF 19 g); o autofit do xlsxwriter nao funciona com
    # constant_memory, entao a largura e medida enquanto as linhas passam
    widths = [len(str(name)) for name in header]
    for chunk in chunks:
        _check(cancel)
        for values in chunk:
            if row == MAX_SHEET_ROWS:
                part, row = part + 1, 0
                sheet = book.add_worksheet(sheet_name(title, part, used))
                sheets.append(sheet)
                sheet.write_row(0, 0, header)
            row += 1
            cells = [_excel_value(v) for v in values]
            for index, value in enumerate(cells):
                width = _cell_width(value)
                if width > widths[index]:
                    widths[index] = width
            sheet.write_row(row, 0, cells)
        written += len(chunk)
    for each in sheets:
        for index, width in enumerate(widths):
            each.set_column(index, index, min(width, MAX_COLUMN_WIDTH) + 2)  # + margem: o texto nunca encosta
    return written


def _chunks(cursor) -> Iterable[list[tuple]]:
    while rows := cursor.fetchmany(CHUNK):
        yield rows


def _sheets_to_xlsx(
    manager: DBManager, sheets: Sequence[Sheet], out: Path, progress: Progress, cancel: threading.Event | None
) -> None:
    book = _workbook(out)
    used: set[str] = {"history"}  # nome reservado pelo Excel
    try:
        with manager.cursor() as cursor:
            for done, (name, query, params) in enumerate(sheets):
                _check(cancel)
                progress(done, len(sheets), name)
                cursor.execute(query, list(params))
                _write_sheets(book, name, [c[0] for c in cursor.description], _chunks(cursor), used, cancel)
    finally:
        book.close()


def export_result(
    manager: DBManager,
    query: str,
    title: str,
    out: Path,
    progress: Progress,
    cancel: threading.Event | None = None,
    params: Sequence[Any] = (),
) -> int:
    """Grava o resultado de query (tabela atual ou SQL) em out (.csv UTF-8 com BOM ou .xlsx); devolve as linhas.

    params: valores dos ? de query (tabela com a pesquisa e os filtros: so as linhas encontradas)
    """
    suffix = out.suffix.lower()
    if suffix not in RESULT_FORMATS:
        raise ValueError(tr("error.export_format", suffix=suffix))
    written = 0
    with _staged(out, cancel) as temp, manager.cursor() as cursor:
        cursor.execute(query, list(params))
        if cursor.description is None:
            raise ValueError(tr("error.no_rows"))
        header = [c[0] for c in cursor.description]

        def counted() -> Iterable[list[tuple]]:
            nonlocal written
            for rows in _chunks(cursor):
                yield rows
                written += len(rows)
                progress(written, 0, tr("export.rows_one" if written == 1 else "export.rows", count=num(written)))

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
