// NIVEL BASICO: Script de build Tauri
// NIVEL TECNICO: Generates necessary Tauri context at compile time

use std::path::Path;

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

    // commit (hash completo) e data dele para o Sobre, gravados pelos scripts de build (secao 18 b: "commit <hash> -
    // <AAAA-MM-DD>"); fora do build oficial: "dev"
    println!("cargo:rerun-if-env-changed=MDB2SQL_COMMIT");
    println!("cargo:rerun-if-env-changed=MDB2SQL_COMMIT_DATE");
    let label = match (std::env::var("MDB2SQL_COMMIT"), std::env::var("MDB2SQL_COMMIT_DATE")) {
        (Ok(c), Ok(d)) if c.len() == 40 && !d.is_empty() => format!("commit {c} - {d}"),
        _ => "dev".to_string(),
    };
    println!("cargo:rustc-env=BUILD_LABEL={label}");

    embedded_mdbtools();
    tauri_build::build()
}

// mdbtools embutido no exe: .tools/mdbtools-1.0.1-w11-amd64/ (Windows, scripts/setup_tools.ps1) ou
// .tools/mdbtools-1.0.1-linux-amd64/ (Debian, scripts/build_debian.sh). Com a pasta: cfg mdbtools_embedded e
// MDBTOOLS_DIR para o include_bytes! de access.rs. Sem ela o app usa o mdbtools do PATH; os builds oficiais
// pedem MDB2SQL_REQUIRE_MDBTOOLS=1 e param aqui se faltar.
fn embedded_mdbtools() {
    println!("cargo:rustc-check-cfg=cfg(mdbtools_embedded)");
    println!("cargo:rerun-if-env-changed=MDB2SQL_REQUIRE_MDBTOOLS");
    let var = |name: &str| std::env::var(name).unwrap_or_default();
    let os = match var("CARGO_CFG_TARGET_OS").as_str() {
        "windows" => "w11".to_string(),
        other => other.to_string(),
    };
    let arch = match var("CARGO_CFG_TARGET_ARCH").as_str() {
        "x86_64" => "amd64".to_string(),
        other => other.to_string(),
    };
    let dir = Path::new(&var("CARGO_MANIFEST_DIR")).join(".tools").join(format!("mdbtools-1.0.1-{os}-{arch}"));
    let exe = if os == "w11" { "mdb-export.exe" } else { "mdb-export" };
    println!("cargo:rerun-if-changed={}", dir.join(exe).display());
    if dir.join(exe).is_file() {
        println!("cargo:rustc-cfg=mdbtools_embedded");
        println!("cargo:rustc-env=MDBTOOLS_DIR={}", dir.display());
    } else if var("MDB2SQL_REQUIRE_MDBTOOLS") == "1" {
        panic!("{} nao existe: rode o setup do build (scripts/setup_tools.ps1 ou scripts/build_debian.sh)", dir.display());
    }
}
