// SQLite convertido de um Access: fica numa pasta temporaria por processo ate o usuario salvar (Arquivo > Salvar) ou sair
// !T: <temp>/mdb2sql-go-wails-react/<pid>/<random>/<source name>.sqlite, where <temp> is the user's temporary folder,
// else the system's, else the folder of the Access file (the first where a file can be created); folders of dead
// processes are removed at the next start (CleanStaleConverted), so a crash never leaves an orphan for good

package backend

import (
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

const convertedDir = "mdb2sql-go-wails-react"

// OnSourceFolderTemp is called with the folder created beside an Access file when no temporary folder could hold its
// converted SQLite: the app keeps it in the settings, so the next start also looks there for leftovers
var OnSourceFolderTemp = func(root string) {}

// ConvertedRoots are the folders that may hold converted files, best first: the user's temporary folder, the system's
// and, with source (an Access file), a folder beside it
func ConvertedRoots(source string) []string {
	system := "/tmp"
	if runtime.GOOS == "windows" {
		system = filepath.Join(os.Getenv("SystemRoot"), "Temp")
	}
	roots := []string{filepath.Join(os.TempDir(), convertedDir), filepath.Join(system, convertedDir)}
	if source != "" {
		roots = append(roots, filepath.Join(filepath.Dir(source), convertedDir))
	}
	return roots
}

// LegacyConvertedRoot is where 1.3.0 kept the converted files (%LOCALAPPDATA%\mdb2sql\converted-go-wails-react):
// only cleaned now, so a crash of that version leaves nothing behind
func LegacyConvertedRoot() string {
	base, err := os.UserCacheDir()
	if err != nil {
		return ""
	}
	return filepath.Join(base, "mdb2sql", "converted-go-wails-react")
}

func newConvertedPath(source string) (string, error) {
	roots := ConvertedRoots(source)
	path, err := newConvertedIn(roots, source)
	if err == nil && strings.HasPrefix(path, roots[len(roots)-1]+string(filepath.Separator)) && roots[0] != roots[len(roots)-1] {
		OnSourceFolderTemp(roots[len(roots)-1])
	}
	return path, err
}

// newConvertedIn returns a fresh path <root>/<pid>/<random>/<source stem>.sqlite under the first root where a file
// can be created (folders created, file not)
func newConvertedIn(roots []string, source string) (string, error) {
	var err error
	for _, root := range roots {
		mine := filepath.Join(root, strconv.Itoa(os.Getpid()))
		if err = os.MkdirAll(mine, 0o755); err != nil {
			continue
		}
		var dir string
		if dir, err = os.MkdirTemp(mine, ""); err == nil {
			path := filepath.Join(dir, ConvertedName(source))
			var probe *os.File
			if probe, err = os.Create(path); err == nil {
				probe.Close()
				os.Remove(path)
				return path, nil
			}
		}
		removeEmpty(dir, mine, root)
	}
	return "", err
}

// removeEmpty removes the folders that are empty (Remove refuses a folder with something inside), inner first
func removeEmpty(dirs ...string) {
	for _, d := range dirs {
		if d != "" {
			os.Remove(d)
		}
	}
}

// ConvertedName is the default name of the converted file: "<source without extension>.sqlite"
func ConvertedName(source string) string {
	base := filepath.Base(source)
	return strings.TrimSuffix(base, filepath.Ext(base)) + ".sqlite"
}

// RemoveConverted deletes a converted file with its folder (and any -journal file the engine left); the process
// folder and its root go too once empty, so nothing stays beside an Access file
func RemoveConverted(path string) error {
	if path == "" {
		return nil
	}
	dir := filepath.Dir(path)
	err := os.RemoveAll(dir)
	removeEmpty(filepath.Dir(dir), filepath.Dir(filepath.Dir(dir)))
	return err
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

// CleanStaleConverted removes from roots the converted files left by mdb2sql processes that no longer run (a crash or
// a kill); returns how many process folders it removed
func CleanStaleConverted(roots ...string) int {
	n := 0
	for _, root := range roots {
		entries, _ := os.ReadDir(root)
		for _, e := range entries {
			pid, err := strconv.Atoi(e.Name())
			if err != nil || pid == os.Getpid() || processAlive(pid) {
				continue
			}
			if os.RemoveAll(filepath.Join(root, e.Name())) == nil {
				n++
			}
		}
		removeEmpty(root)
	}
	return n
}
