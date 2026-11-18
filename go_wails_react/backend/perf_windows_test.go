package backend

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Medicao de desempenho ao abrir Access (REGRA_DESEMPENHO): MDB2SQL_PERF=1 e MDB2SQL_TEST_DB_DIR com as copias.
// 3 execucoes por caso, mediana; etapas: leitura do Access (export + carga), gravacao do SQLite, abertura com a
// lista de tabelas e a 1a tabela (100 linhas). Memoria: pico do processo (working set) no fim.
// !T: go test ./backend -run Perf -v -timeout 120m

var procGetProcessMemoryInfo = windows.NewLazySystemDLL("psapi.dll").NewProc("GetProcessMemoryInfo")

type memCounters struct {
	cb                                                         uint32
	pageFaults                                                 uint32
	peakWorkingSet, workingSet, quotaPeakPaged, quotaPaged     uintptr
	quotaPeakNonPaged, quotaNonPaged, pagefileUsage, peakPagef uintptr
}

func peakMB() float64 {
	var m memCounters
	m.cb = uint32(unsafe.Sizeof(m))
	procGetProcessMemoryInfo.Call(uintptr(windows.CurrentProcess()), uintptr(unsafe.Pointer(&m)), uintptr(m.cb))
	return float64(m.peakWorkingSet) / (1 << 20)
}

func median(d []time.Duration) time.Duration {
	s := append([]time.Duration(nil), d...)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	return s[len(s)/2]
}

func secs(d time.Duration) string { return fmt.Sprintf("%.1f", d.Seconds()) }

func TestPerfAccessOpen(t *testing.T) {
	if os.Getenv("MDB2SQL_PERF") == "" {
		t.Skip("MDB2SQL_PERF not set")
	}
	dir := realDBDir(t)
	readers := []string{"mdbtools"}
	if odbcInstalled() {
		readers = append(readers, "odbc")
	}
	noProgress := func(int, int, string) {}
	for _, base := range realBases {
		for _, r := range readers {
			var read, write, open, total []time.Duration
			saved := ""
			for run := 0; run < 3; run++ {
				t.Setenv("MDB2SQL_ACCESS_READER", r)
				ctx := context.Background()
				t0 := time.Now()
				reader := SourceODBC
				if r == "mdbtools" {
					reader = SourceMdbtools
				}
				db, err := importAccess(ctx, reader, filepath.Join(dir, base+".accdb"), noProgress)
				if err != nil {
					t.Fatal(err)
				}
				t1 := time.Now()
				tables, _ := listTables(db)
				out, _ := newConvertedPath(base + ".accdb")
				if err := copyDatabase(ctx, db, "sqlite", out, tableItems(tables), noProgress); err != nil {
					t.Fatal(err)
				}
				db.Close()
				t2 := time.Now()
				m := NewDBManager()
				if err := m.Connect(out); err != nil {
					t.Fatal(err)
				}
				list, _ := m.ListTables()
				if _, err := m.QueryTable(list[0], 100, ""); err != nil {
					t.Fatal(err)
				}
				t3 := time.Now()
				m.Close()
				read, write, open, total = append(read, t1.Sub(t0)), append(write, t2.Sub(t1)), append(open, t3.Sub(t2)), append(total, t3.Sub(t0))
				if saved != "" {
					RemoveConverted(saved)
				}
				saved = out
			}
			t.Logf("PERF %s %s: read %s | write SQLite %s | open+list+1st table %s | total %s s (median of 3)",
				base, r, secs(median(read)), secs(median(write)), secs(median(open)), secs(median(total)))

			// the saved SQLite reopened, and the exports from it
			var reopen, expS, expD []time.Duration
			for run := 0; run < 3; run++ {
				t0 := time.Now()
				m := NewDBManager()
				if err := m.Connect(saved); err != nil {
					t.Fatal(err)
				}
				list, _ := m.ListTables()
				m.QueryTable(list[0], 100, "")
				t1 := time.Now()
				tmp := t.TempDir()
				if err := m.ExportDatabase(context.Background(), "sqlite", filepath.Join(tmp, "e.sqlite"), noProgress); err != nil {
					t.Fatal(err)
				}
				t2 := time.Now()
				if err := m.ExportDatabase(context.Background(), "duckdb", filepath.Join(tmp, "e.duckdb"), noProgress); err != nil {
					t.Fatal(err)
				}
				t3 := time.Now()
				m.Close()
				reopen, expS, expD = append(reopen, t1.Sub(t0)), append(expS, t2.Sub(t1)), append(expD, t3.Sub(t2))
			}
			RemoveConverted(saved)
			t.Logf("PERF %s %s: reopen saved SQLite %s | Export→SQLite %s | Export→DuckDB %s s", base, r,
				secs(median(reopen)), secs(median(expS)), secs(median(expD)))
		}
		for _, ext := range []string{".sqlite", ".duckdb"} {
			var d []time.Duration
			for run := 0; run < 3; run++ {
				t0 := time.Now()
				m := NewDBManager()
				if err := m.Connect(filepath.Join(dir, base+ext)); err != nil {
					t.Fatal(err)
				}
				list, _ := m.ListTables()
				m.QueryTable(list[0], 100, "")
				d = append(d, time.Since(t0))
				m.Close()
			}
			t.Logf("PERF %s reference %s: open+list+1st table %s s", base, ext, secs(median(d)))
		}
	}
	t.Logf("PERF peak working set of the test process: %.0f MB", peakMB())
}
