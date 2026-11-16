MDB2SQL (Go + Wails + React) - BUILD, PRODUTOS E LIMPEZA
=========================================================
Guia pratico de build desta pasta. O README.md descreve o app; este arquivo diz qual comando rodar e onde
fica cada coisa. Versao: info.productVersion em wails.json (fonte unica).


1. REGRAS
---------
- Um comando por sistema e arquitetura, rodado nesta pasta. Ele faz tudo: limpa, baixa as ferramentas
  fixas para .tools\, compila, roda os testes, gera os produtos e so no fim troca dist\<os>\<arch>\.
  Se algo falhar, os produtos anteriores ficam intactos em dist\.
- Ele imprime "Source: <tag>-<n>-g<commit>[-dirty]": esse e o commit que esta dentro do produto.
  Para release, commite antes (sem "-dirty").
- Numero do build = git rev-list --count HEAD; data = dia do build. Os dois vao para o exe
  (-ldflags -X) e aparecem em Ajuda > Sobre ("build dev" fora deste comando).
- Sem build cruzado: cada pacote e gerado no proprio sistema/arquitetura.
- Codigos de saida: 0 ok, 1 falha de build/teste, 2 maquina errada (nao e Windows amd64).


2. "MAKE" - BUILD COMPLETO
--------------------------
  Windows 11 amd64   pwsh -NoProfile -File build_w11_amd64.ps1   -> dist\w11\amd64\
  Debian / outros    sem comando de pacote ainda; "wails build" gera build/bin/mdb2sql (docs/SetupDebian.md).
                     Fora do Windows nao ha ODBC do Access; o leitor Access usa mdb-tools do PATH.

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


3. "MAKE CLEAN" - LIMPAR
------------------------
  Windows:  .\clean.ps1          apaga build\, frontend\dist\, dist\.stage\ e as copias em backend\embedded\
            .\clean.ps1 -Dist    idem e tambem dist\ (todos os produtos)
  Linux:    ./clean.sh           idem
            ./clean.sh --dist    idem e tambem dist/
  .tools\ nunca e apagado; apague a mao para forcar novo download.
  O build completo (secao 2) ja comeca limpo.
  Na maquina do usuario o app cria so:
    %LOCALAPPDATA%\mdb2sql\go-wails-react-<versao>-<build>\   mdbtools e extensao sqlite (extraidos ao usar;
                                                             pastas de builds antigos sao apagadas)
    %LOCALAPPDATA%\mdb2sql\go-wails-react-webview\           dados do WebView2
    %APPDATA%\mdb2sql\go-wails-react.json                    tema e ultima pasta usada


4. ONDE FICA CADA PRODUTO
-------------------------
Windows - dist\w11\amd64\
  mdb2sql-<versao>-w11-amd64-go-wails-react.exe
      EXECUTAVEL unico: DuckDB linkado estaticamente, UI no WebView2 do Windows, mdbtools e extensao sqlite
      embutidos; duplo clique, sem instalar.
  mdb2sql-<versao>-w11-amd64-go-wails-react.zip
      ZIP da pasta do app: mdb2sql-<versao>-w11-amd64-go-wails-react\mdb2sql.exe + LEIAME.txt.
  mdb2sql-<versao>-w11-amd64-go-wails-react-installer.exe
      INSTALADOR NSIS (modelo padrao do Wails: Program Files, atalhos, desinstalador, instala o WebView2
      se faltar).


5. PASTAS DE TRABALHO (podem ser apagadas; o build recria)
----------------------------------------------------------
  build\bin\          saida do wails build (mdb2sql.exe, mdb2sql-amd64-installer.exe)
  build\windows\      icone, manifesto e projeto NSIS gerados pelo Wails a partir dos modelos dele
  frontend\dist\      saida do Vite, embutida no exe (go:embed)
  backend\embedded\   copias de .tools embutidas no exe (go:embed; no git so o .gitkeep)
  dist\.stage\        produtos sendo montados antes de irem para dist\w11\amd64\
  .tools\             Go, GCC, Wails, NSIS, mdbtools e extensao fixados
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
  scripts\env_w11.ps1: poe Go, GCC, Wails e NSIS no PATH (dot-source).


7. DESENVOLVIMENTO (nao usar para release)
------------------------------------------
  . scripts\env_w11.ps1; wails dev
  . scripts\env_w11.ps1; go test ./...; pnpm --dir frontend exec vitest run
  (go test precisa de frontend\dist e backend\embedded: rode um build antes)
  Conferencia com o banco real (lenta, ~2 min):
    $env:MDB2SQL_TEST_DB_DIR = '<pasta com copias de "2026-07-14 DB4".accdb/.sqlite/.duckdb>'
    go test ./backend -run RealDB -v -timeout 30m
  Forcar o leitor Access: $env:MDB2SQL_ACCESS_READER = 'mdbtools'   (ou 'odbc')
