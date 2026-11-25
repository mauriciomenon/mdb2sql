// Ferramentas embutidas no exe (mdbtools e extensao sqlite do DuckDB), extraidas sob demanda para um cache por versao
// !T: One exe, no installer needed: embedded/ is filled by scripts/build_w11.ps1 (Windows) or scripts/build_debian.sh
// (Linux); in git it only holds .gitkeep

package backend

import (
	"compress/gzip"
	"embed"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"

	"mdb2sql/i18n"
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
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755) // executable: the Linux mdbtools
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

// exeSuffix of the embedded programs: Windows build mdb-export.exe, Linux build mdb-export
var exeSuffix = map[bool]string{true: ".exe", false: ""}[runtime.GOOS == "windows"]

// mdbtool returns the embedded mdbtools program (Windows and Linux release builds) or the one on PATH
func mdbtool(name string) (string, error) {
	if hasAsset(name + exeSuffix) {
		// the license texts travel with the programs; the Linux programs load libmdb.so.3 from the same folder
		for _, f := range []string{"COPYING", "COPYING.LIB", "VERSION.txt", "copyright", "libmdb.so.3"} {
			if hasAsset(f) {
				if _, err := assetPath(f); err != nil {
					return "", err
				}
			}
		}
		return assetPath(name + exeSuffix)
	}
	return exec.LookPath(name)
}

// MdbtoolsLabel names the mdbtools the app would use, for Help > About: "mdbtools 1.0.1" (version from the embedded
// VERSION.txt, "mdbtools 1.0.1 (8eedb1b) - Windows amd64...") or "mdbtools"; system = found on PATH, not embedded;
// "" = no mdbtools at all
func MdbtoolsLabel() (label string, system bool) {
	if hasAsset("mdb-tables" + exeSuffix) {
		data, _ := fs.ReadFile(embedded, "embedded/VERSION.txt")
		return mdbtoolsVersionLabel(string(data)), false
	}
	if mdbtoolsAvailable() {
		return "mdbtools", true
	}
	return "", false
}

func mdbtoolsVersionLabel(versionTxt string) string {
	if f := strings.Fields(versionTxt); len(f) > 1 && f[0] == "mdbtools" {
		return "mdbtools " + f[1]
	}
	return "mdbtools"
}

func mdbtoolsAvailable() bool {
	for _, n := range mdbtoolsNames {
		if !hasAsset(n+exeSuffix) && !onPath(n) {
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
		return "", errors.New(i18n.T("err.noSqliteExtension"))
	}
	return assetPath(sqliteExtensionAsset)
}
