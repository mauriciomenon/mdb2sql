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
use tauri::{Manager, State};

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

fn main() {
    // NIVEL BASICO: Builder pattern cria app Tauri
    // invoke_handler registra comandos disponiveis para frontend
    // run() inicia event loop (janela fica aberta ate fechar)

    tauri::Builder::default()
        .manage(AppState {
            db_manager: Mutex::new(DBManager::new()),
        })
        .invoke_handler(tauri::generate_handler![
            load_database,
            get_table_data,
            get_row_count,
            get_table_schema
        ])
        .setup(|app| {
            // NIVEL TECNICO: Setup hook, executa antes de mostrar janela
            #[cfg(debug_assertions)]
            {
                let window = app.get_window("main").unwrap();
                window.open_devtools();
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
