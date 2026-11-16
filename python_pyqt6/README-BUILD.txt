MDB2SQL (Python + PyQt6) - BUILD, PRODUTOS E LIMPEZA
=====================================================
Guia pratico de build desta pasta. O README.md descreve o app e o uso; este arquivo diz qual comando rodar e
onde fica cada coisa. Versao: "version" em pyproject.toml (fonte unica).


1. REGRAS
---------
- Um comando por sistema e arquitetura, rodado nesta pasta. Ele faz tudo: limpa, baixa as ferramentas
  fixas para .tools\ (sha256 conferido), compila, roda os testes, varre os produtos atras de dados da
  maquina de build, gera os tres produtos e so no fim troca dist\<os>\<arch>\.
  Se algo falhar, os produtos anteriores ficam intactos em dist\.
- Ele imprime "Source: <tag>-<n>-g<commit>[-dirty]": esse e o commit que esta dentro do produto.
  Para release, commite antes (sem "-dirty").
- O Sobre mostra "build <N> (<AAAA-MM-DD>)": N = git rev-list --count HEAD e a data do build, gravados
  pelo mdb2sql.spec em build\BUILD. Rodando do codigo aparece "build dev".
- Sem build cruzado: cada pacote e gerado no proprio sistema/arquitetura.
- Codigos de saida: 0 ok, 1 falha de build/teste, 2 maquina errada (nao e Windows amd64).


2. "MAKE" - BUILD COMPLETO
--------------------------
  Windows 11 amd64   pwsh -NoProfile -File build_w11_amd64.ps1   -> dist\w11\amd64\
  Debian / outros    sem comando de pacote; rodar do codigo (README.md). O leitor mdbtools embutido e
                     a extensao sqlite baixada sao de Windows amd64.

