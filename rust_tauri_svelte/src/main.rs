// NIVEL BASICO: Entry point do app Tauri
// Rust compila este codigo e cria a janela do app usando webview do sistema
// O frontend (Svelte) sera servido dentro desta janela

// NIVEL TECNICO: Prevent console window on Windows release builds
#![cfg_attr(
    all(not(debug_assertions), target_os = "windows"),
    windows_subsystem = "windows"
)]

mod backend;

use backend::converted::{self, Converted};
use backend::db_manager::{ColumnSchema, DBManager, Filter, SqlResult, Step};
use backend::export::{self, Source, Summary};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{AppHandle, Emitter, Manager, State};

// NIVEL BASICO: Estado global: banco aberto, pedido de cancelar a exportacao e o SQLite convertido do Access
// NIVEL TECNICO: `converted` has its own lock so the close button never waits for a long import holding
// db_manager; `exiting` lets the final close through after the user answered the save/delete question
struct AppState {
    db_manager: Mutex<DBManager>,
    cancel_export: AtomicBool,
    converted: Mutex<Option<Converted>>,
    exiting: AtomicBool,
}

// NIVEL BASICO: Banco aberto: caminho absoluto, tabelas, por qual caminho foi lido e se ha SQLite convertido
#[derive(Serialize)]
struct Opened {
    path: String,
    tables: Vec<String>,
    source: String,
    converted: bool,
}

// evento de progresso da exportacao
#[derive(Clone, Serialize)]
struct Progress<'a> {
    done: usize,
    total: usize,
    item: &'a str,
}

// evento de progresso da abertura: step = read (Access), convert (gravando o SQLite) ou load (carregando tabelas)
#[derive(Clone, Serialize)]
struct OpenProgress<'a> {
    step: Step,
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

// NIVEL BASICO: LoadDatabase abre o banco (.accdb/.mdb, .sqlite/.sqlite3/.db, .duckdb)
// Caminho vazio: MDB2SQL_DB_PATH ou data/sample.duckdb. A interface resolve antes o SQLite convertido do
// banco anterior (salvar/apagar); se sobrou algum, ele e apagado quando o novo banco abre.
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
    let connected = manager.connect(&path, &mut |step, done, total, item| {
        let _ = app.emit("open-progress", OpenProgress { step, done, total, item });
    })?;
    let has_converted = connected.converted.is_some();
    *state.converted.lock().unwrap() = connected.converted;
    Ok(Opened {
        path: manager.current_path().unwrap_or(path),
        tables: manager.list_tables()?,
        source: connected.source,
        converted: has_converted,
    })
}

// NIVEL BASICO: Fecha o banco (File > Close); o SQLite convertido que ainda existir e apagado
#[tauri::command(async)]
fn close_database(state: State<'_, AppState>) {
    state.converted.lock().unwrap().take();
    state.db_manager.lock().unwrap().close();
}

// NIVEL BASICO: Salva o SQLite convertido em `path`. overwrite = false recusa arquivo existente ([[err.exists]])
// (a escolha lembrada na sessao grava sem dialogo; com arquivo no caminho a interface abre o dialogo)
#[tauri::command(async)]
fn save_converted(path: String, overwrite: bool, state: State<'_, AppState>) -> Result<(), String> {
    let target = Path::new(&path);
    let source = state.db_manager.lock().unwrap().current_path();
    if source.is_some_and(|s| same_file(&s, target)) {
        return Err("[[err.sameFile]]".to_string());
    }
    if !overwrite && target.exists() {
        return Err(format!("[[err.exists]] {path}"));
    }
    let mut slot = state.converted.lock().unwrap();
    let lite = slot.take().ok_or("[[err.noConverted]]")?;
    lite.save(target).map_err(|(lite, e)| {
        *slot = Some(lite); // nao salvou: o temporario continua valendo
        e
    })
}

// NIVEL BASICO: Apaga o SQLite convertido
#[tauri::command(async)]
fn discard_converted(state: State<'_, AppState>) {
    state.converted.lock().unwrap().take();
}

// NIVEL BASICO: Sai do app depois que a interface resolveu o SQLite convertido
#[tauri::command]
fn exit_app(app: AppHandle, state: State<'_, AppState>) {
    state.exiting.store(true, Ordering::SeqCst);
    state.converted.lock().unwrap().take();
    app.exit(0);
}

// NIVEL BASICO: GetTableData retorna ate `limit` linhas (default 100) que passam pelos filtros e pela pesquisa
#[tauri::command(async)]
fn get_table_data(
    table_name: String,
    limit: i32,
    filters: Vec<Filter>,
    search: String,
    state: State<'_, AppState>,
) -> Result<Vec<serde_json::Value>, String> {
    let manager = state.db_manager.lock().unwrap();
    let limit = if limit <= 0 { 100 } else { limit };
    manager.query_table(&table_name, limit, &filters, &search)
}

