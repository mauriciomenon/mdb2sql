# Guia Extensivo de Conceitos em Rust + Tauri + Svelte

> [!info]
> Referencia detalhada (equivalente a 20 pgs) sobre fundamentos de Rust, integracao Tauri e interop com Svelte/DuckDB para o MDB2SQL.

## Sumario
- 01. Filosofia Rust e Mindset de Safety
- 02. Toolchain, Cargo e Layout do Projeto
- 03. Ownership, Borrowing e Lifetimes
- 04. Tipos Basicos, Structs, Enums e Pattern Matching
- 05. Traits, Implementacoes e Generics
- 06. Erros: Result, thiserror, anyhow
- 07. Memory Management, RAII e Drop
- 08. Concurrency: Threads, Sync, Send
- 09. Async Rust (tokio) e quando usar
- 10. Colecoes, Iterators e Functional Style
- 11. Filesystem, Paths e BufReader/Writer
- 12. DuckDB via duckdb crate e database/sql-like patterns
- 13. FFI, C-ABI e Integracao com Python/Go
- 14. Macros, Derives e Ergonomia
- 15. Testing, Property Tests e Benchs
- 16. Profiling, Perf e Otimizacao
- 17. Tauri Basics: Commands, State, Events
- 18. Bridge com Svelte: invoke, events e payloads
- 19. Build, Assinatura e Distribuicao Multi-OS
- 20. Segurança, Config e Checklists
- 21. Roteiro de Estudo e Snippets Uteis

## 01. Filosofia Rust e Mindset de Safety
- Zero-cost abstractions: performance de C com garantias de memoria.
- Sem GC: regras de ownership garantem ausencia de data races e dangling pointers.
- Erros em compile-time preferidos; warnings como erros em CI.

## 02. Toolchain, Cargo e Layout do Projeto
- `rustup` gerencia toolchains; usar nightly apenas se necessario.
- Cargo organiza pacotes, features e profiles (`dev`, `release`).
- Layout: `src/` com `main.rs` (Tauri), `backend/` para logica de dominio, `src-tauri/` configs Tauri, `ui/` Svelte separado.
- Workspaces permitem compartilhar crates se surgirem libs comuns.

## 03. Ownership, Borrowing e Lifetimes
- Cada valor possui um owner; move eh default; clone explicito.
- Borrow imutavel (`&T`) pode ser multiplo; borrow mutavel (`&mut T`) e exclusivo.
- Lifetimes anotadas quando referencias vivem alem do escopo implicito (pouco necessario em alto nivel).
- Evitar `Rc<RefCell<_>>` em excesso; preferir arc+mutex ou passar ownership claro.

## 04. Tipos Basicos, Structs, Enums e Pattern Matching
- Tipos primarios: `i64`, `u64`, `f64`, `String`, `&str`, `Vec<T>`, `HashMap<K, V>`.
- Structs para DTOs (linhas de tabela); derive `Serialize/Deserialize` para IPC com Svelte.
- Enums modelam estados de UI e resultados (Success/Error/Loading) de forma segura.
- Pattern matching com `match` e `if let` simplifica destruturacao de enums.

## 05. Traits, Implementacoes e Generics
- Traits definem comportamento; implementacoes para tipos concretos.
- Traits comuns: `Display`, `Debug`, `From`, `Into`, `AsRef`.
- Generics com bounds: `fn render<T: Serialize>(data: &T) { ... }`.
- Blanket impls e `From`/`TryFrom` para conversoes entre DTOs e modelos da base.

## 06. Erros: Result, thiserror, anyhow
- Fluxo normal retorna `Result<T, E>`; usar `?` para propagacao limpa.
- `thiserror` para definir erros de dominio legiveis traz mensagens e fontes.
- `anyhow` para erros dinamicos em binarios; facilita contexto com `.context("loading db")`.
- Logar erro na borda (handler Tauri) e retornar mensagem amigavel ao frontend.

## 07. Memory Management, RAII e Drop
- Recursos fecham sozinhos quando saem de escopo (`Drop`).
- `Arc<T>` para compartilhamento thread-safe; `Mutex`/`RwLock` para mutabilidade controlada.
- Evite clones desnecessarios de grandes DataFrames; use referencias ou iteradores streaming.

## 08. Concurrency: Threads, Sync, Send
- Tipos `Send` podem cruzar threads; `Sync` permite referencias compartilhadas.
- `std::thread::spawn` para trabalhos paralelos CPU-bound.
- Canary: nao manter `Connection` de DuckDB compartilhando mutabilidade sem lock; usar `Mutex<Connection>` ou criar novas conexoes isoladas.
- `crossbeam` ou `rayon` para paralelismo de colecoes quando fizer sentido.

## 09. Async Rust (tokio) e quando usar
- Tauri roda sincronamente; inserir async requer habilitar runtime (tokio) ou usar `tauri::async_runtime`.
- Async util para I/O de disco em pipelines longos ou redes; para DuckDB local, sync pode ser suficiente.
- Evitar misturar sync/async sem necessidade; mantenha API consistente.

## 10. Colecoes, Iterators e Functional Style
- Iterators permitem pipeline imutavel: `rows.iter().map(...).filter(...).collect::<Vec<_>>()`.
- `fold`/`try_fold` para reducoes; `enumerate` para indices.
- `HashMap` nao ordenado; use `BTreeMap` para ordenacao deterministica.
- Aproveitar slicing de `Vec` para evitar alocacoes extras.

