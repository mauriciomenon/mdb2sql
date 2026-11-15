// NIVEL BASICO: Entry point do app Tauri
// Rust compila este codigo e cria a janela do app usando webview do sistema
// O frontend (Svelte) sera servido dentro desta janela

// NIVEL TECNICO: Prevent console window on Windows release builds
#![cfg_attr(
    all(not(debug_assertions), target_os = "windows"),
    windows_subsystem = "windows"
)]

mod backend;

use backend::db_manager::{ColumnSchema, DBManager};
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::State;

// NIVEL BASICO: Estado global da aplicacao com DBManager
// NIVEL TECNICO: Tauri State manages app-wide shared state
struct AppState {
    db_manager: Mutex<DBManager>,
}

// NIVEL BASICO: LoadDatabase conecta ao banco DuckDB
// Retorna lista de tabelas ou erro
//
// NIVEL TECNICO: Tauri command automatically exposed to frontend
#[tauri::command]
fn load_database(db_path: String, state: State<AppState>) -> Result<Vec<String>, String> {
    let manager = state.db_manager.lock().unwrap();

    // NIVEL BASICO: Se path vazio, tenta env var ou usa default
    let path = if db_path.is_empty() {
        // NIVEL TECNICO: Check MDB2SQL_DB_PATH env var first
        match std::env::var("MDB2SQL_DB_PATH") {
            Ok(env_path) if !env_path.is_empty() => env_path,
            _ => {
                // NIVEL TECNICO: Fallback to default relative path
                let mut p = PathBuf::from("data");
                p.push("sample.duckdb");
                p.to_string_lossy().to_string()
            }
        }
    } else {
        db_path
    };

    // NIVEL BASICO: Conecta ao banco
    manager.connect(&path)?;

    // NIVEL BASICO: Lista tabelas disponiveis
    manager.list_tables()
}

// NIVEL BASICO: GetTableData retorna linhas de uma tabela
//
// Args:
//   - table_name: Nome da tabela
//   - limit: Numero maximo de linhas (default 100)
//
// Returns:
//   - Vec<serde_json::Value>: Dados da tabela como JSON
#[tauri::command]
fn get_table_data(
    table_name: String,
    limit: i32,
    state: State<AppState>,
) -> Result<Vec<serde_json::Value>, String> {
    let manager = state.db_manager.lock().unwrap();
    let limit = if limit <= 0 { 100 } else { limit };
    manager.query_table(&table_name, limit)
}

// NIVEL BASICO: GetRowCount retorna total de linhas em tabela
#[tauri::command]
fn get_row_count(table_name: String, state: State<AppState>) -> Result<i64, String> {
    let manager = state.db_manager.lock().unwrap();
    manager.get_row_count(&table_name)
}

// NIVEL BASICO: GetTableSchema retorna schema da tabela
#[tauri::command]
fn get_table_schema(
    table_name: String,
    state: State<AppState>,
) -> Result<Vec<ColumnSchema>, String> {
    let manager = state.db_manager.lock().unwrap();
    manager.get_table_schema(&table_name)
}

// NIVEL BASICO: Linhas do dialogo Sobre; a versao vem do Cargo.toml (fonte unica)
fn about_lines(runtimes: &str) -> Vec<String> {
    vec![
        "MDB2SQL (Rust + Tauri + Svelte)".to_string(),
        format!("Versao {}", env!("CARGO_PKG_VERSION")),
        "Visualizador de bancos DuckDB convertidos de Microsoft Access: tabelas, esquema, dados e consultas."
            .to_string(),
        runtimes.to_string(),
        "Autor: Mauricio Menon".to_string(),
        "Codigo: https://github.com/mauriciomenon/mdb2sql".to_string(),
    ]
}

// NIVEL TECNICO: Runtime versions are read when the dialog opens; Svelte reports its own
// version from the webview, the Rust compiler version is captured by build.rs
#[tauri::command]
fn about(svelte_version: String) -> Vec<String> {
    let duckdb = duckdb::Connection::open_in_memory()
        .and_then(|conn| conn.query_row("SELECT version()", [], |row| row.get::<_, String>(0)))
        .unwrap_or_else(|e| format!("? ({e})"));
    let webview = tauri::webview_version().unwrap_or_else(|_| "?".to_string());
    about_lines(&format!(
        "Tauri {}, WebView2 {webview}, Rust {}, Svelte {svelte_version}, DuckDB {duckdb}",
        tauri::VERSION,
        env!("RUSTC_VERSION")
    ))
}

fn main() {
    // NIVEL BASICO: Builder pattern cria app Tauri
    // invoke_handler registra comandos disponiveis para frontend
    // run() inicia event loop (janela fica aberta ate fechar)

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState {
            db_manager: Mutex::new(DBManager::new()),
        })
        .invoke_handler(tauri::generate_handler![
            load_database,
            get_table_data,
            get_row_count,
            get_table_schema,
            about
        ])
        .setup(|_app| {
            // NIVEL TECNICO: Setup hook, executa antes de mostrar janela
            #[cfg(debug_assertions)]
            {
                use tauri::Manager;
                let window = _app.get_webview_window("main").unwrap();
                window.open_devtools();
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn about_has_the_six_required_lines() {
        let lines = about("5.0.0".to_string());
        assert_eq!(lines.len(), 6);
        assert_eq!(lines[0], "MDB2SQL (Rust + Tauri + Svelte)");
        assert_eq!(lines[1], "Versao 1.0.1");
        assert!(lines[2].starts_with("Visualizador de bancos DuckDB"));
        assert!(lines[3].starts_with(&format!("Tauri {}, WebView2 ", tauri::VERSION)));
        assert!(lines[3].contains(", Svelte 5.0.0, DuckDB v"), "{}", lines[3]);
        assert!(!lines[3].contains("Rust unknown"));
        assert_eq!(lines[4], "Autor: Mauricio Menon");
        assert_eq!(lines[5], "Codigo: https://github.com/mauriciomenon/mdb2sql");
    }

    // Cargo.toml e a fonte unica: tauri.conf.json herda dele quando nao tem "version"
    #[test]
    fn versions_agree_with_cargo_toml() {
        let json = |path: &str| -> serde_json::Value {
            let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{path}: {e}"));
            serde_json::from_str(&text).unwrap_or_else(|e| panic!("{path}: {e}"))
        };
        let version = env!("CARGO_PKG_VERSION");
        if let Some(conf) = json("tauri.conf.json").get("version") {
            assert_eq!(conf, version, "tauri.conf.json");
        }
        assert_eq!(json("ui/package.json")["version"], version, "ui/package.json");
    }
}
