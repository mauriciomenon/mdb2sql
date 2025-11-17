#!/usr/bin/env python3
"""
MDB to DuckDB Benchmark Suite
Created: 2025-01-20T00:00:00Z
Last Modified: 2025-01-20T00:00:00Z

Description:
    Benchmarks different implementations for converting Microsoft Access
    MDB/ACCDB files to DuckDB format. Measures execution time, success rate,
    and generates comparison reports.

Provides:
    - BenchmarkRunner: Main benchmark orchestration class
    - run_benchmark(): Executes all implementations and collects metrics
    - generate_report(): Creates summary statistics and comparison tables

Implementations Tested:
    - mdbtools: CLI-based converter using mdb-export
    - jackcess: Java-based converter using Jackcess library
    - pyaccess_parser: Pure Python converter using access-parser
    - pypyodbc: Windows-only ODBC-based converter

Dependencies:
    - Python 3.x
    - All converter scripts in the same directory
"""

import subprocess
import time
import sys
from pathlib import Path
import json
from datetime import datetime

class BenchmarkRunner:
    def __init__(self, mdb_folder="import_folder", output_db="benchmark_output.duckdb"):
        self.mdb_folder = Path(mdb_folder)
        self.output_db = output_db
        self.results = []
        
    def find_mdb_files(self):
        mdb_files = list(self.mdb_folder.glob("*.mdb"))
        accdb_files = list(self.mdb_folder.glob("*.accdb"))
        return sorted(mdb_files + accdb_files)
    
    def run_implementation(self, script_name, mdb_file):
        start_time = time.time()
        success = False
        error_msg = None

        try:
            result = subprocess.run(
                ["python3", script_name, "--input", str(mdb_file), "--output", self.output_db],
                capture_output=True,
                text=True
            )
            elapsed_time = time.time() - start_time
            success = result.returncode == 0
            error_msg = result.stderr if not success else None

        except FileNotFoundError:
            elapsed_time = 0
            error_msg = f"Script {script_name} not found"
        except Exception as e:
            elapsed_time = time.time() - start_time
            error_msg = str(e)

        return {
            "success": success,
            "elapsed_time": elapsed_time,
            "error": error_msg
        }

    def run_benchmark(self):
        implementations = [
            ("convert_mdbtools.py", "mdbtools"),
            ("convert_jackcess.py", "jackcess"),
            ("convert_pyaccess_parser.py", "pyaccess_parser"),
            ("convert_pyodbc.py", "pypyodbc")
        ]

        mdb_files = self.find_mdb_files()

        if not mdb_files:
            print(f"No MDB/ACCDB files found in {self.mdb_folder}")
            return
        
        print(f"Found {len(mdb_files)} files to test")
        print(f"Testing {len(implementations)} implementations\n")
        
        for mdb_file in mdb_files:
            print(f"\nTesting: {mdb_file.name}")
            print("-" * 60)
            
            file_results = {
                "file": mdb_file.name,
                "file_size": mdb_file.stat().st_size,
                "implementations": {}
            }
            
            for script, impl_name in implementations:
                print(f"  {impl_name:12s} ... ", end="", flush=True)
                
                result = self.run_implementation(script, mdb_file)
                
                if result["success"]:
                    print(f"OK ({result['elapsed_time']:.2f}s)")
                else:
                    print(f"FAILED ({result['elapsed_time']:.2f}s)")
                    if result["error"]:
                        print(f"    Error: {result['error'][:100]}")
                
                file_results["implementations"][impl_name] = result
            
            self.results.append(file_results)
        
        self.print_summary()
        self.save_results()
    
    def print_summary(self):
        print("\n" + "=" * 60)
        print("BENCHMARK SUMMARY")
        print("=" * 60)
        
        impl_stats = {}
        
        for file_result in self.results:
            for impl_name, result in file_result["implementations"].items():
                if impl_name not in impl_stats:
                    impl_stats[impl_name] = {
                        "total_time": 0,
                        "success_count": 0,
                        "fail_count": 0,
                        "files_tested": 0
                    }
                
                stats = impl_stats[impl_name]
                stats["files_tested"] += 1
                stats["total_time"] += result["elapsed_time"]
                
                if result["success"]:
                    stats["success_count"] += 1
                else:
                    stats["fail_count"] += 1
        
        print("\nImplementation Performance:")
        print("-" * 60)
        
        for impl_name, stats in sorted(impl_stats.items()):
            avg_time = stats["total_time"] / stats["files_tested"] if stats["files_tested"] > 0 else 0
            success_rate = (stats["success_count"] / stats["files_tested"] * 100) if stats["files_tested"] > 0 else 0
            
            print(f"\n{impl_name.upper()}:")
            print(f"  Files tested:   {stats['files_tested']}")
            print(f"  Success:        {stats['success_count']} ({success_rate:.1f}%)")
            print(f"  Failed:         {stats['fail_count']}")
            print(f"  Total time:     {stats['total_time']:.2f}s")
            print(f"  Average time:   {avg_time:.2f}s")
        
        print("\n" + "=" * 60)
    
    def save_results(self):
        output_file = f"benchmark_results_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        
        with open(output_file, "w") as f:
            json.dump({
                "timestamp": datetime.now().isoformat(),
                "results": self.results
            }, f, indent=2)
        
        print(f"\nResults saved to: {output_file}")

def main():
    if len(sys.argv) > 1:
        mdb_folder = sys.argv[1]
    else:
        mdb_folder = "import_folder"
    
    print("MDB2SQL Benchmark Tool")
    print("=" * 60)
    print(f"MDB folder: {mdb_folder}")
    print(f"Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)
    
    runner = BenchmarkRunner(mdb_folder)
    runner.run_benchmark()

if __name__ == "__main__":
    main()
