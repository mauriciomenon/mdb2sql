package i18n

import (
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"testing"
)

func keys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// the three catalogs have the same keys, no empty text, and the same {n} placeholders per key
func TestCatalogsMatch(t *testing.T) {
	en := Catalog("en")
	place := regexp.MustCompile(`\{\d\}`)
	for _, l := range Langs[1:] {
		c := Catalog(l)
		if !reflect.DeepEqual(keys(c), keys(en)) {
			t.Errorf("%s keys differ from en", l)
		}
		for k, v := range c {
			if strings.TrimSpace(v) == "" {
				t.Errorf("%s %s is empty", l, k)
			}
			a, b := place.FindAllString(en[k], -1), place.FindAllString(v, -1)
			sort.Strings(a)
			sort.Strings(b)
			if !reflect.DeepEqual(a, b) {
				t.Errorf("%s %s placeholders %v, en %v", l, k, b, a)
			}
		}
	}
}

// every key the Go code passes to T (or keeps in a table for it) exists
func TestGoKeysExist(t *testing.T) {
	re := regexp.MustCompile(`"((?:err|log|dlg|filter|display)\.[A-Za-z]+)"`)
	files, _ := filepath.Glob("../*.go")
	more, _ := filepath.Glob("../backend/*.go")
	n := 0
	for _, f := range append(files, more...) {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		data, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range re.FindAllStringSubmatch(string(data), -1) {
			n++
			if _, ok := Catalog("en")[m[1]]; !ok {
				t.Errorf("%s: key %q not in the catalogs", f, m[1])
			}
		}
	}
	if n < 20 {
		t.Errorf("only %d keys found in the Go code", n)
	}
}

func TestT(t *testing.T) {
	defer SetLang(Lang())
	SetLang("pt-BR")
	if got := T("err.unsupported", ".txt"); got != "Formato de banco não suportado: .txt" {
		t.Errorf("pt-BR: %q", got)
	}
	// a count: "1 arquivo", "2 arquivos" (standard item 23)
	if got := N("log.staleRemoved", 1, 1); got != "1 arquivo convertido de uma sessão anterior removido" {
		t.Errorf("one: %q", got)
	}
	if got := N("log.staleRemoved", 2, 2); got != "2 arquivos convertidos de uma sessão anterior removidos" {
		t.Errorf("two: %q", got)
	}
	if got := N("err.unsupported", 1, ".txt"); got != "Formato de banco não suportado: .txt" { // no .one: the key
		t.Errorf("no .one: %q", got)
	}
	SetLang("xx") // ignored
	if Lang() != "pt-BR" || T("no.such.key") != "no.such.key" {
		t.Errorf("lang %q", Lang())
	}
}
