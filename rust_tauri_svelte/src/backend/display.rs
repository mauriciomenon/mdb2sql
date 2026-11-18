// NIVEL BASICO: Linux: X11 primeiro, Wayland so como reserva (regra do dono, REGRA_X11)
// Antes do GTK iniciar: GDK_BACKEND definido pelo usuario e respeitado; senao vale "x11,wayland". Sem X11 (DISPLAY
// ausente ou o servidor X local nao existe) o GTK cai no Wayland e a interface mostra um aviso com o comando de
// instalacao da distro. Sem X11 e sem Wayland: erro no terminal e saida com codigo 1.
// NIVEL TECNICO: decide() is pure (environment, os-release text and an X socket probe come in), so it is unit
// tested; the GTK/WebKitGTK libraries themselves are dependencies of the .deb, only the X server can be missing.

// fora do Linux so os testes usam a decisao
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use serde::Serialize;

pub const BACKENDS: &str = "x11,wayland";
// secao do README com a tabela de pacotes por distro
pub const HELP_LINK: &str = "https://github.com/mauriciomenon/mdb2sql/blob/master/rust_tauri_svelte/README.md#linux-x11-e-wayland";

// NIVEL BASICO: Dados do aviso; a interface monta a frase no idioma escolhido
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct DisplayWarning {
    // "no_display" (DISPLAY nao definido) ou "no_server" (nada respondendo no DISPLAY)
    pub missing: &'static str,
    pub display: String,
    pub distro: String,
    // comando da familia da distro; None em distro desconhecida
    pub command: Option<&'static str>,
    pub link: &'static str,
}

#[derive(Debug, PartialEq)]
pub enum Decision {
    // nada a fazer: o usuario escolheu o backend
    UserChoice,
    // definir GDK_BACKEND; Some(aviso) quando o X11 falta e o Wayland vai ser usado
    Use { backend: &'static str, warning: Option<DisplayWarning> },
    // sem X11 e sem Wayland
    NoDisplay,
}

// valor de um campo do /etc/os-release (sem aspas)
fn os_field(os_release: &str, key: &str) -> String {
    os_release
        .lines()
        .find_map(|line| line.strip_prefix(key)?.strip_prefix('='))
        .map(|v| v.trim().trim_matches('"').trim_matches('\'').to_string())
        .unwrap_or_default()
}

// comando que instala o servidor X (XWayland) pela familia da distro (ID e ID_LIKE)
pub(crate) fn install_command(os_release: &str) -> Option<&'static str> {
    let ids = format!("{} {}", os_field(os_release, "ID"), os_field(os_release, "ID_LIKE")).to_ascii_lowercase();
    let has = |name: &str| ids.split_whitespace().any(|id| id == name || id.starts_with(name));
    if has("debian") || has("ubuntu") {
        Some("sudo apt install xwayland")
    } else if has("fedora") || has("rhel") || has("centos") {
        Some("sudo dnf install xorg-x11-server-Xwayland")
    } else if has("arch") {
        Some("sudo pacman -S xorg-xwayland")
    } else if has("opensuse") || has("suse") {
        Some("sudo zypper install xwayland")
    } else {
        None
    }
}

// socket local do DISPLAY ":N" ou ":N.M"; None para DISPLAY remoto (host:N), que nao da para testar aqui
pub(crate) fn x_socket(display: &str) -> Option<String> {
    let number = display.strip_prefix(':')?.split('.').next()?;
    number.parse::<u32>().ok().map(|n| format!("/tmp/.X11-unix/X{n}"))
}

// NIVEL BASICO: A decisao. env(nome) = valor nao vazio da variavel; x_alive(socket) = o servidor X existe
pub fn decide(env: &dyn Fn(&str) -> Option<String>, os_release: &str, x_alive: &dyn Fn(&str) -> bool) -> Decision {
    if env("GDK_BACKEND").is_some() {
        return Decision::UserChoice;
    }
    let display = env("DISPLAY");
    let missing = match &display {
        None => Some("no_display"),
        Some(d) => match x_socket(d) {
            Some(socket) if !x_alive(&socket) => Some("no_server"),
            _ => None,
        },
    };
    let Some(missing) = missing else {
        return Decision::Use { backend: BACKENDS, warning: None };
    };
    if env("WAYLAND_DISPLAY").is_none() {
        return Decision::NoDisplay;
    }
    let distro = Some(os_field(os_release, "PRETTY_NAME")).filter(|p| !p.is_empty()).unwrap_or_else(|| "Linux".into());
    Decision::Use {
        backend: BACKENDS,
        warning: Some(DisplayWarning {
            missing,
            display: display.unwrap_or_default(),
            distro,
            command: install_command(os_release),
            link: HELP_LINK,
        }),
    }
}

// NIVEL BASICO: Aplica a decisao no proprio processo, antes do GTK; devolve o aviso para a interface
#[cfg(target_os = "linux")]
pub fn apply() -> Option<DisplayWarning> {
    let env = |name: &str| std::env::var(name).ok().filter(|v| !v.is_empty());
    let os_release = std::fs::read_to_string("/etc/os-release").unwrap_or_default();
    match decide(&env, &os_release, &|socket| std::path::Path::new(socket).exists()) {
        Decision::UserChoice => None,
        Decision::Use { backend, warning } => {
            // main(), antes de qualquer thread: ninguem le o ambiente ao mesmo tempo
            unsafe { std::env::set_var("GDK_BACKEND", backend) };
            if let Some(w) = &warning {
                eprintln!("mdb2sql: X11 unavailable ({}); using Wayland (fallback). Help: {}", w.missing, w.link);
            }
            warning
        }
        Decision::NoDisplay => {
            eprintln!(
                "mdb2sql: no display: X11 (DISPLAY) and Wayland (WAYLAND_DISPLAY) are both unavailable. Help: {HELP_LINK}"
            );
            std::process::exit(1);
        }
    }
}

#[cfg(not(target_os = "linux"))]
pub fn apply() -> Option<DisplayWarning> {
    None
}