Requisitos (Windows):
  uv no PATH (https://docs.astral.sh/uv/). E o unico pre-requisito: ele baixa o resto.
  gh autenticado (gh auth login) enquanto o repositorio mdbtools_custom for privado: o download anonimo da
  release falha e o setup_tools.ps1 tenta o "gh release download".

Ferramentas fixas (scripts\setup_tools.ps1 baixa para .tools\, sha256 conferido; versoes com >= 2 semanas):
  .tools\python\       Python 3.12.16 (.python-version), via "uv python install" (o uv confere o sha256)
  .tools\mdbtools\     mdbtools 1.0.1 estatico (mdb-tables, mdb-schema, mdb-export + COPYING, COPYING.LIB):
                       release win-static-1.0.1 de mauriciomenon/mdbtools_custom,
                       mdbtools-1.0.1-w11-amd64.zip, sha256 e15c69b9da2f8218f8c1db18fe0147d242cb888522d6c481e8c7c9d97e0405de
  .tools\duckdb_ext\   extensao sqlite do DuckDB 2.0.0 (windows_amd64, assinada pelo DuckDB):
                       sqlite_scanner.duckdb_extension.gz, sha256 3088cb24796c749d35aa3cb782cabc3df0c7d13dab4392f16fb5d2f02cd70d71
                       Ao trocar o DuckDB no uv.lock, troque a versao e o sha256 no setup_tools.ps1.
  .tools\nsis\         NSIS 3.12 (makensis), nsis-3.12.zip, sha256 56581f90db321581c5381193d796fffcf2d24b2f8fed2160a6c6a3baa67f2c4f
  Cada pasta tem um arquivo .sha256 com o hash baixado; hash diferente no script -> novo download.
  uv.lock           PyInstaller 6.22.3, PyQt6 6.10.0, DuckDB 2.0.0, pandas 2.3.3, XlsxWriter 3.3.1, pyodbc 5.3.0,
                    pytest 9.0.3, pytest-qt 4.5.0, openpyxl 3.1.5 (so nos testes, para reler o .xlsx)


3. "MAKE CLEAN" - LIMPAR
------------------------
  Windows:  .\clean.ps1          apaga build\, dist\.stage\, .pytest_cache\, .ruff_cache\
            .\clean.ps1 -Dist    idem e tambem dist\ (todos os produtos)
  Linux:    ./clean.sh           idem
            ./clean.sh --dist    idem e tambem dist/
  .tools\ e .venv\ nunca sao apagados; apague a mao para forcar novo download.
  O build completo (secao 2) ja comeca limpo.


4. ONDE FICA CADA PRODUTO
-------------------------
Windows - dist\w11\amd64\
  mdb2sql-<versao>-w11-amd64-python-pyqt6.exe
      EXECUTAVEL unico (PyInstaller onefile): Python, Qt, DuckDB, extensao sqlite e mdbtools dentro;
      duplo clique, sem instalar. A cada execucao extrai para uma pasta temporaria (_MEI...) e apaga ao sair.
  mdb2sql-<versao>-w11-amd64-python-pyqt6.zip
      PASTA DO APP (PyInstaller onedir) dentro de uma pasta com o mesmo nome: mdb2sql.exe + _internal\.
  mdb2sql-<versao>-w11-amd64-python-pyqt6-installer.exe
      INSTALADOR NSIS por usuario, sem admin: %LOCALAPPDATA%\Programs\MDB2SQL (Python + PyQt6)\, atalho no
      menu Iniciar, desinstalador (Configuracoes > Aplicativos; chave HKCU\...\Uninstall\mdb2sql-python-pyqt6).
      Silencioso: <instalador> /S [/D=<pasta>]; desinstalar: <pasta>\uninstall.exe /S.

Fora de dist\, em tempo de uso:
  %LOCALAPPDATA%\mdb2sql\python-pyqt6-<versao>\mdbtools\   copia do mdbtools, feita ao abrir .mdb/.accdb sem
                                                          ODBC; versoes velhas sao apagadas; o desinstalador
                                                          apaga a da versao dele.
  HKCU\Software\MDB2SQL\MDB2SQL                           tema e ultima pasta usada (QSettings).


5. PASTAS DE TRABALHO (podem ser apagadas; o build recria)
----------------------------------------------------------
  build\           saida do PyInstaller: build\dist\mdb2sql-pyqt.exe (onefile), build\dist\mdb2sql\ (onedir),
                   build\work\, build\VERSION e build\BUILD
  dist\.stage\     produtos sendo montados antes de irem para dist\w11\amd64\
  .tools\          ferramentas fixas (secao 2)
  .venv\           ambiente do uv (dependencias do uv.lock)
  Tudo isso esta no .gitignore.


6. CADEIA DE SCRIPTS
--------------------
  build_w11_amd64.ps1
   -> clean.ps1
   -> scripts\setup_tools.ps1   Python, mdbtools, extensao sqlite e NSIS em .tools\ (sha256 conferido)
   -> scripts\build_w11.ps1     uv sync --locked, pyinstaller mdb2sql.spec (onefile + onedir),
                                scripts\scan_exe.py no exe e na pasta do app (falha se achar caminho/nome
                                da maquina de build; termos extras em MDB2SQL_SCAN_TERMS)
   -> scripts\test_w11.ps1      pytest (QT_QPA_PLATFORM=offscreen)
   -> scripts\package_w11.ps1   exe, zip (Compress-Archive) e instalador (makensis scripts\installer.nsi)
                                em dist\.stage, depois troca dist\w11\amd64\
  scripts\env_w11.ps1: ambiente comum (dot-source). Spec do PyInstaller: mdb2sql.spec.


7. DESENVOLVIMENTO (nao usar para release)
------------------------------------------
  pwsh -NoProfile -File scripts\setup_tools.ps1      uma vez: extensao sqlite e mdbtools em .tools\
  uv run --python 3.12 python src/main.py [banco]
  QT_QPA_PLATFORM=offscreen uv run --python 3.12 pytest -q
  Teste com um .accdb real (copia; compara ODBC x mdbtools):
    $env:MDB2SQL_TEST_ACCDB='<copia.accdb>'; uv run pytest -q tests/test_access.py -k real
  Forcar o leitor de Access: MDB2SQL_ACCESS_READER=odbc | mdbtools
