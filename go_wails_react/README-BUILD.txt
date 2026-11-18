MDB2SQL (Go + Wails + React) - BUILD, PRODUTOS E LIMPEZA
=========================================================
Guia pratico de build desta pasta. O README.md descreve o app; este arquivo diz qual comando rodar e onde
fica cada coisa. Versao: info.productVersion em wails.json (fonte unica).


1. REGRAS
---------
- Um comando por sistema e arquitetura. Ele faz tudo: limpa, baixa as ferramentas fixas para .tools\,
  compila, roda os testes, gera os produtos e so no fim troca dist\<os>\<arch>\. Se algo falhar, os
  produtos anteriores ficam intactos em dist\.
- Ele imprime "Source: <tag>-<n>-g<commit>[-dirty]": esse e o commit que esta dentro do produto.
  Para release, commite antes (o build Debian recusa arvore suja, codigo 2).
- Numero do build = git rev-list --count HEAD; data = dia do build. Os dois vao para o binario
  (-ldflags -X) e aparecem em Ajuda > Sobre ("build dev" fora destes comandos).
- Sem build cruzado: cada pacote e gerado no proprio sistema/arquitetura.
- Codigos de saida: 0 ok, 1 falha de build/teste/varredura, 2 maquina ou pasta errada / arvore suja,
  3 ferramenta ou pacote do sistema faltando (Debian).


2. "MAKE" - BUILD COMPLETO
--------------------------
  Windows 11 amd64   pwsh -NoProfile -File build_w11_amd64.ps1          -> dist\w11\amd64\
  Debian 13 amd64    pwsh -NoProfile -File build_debian_amd64_wsl.ps1   -> dist\debian\amd64\   (pelo WSL)
                     ./build_debian_amd64.sh  (numa maquina Debian, clone em disco Linux)  -> dist/debian/amd64/
  Arch, macOS, FreeBSD/OpenBSD: sem comando nesta versao (fica para a proxima rodada).

  build_debian_amd64_wsl.ps1 mantem um clone em ~/src/mdb2sql-go_wails_react no disco do Linux do WSL (nunca em
  /mnt/c), poe nele o MESMO commit do Windows, roda build_debian_amd64.sh e copia dist/debian/amd64 de volta,
  conferindo o sha256 de cada arquivo.

Requisitos (Windows):
  No sistema: Node.js 22+ e pnpm (workspace pnpm da raiz do repositorio, pnpm-lock.yaml unico),
              WebView2 Runtime (parte do Windows 11), git. gh (GitHub CLI logado) so se o release do
              mdbtools_custom continuar privado (o curl recebe 404 e o script tenta o gh).
  Baixados para .tools\ pelo proprio comando (sha256 conferido), cerca de 1,4 GB:
    .tools\go          Go 1.26.10 (zip oficial de go.dev)
    .tools\winlibs     GCC 16.2.0 MinGW-w64 14.0.0 UCRT r3 (WinLibs), exigido pelo cgo do duckdb-go
    .tools\bin         Wails CLI 2.13.0 (go install; hash do modulo conferido pelo sum.golang.org)
    .tools\nsis        NSIS 3.12 (makensis, para o instalador)
    .tools\mdbtools    mdbtools 1.0.1 estatico (release win-static-1.0.1 de mdbtools_custom)
    .tools\duckdb-ext  extensao sqlite do DuckDB v2.0.0 windows_amd64_mingw (.gz)
  Sem .tools\ o build usa go/wails do PATH (GOTOOLCHAIN=go1.26.11), o GCC de MDB2SQL_GCC_BIN e o
  makensis do PATH; mdbtools e a extensao sao obrigatorios (vao para dentro do exe).

Requisitos (Debian 13 amd64):
  No sistema (uma vez, com root): sudo apt install build-essential pkg-config libgtk-3-dev
              libwebkit2gtk-4.1-dev dpkg-dev zip curl nodejs        (Node.js 20.19+; o pnpm vem pelo corepack)
  Baixados para .tools/linux/ pelo proprio comando (sha256 conferido):
    go/            Go 1.26.10 (tar.gz oficial de go.dev)
    bin/wails      Wails CLI 2.13.0 (go install); bin/pnpm chama "corepack pnpm" (versao de frontend/package.json)
    mdbtools/      mdbtools_1.0.1-0.1 e libmdb3t64_1.0.1-0.1 do Debian 13 (deb.debian.org, extraidos sem root)
    downloads/     os .deb, o tar.gz do Go
  A extensao sqlite do DuckDB v2.0.0 linux_amd64 vai direto para backend/embedded/ (sha256 conferido).
  wails build usa a tag webkit2_41 (o Debian 13 so tem WebKitGTK 4.1).

Dependencias de execucao do .deb (Depends gerado pelo dpkg-shlibdeps do binario e do mdb-export embutido):
  libgtk-3-0t64, libwebkit2gtk-4.1-0, libjavascriptcoregtk-4.1-0, libsoup-3.0-0, libglib2.0-0t64, libgdk-pixbuf-2.0-0,
  libc6 (a lista exata sai no fim do build: "Depends: ..."). O .zip precisa das mesmas bibliotecas
  (sudo apt install libgtk-3-0t64 libwebkit2gtk-4.1-0). DuckDB, mdbtools (com libmdb.so.3) e a extensao sqlite
  estao dentro do binario.


