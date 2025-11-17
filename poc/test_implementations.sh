#!/bin/bash

echo "==================================="
echo "MDB2SQL Manual Benchmark Test"
echo "==================================="
echo ""

TEST_FILE="import_folder/DB2_20_11_2013.mdb"
OUTPUT_DB="benchmark_test.duckdb"

rm -f "$OUTPUT_DB" test_*.duckdb

echo "Test file: $TEST_FILE"
echo "Output DB: $OUTPUT_DB"
echo ""

echo "-----------------------------------"
echo "Testing MDBTOOLS implementation"
echo "-----------------------------------"
START=$(date +%s)
python3 convert_mdbtools.py --input "$TEST_FILE" --output "${OUTPUT_DB}_mdbtools" 2>&1 | tail -5
END=$(date +%s)
MDBTOOLS_TIME=$((END - START))
echo "Time: ${MDBTOOLS_TIME}s"
echo ""

echo "-----------------------------------"
echo "Testing JACKCESS implementation"
echo "-----------------------------------"
START=$(date +%s)
python3 convert_jackcess.py --input "$TEST_FILE" --output "${OUTPUT_DB}_jackcess" 2>&1 | tail -5
END=$(date +%s)
JACKCESS_TIME=$((END - START))
echo "Time: ${JACKCESS_TIME}s"
echo ""

echo "-----------------------------------"
echo "Testing PYPYODBC implementation"
echo "-----------------------------------"
START=$(date +%s)
python3 convert_pyodbc.py --input "$TEST_FILE" --output "${OUTPUT_DB}_pyodbc" 2>&1 | tail -5
END=$(date +%s)
PYODBC_TIME=$((END - START))
echo "Time: ${PYODBC_TIME}s"
echo ""

echo "==================================="
echo "SUMMARY"
echo "==================================="
echo "MDBTOOLS: ${MDBTOOLS_TIME}s"
echo "JACKCESS:  ${JACKCESS_TIME}s"
echo "PYPYODBC:  ${PYODBC_TIME}s"
echo "==================================="

ls -lh *_mdbtools *_jackcess *_pyodbc 2>/dev/null
