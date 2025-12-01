# PR Draft - Release builds, Tauri v2, linting, tests

## Summary
- Added `.flake8` to enforce consistent lint config across dev/CI with max-line-length 120 and ignores for virtualenv/build dirs.
- Hardened `.gitignore` to drop temp build outputs per stack (Go/Wails, Rust/Tauri, Python/PyQt6, dist/target), while keeping final archives allowed (`!*.zip`).
- Upgraded Rust/Tauri stack to v2: aligned `tauri`/`tauri-build` crates and `@tauri-apps/api` to v2, updated `tauri.conf.json` schema v2 and identifier `com.mdb2sql`, and adjusted Svelte IPC import to `@tauri-apps/api/core`.
- Approved pnpm esbuild scripts to silence interactive prompts in CI.
- Full darwin/arm64 release build executed via `scripts/build_release.sh` producing:
  - Go/Wails: `go_wails_react/build/bin/darwin-arm64/mdb2sql`
  - Rust/Tauri: `rust_tauri_svelte/src-tauri/target/release/bundle/macos/MDB2SQL.app` and `.../bundle/dmg/MDB2SQL_0.1.0_aarch64.dmg`
  - Python/PyQt6: `py_qt6/build/darwin-arm64/main`

## Tests
- Go: `go test ./...`
- Python: `uv run pytest`; `uv run ruff check .`; `uv run flake8`
- Frontend (React): `pnpm test -- --runInBand`
- Rust/Tauri UI build: `pnpm run build` (after approving esbuild)
- Release script: `./scripts/build_release.sh` (darwin/arm64) completed all three stacks

## Follow-ups / TODO
- Fix accessibility warning in `rust_tauri_svelte/ui/src/App.svelte` (label needs `for`/`id`).
- Consider switching PyInstaller to onedir (onefile+macOS bundle is deprecated).
- If targeting other OS/arch, rerun `scripts/approve_builds` in CI or pre-approve esbuild equivalents per platform.
