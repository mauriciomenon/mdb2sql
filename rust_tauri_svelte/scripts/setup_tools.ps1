# Prepara o que o build do app Tauri precisa e nao vem do sistema, em versoes fixas.
# Chamado por ..\build_w11_amd64.ps1; sozinho: pwsh -NoProfile -File scripts/setup_tools.ps1
# Fica no sistema (ver README): rustup, MSVC Build Tools + Windows SDK, Node.js + pnpm, WebView2.
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot)

$TauriCliVersion = '2.12.4'  # crates.io, 2026-10-21; mesma serie do crate tauri 2.12 do Cargo.lock

foreach ($tool in 'rustup', 'cargo', 'pnpm') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool nao encontrado no PATH (pre-requisito do sistema)" }
}

# instala o compilador fixado em rust-toolchain.toml (sem argumentos o rustup le esse arquivo)
rustup toolchain install
if ($LASTEXITCODE) { throw "rustup toolchain install falhou ($LASTEXITCODE)" }

# tauri-cli compilado do codigo do crates.io em .tools\bin\cargo-tauri.exe; --locked usa o Cargo.lock publicado
# com o crate e o cargo confere o sha256 de cada dependencia contra o indice do crates.io
cargo install --root .tools tauri-cli --version $TauriCliVersion --locked
if ($LASTEXITCODE) { throw "cargo install tauri-cli falhou ($LASTEXITCODE)" }

# dependencias do frontend nas versoes exatas do pnpm-lock.yaml (o workspace pnpm fica na raiz do repositorio)
pnpm --dir .. install --frozen-lockfile --filter mdb2sql-ui
if ($LASTEXITCODE) { throw "pnpm install falhou ($LASTEXITCODE)" }

& .tools\bin\cargo-tauri.exe tauri --version
