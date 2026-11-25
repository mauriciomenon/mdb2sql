// Catalogos de texto (en, pt-BR, es): um JSON por idioma, mesmas chaves, lidos pelo Go e pelo React
// !T: Single source for every user-visible text; the frontend imports the same JSON files

package i18n

import (
	"embed"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
)

//go:embed *.json
var files embed.FS

// Langs in menu order; the first one is the default
var Langs = []string{"en", "pt-BR", "es"}

var (
	catalogs = load()
	mu       sync.RWMutex
	current  = Langs[0]
)

func load() map[string]map[string]string {
	out := map[string]map[string]string{}
	for _, l := range Langs {
		data, err := files.ReadFile(l + ".json")
		if err != nil {
			panic(err) // embedded at build time: a missing file is a build bug
		}
		m := map[string]string{}
		if err := json.Unmarshal(data, &m); err != nil {
			panic(fmt.Sprintf("%s.json: %v", l, err))
		}
		out[l] = m
	}
	return out
}

// Catalog returns the texts of one language (nil if unknown)
func Catalog(lang string) map[string]string { return catalogs[lang] }

// Valid tells whether lang has a catalog
func Valid(lang string) bool { return catalogs[lang] != nil }

// SetLang changes the language of T; an unknown one is ignored
func SetLang(lang string) {
	if Valid(lang) {
		mu.Lock()
		current = lang
		mu.Unlock()
	}
}

// Lang is the current language
func Lang() string {
	mu.RLock()
	defer mu.RUnlock()
	return current
}

// T returns the text of key in the current language with {0}, {1}... replaced by args (English, then the key, as fallback)
func T(key string, args ...any) string {
	s, ok := catalogs[Lang()][key]
	if !ok {
		if s, ok = catalogs[Langs[0]][key]; !ok {
			s = key
		}
	}
	for i, a := range args {
		s = strings.ReplaceAll(s, fmt.Sprintf("{%d}", i), fmt.Sprint(a))
	}
	return s
}

// N is T for a text with a count: key.one when n is 1 and the catalogs have it ("1 arquivo"), else key ("2 arquivos")
func N(key string, n int, args ...any) string {
	if _, ok := catalogs[Langs[0]][key+".one"]; ok && n == 1 {
		key += ".one"
	}
	return T(key, args...)
}
