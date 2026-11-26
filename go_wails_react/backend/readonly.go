// Aba SQL so de leitura: cada comando e classificado pelo tipo que o DuckDB lhe da (nunca pelo texto) antes de rodar
// !T: Two guards: every statement must be a read by DuckDB's own statement type, and the query then runs inside a READ
// ONLY transaction that is always rolled back, so the open file, its converted copy and the in-memory catalog never
// change (not even through EXPLAIN ANALYZE of a write)

package backend

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"unsafe"

	"github.com/duckdb/duckdb-go/v2"
	"github.com/duckdb/duckdb-go/v2/mapping"

	"mdb2sql/i18n"
)

// readTypes: what the SQL tab runs. DuckDB gives the type SELECT to every query (SELECT, WITH, FROM, VALUES, SHOW,
// DESCRIBE, SUMMARIZE and the PRAGMAs that only read, as table_info); MULTI is PIVOT. Everything else (INSERT, UPDATE,
// DELETE, CREATE, DROP, ALTER, COPY, SET, PRAGMA settings, ATTACH, CALL, transactions...) is refused.
var readTypes = map[duckdb.StmtType]bool{
	duckdb.STATEMENT_TYPE_SELECT:  true,
	duckdb.STATEMENT_TYPE_EXPLAIN: true,
	duckdb.STATEMENT_TYPE_MULTI:   true,
}

// checkReadOnly prepares every statement of query WITHOUT running any and refuses the query (err.sqlReadOnly) when one
// of them is not a read; a query the engine cannot parse or bind returns the engine's error
func checkReadOnly(conn *sql.Conn, query string) error {
	return conn.Raw(func(driverConn any) error {
		// duckdb-go keeps its C connection private and its own Prepare runs every statement of a script but the
		// last: the statements are prepared here, one by one, on that same connection
		f := reflect.ValueOf(driverConn).Elem().FieldByName("conn")
		if !f.IsValid() || f.Type() != reflect.TypeFor[mapping.Connection]() {
			return errors.New("cannot classify the SQL: the duckdb-go connection changed")
		}
		raw := *(*mapping.Connection)(unsafe.Pointer(f.UnsafeAddr()))
		var stmts mapping.ExtractedStatements
		n := mapping.ExtractStatements(raw, query, &stmts)
		defer mapping.DestroyExtracted(&stmts)
		if n == 0 {
			if msg := mapping.ExtractStatementsError(stmts); msg != "" {
				return errors.New(msg)
			}
			return errors.New("empty query")
		}
		for i := mapping.IdxT(0); i < n; i++ {
			var prep mapping.PreparedStatement
			state := mapping.PrepareExtractedStatement(raw, stmts, i, &prep)
			msg, typ := mapping.PrepareError(prep), duckdb.StmtType(mapping.PreparedStatementType(prep))
			mapping.DestroyPrepare(&prep)
			if state == mapping.StateError {
				return errors.New(msg)
			}
			if !readTypes[typ] {
				return errors.New(i18n.T("err.sqlReadOnly"))
			}
		}
		return nil
	})
}

// writingFunction: a table function that attaches a database or writes a file inside a SELECT (review 26/11:
// sqlite_attach('x.sqlite', overwrite=true) replaces views; checkpoint writes the database file)
func writingFunction(name string) bool {
	name = strings.ToLower(name)
	return strings.HasSuffix(name, "_attach") || name == "checkpoint" || name == "force_checkpoint"
}

// hasWritingFunction walks the parse tree of json_serialize_sql (the parser's own tree, never the text) for a
// function_name that writes
func hasWritingFunction(v any) bool {
	switch x := v.(type) {
	case map[string]any:
		if name, ok := x["function_name"].(string); ok && writingFunction(name) {
			return true
		}
		for _, e := range x {
			if hasWritingFunction(e) {
				return true
			}
		}
	case []any:
		for _, e := range x {
			if hasWritingFunction(e) {
				return true
			}
		}
	}
	return false
}

// checkFunctions refuses (err.sqlReadOnly) a SELECT that calls a writing table function. A query the serializer does
// not take (a statement other than SELECT, a syntax error) is left to checkReadOnly, which refuses or explains it.
func checkFunctions(ctx context.Context, conn *sql.Conn, query string) error {
	var tree string
	var v any
	if conn.QueryRowContext(ctx, "SELECT json_serialize_sql(?)", query).Scan(&tree) != nil || json.Unmarshal([]byte(tree), &v) != nil {
		return nil
	}
	if hasWritingFunction(v) {
		return errors.New(i18n.T("err.sqlReadOnly"))
	}
	return nil
}

// readOnlyConn gives the connection that runs a SQL tab query: the query was checked (checkFunctions, checkReadOnly)
// and the connection is inside a READ ONLY transaction; done rolls it back and frees the connection
func (m *DBManager) readOnlyConn(ctx context.Context, query string) (*sql.Conn, func(), error) {
	conn, err := m.conn.Conn(ctx)
	if err != nil {
		return nil, nil, err
	}
	if err = checkFunctions(ctx, conn, query); err == nil {
		err = checkReadOnly(conn, query)
	}
	if err == nil {
		_, err = conn.ExecContext(ctx, "BEGIN TRANSACTION READ ONLY")
	}
	if err != nil {
		conn.Close()
		return nil, nil, err
	}
	return conn, func() {
		conn.ExecContext(context.Background(), "ROLLBACK")
		conn.Close()
	}, nil
}
