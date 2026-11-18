#!/usr/bin/env bash
# Debian 13 amd64: tools, build, tests and products in dist/debian/amd64/ (.deb and .zip), mdbtools inside the binary.
# Called by ../build_debian_amd64.sh; from Windows: ../build_debian_amd64_wsl.ps1 (clone on the Linux disk of WSL).
# Exit codes: 0 ok, 1 build/test/scan failure, 2 wrong machine/folder or dirty tree, 3 missing tool or package.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
slug=mdb2sql-go-wails-react

fail() {
    echo "ERRO: $2" >&2
    exit "$1"
}

[ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] || fail 2 "este comando gera o pacote Debian amd64 e so roda em Linux x86_64"
case "$root" in
    /mnt/*) fail 2 "rode num clone no disco do Linux (ex.: ~/src/mdb2sql-go_wails_react), nao em $root" ;;
esac

# System packages (need root once): sudo apt install build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev
# dpkg-dev zip curl nodejs. Everything else is downloaded to .tools/linux/ with a fixed version and sha256.
missing=""
for p in build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev dpkg-dev zip curl nodejs; do
    dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"
done
[ -z "$missing" ] || fail 3 "faltam pacotes: sudo apt install$missing"
command -v corepack >/dev/null || fail 3 "corepack nao encontrado (vem com o Node.js 20+; Debian: sudo apt install nodejs)"

if [ -n "$(git status --porcelain)" ]; then
    git status --short
    fail 2 "arvore com alteracoes nao commitadas; commite antes do build"
fi

# Fixed versions (the same as scripts/setup_tools.ps1 where both exist). To update: change version and sha256 together.
go_version=1.26.10
go_sha256=ccfe7ae822d2c2f41f4fe7c956199967a4dac22d0ee0d2b2bfdb440aab3b20c5 # https://go.dev/dl/?mode=json&include=all
wails_version=v2.13.0
# mdbtools 1.0.1 of Debian 13 (trixie), sha256 of the .deb files in deb.debian.org (2026-11-17)
mdb_pool=https://deb.debian.org/debian/pool/main/m/mdbtools
mdb_debs="mdbtools_1.0.1-0.1_amd64.deb:77b2d317b9429f22de27e903586228836c013c81c8b6ed3a990ea8bf94b3bc52
libmdb3t64_1.0.1-0.1_amd64.deb:705eaf16f423be3eebb4c794fca817130dbcabbafd10c408f4fdb5f3e1c1d172"
# DuckDB sqlite extension for the DuckDB linked by duckdb-go (v2.0.0), Linux build; signed by DuckDB (2026-10-20)
ext_url=https://extensions.duckdb.org/v2.0.0/linux_amd64/sqlite_scanner.duckdb_extension.gz
ext_sha256=59b8a0ba6d7599d4aa584bd24e8b4cc3247076bb174157f43e110e56e6c72e86

tools=$root/.tools/linux
mkdir -p "$tools/downloads"
get() { # url sha256 file
    [ -f "$3" ] && [ "$(sha256sum "$3" | cut -d' ' -f1)" = "$2" ] && return 0
    curl -fsSL --retry 3 -o "$3" "$1" || fail 3 "download falhou: $1"
    [ "$(sha256sum "$3" | cut -d' ' -f1)" = "$2" ] || { rm -f "$3"; fail 3 "sha256 nao confere: $1"; }
}

if [ ! -x "$tools/go/bin/go" ] || [ "$("$tools/go/bin/go" env GOVERSION)" != "go$go_version" ]; then
    echo "baixando Go $go_version ..."
    get "https://go.dev/dl/go$go_version.linux-amd64.tar.gz" "$go_sha256" "$tools/downloads/go.tar.gz"
    rm -rf "${tools:?}/go"
    tar -C "$tools" -xzf "$tools/downloads/go.tar.gz"
fi
export PATH="$tools/go/bin:$tools/bin:$PATH" GOTOOLCHAIN=local GOFLAGS=-trimpath CGO_ENABLED=1
unset GOROOT
if [ ! -x "$tools/bin/wails" ] || [ ! -f "$tools/bin/.wails-$wails_version-go$go_version" ]; then
    echo "compilando Wails CLI $wails_version ..."
    GOBIN="$tools/bin" go install "github.com/wailsapp/wails/v2/cmd/wails@$wails_version"
    touch "$tools/bin/.wails-$wails_version-go$go_version"
fi
# pnpm in the version of frontend/package.json (packageManager), run by corepack; wails calls "pnpm"
printf '#!/bin/sh\nexec corepack pnpm "$@"\n' >"$tools/bin/pnpm"
chmod 755 "$tools/bin/pnpm"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

# what goes inside the binary (go:embed backend/embedded): mdbtools of Debian with libmdb.so.3, and the sqlite extension
./clean.sh # a stale frontend/dist would be embedded instead of the new UI
mdb_dir=$tools/mdbtools
rm -rf "${mdb_dir:?}"
mkdir -p "$mdb_dir"
echo "$mdb_debs" | while IFS=: read -r deb sum; do
    get "$mdb_pool/$deb" "$sum" "$tools/downloads/$deb"
    dpkg-deb -x "$tools/downloads/$deb" "$mdb_dir"
done
emb=backend/embedded
for p in mdb-tables mdb-schema mdb-export; do install -m 755 "$mdb_dir/usr/bin/$p" "$emb/$p"; done
install -m 644 "$mdb_dir/usr/lib/x86_64-linux-gnu/libmdb.so.3" "$emb/libmdb.so.3"
install -m 644 "$mdb_dir/usr/share/doc/mdbtools/copyright" "$emb/copyright"
echo "mdbtools 1.0.1-0.1 (Debian 13, deb.debian.org)" >"$emb/VERSION.txt"
get "$ext_url" "$ext_sha256" "$emb/sqlite_scanner.duckdb_extension.gz"

source_id=$(git describe --tags --always --long 2>/dev/null || git rev-parse --short HEAD)
version=$(sed -n 's/.*"productVersion": "\(.*\)".*/\1/p' wails.json)
build_number=$(git rev-list --count HEAD)
build_date=$(date -u +%F)
echo "Source: $source_id  versao $version  build $build_number ($build_date)  $(go version)"

