#!/usr/bin/env bash
# Script para rodar as 3 implementacoes GUI do MDB2SQL

set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
set -euo pipefail

echo "========================================="
echo "MDB2SQL - Running All GUI Implementations"
echo "========================================="
echo ""

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 1. Python + PyQt6
echo -e "${GREEN}[1/3] Starting Python + PyQt6...${NC}"
cd "${ROOT_DIR}/py_qt6"
uv run python src/main.py &
PY_PID=$!
echo -e "${GREEN}Python GUI started (PID: $PY_PID)${NC}"
sleep 2

# 2. Go + Wails + React
echo ""
echo -e "${GREEN}[2/3] Starting Go + Wails + React...${NC}"
cd "${ROOT_DIR}/go_wails_react"
wails dev &
GO_PID=$!
echo -e "${GREEN}Go Wails GUI started (PID: $GO_PID)${NC}"
sleep 3

# 3. Rust + Tauri + Svelte
echo ""
echo -e "${GREEN}[3/3] Starting Rust + Tauri + Svelte...${NC}"
cd "${ROOT_DIR}/rust_tauri_svelte"
cargo tauri dev &
RUST_PID=$!
echo -e "${GREEN}Rust Tauri GUI started (PID: $RUST_PID)${NC}"

echo ""
echo "========================================="
echo -e "${YELLOW}All 3 GUIs are starting...${NC}"
echo ""
echo "PIDs:"
echo "  Python PyQt6: $PY_PID"
echo "  Go Wails:     $GO_PID"
echo "  Rust Tauri:   $RUST_PID"
echo ""
echo "Press Ctrl+C to stop all processes"
echo "========================================="

# Wait for all background processes
wait
