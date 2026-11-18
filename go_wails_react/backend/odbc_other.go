//go:build !windows

// Fora do Windows nao ha ODBC do Access: so mdbtools (embutido no build Linux ou do PATH)

package backend

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

func odbcInstalled() bool { return false }

// prepareTool: the embedded Linux mdbtools load libmdb.so.3 from their own folder
func prepareTool(cmd *exec.Cmd) {
	cmd.Env = append(os.Environ(), "LD_LIBRARY_PATH="+filepath.Dir(cmd.Path))
}

// processAlive: signal 0 only checks; EPERM means the process exists but belongs to another user
func processAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

func importODBC(context.Context, *sql.DB, string, Progress) error {
	return errors.New("the Access ODBC driver exists only on Windows")
}
