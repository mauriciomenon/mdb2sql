// Leitura de .mdb/.accdb: ODBC do Access (se instalado) ou mdbtools embutido; o arquivo e convertido UMA vez para
// SQLite (arquivo temporario, ver convert.go) e lido dali
// !T: Order: ODBC driver, then embedded mdbtools, else a clear message; MDB2SQL_ACCESS_READER=odbc|mdbtools forces one

package backend

import (
	"bufio"
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"

	"mdb2sql/i18n"
)

// AccessODBCDriver is the 64-bit driver of the Microsoft Access Database Engine
const AccessODBCDriver = "Microsoft Access Driver (*.mdb, *.accdb)"

const accessEngineURL = "https://www.microsoft.com/download/details.aspx?id=54920"

// chooseAccessReader applies the reader order; force is MDB2SQL_ACCESS_READER ("", "auto", "odbc" or "mdbtools")
func chooseAccessReader(force string, odbcOK, mdbtoolsOK bool) (string, error) {
	switch strings.ToLower(strings.TrimSpace(force)) {
	case "", "auto":
		if odbcOK {
			return SourceODBC, nil
		}
		if mdbtoolsOK {
			return SourceMdbtools, nil
		}
		return "", errors.New(i18n.T("err.noAccessReader", AccessODBCDriver, accessEngineURL))
	case "odbc":
		if !odbcOK {
			return "", errors.New(i18n.T("err.forcedODBC", AccessODBCDriver, accessEngineURL))
		}
		return SourceODBC, nil
	case "mdbtools":
		if !mdbtoolsOK {
			return "", errors.New(i18n.T("err.forcedMdbtools"))
		}
		return SourceMdbtools, nil
	}
	return "", errors.New(i18n.T("err.badReader", force))
}

// openAccess converts the Access file ONCE into a SQLite file (temporary, see convert.go) and returns its path.
// The reader fills an in-memory DuckDB, which copyDatabase then writes to SQLite with typed columns.
func openAccess(ctx context.Context, path string, progress Progress) (sqlitePath, reader string, err error) {
	if reader, err = chooseAccessReader(os.Getenv("MDB2SQL_ACCESS_READER"), odbcInstalled(), mdbtoolsAvailable()); err != nil {
		return "", "", err
	}
	db, err := openMemory()
	if err != nil {
		return "", "", err
	}
	defer db.Close()
	if reader == SourceODBC {
		err = importODBC(ctx, db, path, progress)
	} else {
		err = importMdbtools(ctx, db, path, progress)
	}
	if err != nil {
		return "", "", fmt.Errorf("%s: %w", reader, err)
	}
	tables, err := listTables(db)
	if err != nil {
		return "", "", err
	}
	if sqlitePath, err = newConvertedPath(path); err != nil {
		return "", "", err
	}
	if err = copyDatabase(ctx, db, "sqlite", sqlitePath, tableItems(tables), progress); err != nil {
		RemoveConverted(sqlitePath)
		return "", "", err
	}
	return sqlitePath, reader, nil
}

type accessColumn struct{ name, typ string }

var (
	schemaTableRe  = regexp.MustCompile(`^CREATE TABLE \[(.+)\]\s*$`)
	schemaColumnRe = regexp.MustCompile(`^\s+\[(.+)\]\s+(.+?)\s*,?\s*$`)
	numericRe      = regexp.MustCompile(`(?i)^numeric\s*\((\d+),\s*(\d+)\)$`)
)

// parseAccessSchema reads `mdb-schema <file> access` (Access type names in [brackets]; Access forbids ] in names)
func parseAccessSchema(ddl string) map[string][]accessColumn {
	out := map[string][]accessColumn{}
	table := ""
	sc := bufio.NewScanner(strings.NewReader(ddl))
	sc.Buffer(make([]byte, 64*1024), 16*1024*1024)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if m := schemaTableRe.FindStringSubmatch(line); m != nil {
			table = m[1]
			out[table] = nil
		} else if strings.HasPrefix(line, ");") {
			table = ""
		} else if m := schemaColumnRe.FindStringSubmatch(line); m != nil && table != "" {
			out[table] = append(out[table], accessColumn{m[1], m[2]})
		}
	}
	return out
}

// accessToDuck maps mdbtools' Access type names to DuckDB (the same types the ODBC reader produces)
func accessToDuck(t string) string {
	if m := numericRe.FindStringSubmatch(strings.TrimSpace(t)); m != nil {
		p, _ := strconv.Atoi(m[1])
		s, _ := strconv.Atoi(m[2])
		return decimalType(p, s)
	}
	l := strings.ToLower(strings.TrimSpace(t))
	switch l {
	case "boolean":
		return "BOOLEAN"
	case "byte":
		return "UTINYINT"
	case "integer":
		return "SMALLINT"
	case "long integer":
		return "INTEGER"
	case "currency":
		return "DECIMAL(19,4)"
	case "single":
		return "REAL"
	case "double":
		return "DOUBLE"
	case "datetime":
		return "TIMESTAMP"
	}
	// OLE (n), Binary (n): mdb-export writes them as hex (-b hex), loaded with from_hex
	if strings.HasPrefix(l, "ole") || strings.HasPrefix(l, "binary") {
		return "BLOB"
	}
	// Text (n), Memo/Hyperlink, Replication ID
	return "VARCHAR"
}

