#!/usr/bin/env bash
# Script para fazer rebuild limpo do Python PyQt6
set -e

cd "$(dirname "$0")/py_qt6"

echo "========================================="
echo "CLEAN BUILD - PYTHON + PYQT6"
echo "========================================="
echo ""

echo "[1/3] Cleaning Python cache..."
find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find . -type f -name "*.pyc" -delete 2>/dev/null || true
echo "      Done"

echo "[2/3] Removing uv lock..."
rm -f uv.lock
echo "      Done"

echo "[3/3] Syncing dependencies with uv..."
uv sync
echo "      Done"

echo ""
echo "========================================="
echo "Clean build completed successfully!"
echo "Now run: ./run_python_pyqt6.sh"
echo "========================================="
