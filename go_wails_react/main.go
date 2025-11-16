// NIVEL BASICO: Entry point da aplicacao Go
// Este arquivo inicia o app Wails que cria janela desktop com React frontend

package main

import (
	"embed"
	"fmt"
	"log"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
)

//go:embed all:frontend/dist
var assets embed.FS

// NIVEL BASICO: App struct contem estado da aplicacao
// Metodos desta struct ficam disponiveis no frontend automaticamente
type App struct {
	// NIVEL TECNICO: context seria adicionado aqui se necessario
}

// NIVEL BASICO: NewApp cria instancia do App (construtor)
func NewApp() *App {
	return &App{}
}

// NIVEL BASICO: Greet e um metodo que pode ser chamado do React
// Frontend usa: import { Greet } from '../wailsjs/go/main/App'
func (a *App) Greet(name string) string {
	return fmt.Sprintf("Hello %s! Welcome to MDB2SQL", name)
}

// NIVEL TECNICO: Startup hook, chamado quando app inicializa
// func (a *App) startup(ctx context.Context) {
//     a.ctx = ctx
// }

func main() {
	// NIVEL BASICO: Cria instancia do App
	app := NewApp()

	// NIVEL BASICO: Configura e inicia aplicacao Wails
	err := wails.Run(&options.App{
		Title:  "MDB2SQL",
		Width:  1200,
		Height: 800,
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		OnStartup: func() {
			// NIVEL TECNICO: Initialization logic here
		},
		Bind: []interface{}{
			app, // NIVEL BASICO: Registra App para frontend acessar
		},
	})

	if err != nil {
		log.Fatal(err)
	}
}
