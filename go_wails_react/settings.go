package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Settings sao gravadas em %APPDATA%\mdb2sql\go-wails-react.json (tema e ultima pasta usada)
// !T: In Go, not in WebView localStorage: the WebView store depends on the exe name (single exe vs installed)
type Settings struct {
	Theme   string `json:"theme"` // system, light or dark
	LastDir string `json:"lastDir"`
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
	s := Settings{Theme: "system"}
	if data, err := os.ReadFile(settingsPath()); err == nil {
		_ = json.Unmarshal(data, &s) // a broken file just falls back to the defaults
	}
	if !themes[s.Theme] {
		s.Theme = "system"
	}
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
