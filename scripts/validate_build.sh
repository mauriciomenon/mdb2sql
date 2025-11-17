#!/usr/bin/env bash
# NIVEL BASICO: Script de validacao de build limpo para todas as implementacoes
# NIVEL TECNICO: Tests compilation and basic integrity in clean environment

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== MDB2SQL Build Validation Script ==="
echo "Project root: $PROJECT_ROOT"
echo ""

# Track results
FAILED_CHECKS=()
PASSED_CHECKS=()

check_pass() {
    echo -e "${GREEN}✓${NC} $1"
    PASSED_CHECKS+=("$1")
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    FAILED_CHECKS+=("$1")
}

check_warn() {
    echo -e "${YELLOW}!${NC} $1"
}

# ========================================
# CHECK 1: Go/Wails Implementation
# ========================================
echo "--- Checking Go/Wails Implementation ---"

if command -v go &> /dev/null; then
    GO_VERSION=$(go version | awk '{print $3}')
    check_pass "Go installed: $GO_VERSION"

    cd "$PROJECT_ROOT/go_wails_react"

    # Check go.mod exists
    if [[ -f "go.mod" ]]; then
        check_pass "go.mod exists"
    else
        check_fail "go.mod missing"
    fi

    # Check for Arrow dependency issue
    if grep -q "apache/arrow-go" go.mod; then
        if grep -q "go:build.*no_duckdb_arrow" wails.json 2>/dev/null; then
            check_pass "Arrow dependency disabled in wails.json"
        else
            check_warn "Arrow dependency present but not disabled - may cause linker errors"
        fi
    fi

    # Test Go build with no_duckdb_arrow tag
    echo "  Testing Go build (with -tags=no_duckdb_arrow)..."
    if go build -tags=no_duckdb_arrow -o /tmp/mdb2sql_test_go 2>&1 | tee /tmp/go_build.log; then
        check_pass "Go build successful"
        rm -f /tmp/mdb2sql_test_go
    else
        check_fail "Go build failed - see /tmp/go_build.log"
        cat /tmp/go_build.log
    fi

    # Check validateDatabasePath uses EvalSymlinks
    if grep -q "EvalSymlinks" app.go; then
        check_pass "Path traversal protection (EvalSymlinks) present"
    else
        check_fail "Missing EvalSymlinks in validateDatabasePath"
    fi

    # Check validateTableName uses information_schema
    if grep -q "information_schema.tables" backend/db_manager.go; then
        check_pass "Table validation uses information_schema (parameterized)"
    else
        check_fail "Table validation not using information_schema"
    fi

    cd "$PROJECT_ROOT"
else
    check_fail "Go not installed"
fi

echo ""

# ========================================
# CHECK 2: Rust/Tauri Implementation
# ========================================
echo "--- Checking Rust/Tauri Implementation ---"

if command -v cargo &> /dev/null; then
    RUST_VERSION=$(rustc --version | awk '{print $2}')
    check_pass "Rust installed: $RUST_VERSION"

    cd "$PROJECT_ROOT/rust_tauri_svelte"

    # Check Cargo.toml
    if [[ -f "Cargo.toml" ]]; then
        check_pass "Cargo.toml exists"
    else
        check_fail "Cargo.toml missing"
    fi

    # Check both Tauri configs exist
    if [[ -f "tauri.conf.json" ]]; then
        check_pass "tauri.conf.json (v1) exists"
    else
        check_fail "tauri.conf.json missing"
    fi

    if [[ -f "tauri.conf.v2.json" ]]; then
        check_pass "tauri.conf.v2.json (v2) exists"
    else
        check_warn "tauri.conf.v2.json missing - only v1 config available"
    fi

    # Test Rust build
    echo "  Testing Rust build (cargo check)..."
    if cargo check 2>&1 | tee /tmp/rust_check.log; then
        check_pass "Rust check successful"
    else
        check_fail "Rust check failed - see /tmp/rust_check.log"
        tail -n 20 /tmp/rust_check.log
    fi

    # Check validate_database_path uses canonicalize
    if grep -q "canonicalize" src/backend/db_manager.rs 2>/dev/null || grep -q "canonicalize" src/main.rs 2>/dev/null; then
        check_pass "Path traversal protection (canonicalize) present"
    else
        check_warn "Could not verify canonicalize usage"
    fi

    cd "$PROJECT_ROOT"
else
    check_fail "Rust/Cargo not installed"
fi

echo ""

# ========================================
# CHECK 3: Python/PyQt6 Implementation
# ========================================
echo "--- Checking Python/PyQt6 Implementation ---"