// NIVEL BASICO: GetRowCount retorna quantas linhas passam pelos filtros e pela pesquisa (sem nada: o total)
#[tauri::command(async)]
fn get_row_count(table_name: String, filters: Vec<Filter>, search: String, state: State<'_, AppState>) -> Result<i64, String> {
    state.db_manager.lock().unwrap().get_row_count(&table_name, &filters, &search)
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

// NIVEL BASICO: Exporta. scope = "database" (format sqlite, duckdb ou xlsx), "table" ou "sql" (csv ou xlsx)
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
) -> Result<Summary, String> {
    let (conn, source_path) = {
        let manager = state.db_manager.lock().unwrap();
        (manager.export_connection()?, manager.current_path())
    };
    let target = Path::new(&path);
    if source_path.is_some_and(|s| same_file(&s, target)) {
        return Err("[[err.sameFile]]".to_string());
    }
    state.cancel_export.store(false, Ordering::SeqCst);
    let mut progress = |done: usize, total: usize, item: &str| -> Result<(), String> {
        if state.cancel_export.load(Ordering::SeqCst) {
            return Err("[[err.exportCancelled]]".to_string());
        }
        let _ = app.emit("export-progress", Progress { done, total, item });
        Ok(())
    };
    match scope.as_str() {
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
    }
}

#[tauri::command]
fn cancel_export(state: State<'_, AppState>) {
    state.cancel_export.store(true, Ordering::SeqCst);
}

// Barra de titulo da janela; a versao vem do Cargo.toml (fonte unica)
const WINDOW_TITLE: &str = concat!("mdb2sql ", env!("CARGO_PKG_VERSION"), " - Rust");

// Os dois unicos enderecos que o app abre no navegador; capabilities/default.json libera so estes
// para o plugin opener (cargo test confere que as duas listas sao iguais)
const LINKS: [(&str, &str); 2] = [
    ("GitHub", "https://github.com/mauriciomenon/mdb2sql"),
    ("GitLab", "https://gitlab.com/mauricio.menon/mdb2sql"),
];

// motor da janela de cada sistema (o Tauri usa o webview do sistema)
const WEBVIEW: &str = if cfg!(windows) { "WebView2" } else if cfg!(target_os = "macos") { "WKWebView" } else { "WebKitGTK" };

// NIVEL BASICO: Dados do dialogo Sobre. Rotulos e frases ficam nos catalogos de idioma da interface; daqui vem so
// o que e dado: versoes, build e como o Access e lido
#[derive(Serialize)]
struct About {
    version: &'static str,
    build: String,
    stack: String,
    webview: String,
    engines: String,
    access_odbc: bool,
    mdbtools: &'static str,
    mdbtools_embedded: bool,
    author: &'static str,
    links: [(&'static str, &'static str); 2],
}

// NIVEL TECNICO: The version comes from Cargo.toml (single source), build number and date from the
// official build (build.rs). Runtime versions are read when the dialog opens; Svelte reports its
// own version from the webview, the Rust compiler version is captured by build.rs
#[tauri::command]
fn about(svelte_version: String) -> About {
    let duckdb = duckdb::Connection::open_in_memory()
        .and_then(|conn| conn.query_row("SELECT version()", [], |row| row.get::<_, String>(0)))
        .unwrap_or_else(|e| format!("? ({e})"));
    let webview = tauri::webview_version().unwrap_or_else(|_| "?".to_string());
    About {
        version: env!("CARGO_PKG_VERSION"),
        build: env!("BUILD_LABEL").trim_start_matches("build ").to_string(),
        stack: format!("Rust {} + Tauri {} + Svelte {svelte_version}", env!("RUSTC_VERSION"), tauri::VERSION),
        webview: format!("{WEBVIEW} {webview}"),
        // ordem do app: SQLite antes de DuckDB
        engines: format!("SQLite {}, DuckDB {duckdb}", rusqlite::version()),
        access_odbc: backend::access::odbc_installed(),
        mdbtools: backend::access::MDBTOOLS_VERSION,
        mdbtools_embedded: backend::access::mdbtools_embedded(),
        author: "Mauricio Menon",
        links: LINKS,
    }
}

