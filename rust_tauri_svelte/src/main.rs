// NIVEL BASICO: Entry point do app Tauri
// Rust compila este codigo e cria a janela do app usando webview do sistema
// O frontend (Svelte) sera servido dentro desta janela

// NIVEL TECNICO: Prevent console window on Windows release builds
#![cfg_attr(
    all(not(debug_assertions), target_os = "windows"),
    windows_subsystem = "windows"
)]

mod backend;

use backend::db_manager::{ColumnSchema, DBManager, SqlResult};
use backend::export::{self, Source};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{AppHandle, Emitter, State};

// NIVEL BASICO: Estado global da aplicacao com DBManager e o pedido de cancelar a exportacao
// NIVEL TECNICO: Tauri State manages app-wide shared state
struct AppState {
    db_manager: Mutex<DBManager>,
    cancel_export: AtomicBool,
}

// NIVEL BASICO: Banco aberto: caminho absoluto, tabelas e por qual caminho foi lido (barra de status)
#[derive(Serialize)]
struct Opened {
    path: String,
    tables: Vec<String>,
    source: String,
}

// evento de progresso da abertura e da exportacao
#[derive(Clone, Serialize)]
struct Progress<'a> {
    done: usize,
    total: usize,
    item: &'a str,
}

// NIVEL BASICO: Caminho passado na linha de comando (ou "Abrir com" do Windows), senao MDB2SQL_DB_PATH
#[tauri::command]
fn startup_path() -> String {
    std::env::args()
        .nth(1)
        .or_else(|| std::env::var("MDB2SQL_DB_PATH").ok())
        .unwrap_or_default()
}

// NIVEL BASICO: LoadDatabase abre o banco (.duckdb/.db, .sqlite/.sqlite3, .mdb/.accdb)
// Caminho vazio: MDB2SQL_DB_PATH ou data/sample.duckdb
// NIVEL TECNICO: async so a long Access import runs off the main thread; progress goes as events
#[tauri::command(async)]
fn load_database(app: AppHandle, db_path: String, state: State<'_, AppState>) -> Result<Opened, String> {
    let manager = state.db_manager.lock().unwrap();
    let path = if db_path.is_empty() {
        match std::env::var("MDB2SQL_DB_PATH") {
            Ok(env_path) if !env_path.is_empty() => env_path,
            _ => PathBuf::from("data").join("sample.duckdb").to_string_lossy().to_string(),
        }
    } else {
        db_path
    };
    let source = manager.connect(&path, &mut |done, total, item| {
        let _ = app.emit("open-progress", Progress { done, total, item });
    })?;
    Ok(Opened {
        path: manager.current_path().unwrap_or(path),
        tables: manager.list_tables()?,
        source,
    })
}

// NIVEL BASICO: GetTableData retorna ate `limit` linhas de uma tabela (default 100)
#[tauri::command(async)]
fn get_table_data(table_name: String, limit: i32, state: State<'_, AppState>) -> Result<Vec<serde_json::Value>, String> {
    let manager = state.db_manager.lock().unwrap();
    let limit = if limit <= 0 { 100 } else { limit };
    manager.query_table(&table_name, limit)
}

// NIVEL BASICO: GetRowCount retorna total de linhas em tabela
#[tauri::command(async)]
fn get_row_count(table_name: String, state: State<'_, AppState>) -> Result<i64, String> {
    state.db_manager.lock().unwrap().get_row_count(&table_name)
}

// NIVEL BASICO: GetTableSchema retorna schema da tabela
#[tauri::command(async)]
fn get_table_schema(table_name: String, state: State<'_, AppState>) -> Result<Vec<ColumnSchema>, String> {
    state.db_manager.lock().unwrap().get_table_schema(&table_name)
}

// NIVEL BASICO: SQL livre (aba SQL), ate `limit` linhas
#[tauri::command(async)]
fn run_sql(sql: String, limit: usize, state: State<'_, AppState>) -> Result<SqlResult, String> {
    state.db_manager.lock().unwrap().run_sql(&sql, limit.max(1))
}

