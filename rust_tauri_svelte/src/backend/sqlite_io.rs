// NIVEL BASICO: SQLite pela biblioteca nativa (rusqlite, SQLite compilado dentro do exe)
// Abrir: copia as tabelas do arquivo SQLite para o DuckDB em memoria. Exportar: grava um SQLite novo.
//
// NIVEL TECNICO: the DuckDB sqlite extension would do both in SQL, but it is a 47 MB file that
// would have to ship inside the exe; rusqlite adds about 1.5 MB.

use super::db_manager::{ident, json_text, value_to_json};
use duckdb::types::{Value as DuckValue, ValueRef as DuckRef};
use rusqlite::types::{Value as LiteValue, ValueRef as LiteRef};
use rusqlite::{OpenFlags, params_from_iter};
use std::io::Read;
use std::path::Path;

// NIVEL BASICO: Arquivo comeca com o cabecalho do SQLite?
pub(crate) fn is_sqlite_file(path: &Path) -> bool {
    let mut magic = [0u8; 16];
    std::fs::File::open(path)
        .and_then(|mut f| f.read_exact(&mut magic))
        .is_ok_and(|_| &magic == b"SQLite format 3\0")
}

// NIVEL BASICO: Nomes de tipo que versoes antigas gravavam para guardar o numero exato como texto; so a leitura de
// arquivos antigos usa (hoje nada numerico vai como texto, secao 19 h)
const EXACT_AS_TEXT: [(&str, &str); 3] = [("TEXT_HUGE128", "HUGEINT"), ("TEXT_UHUGE128", "UHUGEINT"), ("TEXT_UBIG64", "UBIGINT")];

// (precisao, casas) de um DECIMAL(p,s) do DuckDB
fn decimal_parts(duck: &str) -> Option<(u32, u32)> {
    let args = duck.trim().to_ascii_uppercase().strip_prefix("DECIMAL(")?.strip_suffix(')')?.to_string();
    let (p, s) = args.split_once(',')?;
    Some((p.trim().parse().ok()?, s.trim().parse().ok()?))
}

// NIVEL BASICO: Tipo declarado no SQLite para uma coluna DuckDB e o que se le dela (secao 19 h: nada numerico chega ao
// SQLite como texto). DECIMAL com casas: declarado REAL_DECIMAL(p,s) (afinidade REAL; volta DECIMAL(p,s) na leitura) e
// gravado como REAL (CAST para DOUBLE); DECIMAL sem casas: INTEGER (ate 18 digitos) ou REAL; o resto com o nome do
// DuckDB (afinidade INTEGER, REAL ou NUMERIC)
fn lite_column(name: &str, duck: &str) -> (String, String) {
    match decimal_parts(duck) {
        Some((_, s)) if s > 0 => (format!("REAL_{}", duck.trim().to_ascii_uppercase()), format!("CAST({} AS DOUBLE)", ident(name))),
        Some((p, _)) if p <= 18 => (duck.to_string(), format!("CAST({} AS BIGINT)", ident(name))),
        Some(_) => (duck.to_string(), format!("CAST({} AS DOUBLE)", ident(name))),
        None => (duck.to_string(), ident(name)),
    }
}

// NIVEL BASICO: Tipo declarado no SQLite vira tipo do DuckDB (regras de afinidade do SQLite)
// NIVEL TECNICO: the exporter below declares DuckDB type names, so a round trip keeps them
pub(crate) fn duck_type(declared: &str) -> String {
    let d = declared.trim().to_ascii_uppercase();
    const SAME: [&str; 18] = [
        "BOOLEAN", "TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT", "UHUGEINT", "UTINYINT", "USMALLINT",
        "UINTEGER", "UBIGINT", "FLOAT", "DOUBLE", "DATE", "TIME", "TIMESTAMP", "BLOB", "VARCHAR",
    ];
    if SAME.contains(&d.as_str()) {
        return d;
    }
    if let Some(&(_, duck)) = EXACT_AS_TEXT.iter().find(|(lite, _)| *lite == d) {
        return duck.to_string();
    }
    // TEXT_DECIMAL(p,s): exato como texto; REAL_DECIMAL(p,s): numero (REAL); os dois voltam DECIMAL(p,s)
    if let Some(decimal) = d.strip_prefix("TEXT_").or_else(|| d.strip_prefix("REAL_")) {
        return duck_type(decimal);
    }
    if (d.starts_with("DECIMAL(") || d.starts_with("NUMERIC(")) && d.ends_with(')') {
        let args: Vec<Option<u32>> = d[8..d.len() - 1].split(',').map(|a| a.trim().parse().ok()).collect();
        return match args.as_slice() {
            [Some(p)] if (1..=38).contains(p) => format!("DECIMAL({p},0)"),
            [Some(p), Some(s)] if (1..=38).contains(p) && s <= p => format!("DECIMAL({p},{s})"),
            _ => "DOUBLE".to_string(),
        };
    }
    if d.contains("BOOL") {
        "BOOLEAN"
    } else if d.contains("DATETIME") || d.starts_with("TIMESTAMP") {
        "TIMESTAMP"
    } else if d.contains("INT") {
        "BIGINT"
    } else if d.contains("CHAR") || d.contains("CLOB") || d.contains("TEXT") || d.is_empty() {
        "VARCHAR"
    } else if d.contains("BLOB") {
        "BLOB"
    } else if d.contains("REAL") || d.contains("FLOA") || d.contains("DOUB") || d.starts_with("NUMERIC") || d.starts_with("DECIMAL") {
        "DOUBLE"
    } else {
        "VARCHAR"
    }
    .to_string()
}

