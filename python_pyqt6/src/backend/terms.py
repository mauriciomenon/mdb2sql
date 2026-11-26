# Pesquisa de termos (aba Termos): uma lista colada (ex.: coluna do Excel) procurada em todas as colunas das tabelas,
# como texto. Valor inteiro: a celula sem espacos nas pontas e igual ao termo; Contem: a celula contem o termo; os dois
# sem diferenciar maiusculas. Tudo no motor (DuckDB), uma consulta por tabela.
# !T: The terms travel as a list parameter (no temporary table), so every query is self-contained: the grid, the
# !T: copy and the report re-run it. Hits keep the order of the pasted list, then the order of the table

import threading
from typing import Any, Callable, Sequence

from backend.access import quote
from backend.db_manager import DBManager
from backend.export import Cancelled, Sheet
from shared.i18n import tr

Progress = Callable[[int, int, str], None]
# termos na ordem colada: idx 1, 2, ... (generate_subscripts e unnest da mesma lista andam juntos)
_TERMS = "terms AS (SELECT generate_subscripts(?::VARCHAR[], 1) AS idx, unnest(?::VARCHAR[]) AS term)"
_ROW = "mdb2sql_row"  # posicao da linha na tabela (ordem da tabela)


def parse_terms(text: str) -> tuple[list[str], int]:
    """Termos da caixa: cada linha nao vazia, sem espacos nas pontas, na ordem; repetidos (sem diferenciar
    maiusculas, como a comparacao) entram uma vez. Devolve (termos, quantos repetidos sairam)."""
    terms: list[str] = []
    seen: set[str] = set()
    repeated = 0
    for line in text.splitlines():
        term = line.strip()
        if not term:
            continue
        if term.lower() in seen:
            repeated += 1
            continue
        seen.add(term.lower())
        terms.append(term)
    return terms, repeated


def _hits_cte(table: str, columns: Sequence[str], contains: bool) -> str:
    # hit(idx, linha): o termo idx achou a linha (uma vez, mesmo achado em varias colunas)
    cells = [f"CAST({quote(column)} AS VARCHAR)" for column in columns]
    source = f"src AS (SELECT row_number() OVER () AS {_ROW}, * FROM {quote(table)})"
    if contains:
        # !T: A term is one line, so it can never match across the line breaks that join the cells
        text = "lower(concat_ws(chr(10), " + ", ".join(cells) + "))"
        hit = f"hit AS (SELECT idx, {_ROW} FROM src, terms WHERE contains({text}, lower(term)))"
    else:
        keys = ", ".join(f"lower(trim({cell}))" for cell in cells)
        hit = (f"hit AS (SELECT DISTINCT idx, {_ROW} FROM (SELECT {_ROW}, unnest([{keys}]) AS cell FROM src)"
               " JOIN terms ON cell = lower(term))")
    return f"WITH {_TERMS}, {source}, {hit}"


def hits_query(table: str, columns: Sequence[str], terms: Sequence[str], contains: bool) -> tuple[str, list[Any]]:
    """As linhas achadas: coluna Termo (o termo que achou) + todas as colunas da tabela; ordem dos termos, depois a da
    tabela. Uma linha achada por 2 termos vem 2 vezes."""
    sql = (f"{_hits_cte(table, columns, contains)} SELECT terms.term AS {quote(tr('terms.column'))},"
           f" src.* EXCLUDE ({_ROW}) FROM hit JOIN terms USING (idx) JOIN src USING ({_ROW}) ORDER BY idx, {_ROW}")
    return sql, [list(terms), list(terms)]


def search_terms(manager: DBManager, terms: Sequence[str], contains: bool, tables: Sequence[str], progress: Progress,
                 cancel: threading.Event | None = None) -> dict[str, Any]:
    """Conta os acertos de cada termo em cada tabela. Devolve {"terms", "contains", "columns": {tabela: colunas},
    "hits": [(tabela, {posicao do termo: linhas})] so das tabelas com acerto, na ordem de `tables`}."""
    columns = manager.table_columns()
    hits = []
    for done, table in enumerate(tables):
        if cancel is not None and cancel.is_set():
            raise Cancelled()
        progress(done, len(tables), table)
        if not columns.get(table):
            continue
        sql = f"{_hits_cte(table, columns[table], contains)} SELECT idx, count(*) FROM hit GROUP BY idx"
        with manager.cursor() as cursor:
            counts = dict(cursor.execute(sql, [list(terms), list(terms)]).fetchall())
        if counts:
            hits.append((table, {idx - 1: count for idx, count in counts.items()}))
    progress(len(tables), len(tables), "")
    return {"terms": list(terms), "contains": contains, "columns": columns, "hits": hits}


def not_found(result: dict[str, Any]) -> list[str]:
    """Termos sem acerto em nenhuma tabela, na ordem colada."""
    found = {position for _table, counts in result["hits"] for position in counts}
    return [term for position, term in enumerate(result["terms"]) if position not in found]


def table_hits(result: dict[str, Any], table: str) -> tuple[str, list[Any]]:
    return hits_query(table, result["columns"][table], result["terms"], result["contains"])


def report_sheets(result: dict[str, Any]) -> list[Sheet]:
    """O relatorio: Resumo (Termo, Situacao, Tabela, Linhas: uma linha por termo x tabela; nao encontrado com Tabela
    vazia e 0), uma aba por tabela com acerto (Termo + colunas) e Nao encontrados (Termo)."""
    summary: list[list[Any]] = [[], [], [], []]
    for position, term in enumerate(result["terms"]):
        rows = [(table, counts[position]) for table, counts in result["hits"] if position in counts]
        for table, count in rows or [(None, 0)]:
            for values, value in zip(summary, (term, tr("terms.status_found" if rows else "terms.status_not_found"),
                                               table, count)):
                values.append(value)
    names = [quote(tr(key)) for key in ("terms.column", "terms.col_status", "terms.col_table", "terms.col_rows")]
    sheets: list[Sheet] = [(
        tr("terms.sheet_summary"),
        f"SELECT unnest(?::VARCHAR[]) AS {names[0]}, unnest(?::VARCHAR[]) AS {names[1]},"
        f" unnest(?::VARCHAR[]) AS {names[2]}, unnest(?::BIGINT[]) AS {names[3]}",
        summary,
    )]
    sheets += [(table, *table_hits(result, table)) for table, _counts in result["hits"]]
    sheets.append((tr("terms.sheet_not_found"), f"SELECT unnest(?::VARCHAR[]) AS {names[0]}", [not_found(result)]))
    return sheets
