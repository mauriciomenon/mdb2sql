// NIVEL BASICO: Gerenciador do banco aberto em Rust
// Abre .duckdb/.db, .sqlite/.sqlite3 e .mdb/.accdb, lista tabelas, executa queries
//
// NIVEL TECNICO: every format ends up in one in-memory DuckDB connection: a DuckDB file is
// ATTACHed READ_ONLY as "src" (and made current with USE), SQLite and Access tables are copied
// into the in-memory database. The rest of the app only sees DuckDB.

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

// NIVEL BASICO: Valor do DuckDB vira JSON para a grade (e texto para CSV/SQLite)
pub(crate) fn value_to_json(value: ValueRef) -> serde_json::Value {
    use serde_json::Value as J;
    match value {
        ValueRef::Null => J::Null,
        ValueRef::Boolean(b) => J::Bool(b),
        ValueRef::TinyInt(i) => i.into(),
        ValueRef::SmallInt(i) => i.into(),
        ValueRef::Int(i) => i.into(),
        ValueRef::BigInt(i) => i.into(),
        ValueRef::UTinyInt(i) => i.into(),
        ValueRef::USmallInt(i) => i.into(),
        ValueRef::UInt(i) => i.into(),
        ValueRef::UBigInt(i) => i.into(),
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
            .map_err(|e| format!("Invalid database path: {}", e))?;

        if format_of(&abs_path).is_none() {
            let ext = abs_path.extension().and_then(|s| s.to_str()).unwrap_or("");
            return Err(format!(
                "Only .duckdb, .db, .sqlite, .sqlite3, .mdb and .accdb files are supported, got: .{ext}"
            ));
        }
        if !abs_path.is_file() {
            return Err(format!("Database file not found: {}", abs_path.display()));
        }

        // canonicalize no Windows devolve \\?\C:\...; o driver ODBC e o mdbtools nao entendem esse prefixo
        let text = abs_path.to_string_lossy().to_string();
        Ok(text.strip_prefix(r"\\?\").map(str::to_string).unwrap_or(text))
    }

    // NIVEL BASICO: Abre o banco; devolve por qual caminho ele foi lido (DuckDB, SQLite, Access ODBC, mdbtools)
    // Se falhar, o banco aberto antes continua aberto.
    // NIVEL TECNICO: progress(done, total, table) is called while SQLite/Access tables are copied
    pub fn connect(
        &self,
        db_path: &str,
        progress: &mut dyn FnMut(usize, usize, &str),
    ) -> Result<String, String> {
        let path = self.validate_database_path(db_path)?;
        let conn = Connection::open_in_memory().map_err(|e| format!("Failed to start DuckDB: {e}"))?;
        // nada de baixar extensao da internet sozinho (o build bundled vem com autoinstall ligado)
        conn.execute_batch("SET autoinstall_known_extensions = false; SET autoload_known_extensions = false;")
            .map_err(|e| format!("Failed to configure DuckDB: {e}"))?;

        let mut format = format_of(Path::new(&path)).expect("validated extension");
        // .db tambem e extensao comum de SQLite: decide pelo cabecalho do arquivo
        if format == Format::DuckDb && sqlite_io::is_sqlite_file(Path::new(&path)) {
            format = Format::Sqlite;
        }
        let (source, catalog) = match format {
            Format::DuckDb => {
                // DuckDB nao entende "?access_mode=..." no caminho (isso e DSN do go-duckdb); read-only vai no ATTACH
                conn.execute_batch(&format!("ATTACH {} AS src (READ_ONLY); USE src;", literal(&path)))
                    .map_err(|e| format!("Failed to connect: {e}"))?;
                ("DuckDB".to_string(), "src")
            }
            Format::Sqlite => {
                sqlite_io::import(&conn, Path::new(&path), progress)?;
                ("SQLite".to_string(), "memory")
            }
            Format::Access => (access::import(&conn, &path, progress)?, "memory"),
        };
        *self.open.lock().unwrap() = Some(OpenDb { conn, path, catalog });
        Ok(source)
    }

    fn with_conn<T>(&self, f: impl FnOnce(&Connection) -> Result<T, String>) -> Result<T, String> {
        match self.open.lock().unwrap().as_ref() {
            None => Err("No database connected".to_string()),
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

    // NIVEL BASICO: Executa SELECT na tabela e retorna ate `limit` linhas como JSON
    pub fn query_table(&self, table_name: &str, limit: i32) -> Result<Vec<serde_json::Value>, String> {
        self.validate_table_name(table_name)?;
        self.with_conn(|conn| {
            let query = format!("SELECT * FROM {} LIMIT {}", ident(table_name), limit);
            let mut stmt = conn
                .prepare(&query)
                .map_err(|e| format!("Failed to prepare query: {}", e))?;
            // NIVEL TECNICO: duckdb-rs panics if column metadata is read before the
            // statement runs, so execute first and take the names from the result
            let mut rows = stmt.query([]).map_err(|e| format!("Failed to query table: {}", e))?;
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

    // NIVEL BASICO: Retorna numero total de linhas em uma tabela
    pub fn get_row_count(&self, table_name: &str) -> Result<i64, String> {
        self.validate_table_name(table_name)?;
        self.with_conn(|conn| {
            conn.query_row(&format!("SELECT COUNT(*) FROM {}", ident(table_name)), [], |row| row.get(0))
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
