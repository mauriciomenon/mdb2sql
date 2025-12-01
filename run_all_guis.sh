#!/usr/bin/env bash
# Script para rodar todas as 4 implementacoes GUI do MDB2SQL
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================="
echo "MDB2SQL - Running All GUI Implementations"
echo "========================================="
echo ""

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 1. Python + PyQt6
echo -e "${GREEN}[1/4] Starting Python + PyQt6...${NC}"
echo -e "${BLUE}      Port: N/A (desktop app)${NC}"
cd "${ROOT_DIR}/py_qt6"
uv run python src/main.py &
PY_PID=$!
echo -e "${GREEN}      Python GUI started (PID: $PY_PID)${NC}"
sleep 2

# 2. Go + Wails + React
echo ""
echo -e "${GREEN}[2/4] Starting Go + Wails + React...${NC}"
echo -e "${BLUE}      Port: http://localhost:34115${NC}"
cd "${ROOT_DIR}/go_wails_react"
wails dev &
GO_PID=$!
echo -e "${GREEN}      Go Wails GUI started (PID: $GO_PID)${NC}"
sleep 3

# 3. Rust + Tauri + Svelte
echo ""
echo -e "${GREEN}[3/4] Starting Rust + Tauri + Svelte...${NC}"
echo -e "${BLUE}      Port: http://localhost:1420${NC}"
cd "${ROOT_DIR}/rust_tauri_svelte"
cargo tauri dev &
RUST_PID=$!
echo -e "${GREEN}      Rust Tauri GUI started (PID: $RUST_PID)${NC}"
sleep 3

# 4. Node + Electron + React
echo ""
echo -e "${GREEN}[4/4] Starting Node + Electron + React...${NC}"
echo -e "${BLUE}      Port: http://localhost:5173${NC}"
echo -e "${YELLOW}      Note: Requires Node.js v22 (incompatible with v25)${NC}"
cd "${ROOT_DIR}/node_electron_react"
pnpm run dev &
NODE_PID=$!
echo -e "${GREEN}      Node Electron GUI started (PID: $NODE_PID)${NC}"

echo ""
echo "========================================="
echo -e "${YELLOW}All 4 GUIs are starting...${NC}"
echo ""
echo "PIDs:"
echo "  Python PyQt6:      $PY_PID"
echo "  Go Wails:          $GO_PID (http://localhost:34115)"
echo "  Rust Tauri:        $RUST_PID (http://localhost:1420)"
echo "  Node Electron:     $NODE_PID (http://localhost:5173)"
echo ""
echo "Press Ctrl+C to stop all processes"
echo "========================================="

# Wait for all background processes
wait
