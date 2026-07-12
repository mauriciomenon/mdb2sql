#!/usr/bin/env bash
# Sanity script para builds/tests por stack com artefatos separados por OS/arch

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_OS="${TARGET_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"
TARGET_ARCH="${TARGET_ARCH:-$(uname -m)}"
OUT_DIR_DEFAULT="dist/${TARGET_OS}-${TARGET_ARCH}"

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
fail() { echo "[FAIL] $*" >&2; exit 1; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

cd "$ROOT_DIR"

# --------------------------------------
# Go + Wails + React
# --------------------------------------
if [[ "${SKIP_GO:-0}" -eq 1 ]]; then
  warn "Skipping Go/Wails stack (SKIP_GO=1)."
else
  if ! has_cmd go; then
    warn "Go not found in PATH; skipping Go/Wails stack."
  else
    if ! has_cmd pnpm; then
      warn "pnpm not found; skipping Go/Wails frontend tests/build."
    else
      info "Go/Wails: frontend install+test+build (OUT_DIR=${OUT_DIR_DEFAULT})"
      cd "$ROOT_DIR/go_wails_react/frontend"
      pnpm install --frozen-lockfile --prefer-offline >/dev/null
      pnpm test
      OUT_DIR="${OUT_DIR:-$OUT_DIR_DEFAULT}" pnpm run build
      if [[ ! -f "${OUT_DIR:-$OUT_DIR_DEFAULT}/index.html" ]]; then
          fail "Frontend dist not found at ${OUT_DIR:-$OUT_DIR_DEFAULT}"
      fi
    fi

    info "Go/Wails: backend build+tests"
    cd "$ROOT_DIR/go_wails_react"
    go test ./...
    go vet ./...
    go build -tags=no_duckdb_arrow ./...
  fi
fi

# --------------------------------------
# Rust + Tauri + Svelte
# --------------------------------------
if [[ "${SKIP_RUST:-0}" -eq 1 ]]; then
  warn "Skipping Rust/Tauri stack (SKIP_RUST=1)."
else
  if ! has_cmd cargo; then
    warn "cargo not found in PATH; skipping Rust/Tauri stack."
  else
    info "Rust/Tauri: backend check+tests"
    cd "$ROOT_DIR/rust_tauri_svelte"
    cargo test
    cargo clippy -- -D warnings
  fi
fi

# --------------------------------------
# Python + PyQt6
# --------------------------------------
if [[ "${SKIP_PYTHON:-0}" -eq 1 ]]; then
  warn "Skipping Python/PyQt6 stack (SKIP_PYTHON=1)."
else
  if ! has_cmd uv; then
    warn "uv not found in PATH; skipping Python/PyQt6 tests."
  else
    info "Python/PyQt6: tests"
    cd "$ROOT_DIR/py_qt6"
    uv run pytest
    uv run ruff check
  fi
fi

info "Sanity checks completed (OS=${TARGET_OS}, ARCH=${TARGET_ARCH}, OUT_DIR=${OUT_DIR_DEFAULT})."

if [[ -t 0 && -z "${CI:-}" ]]; then
  echo "Abrir alguma solucao agora? [g] Go/Wails dev | [r] Rust/Tauri dev | [p] Python/PyQt6 | [n] nenhum (default)"
  read -r -p "(g/r/p/n): " OPEN_CHOICE
  case "${OPEN_CHOICE,,}" in
    g)
      (cd "$ROOT_DIR/go_wails_react" && wails dev)
      ;;
    r)
      (cd "$ROOT_DIR/rust_tauri_svelte" && cargo tauri dev)
      ;;
    p)
      (cd "$ROOT_DIR/py_qt6" && uv run python src/main.py)
      ;;
    *)
      echo "Nenhuma solucao aberta."
      ;;
  esac
else
  info "Prompt de abertura pulado (sem TTY ou CI=true)."
fi
