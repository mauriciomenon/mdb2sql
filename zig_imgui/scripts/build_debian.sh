#!/usr/bin/env bash
# Debian amd64: ferramentas fixas, testes, build de release e produtos em dist/debian/amd64/ (.deb e .zip).
# Uso (pelo atalho da raiz): ./build_debian_amd64.sh   (no WSL, pelo build_debian_amd64_wsl.ps1)
# Codigos de saida: 0 ok, 1 falha de build/teste/varredura, 2 maquina ou pasta errada ou arvore suja, 3 falta ferramenta.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
slug=mdb2sql-zig-imgui

fail() {
    echo "ERRO: $2" >&2
    exit "$1"
}

[ "$(uname -m)" = x86_64 ] || fail 2 "este comando gera o pacote amd64 e so roda em Linux x86_64"
case "$root" in
    /mnt/*) fail 2 "rode num clone no disco do Linux (ex.: ~/src/mdb2sql-zig), nao em $root" ;;
esac
missing=""
for p in build-essential curl xz-utils git zip dpkg-dev libx11-dev libgl-dev; do
    dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"
done
[ -z "$missing" ] || fail 3 "faltam pacotes: sudo apt install$missing"
if [ -n "$(git status --porcelain)" ]; then
    git status --short
    fail 2 "arvore com alteracoes nao commitadas; commite antes do build"
fi

bash scripts/setup_tools_linux.sh
zig=$(ls -d "$root"/.tools/zig-x86_64-linux-*/zig | head -n1)
version=$(sed -n 's/^ *\.version = "\(.*\)",/\1/p' build.zig.zon | head -n1)
number=$(git rev-list --count HEAD)
commit=$(git rev-parse HEAD)
date=$(date -u +%F)
source_id=$(git describe --tags --always --dirty 2>/dev/null || git rev-parse --short HEAD)
echo "Build $number ($date)  versao $version  Zig $("$zig" version)"

rm -rf .zig-cache zig-out dist/.stage
# dependencias do build.zig.zon (hash conferido pelo zig); o cliente HTTP do zig as vezes cai no meio: tenta de novo
for try in 1 2 3; do
    "$zig" build --fetch && break
    [ "$try" -lt 3 ] || fail 1 "zig build --fetch falhou 3 vezes"
    sleep 5
done
"$zig" build test --summary all || fail 1 "testes falharam"
"$zig" build install -Doptimize=ReleaseSafe -Dstrip=true "-Dbuild_number=$number" "-Dbuild_date=$date" "-Dcommit=$commit" || fail 1 "zig build falhou"
bin=$root/zig-out/bin

# Varredura de dado pessoal: nenhuma pasta do usuario nem /<usuario>/ nos binarios
for f in "$bin"/mdb2sql-zig "$bin"/mdbtools/mdb-*; do
    if grep -a -q -F -e "$HOME" -e "/$(id -un)/" "$f"; then fail 1 "$f contem $HOME ou /$(id -un)/ (dado pessoal)"; fi
done
echo "Varredura: 0 caminhos de usuario nos binarios"

name=mdb2sql-$version-debian-amd64-zig-imgui
stage=$root/dist/.stage
mkdir -p "$stage/$slug/mdbtools"
# pasta do app: os arquivos precisam ficar juntos (a libduckdb.so e achada ao lado do executavel)
install -m 755 "$bin/mdb2sql-zig" "$bin/libduckdb.so" "$stage/$slug/"
install -m 644 "$bin/sqlite_scanner.duckdb_extension" README.md LICENSE "$stage/$slug/"
install -m 755 "$bin"/mdbtools/mdb-* "$stage/$slug/mdbtools/"
install -m 644 "$bin"/mdbtools/COPYING* "$stage/$slug/mdbtools/"
(cd "$stage" && zip -q -r -X "$name.zip" "$slug")

# .deb: programa em /usr/lib/<slug>, comando /usr/bin/mdb2sql-zig, entrada de menu e icone. Depends: as bibliotecas
# ligadas (dpkg-shlibdeps) mais as carregadas em tempo de execucao (OpenGL, X11 do GLFW, zenity dos dialogos)
pkg=$stage/deb
mkdir -p "$pkg/usr/lib" "$pkg/usr/bin" "$pkg/DEBIAN"
cp -a "$stage/$slug" "$pkg/usr/lib/$slug"
ln -s "../lib/$slug/mdb2sql-zig" "$pkg/usr/bin/mdb2sql-zig"
install -D -m 644 assets/linux/$slug.desktop "$pkg/usr/share/applications/$slug.desktop"
install -D -m 644 assets/linux/$slug.png "$pkg/usr/share/pixmaps/$slug.png"
install -D -m 644 README.md "$pkg/usr/share/doc/$slug/README.md"
echo "Licenca: GPL-2.0-or-later. Texto completo em /usr/share/common-licenses/GPL-2." >"$pkg/usr/share/doc/$slug/copyright"
mkdir -p "$stage/shlibs/debian"
printf 'Source: %s\n\nPackage: %s\nArchitecture: any\n' "$slug" "$slug" >"$stage/shlibs/debian/control"
depends=$(cd "$stage/shlibs" && dpkg-shlibdeps -l"$pkg/usr/lib/$slug" -O "$pkg/usr/lib/$slug/mdb2sql-zig" "$pkg/usr/lib/$slug/libduckdb.so" "$pkg/usr/lib/$slug"/mdbtools/mdb-* 2>/dev/null | sed -n 's/^shlibs:Depends=//p')
[ -n "$depends" ] || fail 1 "dpkg-shlibdeps nao achou as dependencias"
{
    echo "Package: $slug"
    echo "Version: $version"
    echo "Architecture: amd64"
    echo "Maintainer: Mauricio Menon <54405514+mauriciomenon@users.noreply.github.com>"
    echo "Section: database"
    echo "Priority: optional"
    echo "Installed-Size: $(du -sk --exclude=DEBIAN "$pkg" | cut -f1)"
    echo "Depends: $depends, libgl1, libx11-6, libxrandr2, libxinerama1, libxcursor1, libxi6, zenity, xdg-utils, fonts-dejavu-core"
    echo "Homepage: https://github.com/mauriciomenon/mdb2sql"
    echo "Description: mdb2sql (Zig + Dear ImGui): opens Access, SQLite and DuckDB files and exports them"
    echo " Reads .accdb/.mdb with the included mdbtools (no Access needed), converted once to SQLite,"
    echo " searches every table and exports to SQLite, Excel, CSV and DuckDB."
} >"$pkg/DEBIAN/control"
dpkg-deb --root-owner-group --build "$pkg" "$stage/$name.deb" >/dev/null
rm -rf "${stage:?}/deb" "${stage:?}/shlibs" "${stage:?}/$slug"

(cd "$stage" && sha256sum -- mdb2sql-* >SHA256SUMS.txt)
out=$root/dist/debian/amd64
rm -rf "${out:?}"
mkdir -p "$(dirname "$out")"
mv "$stage" "$out"
cat "$out/SHA256SUMS.txt"
echo "Source: $source_id"
