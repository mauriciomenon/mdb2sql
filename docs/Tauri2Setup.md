tauri 2 migration plan for mdb2sql

Overview
- Goal: migrate rust_tauri_svelte to tauri 2.x with minimal surface changes, documenting the process and keeping a working path during transition.
- Current blockers: incompatibilities between tauri 2.x CLI and existing Cargo.toml/Cargo.lock; frontend dev server (vite) dependencies resolution in this environment; network constraints.

Prerequisites
- Rust toolchain up-to-date (rustc/cargo 1.60+ recommended).
- Node.js (v18+ recommended) and pnpm available.
- tauri-cli installed (prefer a stable 2.x line when available).
- Access to modify code and config files in the repo.

High-level migration plan
1) Prepare a dedicated branch for tauri 2 migration.
2) Align backend crates for tauri 2.x:
   - Update Cargo.toml: tauri = "2" and corresponding tauri-build version.
   - If tauri 2 requires API changes in main.rs, adjust minimally.
   - Update dependencies (e.g., tauri-build) to compatible versions.
3) Update tauri configuration to 2.x format:
   - Use src-tauri/tauri.conf.json with schema 2, including build.frontendDist, frontend dev/build commands, and window options.
   - Ensure ui dist path points to the correct directory (../ui/dist).
   - Configure port expectations via the frontend dev server and proper dev commands.
4) Install and verify tauri 2 CLI locally:
   - npm/pnpm: install tauri-cli 2.x or cargo-tauri compatible with 2.x.
   - If the environment blocks network, document required steps and provide fallback.
5) Build and run:
   - Run: cargo tauri dev and ensure the UI (vite dev server) starts and the Tauri window opens.
   - If port conflicts occur, switch the vite dev server port and update tauri config accordingly.
6) Validation and rollback:
   - Validate basic flows: open app window, list tables, run queries through backend commands.
   - If migration blocks exist, keep 1.x working as baseline and defer 2.x migration to a follow-up commit.

Migration details and concrete steps
- Step A: Update Cargo manifests
  - Change rust_tauri_svelte/Cargo.toml tauri line to 2.x compatible form.
  - Update build-dependencies tauri-build to a compatible version.
  - Regenerate lockfile if needed: cargo update -p tauri --precise 2.x.x (if applicable).
- Step B: Configure tauri.conf.json for 2.x
  - Use the 2.x schema root in src-tauri/tauri.conf.json.
  - Point frontendDist to "../ui/dist".
  - Set beforeDevCommand to build UI and start vite, e.g.: "cd ../ui && pnpm install && pnpm run dev".
- Step C: Frontend readiness
  - Ensure ui/ package.json dependencies include vite and pnpm.
  - Run pnpm install in ui and verify vite is installed in node_modules.
- Step D: CLI tooling
  - Install tauri-cli (v2.x) via cargo install tauri-cli (or cargo-tauri) suitable for 2.x.
  - If incompatibilities persist, revert to 1.x temporarily and leave notes for the 2.x migration.
- Step E: Port considerations
  - Default vite port 5173; if blocked, adjust to 3000 or 8080 and update tauri dev flow accordingly.

Validation checklist
- [ ] tauri 2 CLI available and usable in this environment
- [ ] Cargo.toml and tauri.conf.json aligned to 2.x
- [ ] UI dev server starts and serves at http://localhost:<port>
- [ ] Tauri window launches and frontend loads
- [ ] Core features work: load database, list tables, query data

Documentation and notes
- All changes for 2.x migration should be isolated to a dedicated commit/branch with a clear message focusing on the rationale.
- A short README snippet should explain the migration status and how to revert to 1.x if needed.
