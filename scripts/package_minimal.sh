#!/usr/bin/env bash
# Gera zip minimalista por stack (sem IA, apenas binarios e README em md/txt)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS="${TARGET_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"
ARCH="${TARGET_ARCH:-$(uname -m)}"
OUT_DIR_BASE="dist/${OS}-${ARCH}"
PACKAGE_DIR="$ROOT_DIR/build/minimal"

info() { echo "[INFO] $*"; }
fail() { echo "[FAIL] $*" >&2; exit 1; }

rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"

# Go/Wails: assume binario ja construido em build/bin/<os>-<arch>/mdb2sql(.exe)
GO_BIN_SRC="$ROOT_DIR/go_wails_react/build/bin/${OS}-${ARCH}"
if [[ -d "$GO_BIN_SRC" ]]; then
  info "Copiando Go/Wails binarios"
  mkdir -p "$PACKAGE_DIR/go_wails_react"
  cp -a "$GO_BIN_SRC" "$PACKAGE_DIR/go_wails_react/"
else
  fail "Binario Go/Wails nao encontrado em $GO_BIN_SRC (execute wails build e organize em build/bin/${OS}-${ARCH})"
fi

# Rust/Tauri: copia binarios de target/<triple>
RUST_BIN_SRC="$ROOT_DIR/rust_tauri_svelte/src-tauri/target"
if compgen -G "$RUST_BIN_SRC/*/release/*mdb2sql*" > /dev/null; then
  info "Copiando Rust/Tauri binarios"
  mkdir -p "$PACKAGE_DIR/rust_tauri_svelte"
  find "$RUST_BIN_SRC" -path "*release*" -type f -maxdepth 4 \( -name "mdb2sql*" \) -exec cp {} "$PACKAGE_DIR/rust_tauri_svelte/" \;
else
  fail "Binario Rust/Tauri release nao encontrado em $RUST_BIN_SRC (execute cargo tauri build)"
fi

# Python/PyQt6: empacotar README e script runner minimal (expect build ja gerado)
PY_BUILD="$ROOT_DIR/py_qt6/build/${OS}-${ARCH}"
if [[ -d "$PY_BUILD" ]]; then
  info "Copiando build Python/PyQt6"
  mkdir -p "$PACKAGE_DIR/py_qt6"
  cp -a "$PY_BUILD" "$PACKAGE_DIR/py_qt6/"
else
  fail "Build Python/PyQt6 nao encontrado em $PY_BUILD (execute PyInstaller/Nuitka com saida em build/${OS}-${ARCH})"
fi

# READMEs em md e txt
info "Adicionando READMEs"
find "$ROOT_DIR" -maxdepth 1 -type f \( -name "README.md" -o -name "README.txt" \) -exec cp {} "$PACKAGE_DIR" \;

# Zipa pacote
cd "$PACKAGE_DIR/.."
ZIP_NAME="minimal_${OS}_${ARCH}.zip"
rm -f "$ZIP_NAME"
zip -rq "$ZIP_NAME" "$(basename "$PACKAGE_DIR")"
info "Pacote gerado: $PACKAGE_DIR/../$ZIP_NAME"
