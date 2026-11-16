# MDB2SQL (Rust + Tauri + Svelte) 1.1.0

Programa de Windows para abrir bancos Microsoft Access (`.mdb`, `.accdb`), DuckDB (`.duckdb`, `.db`) e SQLite
(`.sqlite`, `.sqlite3`), ver tabelas, esquema e dados, rodar SQL e exportar o banco inteiro para DuckDB, SQLite
ou Excel (uma aba por tabela), ou a tabela/resultado atual para CSV ou Excel. O arquivo aberto nunca e alterado.

Backend em Rust (DuckDB 2.0 embutido), janela Tauri 2 (WebView2 do Windows) e interface Svelte 5.

## Qual arquivo baixar

Release `rust_tauri_svelte-v1.1.0` (pasta `dist\w11\amd64\` do build). Os quatro fazem a mesma coisa:

| Arquivo | Para quem |
| --- | --- |
| `mdb2sql-1.1.0-w11-amd64-rust-tauri-svelte.exe` | **Executavel unico**: baixe e de dois cliques. Nao instala nada. |
| `mdb2sql-1.1.0-w11-amd64-rust-tauri-svelte.zip` | O mesmo exe e este README numa pasta; extraia e rode `mdb2sql.exe`. |
| `mdb2sql-1.1.0-w11-amd64-rust-tauri-svelte-installer.exe` | Instalador NSIS: atalho no menu Iniciar e desinstalador. Nao pede administrador. |
| `mdb2sql-1.1.0-w11-amd64-rust-tauri-svelte-installer.msi` | Instalador MSI (WiX), para distribuicao por politica/GPO. |

O exe nao e assinado digitalmente: na primeira execucao o SmartScreen pode avisar ("Mais informacoes" >
"Executar assim mesmo").

## Requisitos

- **Windows 11 x64** (ou Windows 10 x64 atualizado).
- **Microsoft Edge WebView2 Runtime**: ja vem no Windows 11. Num Windows sem ele o exe nao abre a janela; os
  instaladores baixam e instalam o WebView2 sozinhos (precisa de internet nessa hora).
- **.duckdb e .sqlite**: nada a instalar (DuckDB e SQLite estao dentro do exe).
- **.mdb e .accdb**: o programa usa, nesta ordem:
  1. o driver ODBC **"Microsoft Access Driver (*.mdb, *.accdb)" de 64 bits**, se estiver instalado (vem com o
     Office 64 bits ou com o "Microsoft Access Database Engine 2016 Redistributable", `accessdatabaseengine_X64.exe`);
  2. senao, o **mdbtools 1.0.1** que vai **dentro do exe** (nao precisa instalar nada; e mais lento);
  3. se nenhum funcionar, a barra de status diz o que instalar.

## Como usar

**Abrir um banco** (qualquer um dos jeitos):
- **File > Open...** ou o botao **Browse...**: dialogo do Windows (abre na pasta do ultimo banco aberto);
- digitar ou colar o caminho no campo **Database** e **Open database** (aspas do "Copiar como caminho" sao aceitas);
- linha de comando: `mdb2sql.exe "D:\dados\banco.accdb"`; ou a variavel `MDB2SQL_DB_PATH` com o caminho.

Bancos Access e SQLite sao copiados para um DuckDB em memoria ao abrir (o DB4 de 115 MB leva ~7 s pelo ODBC e
~1 min pelo mdbtools; a barra de status mostra a tabela sendo lida). Arquivos DuckDB sao abertos direto, so leitura.
A **barra de status** (embaixo) mostra a mensagem atual e por qual caminho o arquivo foi lido:
**Opened via DuckDB**, **SQLite**, **Access ODBC** ou **mdbtools**.

**Tela**:
- **Tables** (esquerda): lista de tabelas; **Filter tables** filtra por nome. Clique (ou setas) abre a tabela.
- Aba **Data**: as primeiras linhas da tabela (quantas: **Row limit**, 100/500/1000) e o total de linhas.
  **Search loaded rows** procura em todas as colunas das linhas carregadas (nao na tabela inteira).
- Aba **Schema**: colunas da tabela, tipo e se aceita nulo.
- Aba **SQL**: SQL livre do DuckDB sobre as tabelas abertas (ex.: `SELECT * FROM "RANGER_SOSTAT" WHERE RTUNO = 2`);
  **Run SQL** ou `Ctrl+Enter`. A grade mostra ate o Row limit; a exportacao do resultado leva todas as linhas.
- **Grade** (Data, Schema e SQL): clique seleciona a celula; `Ctrl+C` copia o valor; botao direito (ou a tecla de
  menu) abre **Copy value**, **Copy row**, **Copy row with header** (linha separada por TAB, pronta para colar no
  Excel). As colunas se ajustam ao conteudo, nada e cortado; role na horizontal para ver tudo.

**Menu File**
- **Open...**: abre um banco.
- **Export** (tambem no botao **Export...** ao lado do campo Database):
  - **Database to DuckDB (.duckdb)** / **Database to SQLite (.sqlite)**: todas as tabelas, com os tipos
    (DECIMAL, TIMESTAMP, DOUBLE, texto...). No SQLite datas vao como texto ISO e o tipo DuckDB fica declarado
    na coluna, de modo que o arquivo reabre com os mesmos tipos.
  - **Database to Excel (.xlsx, one sheet per table)**: uma aba por tabela, cabecalho na linha 1 (fixado).
    Nome da aba = nome da tabela sem `[ ] : * ? / \`, cortado em 31 caracteres; nomes que ficariam iguais
    ganham `~2`, `~3`. Tabela com mais de 1.048.575 linhas continua nas abas `<nome> (2)`, `<nome> (3)`...
  - **Current table to CSV / Excel**: a tabela inteira (nao so as linhas carregadas).
  - **SQL result to CSV / Excel**: roda de novo o ultimo SQL da aba SQL e grava todas as linhas.
  - CSV: UTF-8 com BOM (o Excel reconhece acentos), separador virgula, valores com virgula/aspas/quebra de
    linha entre aspas, NULL vazio, datas `AAAA-MM-DD HH:MM:SS`.
  - O dialogo de salvar abre na pasta do banco aberto (sem banco aberto, na ultima pasta usada) e nao sugere o
    nome do proprio arquivo aberto; gravar por cima do banco aberto e recusado.
  - A exportacao roda em segundo plano com barra de progresso e **Cancel**. O arquivo e gravado como
    `<nome>.partial` e so recebe o nome final no fim: cancelar ou dar erro nunca deixa arquivo pela metade.
  - **Gerar .mdb/.accdb: nao.** Nao ha biblioteca confiavel para gravar Access; exporte para DuckDB/SQLite/Excel.

**Menu Settings > Theme**: System (segue o Windows), Light ou Dark; a escolha fica gravada.

**Menu Help > About MDB2SQL**: versao, numero e data do build, versoes de Tauri, WebView2, Rust, Svelte, DuckDB,
SQLite e mdbtools, e se o driver ODBC do Access esta instalado.

**Variaveis de ambiente** (opcionais): `MDB2SQL_DB_PATH` = banco aberto ao iniciar;
`MDB2SQL_ACCESS_READER=odbc` ou `=mdbtools` forca o leitor de .mdb/.accdb.

## O que o programa grava no computador

- `%LOCALAPPDATA%\mdb2sql\rust-tauri-svelte-1.1.0\mdbtools\`: o mdbtools embutido, extraido na primeira vez que
  um Access e aberto sem ODBC (3 exes + licenca GPL, ~0,7 MB). Pastas de versoes antigas deste programa sao
  apagadas sozinhas. Pode ser apagada a qualquer momento.
- `%LOCALAPPDATA%\com.mdb2sql.app\`: dados do WebView2 e as preferencias (tema, ultima pasta).
- `%TEMP%\mdb2sql-<n>-mdbtools.csv`: temporario durante a leitura pelo mdbtools, apagado em seguida.
- So os arquivos que voce exportar. O banco aberto nunca e alterado.

## Testado

Windows 11 Pro 10.0.26300 amd64, WebView2 RUNTIME_WEBVIEW2, driver ODBC do Access 64 bits instalado.
Com copias de bancos reais do NMR5 (287 tabelas; RANGER_SOSTAT com 36.754 linhas):

RESULTADOS_TESTES

## Limites conhecidos

- Access e SQLite sao lidos inteiros para a memoria (RAM ~ tamanho do arquivo); um banco de varios GB nao cabe.
- Pelo mdbtools a leitura e ~8x mais lenta que pelo ODBC (DB4: ~1 min). Nomes de tabela Access com acento pelo
  ODBC nao foram testados (os bancos NMR5 so tem ASCII).
- A busca da aba Data so ve as linhas carregadas (Row limit); para a tabela inteira use a aba SQL.
- Excel: texto com mais de 32.767 caracteres e cortado nesse limite (limite do Excel); numeros com mais de 15
  digitos significativos e datas antes de 1900 vao como texto; BLOB vai como texto.
- O SQL livre roda no DuckDB com todo o poder dele: o arquivo aberto e so leitura, mas um `COPY ... TO` ou
  `ATTACH` grava onde o usuario mandar.
- Sem pacote para Linux/macOS (o codigo compila; ver README-BUILD.txt).

## Build

```powershell
pwsh -NoProfile -File build_w11_amd64.ps1   # -> dist\w11\amd64\ (exe, zip, instaladores NSIS e MSI)
```

Comandos, produtos, pastas de trabalho e limpeza: [README-BUILD.txt](README-BUILD.txt).
Use sempre esse comando (ou `cargo tauri build`): um `cargo build --release` puro gera um exe que procura o
servidor de desenvolvimento e abre uma janela vazia.

Testes: `cargo test` nesta pasta (abrir os tres formatos, exportar e reabrir, nomes e divisao de abas do Excel,
CSV, escolha do leitor Access, tipos, Sobre, versoes) e `pnpm --filter mdb2sql-ui test` (`node --test`: copia da
grade, busca, pasta padrao e nome sugerido dos dialogos de salvar). Com `MDB2SQL_TEST_ACCDB` (copia de um .accdb) e
`MDB2SQL_TEST_DUCKDB` (conversao de referencia) o `cargo test` tambem abre o Access pelos dois leitores, confere
tabelas e linhas contra a referencia e compara ODBC x mdbtools celula a celula.

Stack: Rust 1.99.1, tauri 2.12 (tauri-cli 2.12.4, tauri-plugin-dialog 2.8), crate duckdb 1.20000.2
(DuckDB 2.0.0 bundled), rusqlite 0.41.1 (SQLite bundled), odbc-api 29.3, rust_xlsxwriter 0.102, mdbtools 1.0.1
estatico, Svelte 5.57 + Vite 8.3. Versoes exatas: `rust-toolchain.toml`, `Cargo.lock` e `pnpm-lock.yaml` (raiz).

## Versao

A fonte unica e `version` em `Cargo.toml`. O `tauri.conf.json` nao tem `version` (o Tauri herda a do Cargo.toml),
o dialogo About le a mesma constante, e `ui/package.json` repete o numero; `cargo test` falha se eles divergirem.
Numero do build (`git rev-list --count HEAD`) e data entram no About pelo build oficial; fora dele, "build dev".

## Ferramentas com versao fixa

| Ferramenta | Versao | Onde fica | Quem instala |
| --- | --- | --- | --- |
| Rust (rustc, cargo) | 1.99.1 | toolchain do rustup, escolhida por `rust-toolchain.toml` | `scripts/setup_tools.ps1` (`rustup toolchain install`) |
| tauri-cli | 2.12.4 | `.tools\bin\cargo-tauri.exe` (pasta ignorada pelo git) | `scripts/setup_tools.ps1` (`cargo install --root .tools ... --locked`) |
| mdbtools estatico | 1.0.1 (`mdbtools-1.0.1-w11-amd64.zip`, sha256 `e15c69b9...0405de`) | `.tools\mdbtools-1.0.1-w11-amd64\`, embutido no exe | `scripts/setup_tools.ps1` (release `win-static-1.0.1` do mdbtools_custom; sha256 conferido) |
| Dependencias Rust | `Cargo.lock` | registry do cargo | cargo |
| Dependencias do frontend | `pnpm-lock.yaml` (raiz) | `node_modules` | `scripts/setup_tools.ps1` (`pnpm install --frozen-lockfile`) |

Escolha de versoes (recentes, com pelo menos ~2 semanas): odbc-api 29.3.0 (2026-11-01; a 30.x tem dias),
rust_xlsxwriter 0.102.0 (2026-10-29), rusqlite 0.41.1 (2026-10-28; 0.42/0.43 tem dias). O crate duckdb 1.20000.2
ja estava fixado antes desta versao. O Rust 1.100.0 saiu em 2026-11-09, ha menos de duas semanas, por isso o
pino fica em 1.99.1. A extensao sqlite do DuckDB nao e usada: tem 47 MB; o rusqlite acrescenta ~1,5 MB.

## O que continua no sistema e por que

- **rustup**: e ele que le o `rust-toolchain.toml` e baixa o compilador fixado, com assinatura conferida.
- **MSVC Build Tools (C++) + Windows SDK**: o linker `link.exe` e o `cl.exe` que constroi o DuckDB e o SQLite
  embutidos. Sao instalados pelo Visual Studio Installer, tem licenca propria e varios GB.
- **Node.js + pnpm**: executam o Vite que gera `ui/dist`. O workspace pnpm e da raiz do repositorio e e
  compartilhado com o stack Go + Wails.
- **gh** (GitHub CLI logado): so se o download anonimo do mdbtools falhar (o repositorio mdbtools_custom e privado).
- **WebView2 Runtime**: componente do Windows 11, usado pelo app em execucao.
- **NSIS e WiX**: o tauri-cli baixa as versoes que ele mesmo fixa (e confere o hash) para
  `%LOCALAPPDATA%\tauri` na primeira vez que gera os instaladores.

## Seguranca

O banco e aberto so para leitura (DuckDB por ATTACH READ_ONLY, SQLite com SQLITE_OPEN_READ_ONLY, Access com
ReadOnly=1 no ODBC; o mdbtools so le). So extensoes de banco sao aceitas e os nomes de tabela sao conferidos
contra a lista lida do banco antes de entrar no SQL. Licencas: o mdbtools e GPL/LGPL; o texto da GPL vai junto
(`COPYING`) na pasta extraida.
