// NIVEL BASICO: Pesquisa de termos (aba Termos): acha, em todas as colunas das tabelas do escopo, as linhas com uma
// celula igual a um termo (valor inteiro) ou que contem um termo. A celula entra como texto (CAST para VARCHAR);
// maiusculas e espacos nas pontas nao contam. Serve para qualquer banco e qualquer tabela.
//
// NIVEL TECNICO: runs in the engine, on a connection of its own (a clone of the session one). The terms go to a
// temporary table and each table of the scope gets one statement that stores its hit rows in a temporary table
// "mdb2sql hit <table>": the term, then the table columns, in the order of the pasted terms and then of the table.
// The grid, the copy and the report read those tables, so nothing is searched twice. Temporary tables belong to
// the connection: the open file and the session copy never change.

use super::db_manager::{ColumnSchema, SqlResult, all_columns, has_rowid, ident, literal, rows_to_json, table_info};
use duckdb::Connection;
use serde::Serialize;

const TERMS: &str = "\"mdb2sql terms\""; // (ord INTEGER, term VARCHAR): os termos na ordem colada
const COUNTS: &str = "\"mdb2sql counts\""; // (ord INTEGER, tbl VARCHAR, n BIGINT): linhas de cada termo em cada tabela
const ORD: &str = "\"mdb2sql ord\"";
const TERM: &str = "\"mdb2sql term\"";
const RID: &str = "\"mdb2sql rid\"";

fn hit_name(table: &str) -> String {
    format!("mdb2sql hit {table}")
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
        "CREATE TEMP TABLE {TERMS} (ord INTEGER, term VARCHAR); CREATE TEMP TABLE {COUNTS} (ord INTEGER, tbl VARCHAR, n BIGINT); \
         BEGIN TRANSACTION"
    ))?;
    {
        let mut insert = conn.prepare(&format!("INSERT INTO {TERMS} VALUES (?, ?)")).map_err(|e| e.to_string())?;
        for (ord, term) in terms.iter().enumerate().filter(|(_, term)| !term.trim().is_empty()) {
            insert.execute(duckdb::params![ord as i64, term]).map_err(|e| e.to_string())?;
        }
    }
    run("COMMIT")?;
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
        let cols: Vec<String> = cols.iter().map(|(name, _)| name.clone()).collect();
        let cols = &cols;
        let text = |column: &String| format!("CAST({} AS VARCHAR)", ident(column));
        // identidade da linha so dentro deste comando: o rowid; sem ele (view), a ordem de leitura, guardada
        // (MATERIALIZED) para as duas leituras verem a mesma
        let (rid, kept) = if has_rowid(conn, table, cols) { ("rowid", "") } else { ("row_number() OVER ()", "MATERIALIZED ") };
        let (cell, hit) = if whole {
            let cells: Vec<String> = cols.iter().map(|c| format!("lower(trim({}))", text(c))).collect();
            (format!("unnest([{}])", cells.join(", ")), format!("SELECT DISTINCT k.ord, c.rid FROM cell c JOIN {TERMS} k ON c.cell = lower(trim(k.term))"))
        } else {
            let cells: Vec<String> = cols.iter().map(text).collect();
            (
                format!("lower(concat_ws(chr(10), {}))", cells.join(", ")),
                format!("SELECT k.ord, c.rid FROM cell c JOIN {TERMS} k ON contains(c.cell, lower(trim(k.term)))"),
            )
        };
        let name = ident(&hit_name(table));
        run(&format!(
            "CREATE TEMP TABLE {name} AS WITH base AS {kept}(SELECT {rid} AS {RID}, * FROM {}.{}.{}), \
             cell AS (SELECT {RID} AS rid, {cell} AS cell FROM base), hit AS ({hit}) \
             SELECT hit.ord AS {ORD}, k.term AS {TERM}, base.* EXCLUDE ({RID}) FROM hit JOIN {TERMS} k ON k.ord = hit.ord \
             JOIN base ON base.{RID} = hit.rid ORDER BY hit.ord, hit.rid",
            ident(&catalog),
            ident(&schema),
            ident(table)
        ))
        .map_err(|e| format!("{table}: {e}"))?;
        let found: Vec<(i64, i64)> = conn
            .prepare(&format!("SELECT {ORD}, count(*) FROM {name} GROUP BY 1 ORDER BY 1"))
            .and_then(|mut stmt| stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?.collect())
            .map_err(|e| format!("{table}: {e}"))?;
        if found.is_empty() {
            run(&format!("DROP TABLE {name}"))?;
        }
        for (ord, count) in found {
            run(&format!("INSERT INTO {COUNTS} VALUES ({ord}, {}, {count})", literal(table)))?;
            hits.push(TermHit { ord: ord as usize, table: table.clone(), count });
        }
    }
    Ok(hits)
}

