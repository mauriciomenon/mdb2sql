#!/usr/bin/env bash
# Script para rodar Zig + Dear ImGui
set -e

cd "$(dirname "$0")/zig_imgui"

echo "========================================="
echo "ZIG + DEAR IMGUI - MDB2SQL POC"
echo "========================================="
echo ""
echo "Starting Zig Dear ImGui application..."
echo "Frontend: Dear ImGui (GLFW + OpenGL3)"
echo "Backend: Zig + libduckdb (C API)"
echo "Type: Desktop application (no port)"
echo ""

# Argumento opcional: caminho de um .duckdb/.db (sem argumento usa MDB2SQL_DB_PATH)
zig build run -Doptimize=ReleaseSafe -- "$@"
