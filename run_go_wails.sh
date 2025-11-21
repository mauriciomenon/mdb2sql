#!/bin/bash
# TERMINAL 2: Go + Wails + React

cd "$(dirname "$0")/go_wails_react"

echo "========================================="
echo "GO + WAILS + REACT - MDB2SQL POC"
echo "========================================="
echo ""
echo "Starting Go Wails development server..."
echo "Frontend will be at: http://localhost:34115"
echo ""
echo "Installing frontend dependencies..."
cd frontend && npm install && cd ..
echo ""
echo "Starting Wails dev mode..."

wails dev
