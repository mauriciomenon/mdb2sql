# Linux: X11 primeiro, Wayland so como reserva, aviso curto com o comando da distribuicao (REGRA_X11)
import pytest
from PyQt6.QtWidgets import QApplication, QPushButton

from shared import display, i18n
from shared.display import HELP, Notice, decide, os_release
from ui.dialogs import DisplayWarning

DEBIAN = 'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"\nNAME="Debian GNU/Linux"\nID=debian\n'
UBUNTU = 'PRETTY_NAME="Ubuntu 24.04.3 LTS"\nID=ubuntu\nID_LIKE=debian\n'
FEDORA = 'NAME="Fedora Linux"\nPRETTY_NAME="Fedora Linux 43 (Workstation Edition)"\nID=fedora\n'
ROCKY = 'PRETTY_NAME="Rocky Linux 9.6 (Blue Onyx)"\nID="rocky"\nID_LIKE="rhel centos fedora"\n'
ARCH = 'NAME="Arch Linux"\nPRETTY_NAME="Arch Linux"\nID=arch\n'
SUSE = 'PRETTY_NAME="openSUSE Tumbleweed"\nID="opensuse-tumbleweed"\nID_LIKE="opensuse suse"\n'
OTHER = 'PRETTY_NAME="Void Linux"\nID=void\n'
WAYLAND = {"WAYLAND_DISPLAY": "wayland-0"}
X11 = {"DISPLAY": ":0", "WAYLAND_DISPLAY": "wayland-0"}


def test_os_release_family() -> None:
    assert [os_release(t)[0] for t in (DEBIAN, UBUNTU, FEDORA, ROCKY, ARCH, SUSE, OTHER, "")] == [
        "debian", "debian", "fedora", "fedora", "arch", "suse", "", ""
    ]
    assert os_release(UBUNTU)[1] == "Ubuntu 24.04.3 LTS" and os_release("")[1] == "Linux"


def test_x11_available_no_warning() -> None:
    assert decide(X11, DEBIAN, []) == ("xcb;wayland", None)


def test_user_choice_is_respected() -> None:
    assert decide({**WAYLAND, "QT_QPA_PLATFORM": "wayland"}, DEBIAN, ["libxcb.so.1"]) == (None, None)
    assert decide({"QT_QPA_PLATFORM": "offscreen"}, "", []) == (None, None)


@pytest.mark.parametrize(
    ("release", "command", "distro"),
    [
        (DEBIAN, "sudo apt install xwayland", "Debian GNU/Linux 13 (trixie)"),
        (UBUNTU, "sudo apt install xwayland", "Ubuntu 24.04.3 LTS"),
        (FEDORA, "sudo dnf install xorg-x11-server-Xwayland", "Fedora Linux 43 (Workstation Edition)"),
        (ARCH, "sudo pacman -S xorg-xwayland", "Arch Linux"),
        (SUSE, "sudo zypper install xwayland", "openSUSE Tumbleweed"),
    ],
)
def test_no_x_server_falls_back_to_wayland_with_the_distro_command(release, command, distro) -> None:
    platform, notice = decide(WAYLAND, release, [])
    assert platform == "xcb;wayland" and notice == Notice(
        ["X11 unavailable; using Wayland.", "Missing: X server"], distro, command
    )
    # tres linhas curtas, sem URL no texto (o link Ajuda e clicavel no dialogo)
    assert notice.text() == f"X11 unavailable; using Wayland.\nMissing: X server\n{distro}: {command}"


@pytest.mark.parametrize(
    ("release", "command"),
    [
        (DEBIAN, "sudo apt install libxcb1 libegl1"),
        (FEDORA, "sudo dnf install libxcb libglvnd-egl"),
        (ARCH, "sudo pacman -S libxcb libglvnd"),
        (SUSE, "sudo zypper install libxcb1 libEGL1"),
    ],
)
def test_missing_libraries_are_named_with_their_packages(release, command) -> None:
    platform, notice = decide(X11, release, ["libxcb.so.1", "libEGL.so.1"])
    assert platform == "xcb;wayland" and notice.command == command
    assert notice.lines[1] == "Missing: libxcb.so.1, libEGL.so.1"


def test_other_distro_lists_what_is_missing_without_a_command() -> None:
    platform, notice = decide(WAYLAND, OTHER, ["libGL.so.1"])
    assert platform == "xcb;wayland"
    assert notice.text() == "X11 unavailable; using Wayland.\nMissing: libGL.so.1, X server"


def test_neither_x11_nor_wayland_is_an_error() -> None:
    platform, notice = decide({}, DEBIAN, [])
    assert platform == "" and "WAYLAND_DISPLAY" in notice.text()


def test_message_in_the_chosen_language() -> None:
    i18n.set_language("pt_BR")
    _, notice = decide(WAYLAND, DEBIAN, [])
    assert notice.text() == (
        "X11 indisponível; usando Wayland.\nFalta: servidor X\nDebian GNU/Linux 13 (trixie): sudo apt install xwayland"
    )


def test_missing_libs_uses_dlopen(monkeypatch) -> None:
    loaded = []

    def fake_cdll(name):
        loaded.append(name)
        if name == "libEGL.so.1":
            raise OSError(name)

    monkeypatch.setattr(display.ctypes, "CDLL", fake_cdll)
    assert display.missing_libs() == ["libEGL.so.1"] and loaded == list(display.SYSTEM_LIBS)


def test_warning_dialog_command_copy_and_help_link(qtbot) -> None:
    _, notice = decide(WAYLAND, DEBIAN, [])
    box = DisplayWarning(notice)
    qtbot.addWidget(box)
    assert box.windowTitle() == "Display mode"
    assert box.command.text() == "sudo apt install xwayland" and box.command.isReadOnly()
    next(b for b in box.findChildren(QPushButton) if b.text() == "Copy").click()
    assert QApplication.clipboard().text() == "sudo apt install xwayland"
    assert box.help.text() == f'<a href="{HELP}">Help</a>' and box.help.openExternalLinks()
    assert HELP not in "\n".join(notice.lines)  # sem URL crua no texto
