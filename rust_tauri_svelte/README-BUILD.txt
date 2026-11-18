MDB2SQL (Rust + Tauri 2 + Svelte) - BUILD, PRODUTOS E LIMPEZA
==============================================================
Guia pratico de build desta pasta. O README.md descreve o app e como usar; este arquivo diz qual comando
rodar e onde fica cada coisa. Versao: "version" em Cargo.toml (fonte unica; cargo test confere ui/package.json).


1. REGRAS
---------
- Um comando por sistema e arquitetura, rodado nesta pasta. Ele faz tudo: limpa, prepara as ferramentas
  fixas, compila, roda os testes, gera os produtos e so no fim troca dist\<os>\<arch>\.
  Se algo falhar, os produtos anteriores ficam intactos em dist\.
- Ele imprime "Source: <tag>-<n>-g<commit>[-dirty]": esse e o commit que esta dentro do produto.
  Para release, commite antes (sem "-dirty"). O About mostra "build <n> (<data>)", com
  n = git rev-list --count HEAD e a data do build (scripts\env_w11.ps1); fora do comando, "build dev".
- Sem build cruzado: cada pacote e gerado no proprio sistema/arquitetura.
- Use sempre o comando (ou cargo tauri build): um "cargo build --release" puro gera um exe que procura o
  servidor de desenvolvimento e abre uma janela vazia.
- Codigos de saida: 0 ok, 1 falha de build/teste, 2 maquina errada (nao e Windows amd64).
- Rode cada build num pwsh novo (pwsh -NoProfile -File ...).


2. "MAKE" - BUILD COMPLETO
--------------------------
  Windows 11 amd64   pwsh -NoProfile -File build_w11_amd64.ps1        -> dist\w11\amd64\
  Debian 13 amd64    pwsh -NoProfile -File build_debian_amd64_wsl.ps1 -> dist\debian\amd64\  (pelo WSL)
                     ou, num clone no disco do Linux: ./build_debian_amd64.sh -> dist/debian/amd64/
  macOS, Arch, BSD   sem script nesta versao (fica para a proxima rodada; nada testado).

Requisitos (Debian 13 amd64, no Linux ou no WSL):
  No sistema: git, curl, rustup, Node.js >= 20.19 (traz o corepack), gcc/make (build-essential), zip,
              dpkg-dev e as bibliotecas de desenvolvimento do Tauri:
                sudo apt install build-essential pkg-config libwebkit2gtk-4.1-dev libgtk-3-dev \
                    libsoup-3.0-dev librsvg2-dev libxdo-dev libssl-dev dpkg-dev zip
              Falta algum: o script diz qual e sai com codigo 3.
  Preparados pelo comando (scripts/build_debian.sh), na pasta .tools/ do clone Linux:
    Rust 1.99.1              rust-toolchain.toml (rustup)
    .tools/bin/cargo-tauri   tauri-cli 2.12.4, cargo install --locked
    .tools/bin/pnpm          pnpm da versao do ui/package.json pelo corepack
    .tools/mdbtools-1.0.1-linux-amd64/
                             mdbtools 1.0.1 compilado do fonte oficial (github.com/mdbtools/mdbtools, release
                             v1.0.1, mdbtools-1.0.1.tar.gz, sha256 ff9c425a88bc20bf9318a332eec50b17e77896eef65a0e69415ccb4e396d1812
                             conferido), estatico e sem GLib (so depende da libc); vai para dentro do binario
  Produto .deb: Depends libwebkit2gtk-4.1-0 e libgtk-3-0 (o apt instala); nao depende de mdbtools nem de unixODBC.
  Debian pelo WSL: o build_debian_amd64_wsl.ps1 clona o repositorio em ~/src/mdb2sql-rust-tauri-svelte (disco do
  Linux, nunca /mnt/c), poe o mesmo commit do Windows, roda o build la e traz dist/debian/amd64 conferindo sha256.
  Os pacotes do sistema acima tem de estar instalados no WSL antes (sudo apt install ...).

Requisitos (Windows):
  No sistema: rustup, Visual Studio Build Tools (C++ + Windows SDK: link.exe e o cl.exe que compila o
              DuckDB e o SQLite embutidos), Node.js + pnpm, WebView2 Runtime, gh logado (so se o download
              anonimo do mdbtools falhar: o repositorio mdbtools_custom e privado).
  Preparados pelo comando:
    Rust 1.99.1              rust-toolchain.toml, instalado pelo rustup (assinatura conferida)
    .tools\bin\cargo-tauri   tauri-cli 2.12.4, cargo install --locked (sha256 de cada crate conferido)
    .tools\mdbtools-1.0.1-w11-amd64\
                             mdbtools estatico (release win-static-1.0.1 do mdbtools_custom, arquivo
                             mdbtools-1.0.1-w11-amd64.zip, sha256 e15c69b9da2f8218f8c1db18fe0147d242cb888522d6c481e8c7c9d97e0405de
                             conferido); mdb-tables, mdb-schema, mdb-export, COPYING, COPYING.LIB e VERSION.txt vao
                             para dentro do exe (include_bytes! em src\backend\access.rs)
    node_modules             pnpm install --frozen-lockfile (pnpm-lock.yaml da raiz)
    NSIS e WiX               baixados pelo tauri-cli para %LOCALAPPDATA%\tauri na 1a vez (hash conferido)
  O build demora (~10 min): o DuckDB (C++) leva varios minutos e o clean apaga target\.
  Sem .tools\mdbtools-1.0.1-w11-amd64\ o cargo nao compila: rode scripts\setup_tools.ps1 uma vez.


