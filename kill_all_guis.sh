#!/usr/bin/env bash
# Script para matar todos os processos GUI rodando

echo "========================================="
echo "KILLING ALL GUI PROCESSES"
echo "========================================="
echo ""

echo "Killing Wails processes..."
pkill -f "wails dev" 2>/dev/null || echo "  No Wails processes found"

echo "Killing Tauri processes..."
pkill -f "cargo tauri" 2>/dev/null || echo "  No Tauri processes found"

echo "Killing Electron processes..."
pkill -f "electron" 2>/dev/null || echo "  No Electron processes found"

echo "Killing Vite dev servers..."
pkill -f "vite" 2>/dev/null || echo "  No Vite processes found"

echo "Killing Python PyQt6..."
pkill -f "python.*main.py" 2>/dev/null || echo "  No PyQt6 processes found"

echo ""
echo "========================================="
echo "All GUI processes terminated"
echo "========================================="
