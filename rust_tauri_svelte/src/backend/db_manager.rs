// NIVEL BASICO: Gerenciador de conexoes DuckDB em Rust
// Responsavel por carregar bancos, listar tabelas, executar queries

use duckdb::{AccessMode, Config, Connection, Result};
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

// NIVEL BASICO: Manager de banco DuckDB com conexao thread-safe
// NIVEL TECNICO: Mutex ensures safe concurrent access from Tauri commands
pub struct DBManager {
    conn: Mutex<Option<Connection>>,
    current_db: Mutex<Option<String>>,
}

impl DBManager {
    // NIVEL BASICO: Cria novo DBManager sem conectar
    pub fn new() -> Self {
        DBManager {
            conn: Mutex::new(None),
            current_db: Mutex::new(None),
        }
    }

    // NIVEL BASICO: Valida caminho do banco de dados
    // NIVEL TECNICO: Prevents path traversal and validates file extension
    pub(crate) fn validate_database_path(&self, db_path: &str) -> Result<String, String> {
        // NIVEL BASICO: Converte para caminho absoluto canonico
        let path = Path::new(db_path);
        let abs_path = path
            .canonicalize()
            .map_err(|e| format!("Invalid database path: {}", e))?;

        // NIVEL BASICO: Valida extensao do arquivo
        // NIVEL TECNICO: Only .duckdb and .db files allowed
        let ext = abs_path.extension().and_then(|s| s.to_str()).unwrap_or("");

        if ext != "duckdb" && ext != "db" {
            return Err(format!(
                "Only .duckdb and .db files are supported, got: .{}",
                ext
            ));
        }

        // NIVEL BASICO: Verifica se arquivo existe
        if !abs_path.exists() {
            return Err(format!("Database file not found: {}", abs_path.display()));
        }

        Ok(abs_path.to_string_lossy().to_string())
    }

    // NIVEL BASICO: Conecta ao banco DuckDB especificado
    // Se ja existe conexao, fecha antes de abrir nova
    //
    // Args:
    //   - db_path: Caminho para arquivo .duckdb
    //
    // Returns:
    //   - Result<()>: Ok se sucesso, Err com mensagem caso contrario
    pub fn connect(&self, db_path: &str) -> Result<(), String> {
        // NIVEL BASICO: Valida caminho do banco
        // NIVEL TECNICO: Prevent path traversal and validate file extension
        let validated_path = self.validate_database_path(db_path)?;

        // NIVEL BASICO: Fecha conexao anterior se existir
        let mut conn_guard = self.conn.lock().unwrap();
        *conn_guard = None;

        // NIVEL BASICO: Abre conexao DuckDB read-only
        // NIVEL TECNICO: read_only flag prevents accidental writes
        // DuckDB nao entende "?access_mode=..." no caminho (isso e DSN do go-duckdb):
        // o sufixo virava parte do nome do arquivo. Read-only vai pela Config.
        let config = Config::default()
            .access_mode(AccessMode::ReadOnly)
            .map_err(|e| format!("Failed to configure connection: {}", e))?;
        match Connection::open_with_flags(&validated_path, config) {
            Ok(conn) => {
                *conn_guard = Some(conn);
                let mut db_guard = self.current_db.lock().unwrap();
                *db_guard = Some(validated_path);
                Ok(())
            }
            Err(e) => Err(format!("Failed to connect: {}", e)),
        }
    }

    // NIVEL BASICO: Retorna lista de nomes de tabelas no banco atual
    //
    // Returns:
    //   - Result<Vec<String>>: Lista de tabelas ou erro
    pub fn list_tables(&self) -> Result<Vec<String>, String> {
        let conn_guard = self.conn.lock().unwrap();

        match conn_guard.as_ref() {
            None => Err("No database connected".to_string()),
            Some(conn) => {
                // NIVEL BASICO: Query SHOW TABLES retorna lista de tabelas
                // NIVEL TECNICO: DuckDB-specific SHOW TABLES syntax
                let mut stmt = conn
                    .prepare("SHOW TABLES")
                    .map_err(|e| format!("Failed to prepare query: {}", e))?;

                // NIVEL BASICO: Le cada linha e adiciona nome da tabela na lista
                let table_iter = stmt
                    .query_map([], |row| row.get(0))
                    .map_err(|e| format!("Failed to query tables: {}", e))?;

                let mut tables = Vec::new();
                for table_result in table_iter {
                    tables.push(
                        table_result.map_err(|e| format!("Failed to read table name: {}", e))?,
                    );
                }

                Ok(tables)
            }
        }
    }

