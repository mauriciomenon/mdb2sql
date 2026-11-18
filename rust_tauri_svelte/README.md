# MDB2SQL (Rust + Tauri + Svelte) 1.3.0

Programa para abrir bancos Microsoft Access (`.accdb`, `.mdb`), SQLite (`.sqlite`, `.sqlite3`, `.db`) e DuckDB
(`.duckdb`), ver tabelas, esquema e dados, pesquisar, rodar SQL e exportar o banco inteiro para SQLite, DuckDB ou
Excel (uma aba por tabela), ou a tabela/resultado atual para CSV ou Excel. O arquivo aberto nunca e alterado.
**Access abre sem Access instalado**: o mdbtools vai dentro do programa.

Backend em Rust (SQLite e DuckDB embutidos), janela Tauri 2 (WebView2 no Windows, WebKitGTK no Linux) e interface
Svelte 5. Interface em ingles (padrao), portugues (Brasil) ou espanhol.

## Qual arquivo baixar

Release `rust_tauri_svelte-v1.3.0` (pastas `dist\w11\amd64\` e `dist/debian/amd64/` do build):

| Arquivo | Para quem |
| --- | --- |
| `mdb2sql-1.3.0-w11-amd64-rust-tauri-svelte.exe` | **Windows, executavel unico**: baixe e de dois cliques. Nao instala nada. |
| `mdb2sql-1.3.0-w11-amd64-rust-tauri-svelte.zip` | O mesmo exe, este README e o LICENSE numa pasta; extraia e rode `mdb2sql.exe`. |
| `mdb2sql-1.3.0-w11-amd64-rust-tauri-svelte-installer.exe` | Instalador NSIS: atalho no menu Iniciar e desinstalador. Nao pede administrador. |
| `mdb2sql-1.3.0-w11-amd64-rust-tauri-svelte-installer.msi` | Instalador MSI (WiX), para distribuicao por politica/GPO. |
| `mdb2sql-1.3.0-debian-amd64-rust-tauri-svelte.deb` | **Debian/Ubuntu amd64**: `sudo apt install ./mdb2sql-...deb` (instala as dependencias). |
| `mdb2sql-1.3.0-debian-amd64-rust-tauri-svelte.zip` | Linux amd64: binario `mdb2sql`, README e LICENSE; precisa do WebKitGTK 4.1 instalado. |

O exe do Windows nao e assinado digitalmente: na primeira execucao o SmartScreen pode avisar ("Mais informacoes" >
"Executar assim mesmo").

## Requisitos

- **Windows 11 x64** (ou Windows 10 x64 atualizado) com o **Microsoft Edge WebView2 Runtime** (ja vem no Windows
  11; os instaladores baixam se faltar).
- **Debian 13 amd64** (ou derivado com WebKitGTK 4.1): o `.deb` pede `libwebkit2gtk-4.1-0` e `libgtk-3-0`, que o
  `apt` instala junto. Para o `.zip`: `sudo apt install libwebkit2gtk-4.1-0 libgtk-3-0`.
- **.accdb e .mdb: nada a instalar.** O **mdbtools 1.0.1** vai dentro do programa. No Windows, se o driver ODBC
  "Microsoft Access Driver (*.mdb, *.accdb)" de 64 bits existir (Office 64 bits ou Access Database Engine), ele e
  usado por ser mais rapido; sem ele, o mdbtools. `MDB2SQL_ACCESS_READER=mdbtools` forca o mdbtools (ou `=odbc`).
- **SQLite e DuckDB**: nada a instalar.

## Como usar

**Abrir um banco** (qualquer um dos jeitos):
- botao **Browse...**: dialogo do sistema, com os filtros Access, SQLite e DuckDB (abre na pasta do ultimo banco);
- digitar ou colar o caminho no campo **Database** e **Open database** (aspas do "Copiar como caminho" sao aceitas);
- linha de comando: `mdb2sql.exe "D:\dados\banco.accdb"`; ou a variavel `MDB2SQL_DB_PATH` com o caminho.

**Access**: o arquivo e lido uma vez e gravado num **SQLite temporario** (com os tipos: inteiro, decimal exato,
texto, data, booleano e binario, e os NULL); o app le dali. A barra de status mostra a etapa (lendo o Access,
gravando o SQLite, carregando) e depois "Opened via mdbtools → SQLite" (ou "Access ODBC → SQLite").
Ao **fechar o banco** (File > Close database), **abrir outro** ou **sair**, o app pergunta
**Save the converted SQLite?**:
- **Save...**: dialogo de salvar na pasta do Access, nome `<nome do Access>.sqlite`; o SQLite fica onde voce escolher
  e pode ser aberto depois direto (bem mais rapido que reler o Access);
- **Delete**: apaga o temporario;
- **Cancel**: nao fecha, nao abre o outro, nao sai.

"Remember for this session" repete a escolha sem perguntar ate fechar o app (Save grava na ultima pasta usada; se
ja existir um arquivo com o nome, abre o dialogo). Se o app cair, o temporario e apagado na proxima abertura.

SQLite e Access ficam num DuckDB em memoria enquanto o banco esta aberto (motor das consultas, filtros e
exportacao); arquivos DuckDB sao abertos direto, so leitura.

**Tela**:
- **Tables** (esquerda): lista de tabelas com o nome inteiro (nome longo quebra a linha); **Filter tables** filtra
  por nome. Clique ou setas (Home/End) abrem a tabela.
- Aba **Data**: as primeiras linhas (quantas: **Row limit**, 100/500/1000) e o total. A **pesquisa** (**Search
  table**) roda no banco, na **tabela inteira** (todas as linhas e colunas, nao so as carregadas): a linha aparece
  quando uma mesma celula tem todas as palavras, em qualquer ordem, sem diferenciar maiusculas nem acentos
  (`tension de campo` acha `EXCITACION TENSION DE CAMPO`, RTUNO 50 / PNTNO 9 de RANGER_SOANLG no DB4, fora das 100
  primeiras linhas; `tensao` acha `TENSÃO` mas nao `TENSION`: nao ha busca aproximada). A contagem vira
  "Showing N of M matching rows (T in the table)".
- **Columns...** (ou botao direito no cabecalho > **Hide this column** / **Columns...** / **Show all**): marque e
  desmarque colunas (busca por nome no topo, caixas em grade que acompanha a janela). **Show all** e **Hide all**
  agem nas colunas listadas (com busca, so nelas). A barra de status mostra "N columns hidden". A pesquisa olha
  todas as colunas e a exportacao sai com todas.
- **Filter by this value** (botao direito numa celula da aba Data): coluna = valor exato na consulta ao banco
  (`WHERE "coluna" = ?`; celula vazia de NULL vira `IS NULL`). Varios filtros somam (E); os ativos aparecem acima
  da grade (`Filter: SIGLA = 'U9A' x`) com **Clear filters**. Filtros e pesquisa valem juntos.
- Aba **Schema**: colunas da tabela, tipo e se aceita nulo.
- Aba **SQL**: SQL livre do DuckDB sobre as tabelas abertas (ex.: `SELECT * FROM "RANGER_SOSTAT" WHERE RTUNO = 2`);
  **Run SQL** ou `Ctrl+Enter`. A grade mostra ate o Row limit; a exportacao do resultado leva todas as linhas.
- **Grade**: clique seleciona a celula; `Ctrl+C` copia o valor; botao direito (ou a tecla de menu) abre **Copy
  value**, **Copy row**, **Copy row with header** (TAB, pronto para colar no Excel). NULL aparece como celula vazia
  e numero inteiro sem ".0", como nas outras stacks. As colunas se ajustam ao conteudo; nada e cortado.

**Menu File**: **Export** (abaixo) e **Close database**.
  - **Database to SQLite (.sqlite)** / **Database to DuckDB (.duckdb)**: todas as tabelas, com os tipos. No SQLite
    datas vao como texto ISO e o tipo fica declarado na coluna (o arquivo reabre com os mesmos tipos); decimais
    com mais de 15 digitos (a Moeda do Access e `DECIMAL(19,4)`) vao como numero REAL (tipo declarado
    `REAL_DECIMAL(p,s)`) quando todo valor da coluna cabe exato num DOUBLE, de modo que no sqlite3 `WHERE preco > 20`,
    `ORDER BY` e `SUM` comparam como numero; se algum valor so cabe exato como texto, a coluna fica texto exato
    (`TEXT_DECIMAL(p,s)`, que no sqlite3 compara como texto). Inteiros de 128 bits/UBIGINT ficam como texto exato.
    O mesmo vale para o SQLite convertido do Access.
  - **Database to Excel (.xlsx, one sheet per table)**: uma aba por tabela (nome sem `[ ] : * ? / \`, ate 31
    caracteres, repetidos ganham `~2`); tabela com mais de 1.048.575 linhas continua em `<nome> (2)`...
  - **Current table to CSV / Excel** (tabela inteira) e **SQL result to CSV / Excel** (roda de novo o ultimo SQL).
  - CSV: UTF-8 com BOM, virgula, aspas quando precisa, NULL vazio, datas `AAAA-MM-DD HH:MM:SS`.
  - O dialogo de salvar abre na pasta do banco aberto e nao sugere o proprio arquivo; gravar por cima do banco aberto
    e recusado. A exportacao roda em segundo plano com barra de progresso e **Cancel**; o arquivo e gravado numa
    pasta temporaria propria ao lado do destino e so no fim recebe o nome escolhido (cancelar ou dar erro nunca
    deixa arquivo pela metade nem mexe no anterior).
  - **Gerar .mdb/.accdb: nao.** Nao ha biblioteca confiavel para gravar Access.

**Menu View > Log**: painel com as mensagens da sessao (hora e texto), selecionavel (`Ctrl+C`) e **Copy all**.
O texto da barra de status tambem pode ser copiado: botao direito > **Copy**.

**Menu Settings**: **Theme** (System, Light, Dark) e **Language** (English, Português (Brasil), Español); as escolhas
ficam gravadas e o idioma troca na hora.

**Menu Help > About MDB2SQL**: versao, build, stack (Rust + Tauri + Svelte), janela (WebView2/WebKitGTK), SQLite e
DuckDB, leitor do Access, autor, licenca e os links do codigo no GitHub e no GitLab (o app so pode abrir esses dois
enderecos).

**Variaveis de ambiente** (opcionais): `MDB2SQL_DB_PATH` = banco aberto ao iniciar;
`MDB2SQL_ACCESS_READER=mdbtools` (ou `odbc`) forca o leitor de .mdb/.accdb.

## Linux: X11 e Wayland

O programa abre a janela em **X11** (o GTK recebe `GDK_BACKEND=x11,wayland`) e usa **Wayland** so como reserva.
Se voce definiu `GDK_BACKEND`, vale a sua escolha e nao ha aviso. Sem X11 (variavel `DISPLAY` vazia, ou nenhum
servidor X respondendo nela) a janela abre no Wayland e aparece o aviso **Display mode** (texto selecionavel, tambem
no View > Log) com o comando que instala o servidor X da sua distribuicao. Sem X11 e sem Wayland o programa diz isso
no terminal e sai com codigo 1. As bibliotecas do GTK e do WebKitGTK vem como dependencias do `.deb`; o que pode
faltar e so o servidor X (XWayland):

| Distribuicao (ID / ID_LIKE do /etc/os-release) | Comando |
| --- | --- |
| Debian, Ubuntu e derivados | `sudo apt install xwayland` |
| Fedora, RHEL, CentOS, Rocky | `sudo dnf install xorg-x11-server-Xwayland` |
| Arch | `sudo pacman -S xorg-xwayland` |
| openSUSE | `sudo zypper install xwayland` |
| Outras | instale o XWayland (ou um servidor X) pelo gerenciador de pacotes da distribuicao |

## O que o programa grava no computador

- Windows `%LOCALAPPDATA%\mdb2sql\rust-tauri-svelte-1.3.0\mdbtools\`, Linux
  `~/.local/share/mdb2sql/rust-tauri-svelte-1.3.0/mdbtools/`: o mdbtools embutido, extraido na primeira vez que um
  Access e aberto (3 programas + licencas GPL e LGPL, menos de 1 MB). Versoes antigas sao apagadas sozinhas.
- Windows `%TEMP%\mdb2sql-rust-tauri-svelte\`, Linux `~/.cache/mdb2sql-rust-tauri-svelte/`: o SQLite convertido
  do Access enquanto ele esta aberto (apagado ou movido quando voce responde a pergunta; sobra de queda e apagada na
  abertura seguinte) e o CSV de trabalho do mdbtools durante a leitura.
- Dados do webview e preferencias (tema, idioma, ultima pasta): Windows `%LOCALAPPDATA%\com.mdb2sql.app\`, Linux
  `~/.local/share/com.mdb2sql.app/`.
- So os arquivos que voce exportar ou salvar. O banco aberto nunca e alterado.

## Testado

Windows 11 Pro 10.0.26300 amd64 (WebView2 157) e Debian 13 amd64 (WSL), Rust 1.99.1, Tauri 2.12.5, DuckDB 2.0.0,
SQLite 3.54.1, mdbtools 1.0.1. Copias de bancos reais do NMR5 e um .mdb pequeno gerado para o teste:

| Teste | Resultado |
| --- | --- |
| `2026-07-14 DB4.accdb` (115 MB) pelo mdbtools → SQLite, x conversoes de referencia (.duckdb e .sqlite) | 287 tabelas e 113.962 linhas, contagem igual tabela a tabela |
| O mesmo arquivo pelo driver ODBC x mdbtools | iguais celula a celula nas 287 tabelas |
| `2026-06-25 DB3 1.accdb` (115 MB) pelo mdbtools e pelo ODBC x referencias | 287 tabelas e 113.826 linhas, contagem igual tabela a tabela; ODBC x mdbtools iguais celula a celula |
| `tests/data/sample.mdb` (versionado, gerado por `scripts/make_test_mdb.ps1`) pelo mdbtools | tipos e NULL preservados no SQLite e na tela (`cargo test`, Windows e Debian) |
| Pesquisa `tension de campo` no DB4 | acha RTUNO 50 / PNTNO 9 em RANGER_SOANLG, fora das 100 primeiras linhas |

## Limites conhecidos

- Pelo mdbtools o Access demora mais que pelo ODBC (DB4: ~1,5 min pelo mdbtools, com ate 4 mdb-export ao mesmo
  tempo, e ~0,5 min pelo ODBC, somando ler, gravar o SQLite e carregar, medidos com a maquina ocupada); salvar o
  SQLite e abri-lo nas proximas vezes evita reler o Access.
- O mdbtools nao distingue texto vazio de NULL: um campo `""` do Access chega como NULL (pelo ODBC chega `""`).
- SQLite e Access ficam em memoria enquanto abertos (RAM ~ tamanho dos dados); um banco de varios GB nao cabe.
- A pesquisa compara o texto de cada valor como o DuckDB o escreve (ex.: `2.0` para um DOUBLE que a grade mostra `2`).
- Excel: texto com mais de 32.767 caracteres e cortado (limite do Excel); numeros com mais de 15 digitos e datas
  antes de 1900 vao como texto; BLOB vai como texto.
- O SQL livre roda no DuckDB com todo o poder dele: o arquivo aberto e so leitura, mas um `COPY ... TO` ou `ATTACH`
  grava onde o usuario mandar.
- Mensagens tecnicas vindas dos motores (erro de SQL do DuckDB, do sistema de arquivos) aparecem como o motor
  escreve, em ingles.
- macOS, Arch e BSD: sem script nem pacote nesta versao.

## Build

```powershell
pwsh -NoProfile -File build_w11_amd64.ps1        # Windows -> dist\w11\amd64\ (exe, zip, NSIS, MSI)
pwsh -NoProfile -File build_debian_amd64_wsl.ps1 # Debian pelo WSL -> dist\debian\amd64\ (.deb, .zip)
```

Comandos, produtos, pastas de trabalho e limpeza: [README-BUILD.txt](README-BUILD.txt).

Testes: `cargo test` (abrir os tres formatos, Access pelo mdbtools com o `.mdb` versionado, SQLite convertido,
salvar/apagar/limpar o temporario, pesquisa na tabela inteira, exportar e reabrir, Excel, CSV, filtros, Sobre,
links liberados, versoes) e `pnpm --filter mdb2sql-ui test` (`node --test`: catalogos de idioma, nenhum texto fora
do catalogo, nada duplicado, ordem Access/SQLite/DuckDB, colunas, filtros, caminhos). Com `MDB2SQL_TEST_ACCDB`,
`MDB2SQL_TEST_DUCKDB` e `MDB2SQL_TEST_SQLITE` (copias) o `cargo test` tambem confere um Access real contra as
conversoes de referencia.

Stack: Rust 1.99.1, tauri 2.12 (tauri-cli 2.12.4, tauri-plugin-dialog 2.8, tauri-plugin-opener 2.7), crate duckdb
1.20000.2 (DuckDB 2.0.0 bundled), rusqlite 0.41.1 (SQLite bundled), odbc-api 29.3 (so Windows), rust_xlsxwriter
0.102, mdbtools 1.0.1 estatico, Svelte 5.57 + Vite 8.3. Versoes exatas: `rust-toolchain.toml`, `Cargo.lock` e
`pnpm-lock.yaml` (raiz).

## Versao

A fonte unica e `version` em `Cargo.toml`; `ui/package.json` repete o numero e o `cargo test` confere. Numero do
build (`git rev-list --count HEAD`) e data entram no About pelo build oficial; fora dele, "build dev".
Historico: [CHANGELOG.md](CHANGELOG.md).

## Seguranca

O banco e aberto so para leitura (DuckDB por ATTACH READ_ONLY, SQLite com SQLITE_OPEN_READ_ONLY, Access com
ReadOnly=1 no ODBC; o mdbtools so le). Nomes de tabela sao conferidos contra a lista do banco; nome de coluna vai
entre aspas e todo valor de filtro e palavra da pesquisa vai como parametro da consulta, nunca no texto do SQL.
Temporarios sao criados de forma exclusiva (nome reservado no sistema de arquivos, sem "confere e depois cria") e na
pasta do usuario. O plugin opener so abre os dois links do About (`capabilities/default.json`; o `cargo test`
confere).

Alertas Dependabot desta stack (2026-11-18): `glib` 0.18 (GHSA-wrw7-89jp-8q8g, so Linux, puxado pelo Tauri 2 via
gtk-rs 0.18; a correcao 0.20 exige o Tauri 3, ainda alfa; o app nao usa `VariantStrIter`) e `picomatch` 4.0.7
(GHSA-fc5q-39xc-vjpf, ferramenta de build do Vite, sem versao corrigida publicada). Nenhum dos dois vai no exe do
Windows.

## Licenca

Licenca: GPL v2 ou posterior (SPDX `GPL-2.0-or-later`), texto em [LICENSE](LICENSE), que vai no zip, nos
instaladores e no .deb. Componentes de terceiros (Tauri, DuckDB, SQLite, mdbtools etc.) mantem as licencas deles;
os textos do mdbtools (`COPYING`, `COPYING.LIB`) vao junto na pasta extraida.
