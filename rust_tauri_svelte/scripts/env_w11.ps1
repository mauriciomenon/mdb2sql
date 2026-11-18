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

# numero e data do build no dialogo Sobre (build.rs); o mesmo valor no build e no teste evita recompilar
$env:MDB2SQL_BUILD_NUMBER = (git rev-list --count HEAD)
$env:MDB2SQL_BUILD_DATE = Get-Date -Format 'yyyy-MM-dd'

# o build oficial sempre leva o mdbtools dentro do exe: sem .tools\mdbtools-1.0.1-w11-amd64\ o build.rs para
$env:MDB2SQL_REQUIRE_MDBTOOLS = '1'
