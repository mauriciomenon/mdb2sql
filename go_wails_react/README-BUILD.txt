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
- Sem build cruzado: cada pacote e gerado no proprio sistema/arquitetura.
- Codigos de saida: 0 ok, 1 falha de build/teste, 2 maquina errada (nao e Windows amd64).


2. "MAKE" - BUILD COMPLETO
--------------------------
  Windows 11 amd64   pwsh -NoProfile -File build_w11_amd64.ps1   -> dist\w11\amd64\
  Debian / outros    sem comando de pacote ainda; "wails build" gera build/bin/mdb2sql (docs/SetupDebian.md).

Requisitos (Windows):
  No sistema: Node.js 22+ e pnpm (workspace pnpm da raiz do repositorio, pnpm-lock.yaml unico),
              WebView2 Runtime (parte do Windows 11).
  Baixados para .tools\ pelo proprio comando (sha256 conferido), cerca de 1,3 GB:
    .tools\go        Go 1.26.10 (zip oficial de go.dev)
    .tools\winlibs   GCC 16.2.0 MinGW-w64 14.0.0 UCRT r3 (WinLibs), exigido pelo cgo do duckdb-go
    .tools\bin       Wails CLI 2.13.0 (go install; hash do modulo conferido pelo sum.golang.org)
  Sem .tools\ o build usa go/wails do PATH (GOTOOLCHAIN=go1.26.11) e o GCC de MDB2SQL_GCC_BIN.


3. "MAKE CLEAN" - LIMPAR
------------------------
  Windows:  .\clean.ps1          apaga build\, frontend\dist\, dist\.stage\
            .\clean.ps1 -Dist    idem e tambem dist\ (todos os produtos)
  Linux:    ./clean.sh           idem
            ./clean.sh --dist    idem e tambem dist/
  .tools\ nunca e apagado; apague a mao para forcar novo download.
  O build completo (secao 2) ja comeca limpo.


4. ONDE FICA CADA PRODUTO
-------------------------
Windows - dist\w11\amd64\
  mdb2sql-<versao>-w11-amd64-go-wails-react.exe
      EXECUTAVEL unico: DuckDB linkado estaticamente, UI no WebView2 do Windows; duplo clique, sem instalar.

Formas Windows hoje: so o executavel unico. O .zip e o instalador ainda nao existem; entram em
scripts\package_w11.ps1 com os nomes
  mdb2sql-<versao>-w11-amd64-go-wails-react.zip
  mdb2sql-<versao>-w11-amd64-go-wails-react-installer.exe


5. PASTAS DE TRABALHO (podem ser apagadas; o build recria)
----------------------------------------------------------
  build\bin\       saida do wails build (mdb2sql.exe)
  frontend\dist\   saida do Vite, embutida no exe (go:embed)
  dist\.stage\     produtos sendo montados antes de irem para dist\w11\amd64\
  .tools\          Go, GCC e Wails fixados
  Tudo isso esta no .gitignore.


6. CADEIA DE SCRIPTS
--------------------
  build_w11_amd64.ps1
   -> clean.ps1
   -> scripts\setup_tools.ps1   Go, GCC e Wails CLI em .tools\ (versoes e sha256 no topo do script)
   -> scripts\build_w11.ps1     wails build -clean -trimpath (sem caminhos locais no exe)
   -> scripts\test_w11.ps1      go test ./... e vitest (frontend)
   -> scripts\package_w11.ps1   copia e renomeia para dist\w11\amd64\
  scripts\env_w11.ps1: poe Go, GCC e Wails no PATH (dot-source).


7. DESENVOLVIMENTO (nao usar para release)
------------------------------------------
  . scripts\env_w11.ps1; wails dev
  . scripts\env_w11.ps1; go test ./...; pnpm --dir frontend exec vitest run
  (go test precisa de frontend\dist: rode um build antes)