fn lite_to_duck(value: LiteRef, as_text: bool) -> DuckValue {
    match value {
        LiteRef::Null => DuckValue::Null,
        LiteRef::Integer(i) if as_text => DuckValue::Text(i.to_string()),
        LiteRef::Real(f) if as_text => DuckValue::Text(f.to_string()),
        LiteRef::Integer(i) => DuckValue::BigInt(i),
        LiteRef::Real(f) => DuckValue::Double(f),
        LiteRef::Text(t) => DuckValue::Text(String::from_utf8_lossy(t).into_owned()),
        LiteRef::Blob(b) => DuckValue::Blob(b.to_vec()),
    }
}

// NIVEL BASICO: Copia todas as tabelas do SQLite (aberto so para leitura) para o DuckDB em memoria
pub fn import(
    duck: &duckdb::Connection,
    path: &Path,
    progress: &mut dyn FnMut(usize, usize, &str),
) -> Result<(), String> {
    let lite = rusqlite::Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| format!("Failed to open SQLite: {e}"))?;
    let tables: Vec<String> = lite
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name")
        .and_then(|mut s| s.query_map([], |r| r.get(0))?.collect())
        .map_err(|e| format!("Failed to list SQLite tables: {e}"))?;
    for (i, table) in tables.iter().enumerate() {
        progress(i, tables.len(), table);
        // um valor que nao cabe no tipo declarado (SQLite aceita qualquer coisa) derruba a copia tipada;
        // nesse caso a tabela entra com todas as colunas como texto, sem perder linha
        if import_table(duck, &lite, table, false).is_err() {
            import_table(duck, &lite, table, true).map_err(|e| format!("{table}: {e}"))?;
        }
    }
    Ok(())
}

fn import_table(duck: &duckdb::Connection, lite: &rusqlite::Connection, table: &str, as_text: bool) -> Result<(), String> {
    let columns: Vec<(String, String)> = lite
        .prepare(&format!("PRAGMA table_info({})", ident(table)))
        .and_then(|mut s| s.query_map([], |r| Ok((r.get(1)?, r.get(2)?)))?.collect())
        .map_err(|e| e.to_string())?;
    let defs: Vec<String> = columns
        .iter()
        .map(|(name, decl)| format!("{} {}", ident(name), if as_text { "VARCHAR".into() } else { duck_type(decl) }))
        .collect();
    duck.execute_batch(&format!("DROP TABLE IF EXISTS {0}; CREATE TABLE {0} ({1})", ident(table), defs.join(", ")))
        .map_err(|e| e.to_string())?;

    let mut stmt = lite.prepare(&format!("SELECT * FROM {}", ident(table))).map_err(|e| e.to_string())?;
    let mut rows = stmt.query([]).map_err(|e| e.to_string())?;
    let mut appender = duck.appender(table).map_err(|e| e.to_string())?;
    while let Some(row) = rows.next().map_err(|e| e.to_string())? {
        let values: Vec<DuckValue> = (0..columns.len())
            .map(|i| row.get_ref(i).map(|v| lite_to_duck(v, as_text)))
            .collect::<Result<_, _>>()
            .map_err(|e| e.to_string())?;
        appender.append_row(duckdb::appender_params_from_iter(values)).map_err(|e| e.to_string())?;
    }
    appender.flush().map_err(|e| e.to_string())
}

