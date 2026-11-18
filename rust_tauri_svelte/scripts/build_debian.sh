#!/usr/bin/env bash
# Debian 13 amd64: prepara as ferramentas fixas, compila o mdbtools 1.0.1 estatico, testa, gera o .deb e o .zip em
# dist/debian/amd64/. Chamado por ../build_debian_amd64.sh (num clone no disco do Linux; pelo Windows:
# build_debian_amd64_wsl.ps1). Codigos de saida: 0 ok, 1 falha de build/teste/varredura, 2 maquina/pasta errada
# ou arvore suja, 3 falta ferramenta ou pacote do sistema.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
slug=rust-tauri-svelte

fail() {
    echo "ERRO: $2" >&2
    exit "$1"
}

[ "$(uname -m)" = x86_64 ] || fail 2 "esta maquina e $(uname -m); o comando e para amd64 (sem build cruzado)"
case "$root" in
    /mnt/*) fail 2 "rode num clone no disco do Linux (ex.: ~/src/mdb2sql-rust-tauri-svelte), nao em $root" ;;
esac

# Um shell nao interativo (wsl.exe -e bash -c) nao tem a pasta do rustup no PATH
cargo_home=${CARGO_HOME:-$HOME/.cargo}
rustup_home=${RUSTUP_HOME:-$HOME/.rustup}
[ ! -d "$cargo_home/bin" ] || PATH="$cargo_home/bin:$PATH"
for tool in git curl rustup cargo corepack make gcc zip dpkg-deb; do
    command -v "$tool" >/dev/null || fail 3 "$tool nao encontrado"
done
# pacotes do sistema que o Tauri (WebKitGTK) pede para compilar; o .deb pede so as bibliotecas de execucao
missing=""
for p in build-essential pkg-config libwebkit2gtk-4.1-dev libgtk-3-dev libsoup-3.0-dev librsvg2-dev libxdo-dev libssl-dev; do
    dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"
done
[ -z "$missing" ] || fail 3 "faltam pacotes: sudo apt install$missing"

if [ -n "$(git status --porcelain)" ]; then
    git status --short
    fail 2 "arvore com alteracoes nao commitadas; commite antes do build"
fi

version=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -n1)
source_id=$(git describe --tags --always --long 2>/dev/null || git rev-parse --short HEAD)
MDB2SQL_BUILD_NUMBER=$(git rev-list --count HEAD)
MDB2SQL_BUILD_DATE=$(date -u +%F)
export MDB2SQL_BUILD_NUMBER MDB2SQL_BUILD_DATE
echo "Source: $source_id  versao $version  build $MDB2SQL_BUILD_NUMBER ($MDB2SQL_BUILD_DATE)"

# --- ferramentas fixas em .tools/ (como no Windows) ---------------------------------------------------------
rustup toolchain install # le rust-toolchain.toml (Rust 1.99.1)
tauri_cli_version=2.12.4 # mesma do scripts/setup_tools.ps1
mkdir -p .tools/bin
if ! .tools/bin/cargo-tauri tauri --version 2>/dev/null | grep -q "$tauri_cli_version"; then
    cargo install --root .tools tauri-cli --version "$tauri_cli_version" --locked
fi
# pnpm na versao do packageManager do ui/package.json, pelo corepack do Node (o Tauri chama "pnpm" no build)
pnpm_version=$(sed -n 's/.*"packageManager": "pnpm@\(.*\)".*/\1/p' ui/package.json)
printf '#!/bin/sh\nexec corepack pnpm@%s "$@"\n' "$pnpm_version" >.tools/bin/pnpm
chmod 755 .tools/bin/pnpm
PATH="$root/.tools/bin:$PATH"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
pnpm --dir .. install --frozen-lockfile --filter mdb2sql-ui

