#!/usr/bin/env bash
# Debian amd64: limpa, baixa as ferramentas fixas (scripts/setup_tools_linux.sh), roda os testes, compila
# (PyInstaller, pasta do app com Python/Qt/DuckDB, extensao sqlite e mdbtools dentro), varre os produtos atras de
# dados da maquina de build, confere que o app abre um .mdb pelo mdbtools do pacote e so no fim troca
# dist/debian/amd64/ (.deb e .zip).
# Uso (clone no disco Linux, arvore commitada): ./build_debian_amd64.sh   No Windows: build_debian_amd64_wsl.ps1
# Saida: 0 ok, 1 falha de build/teste, 2 maquina ou pasta errada / arvore com alteracoes, 3 ferramenta faltando
set -Eeuo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$root_dir"
slug="mdb2sql-python-pyqt6"

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]] || ! grep -qsE '^ID(_LIKE)?=.*debian' /etc/os-release; then
    echo "este comando gera o pacote Debian amd64 e so roda em Debian (ou derivado) amd64" >&2
    exit 2
fi
# pasta do Windows pelo WSL (/mnt/c): permissoes 777 que o dpkg-deb recusa e .venv/.tools misturados com o Windows
case "$(stat -f -c %T "$root_dir")" in
    v9fs | 9p | drvfs) echo "$root_dir esta num disco do Windows: use um clone no disco Linux (build_debian_amd64_wsl.ps1)" >&2; exit 2 ;;
esac
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "arvore com alteracoes nao commitadas; commite antes:" >&2
    git status --short --untracked-files=no >&2
    exit 2
fi
for tool in uv dpkg-deb dpkg-query curl; do
    command -v "$tool" >/dev/null || { echo "$tool nao encontrado (sudo apt install dpkg curl; uv: https://docs.astral.sh/uv/)" >&2; exit 3; }
done
echo "Source: $(git describe --tags --always) ($(git rev-parse HEAD))"

./clean.sh
scripts/setup_tools_linux.sh
export UV_PYTHON_INSTALL_DIR="$root_dir/.tools/python" UV_PYTHON_PREFERENCE=only-managed UV_LOCKED=1

uv sync
QT_QPA_PLATFORM=offscreen uv run --no-sync pytest -q -p no:cacheprovider
uv run --no-sync pyinstaller --noconfirm --clean --distpath build/dist --workpath build/work mdb2sql.spec
app="build/dist/mdb2sql"
install -m 644 LICENSE "$app/LICENSE"  # GPL v2 ou posterior: vai no zip e no .deb
version="$(cat build/VERSION)"
name="mdb2sql-$version-debian-amd64-python-pyqt6"

# o pacote tem de abrir Access sem nada instalado: mdbtools do proprio pacote num .mdb (copia do teste)
LD_LIBRARY_PATH="$app/_internal/mdbtools" "$app/_internal/mdbtools/mdb-tables" -1 tests/data/sample.mdb
# o app sobe e continua aberto com um .mdb na linha de comando (124 = ainda rodando quando o timeout fechou)
smoke="$(mktemp -d)"
cp tests/data/sample.mdb "$smoke/"
set +e
HOME="$smoke" TMPDIR="$smoke" QT_QPA_PLATFORM=offscreen MDB2SQL_ACCESS_READER=mdbtools timeout 15 "$app/mdb2sql" "$smoke/sample.mdb"
status=$?
set -e
rm -rf "${smoke:?}"
[[ $status == 124 ]] || { echo "o app saiu com codigo $status ao abrir sample.mdb" >&2; exit 1; }

stage="dist/.stage"
rm -rf "$stage"
mkdir -p "$stage"

# .deb: /opt/<slug>/ (pasta do app), /usr/bin/<slug>, menu, icone e copyright em texto simples
deb="$stage/debroot"
mkdir -p "$deb/DEBIAN" "$deb/opt" "$deb/usr/bin" "$deb/usr/share/applications" \
    "$deb/usr/share/icons/hicolor/1024x1024/apps" "$deb/usr/share/doc/$slug"
cp -a "$app" "$deb/opt/$slug"
printf '%s\n' '#!/bin/sh' "exec /opt/$slug/mdb2sql \"\$@\"" >"$deb/usr/bin/$slug"
chmod 755 "$deb/usr/bin/$slug"
install -m 644 src/resources/mdb2sql.png "$deb/usr/share/icons/hicolor/1024x1024/apps/$slug.png"
printf '%s\n' "[Desktop Entry]" "Type=Application" "Name=MDB2SQL (Python + PyQt6)" \
    "Comment=Access, SQLite and DuckDB viewer and exporter" "Exec=$slug %f" "Icon=$slug" "Terminal=false" \
    "Categories=Office;Database;" "MimeType=application/vnd.ms-access;application/x-msaccess;application/vnd.sqlite3;" \
    >"$deb/usr/share/applications/$slug.desktop"
printf '%s\n' "Licenca: GPL-2.0-or-later. Texto completo em /usr/share/common-licenses/GPL-2." \
    >"$deb/usr/share/doc/$slug/copyright"
glibc="$(dpkg-query -W -f='${source:Upstream-Version}' libc6)"
# bibliotecas do sistema que o Qt do PyQt6 (xcb/wayland) e o mdbtools (glib, libatomic) carregam
printf '%s\n' "Package: $slug" "Version: $version" "Section: utils" "Priority: optional" "Architecture: amd64" \
    "Depends: libc6 (>= $glibc), libatomic1, libdbus-1-3, libegl1, libfontconfig1, libfreetype6, libgl1, libglib2.0-0t64 | libglib2.0-0, libwayland-client0, libwayland-cursor0, libwayland-egl1, libx11-6, libx11-xcb1, libxcb1, libxcb-cursor0, libxcb-icccm4, libxcb-image0, libxcb-keysyms1, libxcb-randr0, libxcb-render0, libxcb-render-util0, libxcb-shape0, libxcb-shm0, libxcb-sync1, libxcb-util1, libxcb-xfixes0, libxcb-xkb1, libxkbcommon0, libxkbcommon-x11-0" \
    "Maintainer: Mauricio Menon <54405514+mauriciomenon@users.noreply.github.com>" \
    "Description: MDB2SQL (Python + PyQt6): Access, SQLite and DuckDB viewer and exporter" \
    " Opens .accdb/.mdb without Microsoft Access (bundled mdbtools), SQLite and DuckDB files; exports to" \
    " SQLite, DuckDB, Excel and CSV." >"$deb/DEBIAN/control"
dpkg-deb --root-owner-group --build "$deb" "$stage/$name.deb"
rm -rf "$deb"

# .zip: a pasta do app dentro de <nome>/ (zipfile guarda as permissoes: os executaveis continuam executaveis)
mkdir "$stage/$name"
cp -a "$app/." "$stage/$name/"
(cd "$stage" && "$root_dir/.venv/bin/python" -m zipfile -c "$name.zip" "$name")
rm -rf "${stage:?}/$name"

# produtos sem caminho/nome da maquina de build: a pasta do app e o .deb extraido
check="$(mktemp -d)"
dpkg-deb -x "$stage/$name.deb" "$check"
uv run --no-sync python scripts/scan_exe.py "$app" "$check/opt/$slug"
rm -rf "${check:?}"

rm -rf dist/debian/amd64
mkdir -p dist/debian
mv "$stage" dist/debian/amd64
echo "Source: $(git describe --tags --always) ($(git rev-parse HEAD))"
(cd dist/debian/amd64 && sha256sum -- * && du -h -- *)
