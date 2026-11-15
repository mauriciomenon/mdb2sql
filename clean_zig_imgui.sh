#!/usr/bin/env bash
# Script para fazer rebuild limpo do Zig Dear ImGui
set -e

cd "$(dirname "$0")/zig_imgui"

echo "========================================="
echo "CLEAN BUILD - ZIG + DEAR IMGUI"
echo "========================================="
echo ""

echo "[1/3] Cleaning build cache..."
rm -rf .zig-cache
echo "      Done"

echo "[2/3] Cleaning build output..."
rm -rf zig-out
echo "      Done"

# Usa o Zig de .tools/ (setup_tools.ps1) quando existe
for d in .tools/zig-*/; do [ -x "$d/zig.exe" ] && PATH="$PWD/$d:$PATH"; done
echo "[3/3] Building (ReleaseSafe)..."
zig build -Doptimize=ReleaseSafe
echo "      Done"

echo ""
echo "========================================="
echo "Clean build completed successfully!"
echo "Now run: ./run_zig_imgui.sh"
echo "========================================="
