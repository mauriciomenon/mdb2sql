MDB2SQL - BUILD, PRODUTOS E LIMPEZA (raiz)
==========================================
O repositorio tem quatro subprojetos independentes. Cada um tem o proprio README-BUILD.txt com os
detalhes; aqui fica so o mapa. Nao ha build na raiz.


1. UM COMANDO POR SUBPROJETO (Windows 11 amd64)
-----------------------------------------------
  pwsh -NoProfile -File python_pyqt6\build_w11_amd64.ps1        -> python_pyqt6\dist\w11\amd64\
  pwsh -NoProfile -File go_wails_react\build_w11_amd64.ps1      -> go_wails_react\dist\w11\amd64\
  pwsh -NoProfile -File rust_tauri_svelte\build_w11_amd64.ps1   -> rust_tauri_svelte\dist\w11\amd64\
  pwsh -NoProfile -File zig_imgui\build_w11_amd64.ps1           -> zig_imgui\dist\w11\amd64\

  Cada comando limpa, baixa as ferramentas fixas para <subprojeto>\.tools\ (sha256 conferido), compila,
  roda os testes e so no fim troca dist\w11\amd64\. Imprime "Source: <tag>-<n>-g<commit>[-dirty]".
  Rode cada um num pwsh novo. Codigos de saida: 0 ok, 1 falha, 2 maquina errada.
  Debian/Linux: ainda sem comando de pacote (docs\SetupDebian.md tem os comandos de desenvolvimento).


2. PRODUTOS (nome: mdb2sql-<versao>-w11-amd64-<stack>...)
---------------------------------------------------------
  Padrao em Windows: executavel unico, .zip da pasta do app e instalador. Hoje:

  Subprojeto          executavel unico   .zip      instalador
  python_pyqt6        sim                sim       sim (NSIS, por usuario)
  go_wails_react      sim                sim       sim (NSIS do Wails)
  rust_tauri_svelte   sim                sim       sim (NSIS .exe e MSI)
  zig_imgui           sim                sim       sim (NSIS, por usuario)

  Todos os subprojetos geram os tres produtos (1.1.0). Detalhes no scripts\package_w11.ps1 de cada subprojeto (nomes ja definidos no README-BUILD.txt
  de cada um).


3. LIMPEZA
----------
  <subprojeto>\clean.ps1 [-Dist]   (clean.sh [--dist] em python_pyqt6, go_wails_react e rust_tauri_svelte)
  .tools\ de cada subprojeto nunca e apagado pelo clean.


4. PRE-REQUISITOS DO SISTEMA (o resto vem para .tools\)
-------------------------------------------------------
  python_pyqt6        uv
  go_wails_react      Node.js 22+ e pnpm, WebView2
  rust_tauri_svelte   rustup, Visual Studio Build Tools (C++ + Windows SDK), Node.js e pnpm, WebView2
  zig_imgui           nada alem do PowerShell 7 e do tar.exe do Windows
  Guias de instalacao: docs\SetupWindows11.md, docs\SetupWindows.md, docs\SetupDebian.md.
