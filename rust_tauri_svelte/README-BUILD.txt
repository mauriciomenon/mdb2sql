MDB2SQL (Rust + Tauri 2 + Svelte) - BUILD, PRODUTOS E LIMPEZA
==============================================================
Guia pratico de build desta pasta. O README.md descreve o app; este arquivo diz qual comando rodar e onde
fica cada coisa. Versao: "version" em Cargo.toml (fonte unica; cargo test confere ui/package.json).


1. REGRAS
---------
- Um comando por sistema e arquitetura, rodado nesta pasta. Ele faz tudo: limpa, prepara as ferramentas
  fixas, compila, roda os testes, gera os produtos e so no fim troca dist\<os>\<arch>\.
  Se algo falhar, os produtos anteriores ficam intactos em dist\.
- Ele imprime "Source: <tag>-<n>-g<commit>[-dirty]": esse e o commit que esta dentro do produto.
  Para release, commite antes (sem "-dirty").
- Sem build cruzado: cada pacote e gerado no proprio sistema/arquitetura.
- Use sempre o comando (ou cargo tauri build): um "cargo build --release" puro gera um exe que procura o
  servidor de desenvolvimento e abre uma janela vazia.
- Codigos de saida: 0 ok, 1 falha de build/teste, 2 maquina errada (nao e Windows amd64).


2. "MAKE" - BUILD COMPLETO
--------------------------
  Windows 11 amd64   pwsh -NoProfile -File build_w11_amd64.ps1   -> dist\w11\amd64\
  Debian / outros    sem comando de pacote ainda; "cargo tauri build" gera o .deb (docs/SetupDebian.md).

Requisitos (Windows):
  No sistema: rustup, Visual Studio Build Tools (C++ + Windows SDK: link.exe e o cl.exe que compila o
              DuckDB embutido), Node.js + pnpm, WebView2 Runtime.
  Preparados pelo comando:
    Rust 1.99.1              rust-toolchain.toml, instalado pelo rustup (assinatura conferida)
    .tools\bin\cargo-tauri   tauri-cli 2.12.4, cargo install --locked (sha256 de cada crate conferido)
    node_modules             pnpm install --frozen-lockfile (pnpm-lock.yaml da raiz)
    NSIS e WiX               baixados pelo tauri-cli para %LOCALAPPDATA%\tauri na 1a vez (hash conferido)
  O build demora: o DuckDB (C++) leva varios minutos e o clean apaga target\.


3. "MAKE CLEAN" - LIMPAR
------------------------
  Windows:  .\clean.ps1          apaga target\, ui\dist\, dist\.stage\
            .\clean.ps1 -Dist    idem e tambem dist\ (todos os produtos)
  Linux:    ./clean.sh           idem
            ./clean.sh --dist    idem e tambem dist/
  .tools\ nunca e apagado; apague a mao para forcar nova instalacao do tauri-cli.
  O build completo (secao 2) ja comeca limpo.


4. ONDE FICA CADA PRODUTO
-------------------------
Windows - dist\w11\amd64\
  mdb2sql-<versao>-w11-amd64-rust-tauri-svelte.exe
      EXECUTAVEL unico: DuckDB e a UI dentro, janela no WebView2 do Windows; duplo clique, sem instalar.
  mdb2sql-<versao>-w11-amd64-rust-tauri-svelte-installer.exe
      INSTALADOR NSIS (gerado pelo Tauri).
  mdb2sql-<versao>-w11-amd64-rust-tauri-svelte-installer.msi
      INSTALADOR MSI (WiX, gerado pelo Tauri).

Formas Windows hoje: executavel unico e instaladores. O .zip ainda nao existe; entra em
scripts\package_w11.ps1 com o nome mdb2sql-<versao>-w11-amd64-rust-tauri-svelte.zip


5. PASTAS DE TRABALHO (podem ser apagadas; o build recria)
----------------------------------------------------------
  target\          saida do cargo (target\release\mdb2sql.exe, target\release\bundle\nsis|msi\)
  ui\dist\         saida do Vite, embutida no exe
  dist\.stage\     produtos sendo montados antes de irem para dist\w11\amd64\
  .tools\          tauri-cli fixado
  Tudo isso esta no .gitignore.


6. CADEIA DE SCRIPTS
--------------------
  build_w11_amd64.ps1
   -> clean.ps1
   -> scripts\setup_tools.ps1   rustup toolchain install, cargo install tauri-cli, pnpm install
   -> scripts\build_w11.ps1     cargo tauri build (exe + NSIS + MSI)
   -> scripts\test_w11.ps1      cargo test --release e pnpm --filter mdb2sql-ui test
   -> scripts\package_w11.ps1   copia e renomeia para dist\w11\amd64\
  scripts\env_w11.ps1: RUSTFLAGS/CFLAGS que tiram os caminhos locais do binario (dot-source).
  Configuracao do app e dos instaladores: tauri.conf.json.


7. DESENVOLVIMENTO (nao usar para release)
------------------------------------------
  .tools\bin\cargo-tauri.exe tauri dev     (ou cargo tauri dev)
  cargo test
  pnpm --filter mdb2sql-ui test            (na raiz do repositorio ou aqui)
