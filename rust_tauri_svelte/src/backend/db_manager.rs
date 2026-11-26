// NIVEL BASICO: Gerenciador do banco aberto em Rust
// Abre .accdb/.mdb, .sqlite/.sqlite3/.db e .duckdb, lista tabelas, executa queries
//
// NIVEL TECNICO: every format ends up in one in-memory DuckDB connection: a DuckDB file is
// ATTACHed READ_ONLY as "src" (and made current with USE), SQLite and Access tables are copied
// into the in-memory database. The rest of the app only sees DuckDB. Nothing the user does changes that copy:
// the SQL tab runs read commands only (see Probe).

use super::converted::{self, Converted};
use super::{access, sqlite_io};
use duckdb::types::ValueRef;
use duckdb::{Connection, Rows, ffi};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;

// NIVEL BASICO: Struct que representa schema de uma coluna
// NIVEL TECNICO: Serializable for JSON responses to frontend
#[derive(Debug, Serialize, Deserialize)]
pub struct ColumnSchema {
    pub name: String,
    #[serde(rename = "type")]
    pub col_type: String,
    pub null: String,
}

// NIVEL BASICO: Resultado do SQL livre: colunas, linhas (ate o limite) e se havia mais linhas
#[derive(Debug, Serialize)]
pub struct SqlResult {
    pub columns: Vec<ColumnSchema>,
    pub rows: Vec<serde_json::Value>,
    pub truncated: bool,
}

// NIVEL BASICO: Tabela achada pela pesquisa em todas as tabelas e quantas linhas dela tem o termo
#[derive(Debug, PartialEq, Serialize)]
pub struct Found {
    pub table: String,
    pub count: i64,
}

// NIVEL BASICO: Formato do arquivo, decidido pela extensao
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Format {
    DuckDb,
    Sqlite,
    Access,
}

pub(crate) fn format_of(path: &Path) -> Option<Format> {
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    match ext.as_str() {
        "duckdb" | "db" => Some(Format::DuckDb),
        "sqlite" | "sqlite3" => Some(Format::Sqlite),
        "mdb" | "accdb" => Some(Format::Access),
        _ => None,
    }
}

// identificador SQL entre aspas duplas, aspas internas dobradas
pub(crate) fn ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

// literal de texto SQL entre aspas simples
pub(crate) fn literal(text: &str) -> String {
    format!("'{}'", text.replace('\'', "''"))
}

// NIVEL BASICO: Filtro da grade (clique direito > "Filtrar por este valor"): coluna = valor exato
// `value` e o valor JSON que a grade recebeu (numero, texto, booleano ou null)
#[derive(Debug, Deserialize)]
pub struct Filter {
    pub column: String,
    pub value: serde_json::Value,
}

// NIVEL BASICO: Monta o WHERE dos filtros (somados com AND) e a lista de parametros
// NIVEL TECNICO: the column name is always quoted by ident() and the value always goes as a bound
// parameter, never into the SQL text; NULL becomes IS NULL. DuckDB casts the parameter to the column
// type, so the text the grid shows for DECIMAL, DATE, TIME and TIMESTAMP compares in the column type.
// shortcut: TIMESTAMP WITH TIME ZONE is shown in UTC but the bound text is read in the session time
// zone; append the offset here when a table with that type needs the filter
pub(crate) fn where_clause(filters: &[Filter]) -> Result<(String, Vec<duckdb::types::Value>), String> {
    use duckdb::types::Value as P;
    use serde_json::Value as J;
    let mut terms = Vec::new();
    let mut params = Vec::new();
    for filter in filters {
        let column = ident(&filter.column);
        let param = match &filter.value {
            J::Null => {
                terms.push(format!("{column} IS NULL"));
                continue;
            }
            J::Bool(b) => P::Boolean(*b),
            J::String(s) => P::Text(s.clone()),
            J::Number(n) => match (n.as_i64(), n.as_u64(), n.as_f64()) {
                (Some(i), _, _) => P::BigInt(i),
                (_, Some(u), _) => P::UBigInt(u),
                (_, _, Some(f)) => P::Double(f),
                _ => return Err(format!("Cannot filter {} by {n}", filter.column)),
            },
            other => return Err(format!("Cannot filter {} by {other}", filter.column)),
        };
        terms.push(format!("{column} = ?"));
        params.push(param);
    }
    let sql = if terms.is_empty() { String::new() } else { format!(" WHERE {}", terms.join(" AND ")) };
    Ok((sql, params))
}

// NIVEL BASICO: Pesquisa da aba Data na tabela inteira, no banco: a linha entra quando UMA celula tem todas as
// palavras (qualquer ordem, sem diferenciar maiusculas nem acentos). Devolve a condicao (sem WHERE) e os parametros.
// NIVEL TECNICO: every column is compared as text (CAST AS VARCHAR) after lower(strip_accents()); the words go as
// bound parameters folded the same way, so "tensao" finds "TENSÃO". NULL never matches. Empty search = None.
// columns = (nome, tipo): numbers, dates, times and booleans already print in lowercase without accents, so they skip
// the fold, and a word with a letter their text never has ("tension") skips those columns (same rows; on DB3 the fold
// and the cast of every cell were most of the time of the all-tables search, tests.rs). No column left: FALSE
pub(crate) fn search_condition(columns: &[(String, String)], search: &str) -> Option<(String, Vec<duckdb::types::Value>)> {
    let words: Vec<&str> = search.split_whitespace().collect();
    if words.is_empty() || columns.is_empty() {
        return None;
    }
    // palavra com caractere ASCII que o texto do tipo nunca tem nao esta na celula; fora do ASCII a palavra ainda passa
    // pelo dobramento (fálse vira false): a coluna fica
    let fits = |chars: &str| words.iter().all(|w| w.chars().all(|c| !c.is_ascii() || chars.contains(c.to_ascii_lowercase())));
    let fold = |sql: &str| format!("lower(strip_accents({sql}))");
    let mut params = Vec::new();
    let cells: Vec<String> = columns
        .iter()
        .filter(|(_, kind)| printed_chars(kind).is_none_or(fits))
        .map(|(col, kind)| {
            let text = format!("CAST({} AS VARCHAR)", ident(col));
            let cell = if printed_chars(kind).is_some() { text } else { fold(&text) };
            let all: Vec<String> = words
                .iter()
                .map(|w| {
                    params.push(duckdb::types::Value::Text(w.to_string()));
                    format!("contains({cell}, {})", fold("?"))
                })
                .collect();
            format!("({})", all.join(" AND "))
        })
        .collect();
    if cells.is_empty() {
        return Some(("FALSE".to_string(), params));
    }
    Some((format!("({})", cells.join(" OR ")), params))
}

