// NIVEL BASICO: Script de build Tauri
// NIVEL TECNICO: Generates necessary Tauri context at compile time

fn main() {
    // versao do compilador para o dialogo Sobre ("rustc 1.99.1 (hash data)" -> "1.99.1")
    let rustc = std::env::var("RUSTC").unwrap_or_else(|_| "rustc".into());
    let out = std::process::Command::new(rustc)
        .arg("--version")
        .output()
        .expect("rustc --version");
    let text = String::from_utf8_lossy(&out.stdout);
    let version = text.split_whitespace().nth(1).unwrap_or("unknown");
    println!("cargo:rustc-env=RUSTC_VERSION={version}");

    tauri_build::build()
}
