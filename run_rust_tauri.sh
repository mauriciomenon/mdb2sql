#!/usr/bin/env bash
# Script para rodar Rust + Tauri + Svelte em dev mode

set -e

cd "$(dirname "$0")/rust_tauri_svelte"

echo "========================================="
echo "RUST + TAURI + SVELTE - MDB2SQL POC"
echo "========================================="
echo ""
echo "Starting Rust Tauri development server..."
echo "Frontend: Svelte + Vite"
echo "Backend: Rust + Tauri v1.8"
echo "Port: http://localhost:1420"
echo ""

cargo tauri dev