// NIVEL BASICO: Tipo numerico (inteiro, decimal, double): a pesquisa de termos por valor inteiro compara o valor
pub(crate) fn is_number(kind: &str) -> bool {
    let kind = kind.to_ascii_uppercase();
    let numbers = ["TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT", "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT", "UHUGEINT"];
    kind.starts_with("DECIMAL(") || ["FLOAT", "DOUBLE"].contains(&kind.as_str()) || numbers.contains(&kind.as_str())
}

// NIVEL BASICO: Os caracteres que o texto (CAST AS VARCHAR) de um tipo do DuckDB pode ter: numeros, datas, horas e
// booleanos so escrevem digitos, pontuacao e minusculas sem acento (-12, 1e+20, -inf, nan, 2024-01-02, 0001-01-01 (BC),
// infinity, 23:59:58.5, 10:00:00+00, true, false), entao lower(strip_accents()) nao muda nada neles. None: texto livre
fn printed_chars(kind: &str) -> Option<&'static str> {
    let kind = kind.to_ascii_uppercase();
    Some(match kind.as_str() {
        "TINYINT" | "SMALLINT" | "INTEGER" | "BIGINT" | "HUGEINT" | "UTINYINT" | "USMALLINT" | "UINTEGER" | "UBIGINT"
        | "UHUGEINT" => "0123456789-",
        "FLOAT" | "DOUBLE" => "0123456789-+.einfa",
        "DATE" => "0123456789- ()bcinfty",
        "TIME" => "0123456789:.",
        "BOOLEAN" => "truefals",
        decimal if decimal.starts_with("DECIMAL(") => "0123456789-.",
        timestamp if timestamp.starts_with("TIMESTAMP") => "0123456789-:. +()bcinfty",
        _ => return None,
    })
}

// filtros (AND) e pesquisa juntos num WHERE so
fn where_all(filters: &[Filter], columns: &[(String, String)], search: &str) -> Result<(String, Vec<duckdb::types::Value>), String> {
    let (mut sql, mut params) = where_clause(filters)?;
    if let Some((cond, more)) = search_condition(columns, search) {
        sql = if sql.is_empty() { format!(" WHERE {cond}") } else { format!("{sql} AND {cond}") };
        params.extend(more);
    }
    Ok((sql, params))
}

const MICROS_PER_DAY: i64 = 86_400_000_000;

// NIVEL BASICO: Dias desde 1970-01-01 viram "AAAA-MM-DD"
// NIVEL TECNICO: civil_from_days (Howard Hinnant), proleptic Gregorian, valid for negative days
pub(crate) fn format_date(days: i64) -> String {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}")
}

// NIVEL BASICO: Microssegundos desde a meia-noite viram "HH:MM:SS" (fracao so quando existe)
pub(crate) fn format_time(micros: i64) -> String {
    let secs = micros / 1_000_000;
    let text = format!("{:02}:{:02}:{:02}", secs / 3600, secs / 60 % 60, secs % 60);
    match micros % 1_000_000 {
        0 => text,
        frac => format!("{text}.{frac:06}").trim_end_matches('0').to_string(),
    }
}

// NIVEL BASICO: Microssegundos desde 1970-01-01 viram "AAAA-MM-DD HH:MM:SS"
pub(crate) fn format_timestamp(micros: i64) -> String {
    format!(
        "{} {}",
        format_date(micros.div_euclid(MICROS_PER_DAY)),
        format_time(micros.rem_euclid(MICROS_PER_DAY))
    )
}

// Number.MAX_SAFE_INTEGER do JavaScript
const JS_MAX_SAFE_INTEGER: u64 = (1 << 53) - 1;

// NIVEL BASICO: Valor do DuckDB vira JSON para a grade (e texto para CSV/SQLite)
pub(crate) fn value_to_json(value: ValueRef) -> serde_json::Value {
    use serde_json::Value as J;
    match value {
        ValueRef::Null => J::Null,
        ValueRef::Boolean(b) => J::Bool(b),
        ValueRef::TinyInt(i) => i.into(),
        ValueRef::SmallInt(i) => i.into(),
        ValueRef::Int(i) => i.into(),
        // fora de +-(2^53 - 1) o Number do JavaScript perde digitos: vai como texto
        ValueRef::BigInt(i) if i.unsigned_abs() > JS_MAX_SAFE_INTEGER => J::String(i.to_string()),
        ValueRef::BigInt(i) => i.into(),
        ValueRef::UTinyInt(i) => i.into(),
        ValueRef::USmallInt(i) => i.into(),
        ValueRef::UInt(i) => i.into(),
        ValueRef::UBigInt(i) if i > JS_MAX_SAFE_INTEGER => J::String(i.to_string()),
        ValueRef::UBigInt(i) => i.into(),
        ValueRef::UHugeInt(i) => J::String(i.to_string()),
        ValueRef::Float(f) => serde_json::json!(f),
        ValueRef::Double(f) => serde_json::json!(f),
        ValueRef::Text(s) => J::String(String::from_utf8_lossy(s).to_string()),
        // texto: JavaScript perderia digitos de inteiros de 128 bits e decimais
        ValueRef::HugeInt(i) => J::String(i.to_string()),
        ValueRef::Decimal(d) => J::String(d.to_string()),
        // TIMESTAMP WITH TIME ZONE chega em UTC e e mostrado em UTC
        ValueRef::Timestamp(unit, v) => J::String(format_timestamp(unit.to_micros(v))),
        ValueRef::Date32(days) => J::String(format_date(days.into())),
        ValueRef::Time64(unit, v) => J::String(format_time(unit.to_micros(v))),
        // shortcut: other types (blobs, intervals, lists) show their debug form; add real
        // formatting when a table needs it
        other => J::String(format!("{:?}", other)),
    }
}

