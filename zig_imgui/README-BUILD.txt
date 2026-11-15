MDB2SQL (Zig + Dear ImGui) - BUILD, PRODUTOS E LIMPEZA
=======================================================
Guia pratico de build desta pasta. O README.md descreve o app; este arquivo diz qual comando rodar e onde
fica cada coisa. Versao: .version em build.zig.zon (fonte unica).


1. REGRAS
---------
- Um comando por sistema e arquitetura, rodado nesta pasta. Ele faz tudo: limpa, baixa o Zig fixado para
  .tools\, compila, roda os testes, gera os produtos e so no fim troca dist\<os>\<arch>\.
  Se algo falhar, os produtos anteriores ficam intactos em dist\.
- Ele imprime "Source: <tag>-<n>-g<commit>[-dirty]": esse e o commit que esta dentro do produto.
  Para release, commite antes (sem "-dirty").
- So Windows amd64: o build.zig para em outros alvos (so a libduckdb de Windows esta fixada).
  Por isso nao ha clean.sh nem build Linux.
- Codigos de saida: 0 ok, 1 falha de build/teste, 2 maquina errada (nao e Windows amd64).


2. "MAKE" - BUILD COMPLETO
--------------------------
  Windows 11 amd64   pwsh -NoProfile -File build_w11_amd64.ps1   -> dist\w11\amd64\

Requisitos:
  No sistema: PowerShell 7 e o tar.exe do Windows. Nenhum compilador C/C++ nem Windows SDK.
  .tools\zig-x86_64-windows-0.17.1   Zig 0.17.1 (sha256 de ziglang.org/download/index.json)
  zig-pkg\                           Dear ImGui 1.93, cimgui, zglfw (GLFW 3.4), libduckdb 2.0.0: baixados
                                     pelo zig build, fixados por hash em build.zig.zon
  Sem .tools\ o build usa o zig 0.17.x do PATH. O 1o build demora (translate-c de duckdb.h e cimgui.h).


3. "MAKE CLEAN" - LIMPAR
------------------------
  .\clean.ps1          apaga .zig-cache\, zig-out\, dist\.stage\
  .\clean.ps1 -Dist    idem e tambem dist\ (todos os produtos)
  .tools\ e zig-pkg\ nunca sao apagados; apague a mao para baixar de novo.
  O build completo (secao 2) ja comeca limpo.


4. ONDE FICA CADA PRODUTO
-------------------------
Windows - dist\w11\amd64\
  mdb2sql-<versao>-w11-amd64-zig-imgui.zip
      pasta do app zipada: mdb2sql-zig.exe + duckdb.dll (os dois precisam ficar juntos).
  mdb2sql-zig-imgui\
      a mesma pasta, aberta (uso local; nao vai para o release).
      Executavel: mdb2sql-zig-imgui\mdb2sql-zig.exe

Formas Windows hoje: so o .zip (e a pasta aberta). O executavel unico e o instalador ainda nao existem;
entram em scripts\package_w11.ps1 com os nomes
  mdb2sql-<versao>-w11-amd64-zig-imgui.exe
  mdb2sql-<versao>-w11-amd64-zig-imgui-installer.exe


5. PASTAS DE TRABALHO (podem ser apagadas; o build recria)
----------------------------------------------------------
  zig-out\bin\     saida do zig build (mdb2sql-zig.exe + duckdb.dll)
  .zig-cache\      cache do compilador
  zig-pkg\         dependencias baixadas
  dist\.stage\     produtos sendo montados antes de irem para dist\w11\amd64\
  .tools\          Zig fixado
  Tudo isso esta no .gitignore.


6. CADEIA DE SCRIPTS
--------------------
  build_w11_amd64.ps1
   -> clean.ps1
   -> scripts\setup_tools.ps1   Zig 0.17.1 em .tools\ (versao e sha256 no topo do script)
   -> scripts\build_w11.ps1     zig build -Doptimize=ReleaseSafe
   -> scripts\test_w11.ps1      zig build test --summary all
   -> scripts\package_w11.ps1   pasta do app + zip em dist\w11\amd64\
  scripts\env_w11.ps1: acha o zig (dot-source). Projeto e dependencias: build.zig, build.zig.zon.


7. DESENVOLVIMENTO (nao usar para release)
------------------------------------------
  zig build run -Doptimize=ReleaseSafe -- "caminho\do\banco.duckdb"
  zig build test --summary all
  zig build -Doptimize=ReleaseSafe -Dconsole=true     exe de release que mantem o console