func decimalType(p, s int) string {
	if p < 1 || p > 38 || s < 0 || s > p {
		return "DOUBLE"
	}
	return fmt.Sprintf("DECIMAL(%d,%d)", p, s)
}

func runTool(ctx context.Context, exe string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, exe, args...)
	prepareTool(cmd)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("%s: %w: %s", filepath.Base(exe), err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

func importMdbtools(ctx context.Context, db *sql.DB, path string, progress Progress) error {
	var exe [3]string
	for i, n := range mdbtoolsNames {
		p, err := mdbtool(n)
		if err != nil {
			return err
		}
		exe[i] = p
	}
	list, err := runTool(ctx, exe[0], "-1", path)
	if err != nil {
		return err
	}
	ddl, err := runTool(ctx, exe[1], "--no-indexes", "--no-relations", "--no-comments", "--no-default-values",
		"--no-not-null", "--no-drop-table", path, "access")
	if err != nil {
		return err
	}
	schema := parseAccessSchema(string(ddl))
	var tables []string
	for _, t := range strings.Split(string(list), "\n") {
		if t = strings.TrimRight(t, "\r"); t != "" {
			tables = append(tables, t)
		}
	}

	tmp, err := os.MkdirTemp("", "mdb2sql-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	// mdb-export is the slow part (DB4: ~100 s in one process, 40 s of them in RANGER_SOSTAT), so several run at once;
	// the loads below still go one by one in table order, each waiting for its own CSV
	ctx, stop := context.WithCancel(ctx)
	var wg sync.WaitGroup
	defer wg.Wait() // runs after stop(): every export has ended before tmp is removed
	defer stop()    // an error below stops the exports still running
	exported := make([]chan error, len(tables))
	for i := range exported {
		exported[i] = make(chan error, 1)
	}
	slots := make(chan struct{}, min(4, max(1, runtime.NumCPU()/2)))
	wg.Add(1)
	go func() { // starts the exports in table order, a few at a time
		defer wg.Done()
		for i, t := range tables {
			slots <- struct{}{}
			if ctx.Err() != nil {
				exported[i] <- ctx.Err()
				<-slots
				continue
			}
			wg.Add(1)
			go func() {
				defer wg.Done()
				exported[i] <- exportCSV(ctx, exe[2], path, t, filepath.Join(tmp, fmt.Sprintf("%d.csv", i)))
				<-slots
			}()
		}
	}()
	for i, t := range tables {
		progress(i, len(tables), t)
		cols := schema[t]
		if len(cols) == 0 {
			return fmt.Errorf("mdb-schema has no columns for table %s", t)
		}
		defs := make([]string, len(cols))
		exprs := make([]string, len(cols))
		names := make([]string, len(cols))
		for j, c := range cols {
			typ := accessToDuck(c.typ)
			defs[j] = quoteIdent(c.name) + " " + typ
			// the CSV columns get neutral names (c0, c1...): Access names may repeat after case folding
			names[j] = fmt.Sprintf("'c%d': 'VARCHAR'", j)
			exprs[j] = fmt.Sprintf("c%d", j)
			if typ == "BLOB" {
				exprs[j] = "from_hex(" + exprs[j] + ")"
			}
		}
		if _, err := db.ExecContext(ctx, fmt.Sprintf("CREATE TABLE %s (%s)", quoteIdent(t), strings.Join(defs, ", "))); err != nil {
			return fmt.Errorf("create %s: %w", t, err)
		}
		csvPath := filepath.Join(tmp, fmt.Sprintf("%d.csv", i))
		if err := <-exported[i]; err != nil {
			return err
		}
		// text columns, then INSERT casts each one to the table type. mdb-export writes NULL as \N (-0), so an empty
		// field is an empty string and a quoted "\N" is text (allow_quoted_nulls=false)
		load := fmt.Sprintf(`INSERT INTO %s SELECT %s FROM read_csv(%s, header=true, columns={%s}, delim=',', quote='"', escape='"', nullstr='\N', allow_quoted_nulls=false)`,
			quoteIdent(t), strings.Join(exprs, ", "), quoteLiteral(csvPath), strings.Join(names, ", "))
		if _, err := db.ExecContext(ctx, load); err != nil {
			return fmt.Errorf("load %s: %w", t, err)
		}
		os.Remove(csvPath)
	}
	progress(len(tables), len(tables), "")
	return nil
}

func exportCSV(ctx context.Context, exe, path, table, csvPath string) error {
	f, err := os.Create(csvPath)
	if err != nil {
		return err
	}
	defer f.Close()
	const ts = "%Y-%m-%d %H:%M:%S"
	cmd := exec.CommandContext(ctx, exe, "-D", ts, "-T", ts, "-B", "-b", "hex", "-0", `\N`, path, table)
	prepareTool(cmd)
	var stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = f, &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("mdb-export %s: %w: %s", table, err, strings.TrimSpace(stderr.String()))
	}
	return f.Close()
}