// texto de um valor como aparece na grade; NULL vira vazio
pub(crate) fn json_text(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::Null => String::new(),
        serde_json::Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

// NIVEL BASICO: Le ate `limit` linhas como objetos JSON; true no fim se ainda havia linhas
pub(crate) fn rows_to_json(
    rows: &mut Rows,
    names: &[String],
    limit: usize,
) -> Result<(Vec<serde_json::Value>, bool), String> {
    let mut results = Vec::new();
    while let Some(row) = rows.next().map_err(|e| format!("Failed to read row: {e}"))? {
        if results.len() == limit {
            return Ok((results, true));
        }
        let mut map = serde_json::Map::new();
        for (i, name) in names.iter().enumerate() {
            let value = row.get_ref(i).map_err(|e| format!("Failed to read value: {e}"))?;
            map.insert(name.clone(), value_to_json(value));
        }
        results.push(serde_json::Value::Object(map));
    }
    Ok((results, false))
}

// NIVEL BASICO: Etapa da abertura, para a barra de status: ler o Access, gravar o SQLite, carregar as tabelas
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Step {
    Read,
    Convert,
    Load,
}

// NIVEL BASICO: Resultado da abertura: por onde foi lido e o SQLite convertido (so Access)
pub struct Connected {
    pub source: String,
    pub converted: Option<Converted>,
}

// NIVEL BASICO: Conexao crua do mesmo banco, so para perguntar ao DuckDB o tipo de um comando sem roda-lo (aba SQL)
// NIVEL TECNICO: duckdb-rs keeps the statement type private, so the database is opened through the C API: the
// Connection of Engine does all the work and this one only prepares. Dropped after it, it closes the database handle
// (connections still alive, an export on its own thread, keep the instance until they finish).
struct Probe {
    db: ffi::duckdb_database,
    con: ffi::duckdb_connection,
}

// a conexao crua so e usada com o banco aberto travado (Mutex de DBManager)
unsafe impl Send for Probe {}

impl Drop for Probe {
    fn drop(&mut self) {
        unsafe {
            ffi::duckdb_disconnect(&mut self.con);
            ffi::duckdb_close(&mut self.db);
        }
    }
}

// comandos que a aba SQL roda: consulta (SELECT, WITH, VALUES, FROM, SHOW, DESCRIBE, SUMMARIZE e os PRAGMA de leitura,
// que o DuckDB reescreve como SELECT) e EXPLAIN de uma consulta
const EXPLAIN: ffi::duckdb_statement_type = ffi::duckdb_statement_type_DUCKDB_STATEMENT_TYPE_EXPLAIN;
const READ_STATEMENTS: [ffi::duckdb_statement_type; 2] = [ffi::duckdb_statement_type_DUCKDB_STATEMENT_TYPE_SELECT, EXPLAIN];

// o texto depois da palavra-chave (sem diferenciar maiusculas), se ele comeca com ela
fn keyword<'a>(text: &'a str, word: &str) -> Option<&'a str> {
    let rest = text.get(word.len()..)?;
    let whole = !rest.starts_with(|c: char| c.is_alphanumeric() || c == '_');
    (text[..word.len()].eq_ignore_ascii_case(word) && whole).then_some(rest)
}

// NIVEL BASICO: O comando que um EXPLAIN explica: o texto depois de EXPLAIN [ANALYZE | ANALYSE | (opcoes)]. None se o
// texto nao comeca assim ou se as opcoes tem algo alem de palavras e virgulas (a aba SQL recusa)
// NIVEL TECNICO: the C API gives the statement type but not the explained statement; DuckDB still classifies the
// text found here, the text only tells where it starts. Comments are refused by the caller (DuckDB nests /* */, so
// skipping them here could point at another statement than the one DuckDB runs)
fn explained(sql: &str) -> Option<&str> {
    let rest = keyword(sql.trim_start(), "EXPLAIN")?.trim_start();
    let rest = match keyword(rest, "ANALYZE").or_else(|| keyword(rest, "ANALYSE")) {
        Some(after) => after,
        None if rest.starts_with('(') => {
            let end = rest.find(')')?;
            let plain = rest[1..end].chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == ',' || c.is_whitespace());
            plain.then(|| &rest[end + 1..])?
        }
        None => rest,
    };
    Some(rest.trim_start())
}

