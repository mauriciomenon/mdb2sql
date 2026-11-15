# MDB2SQL (Go + Wails + React)

Viewer for DuckDB databases converted from Microsoft Access: tables, schema and data.
One exe (`build/bin/mdb2sql.exe`), DuckDB linked statically, UI in the system WebView2.

Version: `wails.json` -> `info.productVersion` is the single source. Go embeds that file and
serves it to the About dialog (`GetAppInfo`); the Wails CLI writes the same value into the exe resource.

## Build on Windows

```powershell
pwsh -NoProfile -File go_wails_react/setup_tools.ps1    # once; downloads into go_wails_react/.tools/
pwsh -NoProfile -File go_wails_react/build_windows.ps1  # -> go_wails_react/build/bin/mdb2sql.exe
```

`setup_tools.ps1` installs fixed versions into `.tools/` (not in git, about 1.3 GB):

| Tool | Version | Source and check |
| --- | --- | --- |
| Go | 1.26.10 | official zip from go.dev, sha256 from go.dev/dl |
| WinLibs GCC (MinGW-w64 UCRT) | 16.2.0, MinGW-w64 14.0.0, r3 | GitHub release of brechtsanders/winlibs_mingw, sha256 published with the release |
| Wails CLI | 2.13.0 | `go install` with `GOBIN=.tools/bin`; module hash checked by sum.golang.org |

Why these: cgo (duckdb-go) needs a GCC with the UCRT runtime; the Wails CLI 2.13.0 does not run on
Go 1.27, so Go stays on 1.26.x; the CLI version matches the Wails module in `go.mod`.
To update a tool, change its version and sha256 together at the top of `setup_tools.ps1`.

`build_windows.ps1` uses `.tools/` when it exists. Without it, it falls back to the system:
`go` and `wails` from PATH with `GOTOOLCHAIN=go1.26.11`, GCC from `MDB2SQL_GCC_BIN` or
`~\.local\winlibs-gcc-16.2.0-ucrt-r3\mingw64\bin`. `MDB2SQL_GCC_BIN` always wins.

### Prerequisites that stay on the system

- Node.js (22 or newer) and pnpm: the frontend is one package of the pnpm workspace at the repo root
  (`pnpm-workspace.yaml`, one `pnpm-lock.yaml` shared with the Tauri UI). The lockfile already fixes
  every frontend dependency, and a private Node inside one stack would not match what the other
  stack and the root scripts use.
- Microsoft Edge WebView2 Runtime: part of Windows 11; the app needs it at run time, too.
- The Go module cache (`%USERPROFILE%\go\pkg\mod`) is the normal per-user cache; modules are checked against `go.sum`.

## Tests

```powershell
# Go tests need frontend/dist (go:embed), so build once before; put .tools go and gcc on PATH
$env:PATH = "$PWD\.tools\go\go\bin;$PWD\.tools\winlibs\mingw64\bin;$env:PATH"; $env:CGO_ENABLED = '1'; $env:GOTOOLCHAIN = 'local'
go test ./...
cd frontend; pnpm exec vitest run
```

## Use

- Load database: native file dialog (`.duckdb`, `.db`, `.sqlite`, `.sqlite3`), opened read-only.
- Sample data: opens the file in `MDB2SQL_DB_PATH`, or `data/sample.duckdb` when the variable is not set.
- Theme: auto (follows Windows), light or dark. About: app version and runtime versions.