// mesmo arquivo do banco aberto? (exportar por cima dele destruiria a origem)
fn same_file(a: &str, b: &Path) -> bool {
    match (Path::new(a).canonicalize(), b.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

// NIVEL BASICO: Exporta. scope = "database" (format duckdb, sqlite ou xlsx), "table" ou "sql" (csv ou xlsx)
// NIVEL TECNICO: runs on its own DuckDB connection, so the grid keeps working; progress goes as
// "export-progress" events and cancel_export stops it at the next table or every 10.000 rows
#[tauri::command(async)]
fn export(
    app: AppHandle,
    state: State<'_, AppState>,
    scope: String,
    format: String,
    path: String,
    table: Option<String>,
    sql: Option<String>,
) -> Result<String, String> {
    let (conn, source_path) = {
        let manager = state.db_manager.lock().unwrap();
        (manager.export_connection()?, manager.current_path())
    };
    let target = Path::new(&path);
    if source_path.is_some_and(|s| same_file(&s, target)) {
        return Err("Choose another file: this one is the open database".to_string());
    }
    state.cancel_export.store(false, Ordering::SeqCst);
    let mut progress = |done: usize, total: usize, item: &str| -> Result<(), String> {
        if state.cancel_export.load(Ordering::SeqCst) {
            return Err("Export cancelled".to_string());
        }
        let _ = app.emit("export-progress", Progress { done, total, item });
        Ok(())
    };
    let summary = match scope.as_str() {
        "database" => export::export_database(&conn, &format, target, &mut progress),
        "table" => {
            let source = Source::Table(table.ok_or("No table selected")?);
            export::export_source(&conn, &source, &format, target, &mut progress)
        }
        "sql" => {
            let source = Source::Sql(sql.ok_or("No SQL to export")?);
            export::export_source(&conn, &source, &format, target, &mut progress)
        }
        other => Err(format!("Unknown export scope: {other}")),
    }?;
    Ok(format!("Exported {summary} to {path}"))
}

#[tauri::command]
fn cancel_export(state: State<'_, AppState>) {
    state.cancel_export.store(true, Ordering::SeqCst);
}

// NIVEL BASICO: Linhas do dialogo Sobre; a versao vem do Cargo.toml (fonte unica),
// numero e data do build vem do build oficial (build.rs)
fn about_lines(runtimes: &str) -> Vec<String> {
    vec![
        "MDB2SQL (Rust + Tauri + Svelte)".to_string(),
        format!("Versao {} - {}", env!("CARGO_PKG_VERSION"), env!("BUILD_LABEL")),
        "Abre bancos Access, DuckDB e SQLite e exporta para DuckDB, SQLite, Excel e CSV.".to_string(),
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
    let odbc = if backend::access::odbc_installed() { "installed" } else { "not installed" };
    about_lines(&format!(
        "Tauri {}, WebView2 {webview}, Rust {}, Svelte {svelte_version}, DuckDB {duckdb}, SQLite {}, \
         mdbtools {} (embedded), Access ODBC driver {odbc}",
        tauri::VERSION,
        env!("RUSTC_VERSION"),
        rusqlite::version(),
        backend::access::MDBTOOLS_VERSION,
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
            cancel_export: AtomicBool::new(false),
        })
        .invoke_handler(tauri::generate_handler![
            startup_path,
            load_database,
            get_table_data,
            get_row_count,
            get_table_schema,
            run_sql,
            export,
            cancel_export,
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
        // "Versao 1.1.1 - build 123 (2026-11-15)" no build oficial, "Versao 1.1.1 - build dev" fora dele
        let version = lines[1].strip_prefix("Versao 1.1.1 - build ").expect(&lines[1]);
        let official = version.split_once(" (").is_some_and(|(n, d)| {
            n.parse::<u32>().is_ok() && d.len() == 11 && d.ends_with(')') && d.as_bytes()[4] == b'-'
        });
        assert!(version == "dev" || official, "{}", lines[1]);
        assert!(lines[2].starts_with("Abre bancos Access, DuckDB e SQLite"));
        assert!(lines[3].starts_with(&format!("Tauri {}, WebView2 ", tauri::VERSION)));
        assert!(lines[3].contains(", Svelte 5.0.0, DuckDB v"), "{}", lines[3]);
        assert!(lines[3].contains(", SQLite 3."), "{}", lines[3]);
        assert!(lines[3].contains(", mdbtools 1.0.1 (embedded), Access ODBC driver "), "{}", lines[3]);
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
