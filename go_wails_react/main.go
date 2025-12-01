// Entry point Wails - inicializa aplicacao com assets embutidos e bindings
// !T: Main entry point embedding frontend dist via go:embed and exposing Go methods to JS

package main

import (
	"embed"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
)

// Embute diretorio frontend/dist no binario final
// !T: go:embed directive bundles frontend assets into single executable
//go:embed all:frontend/dist
var assets embed.FS

func main() {
	// Cria instancia da struct App com DB manager
	// !T: NewApp() initializes App struct with DBManager singleton
	app := NewApp()

	// Configura e inicia aplicacao Wails com opcoes de janela e bindings
	// !T: Wails.Run starts WebView window with IPC bridge to Go methods
	err := wails.Run(&options.App{
		Title:  "mdb2sql",
		Width:  1024,
		Height: 768,
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		BackgroundColour: &options.RGBA{R: 27, G: 38, B: 54, A: 1},
		OnStartup:        app.startup,
		Bind: []interface{}{
			app,
		},
	})

	if err != nil {
		println("Error:", err.Error())
	}
}
