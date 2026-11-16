//go:build windows

// Leitor Access pelo ODBC do Windows (odbc32.dll, sem cgo): catalogo por SQLTables/SQLColumns, dados por database/sql
// !T: github.com/alexbrainman/odbc reads rows; it has no catalog functions, so those two are called directly

package backend

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"fmt"
	"math"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"github.com/alexbrainman/odbc"
	"github.com/alexbrainman/odbc/api"
	"github.com/duckdb/duckdb-go/v2"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// odbcInstalled reads the 64-bit driver list (this process is 64-bit, so it sees the 64-bit registry view)
func odbcInstalled() bool {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers`, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer k.Close()
	v, _, err := k.GetStringValue(AccessODBCDriver)
	return err == nil && v == "Installed"
}

func hideWindow(cmd *exec.Cmd) {
	// a GUI exe starting console programs would flash a console window per call
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}
}

func odbcConnString(path string) string {
	if strings.ContainsAny(path, ";{}") {
		path = "{" + strings.ReplaceAll(path, "}", "}}") + "}"
	}
	return "Driver={" + AccessODBCDriver + "};Dbq=" + path + ";ReadOnly=1;"
}

var (
	odbc32          = windows.NewLazySystemDLL("odbc32.dll")
	procSQLTablesW  = odbc32.NewProc("SQLTablesW")
	procSQLColumnsW = odbc32.NewProc("SQLColumnsW")
)

type odbcColumn struct {
	name             string
	dataType, digits int
	size             int
}

func odbcOK(r api.SQLRETURN) bool { return r == api.SQL_SUCCESS || r == api.SQL_SUCCESS_WITH_INFO }

func wstr(s string) *uint16 {
	p, _ := windows.UTF16PtrFromString(s)
	return p
}

// odbcCatalog returns the user tables (in catalog order) and their columns
func odbcCatalog(connStr string) ([]string, map[string][]odbcColumn, error) {
	var env, dbc api.SQLHANDLE
	if r := api.SQLAllocHandle(api.SQL_HANDLE_ENV, api.SQLHANDLE(api.SQL_NULL_HANDLE), &env); !odbcOK(r) {
		return nil, nil, fmt.Errorf("SQLAllocHandle(env) failed")
	}
	defer api.SQLFreeHandle(api.SQL_HANDLE_ENV, env)
	api.SQLSetEnvUIntPtrAttr(api.SQLHENV(env), api.SQL_ATTR_ODBC_VERSION, api.SQL_OV_ODBC3, 0)
	if r := api.SQLAllocHandle(api.SQL_HANDLE_DBC, env, &dbc); !odbcOK(r) {
		return nil, nil, odbc.NewError("SQLAllocHandle", api.SQLHENV(env))
	}
	defer api.SQLFreeHandle(api.SQL_HANDLE_DBC, dbc)
	cs := wstr(connStr)
	if r := api.SQLDriverConnect(api.SQLHDBC(dbc), 0, (*api.SQLWCHAR)(unsafe.Pointer(cs)), api.SQL_NTS, nil, 0, nil, api.SQL_DRIVER_NOPROMPT); !odbcOK(r) {
		return nil, nil, odbc.NewError("SQLDriverConnect", api.SQLHDBC(dbc))
	}
	defer api.SQLDisconnect(api.SQLHDBC(dbc))

	tableRows, err := catalogQuery(dbc, procSQLTablesW, []int{3}, nil, nil, wstr("%"), wstr("TABLE"))
	if err != nil {
		return nil, nil, err
	}
	colRows, err := catalogQuery(dbc, procSQLColumnsW, []int{3, 4, 5, 7, 9}, nil, nil, wstr("%"), wstr("%"))
	if err != nil {
		return nil, nil, err
	}
	tables := make([]string, len(tableRows))
	for i, r := range tableRows {
		tables[i] = r[0]
	}
	cols := map[string][]odbcColumn{}
	for _, r := range colRows {
		dt, _ := strconv.Atoi(r[2])
		size, _ := strconv.Atoi(r[3])
		digits, _ := strconv.Atoi(r[4])
		cols[r[0]] = append(cols[r[0]], odbcColumn{name: r[1], dataType: dt, size: size, digits: digits})
	}
	return tables, cols, nil
}

// catalogQuery runs SQLTablesW or SQLColumnsW (4 string arguments, nil = any) and reads the wanted columns as text
func catalogQuery(dbc api.SQLHANDLE, proc *windows.LazyProc, want []int, args ...*uint16) ([][]string, error) {
	var stmt api.SQLHANDLE
	if r := api.SQLAllocHandle(api.SQL_HANDLE_STMT, dbc, &stmt); !odbcOK(r) {
		return nil, odbc.NewError("SQLAllocHandle", api.SQLHDBC(dbc))
	}
	defer api.SQLFreeHandle(api.SQL_HANDLE_STMT, stmt)
	call := []uintptr{uintptr(stmt)}
	for _, a := range args {
		n := uintptr(0)
		if a != nil {
			n = uintptr(uint16(0xFFFD)) // SQL_NTS (-3) as SQLSMALLINT
		}
		call = append(call, uintptr(unsafe.Pointer(a)), n)
	}
	r, _, _ := proc.Call(call...)
	if !odbcOK(api.SQLRETURN(r)) {
		return nil, odbc.NewError(proc.Name, api.SQLHSTMT(stmt))
	}
	var out [][]string
	buf := make([]uint16, 1024)
	for {
		r := api.SQLFetch(api.SQLHSTMT(stmt))
		if r == api.SQL_NO_DATA {
			return out, nil
		}
		if !odbcOK(r) {
			return nil, odbc.NewError("SQLFetch", api.SQLHSTMT(stmt))
		}
		row := make([]string, len(want))
		for i, c := range want {
			var n api.SQLLEN
			r := api.SQLGetData(api.SQLHSTMT(stmt), api.SQLUSMALLINT(c), api.SQL_C_WCHAR,
				api.SQLPOINTER(unsafe.Pointer(&buf[0])), api.SQLLEN(len(buf)*2), &n)
			if !odbcOK(r) {
				return nil, odbc.NewError("SQLGetData", api.SQLHSTMT(stmt))
			}
			if n > 0 {
				row[i] = windows.UTF16ToString(buf[:min(int(n)/2, len(buf))])
			}
		}
		out = append(out, row)
	}
}

// valueKind: the Go value DuckDB's appender gets for a column
type valueKind int

const (
	kindText valueKind = iota
	kindInt
	kindScaled // DECIMAL(p,s): unscaled integer
	kindFloat
	kindBool
	kindTime
	kindBlob
)

// odbcToDuck maps an ODBC SQL type (SQLColumns DATA_TYPE) to a DuckDB type; scale is for kindScaled
func odbcToDuck(c odbcColumn) (string, valueKind) {
	switch c.dataType {
	case -7: // BIT (Yes/No)
		return "BOOLEAN", kindBool
	case -6: // Byte (0..255)
		return "UTINYINT", kindInt
	case 5:
		return "SMALLINT", kindInt
	case 4: // Long Integer, AutoNumber
		return "INTEGER", kindInt
	case -5:
		return "BIGINT", kindInt
	case 7:
		return "REAL", kindFloat
	case 6, 8:
		return "DOUBLE", kindFloat
	case 2, 3: // NUMERIC, DECIMAL, CURRENCY (19,4); the driver hands them over as float64
		// the unscaled value goes as int64: up to 19 digits (Currency is 19,4); wider ones fall back to DOUBLE
		if t := decimalType(c.size, c.digits); t != "DOUBLE" && c.size <= 19 {
			return t, kindScaled
		}
		return "DOUBLE", kindFloat
	case 9, 91:
		return "DATE", kindTime
	case 10, 92:
		return "TIME", kindTime
	case 11, 93:
		return "TIMESTAMP", kindTime
	case -2, -3, -4:
		return "BLOB", kindBlob
	}
	return "VARCHAR", kindText // CHAR, VARCHAR, LONGCHAR (Memo), GUID
}

// convertValue turns a value from the odbc driver into what the appender expects for kind
func convertValue(v any, kind valueKind, scale int) any {
	if v == nil {
		return nil
	}
	switch kind {
	case kindInt, kindScaled:
		var f float64
		switch x := v.(type) {
		case int64:
			f = float64(x)
			if kind == kindInt {
				return x
			}
		case int32:
			f = float64(x)
		case float64:
			f = x
		case bool:
			if x {
				f = 1
			}
		default:
			return nil
		}
		if kind == kindScaled {
			f *= math.Pow10(scale)
		}
		return int64(math.Round(f))
	case kindFloat:
		switch x := v.(type) {
		case float64:
			return x
		case int64:
			return float64(x)
		case int32:
			return float64(x)
		}
	case kindBool:
		if b, ok := v.(bool); ok {
			return b
		}
	case kindTime:
		if t, ok := v.(time.Time); ok {
			// the driver builds times in time.Local; DuckDB TIMESTAMP keeps the wall clock, not the instant
			return time.Date(t.Year(), t.Month(), t.Day(), t.Hour(), t.Minute(), t.Second(), t.Nanosecond(), time.UTC)
		}
	case kindBlob:
		if b, ok := v.([]byte); ok {
			return append([]byte(nil), b...)
		}
	}
	if b, ok := v.([]byte); ok {
		return string(b)
	}
	return cellString(v)
}

func importODBC(ctx context.Context, db *sql.DB, path string, progress Progress) error {
	connStr := odbcConnString(path)
	tables, catalog, err := odbcCatalog(connStr)
	if err != nil {
		return err
	}
	src, err := sql.Open("odbc", connStr)
	if err != nil {
		return err
	}
	defer src.Close()
	conn, err := db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	for i, t := range tables {
		progress(i, len(tables), t)
		if err := importODBCTable(ctx, src, conn, t, catalog[t]); err != nil {
			return fmt.Errorf("table %s: %w", t, err)
		}
	}
	progress(len(tables), len(tables), "")
	return nil
}

func importODBCTable(ctx context.Context, src *sql.DB, conn *sql.Conn, table string, catalog []odbcColumn) error {
	rows, err := src.QueryContext(ctx, "SELECT * FROM ["+table+"]")
	if err != nil {
		return err
	}
	defer rows.Close()
	names, err := rows.Columns()
	if err != nil {
		return err
	}
	byName := map[string]odbcColumn{}
	for _, c := range catalog {
		byName[strings.ToLower(c.name)] = c
	}
	kinds := make([]valueKind, len(names))
	scales := make([]int, len(names))
	defs := make([]string, len(names))
	for i, n := range names {
		c, ok := byName[strings.ToLower(n)]
		typ := "VARCHAR"
		if ok {
			typ, kinds[i] = odbcToDuck(c)
			scales[i] = c.digits
		}
		defs[i] = quoteIdent(n) + " " + typ
	}
	if _, err := conn.ExecContext(ctx, fmt.Sprintf("CREATE TABLE %s (%s)", quoteIdent(table), strings.Join(defs, ", "))); err != nil {
		return err
	}
	return conn.Raw(func(dc any) error {
		app, err := duckdb.NewAppenderFromConn(dc.(driver.Conn), "", table)
		if err != nil {
			return err
		}
		values := make([]any, len(names))
		ptrs := make([]any, len(names))
		for i := range values {
			ptrs[i] = &values[i]
		}
		row := make([]driver.Value, len(names))
		for n := 0; rows.Next(); n++ {
			if n%1000 == 0 && ctx.Err() != nil {
				app.Close()
				return ctx.Err()
			}
			if err := rows.Scan(ptrs...); err != nil {
				app.Close()
				return err
			}
			for i, v := range values {
				row[i] = convertValue(v, kinds[i], scales[i])
			}
			if err := app.AppendRow(row...); err != nil {
				app.Close()
				return err
			}
		}
		if err := rows.Err(); err != nil {
			app.Close()
			return err
		}
		return app.Close()
	})
}