// NIVEL BASICO: Valor do DuckDB para gravar no SQLite: numero como INTEGER ou REAL, nunca texto (secao 19 h); datas e
// horas como texto ISO. Os DECIMAL ja chegam como BIGINT ou DOUBLE (lite_column)
// shortcut: an integer beyond i64 goes as REAL (about 16 digits kept); store such ids as text only if a database ever
// needs them exact
fn duck_to_lite(value: DuckRef) -> LiteValue {
    match value {
        DuckRef::Null => LiteValue::Null,
        DuckRef::Boolean(b) => LiteValue::Integer(b.into()),
        DuckRef::TinyInt(i) => LiteValue::Integer(i.into()),
        DuckRef::SmallInt(i) => LiteValue::Integer(i.into()),
        DuckRef::Int(i) => LiteValue::Integer(i.into()),
        DuckRef::BigInt(i) => LiteValue::Integer(i),
        DuckRef::UTinyInt(i) => LiteValue::Integer(i.into()),
        DuckRef::USmallInt(i) => LiteValue::Integer(i.into()),
        DuckRef::UInt(i) => LiteValue::Integer(i.into()),
        DuckRef::UBigInt(i) => i64::try_from(i).map_or(LiteValue::Real(i as f64), LiteValue::Integer),
        DuckRef::HugeInt(i) => i64::try_from(i).map_or(LiteValue::Real(i as f64), LiteValue::Integer),
        DuckRef::UHugeInt(i) => i64::try_from(i).map_or(LiteValue::Real(i as f64), LiteValue::Integer),
        DuckRef::Float(f) => LiteValue::Real(f.into()),
        DuckRef::Double(f) => LiteValue::Real(f),
        DuckRef::Blob(b) => LiteValue::Blob(b.to_vec()),
        // data, hora e outros nao numericos: o texto mostrado
        other => LiteValue::Text(json_text(&value_to_json(other))),
    }
}


// NIVEL BASICO: Grava as tabelas num arquivo SQLite novo (path ainda nao existe)
// NIVEL TECNICO: the declared type is the DuckDB type name; SQLite derives the affinity from it
pub fn export(
    duck: &duckdb::Connection,
    tables: &[String],
    path: &Path,
    progress: &mut dyn FnMut(usize, usize, &str) -> Result<(), String>,
) -> Result<(), String> {
    let mut lite = rusqlite::Connection::open(path).map_err(|e| format!("Failed to create SQLite: {e}"))?;
    // uma transacao para o arquivo inteiro: um so commit (cada commit por tabela custava um fsync; 287 tabelas no DB4)
    let tx = lite.transaction().map_err(|e| e.to_string())?;
    for (i, table) in tables.iter().enumerate() {
        progress(i, tables.len(), table)?;
        let mut stmt = duck
            .prepare(&format!("PRAGMA table_info({})", ident(table)))
            .map_err(|e| e.to_string())?;
        let columns: Vec<(String, String)> = stmt
            .query_map([], |r| Ok((r.get(1)?, r.get(2)?)))
            .and_then(|rows| rows.collect())
            .map_err(|e| e.to_string())?;
        // tipo declarado e expressao lida do DuckDB, por coluna
        let mut defs = Vec::new();
        let mut reads = Vec::new();
        for (name, duck_type) in &columns {
            let (lite, read) = lite_column(name, duck_type);
            defs.push(format!("{} {lite}", ident(name)));
            reads.push(read);
        }
        let marks = vec!["?"; columns.len()].join(", ");

        tx.execute(&format!("CREATE TABLE {} ({})", ident(table), defs.join(", ")), [])
            .map_err(|e| format!("{table}: {e}"))?;
        {
            let mut insert = tx
                .prepare(&format!("INSERT INTO {} VALUES ({marks})", ident(table)))
                .map_err(|e| e.to_string())?;
            let mut select = duck
                .prepare(&format!("SELECT {} FROM {}", reads.join(", "), ident(table)))
                .map_err(|e| e.to_string())?;
            let mut rows = select.query([]).map_err(|e| e.to_string())?;
            let mut n = 0usize;
            while let Some(row) = rows.next().map_err(|e| e.to_string())? {
                let values: Vec<LiteValue> = (0..columns.len())
                    .map(|c| row.get_ref(c).map(duck_to_lite))
                    .collect::<Result<_, _>>()
                    .map_err(|e| e.to_string())?;
                insert.execute(params_from_iter(values)).map_err(|e| format!("{table}: {e}"))?;
                n += 1;
                if n.is_multiple_of(10_000) {
                    progress(i, tables.len(), table)?;
                }
            }
        }
    }
    tx.commit().map_err(|e| e.to_string())?;
    Ok(())
}
