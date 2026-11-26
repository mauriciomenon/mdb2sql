# Pesquisa de termos (aba Termos): uma lista colada (ex.: coluna do Excel) procurada em todas as colunas das tabelas,
# como texto. Valor inteiro: a celula sem espacos nas pontas e igual ao termo; Contem: a celula contem o termo; os dois
# sem diferenciar maiusculas. Tudo no motor (DuckDB), uma consulta por tabela.
# !T: The terms travel as a list parameter (no temporary table), so every query is self-contained: the grid, the
# !T: copy and the report re-run it. Hits keep the order of the pasted list, then the order of the table

import re
import threading
from typing import Any, Callable, Sequence

from backend.access import quote
from backend.db_manager import DBManager
from backend.export import Cancelled, Sheet

Progress = Callable[[int, int, str], None]
# termos na ordem colada: posicao 1, 2, ... (generate_subscripts e unnest da mesma lista andam juntos)
# !T: Names of our own columns are prefixed and every table column is qualified with src., so a table with columns
# !T: such as IDX or TERM is never ambiguous
_IDX, _TERM, _ROW = "mdb2sql_idx", "mdb2sql_term", "mdb2sql_row"  # _ROW: posicao da linha na tabela

# Valor inteiro com numeros, regra frouxa (ha dados em formato EUA e BR/Europa): termo e celula que se leem como numero
# casam quando alguma leitura de um e igual a alguma do outro. Um texto numerico tem ate duas leituras: ponto decimal
# com virgula de milhar e virgula decimal com ponto de milhar (milhar = grupos de 3 digitos). Com os dois separadores,
# so a leitura em que o ultimo e o decimal vale (1.234,5 e 1,234.5 = 1234.5); um separador repetido e de milhar
# (1.234.567); um separador so: as duas, quando cabem (1,234 = 1.234 ou 1234; 216,0 = 216, nunca 2160)
_DOT = r"[+-]?(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d+)?"
_COMMA = r"[+-]?(?:\d+|\d{1,3}(?:\.\d{3})+)(?:,\d+)?"
# celula de coluna numerica: o valor dela (uma leitura so)
_NUMERIC = re.compile(r"U?(?:TINY|SMALL|BIG|HUGE)?INT(?:EGER)?|FLOAT|DOUBLE|REAL|DECIMAL\(.*\)|NUMERIC.*", re.I)


def number_readings(text: str) -> set[float]:
    """As leituras numericas de um texto (vazio: nao e numero); as mesmas que _sql_readings faz no motor."""
    text, found = text.strip(), set()
    if re.fullmatch(_DOT, text):
        found.add(float(text.replace(",", "")))
    if re.fullmatch(_COMMA, text):
        found.add(float(text.replace(".", "").replace(",", ".")))
    return found


def _sql_readings(text: str) -> str:
    """SQL da lista de leituras numericas (DOUBLE) do texto `text` (uma expressao SQL)."""
    # list_distinct tira os NULL (a leitura que nao cabe) e a leitura repetida
    return (f"list_distinct([CASE WHEN regexp_full_match({text}, '{_DOT}') THEN TRY_CAST(replace({text}, ',', '')"
            f" AS DOUBLE) END, CASE WHEN regexp_full_match({text}, '{_COMMA}') THEN TRY_CAST(replace(replace({text},"
            " '.', ''), ',', '.') AS DOUBLE) END])")


_TERMS = (f"terms AS (SELECT {_IDX}, {_TERM}, {_sql_readings(f'trim({_TERM})')} AS mdb2sql_nums FROM"
          f" (SELECT generate_subscripts(?::VARCHAR[], 1) AS {_IDX}, unnest(?::VARCHAR[]) AS {_TERM}))")


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


def _hits_cte(table: str, columns: Sequence[str], contains: bool, numeric: Sequence[str] | None = None) -> str:
    # hit(termo, linha): o termo achou a linha (uma vez, mesmo achado em varias colunas). numeric: as colunas
    # numericas da tabela, quando algum termo e numero (None: nenhum termo e numero, so a comparacao de texto)
    cells = [f"CAST(src.{quote(column)} AS VARCHAR)" for column in columns]
    source = f"src AS (SELECT row_number() OVER () AS {_ROW}, * FROM {quote(table)})"
    if contains:
        # !T: A term is one line, so it can never match across the line breaks that join the cells
        text = "lower(concat_ws(chr(10), " + ", ".join(cells) + "))"
        hit = (f"hit AS (SELECT terms.{_IDX}, src.{_ROW} FROM src, terms"
               f" WHERE contains({text}, lower(terms.{_TERM})))")
        return f"WITH {_TERMS}, {source}, {hit}"
    keys = ", ".join(f"lower(trim({cell}))" for cell in cells)
    hit = (f"SELECT terms.{_IDX}, cells.{_ROW} FROM (SELECT src.{_ROW}, unnest([{keys}]) AS"
           f" mdb2sql_cell FROM src) cells JOIN terms ON cells.mdb2sql_cell = lower(terms.{_TERM})")
    if numeric is not None:
        # celula numerica: o valor dela; celula de texto: as leituras do texto; casa com qualquer leitura do termo
        readings = [f"[CAST(src.{quote(column)} AS DOUBLE)]" if column in numeric else _sql_readings(f"trim({cell})")
                    for column, cell in zip(columns, cells)]
        hit += (f" UNION SELECT terms.{_IDX}, nums.{_ROW} FROM (SELECT src.{_ROW}, unnest(flatten([{', '.join(readings)}]))"
                f" AS mdb2sql_num FROM src) nums JOIN (SELECT {_IDX}, unnest(mdb2sql_nums) AS mdb2sql_num FROM terms)"
                f" terms ON nums.mdb2sql_num = terms.mdb2sql_num")
    return f"WITH {_TERMS}, {source}, hit AS (SELECT DISTINCT * FROM ({hit}))"