## 11. Filesystem, Paths e BufReader/Writer
- `std::fs` para leitura/escrita; `PathBuf` para paths multiplataforma.
- `BufReader`/`BufWriter` reduzem syscalls para arquivos grandes.
- Validar existencia e permissao de `data/` antes de iniciar Tauri.
- Nunca construir path com string concatenada; use `push`/`join` em `PathBuf`.

## 12. DuckDB via duckdb crate e database/sql-like patterns
- Crate `duckdb` provê `Connection`, `Statement`, `Result`; usar `?access_mode=read_only`.
- Statements preparados: `let mut stmt = conn.prepare("SELECT * FROM tbl WHERE name LIKE ?")?;`.
- Mapeamento para `serde_json::Value` quando retorno heterogeneo; ou struct tipado via `row.get::<_, i64>(0)?`.
- Criar camada `DbManager` para abrir/fechar e listar tabelas, isolando IPC de SQL bruto.

## 13. FFI, C-ABI e Integracao com Python/Go
- Exportar funcoes `extern "C"` com tipos simples (primitives, pointers) e `#[no_mangle]`.
- Converter `String` para `CString`/`CStr` na borda; gerenciar ownership de buffers.
- Evitar panics no FFI; retornar codigos de erro e manter invariantes claros.
- Usar `pyo3`/`cbindgen` se for gerar bindings automaticamente quando necessario.

## 14. Macros, Derives e Ergonomia
- Derives padrao: `Debug`, `Clone`, `Serialize`, `Deserialize`, `Default`.
- Macros utilitarias: `vec![]`, `format!`, `include_str!` para assets pequenos.
- Criar macro leve para logs contextualizados se repeticao aumentar.

## 15. Testing, Property Tests e Benchs
- `cargo test` roda suite; mod de testes dentro do modulo com `#[cfg(test)]`.
- Fake DB: usar DuckDB in-memory (`duckdb://:memory:`) para testes de logica.
- Property tests com `proptest` para verificar invariantes em mapeamento de tabelas.
- Benchmarks (criterion) para funcoes pesadas de diff/merge.

## 16. Profiling, Perf e Otimizacao
- `cargo flamegraph` (via inferno) para visualizar hotspots.
- `cargo bloat` para medir tamanho de binario e funcoes pesadas.
- Compile `release` com `-C target-cpu=native` se permitido; manter `debug-assertions=false` para release.
- Micro-opt so apos medir; priorizar clareza e invariantes.

## 17. Tauri Basics: Commands, State, Events
- Comandos: funcoes marcadas com `#[tauri::command]` expostas para JS.
- `AppState` compartilhado via `tauri::State<'_, AppState>`; armazene `DbManager`, config, caches.
- Eventos: `app_handle.emit_all("db-loaded", payload)?;` para notificar Svelte.
- Window management: `tauri::Manager` disponibiliza handles; evitar bloquear thread de evento.

## 18. Bridge com Svelte: invoke, events e payloads
- Frontend chama: `invoke('load_database', { dbPath })`.
- Payloads devem ser `Serialize`; manter nomes em `snake_case` no Rust e camelCase no JS se preferir (converter no frontend).
- Erros retornados viram rejected Promise; incluir mensagem amigavel e campo tecnico opcional.
- Considere throttling para eventos de progresso para nao saturar UI.

## 19. Build, Assinatura e Distribuicao Multi-OS
- `cargo tauri dev` para hot reload; `cargo tauri build` gera binarios em `src-tauri/target/release`.
- Checar dependencias de plataforma (webkit2gtk em Linux, signtool em Windows).
- Assinatura de código: usar certificados adequados; Tauri suporta bundlers (MSIX/DMG/AppImage).
- Empacote assets do `ui/dist` embutidos no binario; garantir paths relativos seguros.

## 20. Segurança, Config e Checklists
- Sanitizar entradas: queries parametrizadas, whitelist de tabelas.
- Armazenar configuracao mutavel em dir de usuario; padroes somente leitura em `config/`.
- Prevenir panics: usar `expect` somente em invariantes internas fortes; preferir `?` + erro contextualizado.
- Checklists de PR: fmt (`cargo fmt`), lint (`cargo clippy -- -D warnings`), tests, revisao de eventos Tauri, revisao de IPC payloads.

## 21. Roteiro de Estudo e Snippets Uteis
- Sequencia sugerida:
  1. Ownership e borrowing hands-on (2h)
  2. Traits + Result + error handling (2h)
  3. Iterators e colecoes (2h)
  4. Concurrency básica + Send/Sync (2h)
  5. DuckDB + serde (3h)
  6. Tauri commands + invoke (3h)
- Snippets:
```rust
#[tauri::command]
pub fn list_tables(state: State<AppState>) -> Result<Vec<String>, String> {
    state.db_manager.list_tables().map_err(|e| e.to_string())
}

// Execute query com timeout sync
use std::time::{Duration, Instant};
use duckdb::Connection;
fn run_query(conn: &Connection, sql: &str) -> anyhow::Result<Vec<Row>> {
    let start = Instant::now();
    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map([], |row| Ok(Row::from_row(row)))?
        .collect::<Result<Vec<_>, _>>()?;
    let dur = start.elapsed();
    tracing::info!(?dur, "query done");
    Ok(rows)
}
```

