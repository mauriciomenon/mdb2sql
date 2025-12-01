#!/usr/bin/env bash
# Script para testar Go + Wails + React com dados reais

set -e

echo "========================================="
echo "Testing Go + Wails + React Implementation"
echo "========================================="
echo ""

# Verificar se o banco existe
if [ ! -f "/Users/menon/git/mdb2sql/go_wails_react/data/sample.duckdb" ]; then
    echo "ERROR: Database file not found!"
    echo "Expected: /Users/menon/git/mdb2sql/go_wails_react/data/sample.duckdb"
    exit 1
fi

echo "Database file: OK ($(ls -lh /Users/menon/git/mdb2sql/go_wails_react/data/sample.duckdb | awk '{print $5}'))"
echo ""

# Verificar se frontend/dist existe
if [ ! -d "/Users/menon/git/mdb2sql/go_wails_react/frontend/dist" ]; then
    echo "ERROR: Frontend dist folder not found!"
    exit 1
fi

echo "Frontend dist: OK"
echo ""

# Verificar arquivos no dist
echo "Frontend files:"
ls -1 /Users/menon/git/mdb2sql/go_wails_react/frontend/dist/ | head -5
echo ""

echo "Starting Wails dev server..."
echo ""
echo "The application should open in a new window."
echo "Click 'Load Sample Database' to see the data."
echo ""
echo "Press Ctrl+C to stop"
echo "========================================="
echo ""

cd /Users/menon/git/mdb2sql/go_wails_react
wails dev
