# Ambiente comum de build e teste (dot-source: . scripts\env_w11.ps1). Vai para a raiz do subprojeto.
# Build e teste usam as mesmas flags para o cargo reaproveitar o DuckDB ja compilado.
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot
Set-Location $Root

# troca a pasta do usuario (registry do cargo) e a pasta do projeto por caminhos neutros nas mensagens do binario
$env:RUSTFLAGS = "--remap-path-prefix=$HOME=~ --remap-path-prefix=$Root=."
# o duckdb bundled e C++ compilado pelo MSVC (crate cc le CFLAGS/CXXFLAGS); /d1trimfile tira o prefixo do __FILE__
$env:CFLAGS = "/d1trimfile:$Root\"
$env:CXXFLAGS = "/d1trimfile:$Root\"