// titulo da coluna do termo; se a tabela ja tem uma coluna com esse nome, ganha "_" ate nao repetir
fn term_label(label: &str, columns: &[ColumnSchema]) -> String {
    let mut label = label.to_string();
    while columns.iter().any(|column| column.name.eq_ignore_ascii_case(&label)) {
        label.push('_');
    }
    label
}

// colunas da tabela achada (sem as duas internas) e o SELECT das linhas dela: o termo, com o titulo `label`, e depois
// as colunas da tabela, na ordem em que foram guardadas (termo, depois tabela)
fn hit_select(conn: &Connection, table: &str, label: &str) -> Result<(Vec<ColumnSchema>, String), String> {
    let mut columns = table_info(conn, &hit_name(table))?;
    columns.drain(..2.min(columns.len()));
    let label = term_label(label, &columns);
    let select = format!("SELECT {TERM} AS {}, * EXCLUDE ({ORD}, {TERM}) FROM {}", ident(&label), ident(&hit_name(table)));
    columns.insert(0, ColumnSchema { name: label, col_type: "VARCHAR".to_string(), null: "NO".to_string() });
    Ok((columns, select))
}

// NIVEL BASICO: Linhas achadas de uma tabela (grade da aba Termos e Copiar as linhas encontradas): ate `limit`
pub fn rows(conn: &Connection, table: &str, label: &str, limit: usize) -> Result<SqlResult, String> {
    let (columns, select) = hit_select(conn, table, label)?;
    let mut stmt = conn.prepare(&select).map_err(|e| e.to_string())?;
    let mut rows = stmt.query([]).map_err(|e| e.to_string())?;
    let names = rows.as_ref().map(|s| s.column_names()).unwrap_or_default();
    let (rows, truncated) = rows_to_json(&mut rows, &names, limit)?;
    Ok(SqlResult { columns, rows, truncated })
}

// NIVEL BASICO: Nomes das abas do relatorio (e das tabelas no SQLite/DuckDB e dos arquivos CSV): o resumo, as tabelas
// com acerto e os nao encontrados. Resumo e nao encontrados ganham "_" se uma tabela achada ja tem o nome
pub fn report_names(tables: &[String], summary: &str, not_found: &str) -> Vec<String> {
    let unique = |name: &str| {
        let mut name = name.to_string();
        while tables.iter().any(|table| table.eq_ignore_ascii_case(&name)) {
            name.push('_');
        }
        name
    };
    std::iter::once(unique(summary)).chain(tables.iter().cloned()).chain([unique(not_found)]).collect()
}

// NIVEL BASICO: Prepara o relatorio da ultima pesquisa: views temporarias com os nomes de report_names e os titulos
// no idioma da tela. Resumo: uma linha por termo x tabela (termo nao encontrado: tabela vazia e 0 linhas); uma view por
// tabela com acerto (termo + colunas); nao encontrados (so o termo). labels = Termo, Situacao, Tabela, Linhas,
// Encontrado, Nao encontrado, nome do resumo, nome dos nao encontrados. Devolve os nomes, na ordem das abas
// NIVEL TECNICO: temporary views come first in name lookup, so the writers of export.rs read them by plain name
pub fn report(conn: &Connection, tables: &[String], labels: &[String]) -> Result<Vec<String>, String> {
    let [term, status, table, rows, found, missing, summary, not_found] = labels else {
        return Err("Term report needs 8 labels".to_string());
    };
    let names = report_names(tables, summary, not_found);
    let view = |name: &str, select: &str| format!("CREATE OR REPLACE TEMP VIEW {} AS {select};", ident(name));
    let mut sql = view(
        &names[0],
        &format!(
            "SELECT k.term AS {}, CASE WHEN c.tbl IS NULL THEN {} ELSE {} END AS {}, coalesce(c.tbl, '') AS {}, coalesce(c.n, 0) AS {} \
             FROM {TERMS} k LEFT JOIN {COUNTS} c ON c.ord = k.ord ORDER BY k.ord, c.tbl",
            ident(term),
            literal(missing),
            literal(found),
            ident(status),
            ident(table),
            ident(rows)
        ),
    );
    for table in tables {
        sql += &view(table, &hit_select(conn, table, term)?.1);
    }
    sql += &view(
        &names[names.len() - 1],
        &format!("SELECT term AS {} FROM {TERMS} WHERE ord NOT IN (SELECT ord FROM {COUNTS}) ORDER BY ord", ident(term)),
    );
    conn.execute_batch(&sql).map_err(|e| e.to_string())?;
    Ok(names)
}
