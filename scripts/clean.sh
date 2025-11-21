#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS="${TARGET_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"
ARCH="${TARGET_ARCH:-$(uname -m)}"

echo "[INFO] Cleaning dist/build/target/minimal for ${OS}-${ARCH}"
rm -rf "$ROOT_DIR/go_wails_react/frontend/dist/${OS}-${ARCH}"
rm -rf "$ROOT_DIR/go_wails_react/build/bin/${OS}-${ARCH}"
rm -rf "$ROOT_DIR/rust_tauri_svelte/src-tauri/target"
rm -rf "$ROOT_DIR/rust_tauri_svelte/ui/dist/${OS}-${ARCH}"
rm -rf "$ROOT_DIR/py_qt6/build/${OS}-${ARCH}"
rm -rf "$ROOT_DIR/build/minimal"
