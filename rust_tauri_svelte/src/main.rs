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
use backend::db_manager::{self, ColumnSchema, DBManager, Filter, Found, SqlResult, Step, TablePage};
use backend::display::DisplayWarning;
use backend::export::{self, Source, Summary};
use backend::terms::{self, TermHit};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager, State};

// NIVEL BASICO: Resultado da ultima pesquisa de termos: a conexao com as tabelas temporarias dos acertos e as tabelas
// com acerto, na ordem da lista
struct TermsRun {
    conn: duckdb::Connection,
    tables: Vec<String>,
}

// NIVEL BASICO: Estado global: banco aberto, pedido de cancelar a exportacao e o SQLite convertido do Access
// NIVEL TECNICO: `converted` has its own lock so the close button never waits for a long import holding
// db_manager; `exiting` lets the final close through after the user answered the question asked on exit
struct AppState {
    db_manager: Mutex<DBManager>,
    cancel_export: AtomicBool,
    exporting: AtomicBool, // exportacao em andamento: fechar a janela pergunta antes
    converted: Mutex<Option<Converted>>,
    exiting: AtomicBool,
    // numero da pesquisa em todas as tabelas mais nova: a anterior ve o numero mudar e para entre uma tabela e outra
    search_run: AtomicU64,
    // numero da pesquisa de termos que vale: outra pesquisa, Cancelar, fechar ou abrir um banco mudam o numero; a que
    // estava rodando para e o resultado dela nao e guardado
    terms_run: AtomicU64,
    terms: Mutex<Option<TermsRun>>,
    // para a consulta da pesquisa de termos em andamento (Cancelar no meio de uma tabela grande): (numero, alca)
    terms_interrupt: Mutex<Option<(u64, Arc<duckdb::InterruptHandle>)>>,
    // Linux sem X11: aviso de que a janela esta no Wayland (reserva); None no resto
    display_warning: Option<DisplayWarning>,
}

impl AppState {
    // outro banco (ou nenhum): a pesquisa de termos em andamento para e o resultado guardado some
    fn drop_terms(&self) {
        self.terms_run.fetch_add(1, Ordering::SeqCst);
        if let Some((_, handle)) = self.terms_interrupt.lock().unwrap().take() {
            handle.interrupt();
        }
        self.terms.lock().unwrap().take();
    }
}

