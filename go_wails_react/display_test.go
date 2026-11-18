package main

import (
	"strings"
	"testing"

	"mdb2sql/i18n"
)

func TestPlanDisplay(t *testing.T) {
	defer i18n.SetLang("en")
	i18n.SetLang("en")
	osr := map[string]string{
		"debian":   "PRETTY_NAME=\"Debian GNU/Linux 13 (trixie)\"\nID=debian\n",
		"ubuntu":   "PRETTY_NAME=\"Ubuntu 24.04 LTS\"\nID=ubuntu\nID_LIKE=debian\n",
		"fedora":   "PRETTY_NAME=\"Fedora Linux 41\"\nID=fedora\n",
		"rocky":    "PRETTY_NAME=\"Rocky Linux 9\"\nID=\"rocky\"\nID_LIKE=\"rhel centos fedora\"\n",
		"arch":     "PRETTY_NAME=\"Arch Linux\"\nID=arch\n",
		"manjaro":  "PRETTY_NAME=\"Manjaro Linux\"\nID=manjaro\nID_LIKE=arch\n",
		"opensuse": "PRETTY_NAME=\"openSUSE Tumbleweed\"\nID=\"opensuse-tumbleweed\"\nID_LIKE=\"opensuse suse\"\n",
		"other":    "PRETTY_NAME=\"Alpine Linux v3.20\"\nID=alpine\n",
	}
	env := func(kv ...string) func(string) string {
		m := map[string]string{}
		for i := 0; i+1 < len(kv); i += 2 {
			m[kv[i]] = kv[i+1]
		}
		return func(k string) string { return m[k] }
	}
	wayland := env("WAYLAND_DISPLAY", "wayland-0")
	cases := []struct {
		name, release   string
		getenv          func(string) string
		backend, distro string
		command         string // "-" = no warning
		fatal           bool
	}{
		{"user GDK_BACKEND wins", osr["debian"], env("GDK_BACKEND", "wayland", "WAYLAND_DISPLAY", "w"), "", "", "-", false},
		{"X11 present", osr["debian"], env("DISPLAY", ":0", "WAYLAND_DISPLAY", "w"), "x11,wayland", "", "-", false},
		{"debian", osr["debian"], wayland, "x11,wayland", "Debian GNU/Linux 13 (trixie)", "sudo apt install xwayland", false},
		{"ubuntu", osr["ubuntu"], wayland, "x11,wayland", "Ubuntu 24.04 LTS", "sudo apt install xwayland", false},
		{"fedora", osr["fedora"], wayland, "x11,wayland", "Fedora Linux 41", "sudo dnf install xorg-x11-server-Xwayland", false},
		{"rhel family", osr["rocky"], wayland, "x11,wayland", "Rocky Linux 9", "sudo dnf install xorg-x11-server-Xwayland", false},
		{"arch", osr["arch"], wayland, "x11,wayland", "Arch Linux", "sudo pacman -S xorg-xwayland", false},
		{"arch family", osr["manjaro"], wayland, "x11,wayland", "Manjaro Linux", "sudo pacman -S xorg-xwayland", false},
		{"opensuse", osr["opensuse"], wayland, "x11,wayland", "openSUSE Tumbleweed", "sudo zypper install xwayland", false},
		{"other: no command", osr["other"], wayland, "x11,wayland", "Alpine Linux v3.20", "", false},
		{"no display at all", osr["debian"], env(), "", "", "-", true},
	}
	for _, c := range cases {
		p := planDisplay(c.getenv, c.release)
		if p.backend != c.backend || (p.fatal != "") != c.fatal || (c.command == "-") != (p.warn == nil) {
			t.Errorf("%s: %+v", c.name, p)
			continue
		}
		if w := p.warn; w != nil {
			if w.Distro != c.distro || w.Command != c.command || w.Help != displayHelp ||
				w.Text != "X11 unavailable; using Wayland." || w.Missing != "X server not set (DISPLAY)" {
				t.Errorf("%s: %+v", c.name, *w)
			}
			// 3 short lines (2 without a command), no raw URL, no "..."
			lines := strings.Split(w.Lines(), "\n")
			if want := map[bool]int{true: 3, false: 2}[c.command != ""]; len(lines) != want ||
				strings.Contains(w.Lines(), "http") || strings.Contains(w.Lines(), "...") {
				t.Errorf("%s: lines %q", c.name, lines)
			}
		}
	}
	i18n.SetLang("pt-BR")
	if w := planDisplay(wayland, osr["debian"]).warn; w.Text != "X11 indisponível; usando Wayland." || w.Missing != "Servidor X não definido (DISPLAY)" {
		t.Errorf("pt-BR: %+v", *w)
	}
}
