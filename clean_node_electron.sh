#!/usr/bin/env bash
# Script para fazer rebuild limpo do Node Electron
set -e

cd "$(dirname "$0")/node_electron_react"

echo "========================================="
echo "CLEAN BUILD - NODE + ELECTRON + REACT"
echo "========================================="
echo ""

echo "[1/3] Cleaning frontend dist..."
rm -rf frontend/dist
echo "      Done"

echo "[2/3] Installing dependencies..."
pnpm install
echo "      Done"

echo "[3/3] Installing frontend dependencies..."
cd frontend && pnpm install && cd ..
echo "      Done"

echo ""
echo "========================================="
echo "Clean build completed successfully!"
echo "NOTE: Requires Node.js v22 (not v25)"
echo "Now run: ./run_node_electron.sh"
echo "========================================="