// NIVEL BASICO: Banco aberto: caminho absoluto, tabelas e as linhas de cada uma (mesma ordem), por qual caminho foi
// lido e se ha SQLite convertido
#[derive(Serialize)]
struct Opened {
    path: String,
    // arquivo lido de fato: o mesmo `path`, ou o arquivo salvo quando o Access foi reaberto por ele (Salvar nao sugere
    // gravar por cima dele)
    file: String,
    tables: Vec<String>,
    rows: Vec<Option<i64>>, // None: a tabela nao deu para contar (a celula fica vazia)
    source: String,
    converted: bool,
    // pasta do temporario quando ele ficou ao lado do original: a interface guarda para a limpeza da proxima abertura
    beside: Option<String>,
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
// Caminho vazio: MDB2SQL_DB_PATH ou data/sample.duckdb. O SQLite convertido e nao salvo do banco anterior e apagado
// quando o novo banco abre (a interface poe a linha no Log).
// saved: o arquivo salvo deste mesmo Access (SQLite ou DuckDB), sem mudanca nos dois (a interface conferiu as chaves de
// file_key): e ele que abre, sem converter de novo nem perguntar ao sair; titulo e caminho na tela continuam os do Access
// NIVEL TECNICO: async so a long Access import runs off the main thread; progress goes as events
#[tauri::command(async)]
fn load_database(app: AppHandle, db_path: String, saved: Option<String>, state: State<'_, AppState>) -> Result<Opened, String> {
    let manager = state.db_manager.lock().unwrap();
    let path = if db_path.is_empty() {
        match std::env::var("MDB2SQL_DB_PATH") {
            Ok(env_path) if !env_path.is_empty() => env_path,
            _ => PathBuf::from("data").join("sample.duckdb").to_string_lossy().to_string(),
        }
    } else {
        db_path
    };
    let connected = manager.connect(saved.as_deref().unwrap_or(&path), &mut |step, done, total, item| {
        let _ = app.emit("open-progress", OpenProgress { step, done, total, item });
    })?;
    // abriu: a pesquisa de termos do banco anterior para e some (se falhar, o anterior e o resultado dele continuam)
    state.drop_terms();
    let has_converted = connected.converted.is_some();
    let beside = connected.converted.as_ref().and_then(Converted::beside).map(|dir| dir.to_string_lossy().into_owned());
    *state.converted.lock().unwrap() = connected.converted;
    let opened = match saved {
        Some(_) => manager.validate_database_path(&path).unwrap_or(path),
        None => manager.current_path().unwrap_or(path),
    };
    let tables = manager.list_tables()?;
    let rows = manager.table_rows(&tables)?;
    show_title(&app, Some(&opened));
    Ok(Opened {
        file: manager.current_path().unwrap_or_else(|| opened.clone()),
        path: opened,
        rows,
        tables,
        source: connected.source,
        converted: has_converted,
        beside,
    })
}

// NIVEL BASICO: Fecha o banco (Arquivo > Fechar); o SQLite convertido que ainda existir e apagado
#[tauri::command(async)]
fn close_database(app: AppHandle, state: State<'_, AppState>) {
    state.drop_terms();
    state.converted.lock().unwrap().take();
    state.db_manager.lock().unwrap().close();
    show_title(&app, None);
}

// NIVEL BASICO: Na abertura do app: apaga os SQLite convertidos que uma execucao anterior deixou (o app caiu), nas
// pastas temporarias e nas pastas de originais que a interface guardou; devolve quantos (linha do Log)
#[tauri::command(async)]
fn clean_stale(beside: Vec<String>) -> usize {
    converted::clean_all(&beside)
}

// NIVEL BASICO: Caixa de salvar de Arquivo > Salvar e Salvar como: types = [nome do tipo, extensao] na ordem do app,
// selected = o tipo ja marcado. Devolve [caminho, tipo marcado] ou null (cancelada)
#[tauri::command(async)]
fn save_dialog(
    window: tauri::WebviewWindow,
    title: String,
    path: String,
    types: Vec<(String, String)>,
    selected: usize,
) -> Option<(String, usize)> {
    backend::save_dialog::pick(&window, &title, Path::new(&path), &types, selected)
        .map(|(path, index)| (path.to_string_lossy().into_owned(), index))
}

// NIVEL BASICO: Apaga o SQLite convertido (banco salvo, ou fechado sem salvar)
#[tauri::command(async)]
fn discard_converted(state: State<'_, AppState>) {
    state.converted.lock().unwrap().take();
}

// NIVEL BASICO: Chave do arquivo (caminho, tamanho e data) para reconhecer o Access ja convertido e salvo; null se o
// arquivo nao existe
#[tauri::command(async)]
fn file_key(path: String) -> Option<String> {
    converted::file_key(Path::new(&path))
}

// NIVEL BASICO: Sai do app depois que a interface resolveu a exportacao em andamento e o SQLite convertido
#[tauri::command]
fn exit_app(app: AppHandle, state: State<'_, AppState>) {
    state.exiting.store(true, Ordering::SeqCst);
    state.drop_terms(); // pesquisa em andamento: cancela sem perguntar
    state.search_run.fetch_add(1, Ordering::SeqCst);
    state.converted.lock().unwrap().take();
    app.exit(0);
}

// NIVEL BASICO: Aviso de X11 indisponivel (Linux), mostrado pela interface ao abrir
#[tauri::command]
fn display_warning(state: State<'_, AppState>) -> Option<DisplayWarning> {
    state.display_warning.clone()
}

// NIVEL BASICO: GetTableData retorna ate `limit` linhas (default 100) a partir da `offset` (paginas) que passam pelos filtros e pela pesquisa e, a
// parte, as linhas marcadas (`marked` = identidades que a tela guarda), com a identidade de cada linha
#[tauri::command(async)]
fn get_table_data(
    table_name: String,
    limit: i32,
    offset: i64,
    filters: Vec<Filter>,
    search: String,
    marked: Vec<serde_json::Value>,
    state: State<'_, AppState>,
) -> Result<TablePage, String> {
    let manager = state.db_manager.lock().unwrap();
    let limit = if limit <= 0 { 100 } else { limit };
    manager.table_page(&table_name, limit, offset.max(0), &filters, &search, &marked)
}

// NIVEL BASICO: GetRowCount retorna quantas linhas passam pelos filtros e pela pesquisa (sem nada: o total)
#[tauri::command(async)]
fn get_row_count(table_name: String, filters: Vec<Filter>, search: String, state: State<'_, AppState>) -> Result<i64, String> {
    state.db_manager.lock().unwrap().get_row_count(&table_name, &filters, &search)
}

// NIVEL BASICO: Pesquisa da aba Data em todas as tabelas: cada tabela com linhas achadas e quantas. Uma pesquisa
// nova faz a anterior parar na proxima tabela (digitar t, te, ten nao enfileira tres pesquisas inteiras no lock)
#[tauri::command(async)]
fn search_all_tables(search: String, state: State<'_, AppState>) -> Result<Vec<Found>, String> {
    let run = state.search_run.fetch_add(1, Ordering::SeqCst) + 1;
    let stop = || state.search_run.load(Ordering::SeqCst) != run;
    state.db_manager.lock().unwrap().search_tables(&search, &stop)
}

// NIVEL BASICO: GetTableSchema retorna schema da tabela
#[tauri::command(async)]
fn get_table_schema(table_name: String, state: State<'_, AppState>) -> Result<Vec<ColumnSchema>, String> {
    state.db_manager.lock().unwrap().get_table_schema(&table_name)
}

// NIVEL BASICO: SQL da aba SQL (so comandos de leitura), ate `limit` linhas
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

// NIVEL BASICO: Recusa gravar por cima do arquivo aberto ou do temporario da conversao ([[err.sameFile]])
fn check_target(state: &AppState, target: &Path) -> Result<(), String> {
    let open = state.db_manager.lock().unwrap().current_path();
    let temp = state.converted.lock().unwrap().as_ref().map(|lite| lite.path().to_string_lossy().into_owned());
    if open.into_iter().chain(temp).any(|source| same_file(&source, target)) {
        return Err("[[err.sameFile]]".to_string());
    }
    Ok(())
}

// NIVEL BASICO: Pedido de exportacao da interface. scope: "database" (Arquivo > Salvar: sqlite, duckdb ou xlsx), "converted"
// (Arquivo > Salvar do Access convertido em SQLite: a copia do temporario),
// "table" (tabela atual; com filtros ou pesquisa, so as linhas que a grade achou), "marked" (linhas marcadas: ids),
// "schema" (da tabela, ou do banco sem tabela; labels = titulos), "sql" (resultado do SQL), "found" (resultado da
// busca em todas as tabelas, xlsx), "tables" (todas as tabelas em CSV; path = pasta) e "terms" (relatorio da
// pesquisa de termos: xlsx, sqlite, duckdb ou csv numa pasta; labels = titulos e nomes das abas)
#[derive(Deserialize)]
struct ExportRequest {
    scope: String,
    format: String,
    path: String,
    table: Option<String>,
    sql: Option<String>,
    #[serde(default)]
    filters: Vec<Filter>,
    #[serde(default)]
    search: String,
    #[serde(default)]
    ids: Vec<serde_json::Value>,
    #[serde(default)]
    labels: Vec<String>,
}

// marca "exportando" enquanto vive (fechar a janela pergunta antes de sair)
struct Exporting<'a>(&'a AtomicBool);

