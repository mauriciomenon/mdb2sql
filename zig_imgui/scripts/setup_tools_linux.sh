#!/usr/bin/env bash
# Linux x86_64: baixa para .tools/ (fora do git) as ferramentas e arquivos fixos, conferindo o sha256 de cada um:
#   Zig (compilador), extensao sqlite do DuckDB (vai junto do programa) e o fonte do mdbtools 1.0.1, compilado aqui
#   (estatico: mdb-tables, mdb-schema e mdb-export sem libmdb.so; vai junto do programa).
# Chamado por scripts/build_debian.sh; sozinho: bash scripts/setup_tools_linux.sh
# As outras dependencias (Dear ImGui, cimgui, zglfw, libduckdb) sao baixadas pelo `zig build`, fixadas por hash
# em build.zig.zon.
set -euo pipefail
cd "$(dirname "$0")/.."
tools=$PWD/.tools
mkdir -p "$tools"

# Versoes fixas. Para trocar: versao + sha256 juntos.
zig_version=0.17.1
zig_sha256=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a # ziglang.org/download/index.json
duckdb_version=v2.0.0 # a mesma da libduckdb de build.zig.zon
sqlite_ext_sha256=59b8a0ba6d7599d4aa584bd24e8b4cc3247076bb174157f43e110e56e6c72e86 # .gz conferido em 2026-11-17
mdbtools_version=1.0.1
mdbtools_sha256=ff9c425a88bc20bf9318a332eec50b17e77896eef65a0e69415ccb4e396d1812 # release v1.0.1 do mdbtools

fetch() { # url arquivo sha256
    curl -fsSL --retry 3 -o "$2" "$1"
    echo "$3  $2" | sha256sum -c --quiet - || { rm -f "$2"; echo "sha256 de $(basename "$2") nao confere" >&2; exit 1; }
}

zig_dir=$tools/zig-x86_64-linux-$zig_version
if [ -x "$zig_dir/zig" ]; then echo "Zig $zig_version ja esta em $zig_dir"; else
    fetch "https://ziglang.org/download/$zig_version/zig-x86_64-linux-$zig_version.tar.xz" "$tools/_zig.tar.xz" "$zig_sha256"
    tar -xJf "$tools/_zig.tar.xz" -C "$tools"
    rm -f "$tools/_zig.tar.xz"
    echo "Zig $zig_version instalado em $zig_dir"
fi

ext_dir=$tools/duckdb-ext-$duckdb_version-linux
if [ -f "$ext_dir/.sha256-$sqlite_ext_sha256" ]; then echo "extensao sqlite $duckdb_version ja esta em $ext_dir"; else
    mkdir -p "$ext_dir"
    fetch "http://extensions.duckdb.org/$duckdb_version/linux_amd64/sqlite_scanner.duckdb_extension.gz" "$ext_dir/ext.gz" "$sqlite_ext_sha256"
    gunzip -c "$ext_dir/ext.gz" >"$ext_dir/sqlite_scanner.duckdb_extension"
    rm -f "$ext_dir/ext.gz"
    touch "$ext_dir/.sha256-$sqlite_ext_sha256"
    echo "extensao sqlite instalada em $ext_dir"
fi

mdb_dir=$tools/mdbtools-$mdbtools_version-linux
if [ -f "$mdb_dir/.sha256-$mdbtools_sha256" ]; then echo "mdbtools $mdbtools_version ja esta em $mdb_dir"; else
    work=$tools/_mdbtools
    rm -rf "${work:?}"
    mkdir -p "$work"
    fetch "https://github.com/mdbtools/mdbtools/releases/download/v$mdbtools_version/mdbtools-$mdbtools_version.tar.gz" "$work/src.tar.gz" "$mdbtools_sha256"
    tar -xzf "$work/src.tar.gz" -C "$work"
    (
        cd "$work/mdbtools-$mdbtools_version"
        # estatico (sem libmdb.so para instalar), sem GLib (fakeglib do proprio mdbtools) e sem manuais; o driver
        # ODBC do mdbtools nao e pedido (padrao: desligado); caminhos neutros no binario
        CFLAGS="-O2 -ffile-prefix-map=$work=mdbtools" ./configure --disable-shared --enable-static --disable-glib \
            --disable-man >../configure.log
        make -j"$(nproc)" >../make.log
    )
    rm -rf "${mdb_dir:?}"
    mkdir -p "$mdb_dir"
    for t in mdb-tables mdb-schema mdb-export; do
        install -m 755 "$work/mdbtools-$mdbtools_version/src/util/$t" "$mdb_dir/$t"
        strip "$mdb_dir/$t"
    done
    install -m 644 "$work/mdbtools-$mdbtools_version/COPYING" "$work/mdbtools-$mdbtools_version/COPYING.LIB" "$mdb_dir/"
    rm -rf "${work:?}"
    touch "$mdb_dir/.sha256-$mdbtools_sha256"
    echo "mdbtools $mdbtools_version compilado em $mdb_dir"
fi
