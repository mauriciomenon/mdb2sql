// NIVEL BASICO: Gerenciador de conexoes DuckDB em Rust
// Responsavel por carregar bancos, listar tabelas, executar queries

use duckdb::{Connection, Result};
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

    // NIVEL BASICO: Conecta ao banco DuckDB especificado
    // Se ja existe conexao, fecha antes de abrir nova
    //
    // Args:
    //   - db_path: Caminho para arquivo .duckdb
    //
    // Returns:
    //   - Result<()>: Ok se sucesso, Err com mensagem caso contrario
    pub fn connect(&self, db_path: &str) -> Result<(), String> {
        // NIVEL BASICO: Verifica se arquivo existe
        if !Path::new(db_path).exists() {
            return Err(format!("Database not found: {}", db_path));
        }

        // NIVEL BASICO: Fecha conexao anterior se existir
        let mut conn_guard = self.conn.lock().unwrap();
        *conn_guard = None;

        // NIVEL BASICO: Abre conexao DuckDB read-only
        // NIVEL TECNICO: read_only flag prevents accidental writes
        let conn_str = format!("{}?access_mode=read_only", db_path);
        match Connection::open(&conn_str) {
            Ok(conn) => {
                *conn_guard = Some(conn);
                let mut db_guard = self.current_db.lock().unwrap();
                *db_guard = Some(db_path.to_string());
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

    // NIVEL BASICO: Retorna schema (colunas e tipos) de uma tabela
    //
    // Args:
    //   - table_name: Nome da tabela
    //
    // Returns:
    //   - Result<Vec<ColumnSchema>>: Lista de colunas com metadata
    pub fn get_table_schema(&self, table_name: &str) -> Result<Vec<ColumnSchema>, String> {
        let conn_guard = self.conn.lock().unwrap();

        match conn_guard.as_ref() {
            None => Err("No database connected".to_string()),
            Some(conn) => {
                // NIVEL BASICO: DESCRIBE retorna info das colunas
                // NIVEL TECNICO: Quote table name to handle special characters
                let query = format!("DESCRIBE SELECT * FROM \"{}\"", table_name);
                let mut stmt = conn
                    .prepare(&query)
                    .map_err(|e| format!("Failed to describe table: {}", e))?;

                // NIVEL BASICO: Le metadata de cada coluna
                let schema_iter = stmt
                    .query_map([], |row| {
                        Ok(ColumnSchema {
                            name: row.get(0)?,
                            col_type: row.get(1)?,
                            null: row.get(2)?,
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
        let conn_guard = self.conn.lock().unwrap();

        match conn_guard.as_ref() {
            None => Err("No database connected".to_string()),
            Some(conn) => {
                // NIVEL BASICO: SELECT com LIMIT para nao carregar tabela inteira
                // NIVEL TECNICO: Quote table name to handle special characters
                let query = format!("SELECT * FROM \"{}\" LIMIT {}", table_name, limit);
                let mut stmt = conn
                    .prepare(&query)
                    .map_err(|e| format!("Failed to prepare query: {}", e))?;

                // NIVEL BASICO: Pega nomes das colunas
                let column_count = stmt.column_count();
                let column_names: Vec<String> = (0..column_count)
                    .map(|i| stmt.column_name(i).unwrap().to_string())
                    .collect();

                // NIVEL BASICO: Le cada row e converte para JSON object
                let rows = stmt
                    .query_map([], |row| {
                        let mut map = serde_json::Map::new();
                        for (i, col_name) in column_names.iter().enumerate() {
                            // NIVEL TECNICO: Handle multiple DuckDB types
                            let value: serde_json::Value = match row.get_ref(i).unwrap() {
                                duckdb::types::ValueRef::Null => serde_json::Value::Null,
                                duckdb::types::ValueRef::Boolean(b) => {
                                    serde_json::Value::Bool(b)
                                }
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
                                duckdb::types::ValueRef::Text(s) => {
                                    serde_json::Value::String(
                                        String::from_utf8_lossy(s).to_string(),
                                    )
                                }
                                _ => serde_json::Value::String(format!("{:?}", row.get_ref(i))),
                            };
                            map.insert(col_name.clone(), value);
                        }
                        Ok(serde_json::Value::Object(map))
                    })
                    .map_err(|e| format!("Failed to query table: {}", e))?;

                let mut results = Vec::new();
                for row_result in rows {
                    results.push(row_result.map_err(|e| format!("Failed to read row: {}", e))?);
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
        let conn_guard = self.conn.lock().unwrap();

        match conn_guard.as_ref() {
            None => Err("No database connected".to_string()),
            Some(conn) => {
                // NIVEL BASICO: COUNT(*) retorna total de linhas
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
