#!/usr/bin/env bash
# Script para rodar Go + Wails + React em dev mode
set -e

cd "$(dirname "$0")/go_wails_react"

echo "========================================="
echo "GO + WAILS + REACT - MDB2SQL POC"
echo "========================================="
echo ""
echo "Starting Go Wails development server..."
echo "Frontend: React + TypeScript"
echo "Backend: Go + Wails v2"
echo "Port: http://localhost:34115"
echo ""
echo "Installing frontend dependencies..."
cd frontend && pnpm install && cd ..
echo ""
echo "Starting Wails dev mode..."

wails dev
