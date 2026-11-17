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
  Windows 11 amd64   pwsh -NoProfile -File build_w11_amd64.ps1   -> dist\w11\amd64\
  Debian / outros    sem comando de pacote ainda; "cargo tauri build" gera o .deb (docs/SetupDebian.md);
                     precisa de unixodbc-dev (odbc-api) e usa o mdbtools do sistema (pacote mdbtools).

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
      (so ao abrir Access sem o driver ODBC; versoes antigas sao apagadas) alem dos dados do WebView2.
  mdb2sql-<versao>-w11-amd64-rust-tauri-svelte.zip
      ZIP da pasta do app: mdb2sql-<versao>-w11-amd64-rust-tauri-svelte\mdb2sql.exe, README.md e LICENSE.
  mdb2sql-<versao>-w11-amd64-rust-tauri-svelte-installer.exe
      INSTALADOR NSIS (gerado pelo Tauri; por usuario, sem administrador; instala o WebView2 se faltar;
      o LICENSE vai junto na pasta do app, como no MSI).
  mdb2sql-<versao>-w11-amd64-rust-tauri-svelte-installer.msi
      INSTALADOR MSI (WiX, gerado pelo Tauri; por maquina).


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
  scripts\env_w11.ps1: RUSTFLAGS/CFLAGS que tiram os caminhos locais do binario e o numero/data do build
  (dot-source; build e teste usam as mesmas variaveis para nao recompilar).
  Configuracao do app e dos instaladores: tauri.conf.json. Permissoes da janela: capabilities\default.json.


7. DESENVOLVIMENTO (nao usar para release)
------------------------------------------
  .tools\bin\cargo-tauri.exe tauri dev     (ou cargo tauri dev)
  cargo test
  pnpm --filter mdb2sql-ui test            (na raiz do repositorio ou aqui)
  Teste com um Access real (fora do git; ~2 min, os dois leitores):
    $env:MDB2SQL_TEST_ACCDB  = '<copia>\2026-07-14 DB4.accdb'
    $env:MDB2SQL_TEST_DUCKDB = '<copia>\2026-07-14 DB4.duckdb'
    cargo test --release real_access -- --nocapture
