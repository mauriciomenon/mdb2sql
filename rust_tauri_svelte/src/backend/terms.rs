// NIVEL BASICO: Pesquisa de termos (aba Termos): acha, em todas as colunas das tabelas do escopo, as linhas com uma
// celula igual a um termo (valor inteiro) ou que contem um termo. A celula entra como texto (CAST para VARCHAR);
// maiusculas e espacos nas pontas nao contam. Serve para qualquer banco e qualquer tabela.
//
// NIVEL TECNICO: runs in the engine, on a connection of its own (a clone of the session one). The terms go to a
// temporary table and each table of the scope gets one statement that stores its hit rows in a temporary table
// "mdb2sql hit <table>": the term, then the table columns, in the order of the pasted terms and then of the table.
// The grid, the copy and the report read those tables, so nothing is searched twice. Temporary tables belong to
// the connection: the open file and the session copy never change.

use super::db_manager::{ColumnSchema, SqlResult, all_columns, has_rowid, ident, is_number, rows_to_json, table_info};
use duckdb::Connection;
use serde::Serialize;

const TERMS: &str = "\"mdb2sql terms\""; // (ord INTEGER, term VARCHAR): os termos na ordem colada
const KEYS: &str = "\"mdb2sql keys\""; // (ord INTEGER, key VARCHAR): chaves do valor inteiro de cada termo (texto e numero)
const ORD: &str = "\"mdb2sql ord\"";
const RID: &str = "\"mdb2sql rid\"";

fn hit_name(table: &str) -> String {
    format!("mdb2sql hit {table}")
}

// NIVEL BASICO: Leituras de numero do TERMO (secoes 13 a e 20, regra frouxa: ha dados em formato EUA e BR/Europa), as
// mesmas do Python: ponto decimal com virgula de milhar (mdb2sql_n1) e virgula decimal com ponto de milhar (mdb2sql_n2),
// milhar so em grupos de exatamente 3 digitos. 1.234,5 e 1,234.5 = 1234.5; 1.234.567 = 1234567; 1,234 = 1234 ou 1.234;
// 216,0 = 216 (nunca 2160); 0,1 = 0.1 (nunca 1); 12,34,567 nao e numero. A leitura que nao cabe e NULL. mdb2sql_key = a
// chave 'n:' do valor (o numero escrito pelo DuckDB a partir do DOUBLE: 216, 216.0 e 216,0 dao "216.0")
const NUMBER_READINGS: &str = "CREATE OR REPLACE TEMP MACRO mdb2sql_n1(s) AS CASE \
     WHEN regexp_full_match(s, '[+-]?(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:[.][0-9]+)?') THEN replace(s, ',', '') END; \
   CREATE OR REPLACE TEMP MACRO mdb2sql_n2(s) AS CASE \
     WHEN regexp_full_match(s, '[+-]?(?:[0-9]+|[0-9]{1,3}(?:[.][0-9]{3})+)(?:,[0-9]+)?') \
     THEN replace(replace(s, '.', ''), ',', '.') END; \
   CREATE OR REPLACE TEMP MACRO mdb2sql_key(x) AS 'n:' || CAST(TRY_CAST(x AS DOUBLE) AS VARCHAR);";

// chaves dos termos: o texto e as leituras de numero (NULL, de termo que nao e numero, fica de fora)
fn term_keys() -> String {
    let reading = |n: &str| format!("SELECT ord, mdb2sql_key({n}(trim(term))) AS key FROM {TERMS} WHERE key IS NOT NULL");
    format!("SELECT ord, 't:' || lower(trim(term)) AS key FROM {TERMS} UNION ALL {} UNION ALL {}", reading("mdb2sql_n1"), reading("mdb2sql_n2"))
}

// NIVEL BASICO: Chaves de uma celula no valor inteiro: 't:' + o texto; com termo numerico, a coluna NUMERICA do schema
// tambem pelo valor. Coluna de texto e texto: nada de ler numero dentro da celula (secao 20; a leitura frouxa de virgula e
// ponto e so do termo)
// shortcut: the value goes through DOUBLE, so integers above 2^53 that differ only past that precision match the same
// term; compare them as text if such ids ever need it
fn cell_keys(column: &str, kind: &str, numbers: bool) -> String {
    let key = format!("'t:' || lower(trim(CAST({column} AS VARCHAR)))");
    if numbers && is_number(kind) {
        format!("[{key}, 'n:' || CAST(CAST({column} AS DOUBLE) AS VARCHAR)]")
    } else {
        format!("[{key}]")
    }
}

