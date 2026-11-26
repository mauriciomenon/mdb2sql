// Aba SQL so de leitura: cada comando e classificado pelo tipo que o DuckDB lhe da (nunca pelo texto) antes de rodar
// !T: Two guards: every statement must be a read by DuckDB's own statement type, and the query then runs inside a READ
// ONLY transaction that is always rolled back, so the open file, its converted copy and the in-memory catalog never
// change (not even through EXPLAIN ANALYZE of a write)

package backend

import (
	"context"
	"database/sql"
	"errors"
	"reflect"
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

// readOnlyConn gives the connection that runs a SQL tab query: the query was checked (checkReadOnly) and the
// connection is inside a READ ONLY transaction; done rolls it back and frees the connection
func (m *DBManager) readOnlyConn(ctx context.Context, query string) (*sql.Conn, func(), error) {
	conn, err := m.conn.Conn(ctx)
	if err != nil {
		return nil, nil, err
	}
	if err = checkReadOnly(conn, query); err == nil {
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
