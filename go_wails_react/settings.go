package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"mdb2sql/i18n"
)

// Settings sao gravadas em %APPDATA%\mdb2sql\go-wails-react.json (tema, idioma e ultima pasta usada)
// !T: In Go, not in WebView localStorage: the WebView store depends on the exe name (single exe vs installed)
type Settings struct {
	Theme    string `json:"theme"`    // system, light or dark
	Language string `json:"language"` // en (default), pt-BR or es
	LastDir  string `json:"lastDir"`
	LogOpen  bool   `json:"logOpen"`  // Log panel expanded (default: collapsed)
	ShowNull bool   `json:"showNull"` // a NULL cell shows "NULL"; off (default) it stays empty
	// Data tab search when the app starts: "all" (all tables, default, standard 18a) or "table" (the open table). A new
	// key: older versions wrote "searchScope": "table" for everyone, chosen or not, so that one is no longer read
	SearchScope string `json:"dataScope"`
	// Terms tab comparison when the app starts: "whole" (the whole cell equals the term, default) or "contains"
	TermMatch string `json:"termMatch"`
	// SQLite or DuckDB saved from each Access file (lowercase path), so the same unchanged file opens it without converting
	Converted map[string]SavedConversion `json:"converted,omitempty"`
	// folders created beside Access files to hold their converted SQLite (no temporary folder could): the startup
	// looks there for what a crash left
	TempDirs []string `json:"tempDirs,omitempty"`
}

// SavedConversion: the Access file's version when converted (fileKey: path, size, date), the file saved from it and
// that file's own version when saved; a change in either converts again
type SavedConversion struct {
	Key     string `json:"key"`
	Dest    string `json:"dest"`
	DestKey string `json:"destKey"`
}

var searchScopes = map[string]bool{"table": true, "all": true}

// GetSearchScope / SetSearchScope: Settings > Default search scope
func (a *App) GetSearchScope() string { return a.settings.SearchScope }

func (a *App) SetSearchScope(scope string) error {
	if !searchScopes[scope] {
		return fmt.Errorf("unknown search scope %q", scope)
	}
	a.settings.SearchScope = scope
	return a.saveSettings()
}

var termMatches = map[string]bool{"whole": true, "contains": true}

// GetTermMatch / SetTermMatch: Settings > Term matching
func (a *App) GetTermMatch() string { return a.settings.TermMatch }

func (a *App) SetTermMatch(match string) error {
	if !termMatches[match] {
		return fmt.Errorf("unknown term matching %q", match)
	}
	a.settings.TermMatch = match
	return a.saveSettings()
}

// GetShowNull / SetShowNull: Settings > Show NULL
func (a *App) GetShowNull() bool { return a.settings.ShowNull }

func (a *App) SetShowNull(show bool) error {
	a.settings.ShowNull = show
	return a.saveSettings()
}

// GetLogOpen / SetLogOpen: the Log panel state, remembered between sessions
func (a *App) GetLogOpen() bool { return a.settings.LogOpen }

func (a *App) SetLogOpen(open bool) error {
	a.settings.LogOpen = open
	return a.saveSettings()
}

var themes = map[string]bool{"system": true, "light": true, "dark": true}

func settingsPath() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "mdb2sql", "go-wails-react.json")
}

func loadSettings() Settings {
	s := Settings{Theme: "system", Language: i18n.Langs[0]}
	if data, err := os.ReadFile(settingsPath()); err == nil {
		_ = json.Unmarshal(data, &s) // a broken file just falls back to the defaults
	}
	if !themes[s.Theme] {
		s.Theme = "system"
	}
	if !searchScopes[s.SearchScope] {
		s.SearchScope = "all"
	}
	if !termMatches[s.TermMatch] {
		s.TermMatch = "whole"
	}
	if !i18n.Valid(s.Language) {
		s.Language = i18n.Langs[0]
	}
	i18n.SetLang(s.Language)
	return s
}

func (a *App) saveSettings() error {
	path := settingsPath()
	if path == "" {
		return fmt.Errorf("no user config folder")
	}
	data, _ := json.MarshalIndent(a.settings, "", "  ")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// GetTheme devolve o tema gravado (system, light, dark)
func (a *App) GetTheme() string { return a.settings.Theme }

// SetTheme grava o tema escolhido em Settings > Theme
func (a *App) SetTheme(theme string) error {
	if !themes[theme] {
		return fmt.Errorf("unknown theme %q", theme)
	}
	a.settings.Theme = theme
	return a.saveSettings()
}

// GetLanguage devolve o idioma gravado (en, pt-BR, es)
func (a *App) GetLanguage() string { return a.settings.Language }

// SetLanguage grava o idioma (Settings > Language) e passa a usa-lo nas mensagens e dialogos do Go
func (a *App) SetLanguage(lang string) error {
	if !i18n.Valid(lang) {
		return fmt.Errorf("unknown language %q", lang)
	}
	a.settings.Language = lang
	i18n.SetLang(lang)
	return a.saveSettings()
}
