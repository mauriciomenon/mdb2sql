MDB2SQL (Zig + Dear ImGui) - BUILD, PRODUTOS E LIMPEZA
=======================================================
Guia pratico de build desta pasta. O README.md descreve o app; este arquivo diz qual comando rodar e onde
fica cada coisa. Versao: .version em build.zig.zon (fonte unica; hoje 1.2.0).


1. REGRAS
---------
- Um comando por sistema e arquitetura, rodado nesta pasta num pwsh novo. Ele faz tudo: limpa, baixa as
  ferramentas fixas para .tools\ (sha256 conferido), compila, roda os testes, gera os tres produtos e so no fim
  troca dist\<os>\<arch>\. Se algo falhar, os produtos anteriores ficam intactos em dist\.
- Ele imprime "Build <N> (<AAAA-MM-DD>)" (N = git rev-list --count HEAD, data de hoje; gravados no programa e
  mostrados em Help > About; fora deste comando o About mostra Build "dev") e, no fim,
  "Source: <tag>-<n>-g<commit>[-dirty]": esse e o commit que esta dentro dos produtos. Para release, commite antes.
- So Windows amd64: o build.zig para em outros alvos (so a libduckdb de Windows esta fixada).
  Por isso nao ha clean.sh nem build Linux.
- Codigos de saida: 0 ok, 1 falha de build/teste, 2 maquina errada (nao e Windows amd64).


2. "MAKE" - BUILD COMPLETO
--------------------------
  Windows 11 amd64   pwsh -NoProfile -File build_w11_amd64.ps1   -> dist\w11\amd64\

Requisitos:
  No sistema: PowerShell 7 e o tar.exe do Windows. Nenhum compilador C/C++ nem Windows SDK.
  Internet no 1o build. O mdbtools vem de um repositorio que pode ser privado: com o gh (GitHub CLI)
  autenticado o download e feito por ele; sem gh, pelo link publico do release.
  Baixados por scripts\setup_tools.ps1 (versao e sha256 no topo do script):
    .tools\zig-x86_64-windows-0.17.1     Zig 0.17.1 (sha256 de ziglang.org/download/index.json)
    .tools\duckdb-ext-v2.0.0             extensao sqlite_scanner do DuckDB 2.0.0 (vai junto do programa)
    .tools\mdbtools-1.0.1                mdbtools 1.0.1 estatico (mdb-tables, mdb-schema, mdb-export; vai junto)
    .tools\nsis-3.13                     NSIS 3.13 (gera o instalador)
  Baixados pelo zig build, fixados por hash em build.zig.zon (pasta zig-pkg\):
    Dear ImGui 1.93, cimgui, zglfw (GLFW 3.4), libduckdb 2.0.0
  O 1o build demora (translate-c de duckdb.h e cimgui.h, C++ do Dear ImGui, compressao do executavel unico).


3. "MAKE CLEAN" - LIMPAR
------------------------
  .\clean.ps1          apaga .zig-cache\, zig-out\, dist\.stage\
  .\clean.ps1 -Dist    idem e tambem dist\ (todos os produtos)
  .tools\ e zig-pkg\ nunca sao apagados; apague a mao para baixar de novo.
  O build completo (secao 2) ja comeca limpo.


4. ONDE FICA CADA PRODUTO
-------------------------
Windows - dist\w11\amd64\
  mdb2sql-<versao>-w11-amd64-zig-imgui.exe
      executavel unico: na 1a execucao extrai a pasta do app para
      %LOCALAPPDATA%\mdb2sql\zig-imgui-<versao>-<hash>\ e roda de la (apaga as versoes velhas dessa pasta).
  mdb2sql-<versao>-w11-amd64-zig-imgui.zip
      pasta do app zipada (mdb2sql-zig-imgui\): mdb2sql-zig.exe, duckdb.dll, sqlite_scanner.duckdb_extension,
      mdbtools\ (3 exes + COPYING, COPYING.LIB) e README.md. Os arquivos precisam ficar juntos.
  mdb2sql-<versao>-w11-amd64-zig-imgui-installer.exe
      instalador NSIS por usuario (sem administrador): %LOCALAPPDATA%\Programs\mdb2sql-zig-imgui,
      atalho no Menu Iniciar, desinstalar em Configuracoes > Aplicativos. Silencioso: /S [/D=pasta].


5. PASTAS DE TRABALHO (podem ser apagadas; o build recria)
----------------------------------------------------------
  zig-out\bin\      pasta do app (mdb2sql-zig.exe + .pdb, duckdb.dll, extensao sqlite, mdbtools\)
  zig-out\onefile\  executavel unico (mdb2sql-zig-onefile.exe, renomeado no dist\)
  .zig-cache\       cache do compilador (os testes criam arquivos temporarios em .zig-cache\tmp\)
  zig-pkg\          dependencias baixadas pelo zig build
  dist\.stage\      produtos sendo montados antes de irem para dist\w11\amd64\
  .tools\           ferramentas fixas (secao 2)
  Tudo isso esta no .gitignore.


6. CADEIA DE SCRIPTS
--------------------
  build_w11_amd64.ps1
   -> clean.ps1
   -> scripts\setup_tools.ps1   Zig, extensao sqlite, mdbtools, NSIS em .tools\ (sha256 conferido)
   -> scripts\build_w11.ps1     zig build install onefile -Doptimize=ReleaseSafe -Dbuild_number=N -Dbuild_date=D
   -> scripts\test_w11.ps1      zig build test --summary all
   -> scripts\package_w11.ps1   executavel unico, zip e instalador (scripts\installer.nsi) em dist\w11\amd64\
  scripts\env_w11.ps1: acha o zig (dot-source). Projeto e dependencias: build.zig, build.zig.zon.


7. DESENVOLVIMENTO (nao usar para release)
------------------------------------------
  zig build run -Doptimize=ReleaseSafe -- "caminho\do\banco.accdb"
  zig build test --summary all
  zig build onefile -Doptimize=ReleaseSafe           so o executavel unico (zig-out\onefile\)
  zig build -Doptimize=ReleaseSafe -Dconsole=true     exe de release que mantem o console
  Teste opcional com um Access real (use uma COPIA), os dois leitores e as exportacoes:
    $env:MDB2SQL_TEST_ACCDB = 'C:\copia\DB4.accdb'
    $env:MDB2SQL_TEST_MDBTOOLS = (Resolve-Path .tools\mdbtools-1.0.1).Path
    $env:MDB2SQL_TEST_OUT = 'C:\copia\saida'           (opcional: exporta .duckdb/.sqlite/.xlsx e confere)
    $env:MDB2SQL_TEST_SQLITE_EXT = (Resolve-Path .tools\duckdb-ext-v2.0.0\sqlite_scanner.duckdb_extension).Path
    zig build test -Doptimize=ReleaseSafe --summary all
  Variaveis do programa: MDB2SQL_DB_PATH (arquivo aberto ao iniciar), MDB2SQL_ACCESS_READER=odbc|mdbtools|auto.
