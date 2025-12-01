#!/usr/bin/env bash
# Script para fazer rebuild limpo do Go Wails
set -e

cd "$(dirname "$0")/go_wails_react"

echo "========================================="
echo "CLEAN BUILD - GO + WAILS + REACT"
echo "========================================="
echo ""

echo "[1/4] Cleaning frontend dist..."
rm -rf frontend/dist
echo "      Done"

echo "[2/4] Cleaning build artifacts..."
rm -rf build
echo "      Done"

echo "[3/4] Installing frontend dependencies..."
cd frontend && pnpm install && cd ..
echo "      Done"

echo "[4/4] Building frontend..."
cd frontend && pnpm run build && cd ..
echo "      Done"

echo ""
echo "========================================="
echo "Clean build completed successfully!"
echo "Now run: ./run_go_wails.sh"
echo "========================================="
