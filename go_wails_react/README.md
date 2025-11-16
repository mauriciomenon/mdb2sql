# GO + WAILS + REACT IMPLEMENTATION

---

## STACK

- **Backend**: Go (simplicity, concurrency, fast compilation)
- **Frontend**: React (flexible, mature ecosystem)
- **Bridge**: Wails (Go alternative to Electron/Tauri)
- **Database**: DuckDB (embedded analytics)

---

## PREREQUISITES

### System
- Go 1.21+ (`go version`)
- Node.js 18+ (`node --version`)
- pnpm 10+ (`pnpm --version`)

### Platform Specific
- **macOS**: Xcode Command Line Tools
- **Linux**: build-essential, gtk+3, webkit2gtk
- **Windows**: WebView2 runtime, gcc (mingw-w64)

---

## SETUP

```bash
# Install Wails CLI (optional, manual setup works)
go install github.com/wailsapp/wails/v2/cmd/wails@latest

# Install pnpm (if not installed)
npm install -g pnpm

# Install Go dependencies
go mod tidy

# Install frontend dependencies
cd frontend
pnpm install
cd ..

# Run dev mode (if wails CLI available)
wails dev

# Or manual dev (without wails CLI)
cd frontend && pnpm run dev &
go run .

# Build production
wails build
```

---

## PROJECT STRUCTURE

```
go_wails_react/
├── backend/                # Go backend
│   ├── app.go             # main app struct
│   ├── db/                # DuckDB interface
│   ├── search/            # search engine
│   └── diff/              # comparison engine
├── frontend/              # React frontend
│   ├── src/
│   │   ├── App.tsx
│   │   ├── components/
│   │   └── hooks/
│   └── package.json
├── config/                # schemas, mappings
├── data/                  # converted DuckDB files
├── importacao/            # original MDB files
├── go.mod                 # Go dependencies
├── main.go                # entry point
└── wails.json             # Wails configuration
```

---

## KEY CONCEPTS

### Wails Bindings
Go methods exposed to JavaScript via struct binding

```go
type App struct {
    ctx context.Context
}

func (a *App) SearchTerm(term string) ([]Row, error) {
    // Go implementation
    return results, nil
}
```

Called from React:
```typescript
import { SearchTerm } from '../wailsjs/go/backend/App';

const results = await SearchTerm('example');
```

### DuckDB Go
```go
import (
    "database/sql"
    _ "github.com/marcboeker/go-duckdb"
)

db, err := sql.Open("duckdb", "data/202511_db1.duckdb")
defer db.Close()

rows, err := db.Query("SELECT * FROM table1")
```

### React Hooks
```typescript
const [searchTerm, setSearchTerm] = useState('');
const [results, setResults] = useState([]);

useEffect(() => {
  SearchTerm(searchTerm).then(setResults);
}, [searchTerm]);

return (
  <input value={searchTerm} onChange={e => setSearchTerm(e.target.value)} />
  {results.map(row => <div key={row.id}>{row.field}</div>)}
);
```

---

## CURRENT STATUS

- [ ] Wails initialized
- [ ] DuckDB Go binding integrated
- [ ] Basic UI scaffold
- [ ] Load last database
- [ ] Display table

---

## LEARNING RESOURCES

### Go Basics
- Goroutines: lightweight threads (`go myFunction()`)
- Channels: comunicacao entre goroutines (`ch <- value`, `value := <-ch`)
- Defer: executa funcao ao final do scope (cleanup)
- Error handling: retornar `error` como ultimo valor

### Wails
- Bindings: metodos Go automaticamente disponiveis no frontend
- Events: emit/on para comunicacao bidirecional
- Native dialogs: file picker, message boxes via Go

### React
- Hooks: useState (state), useEffect (side effects), useMemo (cache)
- Components: funcoes que retornam JSX
- Props: parametros passados para componentes

---

**Next**: Initialize Wails project structure