// NIVEL BASICO: Um termo achado numa tabela: posicao do termo na lista, tabela e quantas linhas
#[derive(Debug, PartialEq, Serialize)]
pub struct TermHit {
    pub ord: usize,
    pub table: String,
    pub count: i64,
}

// NIVEL BASICO: Pesquisa `terms` (sem repetidos, ja sem espacos nas pontas) nas tabelas `tables`, na ordem delas.
// whole: valor inteiro (a celula e o termo); senao contem. Devolve cada termo x tabela com acerto; o que nao aparece
// nao foi encontrado. progress(feitas, total, tabela) roda antes de cada tabela e devolve Err para cancelar
// NIVEL TECNICO: whole value unnests the cells of each row and hash-joins them with the terms (the time does not grow
// with the number of terms); contains joins the row text (cells joined by a line break, which a term never has) with
// every term. A row found by two terms is stored twice, once per term.
pub fn search(
    conn: &Connection,
    terms: &[String],
    whole: bool,
    tables: &[String],
    progress: &mut dyn FnMut(usize, usize, &str) -> Result<(), String>,
) -> Result<Vec<TermHit>, String> {
    let run = |sql: &str| conn.execute_batch(sql).map_err(|e| e.to_string());
    run(&format!(
        "CREATE TEMP TABLE {TERMS} (ord INTEGER, term VARCHAR); BEGIN TRANSACTION"
    ))?;
    {
        let mut insert = conn.prepare(&format!("INSERT INTO {TERMS} VALUES (?, ?)")).map_err(|e| e.to_string())?;
        for (ord, term) in terms.iter().enumerate().filter(|(_, term)| !term.trim().is_empty()) {
            insert.execute(duckdb::params![ord as i64, term]).map_err(|e| e.to_string())?;
        }
    }
    run("COMMIT")?;
    // valor inteiro: chaves 't:' + o texto e, de termo ou celula que se le como numero, 'n:' + cada leitura dele
    run(&format!("{NUMBER_READINGS} CREATE TEMP TABLE {KEYS} AS {}", term_keys()))?;
    let numbers = whole
        && conn
            .query_row(&format!("SELECT count(*) > 0 FROM {KEYS} WHERE starts_with(key, 'n:')"), [], |row| row.get::<_, bool>(0))
            .map_err(|e| e.to_string())?;
    let (catalog, schema): (String, String) = conn
        .query_row("SELECT current_database(), current_schema()", [], |row| Ok((row.get(0)?, row.get(1)?)))
        .map_err(|e| e.to_string())?;
    let columns = all_columns(conn)?;
    let mut hits = Vec::new();
    for (i, table) in tables.iter().enumerate() {
        progress(i, tables.len(), table)?;
        let Some(cols) = columns.get(table).filter(|cols| !cols.is_empty()) else {
            continue;
        };
        let names: Vec<String> = cols.iter().map(|(name, _)| name.clone()).collect();
        let text = |column: &String| format!("CAST({} AS VARCHAR)", ident(column));
        // identidade da linha so dentro deste comando: o rowid; sem ele (view), a ordem de leitura, guardada
        // (MATERIALIZED) para as duas leituras verem a mesma
        let (rid, kept) = if has_rowid(conn, table, &names) { ("rowid", "") } else { ("row_number() OVER ()", "MATERIALIZED ") };
        let (cell, hit) = if whole {
            // sem termo numerico, so o texto (o custo de antes); com ele, as celulas numericas pelo valor e as de texto
            // tambem pelas leituras de numero delas
            let cells: Vec<String> = cols.iter().map(|(c, kind)| cell_keys(&ident(c), kind, numbers)).collect();
            (format!("unnest(flatten([{}]))", cells.join(", ")), format!("SELECT DISTINCT k.ord, c.rid FROM cell c JOIN {KEYS} k ON c.cell = k.key"))
        } else {
            let cells: Vec<String> = names.iter().map(text).collect();
            (
                format!("lower(concat_ws(chr(10), {}))", cells.join(", ")),
                format!("SELECT k.ord, c.rid FROM cell c JOIN {TERMS} k ON contains(c.cell, lower(trim(k.term)))"),
            )
        };
        let name = ident(&hit_name(table));
        run(&format!(
            "CREATE TEMP TABLE {name} AS WITH base AS {kept}(SELECT {rid} AS {RID}, * FROM {}.{}.{}), \
             cell AS (SELECT {RID} AS rid, {cell} AS cell FROM base), hit AS ({hit}) \
             SELECT hit.ord AS {ORD}, base.* FROM hit JOIN base ON base.{RID} = hit.rid ORDER BY hit.ord, hit.rid",
            ident(&catalog),
            ident(&schema),
            ident(table)
        ))
        .map_err(|e| format!("{table}: {e}"))?;
        let found: Vec<(i64, i64)> = conn
            // cada linha conta uma vez, no primeiro termo que a achou (a tela e o relatorio mostram cada linha uma vez);
            // termo que so achou linhas ja contadas vem com 0 (foi encontrado)
            .prepare(&format!(
                "SELECT {ORD}, count(*) FILTER (WHERE n = 1) FROM (SELECT {ORD}, row_number() OVER (PARTITION BY {RID} ORDER BY {ORD}) AS n \
                 FROM {name}) GROUP BY 1 ORDER BY 1"
            ))
            .and_then(|mut stmt| stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?.collect())
            .map_err(|e| format!("{table}: {e}"))?;
        if found.is_empty() {
            run(&format!("DROP TABLE {name}"))?;
        }
        for (ord, count) in found {
            hits.push(TermHit { ord: ord as usize, table: table.clone(), count });
        }
    }
    Ok(hits)
}

