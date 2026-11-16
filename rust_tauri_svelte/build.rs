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

    // numero e data do build para o Sobre, gravados por scripts\env_w11.ps1; fora do build oficial: "build dev"
    println!("cargo:rerun-if-env-changed=MDB2SQL_BUILD_NUMBER");
    println!("cargo:rerun-if-env-changed=MDB2SQL_BUILD_DATE");
    let label = match (std::env::var("MDB2SQL_BUILD_NUMBER"), std::env::var("MDB2SQL_BUILD_DATE")) {
        (Ok(n), Ok(d)) if !n.is_empty() && !d.is_empty() => format!("build {n} ({d})"),
        _ => "build dev".to_string(),
    };
    println!("cargo:rustc-env=BUILD_LABEL={label}");

    tauri_build::build()
}