3. "MAKE CLEAN" - LIMPAR
------------------------
  Windows:  .\clean.ps1          apaga target\, ui\dist\, dist\.stage\
            .\clean.ps1 -Dist    idem e tambem dist\ (todos os produtos)
  Linux:    ./clean.sh           idem
            ./clean.sh --dist    idem e tambem dist/
  .tools\ nunca e apagado; apague a mao para forcar nova instalacao do tauri-cli e do mdbtools.
  O build completo (secao 2) ja comeca limpo.
  Na maquina de quem usa o app: %LOCALAPPDATA%\mdb2sql\rust-tauri-svelte-<versao>\ (mdbtools extraido) e
  %LOCALAPPDATA%\com.mdb2sql.app\ (WebView2 e preferencias) podem ser apagados; o app recria.


4. ONDE FICA CADA PRODUTO
-------------------------
Windows - dist\w11\amd64\
  mdb2sql-<versao>-w11-amd64-rust-tauri-svelte.exe
      EXECUTAVEL unico: UI, DuckDB, SQLite e mdbtools dentro, janela no WebView2 do Windows; duplo clique,
      sem instalar. Unica pasta que ele cria: %LOCALAPPDATA%\mdb2sql\rust-tauri-svelte-<versao>\mdbtools
      (ao abrir Access; versoes antigas sao apagadas) e %TEMP%\mdb2sql-rust-tauri-svelte (SQLite convertido),
      alem dos dados do WebView2.
  mdb2sql-<versao>-w11-amd64-rust-tauri-svelte.zip
      ZIP da pasta do app: mdb2sql-<versao>-w11-amd64-rust-tauri-svelte\mdb2sql.exe, README.md e LICENSE.
  mdb2sql-<versao>-w11-amd64-rust-tauri-svelte-installer.exe
      INSTALADOR NSIS (gerado pelo Tauri; por usuario, sem administrador; instala o WebView2 se faltar;
      o LICENSE vai junto na pasta do app, como no MSI).
  mdb2sql-<versao>-w11-amd64-rust-tauri-svelte-installer.msi
      INSTALADOR MSI (WiX, gerado pelo Tauri; por maquina).

Debian - dist/debian/amd64/ (dist\debianmd64\ no Windows, pelo WSL)
  mdb2sql-<versao>-debian-amd64-rust-tauri-svelte.deb
      PACOTE .deb (gerado pelo Tauri): /usr/bin/mdb2sql, atalho no menu, LICENSE em /usr/lib/MDB2SQL/ e
      /usr/share/doc/mdb2sql/copyright. Depends: libwebkit2gtk-4.1-0, libgtk-3-0. mdbtools dentro do binario.
  mdb2sql-<versao>-debian-amd64-rust-tauri-svelte.zip
      ZIP: mdb2sql-<versao>-debian-amd64-rust-tauri-svelte/mdb2sql, README.md e LICENSE (precisa do WebKitGTK 4.1).
  SHA256SUMS.txt


5. PASTAS DE TRABALHO (podem ser apagadas; o build recria)
----------------------------------------------------------
  target\          saida do cargo (target\release\mdb2sql.exe, target\release\bundle\nsis|msi\)
  ui\dist\         saida do Vite, embutida no exe
  dist\.stage\     produtos sendo montados antes de irem para dist\w11\amd64\
  .tools\          tauri-cli e mdbtools fixados
  Tudo isso esta no .gitignore.


6. CADEIA DE SCRIPTS
--------------------
  build_w11_amd64.ps1
   -> clean.ps1
   -> scripts\setup_tools.ps1   rustup toolchain install, cargo install tauri-cli, pnpm install, mdbtools
   -> scripts\build_w11.ps1     cargo tauri build (exe + NSIS + MSI)
   -> scripts\test_w11.ps1      cargo test --release e pnpm --filter mdb2sql-ui test
   -> scripts\package_w11.ps1   copia, renomeia e zipa para dist\w11\amd64\
  build_debian_amd64_wsl.ps1 (Windows) -> WSL: ~/src/mdb2sql-rust-tauri-svelte/rust_tauri_svelte/build_debian_amd64.sh
   -> scripts/build_debian.sh   ferramentas, mdbtools do fonte, cargo tauri build --bundles deb, cargo test,
                                pnpm test, varredura de dados pessoais (binario e .deb), .deb + .zip
  scripts\make_test_mdb.ps1: gera tests\data\sample.mdb (versionado; precisa do Access Database Engine).
  scripts\env_w11.ps1: RUSTFLAGS/CFLAGS que tiram os caminhos locais do binario e o numero/data do build
  (dot-source; build e teste usam as mesmas variaveis para nao recompilar).
  Configuracao do app e dos instaladores: tauri.conf.json. Permissoes da janela: capabilities\default.json.


7. DESENVOLVIMENTO (nao usar para release)
------------------------------------------
  .tools\bin\cargo-tauri.exe tauri dev     (ou cargo tauri dev)
  cargo test
  pnpm --filter mdb2sql-ui test            (na raiz do repositorio ou aqui)
  Teste com um Access real (fora do git; alguns minutos, mdbtools e ODBC):
    $env:MDB2SQL_TEST_ACCDB  = '<copia>\2026-07-14 DB4.accdb'
    $env:MDB2SQL_TEST_DUCKDB = '<copia>\2026-07-14 DB4.duckdb'    (conversao de referencia)
    $env:MDB2SQL_TEST_SQLITE = '<copia>\2026-07-14 DB4.sqlite'    (opcional)
    cargo test --release real_access -- --nocapture