impl Probe {
    // NIVEL BASICO: true se todo comando de `sql` so le. EXPLAIN so de uma consulta, sozinho e sem comentario: EXPLAIN
    // ANALYZE roda o comando que explica, e um COPY ... TO gravaria um arquivo (a transacao so de leitura nao impede)
    fn reads_only(&self, sql: &str) -> Result<bool, String> {
        let kinds = self.statement_types(sql)?;
        if kinds.iter().any(|kind| !READ_STATEMENTS.contains(kind)) {
            return Ok(false);
        }
        if !kinds.contains(&EXPLAIN) {
            return Ok(true);
        }
        if kinds.len() != 1 || sql.contains("/*") || sql.contains("--") {
            return Ok(false);
        }
        match explained(sql) {
            Some(inner) if self.statement_types(inner)?.len() == 1 => self.reads_only(inner),
            _ => Ok(false),
        }
    }

    fn run(&self, sql: &str) -> Result<(), String> {
        let text = std::ffi::CString::new(sql).map_err(|e| e.to_string())?;
        unsafe {
            let mut out: ffi::duckdb_result = std::mem::zeroed();
            let state = ffi::duckdb_query(self.con, text.as_ptr(), &mut out);
            ffi::duckdb_destroy_result(&mut out);
            if state == ffi::DuckDBSuccess { Ok(()) } else { Err(format!("Failed to run {sql}")) }
        }
    }

    // NIVEL BASICO: Tipo (do DuckDB) de cada comando de `sql`, sem rodar nenhum. Err = o texto do DuckDB (erro de
    // sintaxe, tabela que nao existe), o mesmo que rodar o comando daria
    fn statement_types(&self, sql: &str) -> Result<Vec<ffi::duckdb_statement_type>, String> {
        let text = std::ffi::CString::new(sql).map_err(|e| e.to_string())?;
        let message = |text: *const std::os::raw::c_char| {
            if text.is_null() { String::new() } else { unsafe { std::ffi::CStr::from_ptr(text) }.to_string_lossy().into_owned() }
        };
        unsafe {
            let mut extracted: ffi::duckdb_extracted_statements = std::ptr::null_mut();
            let count = ffi::duckdb_extract_statements(self.con, text.as_ptr(), &mut extracted);
            let mut kinds = Ok(Vec::new());
            if count == 0 {
                // so comentario ou vazio: sem erro e sem comando (o DuckDB diz isso ao rodar)
                let error = message(ffi::duckdb_extract_statements_error(extracted));
                if !error.is_empty() {
                    kinds = Err(error);
                }
            }
            for i in 0..count {
                let mut statement: ffi::duckdb_prepared_statement = std::ptr::null_mut();
                let prepared = ffi::duckdb_prepare_extracted_statement(self.con, extracted, i, &mut statement);
                if let Ok(list) = &mut kinds {
                    if prepared == ffi::DuckDBSuccess {
                        list.push(ffi::duckdb_prepared_statement_type(statement));
                    } else {
                        kinds = Err(message(ffi::duckdb_prepare_error(statement)));
                    }
                }
                ffi::duckdb_destroy_prepare(&mut statement);
            }
            ffi::duckdb_destroy_extracted(&mut extracted);
            kinds
        }
    }
}

// NIVEL BASICO: Motor da sessao: a conexao do DuckDB em memoria e a conexao crua que classifica os comandos
pub(crate) struct Engine {
    pub conn: Connection,
    probe: Probe, // depois de conn: fecha o banco por ultimo
}

// DuckDB em memoria sem baixar extensao da internet sozinho (o build bundled vem com autoinstall ligado)
fn new_duckdb() -> Result<Engine, String> {
    let fail = |what: &str| format!("Failed to start DuckDB: {what}");
    let probe = unsafe {
        let mut db: ffi::duckdb_database = std::ptr::null_mut();
        if ffi::duckdb_open(std::ptr::null(), &mut db) != ffi::DuckDBSuccess {
            return Err(fail("open"));
        }
        let mut con: ffi::duckdb_connection = std::ptr::null_mut();
        let connected = ffi::duckdb_connect(db, &mut con) == ffi::DuckDBSuccess;
        let probe = Probe { db, con };
        if !connected {
            return Err(fail("connect"));
        }
        probe
    };
    let conn = unsafe { Connection::open_from_raw(probe.db) }.map_err(|e| fail(&e.to_string()))?;
    conn.execute_batch("SET autoinstall_known_extensions = false; SET autoload_known_extensions = false;")
        .map_err(|e| format!("Failed to configure DuckDB: {e}"))?;
    Ok(Engine { conn, probe })
}

// NIVEL BASICO: Roda `f` numa transacao so de leitura, desfeita no fim: o que a aba SQL (e a exportacao do resultado
// dela) roda nunca muda o banco, a copia nem a memoria
// NIVEL TECNICO: the statement type already refuses every write; EXPLAIN ANALYZE is allowed and runs the statement
// it explains, so a write under it fails in the READ ONLY transaction
pub(crate) fn rolled_back<T>(conn: &Connection, f: impl FnOnce(&Connection) -> Result<T, String>) -> Result<T, String> {
    conn.execute_batch("BEGIN TRANSACTION READ ONLY").map_err(|e| e.to_string())?;
    let result = f(conn);
    let _ = conn.execute_batch("ROLLBACK");
    result
}

// NIVEL BASICO: Access -> SQLite temporario, uma vez: le com tipos (ODBC ou mdbtools) num DuckDB em memoria e
// grava o SQLite com os tipos declarados (mesmo gravador do Exportar > SQLite). Devolve o arquivo, o leitor e o
// proprio DuckDB, que vira o motor da sessao: o SQLite foi gravado dele (mesmos dados e tipos; teste com o .mdb e com
// o DB4) e reler o arquivo so custava tempo (REGRA_DESEMPENHO: sem conversao dupla). Em erro o temporario some.
fn convert_access(
    path: &str,
    reader: Option<&str>,
    progress: &mut dyn FnMut(Step, usize, usize, &str),
) -> Result<(Converted, String, Engine), String> {
    let scratch = new_duckdb()?;
    let used = access::import(&scratch.conn, path, reader, &mut |d, t, i| progress(Step::Read, d, t, i))?;
    let tables = list_tables(&scratch.conn)?;
    let name = Path::new(path).file_stem().map_or("access".into(), |s| s.to_string_lossy().into_owned());
    let file = converted::new_temp_path(&format!("{name}.sqlite"), Path::new(path).parent())?;
    let written = sqlite_io::export(&scratch.conn, &tables, &file, &mut |d, t, i| {
        progress(Step::Convert, d, t, i);
        Ok(())
    });
    if let Err(e) = written {
        let _ = std::fs::remove_file(&file);
        return Err(format!("SQLite: {e}"));
    }
    Ok((Converted::new(file), used, scratch))
}

