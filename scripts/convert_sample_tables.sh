#!/bin/bash
# NIVEL BASICO: Script para converter apenas 3 tabelas de exemplo
# Para testes rapidos sem esperar conversao completa

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
IMPORT_DIR="$PROJECT_ROOT/poc/importacao"
DATA_DIR="$PROJECT_ROOT/data"

mkdir -p "$DATA_DIR"

LATEST_MDB=$(ls -t "$IMPORT_DIR"/*.accdb 2>/dev/null | head -1)

if [ -z "$LATEST_MDB" ]; then
    echo "Error: No .accdb files found"
    exit 1
fi

echo "Source: $LATEST_MDB"

OUTPUT_DB="$DATA_DIR/sample.duckdb"
rm -f "$OUTPUT_DB"

echo "Output: $OUTPUT_DB"

# NIVEL BASICO: Converte apenas 3 tabelas como exemplo
# SOACCU: accumulator data
# SOGEN: general data
# SOVARS: variables
SAMPLE_TABLES="RANGER_SOACCU RANGER_SOGEN RANGER_SOVARS"

for TABLE in $SAMPLE_TABLES; do
    echo "Converting $TABLE..."
    mdb-export "$LATEST_MDB" "$TABLE" 2>/dev/null | \
        duckdb "$OUTPUT_DB" "CREATE TABLE IF NOT EXISTS \"$TABLE\" AS SELECT * FROM read_csv_auto('/dev/stdin')" || echo "  (table may be empty or not exist)"
done

echo "Sample DB created: $OUTPUT_DB"

# NIVEL BASICO: Mostra estatisticas rapidas
duckdb "$OUTPUT_DB" <<SQL
SELECT 'Tables created:' as info;
SHOW TABLES;
SELECT '';
SELECT 'Row counts:' as info;
SELECT 'RANGER_SOACCU' as table_name, COUNT(*) as rows FROM RANGER_SOACCU;
SELECT 'RANGER_SOGEN' as table_name, COUNT(*) as rows FROM RANGER_SOGEN;
SELECT 'RANGER_SOVARS' as table_name, COUNT(*) as rows FROM RANGER_SOVARS;
SQL

echo "Done!"