    // NIVEL BASICO: Valida se tableName existe no banco
    // NIVEL TECNICO: Prevents SQL injection by checking against known tables
    fn validate_table_name(&self, table_name: &str) -> Result<(), String> {
        let tables = self.list_tables()?;
        if tables.contains(&table_name.to_string()) {
            Ok(())
        } else {
            Err(format!("Table not found: {}", table_name))
        }
    }

    // NIVEL BASICO: Retorna schema (colunas e tipos) de uma tabela
    //
    // Args:
    //   - table_name: Nome da tabela
    //
    // Returns:
    //   - Result<Vec<ColumnSchema>>: Lista de colunas com metadata
    pub fn get_table_schema(&self, table_name: &str) -> Result<Vec<ColumnSchema>, String> {
        // NIVEL BASICO: Valida tableName contra lista de tabelas
        // NIVEL TECNICO: Prevent SQL injection by validating input
        self.validate_table_name(table_name)?;

        let conn_guard = self.conn.lock().unwrap();

        match conn_guard.as_ref() {
            None => Err("No database connected".to_string()),
            Some(conn) => {
                // NIVEL BASICO: PRAGMA table_info retorna metadata sem varrer dados
                // NIVEL TECNICO: More efficient than DESCRIBE SELECT *
                let query = format!("PRAGMA table_info(\"{}\")", table_name);
                let mut stmt = conn
                    .prepare(&query)
                    .map_err(|e| format!("Failed to get table info: {}", e))?;

                // NIVEL BASICO: Le metadata de cada coluna
                // NIVEL TECNICO: PRAGMA returns: cid, name, type, notnull, dflt_value, pk
                let schema_iter = stmt
                    .query_map([], |row| {
                        let not_null: bool = row.get(3)?;
                        Ok(ColumnSchema {
                            name: row.get(1)?,     // name
                            col_type: row.get(2)?, // type
                            null: if not_null {
                                "NO".to_string()
                            } else {
                                "YES".to_string()
                            },
                        })
                    })
                    .map_err(|e| format!("Failed to query schema: {}", e))?;

                let mut schema = Vec::new();
                for col_result in schema_iter {
                    schema.push(col_result.map_err(|e| format!("Failed to read column: {}", e))?);
                }

                Ok(schema)
            }
        }
    }

