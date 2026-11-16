// Leitura de .mdb/.accdb: ODBC do Access (se instalado) ou mdbtools embutido, importando para DuckDB em memoria
// !T: Order: ODBC driver, then embedded mdbtools, else a clear message; MDB2SQL_ACCESS_READER=odbc|mdbtools forces one

package backend

import (
	"bufio"
	"bytes"
	"context"
	"database/sql"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// AccessODBCDriver is the 64-bit driver of the Microsoft Access Database Engine
const AccessODBCDriver = "Microsoft Access Driver (*.mdb, *.accdb)"

const accessEngineURL = "https://www.microsoft.com/download/details.aspx?id=54920"

// chooseAccessReader applies the reader order; force is MDB2SQL_ACCESS_READER ("", "auto", "odbc" or "mdbtools")
func chooseAccessReader(force string, odbcOK, mdbtoolsOK bool) (string, error) {
	noODBC := fmt.Errorf("the ODBC driver %q is not installed (64-bit Microsoft Access Database Engine: %s)", AccessODBCDriver, accessEngineURL)
	switch strings.ToLower(strings.TrimSpace(force)) {
	case "", "auto":
		if odbcOK {
			return SourceODBC, nil
		}
		if mdbtoolsOK {
			return SourceMdbtools, nil
		}
		return "", fmt.Errorf("cannot read Access files on this computer: install the 64-bit Microsoft Access Database Engine "+
			"(ODBC driver %q) from %s, or use the release build of mdb2sql, which embeds mdbtools", AccessODBCDriver, accessEngineURL)
	case "odbc":
		if !odbcOK {
			return "", fmt.Errorf("MDB2SQL_ACCESS_READER=odbc, but %w", noODBC)
		}
		return SourceODBC, nil
	case "mdbtools":
		if !mdbtoolsOK {
			return "", fmt.Errorf("MDB2SQL_ACCESS_READER=mdbtools, but mdbtools is not embedded in this build nor on PATH")
		}
		return SourceMdbtools, nil
	}
	return "", fmt.Errorf("MDB2SQL_ACCESS_READER=%q: use odbc, mdbtools or leave it empty", force)
}

func openAccess(ctx context.Context, path string, progress Progress) (*sql.DB, string, error) {
	reader, err := chooseAccessReader(os.Getenv("MDB2SQL_ACCESS_READER"), odbcInstalled(), mdbtoolsAvailable())
	if err != nil {
		return nil, "", err
	}
	db, err := openMemory()
	if err != nil {
		return nil, "", err
	}
	if reader == SourceODBC {
		err = importODBC(ctx, db, path, progress)
	} else {
		err = importMdbtools(ctx, db, path, progress)
	}
	if err != nil {
		db.Close()
		return nil, "", fmt.Errorf("%s: %w", reader, err)
	}
	return db, reader, nil
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
	switch strings.ToLower(strings.TrimSpace(t)) {
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
	// Text (n), Memo/Hyperlink, Replication ID; Binary/OLE too, as hex text
	// shortcut: binary columns become hex VARCHAR on this path (none in the NMR5 files); load as BLOB if one appears
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
	hideWindow(cmd)
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
	for i, t := range tables {
		progress(i, len(tables), t)
		cols := schema[t]
		if len(cols) == 0 {
			return fmt.Errorf("mdb-schema has no columns for table %s", t)
		}
		defs := make([]string, len(cols))
		for j, c := range cols {
			defs[j] = quoteIdent(c.name) + " " + accessToDuck(c.typ)
		}
		if _, err := db.ExecContext(ctx, fmt.Sprintf("CREATE TABLE %s (%s)", quoteIdent(t), strings.Join(defs, ", "))); err != nil {
			return fmt.Errorf("create %s: %w", t, err)
		}
		csvPath := filepath.Join(tmp, fmt.Sprintf("%d.csv", i))
		if err := exportCSV(ctx, exe[2], path, t, csvPath); err != nil {
			return err
		}
		// all_varchar + INSERT casts each column to the table type; quoted "" stays an empty string, unquoted is NULL
		load := fmt.Sprintf(`INSERT INTO %s SELECT * FROM read_csv(%s, header=true, all_varchar=true, delim=',', quote='"', escape='"', allow_quoted_nulls=false)`,
			quoteIdent(t), quoteLiteral(csvPath))
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
	cmd := exec.CommandContext(ctx, exe, "-D", ts, "-T", ts, "-B", "-b", "hex", path, table)
	hideWindow(cmd)
	var stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = f, &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("mdb-export %s: %w: %s", table, err, strings.TrimSpace(stderr.String()))
	}
	return f.Close()
}
