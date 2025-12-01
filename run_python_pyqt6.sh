#!/usr/bin/env bash
# Script para rodar Python + PyQt6

set -e

cd "$(dirname "$0")/py_qt6"

echo "========================================="
echo "PYTHON + PYQT6 - MDB2SQL POC"
echo "========================================="
echo ""
echo "Starting Python PyQt6 application..."
echo "Frontend: PyQt6 (native desktop)"
echo "Backend: Python + DuckDB"
echo "Type: Desktop application (no port)"
echo ""

uv run python src/main.py