3. "MAKE CLEAN" - LIMPAR
------------------------
  Windows:  .\clean.ps1          apaga o gerado em build\ (fica o icone), frontend\dist\, dist\.stage\ e as copias em backend\embedded\
            .\clean.ps1 -Dist    idem e tambem dist\ (todos os produtos)
  Linux:    ./clean.sh           idem
            ./clean.sh --dist    idem e tambem dist/
  .tools\ nunca e apagado; apague a mao para forcar novo download.
  O build completo (secao 2) ja comeca limpo (um frontend\dist antigo seria embutido no lugar da UI nova).
  Na maquina do usuario o app cria so:
    %LOCALAPPDATA%\mdb2sql\go-wails-react-<versao>-<build>\   mdbtools e extensao sqlite (extraidos ao usar;
                                                             pastas de builds antigos sao apagadas)
    %LOCALAPPDATA%\mdb2sql\converted-go-wails-react\<pid>\   SQLite convertido de um Access ate o usuario salvar
                                                             ou apagar (apagado ao sair; sobra de queda e apagada
                                                             na proxima abertura)
    %LOCALAPPDATA%\mdb2sql\go-wails-react-webview\           dados do WebView2
    %APPDATA%\mdb2sql\go-wails-react.json                    tema, idioma e ultima pasta usada
  Linux: ~/.cache/mdb2sql/ e ~/.config/mdb2sql/ no lugar de %LOCALAPPDATA% e %APPDATA%.


4. ONDE FICA CADA PRODUTO
-------------------------
Windows - dist\w11\amd64\
  mdb2sql-<versao>-w11-amd64-go-wails-react.exe
      EXECUTAVEL unico: DuckDB linkado estaticamente, UI no WebView2 do Windows, mdbtools e extensao sqlite
      embutidos; duplo clique, sem instalar.
  mdb2sql-<versao>-w11-amd64-go-wails-react.zip
      ZIP da pasta do app: mdb2sql-<versao>-w11-amd64-go-wails-react\mdb2sql.exe + LEIAME.txt + LICENSE.
  mdb2sql-<versao>-w11-amd64-go-wails-react-installer.exe
      INSTALADOR NSIS (Program Files, atalhos, desinstalador, instala o WebView2 se faltar; instala o LICENSE).
Debian - dist\debian\amd64\
  mdb2sql-<versao>-debian-amd64-go-wails-react.deb
      PACOTE: /usr/bin/mdb2sql-go-wails-react, entrada de menu, icone, README.md, LICENSE e copyright em
      /usr/share/doc/mdb2sql-go-wails-react/. sudo apt install ./<arquivo>.deb
  mdb2sql-<versao>-debian-amd64-go-wails-react.zip
      ZIP da pasta do app: mdb2sql + README.md + LICENSE.
  SHA256SUMS.txt


5. PASTAS DE TRABALHO (podem ser apagadas; o build recria)
----------------------------------------------------------
  build\bin\          saida do wails build (mdb2sql.exe, mdb2sql-amd64-installer.exe; Linux: mdb2sql)
  build\windows\      manifesto e projeto NSIS gerados pelo Wails a partir dos modelos dele
  build\appicon.png, build\windows\icon.ico   icone do app (versionados, nao sao apagados): exe, janela,
                      instalador, atalhos e icone do .deb
  frontend\dist\      saida do Vite, embutida no binario (go:embed)
  backend\embedded\   copias de .tools embutidas no binario (go:embed; no git so o .gitkeep)
  dist\.stage\        produtos sendo montados antes de irem para dist\<os>\amd64\
  .tools\             ferramentas fixadas (Windows) e .tools\linux\ (Debian)
  Tudo isso esta no .gitignore.


6. CADEIA DE SCRIPTS
--------------------
  build_w11_amd64.ps1
   -> clean.ps1
   -> scripts\setup_tools.ps1   ferramentas em .tools\ (versoes e sha256 no topo do script)
   -> scripts\build_w11.ps1     copia mdbtools/extensao para backend\embedded\,
                                wails build -clean -trimpath -nsis -ldflags (numero e data do build)
   -> scripts\test_w11.ps1      go test ./... e vitest (frontend)
   -> scripts\package_w11.ps1   exe unico, zip e instalador com os nomes finais em dist\w11\amd64\
  build_debian_amd64_wsl.ps1 (Windows) -> WSL: build_debian_amd64.sh -> scripts/build_debian.sh
                                ferramentas (versoes e sha256 no topo), clean.sh, mdbtools/extensao para
                                backend/embedded/, wails build -tags webkit2_41, go test, vitest, varredura
                                de dados pessoais no binario e no .deb, .zip e .deb
  scripts\env_w11.ps1: poe Go, GCC, Wails e NSIS no PATH (dot-source).
  scripts\make_test_mdb.ps1: gera backend\testdata\types.mdb (Windows com ACE OLEDB; o arquivo e versionado).


7. DESENVOLVIMENTO (nao usar para release)
------------------------------------------
  . scripts\env_w11.ps1; wails dev
  . scripts\env_w11.ps1; go test ./...; pnpm --dir frontend exec vitest run
  (go test precisa de frontend\dist e backend\embedded: rode um build antes)
  Conferencia com os bancos reais (lenta, ~10 min: dois .accdb, cada um por mdbtools e por ODBC):
    $env:MDB2SQL_TEST_DB_DIR = '<pasta com COPIAS de "<base>".accdb e das referencias "<base>".sqlite/.duckdb>'
    go test ./backend -run RealDB -v -timeout 60m
  Forcar o leitor Access: $env:MDB2SQL_ACCESS_READER = 'mdbtools'   (ou 'odbc')