impl Drop for Exporting<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

// NIVEL BASICO: Exporta (ou salva o banco) conforme o pedido
// NIVEL TECNICO: runs on its own DuckDB connection, so the grid keeps working; progress goes as
// "export-progress" events and cancel_export stops it at the next table or every 10.000 rows
#[tauri::command(async)]
fn export(app: AppHandle, state: State<'_, AppState>, request: ExportRequest) -> Result<Summary, String> {
    let conn = state.db_manager.lock().unwrap().export_connection()?;
    let target = Path::new(&request.path);
    check_target(&state, target)?;
    state.cancel_export.store(false, Ordering::SeqCst);
    state.exporting.store(true, Ordering::SeqCst);
    let _exporting = Exporting(&state.exporting);
    let cancelled = || state.cancel_export.load(Ordering::SeqCst);
    let mut progress = |done: usize, total: usize, item: &str| -> Result<(), String> {
        if cancelled() {
            return Err("[[err.exportCancelled]]".to_string());
        }
        let _ = app.emit("export-progress", Progress { done, total, item });
        Ok(())
    };
    let table = || request.table.clone().ok_or("No table selected");
    let format = request.format.as_str();
    match request.scope.as_str() {
        "database" => export::export_database(&conn, format, target, &mut progress),
        // Arquivo > Salvar do Access convertido em SQLite: copia o temporario (a caixa de salvar ja perguntou se
        // substitui); ele continua ate a interface dizer que o banco esta salvo (discard_converted)
        "converted" => {
            // o caminho sai do lock antes de copiar: o X da janela (on_window_event) le o mesmo lock na thread da interface
            let source = state.converted.lock().unwrap().as_ref().ok_or("[[err.noConverted]]")?.path().to_path_buf();
            progress(0, 1, &request.path)?;
            export::via_partial(target, |partial| std::fs::copy(&source, partial).map(|_| ()).map_err(|e| e.to_string()))
                .map(|_| Summary { count: 1, sheets: None })
        }
        "table" => {
            let table = table()?;
            let source = if request.filters.is_empty() && request.search.trim().is_empty() {
                Source::Table(table)
            } else {
                let (filter, params) = state.db_manager.lock().unwrap().rows_where(&table, &request.filters, &request.search)?;
                Source::Rows(table, filter, params)
            };
            export::export_source(&conn, &source, format, target, &mut progress)
        }
        "marked" => {
            let table = table()?;
            let (filter, params) = state.db_manager.lock().unwrap().marked_where(&table, &request.ids)?;
            export::export_source(&conn, &Source::Rows(table, filter, params), format, target, &mut progress)
        }
        "schema" => {
            let name = target.file_stem().map_or("schema".into(), |stem| stem.to_string_lossy().into_owned());
            let select = db_manager::schema_select(request.table.as_deref(), &request.labels)?;
            export::export_source(&conn, &Source::Query(name, select), format, target, &mut progress)
        }
        "sql" => {
            let sql = request.sql.clone().ok_or("No SQL to export")?;
            state.db_manager.lock().unwrap().check_read_only(&sql)?;
            let source = Source::Sql(sql);
            // como na aba SQL: o que o resultado rodar e desfeito no fim
            db_manager::rolled_back(&conn, |conn| export::export_source(conn, &source, format, target, &mut progress))
        }
        "found" => {
            // as tabelas que a busca acha e, de cada uma, as linhas achadas (a mesma regra da grade)
            let sources = {
                let manager = state.db_manager.lock().unwrap();
                let found = manager.search_tables(&request.search, &cancelled);
                let found = found.map_err(|e| if cancelled() { "[[err.exportCancelled]]".to_string() } else { e })?;
                let rows = |f: Found| manager.rows_where(&f.table, &[], &request.search).map(|(filter, params)| Source::Rows(f.table, filter, params));
                found.into_iter().map(rows).collect::<Result<Vec<_>, _>>()?
            };
            export::export_workbook(&conn, &sources, target, &mut progress)
        }
        "tables" => export::export_folder(&conn, &db_manager::list_tables(&conn)?, target, &mut progress),
        "terms" => {
            let slot = state.terms.lock().unwrap();
            let run = slot.as_ref().ok_or("[[err.searchCancelled]]")?;
            let names = terms::report(&run.conn, &run.tables, &request.labels)?;
            match format {
                "csv" => export::export_folder(&run.conn, &names, target, &mut progress),
                _ => export::write_tables(&run.conn, &names, format, target, &mut progress),
            }
        }
        other => Err(format!("Unknown export scope: {other}")),
    }
}

