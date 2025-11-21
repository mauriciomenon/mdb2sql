#!/usr/bin/env bash
# Build release artifacts por OS/arch para Go/Wails, Rust/Tauri, Python/PyQt6
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS="${TARGET_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"
ARCH="${TARGET_ARCH:-$(uname -m)}"
PLATFORM="${TARGET_PLATFORM:-$(go env GOOS)/$(go env GOARCH)}"

info() { echo "[INFO] $*"; }
fail() { echo "[FAIL] $*" >&2; exit 1; }

# Go/Wails
info "Building Go/Wails (platform=${PLATFORM})"
pushd "$ROOT_DIR/go_wails_react" >/dev/null
wails build -clean -tags=no_duckdb_arrow -platform "${PLATFORM}"
OUT_BIN="$ROOT_DIR/go_wails_react/build/bin/${OS}-${ARCH}"
mkdir -p "$OUT_BIN"
mv -f "$ROOT_DIR/go_wails_react/build/bin/"mdb2sql* "$OUT_BIN/" || fail "Nao foi possivel mover binario Wails"
popd >/dev/null

# Rust/Tauri
info "Building Rust/Tauri release"
pushd "$ROOT_DIR/rust_tauri_svelte" >/dev/null
TAURI_DIST_DIR="ui/dist/${OS}-${ARCH}" TAURI_DEV_PATH="http://localhost:1420" cargo tauri build
popd >/dev/null

# Python/PyQt6
info "Building Python/PyQt6 (PyInstaller) para ${OS}-${ARCH}"
pushd "$ROOT_DIR/py_qt6" >/dev/null
if ! command -v pyinstaller >/dev/null; then
  fail "PyInstaller nao encontrado (uv add --dev pyinstaller) antes do build"
fi
DIST_DIR="$ROOT_DIR/py_qt6/build/${OS}-${ARCH}"
rm -rf "$DIST_DIR"
uv run pyinstaller --windowed --distpath "$DIST_DIR" src/main.py
popd >/dev/null

info "Build release concluido. Binarios esperados:"
echo " - Go/Wails: go_wails_react/build/bin/${OS}-${ARCH}/mdb2sql*"
echo " - Rust/Tauri: rust_tauri_svelte/src-tauri/target/**/release/"
echo " - Python/PyQt6: py_qt6/build/${OS}-${ARCH}/main*"