// NIVEL BASICO: Banco aberto: motor, caminho e catalogo onde estao as tabelas
struct OpenDb {
    engine: Engine,
    path: String,
    catalog: &'static str,
}

// coluna da identidade da linha nas consultas da aba Dados (sai das linhas antes de irem para a tela)
const ROW_ID: &str = "mdb2sql id";

// NIVEL BASICO: Pagina da aba Dados: as linhas da pesquisa (ate o limite) e as linhas marcadas (todas, na ordem da
// tabela), cada lista com a identidade de cada linha na mesma ordem (`ids`, `marked_ids`)
#[derive(Debug, Serialize)]
pub struct TablePage {
    pub rows: Vec<serde_json::Value>,
    pub ids: Vec<serde_json::Value>,
    pub marked: Vec<serde_json::Value>,
    pub marked_ids: Vec<serde_json::Value>,
}

// NIVEL BASICO: Tem rowid do DuckDB? View nao tem; tabela com coluna propria chamada rowid tambem nao serve (o nome
// passa a ser o da coluna, que pode repetir)
pub(crate) fn has_rowid(conn: &Connection, table: &str, columns: &[String]) -> bool {
    !columns.iter().any(|c| c.eq_ignore_ascii_case("rowid")) && conn.prepare(&format!("SELECT rowid FROM {} LIMIT 0", ident(table))).is_ok()
}

// NIVEL BASICO: Identidade de uma linha (linhas marcadas): o rowid do DuckDB, que nao muda enquanto o arquivo esta
// aberto; sem rowid, todos os valores da linha (linhas identicas contam como uma so)
fn row_id(conn: &Connection, table: &str, columns: &[String]) -> String {
    if has_rowid(conn, table, columns) {
        "rowid".to_string()
    } else {
        let all: Vec<String> = columns.iter().map(|c| ident(c)).collect();
        format!("md5(CAST(ROW({}) AS VARCHAR))", all.join(", "))
    }
}

// " WHERE ..." das linhas com estas identidades (cada uma vai como parametro), na ordem da tabela: ORDER BY rowid, que
// uma tabela grande lida em paralelo nao garante sem ele; sem rowid (view), a ordem de leitura
fn marked_condition(id: &str, marked: &[serde_json::Value]) -> (String, Vec<duckdb::types::Value>) {
    let params = marked
        .iter()
        .map(|value| match value.as_i64() {
            Some(rowid) => duckdb::types::Value::BigInt(rowid),
            None => duckdb::types::Value::Text(json_text(value)),
        })
        .collect();
    let order = if id == "rowid" { " ORDER BY rowid" } else { "" };
    (format!(" WHERE {id} IN ({}){order}", vec!["?"; marked.len()].join(", ")), params)
}

// NIVEL BASICO: Colunas (nome, tipo) de cada tabela do banco corrente, na ordem da tabela (uma consulta so, sem PRAGMA
// por tabela)
pub(crate) fn all_columns(conn: &Connection) -> Result<HashMap<String, Vec<(String, String)>>, String> {
    let failed = |e: duckdb::Error| format!("Failed to list columns: {e}");
    let mut columns: HashMap<String, Vec<(String, String)>> = HashMap::new();
    let mut stmt = conn
        .prepare(
            "SELECT table_name, column_name, data_type FROM information_schema.columns WHERE table_catalog = current_database() \
             AND table_schema = current_schema() ORDER BY ordinal_position",
        )
        .map_err(failed)?;
    let mut rows = stmt.query([]).map_err(failed)?;
    while let Some(row) = rows.next().map_err(failed)? {
        let column = (row.get(1).map_err(failed)?, row.get(2).map_err(failed)?);
        columns.entry(row.get(0).map_err(failed)?).or_default().push(column);
    }
    Ok(columns)
}

// NIVEL BASICO: Esquema para exportar: da tabela (Coluna, Tipo, Aceita nulo) ou, sem tabela, do banco inteiro (com a
// coluna Tabela na frente). labels = titulos Tabela, Coluna, Tipo, Aceita nulo e os valores Sim e Nao no idioma da tela
pub(crate) fn schema_select(table: Option<&str>, labels: &[String]) -> Result<String, String> {
    let [in_table, column, kind, nullable, yes, no] = labels else {
        return Err("Schema export needs 6 labels".to_string());
    };
    let (first, only) = match table {
        Some(table) => (String::new(), format!(" AND table_name = {}", literal(table))),
        None => (format!("table_name AS {}, ", ident(in_table)), String::new()),
    };
    Ok(format!(
        "SELECT {first}column_name AS {}, data_type AS {}, CASE WHEN is_nullable THEN {} ELSE {} END AS {} FROM duckdb_columns() \
         WHERE database_name = current_database() AND schema_name = current_schema(){only} ORDER BY table_name, column_index",
        ident(column),
        ident(kind),
        literal(yes),
        literal(no),
        ident(nullable)
    ))
}

// NIVEL BASICO: Manager de banco DuckDB com conexao thread-safe
// NIVEL TECNICO: Mutex ensures safe concurrent access from Tauri commands
pub struct DBManager {
    open: Mutex<Option<OpenDb>>,
}