    // NIVEL BASICO: Executa SELECT na tabela e retorna resultados
    //
    // Args:
    //   - table_name: Nome da tabela
    //   - limit: Numero maximo de linhas
    //
    // Returns:
    //   - Result<Vec<serde_json::Value>>: Lista de rows como JSON objects
    pub fn query_table(
        &self,
        table_name: &str,
        limit: i32,
    ) -> Result<Vec<serde_json::Value>, String> {
        // NIVEL BASICO: Valida tableName contra lista de tabelas
        // NIVEL TECNICO: Prevent SQL injection by validating input
        self.validate_table_name(table_name)?;

        let conn_guard = self.conn.lock().unwrap();

        match conn_guard.as_ref() {
            None => Err("No database connected".to_string()),
            Some(conn) => {
                // NIVEL BASICO: SELECT com LIMIT para nao carregar tabela inteira
                // NIVEL TECNICO: Table name validated, safe to use in query
                let query = format!("SELECT * FROM \"{}\" LIMIT {}", table_name, limit);
                let mut stmt = conn
                    .prepare(&query)
                    .map_err(|e| format!("Failed to prepare query: {}", e))?;

                // NIVEL TECNICO: duckdb-rs panics if column metadata is read before the
                // statement runs, so execute first and take the names from the result
                let mut rows = stmt
                    .query([])
                    .map_err(|e| format!("Failed to query table: {}", e))?;
                let column_names: Vec<String> = rows
                    .as_ref()
                    .map(|executed| executed.column_names())
                    .unwrap_or_default();

                // NIVEL BASICO: Le cada row e converte para JSON object
                let mut results = Vec::new();
                while let Some(row) = rows
                    .next()
                    .map_err(|e| format!("Failed to read row: {}", e))?
                {
                    {
                        let mut map = serde_json::Map::new();
                        for (i, col_name) in column_names.iter().enumerate() {
                            // NIVEL TECNICO: Handle multiple DuckDB types
                            let value: serde_json::Value = match row
                                .get_ref(i)
                                .map_err(|e| format!("Failed to read value: {}", e))?
                            {
                                duckdb::types::ValueRef::Null => serde_json::Value::Null,
                                duckdb::types::ValueRef::Boolean(b) => serde_json::Value::Bool(b),
                                duckdb::types::ValueRef::TinyInt(i) => {
                                    serde_json::Value::Number(i.into())
                                }
                                duckdb::types::ValueRef::SmallInt(i) => {
                                    serde_json::Value::Number(i.into())
                                }
                                duckdb::types::ValueRef::Int(i) => {
                                    serde_json::Value::Number(i.into())
                                }
                                duckdb::types::ValueRef::BigInt(i) => {
                                    serde_json::Value::Number(i.into())
                                }
                                duckdb::types::ValueRef::Float(f) => serde_json::json!(f),
                                duckdb::types::ValueRef::Double(f) => serde_json::json!(f),
                                duckdb::types::ValueRef::Text(s) => serde_json::Value::String(
                                    String::from_utf8_lossy(s).to_string(),
                                ),
                                duckdb::types::ValueRef::UTinyInt(i) => {
                                    serde_json::Value::Number(i.into())
                                }
                                duckdb::types::ValueRef::USmallInt(i) => {
                                    serde_json::Value::Number(i.into())
                                }
                                duckdb::types::ValueRef::UInt(i) => {
                                    serde_json::Value::Number(i.into())
                                }
                                duckdb::types::ValueRef::UBigInt(i) => {
                                    serde_json::Value::Number(i.into())
                                }
                                // texto: JavaScript perderia digitos de inteiros de 128 bits e decimais
                                duckdb::types::ValueRef::HugeInt(i) => {
                                    serde_json::Value::String(i.to_string())
                                }
                                duckdb::types::ValueRef::Decimal(d) => {
                                    serde_json::Value::String(d.to_string())
                                }
                                // TIMESTAMP WITH TIME ZONE chega em UTC e e mostrado em UTC
                                duckdb::types::ValueRef::Timestamp(unit, v) => {
                                    serde_json::Value::String(format_timestamp(unit.to_micros(v)))
                                }
                                duckdb::types::ValueRef::Date32(days) => {
                                    serde_json::Value::String(format_date(days.into()))
                                }
                                duckdb::types::ValueRef::Time64(unit, v) => {
                                    serde_json::Value::String(format_time(unit.to_micros(v)))
                                }
                                // shortcut: other types (blobs, intervals, lists) show their
                                // debug form; add real formatting when a table needs it
                                other => serde_json::Value::String(format!("{:?}", other)),
                            };
                            map.insert(col_name.clone(), value);
                        }
                        results.push(serde_json::Value::Object(map));
                    }
                }

                Ok(results)
            }
        }
    }

    // NIVEL BASICO: Retorna numero total de linhas em uma tabela
    //
    // Args:
    //   - table_name: Nome da tabela
    //
    // Returns:
    //   - Result<i64>: Numero de linhas
    pub fn get_row_count(&self, table_name: &str) -> Result<i64, String> {
        // NIVEL BASICO: Valida tableName contra lista de tabelas
        // NIVEL TECNICO: Prevent SQL injection by validating input
        self.validate_table_name(table_name)?;

        let conn_guard = self.conn.lock().unwrap();

        match conn_guard.as_ref() {
            None => Err("No database connected".to_string()),
            Some(conn) => {
                // NIVEL BASICO: COUNT(*) retorna total de linhas
                // NIVEL TECNICO: Table name validated, safe to use in query
                let query = format!("SELECT COUNT(*) FROM \"{}\"", table_name);
                let count: i64 = conn
                    .query_row(&query, [], |row| row.get(0))
                    .map_err(|e| format!("Failed to count rows: {}", e))?;

                Ok(count)
            }
        }
    }
}

// NIVEL TECNICO: Implement Default trait for convenience
impl Default for DBManager {
    fn default() -> Self {
        Self::new()
    }
}
