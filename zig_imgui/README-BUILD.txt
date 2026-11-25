MDB2SQL (Zig + Dear ImGui) - BUILD, PRODUTOS E LIMPEZA
=======================================================
Guia pratico de build desta pasta. O README.md descreve o app; este arquivo diz qual comando rodar e onde
fica cada coisa. Versao: .version em build.zig.zon (fonte unica; hoje 1.3.0).


1. REGRAS
---------
- Um comando por sistema e arquitetura. Ele faz tudo: baixa as ferramentas fixas para .tools\ (sha256 conferido),
  compila, roda os testes, gera os produtos e so no fim troca dist\<os>\<arch>\. Se algo falhar, os produtos
  anteriores ficam intactos em dist\.
- Ele imprime "Build <N> (<AAAA-MM-DD>)" (N = git rev-list --count HEAD; gravados no programa e mostrados em
  Help > About; fora destes comandos o About mostra Build "dev") e, no fim, "Source: <tag>-<n>-g<commit>[-dirty]":
  esse e o commit que esta dentro dos produtos. Para release, commite antes (o build Debian recusa arvore suja).
- Alvos: Windows x64 e Linux x64 (Debian). O build.zig para em outros (so as libduckdb x86_64 de Windows e Linux
  estao fixadas). macOS, Arch e BSD ficam para uma proxima versao (nao feitos nesta).
- Codigos de saida: 0 ok, 1 falha de build/teste/varredura, 2 maquina ou pasta errada (ou arvore suja no Debian),
  3 falta ferramenta (Debian).


2. "MAKE" - BUILD COMPLETO
--------------------------
  Windows 11 amd64          pwsh -NoProfile -File build_w11_amd64.ps1        -> dist\w11\amd64\
  Debian amd64 pelo WSL     pwsh -NoProfile -File build_debian_amd64_wsl.ps1 -> dist\debian\amd64\
  Debian amd64 (no Linux)   ./build_debian_amd64.sh                         -> dist/debian/amd64/

Windows - requisitos: PowerShell 7 e o tar.exe do Windows. Nenhum compilador C/C++ nem Windows SDK.
  Baixados por scripts\setup_tools.ps1 (versao e sha256 no topo do script):
    .tools\zig-x86_64-windows-0.17.1     Zig 0.17.1 (sha256 de ziglang.org/download/index.json)
    .tools\duckdb-ext-v2.0.0             extensao sqlite_scanner do DuckDB 2.0.0 (vai junto do programa)
    .tools\mdbtools-1.0.1                mdbtools 1.0.1 estatico (mdb-tables, mdb-schema, mdb-export; vai junto)
    .tools\nsis-3.13                     NSIS 3.13 (gera o instalador)

Debian - o build_debian_amd64_wsl.ps1 (no Windows, arvore commitada) mantem um clone no disco do Linux do WSL
  (~/src/mdb2sql-zig, distro "Debian"), poe nele o MESMO commit, roda ./build_debian_amd64.sh la e traz
  dist/debian/amd64 de volta conferindo o sha256 de cada arquivo. O build recusa rodar em /mnt/c (codigo 2).
  Pacotes do sistema (o script diz o que falta): build-essential curl xz-utils git zip dpkg-dev libx11-dev libgl-dev
  Baixados por scripts/setup_tools_linux.sh (versao e sha256 no topo do script):
    .tools/zig-x86_64-linux-0.17.1       Zig 0.17.1
    .tools/duckdb-ext-v2.0.0-linux       extensao sqlite_scanner do DuckDB 2.0.0 linux_amd64 (vai junto)
    .tools/mdbtools-1.0.1-linux          mdbtools 1.0.1 compilado aqui do fonte fixado (estatico, sem GLib; vai junto)
  O build tambem confere que nenhum binario tem a pasta do usuario ($HOME ou /<usuario>/) e grava o exe sem
  informacao de depuracao (-Dstrip=true).

Baixados pelo zig build, fixados por hash em build.zig.zon (pasta zig-pkg\): Dear ImGui 1.93, cimgui,
zglfw (GLFW 3.4) e a libduckdb 2.0.0 do sistema alvo (Windows ou Linux; so a do alvo e baixada).
O 1o build demora (translate-c de duckdb.h e cimgui.h, C++ do Dear ImGui, compressao do executavel unico).


3. "MAKE CLEAN" - LIMPAR
------------------------
  .\clean.ps1          apaga .zig-cache\, zig-out\, dist\.stage\
  .\clean.ps1 -Dist    idem e tambem dist\ (todos os produtos)
  .tools\ e zig-pkg\ nunca sao apagados; apague a mao para baixar de novo. Os builds completos ja comecam limpos.


