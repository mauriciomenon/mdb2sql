// Entry point Wails - inicializa aplicacao com assets embutidos e bindings
// !T: Main entry point embedding frontend dist via go:embed and exposing Go methods to JS

package main

import (
	"embed"
	"os"
	"path/filepath"

	"mdb2sql/backend"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/windows"
)

// Embute diretorio frontend/dist no binario final
// !T: go:embed directive bundles frontend assets into single executable
//
//go:embed all:frontend/dist
var assets embed.FS

// Barra de titulo curta com a versao de wails.json: "mdb2sql 1.3.0 - Go" (a stack completa fica em Ajuda > Sobre)
func windowTitle() string {
	return "mdb2sql " + productVersion() + " - Go"
}

func main() {
	build := buildNumber
	if build == "" {
		build = "dev"
	}
	// one cache folder per build: %LOCALAPPDATA%\mdb2sql\go-wails-react-<version>-<build>
	backend.CacheTag = "go-wails-react-" + productVersion() + "-" + build

	// Cria instancia da struct App com DB manager
	// !T: NewApp() initializes App struct with DBManager singleton
	app := NewApp()
	applyDisplay(app) // Linux: X11 first, Wayland as fallback with a warning; before GTK starts in wails.Run

	winOpts := &windows.Options{}
	if dir, err := os.UserCacheDir(); err == nil {
		// fixed WebView2 data folder: the default one is named after the exe, so each exe name would get its own
		winOpts.WebviewUserDataPath = filepath.Join(dir, "mdb2sql", "go-wails-react-webview")
	}

	// Configura e inicia aplicacao Wails com opcoes de janela e bindings
	// !T: Wails.Run starts WebView window with IPC bridge to Go methods
	err := wails.Run(&options.App{
		Title:  windowTitle(),
		Width:  1280,
		Height: 800,
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		// opaque: A is 0-255; A 1 left the GTK window almost transparent on Wayland (blank page in WSLg)
		BackgroundColour: &options.RGBA{R: 27, G: 38, B: 54, A: 255},
		OnStartup:        app.startup,
		OnBeforeClose:    app.beforeClose,
		OnShutdown:       app.shutdown,
		Windows:          winOpts,
		Bind: []interface{}{
			app,
		},
	})

	if err != nil {
		println("Error:", err.Error())
	}
}
