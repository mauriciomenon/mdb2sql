#!/bin/bash
# TERMINAL 1: Python + PyQt6

cd "$(dirname "$0")/py_qt6"

echo "========================================="
echo "PYTHON + PYQT6 - MDB2SQL POC"
echo "========================================="
echo ""
echo "Starting Python PyQt6 application..."
echo ""

source .venv/bin/activate
python src/main.py
