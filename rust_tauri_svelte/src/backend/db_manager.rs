// NIVEL BASICO: Gerenciador do banco aberto em Rust
// Abre .accdb/.mdb, .sqlite/.sqlite3/.db e .duckdb, lista tabelas, executa queries
//
// NIVEL TECNICO: every format ends up in one in-memory DuckDB connection: a DuckDB file is
// ATTACHed READ_ONLY as "src" (and made current with USE), SQLite and Access tables are copied
// into the in-memory database. The rest of the app only sees DuckDB.

use super::converted::{self, Converted};
use super::{access, sqlite_io};
use duckdb::types::ValueRef;
use duckdb::{Connection, Rows};
use serde::{Deserialize, Serialize};
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
pub(crate) fn search_condition(columns: &[String], search: &str) -> Option<(String, Vec<duckdb::types::Value>)> {
    let words: Vec<&str> = search.split_whitespace().collect();
    if words.is_empty() || columns.is_empty() {
        return None;
    }
    let fold = |sql: &str| format!("lower(strip_accents({sql}))");
    let mut params = Vec::new();
    let cells: Vec<String> = columns
        .iter()
        .map(|col| {
            let cell = fold(&format!("CAST({} AS VARCHAR)", ident(col)));
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
    Some((format!("({})", cells.join(" OR ")), params))
}

// filtros (AND) e pesquisa juntos num WHERE so
fn where_all(filters: &[Filter], columns: &[String], search: &str) -> Result<(String, Vec<duckdb::types::Value>), String> {
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
fn rows_to_json(
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

// DuckDB em memoria sem baixar extensao da internet sozinho (o build bundled vem com autoinstall ligado)
fn new_duckdb() -> Result<Connection, String> {
    let conn = Connection::open_in_memory().map_err(|e| format!("Failed to start DuckDB: {e}"))?;
    conn.execute_batch("SET autoinstall_known_extensions = false; SET autoload_known_extensions = false;")
        .map_err(|e| format!("Failed to configure DuckDB: {e}"))?;
    Ok(conn)
}

// NIVEL BASICO: Access -> SQLite temporario, uma vez: le com tipos (ODBC ou mdbtools) num DuckDB em memoria e
// grava o SQLite com os tipos declarados (mesmo gravador do Exportar > SQLite). Devolve o arquivo, o leitor e o
// proprio DuckDB, que vira o motor da sessao: o SQLite foi gravado dele (mesmos dados e tipos; teste com o .mdb e com
// o DB4) e reler o arquivo so custava tempo (REGRA_DESEMPENHO: sem conversao dupla). Em erro o temporario some.
fn convert_access(
    path: &str,
    reader: Option<&str>,
    progress: &mut dyn FnMut(Step, usize, usize, &str),
) -> Result<(Converted, String, Connection), String> {
    let scratch = new_duckdb()?;
    let used = access::import(&scratch, path, reader, &mut |d, t, i| progress(Step::Read, d, t, i))?;
    let tables = list_tables(&scratch)?;
    let name = Path::new(path).file_stem().map_or("access".into(), |s| s.to_string_lossy().into_owned());
    let file = converted::new_temp_path(&format!("{name}.sqlite"))?;
    let written = sqlite_io::export(&scratch, &tables, &file, &mut |d, t, i| {
        progress(Step::Convert, d, t, i);
        Ok(())
    });
    if let Err(e) = written {
        let _ = std::fs::remove_file(&file);
        return Err(format!("SQLite: {e}"));
    }
    Ok((Converted::new(file), used, scratch))
}

// NIVEL BASICO: Banco aberto: conexao, caminho e catalogo onde estao as tabelas
struct OpenDb {
    conn: Connection,
    path: String,
    catalog: &'static str,
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
        let mut conn = new_duckdb()?;

        let mut format = format_of(Path::new(&path)).expect("validated extension");
        // .db tambem e extensao comum de SQLite: decide pelo cabecalho do arquivo
        if format == Format::DuckDb && sqlite_io::is_sqlite_file(Path::new(&path)) {
            format = Format::Sqlite;
        }
        let mut converted = None;
        let (source, catalog) = match format {
            Format::DuckDb => {
                // DuckDB nao entende "?access_mode=..." no caminho (isso e DSN do go-duckdb); read-only vai no ATTACH
                conn.execute_batch(&format!("ATTACH {} AS src (READ_ONLY); USE src;", literal(&path)))
                    .map_err(|e| format!("Failed to connect: {e}"))?;
                ("DuckDB".to_string(), "src")
            }
            Format::Sqlite => {
                sqlite_io::import(&conn, Path::new(&path), &mut |d, t, i| progress(Step::Load, d, t, i))?;
                ("SQLite".to_string(), "memory")
            }
            Format::Access => {
                let (lite, used, engine) = convert_access(&path, reader, progress)?;
                conn = engine;
                converted = Some(lite);
                // seta Unicode na tela (regra do dono), nunca ">" nem "->"
                (format!("{used} → SQLite"), "memory")
            }
        };
        *self.open.lock().unwrap() = Some(OpenDb { conn, path, catalog });
        Ok(Connected { source, converted })
    }

    // NIVEL BASICO: Fecha o banco aberto (o SQLite convertido e cuidado por quem chamou)
    pub fn close(&self) {
        *self.open.lock().unwrap() = None;
    }

    fn with_conn<T>(&self, f: impl FnOnce(&Connection) -> Result<T, String>) -> Result<T, String> {
        match self.open.lock().unwrap().as_ref() {
            None => Err("[[err.noDatabase]]".to_string()),
            Some(open) => f(&open.conn),
        }
    }

    // NIVEL BASICO: Caminho do banco aberto (pasta padrao dos dialogos de salvar)
    pub fn current_path(&self) -> Option<String> {
        self.open.lock().unwrap().as_ref().map(|open| open.path.clone())
    }

    // NIVEL BASICO: Conexao propria para a exportacao rodar em outra thread sem travar a grade
    // NIVEL TECNICO: same database instance; USE makes the source tables resolve unqualified
    pub fn export_connection(&self) -> Result<Connection, String> {
        let guard = self.open.lock().unwrap();
        let open = guard.as_ref().ok_or("No database connected")?;
        let conn = open.conn.try_clone().map_err(|e| format!("Failed to clone connection: {e}"))?;
        conn.execute_batch(&format!("USE {}", ident(open.catalog)))
            .map_err(|e| format!("Failed to select database: {e}"))?;
        Ok(conn)
    }

    // NIVEL BASICO: Retorna lista de nomes de tabelas no banco atual
    pub fn list_tables(&self) -> Result<Vec<String>, String> {
        self.with_conn(list_tables)
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

    // nomes das colunas na ordem da tabela (a pesquisa olha todas)
    fn column_names(&self, table_name: &str) -> Result<Vec<String>, String> {
        Ok(self.get_table_schema(table_name)?.into_iter().map(|c| c.name).collect())
    }

    // NIVEL BASICO: Retorna schema (colunas e tipos) de uma tabela
    pub fn get_table_schema(&self, table_name: &str) -> Result<Vec<ColumnSchema>, String> {
        self.validate_table_name(table_name)?;
        self.with_conn(|conn| {
            // NIVEL TECNICO: PRAGMA returns: cid, name, type, notnull, dflt_value, pk
            let mut stmt = conn
                .prepare(&format!("PRAGMA table_info({})", ident(table_name)))
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
        })
    }

    // NIVEL BASICO: Executa SELECT na tabela e retorna ate `limit` linhas como JSON; filtros e pesquisa entram
    // no WHERE da consulta (acham linhas na tabela inteira, alem das carregadas)
    pub fn query_table(
        &self,
        table_name: &str,
        limit: i32,
        filters: &[Filter],
        search: &str,
    ) -> Result<Vec<serde_json::Value>, String> {
        self.validate_table_name(table_name)?;
        let (filter_sql, params) = where_all(filters, &self.column_names(table_name)?, search)?;
        self.with_conn(|conn| {
            let query = format!("SELECT * FROM {}{} LIMIT {}", ident(table_name), filter_sql, limit);
            let mut stmt = conn
                .prepare(&query)
                .map_err(|e| format!("Failed to prepare query: {}", e))?;
            // NIVEL TECNICO: duckdb-rs panics if column metadata is read before the
            // statement runs, so execute first and take the names from the result
            let mut rows = stmt
                .query(duckdb::params_from_iter(params))
                .map_err(|e| format!("Failed to query table: {}", e))?;
            let names = rows.as_ref().map(|s| s.column_names()).unwrap_or_default();
            Ok(rows_to_json(&mut rows, &names, usize::MAX)?.0)
        })
    }

    // NIVEL BASICO: SQL livre digitado pelo usuario; devolve ate `limit` linhas
    // NIVEL TECNICO: the source file is attached READ_ONLY, so a write to it fails in DuckDB
    pub fn run_sql(&self, sql: &str, limit: usize) -> Result<SqlResult, String> {
        self.with_conn(|conn| {
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
    }

    // NIVEL BASICO: Retorna numero de linhas da tabela que passam pelos filtros e pela pesquisa (sem nada: todas)
    pub fn get_row_count(&self, table_name: &str, filters: &[Filter], search: &str) -> Result<i64, String> {
        self.validate_table_name(table_name)?;
        let (filter_sql, params) = where_all(filters, &self.column_names(table_name)?, search)?;
        self.with_conn(|conn| {
            let query = format!("SELECT COUNT(*) FROM {}{}", ident(table_name), filter_sql);
            conn.query_row(&query, duckdb::params_from_iter(params), |row| row.get(0))
                .map_err(|e| format!("Failed to count rows: {}", e))
        })
    }
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
