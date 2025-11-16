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

## PROJECT STRUCTURE

```
rust_tauri_svelte/
├── src/                    # Rust backend
│   ├── main.rs            # entry point
│   ├── db/                # DuckDB interface
│   ├── search/            # search engine
│   ├── diff/              # comparison engine
│   └── commands.rs        # Tauri commands exposed to frontend
├── ui/                    # Svelte frontend
│   ├── src/
│   │   ├── App.svelte
│   │   ├── lib/           # components
│   │   └── stores/        # state management
│   └── package.json
├── config/                # schemas, mappings
├── data/                  # converted DuckDB files
├── importacao/            # original MDB files
├── Cargo.toml             # Rust dependencies
└── tauri.conf.json        # Tauri configuration
```

---

## KEY CONCEPTS

### Tauri Commands
Rust functions exposed to JavaScript via `#[tauri::command]`

```rust
#[tauri::command]
fn search_term(term: String) -> Result<Vec<Row>, String> {
    // Rust implementation
}
```

Called from Svelte:
```javascript
import { invoke } from '@tauri-apps/api/tauri';
const results = await invoke('search_term', { term: 'example' });
```

### DuckDB Rust
```rust
use duckdb::{Connection, Result};

let conn = Connection::open("data/202511_db1.duckdb")?;
let mut stmt = conn.prepare("SELECT * FROM table1")?;
let rows = stmt.query_map([], |row| {
    // map row to struct
})?;
```

### Svelte Reactivity
```svelte
<script>
  let searchTerm = '';
  $: results = searchDatabase(searchTerm); // auto-updates when searchTerm changes
</script>

<input bind:value={searchTerm} />
{#each results as row}
  <div>{row.field}</div>
{/each}
```

---

## CURRENT STATUS

- [ ] Tauri initialized
- [ ] DuckDB Rust binding integrated
- [ ] Basic UI scaffold
- [ ] Load last database
- [ ] Display table

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
