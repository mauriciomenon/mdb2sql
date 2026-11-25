//go:build !windows

// Linux: a janela e desenhada pelo WebKitGTK (Ajuda > Sobre > Janela)

package main

func webviewVersion() string { return "WebKitGTK" }