// colunas da tabela achada (sem as duas internas) e o SELECT das linhas dela: so as colunas da tabela, com os titulos e
// os tipos dela; cada linha uma vez, na ordem do primeiro termo que a achou e depois na da tabela (secao 19 d)
fn hit_select(conn: &Connection, table: &str) -> Result<(Vec<ColumnSchema>, String), String> {
    let mut columns = table_info(conn, &hit_name(table))?;
    columns.drain(..2.min(columns.len()));
    let select = format!(
        "SELECT * EXCLUDE ({ORD}, {RID}) FROM {} QUALIFY row_number() OVER (PARTITION BY {RID} ORDER BY {ORD}) = 1 ORDER BY {ORD}, {RID}",
        ident(&hit_name(table))
    );
    Ok((columns, select))
}

// NIVEL BASICO: Linhas achadas de uma tabela (grade da Pesquisa Avancada e Copiar as linhas encontradas): ate `limit`
pub fn rows(conn: &Connection, table: &str, limit: usize) -> Result<SqlResult, String> {
    let (columns, select) = hit_select(conn, table)?;
    let mut stmt = conn.prepare(&select).map_err(|e| e.to_string())?;
    let mut rows = stmt.query([]).map_err(|e| e.to_string())?;
    let names = rows.as_ref().map(|s| s.column_names()).unwrap_or_default();
    let (rows, truncated) = rows_to_json(&mut rows, &names, limit)?;
    Ok(SqlResult { columns, rows, truncated })
}

// NIVEL BASICO: Prepara o relatorio da ultima pesquisa: uma view temporaria por tabela com acerto, com o nome da tabela
// (aba do Excel, tabela do SQLite/DuckDB ou arquivo CSV), com as linhas achadas e so as colunas originais. Sem aba de
// resumo (secao 19 d). Devolve os nomes, na ordem das abas
// NIVEL TECNICO: temporary views come first in name lookup, so the writers of export.rs read them by plain name
pub fn report(conn: &Connection, tables: &[String]) -> Result<Vec<String>, String> {
    let mut sql = String::new();
    for table in tables {
        sql += &format!("CREATE OR REPLACE TEMP VIEW {} AS {};", ident(table), hit_select(conn, table)?.1);
    }
    conn.execute_batch(&sql).map_err(|e| e.to_string())?;
    Ok(tables.to_vec())
}
