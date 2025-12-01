#!/usr/bin/env bash
# NIVEL BASICO: Script para rodar Node + Electron + React em dev mode
set -e

echo "========================================="
echo "NODE + ELECTRON + REACT - MDB2SQL POC"
echo "========================================="
echo ""
echo "Starting Node Electron development server..."
echo "Frontend will be at: http://localhost:5173"
echo ""

cd node_electron_react
pnpm install
cd frontend && pnpm install && cd ..
NODE_ENV=development pnpm run dev