if command -v python3 &> /dev/null; then
    PYTHON_VERSION=$(python3 --version | awk '{print $2}')
    check_pass "Python installed: $PYTHON_VERSION"

    cd "$PROJECT_ROOT/py_qt6"

    # Check for Poetry or venv
    if command -v poetry &> /dev/null; then
        check_pass "Poetry installed"

        # Test Python imports
        echo "  Testing Python imports..."
        if poetry run python -c "from src.backend.db_manager import DBManager; print('OK')" 2>&1 | grep -q "OK"; then
            check_pass "Python imports successful"
        else
            check_fail "Python imports failed"
        fi
    elif [[ -d "venv" ]]; then
        check_pass "venv exists"

        # Activate and test
        source venv/bin/activate 2>/dev/null || source venv/Scripts/activate 2>/dev/null
        if python -c "from src.backend.db_manager import DBManager; print('OK')" 2>&1 | grep -q "OK"; then
            check_pass "Python imports successful"
        else
            check_fail "Python imports failed"
        fi
        deactivate 2>/dev/null || true
    else
        check_warn "No Poetry or venv found - cannot test Python imports"
    fi

    # Check _validate_database_path uses resolve
    if grep -q "\.resolve()" src/backend/db_manager.py; then
        check_pass "Path traversal protection (resolve) present"
    else
        check_fail "Missing Path.resolve() in _validate_database_path"
    fi

    cd "$PROJECT_ROOT"
else
    check_fail "Python3 not installed"
fi

echo ""

# ========================================
# CHECK 4: Documentation Integrity
# ========================================
echo "--- Checking Documentation ---"

# Check setup guides exist
if [[ -f "SETUP_WINDOWS11.md" ]]; then
    check_pass "SETUP_WINDOWS11.md exists"
else
    check_fail "SETUP_WINDOWS11.md missing"
fi

if [[ -f "SETUP_DEBIAN.md" ]]; then
    check_pass "SETUP_DEBIAN.md exists"

    # Check for hardcoded Go version
    if grep -q "go1\.[0-9]*\.[0-9]*\.linux-amd64\.tar\.gz" SETUP_DEBIAN.md && ! grep -q "GO_LATEST_FILENAME" SETUP_DEBIAN.md; then
        check_fail "Hardcoded Go version in SETUP_DEBIAN.md"
    else
        check_pass "Dynamic Go version fetch in SETUP_DEBIAN.md"
    fi
else
    check_fail "SETUP_DEBIAN.md missing"
fi

# Check SETUP_SUMMARY doesn't reference deleted files
if grep -q "ROADMAP_v0.3.0.md" SETUP_SUMMARY.md 2>/dev/null; then
    check_fail "SETUP_SUMMARY.md references deleted ROADMAP_v0.3.0.md"
else
    check_pass "SETUP_SUMMARY.md has no broken references"
fi

echo ""

# ========================================
# CHECK 5: Security Validations
# ========================================
echo "--- Security Checks ---"

# Check all implementations have path validation
PATH_VALIDATION_FOUND=0

if grep -q "EvalSymlinks\|filepath\.Clean" go_wails_react/app.go 2>/dev/null; then
    ((PATH_VALIDATION_FOUND++))
fi

if grep -q "canonicalize" rust_tauri_svelte/src/*.rs rust_tauri_svelte/src/**/*.rs 2>/dev/null; then
    ((PATH_VALIDATION_FOUND++))
fi

if grep -q "\.resolve()" py_qt6/src/backend/db_manager.py 2>/dev/null; then
    ((PATH_VALIDATION_FOUND++))
fi

if [[ $PATH_VALIDATION_FOUND -eq 3 ]]; then
    check_pass "Path validation present in all 3 implementations"
elif [[ $PATH_VALIDATION_FOUND -gt 0 ]]; then
    check_warn "Path validation found in $PATH_VALIDATION_FOUND/3 implementations"
else
    check_fail "No path validation found in any implementation"
fi

# Check for SQL injection protection
if grep -q "information_schema" go_wails_react/backend/db_manager.go 2>/dev/null; then
    check_pass "Go uses parameterized table validation (information_schema)"
else
    check_warn "Go table validation may not use information_schema"
fi

echo ""

# ========================================
# SUMMARY
# ========================================
echo "========================================="
echo "VALIDATION SUMMARY"
echo "========================================="
echo -e "${GREEN}Passed: ${#PASSED_CHECKS[@]}${NC}"
echo -e "${RED}Failed: ${#FAILED_CHECKS[@]}${NC}"
echo ""

if [[ ${#FAILED_CHECKS[@]} -gt 0 ]]; then
    echo -e "${RED}Failed checks:${NC}"
    for check in "${FAILED_CHECKS[@]}"; do
        echo "  - $check"
    done
    echo ""
    exit 1
else
    echo -e "${GREEN}All critical checks passed!${NC}"
    exit 0
fi
