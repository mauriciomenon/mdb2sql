MDB2SQL (Python + PyQt6) - BUILD, PRODUTOS E LIMPEZA
=====================================================
Guia pratico de build desta pasta. O README.md descreve o app; este arquivo diz qual comando rodar e onde
fica cada coisa. Versao: "version" em pyproject.toml (fonte unica).


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
  Debian / outros    sem comando de pacote ainda; rodar do codigo (README.md).

Requisitos (Windows):
  uv no PATH (https://docs.astral.sh/uv/). E o unico pre-requisito: ele baixa o resto.
  .tools\python     Python 3.12.16 (.python-version), via "uv python install", sha256 conferido pelo uv
  uv.lock           PyInstaller 6.22.3, PyQt6 6.10.0, DuckDB 2.0.0, pytest 9.0.3, pytest-qt 4.5.0


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
      EXECUTAVEL unico (PyInstaller onefile): Python, Qt e DuckDB dentro; duplo clique, sem instalar.

Formas Windows hoje: so o executavel unico. O .zip da pasta do app e o instalador ainda nao existem;
entram em scripts\package_w11.ps1 com os nomes
  mdb2sql-<versao>-w11-amd64-python-pyqt6.zip
  mdb2sql-<versao>-w11-amd64-python-pyqt6-installer.exe


5. PASTAS DE TRABALHO (podem ser apagadas; o build recria)
----------------------------------------------------------
  build\           saida do PyInstaller (build\dist\mdb2sql-pyqt.exe, build\work\, build\VERSION)
  dist\.stage\     produtos sendo montados antes de irem para dist\w11\amd64\
  .tools\          Python fixado
  .venv\           ambiente do uv (dependencias do uv.lock)
  Tudo isso esta no .gitignore.


6. CADEIA DE SCRIPTS
--------------------
  build_w11_amd64.ps1
   -> clean.ps1
   -> scripts\setup_tools.ps1   Python fixado em .tools\python
   -> scripts\build_w11.ps1     uv sync --locked, pyinstaller mdb2sql.spec, scripts\scan_exe.py
                                (abre o exe e falha se achar caminho/nome da maquina de build)
   -> scripts\test_w11.ps1      pytest (QT_QPA_PLATFORM=offscreen)
   -> scripts\package_w11.ps1   copia e renomeia para dist\w11\amd64\
  scripts\env_w11.ps1: ambiente comum (dot-source). Spec do PyInstaller: mdb2sql.spec.


7. DESENVOLVIMENTO (nao usar para release)
------------------------------------------
  uv run --python 3.12 python src/main.py [banco.duckdb]
  QT_QPA_PLATFORM=offscreen uv run --python 3.12 pytest -q