# mdbtools 1.0.1 do fonte oficial (sha256 conferido), estatico e sem GLib: os exes so dependem da libc.
# Vai para dentro do binario do app (include_bytes! em src/backend/access.rs), como o do Windows.
mdbtools_dir=.tools/mdbtools-1.0.1-linux-amd64
if [ ! -x "$mdbtools_dir/mdb-export" ]; then
    tarball=mdbtools-1.0.1.tar.gz
    sha=ff9c425a88bc20bf9318a332eec50b17e77896eef65a0e69415ccb4e396d1812
    work=.tools/mdbtools-build
    rm -rf "${work:?}"
    mkdir -p "$work"
    curl -fsSL -o "$work/$tarball" "https://github.com/mdbtools/mdbtools/releases/download/v1.0.1/$tarball"
    echo "$sha  $work/$tarball" | sha256sum -c - >/dev/null || fail 1 "sha256 de $tarball errado"
    tar -xzf "$work/$tarball" -C "$work"
    (
        cd "$work/mdbtools-1.0.1"
        ./configure --disable-shared --enable-static --disable-glib --disable-man \
            CFLAGS="-O2 -ffile-prefix-map=$PWD=mdbtools-1.0.1" >/dev/null
        make -s -C src/libmdb >/dev/null
        make -s -C src/util mdb-tables mdb-schema mdb-export >/dev/null
    ) || fail 1 "compilacao do mdbtools falhou"
    mkdir -p "$mdbtools_dir"
    for exe in mdb-tables mdb-schema mdb-export; do
        install -m 755 "$work/mdbtools-1.0.1/src/util/$exe" "$mdbtools_dir/"
        strip "$mdbtools_dir/$exe"
    done
    install -m 644 "$work/mdbtools-1.0.1/COPYING" "$work/mdbtools-1.0.1/COPYING.LIB" "$mdbtools_dir/"
    echo "mdbtools 1.0.1 ($tarball, sha256 $sha), estatico, sem GLib" >"$mdbtools_dir/VERSION.txt"
    rm -rf "${work:?}"
fi

# --- build e testes --------------------------------------------------------------------------------------------
# caminhos neutros no binario: pasta do usuario e do projeto (Rust e o C/C++ do DuckDB e do SQLite embutidos)
export RUSTFLAGS="--remap-path-prefix=$HOME=~ --remap-path-prefix=$cargo_home=cargo --remap-path-prefix=$rustup_home=rustup --remap-path-prefix=$root=."
export CFLAGS="-ffile-prefix-map=$HOME=~ -ffile-prefix-map=$root=."
export CXXFLAGS="$CFLAGS"
export MDB2SQL_REQUIRE_MDBTOOLS=1
.tools/bin/cargo-tauri tauri build --bundles deb || fail 1 "cargo tauri build falhou"
cargo test --release || fail 1 "cargo test falhou"
pnpm --filter mdb2sql-ui test || fail 1 "teste do frontend falhou"

built=target/release/mdb2sql
deb=$(ls target/release/bundle/deb/*_"${version}"_amd64.deb)

# --- varredura de dados pessoais: binario e conteudo do .deb ----------------------------------------------------
user=$(id -un)
scan() {
    if grep -a -l -r -F -e "$HOME" -e "/$user/" -e "$(hostname)" "$@"; then
        fail 1 "caminho do usuario ou nome da maquina em: $*"
    fi
}
scan "$built"
check=$(mktemp -d)
dpkg-deb -x "$deb" "$check"
scan "$check"
rm -rf "${check:?}"
echo "Varredura: nenhum $HOME, /$user/ ou $(hostname) no binario nem no .deb"

# --- produtos ---------------------------------------------------------------------------------------------------
name="mdb2sql-$version-debian-amd64-$slug"
stage="$root/dist/.stage"
rm -rf "${stage:?}"
mkdir -p "$stage/$name"
cp "$deb" "$stage/$name.deb"
# zip: o binario (interface, DuckDB, SQLite e mdbtools dentro), README e LICENSE; precisa do WebKitGTK instalado
install -m 755 "$built" "$stage/$name/mdb2sql"
install -m 644 README.md LICENSE "$stage/$name/"
(cd "$stage" && zip -q -r -X "$name.zip" "$name")
rm -rf "${stage:?}/$name"
(cd "$stage" && sha256sum -- "$name".* >SHA256SUMS.txt)
out="$root/dist/debian/amd64"
rm -rf "${out:?}"
mkdir -p "$(dirname "$out")"
mv "$stage" "$out"
dpkg-deb -f "$out/$name.deb" Package Version Depends
cat "$out/SHA256SUMS.txt"
echo "Source: $source_id"
