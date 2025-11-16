#!/usr/bin/env python3

import argparse
import duckdb
import subprocess
import re
import sys
from pathlib import Path
from datetime import datetime
from typing import Optional, List


def extract_date_from_filename(filename: str) -> Optional[str]:
    patterns = [
        r'(\d{2})[_-](\d{2})[_-](\d{4})',
        r'(\d{4})[_-](\d{2})[_-](\d{2})',
        r'(\d{2})(\d{2})(\d{4})',
        r'(\d{4})(\d{2})(\d{2})',
    ]
    
    for pattern in patterns:
        match = re.search(pattern, filename)
        if match:
            groups = match.groups()
            if len(groups[0]) == 4:
                return f"{groups[0]}-{groups[1]}-{groups[2]}"
            else:
                return f"{groups[2]}-{groups[1]}-{groups[0]}"
    
    return None


def get_mdb_tables(mdb_file: Path) -> List[str]:
    try:
        result = subprocess.run(
            ['mdb-tables', '-1', str(mdb_file)],
            capture_output=True,
            text=True,
            check=True
        )
        tables = [t.strip() for t in result.stdout.split('\n') if t.strip()]
        return tables
    except subprocess.CalledProcessError as e:
        print(f"Error listing tables: {e}")
        return []
    except FileNotFoundError:
        print("mdb-tools not found. Install with: brew install mdbtools (macOS) or sudo apt install mdbtools (Linux)")
        sys.exit(1)


def export_table_to_csv(mdb_file: Path, table_name: str, output_csv: Path) -> bool:
    try:
        with open(output_csv, 'w') as f:
            subprocess.run(
                ['mdb-export', str(mdb_file), table_name],
                stdout=f,
                check=True
            )
        return True
    except subprocess.CalledProcessError as e:
        print(f"Erro ao exportar tabela {table_name}: {e}")
        return False


def import_to_duckdb(
    mdb_file: Path,
    duckdb_file: Path,
    file_date: Optional[str] = None
):
    print(f"\nProcessing: {mdb_file.name}")
    
    if not file_date:
        file_date = extract_date_from_filename(mdb_file.name)
    
    if not file_date:
        print(f"WARNING: Could not extract date from file {mdb_file.name}")
        file_date = datetime.now().strftime('%Y-%m-%d')
    
    print(f"Date extracted: {file_date}")
    
    tables = get_mdb_tables(mdb_file)
    if not tables:
        print("No tables found")
        return
    
    print(f"Tables found: {len(tables)}")
    
    conn = duckdb.connect(str(duckdb_file))
    
    conn.execute("""
        CREATE TABLE IF NOT EXISTS _metadata (
            import_id INTEGER PRIMARY KEY,
            source_file VARCHAR,
            file_date DATE,
            import_timestamp TIMESTAMP,
            table_name VARCHAR,
            row_count INTEGER
        )
    """)
    
    conn.execute("CREATE SEQUENCE IF NOT EXISTS seq_import_id START 1")
    
    import_timestamp = datetime.now()
    temp_dir = Path('/tmp/mdb2sql')
    temp_dir.mkdir(exist_ok=True)
    
    for table in tables:
        print(f"  Importing: {table}...", end=' ', flush=True)
        
        csv_file = temp_dir / f"{table}.csv"
        
        if not export_table_to_csv(mdb_file, table, csv_file):
            print("FAILED")
            continue
        
        if csv_file.stat().st_size == 0:
            print("EMPTY")
            csv_file.unlink()
            continue
        
        table_with_date = f"{table}_{file_date.replace('-', '')}"
        
        try:
            conn.execute(f"""
                CREATE TABLE IF NOT EXISTS "{table_with_date}" AS 
                SELECT * FROM read_csv_auto('{csv_file}', 
                    header=true, 
                    ignore_errors=true,
                    sample_size=100000
                )
            """)
            
            result = conn.execute(f'SELECT COUNT(*) FROM "{table_with_date}"').fetchone()
            row_count = result[0] if result else 0
            
            conn.execute("""
                INSERT INTO _metadata 
                (import_id, source_file, file_date, import_timestamp, table_name, row_count)
                VALUES (nextval('seq_import_id'), ?, ?, ?, ?, ?)
            """, [mdb_file.name, file_date, import_timestamp, table_with_date, row_count])
            
            print(f"OK ({row_count} rows)")
            
        except Exception as e:
            print(f"ERROR: {e}")
        finally:
            csv_file.unlink(missing_ok=True)
    
    conn.close()
    print(f"\nImport completed: {duckdb_file}")


def batch_import(input_dir: Path, duckdb_file: Path):
    mdb_files = sorted(list(input_dir.glob('*.mdb')) + list(input_dir.glob('*.accdb')))
    
    if not mdb_files:
        print(f"No MDB/ACCDB files found in {input_dir}")
        return
    
    print(f"\n{'='*60}")
    print(f"Encontrados {len(mdb_files)} arquivos para processar")
    print(f"{'='*60}")
    
    for i, mdb_file in enumerate(mdb_files, 1):
        print(f"\n[{i}/{len(mdb_files)}]", end=' ')
        import_to_duckdb(mdb_file, duckdb_file)


def main():
    parser = argparse.ArgumentParser(
        description='Convert MDB/ACCDB to DuckDB using mdbtools'
    )
    parser.add_argument(
        '--input',
        type=Path,
        help='Input MDB/ACCDB file or directory for batch'
    )
    parser.add_argument(
        '--output',
        type=Path,
        default=Path('database.duckdb'),
        help='Output DuckDB file (default: database.duckdb)'
    )
    parser.add_argument(
        '--batch',
        action='store_true',
        help='Process all MDB/ACCDB files in --input directory'
    )
    
    args = parser.parse_args()
    
    if not args.input:
        parser.print_help()
        sys.exit(1)
    
    if not args.input.exists():
        print(f"Error: {args.input} not found")
        sys.exit(1)
    
    if args.batch:
        if not args.input.is_dir():
            print("Error: --batch requires --input to be a directory")
            sys.exit(1)
        batch_import(args.input, args.output)
    else:
        if not args.input.is_file():
            print("Error: --input must be a MDB/ACCDB file")
            sys.exit(1)
        import_to_duckdb(args.input, args.output)


if __name__ == '__main__':
    main()
