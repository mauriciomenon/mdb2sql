# Linux: X11 (xcb) primeiro, Wayland so como reserva, com aviso na abertura (REGRA_X11). Windows e macOS: nada muda.
# !T: decide() is pure (environment, /etc/os-release text, missing libraries) so the rule is unit-tested; main()
# !T: sets QT_QPA_PLATFORM="xcb;wayland" before QApplication and shows the warning after it exists

import ctypes
from pathlib import Path
from typing import Mapping, NamedTuple

from shared.i18n import tr

HELP = "https://github.com/mauriciomenon/mdb2sql/blob/master/python_pyqt6/README.md#linux-x11-e-wayland"
# bibliotecas do sistema que o plugin xcb do Qt carrega e que o pacote nao leva (ldd no libqxcb.so do build Debian;
# libX11, libxcb-cursor, libxkbcommon-x11 etc. vao dentro do pacote) -> pacote por familia de distribuicao
SYSTEM_LIBS = {
    "libxcb.so.1": {"debian": "libxcb1", "fedora": "libxcb", "arch": "libxcb", "suse": "libxcb1"},
    "libGL.so.1": {"debian": "libgl1", "fedora": "libglvnd-glx", "arch": "libglvnd", "suse": "libGL1"},
    "libEGL.so.1": {"debian": "libegl1", "fedora": "libglvnd-egl", "arch": "libglvnd", "suse": "libEGL1"},
}
# servidor X dentro de uma sessao Wayland (DISPLAY ausente)
XWAYLAND = {"debian": "xwayland", "fedora": "xorg-x11-server-Xwayland", "arch": "xorg-xwayland", "suse": "xwayland"}
INSTALL = {"debian": "sudo apt install", "fedora": "sudo dnf install", "arch": "sudo pacman -S",
           "suse": "sudo zypper install"}


def os_release(text: str) -> tuple[str, str]:
    """(familia, nome) a partir do /etc/os-release: familia debian/fedora/arch/suse ou '' (outra)."""
    values = {}
    for line in text.splitlines():
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"')
    # ID e ID_LIKE: "ubuntu" com ID_LIKE "debian", "opensuse-leap", "rocky" com ID_LIKE "rhel centos fedora"
    ids = f"{values.get('ID', '')} {values.get('ID_LIKE', '')}".lower().split()
    families = (("debian", ("debian", "ubuntu")), ("fedora", ("fedora", "rhel", "centos")), ("arch", ("arch",)),
                ("suse", ("suse", "opensuse")))
    family = next((f for f, names in families if any(i == n or i.startswith(f"{n}-") for i in ids for n in names)), "")
    return family, values.get("PRETTY_NAME") or values.get("NAME") or "Linux"


def missing_libs(names=SYSTEM_LIBS) -> list[str]:
    """Bibliotecas do sistema que nao carregam (dlopen)."""
    missing = []
    for name in names:
        try:
            ctypes.CDLL(name)
        except OSError:
            missing.append(name)
    return missing


class Notice(NamedTuple):
    """Aviso de tela: 'X11 indisponivel; usando Wayland.' + 'Falta: ...', a distribuicao e o comando (ou None)."""

    lines: list[str]
    distro: str
    command: str | None

    def text(self) -> str:
        # texto inteiro (log, stderr); a terceira linha so com comando
        return "\n".join(self.lines + ([f"{self.distro}: {self.command}"] if self.command else []))


def decide(env: Mapping[str, str], release: str, missing: list[str]) -> tuple[str | None, Notice | None]:
    """(plataforma do Qt, aviso): plataforma None = a do usuario (sem aviso); 'xcb;wayland' com aviso se o X11 nao
    serve; '' = sem X11 e sem Wayland (o aviso vai para o stderr e o app sai)."""
    if env.get("QT_QPA_PLATFORM"):
        return None, None  # escolha do usuario: respeitar, sem aviso
    if env.get("DISPLAY") and not missing:
        return "xcb;wayland", None
    if not env.get("WAYLAND_DISPLAY"):
        return "", Notice([tr("display.none")], "", None)
    family, pretty = os_release(release)
    no_server = not env.get("DISPLAY")
    # segunda linha: o fato, sem rotulo ("Servidor X nao definido (DISPLAY)", "libxcb.so.1 nao instalada")
    facts = ([tr("display.no_server")] if no_server else []) + (
        [tr("display.not_installed" if len(missing) == 1 else "display.not_installed_many", libs=", ".join(missing))]
        if missing else []
    )
    lines = [tr("display.using_wayland"), "; ".join(facts)]
    if not family:
        return "xcb;wayland", Notice(lines, pretty, None)  # outra distribuicao: so o que falta, sem comando
    packages = [SYSTEM_LIBS[name][family] for name in missing] + ([XWAYLAND[family]] if no_server else [])
    command = f"{INSTALL[family]} {' '.join(dict.fromkeys(packages))}"  # sem repetir (libglvnd no Arch)
    return "xcb;wayland", Notice(lines, pretty, command)


def linux_choice(env: Mapping[str, str]) -> tuple[str | None, Notice | None]:
    """decide() com o os-release e as bibliotecas desta maquina."""
    release = Path("/etc/os-release")
    text = release.read_text(encoding="utf-8", errors="replace") if release.is_file() else ""
    return decide(env, text, missing_libs())
