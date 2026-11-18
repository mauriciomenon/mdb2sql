// SQLite convertido de um Access: fica numa pasta temporaria por processo ate o usuario salvar ou apagar
// !T: <cache>/mdb2sql/converted-go-wails-react/<pid>/<random>/<source name>.sqlite; folders of dead processes are
// removed at the next start (CleanStaleConverted), so a crash never leaves an orphan for good

package backend

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// not under cachePrefix: removeOldCaches would delete it
const convertedDir = "converted-go-wails-react"

func convertedRoot() (string, error) {
	base, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "mdb2sql", convertedDir), nil
}

// newConvertedPath returns a fresh path <root>/<pid>/<random>/<source stem>.sqlite (folders created, file not)
func newConvertedPath(source string) (string, error) {
	root, err := convertedRoot()
	if err != nil {
		return "", err
	}
	mine := filepath.Join(root, strconv.Itoa(os.Getpid()))
	if err := os.MkdirAll(mine, 0o755); err != nil {
		return "", err
	}
	dir, err := os.MkdirTemp(mine, "")
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, ConvertedName(source)), nil
}

// ConvertedName is the default name of the converted file: "<source without extension>.sqlite"
func ConvertedName(source string) string {
	base := filepath.Base(source)
	return strings.TrimSuffix(base, filepath.Ext(base)) + ".sqlite"
}

// RemoveConverted deletes a converted file with its folder (and any -journal file the engine left)
func RemoveConverted(path string) error {
	if path == "" {
		return nil
	}
	return os.RemoveAll(filepath.Dir(path))
}

// SaveConverted moves the converted file to dest (copy + delete across disks), then removes its folder
func SaveConverted(path, dest string) error {
	if err := os.Rename(path, dest); err != nil {
		if err := copyFile(path, dest); err != nil {
			os.Remove(dest)
			return err
		}
	}
	return RemoveConverted(path)
}

func copyFile(src, dest string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dest)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// UniquePath returns dir/name, or dir/"stem (2).ext", "stem (3).ext"... if it exists (never overwrites)
func UniquePath(dir, name string) string {
	ext := filepath.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	p := filepath.Join(dir, name)
	for n := 2; ; n++ {
		if _, err := os.Lstat(p); os.IsNotExist(err) {
			return p
		}
		p = filepath.Join(dir, fmt.Sprintf("%s (%d)%s", stem, n, ext))
	}
}

// CleanStaleConverted removes the converted files left by mdb2sql processes that no longer run (a crash or a kill);
// returns how many folders it removed
func CleanStaleConverted() int {
	root, err := convertedRoot()
	if err != nil {
		return 0
	}
	entries, _ := os.ReadDir(root)
	n := 0
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil || pid == os.Getpid() || processAlive(pid) {
			continue
		}
		if os.RemoveAll(filepath.Join(root, e.Name())) == nil {
			n++
		}
	}
	return n
}
