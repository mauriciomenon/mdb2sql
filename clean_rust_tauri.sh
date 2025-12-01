#!/usr/bin/env bash
# Script para fazer rebuild limpo do Rust Tauri
set -e

cd "$(dirname "$0")/rust_tauri_svelte"

echo "========================================="
echo "CLEAN BUILD - RUST + TAURI + SVELTE"
echo "========================================="
echo ""

echo "[1/4] Cleaning frontend dist..."
rm -rf ui/dist
echo "      Done"

echo "[2/4] Cleaning Rust target..."
rm -rf target src-tauri/target
echo "      Done"

echo "[3/4] Installing frontend dependencies..."
pnpm --dir ui install
echo "      Done"

echo "[4/4] Building frontend..."
pnpm --dir ui run build
echo "      Done"

echo ""
echo "========================================="
echo "Clean build completed successfully!"
echo "Now run: ./run_rust_tauri.sh"
echo "========================================="
