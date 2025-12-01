# Build & Sanity Report

| Stack / Step | Command | OutDir / Artifact | Time (s) | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| Go backend | `go build -tags=no_duckdb_arrow ./...` | `go_wails_react` (binary in `build/bin/<os>-<arch>` via Wails build) | ~2.15 | ✅ | Path traversal + table validation tests cover whitelisted extensions. |
| Go frontend (React) | `OUT_DIR=dist/<platform>-<arch> pnpm run build` | `go_wails_react/frontend/dist/darwin-arm64` | ~1.72 | ✅ | Build passes after enabling esbuild scripts; no Wails export call needed. |
| Rust/Tauri | `cargo build` | `rust_tauri_svelte/target/debug` | ~5.67 | ✅ | Tauri v1 config (tauri=1.8, tauri-build=1.5). |
| Python | `uv run python -m py_compile src/backend/db_manager.py src/main.py` | `py_qt6` | ~0.32 | ✅ | Uses uv; dummy compile sanity. |

## Post-build sanity checklist
- Go backend: `go test ./...` and `go vet ./...` (pass) to ensure IPC surface and validation remain safe.
- Go frontend: ensure `dist/<platform>-<arch>/assets/index.js` exists and no missing exports (App.jsx no longer imports Wails IPC).
- Rust/Tauri: `cargo test`, `cargo fmt`, `cargo clippy -- -D warnings` (pass) and confirm `tauri.conf.json` schema v1 matches crate versions.
- Python: `uv run pytest` (6 tests) and `uv run ruff check` (pass); `uv.lock` versioned for reproducibility.
- Artifacts segregated por OS/arch: Vite uses OUT_DIR default `dist/<platform>-<arch>`, Wails binaries should be organized under `build/bin/<os>-<arch>`, Tauri under `src-tauri/target/<triple>`, PyInstaller/Nuitka sob `build/<os>-<arch>/`.

## Version pins
- Go 1.23.x (host for metrics: go1.25.4, warn only), Wails 2.11.
- Node 23.3.x + pnpm 10.18.x.
- Python 3.12 + uv.
- Rust 1.83.x; Tauri v1 (tauri=1.8, tauri-build=1.5), upgrade v2 adiado.