4. ONDE FICA CADA PRODUTO
-------------------------
Windows - dist\w11\amd64\
  mdb2sql-<versao>-w11-amd64-zig-imgui.exe             executavel unico (extrai para %LOCALAPPDATA%\mdb2sql\)
  mdb2sql-<versao>-w11-amd64-zig-imgui.zip             pasta do app: mdb2sql-zig.exe, duckdb.dll,
                                                       sqlite_scanner.duckdb_extension, mdbtools\, README.md, LICENSE
  mdb2sql-<versao>-w11-amd64-zig-imgui-installer.exe   instalador NSIS por usuario (sem administrador), /S [/D=pasta]
Debian - dist/debian/amd64/
  mdb2sql-<versao>-debian-amd64-zig-imgui.deb          /usr/lib/mdb2sql-zig-imgui/ (programa, libduckdb.so, extensao,
                                                       mdbtools/), comando /usr/bin/mdb2sql-zig, menu e icone;
                                                       Depends: as bibliotecas ligadas (dpkg-shlibdeps) e as que o
                                                       programa carrega: libgl1, libx11-6, libxrandr2, libxinerama1,
                                                       libxcursor1, libxi6, zenity, xdg-utils, fonts-dejavu-core
  mdb2sql-<versao>-debian-amd64-zig-imgui.zip          pasta do app (mdb2sql-zig-imgui/), mesmos arquivos
  SHA256SUMS.txt


5. PASTAS DE TRABALHO (podem ser apagadas; o build recria)
----------------------------------------------------------
  zig-out\bin\      pasta do app (exe, libduckdb, extensao sqlite, mdbtools\)
  zig-out\onefile\  executavel unico (Windows)
  .zig-cache\       cache do compilador (os testes criam arquivos temporarios em .zig-cache\tmp\)
  zig-pkg\          dependencias baixadas pelo zig build
  dist\.stage\      produtos sendo montados
  .tools\           ferramentas fixas (secao 2)
  Tudo isso esta no .gitignore.


6. CADEIA DE SCRIPTS
--------------------
  build_w11_amd64.ps1 -> clean.ps1 -> scripts\setup_tools.ps1 -> scripts\build_w11.ps1 -> scripts\test_w11.ps1
                      -> scripts\package_w11.ps1 (executavel unico, zip e instalador scripts\installer.nsi)
  build_debian_amd64_wsl.ps1 -> (WSL) build_debian_amd64.sh -> scripts/build_debian.sh
                      -> scripts/setup_tools_linux.sh, zig build test, zig build install, .zip, .deb
  scripts\make_test_mdb.ps1: refaz testdata\mdb2sql_test.mdb (so precisa do Windows com o ACE OLEDB 64 bits;
  os testes conferem os valores dele).


