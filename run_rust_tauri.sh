#!/bin/bash
# TERMINAL 3: Rust + Tauri + Svelte

cd "$(dirname "$0")/rust_tauri_svelte"

echo "========================================="
echo "RUST + TAURI + SVELTE - MDB2SQL POC"
echo "========================================="
echo ""
echo "Starting Rust Tauri development server..."
echo "Frontend will be at: http://localhost:1420"
echo ""

cargo tauri dev