# webkit2_41: Debian 13 has only WebKitGTK 4.1
wails build -clean -trimpath -tags webkit2_41 -ldflags "-X main.buildNumber=$build_number -X main.buildDate=$build_date" ||
    fail 1 "wails build falhou"
built=$root/build/bin/mdb2sql
go test -tags webkit2_41 ./... || fail 1 "go test falhou"
(cd frontend && pnpm exec vitest run) || fail 1 "vitest falhou"

# personal data gate: no home folder, no user name, no machine name in the binary
if grep -a -q -F -e "$HOME" -e "/$(id -un)/" -e "$(hostname)" "$built"; then
    fail 1 "o binario contem $HOME, /$(id -un)/ ou o nome da maquina (dado pessoal)"
fi
echo "Varredura: 0 caminhos de usuario ou nome de maquina no binario"

name="mdb2sql-$version-debian-amd64-go-wails-react"
stage=$root/dist/.stage
rm -rf "${stage:?}"
mkdir -p "$stage/$name"
# .zip: the app folder (binary, README.md, LICENSE); runtime needs the libraries listed in README-BUILD.txt
install -m 755 "$built" "$stage/$name/mdb2sql"
install -m 644 README.md LICENSE "$stage/$name/"
(cd "$stage" && zip -q -r -X "$name.zip" "$name")
rm -rf "${stage:?}/$name"

# .deb: /usr/bin command, menu entry and icon; Depends = libraries of the binary (dpkg-shlibdeps) plus those of the
# embedded mdbtools (GLib, libatomic), which dpkg-shlibdeps cannot see inside the binary
pkg=$stage/deb
install -D -m 755 "$built" "$pkg/usr/bin/$slug"
install -D -m 644 "scripts/linux/$slug.desktop" "$pkg/usr/share/applications/$slug.desktop"
install -D -m 644 build/appicon.png "$pkg/usr/share/pixmaps/$slug.png"
install -D -m 644 README.md "$pkg/usr/share/doc/$slug/README.md"
install -D -m 644 LICENSE "$pkg/usr/share/doc/$slug/LICENSE"
echo "Licenca: GPL-2.0-or-later. Texto completo em /usr/share/common-licenses/GPL-2." >"$pkg/usr/share/doc/$slug/copyright"
mkdir -p "$stage/shlibs/debian" "$pkg/DEBIAN"
printf 'Source: %s\n\nPackage: %s\nArchitecture: any\n' "$slug" "$slug" >"$stage/shlibs/debian/control"
depends=$(cd "$stage/shlibs" && dpkg-shlibdeps --ignore-missing-info -O "$pkg/usr/bin/$slug" "$mdb_dir/usr/bin/mdb-export" \
    -l"$mdb_dir/usr/lib/x86_64-linux-gnu" 2>/dev/null | sed -n 's/^shlibs:Depends=//p')
[ -n "$depends" ] || fail 1 "dpkg-shlibdeps nao achou as dependencias do binario"
depends=$(echo "$depends" | sed 's/libmdb3t64[^,]*, *//; s/, *libmdb3t64[^,]*//')
{
    echo "Package: $slug"
    echo "Version: $version"
    echo "Architecture: amd64"
    echo "Maintainer: Mauricio Menon <54405514+mauriciomenon@users.noreply.github.com>"
    echo "Section: utils"
    echo "Priority: optional"
    echo "Installed-Size: $(du -sk --exclude=DEBIAN "$pkg" | cut -f1)"
    echo "Depends: $depends"
    echo "Homepage: https://github.com/mauriciomenon/mdb2sql"
    echo "Description: Microsoft Access, SQLite and DuckDB viewer and converter (Go + Wails + React)"
    echo " Opens .accdb/.mdb without Microsoft Access (embedded mdbtools), SQLite and DuckDB files;"
    echo " converts Access to SQLite and exports to SQLite, DuckDB, Excel and CSV."
} >"$pkg/DEBIAN/control"
dpkg-deb --root-owner-group --build "$pkg" "$stage/${name}.deb" >/dev/null
rm -rf "${stage:?}/deb" "${stage:?}/shlibs"
grep -a -q -F -e "$HOME" -e "/$(id -un)/" "$stage/$name.deb" && fail 1 "o .deb contem caminho de usuario"

(cd "$stage" && sha256sum -- mdb2sql-* >SHA256SUMS.txt)
out=$root/dist/debian/amd64
rm -rf "${out:?}"
mkdir -p "$(dirname "$out")"
mv "$stage" "$out"
cat "$out/SHA256SUMS.txt"
echo "Depends: $depends"
echo "Source: $source_id"