7. DESENVOLVIMENTO E TESTES (nao usar para release)
---------------------------------------------------
  zig build run -Doptimize=ReleaseSafe -- "caminho\do\banco.accdb"
  zig build test --summary all        inclui o .mdb versionado lido pelo mdbtools (o build poe os dois na pasta do teste)
  zig build -Doptimize=ReleaseSafe -Dconsole=true     exe de release que mantem o console (Windows)
  Teste opcional com um Access real (use uma COPIA): conversao pelos leitores, contagens contra o conversor de
  referencia, pesquisa na tabela inteira, tipos declarados no SQLite e 6 consultas com filtro numerico, ORDER BY e
  SUM comparadas (SQL do programa e SQLite direto, convertido e referencia) e exportacoes:
    $env:MDB2SQL_TEST_ACCDB = 'C:\copia\DB4.accdb'
    $env:MDB2SQL_TEST_REF = 'C:\copia\ref_DB4.sqlite'    (opcional: .sqlite ou .duckdb do conversor de referencia)
    $env:MDB2SQL_TEST_READERS = 'mdbtools'               (opcional; padrao: odbc,mdbtools no Windows)
    $env:MDB2SQL_TEST_OUT = 'C:\copia\saida'             (opcional: exporta .duckdb/.sqlite/.xlsx e confere)
    zig build test -Doptimize=ReleaseSafe --summary all
  Protocolo de desempenho (REGRA_DESEMPENHO): com $env:MDB2SQL_PERF = '1' e as variaveis acima, o mesmo teste mede 3
  vezes (mediana) cada leitor: ate a lista de tabelas, ate a 1a tabela, conversao (e, no mdbtools, o tempo esperando
  o mdb-export e gravando o SQLite), reabrir o SQLite salvo, exportar para SQLite e DuckDB, e abrir os arquivos de
  referencia (.sqlite e o .duckdb de mesmo nome).
  Variaveis do programa: MDB2SQL_DB_PATH (arquivo aberto ao iniciar), MDB2SQL_ACCESS_READER=odbc|mdbtools|auto.
  Temporarios do programa: <TEMP>/mdb2sql-zig/<pid>-<n>.sqlite (o SQLite convertido) e os CSVs do mdbtools.

  Linux, janela: o programa pede ao GLFW o X11 (XWayland num desktop Wayland) e so usa o Wayland nativo se nao
  houver X11. Motivo: no Wayland o GLFW decora a janela pelo libdecor, que carrega o GTK (LD_DEBUG=libs mostrava
  libdecor-0, libgtk-3, libgdk-3); no WSLg, logo depois de a VM do WSL reiniciar, 2 de 8 inicios do build 258 cairam
  ("Gdk-CRITICAL gdk_seat_get_keyboard: assertion GDK_IS_SEAT failed" e em seguida "Segmentation fault at address
  0x40", antes do 1o quadro). Sem backtrace: a queda nao se repetiu em 26 inicios seguintes (20 deles, metade sob
  gdb), entao o quadro exato nao foi capturado; a mensagem do GDK aponta para o plugin GTK do libdecor. Com o X11
  (commit 9abc9f3): GTK/libdecor/Wayland nao sao mais carregados e 20 de 20 inicios passaram (10 sob gdb). Se
  cair de novo: gdb -batch -ex run -ex bt --args mdb2sql-zig ... e anote o quadro.

  Capturas de tela (auxiliar de teste, fora da interface): o programa abre o banco sem janela visivel, sem mouse
  nem foco, passa sozinho pelos estados e grava um PNG por estado; nao le nem grava as configuracoes salvas e
  mostra so o nome do arquivo na caixa do caminho. Use uma COPIA do banco. Saida 0; com erro, saida 2 e
  <pasta>\capture_error.txt; passos sem o que precisam (tabela ou coluna do NMR5, Access convertido) sao pulados e
  listados em <pasta>\capture_skipped.txt.
    $env:MDB2SQL_ACCESS_READER = 'mdbtools'
    mdb2sql-zig.exe --capture C:\copia\shots --db C:\copia\DB4.accdb --theme light
  Estados (src\capture.zig): RANGER_SOSTAT, filtro SUBNAM = 'U02', Columns com colunas ocultas (1280x800 e
  1920x1129), janela estreita 720x800, RANGER_SOANLG, Log, Settings > Language, About, dialogo do SQLite convertido,
  os mesmos em portugues e espanhol, e por fim Delete (a captura confere que o temporario sumiu).
  Estados conferidos (m_, n_, o_): clique numa celula com colunas ocultas (continuam ocultas), busca em todas as
  tabelas por ELSUL (a RANGER_SOXAGC, depois da coluna 10.000 do catalogo do DB4, esta no resultado), termo apagado
  com a busca rodando (o resultado velho nao volta), acerto da tabela aberta com o filtro SUBNAM = 'U02' (abre sem o
  filtro, com a contagem listada) e o mesmo arquivo aberto de novo (filtro da lista de tabelas e busca vazios, escopo
  padrao). Estados do padrao das 4 versoes (p_, q_, r_): pergunta "Tabela inteira / So as N linhas encontradas" ao
  exportar com a busca ativa, menu do cabecalho, menu da celula, menu Arquivo e Exportar..., atalhos teclados de
  verdade (Ctrl+2 Esquema, Ctrl+1 Dados, Ctrl+F busca, F5 abrir de novo, Ctrl+Q na saida com Access), aba SQL vazia
  (dica), SQL errado (erro na barra) e o certo por Ctrl+Enter (o erro sai da barra). Conferencia que falha vai para
  capture_error.txt (saida 2) e a captura continua. Com
  $env:MDB2SQL_CAPTURE_SAVE = '1' o ultimo passo responde Save (resposta lembrada, grava <pasta>\<origem>.sqlite sem
  dialogo) e confere que o arquivo salvo e um SQLite e que o temporario sumiu; depois (k_reopened_saved) abre o mesmo
  Access de novo e confere que veio o SQLite salvo, sem converter nem perguntar. Linux: o 1o passo (0_display_warning)
  grava o aviso "Display mode" quando o programa abriu no Wayland por reserva (ex.: env -u DISPLAY no WSLg); com X11
  ele e pulado (capture_skipped.txt).
  Linux, escolha do sistema de janelas: src/display.zig (decisao, com teste) e initLinuxDisplay em src/main.zig;
  MDB2SQL_DISPLAY=x11|wayland escolhe sem aviso.