def hits_query(table: str, columns: Sequence[str], terms: Sequence[str], contains: bool,
               numeric: Sequence[str] | None = None) -> tuple[str, list[Any]]:
    """As linhas achadas, cada uma uma vez, so com as colunas da tabela (nomes, ordem e tipos originais, nenhuma a
    mais: BRIEF 19 d); na ordem do primeiro termo que achou a linha, depois na da tabela."""
    sql = (f"{_hits_cte(table, columns, contains, numeric)} SELECT src.* EXCLUDE ({_ROW}) FROM"
           f" (SELECT {_ROW}, min({_IDX}) AS mdb2sql_first FROM hit GROUP BY {_ROW}) h"
           f" JOIN src ON src.{_ROW} = h.{_ROW} ORDER BY h.mdb2sql_first, h.{_ROW}")
    return sql, [list(terms), list(terms)]


def search_terms(manager: DBManager, terms: Sequence[str], contains: bool, tables: Sequence[str], progress: Progress,
                 cancel: threading.Event | None = None) -> dict[str, Any]:
    """Conta os acertos de cada termo em cada tabela. Devolve {"terms", "contains", "columns": {tabela: colunas},
    "numeric": {tabela: colunas numericas} ou None (nenhum termo e numero, ou Contem), "hits": [(tabela, {posicao do
    termo: linhas})] so das tabelas com acerto, na ordem de `tables`, "rows": {tabela: linhas achadas, cada uma uma
    vez}}."""
    columns = manager.table_columns()
    numeric = None
    if not contains and any(number_readings(term) for term in terms):  # so entao a regra dos numeros entra
        numeric = {table: [name for name, kind in types.items() if _NUMERIC.fullmatch(kind)]
                   for table, types in manager.column_types().items()}
    hits, rows = [], {}
    for done, table in enumerate(tables):
        if cancel is not None and cancel.is_set():
            raise Cancelled()
        progress(done, len(tables), table)
        if not columns.get(table):
            continue
        cte = _hits_cte(table, columns[table], contains, None if numeric is None else numeric.get(table, []))
        # por termo e, na mesma consulta, as linhas distintas (uma linha achada por 2 termos sai uma vez so)
        sql = f"{cte} SELECT {_IDX}, count(*), (SELECT count(DISTINCT {_ROW}) FROM hit) FROM hit GROUP BY {_IDX}"
        with manager.cursor() as cursor:
            found = cursor.execute(sql, [list(terms), list(terms)]).fetchall()
        if found:
            hits.append((table, {idx - 1: count for idx, count, _rows in found}))
            rows[table] = found[0][2]
    if cancel is not None and cancel.is_set():  # Cancelar durante a ultima tabela tambem e cancelar
        raise Cancelled()
    progress(len(tables), len(tables), "")
    return {"terms": list(terms), "contains": contains, "columns": columns, "numeric": numeric, "hits": hits,
            "rows": rows}


def not_found(result: dict[str, Any]) -> list[str]:
    """Termos sem acerto em nenhuma tabela, na ordem colada."""
    found = {position for _table, counts in result["hits"] for position in counts}
    return [term for position, term in enumerate(result["terms"]) if position not in found]


def table_hits(result: dict[str, Any], table: str) -> tuple[str, list[Any]]:
    numeric = result.get("numeric")
    return hits_query(table, result["columns"][table], result["terms"], result["contains"],
                      None if numeric is None else numeric.get(table, []))


def report_sheets(result: dict[str, Any]) -> list[Sheet]:
    """O relatorio: so uma aba (tabela, arquivo CSV) por tabela com acerto, com o nome dela: as linhas achadas com as
    colunas originais (sem coluna Termo nem aba de resumo: BRIEF 19 d)."""
    return [(table, *table_hits(result, table)) for table, _counts in result["hits"]]
