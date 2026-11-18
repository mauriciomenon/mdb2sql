// Linux: X11 primeiro, Wayland so como reserva, com aviso na abertura (REGRA_X11 do dono)
// !T: Pure decision (testable anywhere); main applies it on Linux before GTK starts (wails.Run)

package main

import (
	"bufio"
	"fmt"
	"os"
	"runtime"
	"strings"

	"mdb2sql/i18n"
)

// displayHelp is the "Linux: X11 e Wayland" section of this stack's README
const displayHelp = "https://github.com/mauriciomenon/mdb2sql/blob/master/go_wails_react/README.md#linux-x11-e-wayland"

// displayPlan: backend = value for GDK_BACKEND ("" = leave it), warn = startup warning, fatal = no display at all
type displayPlan struct {
	backend string
	warn    *DisplayWarning
	fatal   string
}

// x11Install returns the command that installs the X server for Wayland sessions (XWayland) on the distribution
// of os-release ("" when the family is unknown) and the distribution's name
func x11Install(osRelease string) (cmd, name string) {
	fields := map[string]string{}
	sc := bufio.NewScanner(strings.NewReader(osRelease))
	for sc.Scan() {
		if k, v, ok := strings.Cut(strings.TrimSpace(sc.Text()), "="); ok {
			fields[k] = strings.Trim(v, `"'`)
		}
	}
	name = fields["PRETTY_NAME"]
	if name == "" {
		name = "Linux"
	}
	for _, id := range strings.Fields(fields["ID"] + " " + fields["ID_LIKE"]) {
		switch id {
		case "debian", "ubuntu":
			return "sudo apt install xwayland", name
		case "fedora", "rhel", "centos":
			return "sudo dnf install xorg-x11-server-Xwayland", name
		case "arch":
			return "sudo pacman -S xorg-xwayland", name
		case "opensuse", "suse", "opensuse-leap", "opensuse-tumbleweed", "sles":
			return "sudo zypper install xwayland", name
		}
	}
	return "", name
}

// planDisplay decides the GTK backend: what the user set wins; else X11 first with Wayland as fallback, and a
// warning when X11 is missing (no DISPLAY: XWayland or the X server is not there). The X11 libraries come with
// GTK itself, so the only thing that can be missing is the X server.
func planDisplay(getenv func(string) string, osRelease string) displayPlan {
	if getenv("GDK_BACKEND") != "" {
		return displayPlan{}
	}
	if getenv("DISPLAY") != "" {
		return displayPlan{backend: "x11,wayland"}
	}
	if getenv("WAYLAND_DISPLAY") == "" {
		return displayPlan{fatal: i18n.T("display.none")}
	}
	cmd, name := x11Install(osRelease)
	return displayPlan{backend: "x11,wayland", warn: &DisplayWarning{
		Text:    i18n.T("display.wayland"),
		Missing: i18n.T("display.missing", i18n.T("display.missingServer")),
		Distro:  name,
		Command: cmd,
		Help:    displayHelp,
	}}
}

// DisplayWarning is the startup warning (3 short lines, a Help link and a command to copy); the UI shows it
type DisplayWarning struct {
	Text    string `json:"text"`    // "X11 unavailable; using Wayland."
	Missing string `json:"missing"` // "Missing: X server"
	Distro  string `json:"distro"`  // PRETTY_NAME of os-release
	Command string `json:"command"` // "" when the distribution family is unknown
	Help    string `json:"help"`    // README section, opened in the browser
}

// Lines is the warning as plain text (terminal and log)
func (w *DisplayWarning) Lines() string {
	s := w.Text + "\n" + w.Missing
	if w.Command != "" {
		s += "\n" + w.Distro + ": " + w.Command
	}
	return s
}

// DisplayWarning is the startup warning about the display mode (nil = none); the UI shows it and logs it
func (a *App) DisplayWarning() *DisplayWarning { return a.displayWarn }

// applyDisplay runs on Linux before GTK starts: sets GDK_BACKEND, keeps the warning for the UI (and stderr), and
// leaves with an error when there is no display at all
func applyDisplay(a *App) {
	if runtime.GOOS != "linux" {
		return
	}
	rel, _ := os.ReadFile("/etc/os-release")
	p := planDisplay(os.Getenv, string(rel))
	if p.fatal != "" {
		fmt.Fprintln(os.Stderr, "mdb2sql: "+p.fatal)
		os.Exit(1)
	}
	if p.backend != "" {
		os.Setenv("GDK_BACKEND", p.backend)
	}
	if a.displayWarn = p.warn; p.warn != nil {
		fmt.Fprintln(os.Stderr, "mdb2sql: "+strings.ReplaceAll(p.warn.Lines(), "\n", "\nmdb2sql: ")+"\nmdb2sql: "+p.warn.Help)
	}
}