impl DBManager {
    // NIVEL BASICO: Cria novo DBManager sem conectar
    pub fn new() -> Self {
        DBManager {
            open: Mutex::new(None),
        }
    }

    // NIVEL BASICO: Valida caminho do banco de dados
    // NIVEL TECNICO: Prevents path traversal and validates file extension
    pub(crate) fn validate_database_path(&self, db_path: &str) -> Result<String, String> {
        let abs_path = Path::new(db_path)
            .canonicalize()
            .map_err(|e| format!("[[err.badPath]] {db_path} ({e})"))?;

        // [[chave]]: a interface troca pela frase do catalogo do idioma escolhido
        if format_of(&abs_path).is_none() {
            let ext = abs_path.extension().and_then(|s| s.to_str()).unwrap_or("");
            return Err(format!("[[err.unsupported]] .{ext}"));
        }
        if !abs_path.is_file() {
            return Err(format!("[[err.badPath]] {}", abs_path.display()));
        }

        // canonicalize no Windows devolve \\?\C:\...; o driver ODBC e o mdbtools nao entendem esse prefixo
        let text = abs_path.to_string_lossy().to_string();
        Ok(text.strip_prefix(r"\\?\").map(str::to_string).unwrap_or(text))
    }

    // NIVEL BASICO: Abre o banco; devolve por qual caminho ele foi lido e, para Access, o SQLite convertido
    // Leitor do Access: MDB2SQL_ACCESS_READER (odbc|mdbtools) ou automatico. Se falhar, o banco aberto antes
    // continua aberto.
    pub fn connect(&self, db_path: &str, progress: &mut dyn FnMut(Step, usize, usize, &str)) -> Result<Connected, String> {
        let forced = std::env::var("MDB2SQL_ACCESS_READER").ok();
        self.connect_with(db_path, forced.as_deref(), progress)
    }

    // NIVEL BASICO: connect com o leitor do Access escolhido (testes forcam o mdbtools sem mexer no ambiente)
    // NIVEL TECNICO: Access is read once into a scratch DuckDB (typed), written once to a SQLite file and the
    // session then reads that file the same way as any .sqlite. progress(step, done, total, table) runs per table.
    pub fn connect_with(
        &self,
        db_path: &str,
        reader: Option<&str>,
        progress: &mut dyn FnMut(Step, usize, usize, &str),
    ) -> Result<Connected, String> {
        let path = self.validate_database_path(db_path)?;
        let mut engine = new_duckdb()?;

        let mut format = format_of(Path::new(&path)).expect("validated extension");
        // .db tambem e extensao comum de SQLite: decide pelo cabecalho do arquivo
        if format == Format::DuckDb && sqlite_io::is_sqlite_file(Path::new(&path)) {
            format = Format::Sqlite;
        }
        let mut converted = None;
        let (source, catalog) = match format {
            Format::DuckDb => {
                // DuckDB nao entende "?access_mode=..." no caminho (isso e DSN do go-duckdb); read-only vai no ATTACH
                engine
                    .conn
                    .execute_batch(&format!("ATTACH {} AS src (READ_ONLY); USE src;", literal(&path)))
                    .map_err(|e| format!("Failed to connect: {e}"))?;
                engine.probe.run("USE src")?; // USE vale por conexao: a que classifica ve as mesmas tabelas
                ("DuckDB".to_string(), "src")
            }
            Format::Sqlite => {
                sqlite_io::import(&engine.conn, Path::new(&path), &mut |d, t, i| progress(Step::Load, d, t, i))?;
                ("SQLite".to_string(), "memory")
            }
            Format::Access => {
                let (lite, used, scratch) = convert_access(&path, reader, progress)?;
                engine = scratch;
                converted = Some(lite);
                // seta Unicode na tela (regra do dono), nunca ">" nem "->"
                (format!("{used} → SQLite"), "memory")
            }
        };
        *self.open.lock().unwrap() = Some(OpenDb { engine, path, catalog });
        Ok(Connected { source, converted })
    }

    // NIVEL BASICO: Fecha o banco aberto (o SQLite convertido e cuidado por quem chamou)
    pub fn close(&self) {
        *self.open.lock().unwrap() = None;
    }

    fn with_open<T>(&self, f: impl FnOnce(&OpenDb) -> Result<T, String>) -> Result<T, String> {
        match self.open.lock().unwrap().as_ref() {
            None => Err("[[err.noDatabase]]".to_string()),
            Some(open) => f(open),
        }
    }

    fn with_conn<T>(&self, f: impl FnOnce(&Connection) -> Result<T, String>) -> Result<T, String> {
        self.with_open(|open| f(&open.engine.conn))
    }

    // NIVEL BASICO: Caminho do banco aberto (pasta padrao dos dialogos de salvar)
    pub fn current_path(&self) -> Option<String> {
        self.open.lock().unwrap().as_ref().map(|open| open.path.clone())
    }

    // NIVEL BASICO: Conexao propria para a exportacao rodar em outra thread sem travar a grade
    // NIVEL TECNICO: same database instance; USE makes the source tables resolve unqualified
    pub fn export_connection(&self) -> Result<Connection, String> {
        let guard = self.open.lock().unwrap();
        let open = guard.as_ref().ok_or("[[err.noDatabase]]")?;
        let conn = open.engine.conn.try_clone().map_err(|e| format!("Failed to clone connection: {e}"))?;
        conn.execute_batch(&format!("USE {}", ident(open.catalog)))
            .map_err(|e| format!("Failed to select database: {e}"))?;
        Ok(conn)
    }

    // NIVEL BASICO: Retorna lista de nomes de tabelas no banco atual
    pub fn list_tables(&self) -> Result<Vec<String>, String> {
        self.with_conn(list_tables)
    }

    // NIVEL BASICO: Linhas de cada tabela, na ordem de `tables` (coluna Linhas da lista de tabelas, como no Zig).
    // Tabela que nao da para contar (ex.: view de um .duckdb que le um arquivo que sumiu) fica sem numero (None): o
    // arquivo abre do mesmo jeito e o erro aparece so ao abrir essa tabela, como antes da coluna existir
    // NIVEL TECNICO: one COUNT(*) per table on the session engine; DB4 (287 tables, 114 k rows) takes milliseconds
    pub fn table_rows(&self, tables: &[String]) -> Result<Vec<Option<i64>>, String> {
        self.with_conn(|conn| {
            Ok(tables
                .iter()
                .map(|table| conn.query_row(&format!("SELECT COUNT(*) FROM {}", ident(table)), [], |row| row.get(0)).ok())
                .collect())
        })
    }

    // NIVEL BASICO: Valida se tableName existe no banco
    // NIVEL TECNICO: Prevents SQL injection by checking against known tables
    fn validate_table_name(&self, table_name: &str) -> Result<(), String> {
        let tables = self.list_tables()?;
        if tables.iter().any(|t| t == table_name) {
            Ok(())
        } else {
            Err(format!("Table not found: {}", table_name))
        }
    }

    // nomes e tipos das colunas na ordem da tabela (a pesquisa olha todas)
    fn columns(&self, table_name: &str) -> Result<Vec<(String, String)>, String> {
        Ok(self.get_table_schema(table_name)?.into_iter().map(|c| (c.name, c.col_type)).collect())
    }

    // NIVEL BASICO: Retorna schema (colunas e tipos) de uma tabela
    pub fn get_table_schema(&self, table_name: &str) -> Result<Vec<ColumnSchema>, String> {
        self.validate_table_name(table_name)?;
        self.with_conn(|conn| table_info(conn, table_name))
    }

    // NIVEL BASICO: Pagina da aba Dados: ate `limit` linhas a partir da `offset` (paginas ◀ ▶) que passam pelos filtros e
    // pela pesquisa (no WHERE da
    // consulta: acham linhas na tabela inteira, alem das carregadas) e, a parte, todas as linhas marcadas (`marked` =
    // identidades que a tela guarda), na ordem da tabela, qualquer que seja a pesquisa
    pub fn table_page(
        &self,
        table_name: &str,
        limit: i32,
        offset: i64,
        filters: &[Filter],
        search: &str,
        marked: &[serde_json::Value],
    ) -> Result<TablePage, String> {
        self.validate_table_name(table_name)?;
        let columns = self.columns(table_name)?;
        let (filter_sql, params) = where_all(filters, &columns, search)?;
        let names: Vec<String> = columns.into_iter().map(|(name, _)| name).collect();
        self.with_conn(|conn| {
            let id = row_id(conn, table_name, &names);
            let select = format!("SELECT {id} AS {}, * FROM {}", ident(ROW_ID), ident(table_name));
            let read = |query: String, params: Vec<duckdb::types::Value>| {
                let mut stmt = conn.prepare(&query).map_err(|e| format!("Failed to prepare query: {e}"))?;
                // NIVEL TECNICO: duckdb-rs panics if column metadata is read before the
                // statement runs, so execute first and take the names from the result
                let mut rows = stmt.query(duckdb::params_from_iter(params)).map_err(|e| format!("Failed to query table: {e}"))?;
                let names = rows.as_ref().map(|s| s.column_names()).unwrap_or_default();
                let mut rows = rows_to_json(&mut rows, &names, usize::MAX)?.0;
                let ids: Vec<serde_json::Value> =
                    rows.iter_mut().map(|row| row.as_object_mut().and_then(|r| r.remove(ROW_ID)).unwrap_or_default()).collect();
                Ok::<_, String>((rows, ids))
            };
            // a ordem da tabela em toda pagina (ORDER BY rowid; sem rowid, a ordem de leitura)
            let order = if id == "rowid" { " ORDER BY rowid" } else { "" };
            let (rows, ids) = read(format!("{select}{filter_sql}{order} LIMIT {limit} OFFSET {offset}"), params)?;
            let (marked, marked_ids) = if marked.is_empty() {
                (Vec::new(), Vec::new())
            } else {
                let (cond, params) = marked_condition(&id, marked);
                read(format!("{select}{cond}"), params)?
            };
            Ok(TablePage { rows, ids, marked, marked_ids })
        })
    }

    #[cfg(test)] // so as linhas da pagina
    pub fn query_table(&self, table_name: &str, limit: i32, filters: &[Filter], search: &str) -> Result<Vec<serde_json::Value>, String> {
        Ok(self.table_page(table_name, limit, 0, filters, search, &[])?.rows)
    }

    // NIVEL BASICO: SQL da aba SQL (e da exportacao do resultado dele): algum comando que nao e de leitura recusa tudo
    // antes de rodar ([[err.sqlReadOnly]])
    // NIVEL TECNICO: DuckDB itself says what each statement is (Probe::statement_types), never the text
    pub fn check_read_only(&self, sql: &str) -> Result<(), String> {
        self.with_open(|open| match open.engine.probe.reads_only(sql)? {
            true => Ok(()),
            false => Err("[[err.sqlReadOnly]]".to_string()),
        })
    }

    // NIVEL BASICO: SQL da aba SQL: so comandos de leitura, ate `limit` linhas
    pub fn run_sql(&self, sql: &str, limit: usize) -> Result<SqlResult, String> {
        self.check_read_only(sql)?;
        self.with_open(|open| {
            rolled_back(&open.engine.conn, |conn| {
                let mut stmt = conn.prepare(sql).map_err(|e| e.to_string())?;
                let mut rows = stmt.query([]).map_err(|e| e.to_string())?;
                let (names, columns) = match rows.as_ref() {
                    Some(s) => {
                        let names = s.column_names();
                        let columns = (0..names.len())
                            .map(|i| ColumnSchema {
                                name: names[i].clone(),
                                col_type: format!("{:?}", s.column_type(i)),
                                null: "YES".to_string(),
                            })
                            .collect();
                        (names, columns)
                    }
                    None => (Vec::new(), Vec::new()),
                };
                let (rows, truncated) = rows_to_json(&mut rows, &names, limit)?;
                Ok(SqlResult { columns, rows, truncated })
            })
        })
    }

    // NIVEL BASICO: Pesquisa da aba Data em "Todas as tabelas": as tabelas (na ordem da lista) com linhas que tem o termo
    // e quantas. A mesma regra da pesquisa de uma tabela (search_condition), em todas as colunas: abrir a tabela achada
    // com a mesma pesquisa mostra o mesmo numero.
    // NIVEL TECNICO: the columns of every table come from one information_schema query (no PRAGMA per table), then
    // one COUNT per table. The time is the CAST and lower(strip_accents()) of every cell (measured on DB3 in tests.rs)
    // stop() true (outra pesquisa comecou): para antes da proxima tabela com [[err.searchCancelled]]
    pub fn search_tables(&self, search: &str, stop: &dyn Fn() -> bool) -> Result<Vec<Found>, String> {
        self.with_conn(|conn| {
            let columns = all_columns(conn)?;
            let mut found = Vec::new();
            for table in list_tables(conn)? {
                if stop() {
                    return Err("[[err.searchCancelled]]".to_string());
                }
                let Some((cond, params)) = columns.get(&table).and_then(|cols| search_condition(cols, search)) else {
                    continue;
                };
                let query = format!("SELECT COUNT(*) FROM {} WHERE {cond}", ident(&table));
                let count: i64 = conn
                    .query_row(&query, duckdb::params_from_iter(params), |row| row.get(0))
                    .map_err(|e| format!("[[err.countRows]] {table}: {e}"))?;
                if count > 0 {
                    found.push(Found { table, count });
                }
            }
            Ok(found)
        })
    }

    // NIVEL BASICO: WHERE das linhas da tabela que a grade achou (filtros e pesquisa, a mesma regra da grade e da
    // contagem), para exportar so elas
    pub fn rows_where(&self, table_name: &str, filters: &[Filter], search: &str) -> Result<(String, Vec<duckdb::types::Value>), String> {
        self.validate_table_name(table_name)?;
        where_all(filters, &self.columns(table_name)?, search)
    }

    // NIVEL BASICO: WHERE das linhas marcadas da tabela (as identidades que a tela guarda), para exportar so elas
    pub fn marked_where(&self, table_name: &str, marked: &[serde_json::Value]) -> Result<(String, Vec<duckdb::types::Value>), String> {
        self.validate_table_name(table_name)?;
        let names: Vec<String> = self.columns(table_name)?.into_iter().map(|(name, _)| name).collect();
        if marked.is_empty() {
            return Err("No marked rows".to_string());
        }
        self.with_conn(|conn| {
            Ok(marked_condition(&row_id(conn, table_name, &names), marked))
        })
    }

    // NIVEL BASICO: Retorna numero de linhas da tabela que passam pelos filtros e pela pesquisa (sem nada: todas)
    pub fn get_row_count(&self, table_name: &str, filters: &[Filter], search: &str) -> Result<i64, String> {
        self.validate_table_name(table_name)?;
        let (filter_sql, params) = where_all(filters, &self.columns(table_name)?, search)?;
        self.with_conn(|conn| {
            let query = format!("SELECT COUNT(*) FROM {}{}", ident(table_name), filter_sql);
            conn.query_row(&query, duckdb::params_from_iter(params), |row| row.get(0))
                .map_err(|e| format!("Failed to count rows: {}", e))
        })
    }
}

// NIVEL BASICO: Colunas (nome, tipo, aceita nulo) de uma tabela ou view da conexao
pub(crate) fn table_info(conn: &Connection, table: &str) -> Result<Vec<ColumnSchema>, String> {
    // NIVEL TECNICO: PRAGMA returns: cid, name, type, notnull, dflt_value, pk
    let mut stmt = conn
        .prepare(&format!("PRAGMA table_info({})", ident(table)))
        .map_err(|e| format!("Failed to get table info: {}", e))?;
    let schema = stmt
        .query_map([], |row| {
            let not_null: bool = row.get(3)?;
            Ok(ColumnSchema {
                name: row.get(1)?,
                col_type: row.get(2)?,
                null: if not_null { "NO" } else { "YES" }.to_string(),
            })
        })
        .map_err(|e| format!("Failed to query schema: {}", e))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| format!("Failed to read column: {}", e))?;
    Ok(schema)
}

// NIVEL BASICO: Tabelas do banco corrente da conexao (SHOW TABLES), em ordem alfabetica
pub(crate) fn list_tables(conn: &Connection) -> Result<Vec<String>, String> {
    let mut stmt = conn
        .prepare("SHOW TABLES")
        .map_err(|e| format!("Failed to prepare query: {}", e))?;
    let tables = stmt
        .query_map([], |row| row.get(0))
        .map_err(|e| format!("Failed to query tables: {}", e))?
        .collect::<Result<Vec<String>, _>>()
        .map_err(|e| format!("Failed to read table name: {}", e))?;
    Ok(tables)
}

// NIVEL TECNICO: Implement Default trait for convenience
impl Default for DBManager {
    fn default() -> Self {
        Self::new()
    }
}
