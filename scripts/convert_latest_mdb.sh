#!/bin/bash
# NIVEL BASICO: Script para converter ultimo MDB para DuckDB
# Usa mdbtools (CLI) para extrair dados e importar no DuckDB

# NIVEL TECNICO: Find latest MDB, extract tables, convert to DuckDB
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
IMPORT_DIR="$PROJECT_ROOT/poc/importacao"
DATA_DIR="$PROJECT_ROOT/data"

# NIVEL BASICO: Cria diretorio data/ se nao existir
mkdir -p "$DATA_DIR"

# NIVEL BASICO: Encontra ultimo arquivo MDB (mais recente por data)
LATEST_MDB=$(ls -t "$IMPORT_DIR"/*.accdb 2>/dev/null | head -1)

if [ -z "$LATEST_MDB" ]; then
    echo "Error: No .accdb files found in $IMPORT_DIR"
    exit 1
fi

echo "Latest MDB: $LATEST_MDB"

# NIVEL BASICO: Extrai nome base para output
BASENAME=$(basename "$LATEST_MDB" .accdb)
OUTPUT_DB="$DATA_DIR/${BASENAME// /_}.duckdb"

echo "Converting to: $OUTPUT_DB"

# NIVEL BASICO: Remove DB antigo se existir
rm -f "$OUTPUT_DB"

# NIVEL BASICO: Lista todas as tabelas do MDB
TABLES=$(mdb-tables "$LATEST_MDB")

if [ -z "$TABLES" ]; then
    echo "Error: No tables found in MDB"
    exit 1
fi

# NIVEL TECNICO: Convert each table via CSV pipe to DuckDB
# mdb-export outputs CSV, duckdb imports directly from stdin
echo "Found $(echo $TABLES | wc -w | tr -d ' ') tables"

TABLE_COUNT=0
for TABLE in $TABLES; do
    TABLE_COUNT=$((TABLE_COUNT + 1))
    echo "[$TABLE_COUNT] Converting $TABLE..."

    # NIVEL TECNICO: Export to CSV, import to DuckDB via stdin
    # Use COPY FROM to handle large tables efficiently
    mdb-export "$LATEST_MDB" "$TABLE" | \
        duckdb "$OUTPUT_DB" "CREATE TABLE IF NOT EXISTS \"$TABLE\" AS SELECT * FROM read_csv_auto('/dev/stdin')"
done

echo "Conversion complete: $OUTPUT_DB"
echo "Total tables: $TABLE_COUNT"

# NIVEL BASICO: Cria arquivo metadata JSON
METADATA_FILE="$DATA_DIR/${BASENAME// /_}.meta.json"
cat > "$METADATA_FILE" <<EOF
{
  "source_file": "$LATEST_MDB",
  "output_db": "$OUTPUT_DB",
  "converted_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "table_count": $TABLE_COUNT,
  "tables": [
EOF

# NIVEL TECNICO: Add table list to metadata
FIRST=true
for TABLE in $TABLES; do
    if [ "$FIRST" = true ]; then
        FIRST=false
    else
        echo "," >> "$METADATA_FILE"
    fi
    echo -n "    \"$TABLE\"" >> "$METADATA_FILE"
done

cat >> "$METADATA_FILE" <<EOF

  ]
}
EOF

echo "Metadata saved: $METADATA_FILE"
