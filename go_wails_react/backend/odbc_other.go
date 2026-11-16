//go:build !windows

// Fora do Windows nao ha ODBC do Access: so mdbtools (do PATH)

package backend

import (
	"context"
	"database/sql"
	"errors"
	"os/exec"
)

func odbcInstalled() bool { return false }

func hideWindow(*exec.Cmd) {}

func importODBC(context.Context, *sql.DB, string, Progress) error {
	return errors.New("the Access ODBC driver exists only on Windows")
}