// NIVEL BASICO: Exportacao para pasta ("tables" e o relatorio de termos em CSV): quantos dos arquivos que ela grava ja
// existem ali (a interface pergunta uma vez so se substitui)
#[tauri::command(async)]
fn export_existing(state: State<'_, AppState>, request: ExportRequest) -> Result<usize, String> {
    let names = match request.scope.as_str() {
        "terms" => {
            let [.., result] = request.labels.as_slice() else {
                return Err("Term report needs 7 labels".to_string());
            };
            let slot = state.terms.lock().unwrap();
            terms::report_names(&slot.as_ref().ok_or("[[err.searchCancelled]]")?.tables, result)
        }
        _ => state.db_manager.lock().unwrap().list_tables()?,
    };
    Ok(export::csv_files(Path::new(&request.path), &names).iter().filter(|file| file.exists()).count())
}

#[tauri::command]
fn cancel_export(state: State<'_, AppState>) {
    state.cancel_export.store(true, Ordering::SeqCst);
}

// NIVEL BASICO: Pesquisa de termos (aba Termos): cada termo x tabela com acerto e quantas linhas. table = so esta
// tabela; sem ela, todas. O progresso vai como eventos "terms-progress"; cancel_terms (ou outra pesquisa) para
// NIVEL TECNICO: runs on a connection of its own, which stays in the state with the hit tables for the grid, the
// copy and the report; an older result is dropped before the new search starts
#[tauri::command(async)]
fn search_terms(
    app: AppHandle,
    terms: Vec<String>,
    whole: bool,
    table: Option<String>,
    state: State<'_, AppState>,
) -> Result<Vec<TermHit>, String> {
    state.drop_terms();
    let run = state.terms_run.load(Ordering::SeqCst);
    let stopped = || state.terms_run.load(Ordering::SeqCst) != run;
    let cancelled = || "[[err.searchCancelled]]".to_string();
    let (conn, tables) = {
        let manager = state.db_manager.lock().unwrap();
        let tables = match table {
            Some(table) => vec![table],
            None => manager.list_tables()?,
        };
        (manager.export_connection()?, tables)
    };
    *state.terms_interrupt.lock().unwrap() = Some((run, conn.interrupt_handle()));
    let found = terms::search(&conn, &terms, whole, &tables, &mut |done, total, item| {
        if stopped() {
            return Err(cancelled());
        }
        let _ = app.emit("terms-progress", Progress { done, total, item });
        Ok(())
    });
    state.terms_interrupt.lock().unwrap().take_if(|(owner, _)| *owner == run);
    // consulta interrompida no meio: o erro do motor vira "Pesquisa cancelada"
    let hits = found.map_err(|e| if stopped() { cancelled() } else { e })?;
    let mut slot = state.terms.lock().unwrap();
    if stopped() {
        return Err(cancelled());
    }
    let mut with_hits: Vec<String> = Vec::new();
    for hit in &hits {
        if with_hits.last() != Some(&hit.table) {
            with_hits.push(hit.table.clone());
        }
    }
    *slot = Some(TermsRun { conn, tables: with_hits });
    Ok(hits)
}

