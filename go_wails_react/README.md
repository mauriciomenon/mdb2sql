# GO + WAILS + REACT IMPLEMENTATION

---

## STACK

- **Backend**: Go 1.21+ (fast, concurrent, compiled)
- **Frontend**: React + TypeScript + Vite (modern web stack)
- **Framework**: Wails v2 (native desktop without Electron overhead)
- **Database**: DuckDB via go-duckdb (embedded analytics)
- **Distribution**: Single native binary per platform

---

## PREREQUISITES

### System
- Go 1.21+ (`go version`)
- Wails CLI (`wails doctor`)
- Node.js 18+ and pnpm (`pnpm --version`)

### Platform Specific
- **macOS**: Xcode Command Line Tools
- **Linux**: gcc, gtk3-devel, webkit2gtk3-devel
- **Windows**: gcc via mingw-w64 or TDM-GCC

### Install Wails
```bash
go install github.com/wailsapp/wails/v2/cmd/wails@latest
wails doctor  # check dependencies
```

---

## QUICK START

```bash
cd go_wails_react
wails dev  # live reload dev mode
```

Or build:
```bash
wails build  # production binary in build/bin/
```

---

## CURRENT STATUS

- [x] Project structure created
- [x] Go backend with DuckDB (backend/db_manager.go)
- [x] Wails bindings (app.go)
- [x] React frontend with TypeScript
- [x] Feature 1: Load and display table
- [ ] Search functionality
- [ ] Multi-DB operations
- [ ] Diff engine

---

## PROJECT STRUCTURE

```
go_wails_react/
├── main.go              # Wails entry point
├── app.go               # App struct with exposed methods
├── backend/             # Go business logic
│   └── db_manager.go    # DuckDB connection manager
├── frontend/            # React + Vite
│   ├── src/
│   │   ├── App.tsx      # Main React component
│   │   ├── App.css      # Styles
│   │   └── main.tsx     # React entry
│   └── package.json     # pnpm dependencies
└── wails.json           # Wails configuration
```

---

## DEVELOPMENT

### Live Development Mode
```bash
wails dev
```
- Hot reload frontend (Vite HMR)
- Auto-restart backend on Go changes
- DevTools available at http://localhost:34115

### Build for Production
```bash
wails build -clean
# Output: build/bin/mdb2sql (or .exe on Windows)
```

### Cross-Platform Builds
```bash
wails build -platform darwin/amd64  # macOS Intel
wails build -platform darwin/arm64  # macOS Apple Silicon
wails build -platform windows/amd64 # Windows x64
wails build -platform linux/amd64   # Linux x64
```

---

## KEY CONCEPTS

### Wails Bindings
Go methods on App struct are automatically exposed to React:

```go
// app.go
func (a *App) LoadDatabase(dbPath string) ([]string, error) {
    return a.dbManager.ListTables()
}
```

```typescript
// React
const tables = await window.go.main.App.LoadDatabase('')
```

### DuckDB in Go
```go
import _ "github.com/marcboeker/go-duckdb"

dsn := "data/sample.duckdb?access_mode=read_only"
conn, _ := sql.Open("duckdb", dsn)
rows, _ := conn.Query("SELECT * FROM table1 LIMIT 100")
```

---

## LEARNING RESOURCES

### Go Basics
- Goroutines: `go functionName()` (concurrent execution)
- Channels: `ch := make(chan int)` (thread-safe communication)
- Defer: `defer file.Close()` (cleanup)
- Error handling: explicit return values

### Wails
- Runtime: `runtime.EventsEmit()`, `runtime.WindowSetTitle()`
- Bindings: Exported methods auto-bound to frontend
- Events: Pub/sub between Go and JavaScript

### React + TypeScript
- Hooks: `useState`, `useEffect` for state management
- TypeScript: type-safe props and state
- Vite: fast dev server with HMR

---

**Next**: Run `wails dev` to start development
