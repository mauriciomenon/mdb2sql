//go:build windows

// Versao do WebView2 que desenha a janela (Ajuda > Sobre > Janela), como o Rust mostra
// !T: The user agent of WebView2 reports 158.0.0.0 (reduced); the runtime API gives the full version

package main

import "github.com/wailsapp/go-webview2/webviewloader"

func webviewVersion() string {
	v, err := webviewloader.GetAvailableCoreWebView2BrowserVersionString("")
	if err != nil || v == "" {
		return "WebView2"
	}
	return "WebView2 " + v
}