#[tauri::command]
fn cancel_terms(state: State<'_, AppState>) {
    state.drop_terms();
}

// NIVEL BASICO: Linhas achadas de uma tabela na ultima pesquisa de termos: o termo (titulo `label`) e as colunas da
// tabela; ate `limit` linhas (0 = todas, para copiar)
#[tauri::command(async)]
fn terms_rows(table: String, limit: usize, label: String, state: State<'_, AppState>) -> Result<SqlResult, String> {
    let slot = state.terms.lock().unwrap();
    let run = slot.as_ref().ok_or("[[err.searchCancelled]]")?;
    terms::rows(&run.conn, &table, &label, if limit == 0 { usize::MAX } else { limit })
}

// Barra de titulo da janela; a versao vem do Cargo.toml (fonte unica). tauri.conf.json repete o texto para a janela
// ja nascer com ele (cargo test confere)
const WINDOW_TITLE: &str = concat!("mdb2sql ", env!("CARGO_PKG_VERSION"), " - Rust");

// NIVEL BASICO: Titulo das 4 versoes: "{arquivo} - mdb2sql 1.3.0 - Rust" com banco aberto, "mdb2sql 1.3.0 - Rust" sem
fn window_title(path: Option<&str>) -> String {
    match path.and_then(|p| Path::new(p).file_name()) {
        Some(name) => format!("{} - {WINDOW_TITLE}", name.to_string_lossy()),
        None => WINDOW_TITLE.to_string(),
    }
}

