# Prepara o que o build do app Tauri precisa e nao vem do sistema, em versoes fixas.
# Chamado por ..\build_w11_amd64.ps1; sozinho: pwsh -NoProfile -File scripts/setup_tools.ps1
# Fica no sistema (ver README): rustup, MSVC Build Tools + Windows SDK, Node.js, WebView2.
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot)

$TauriCliVersion = '2.12.4'  # crates.io, 2026-10-21; mesma serie do crate tauri 2.12 do Cargo.lock
# pnpm: ultima versao (2026-11-22), a mesma do packageManager de ui/package.json; sha256 publicado no release
$PnpmVersion = '12.23.0'
$PnpmSha256 = '1a954bdc1b15ff036294279391d01a09407b7d46ff972a59d81f23becce96c1c'

foreach ($tool in 'rustup', 'cargo', 'node') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool nao encontrado no PATH (pre-requisito do sistema)" }
}

# instala o compilador fixado em rust-toolchain.toml (sem argumentos o rustup le esse arquivo)
rustup toolchain install
if ($LASTEXITCODE) { throw "rustup toolchain install falhou ($LASTEXITCODE)" }

# tauri-cli compilado do codigo do crates.io em .tools\bin\cargo-tauri.exe; --locked usa o Cargo.lock publicado
# com o crate e o cargo confere o sha256 de cada dependencia contra o indice do crates.io
cargo install --root .tools tauri-cli --version $TauriCliVersion --locked
if ($LASTEXITCODE) { throw "cargo install tauri-cli falhou ($LASTEXITCODE)" }

# pnpm em .tools\pnpm (o Tauri chama "pnpm" no build)
$pnpmDir = '.tools\pnpm'
if (-not (Test-Path "$pnpmDir\.installed-$PnpmSha256")) {
    $zip = '.tools\pnpm-win32-x64.zip'
    New-Item -ItemType Directory -Force .tools | Out-Null
    Invoke-WebRequest "https://github.com/pnpm/pnpm/releases/download/v$PnpmVersion/pnpm-win32-x64.zip" -OutFile $zip
    $hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
    if ($hash -ne $PnpmSha256) { Remove-Item $zip; throw "sha256 de pnpm-win32-x64.zip $PnpmVersion errado: $hash" }
    Remove-Item -Recurse -Force $pnpmDir -ErrorAction Ignore
    New-Item -ItemType Directory $pnpmDir | Out-Null
    & (Join-Path $env:SystemRoot 'System32\tar.exe') -xf $zip -C $pnpmDir
    if ($LASTEXITCODE) { throw "extracao de pnpm-win32-x64.zip falhou" }
    Remove-Item $zip
    New-Item -ItemType File "$pnpmDir\.installed-$PnpmSha256" | Out-Null
}
. (Join-Path $PSScriptRoot 'env_w11.ps1')  # pnpm de .tools no PATH, com store e cache em .tools

# dependencias do frontend nas versoes exatas do pnpm-lock.yaml (o workspace pnpm fica na raiz do repositorio)
pnpm --dir .. install --frozen-lockfile --filter mdb2sql-ui
if ($LASTEXITCODE) { throw "pnpm install falhou ($LASTEXITCODE)" }

# mdbtools estatico (reserva para .mdb/.accdb sem o driver ODBC do Access): o exe embute mdb-tables, mdb-schema e
# mdb-export de .tools\mdbtools-1.0.1-w11-amd64\ (include_bytes! em src\backend\access.rs)
$MdbtoolsZip = 'mdbtools-1.0.1-w11-amd64.zip'
$MdbtoolsSha256 = 'e15c69b9da2f8218f8c1db18fe0147d242cb888522d6c481e8c7c9d97e0405de'
$zipPath = Join-Path '.tools' $MdbtoolsZip
if (-not (Test-Path $zipPath)) {
    New-Item -ItemType Directory -Force .tools | Out-Null
    try {
        Invoke-WebRequest "https://github.com/mauriciomenon/mdbtools_custom/releases/download/win-static-1.0.1/$MdbtoolsZip" -OutFile $zipPath
    } catch {
        # repositorio privado: o download anonimo da 404; o gh usa o login do dono
        gh release download win-static-1.0.1 -R mauriciomenon/mdbtools_custom -p $MdbtoolsZip -D .tools --clobber
        if ($LASTEXITCODE) { throw "download de $MdbtoolsZip falhou (sem acesso anonimo nem gh logado)" }
    }
}
$hash = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToLower()
if ($hash -ne $MdbtoolsSha256) { Remove-Item $zipPath; throw "sha256 de $MdbtoolsZip errado: $hash" }
Expand-Archive -Force $zipPath .tools

& .tools\bin\cargo-tauri.exe tauri --version
