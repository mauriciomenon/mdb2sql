# RUST + TAURI + SVELTE IMPLEMENTATION

---

## STACK

- **Backend**: Rust (performance, memory safety)
- **Frontend**: Svelte (reactive, minimal bundle)
- **Bridge**: Tauri (native, lightweight vs Electron)
- **Database**: DuckDB (embedded analytics)

---

## PREREQUISITES

### System
- Rust 1.70+ (`cargo --version`)
- Node.js 18+ (`node --version`)
- pnpm 10+ (`pnpm --version`)

### Platform Specific
- **macOS**: Xcode Command Line Tools
- **Linux**: build-essential, libwebkit2gtk-4.0-dev
- **Windows**: Visual Studio Build Tools

---

## QUICK START

```bash
cd rust_tauri_svelte
cargo tauri dev  # live reload dev mode
```

Or build:
```bash
cargo tauri build  # production binary in src-tauri/target/release/
```

---

## SETUP

```bash
# Install Tauri CLI
cargo install tauri-cli

# Install pnpm (if not installed)
npm install -g pnpm

# Install frontend deps
cd ui
pnpm install

# Run dev mode
cd ..
cargo tauri dev

# Build production
cargo tauri build
```

---

## CURRENT STATUS

- [x] Tauri initialized
- [x] DuckDB Rust binding integrated (backend/db_manager.rs)
- [x] Basic Svelte UI
- [x] Tauri commands (load_database, get_table_data, get_row_count)
- [x] Feature 1: Load and display table
- [ ] Search functionality
- [ ] Multi-DB operations
- [ ] Diff engine

---

## PROJECT STRUCTURE

```
rust_tauri_svelte/
├── src/                    # Rust backend
│   ├── main.rs            # Tauri entry point with commands
│   └── backend/           # Business logic
│       ├── mod.rs
│       └── db_manager.rs  # DuckDB connection manager
├── ui/                    # Svelte frontend
│   ├── src/
│   │   ├── App.svelte     # Main component with table viewer
│   │   └── main.js        # Svelte entry
│   └── package.json       # pnpm dependencies
├── build.rs               # Tauri build script
├── Cargo.toml             # Rust dependencies
└── tauri.conf.json        # Tauri configuration
```

---

## KEY CONCEPTS

### Tauri Commands
Rust functions exposed to JavaScript via `#[tauri::command]`

```rust
#[tauri::command]
fn load_database(db_path: String, state: State<AppState>) -> Result<Vec<String>, String> {
    let manager = state.db_manager.lock().unwrap();
    manager.connect(&db_path)?;
    manager.list_tables()
}
```

Called from Svelte:
```javascript
import { invoke } from '@tauri-apps/api/tauri';
const tables = await invoke('load_database', { dbPath: '' });
```

### DuckDB Rust
```rust
use duckdb::{Connection, Result};

let conn_str = format!("{}?access_mode=read_only", db_path);
let conn = Connection::open(&conn_str)?;
let mut stmt = conn.prepare("SHOW TABLES")?;
let tables = stmt.query_map([], |row| row.get(0))?;
```

### Svelte Reactivity
```svelte
<script>
  let tables = [];
  let selectedTable = '';

  // Reactive statement: auto-updates when tableData changes
  $: columns = tableData.length > 0 ? Object.keys(tableData[0]) : [];

  async function loadDatabase() {
    tables = await invoke('load_database', { dbPath: '' });
  }
</script>

<select bind:value={selectedTable}>
  {#each tables as table}
    <option value={table}>{table}</option>
  {/each}
</select>
```

---

## LEARNING RESOURCES

### Rust Basics
- Ownership: cada valor tem um owner, sem garbage collector
- Borrowing: `&` empresta valor sem transferir ownership
- Result<T, E>: tratamento de erros explicito

### Tauri
- IPC: Inter-Process Communication entre Rust e JavaScript
- Commands: funcoes Rust chamadas do frontend
- Events: comunicacao bidirecional

### Svelte
- Reactive: `$:` marca statement reactivo
- Stores: estado compartilhado entre componentes
- No Virtual DOM: compila para JavaScript vanilla otimizado

---

**Next**: Initialize Tauri project structure