fn show_title(app: &AppHandle, path: Option<&str>) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.set_title(&window_title(path));
    }
}

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

    // Linux: X11 primeiro, Wayland de reserva (antes do GTK iniciar); sem nenhum dos dois o processo sai aqui
    let x11_warning = backend::display::apply();

    // os SQLite convertidos que uma execucao anterior deixou (o app caiu) somem quando a interface abre: clean_stale

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(AppState {
            db_manager: Mutex::new(DBManager::new()),
            cancel_export: AtomicBool::new(false),
            exporting: AtomicBool::new(false),
            converted: Mutex::new(None),
            exiting: AtomicBool::new(false),
            search_run: AtomicU64::new(0),
            terms_run: AtomicU64::new(0),
            terms: Mutex::new(None),
            terms_interrupt: Mutex::new(None),
            display_warning: x11_warning,
        })
        .invoke_handler(tauri::generate_handler![
            startup_path,
            load_database,
            close_database,
            clean_stale,
            save_dialog,
            discard_converted,
            file_key,
            exit_app,
            display_warning,
            get_table_data,
            get_row_count,
            search_all_tables,
            get_table_schema,
            run_sql,
            export,
            export_existing,
            cancel_export,
            search_terms,
            cancel_terms,
            terms_rows,
            about
        ])
        // fechar a janela (X, Alt+F4) com exportacao em andamento ou SQLite convertido nao salvo: a interface pergunta
        // (Voltar / Sair; Salvar / Voltar / Sair) e chama exit_app
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                let state = window.state::<AppState>();
                let pending = state.exporting.load(Ordering::SeqCst) || state.converted.lock().unwrap().is_some();
                if !state.exiting.load(Ordering::SeqCst) && pending {
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
                for dir in converted::temp_dirs(None) {
                    converted::remove_own(&dir);
                }
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

    // o plugin opener so pode abrir os links do Sobre e a ajuda de X11: nada de abrir URL ou arquivo qualquer
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
        // os dois links do Sobre e a ajuda do aviso de X11 (Linux)
        let mut urls: Vec<&str> = LINKS.iter().map(|(_, url)| *url).collect();
        urls.push(backend::display::HELP_LINK);
        let expected = serde_json::json!({
            "identifier": "opener:allow-open-url",
            "allow": urls.iter().map(|url| serde_json::json!({ "url": url })).collect::<Vec<_>>(),
        });
        assert_eq!(opener, [&expected]);
        assert!(urls.iter().all(|url| url.starts_with("https://") && !url.contains('*')));
    }

    // padrao item 3: "{arquivo} - mdb2sql 1.3.0 - Rust" com arquivo aberto, "mdb2sql 1.3.0 - Rust" sem; a janela ja nasce
    // com o titulo sem arquivo (tauri.conf.json), nunca com outro texto antes do setup
    #[test]
    fn window_title_is_short_and_shows_the_version() {
        assert_eq!(WINDOW_TITLE, "mdb2sql 1.3.0 - Rust");
        assert_eq!(WINDOW_TITLE, format!("mdb2sql {} - Rust", env!("CARGO_PKG_VERSION")));
        assert_eq!(window_title(None), "mdb2sql 1.3.0 - Rust");
        if cfg!(windows) {
            assert_eq!(window_title(Some(r"C:\dados\DB4.accdb")), "DB4.accdb - mdb2sql 1.3.0 - Rust");
        }
        assert_eq!(window_title(Some("/home/u/x y.sqlite")), "x y.sqlite - mdb2sql 1.3.0 - Rust");
        let conf: serde_json::Value = serde_json::from_str(&std::fs::read_to_string("tauri.conf.json").unwrap()).unwrap();
        assert_eq!(conf["app"]["windows"][0]["title"], WINDOW_TITLE);
    }

    // padrao item 5: o mesmo mdb2sql.ico nas 4 versoes (exe, janela e instaladores); os PNG saem do mesmo desenho
    // (cargo tauri icon com o mdb2sql.png de 1024 px). Fora do repositorio inteiro (so esta pasta) o teste so confere o ico
    #[test]
    fn icon_is_the_shared_mdb2sql_ico() {
        let ico = std::fs::read("icons/icon.ico").unwrap();
        assert_eq!(u16::from_le_bytes([ico[4], ico[5]]), 7, "16, 24, 32, 48, 64, 128 e 256 px");
        for other in ["../python_pyqt6/src/resources/mdb2sql.ico", "../zig_imgui/assets/mdb2sql.ico", "../go_wails_react/build/windows/icon.ico"] {
            if let Ok(shared) = std::fs::read(other) {
                assert!(shared == ico, "icons/icon.ico differs from {other}");
            }
        }
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
