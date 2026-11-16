// Ferramentas embutidas no exe (mdbtools e extensao sqlite do DuckDB), extraidas sob demanda para um cache por versao
// !T: One exe, no installer needed: embedded/ is filled by scripts/build_w11.ps1; in git it only holds .gitkeep

package backend

import (
	"compress/gzip"
	"embed"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

//go:embed all:embedded
var embedded embed.FS

// CacheTag is this build's folder under %LOCALAPPDATA%\mdb2sql; main sets it from version and build number
var CacheTag = cachePrefix + "dev"

// only folders with this prefix are ours: the other mdb2sql stacks share %LOCALAPPDATA%\mdb2sql
const cachePrefix = "go-wails-react-"

const sqliteExtensionAsset = "sqlite_scanner.duckdb_extension.gz"

var cacheMu sync.Mutex

func hasAsset(name string) bool {
	_, err := fs.Stat(embedded, "embedded/"+name)
	return err == nil
}

// assetPath extracts an embedded file on first use (".gz" assets are stored unpacked) and returns its path
func assetPath(name string) (string, error) {
	cacheMu.Lock()
	defer cacheMu.Unlock()
	base, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	root := filepath.Join(base, "mdb2sql")
	dir := filepath.Join(root, CacheTag)
	dest := filepath.Join(dir, strings.TrimSuffix(name, ".gz"))
	if _, err := os.Stat(dest); err == nil {
		return dest, nil // written by rename below, so it is complete
	}
	src, err := embedded.Open("embedded/" + name)
	if err != nil {
		return "", fmt.Errorf("%s is not embedded in this build", name)
	}
	defer src.Close()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	removeOldCaches(root)

	var r io.Reader = src
	if strings.HasSuffix(name, ".gz") {
		gz, err := gzip.NewReader(src)
		if err != nil {
			return "", fmt.Errorf("extract %s: %w", name, err)
		}
		defer gz.Close()
		r = gz
	}
	tmp := dest + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return "", err
	}
	_, err = io.Copy(f, r)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, dest)
	}
	if err != nil {
		os.Remove(tmp)
		return "", fmt.Errorf("extract %s: %w", name, err)
	}
	return dest, nil
}

// removeOldCaches deletes the folders of other builds of this stack (errors ignored: an old instance may still run)
func removeOldCaches(root string) {
	entries, _ := os.ReadDir(root)
	for _, e := range entries {
		if e.IsDir() && strings.HasPrefix(e.Name(), cachePrefix) && e.Name() != CacheTag {
			_ = os.RemoveAll(filepath.Join(root, e.Name()))
		}
	}
}

var mdbtoolsNames = []string{"mdb-tables", "mdb-schema", "mdb-export"}

// mdbtool returns the embedded mdbtools program (Windows build) or the one on PATH (other systems)
func mdbtool(name string) (string, error) {
	if hasAsset(name + ".exe") {
		for _, lic := range []string{"COPYING", "COPYING.LIB", "VERSION.txt"} {
			if hasAsset(lic) {
				_, _ = assetPath(lic) // the GPL texts travel with the programs
			}
		}
		return assetPath(name + ".exe")
	}
	return exec.LookPath(name)
}

func mdbtoolsAvailable() bool {
	for _, n := range mdbtoolsNames {
		if !hasAsset(n+".exe") && !onPath(n) {
			return false
		}
	}
	return true
}

func onPath(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

func sqliteExtension() (string, error) {
	if !hasAsset(sqliteExtensionAsset) {
		return "", fmt.Errorf("this build has no embedded DuckDB sqlite extension (run scripts\\setup_tools.ps1 and build again)")
	}
	return assetPath(sqliteExtensionAsset)
}
