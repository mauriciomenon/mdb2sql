#!/usr/bin/env bash
# Debian amd64: baixa para .tools/ as ferramentas fixas, com sha256 conferido (equivale ao setup_tools.ps1):
#   uv/          uv fixo (o do sistema pode nao conhecer o Python de .python-version)
#   python/      Python de .python-version (via uv, que confere o sha256)
#   mdbtools/    mdb-tables/mdb-schema/mdb-export + libmdb.so.3 dos pacotes Debian 13 (vao no pacote do app)
#   duckdb_ext/  extensao sqlite do DuckDB linux_amd64 (le e grava .sqlite offline; vai no pacote)
# Chamado por ../build_debian_amd64.sh (que poe .tools/uv no PATH); sozinho: scripts/setup_tools_linux.sh
set -Eeuo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

# Versoes fixas: uv igual ao do build Windows; mdbtools 1.0.1 de Debian 13 (o mesmo 1.0.1 do exe do Windows);
# extensao sqlite da versao do DuckDB do uv.lock
uv_version="0.13.7"
uv_url="https://github.com/astral-sh/uv/releases/download/$uv_version/uv-x86_64-unknown-linux-gnu.tar.gz"
uv_sha="c5221ff41b7892bfc223543883600125f6a47fe845093e0f5bdff4f359196d83"
debian_pool="https://deb.debian.org/debian/pool/main/m/mdbtools"
mdbtools_debs=(
    "mdbtools_1.0.1-0.1_amd64.deb 77b2d317b9429f22de27e903586228836c013c81c8b6ed3a990ea8bf94b3bc52"
    "libmdb3t64_1.0.1-0.1_amd64.deb 705eaf16f423be3eebb4c794fca817130dbcabbafd10c408f4fdb5f3e1c1d172"
)
duckdb_version="2.0.0"
sqlite_ext_url="https://extensions.duckdb.org/v$duckdb_version/linux_amd64/sqlite_scanner.duckdb_extension.gz"
sqlite_ext_sha="59b8a0ba6d7599d4aa584bd24e8b4cc3247076bb174157f43e110e56e6c72e86"

# baixa $1 para $2 e confere o sha256 $3 (arquivo errado e apagado)
fetch() {
    curl -fsSL --retry 2 -o "$2" "$1"
    local got
    got="$(sha256sum "$2" | cut -d' ' -f1)"
    if [[ "$got" != "$3" ]]; then
        rm -f "$2"
        echo "sha256 errado em $1: $got (esperado $3)" >&2
        exit 1
    fi
}

if [[ "$(cat .tools/uv/.sha256 2>/dev/null)" != "$uv_sha" ]]; then
    rm -rf .tools/uv
    mkdir -p .tools/uv
    fetch "$uv_url" .tools/uv/uv.tar.gz "$uv_sha"
    tar -xzf .tools/uv/uv.tar.gz -C .tools/uv --strip-components=1
    rm .tools/uv/uv.tar.gz
    printf '%s' "$uv_sha" >.tools/uv/.sha256
fi
export PATH="$root_dir/.tools/uv:$PATH" UV_PYTHON_INSTALL_DIR="$root_dir/.tools/python"
uv --version
uv python install "$(head -n1 .python-version)" --no-bin
uv python find "$(head -n1 .python-version)" --managed-python

stamp="$(printf '%s\n' "${mdbtools_debs[@]}" | sha256sum | cut -d' ' -f1)"
if [[ "$(cat .tools/mdbtools/.sha256 2>/dev/null)" != "$stamp" ]]; then
    work="$(mktemp -d)"
    trap 'rm -rf "${work:?}"' EXIT
    for entry in "${mdbtools_debs[@]}"; do
        read -r deb sha <<<"$entry"
        fetch "$debian_pool/$deb" "$work/$deb" "$sha"
        dpkg-deb -x "$work/$deb" "$work/root"
    done
    rm -rf .tools/mdbtools
    mkdir -p .tools/mdbtools
    # so o que o app usa: os 3 programas, a libmdb (o resto vem do sistema: glib, libatomic), licenca e versao
    install -m 755 "$work"/root/usr/bin/mdb-{tables,schema,export} .tools/mdbtools/
    cp -P "$work"/root/usr/lib/x86_64-linux-gnu/libmdb.so.3* .tools/mdbtools/
    install -m 644 "$work/root/usr/share/doc/mdbtools/copyright" .tools/mdbtools/COPYING
    printf 'mdbtools 1.0.1 (Debian 1.0.1-0.1, amd64)\n' >.tools/mdbtools/VERSION.txt
    printf '%s' "$stamp" >.tools/mdbtools/.sha256
    echo "mdbtools: pacotes Debian com sha256 conferido em .tools/mdbtools"
fi

if [[ "$(cat .tools/duckdb_ext/.sha256 2>/dev/null)" != "$sqlite_ext_sha" ]]; then
    mkdir -p .tools/duckdb_ext
    fetch "$sqlite_ext_url" .tools/duckdb_ext/sqlite_scanner.duckdb_extension.gz "$sqlite_ext_sha"
    gzip -df .tools/duckdb_ext/sqlite_scanner.duckdb_extension.gz
    printf '%s' "$sqlite_ext_sha" >.tools/duckdb_ext/.sha256
    echo "duckdb_ext: extensao sqlite linux_amd64 com sha256 conferido"
fi
LD_LIBRARY_PATH=.tools/mdbtools .tools/mdbtools/mdb-export --version