fn main() {
    // NIVEL BASICO: Builder pattern cria app Tauri
    // invoke_handler registra comandos disponiveis para frontend
    // run() inicia event loop (janela fica aberta ate fechar)

    // o app caiu antes? apaga os SQLite convertidos que ficaram para tras
    converted::clean_stale(&converted::temp_dir());

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(AppState {
            db_manager: Mutex::new(DBManager::new()),
            cancel_export: AtomicBool::new(false),
            converted: Mutex::new(None),
            exiting: AtomicBool::new(false),
        })
        .invoke_handler(tauri::generate_handler![
            startup_path,
            load_database,
            close_database,
            save_converted,
            discard_converted,
            exit_app,
            get_table_data,
            get_row_count,
            get_table_schema,
            run_sql,
            export,
            cancel_export,
            about
        ])
        // fechar a janela com SQLite convertido pendente: a interface pergunta salvar/apagar/cancelar e chama exit_app
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                let state = window.state::<AppState>();
                if !state.exiting.load(Ordering::SeqCst) && state.converted.lock().unwrap().is_some() {
                    api.prevent_close();
                    let _ = window.emit("close-requested", ());
                }
            }
        })
        .setup(|app| {
            // NIVEL TECNICO: Setup hook, executa antes de mostrar janela
            let window = app.get_webview_window("main").expect("main window");
            window.set_title(WINDOW_TITLE)?;
            #[cfg(debug_assertions)]
            window.open_devtools();
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            // saida por qualquer caminho: nada de temporario orfao deste processo
            if let tauri::RunEvent::Exit = event {
                app.state::<AppState>().converted.lock().unwrap().take();
                converted::remove_own(&converted::temp_dir());
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn about_has_version_build_stack_engines_and_links() {
        let about = about("5.0.0".to_string());
        assert_eq!(about.version, "1.3.0");
        // "123 (2026-11-15)" no build oficial, "dev" fora dele
        let official = about.build.split_once(" (").is_some_and(|(n, d)| {
            n.parse::<u32>().is_ok() && d.len() == 11 && d.ends_with(')') && d.as_bytes()[4] == b'-'
        });
        assert!(about.build == "dev" || official, "{}", about.build);
        let stack = format!("Rust {} + Tauri {} + Svelte 5.0.0", env!("RUSTC_VERSION"), tauri::VERSION);
        assert_eq!(about.stack, stack);
        assert!(!stack.contains("unknown") && stack.starts_with("Rust 1.") && stack.contains(" + Tauri 2."));
        assert!(about.webview.starts_with(WEBVIEW), "{}", about.webview);
        assert!(about.engines.starts_with("SQLite 3.") && about.engines.contains(", DuckDB v"), "{}", about.engines);
        assert_eq!(about.mdbtools, "1.0.1");
        assert_eq!(about.author, "Mauricio Menon");
        assert_eq!(
            about.links,
            [
                ("GitHub", "https://github.com/mauriciomenon/mdb2sql"),
                ("GitLab", "https://gitlab.com/mauricio.menon/mdb2sql")
            ]
        );
    }

    // o build oficial (MDB2SQL_REQUIRE_MDBTOOLS=1, scripts de build) sempre leva o mdbtools dentro do exe
    #[test]
    fn official_build_embeds_mdbtools() {
        if option_env!("MDB2SQL_REQUIRE_MDBTOOLS") == Some("1") {
            assert!(backend::access::mdbtools_embedded());
        }
    }

    // o plugin opener so pode abrir os dois links do Sobre: nada de abrir URL ou arquivo qualquer
    #[test]
    fn opener_is_allowed_only_for_the_about_links() {
        let text = std::fs::read_to_string("capabilities/default.json").unwrap();
        let conf: serde_json::Value = serde_json::from_str(&text).unwrap();
        let opener: Vec<&serde_json::Value> = conf["permissions"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|p| p.to_string().contains("opener") || p.to_string().contains("shell"))
            .collect();
        let urls: Vec<&str> = LINKS.iter().map(|(_, url)| *url).collect();
        let expected = serde_json::json!({
            "identifier": "opener:allow-open-url",
            "allow": urls.iter().map(|url| serde_json::json!({ "url": url })).collect::<Vec<_>>(),
        });
        assert_eq!(opener, [&expected]);
        assert!(urls.iter().all(|url| url.starts_with("https://") && !url.contains('*')));
    }

    #[test]
    fn window_title_is_short_and_shows_the_version() {
        assert_eq!(WINDOW_TITLE, "mdb2sql 1.3.0 - Rust");
        assert_eq!(WINDOW_TITLE, format!("mdb2sql {} - Rust", env!("CARGO_PKG_VERSION")));
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

    // GPL v2 ou posterior: texto integral no LICENSE (vai no zip e nos instaladores) e metadados; a linha do
    // Sobre esta nos catalogos de idioma (ui/src/i18n.test.js)
    #[test]
    fn license_is_gpl2_or_later_everywhere() {
        let text = std::fs::read_to_string("LICENSE").unwrap();
        let mut lines = text.lines().map(str::trim);
        assert_eq!(lines.next(), Some("GNU GENERAL PUBLIC LICENSE"));
        assert!(lines.next().unwrap().starts_with("Version 2, June 1991"));
        assert_eq!(env!("CARGO_PKG_LICENSE"), "GPL-2.0-or-later");
        let json = |path: &str| -> serde_json::Value {
            serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
        };
        assert_eq!(json("ui/package.json")["license"], "GPL-2.0-or-later");
        let bundle = &json("tauri.conf.json")["bundle"];
        assert_eq!(bundle["license"], "GPL-2.0-or-later");
        assert_eq!(bundle["resources"], serde_json::json!(["LICENSE"]));
    }
}
