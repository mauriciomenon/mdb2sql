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
- digitar ou colar o caminho no campo do topo e **Open** (aspas do "Copiar como caminho" sao aceitas); caminho maior
  que o campo mostra o fim (o nome do arquivo) e o comeco sai com "...";
- arrastar o arquivo para a janela;
- linha de comando: `mdb2sql.exe "D:\dados\banco.accdb"`; ou a variavel `MDB2SQL_DB_PATH` com o caminho.

O botao **Export...** ao lado de **Open** abre a mesma lista de exportacao do menu File.

**Access**: o arquivo e lido uma vez (num DuckDB em memoria, que e o motor da tela) e gravado uma vez num **SQLite
temporario** com os mesmos dados e tipos (inteiro, decimal exato, texto, data, booleano e binario, e os NULL); nada e
convertido duas vezes. A barra de status mostra a etapa (lendo o Access, gravando o SQLite) e depois "Opened via mdbtools → SQLite" (ou "Access ODBC → SQLite").
O app so pergunta ao **sair** (X, File > Exit, `Ctrl+Q`, `Alt+F4`) com o Access convertido e nao salvo
(**Converted SQLite file**: "The database converted from `<nome>` was not saved. Save before exiting?"): **Save** abre
a caixa de salvar (cancelada, a pergunta volta); **Back** volta ao app (Esc e o X da caixa tambem); **Exit** apaga o
temporario e sai. **Fechar** (File > Close), **abrir outro** e **Reopen** (F5) nao perguntam: o convertido nao salvo e
apagado e o Log diz isso. Com uma exportacao em andamento, sair pergunta antes (**Back** / **Exit**; Exit cancela a
exportacao, sem arquivo pela metade). Se o app cair, o temporario e apagado na proxima abertura (linha no Log).

**File > Save** (`Ctrl+S`), com qualquer banco aberto: a caixa de salvar do sistema na pasta do original, com o nome
dele, os tipos SQLite, DuckDB e Excel (uma aba por tabela) e ja marcado o tipo do aberto (Access e SQLite: SQLite;
DuckDB: DuckDB). Se o nome sugerido for o proprio arquivo aberto, vira `<nome> (copy)`; gravar por cima do arquivo
aberto ou do temporario e recusado. **Save as...** (`Ctrl+Shift+S`): o mesmo, comecando na ultima pasta em que voce
salvou ou exportou. O Access convertido salvo em SQLite e a copia do temporario; os outros casos gravam o banco com
progresso e **Cancel**. Arquivos .mdb/.accdb nao podem ser gravados (formato proprietario da Microsoft).

**Access ja salvo**: abrir de novo o mesmo .accdb/.mdb (mesmo caminho, tamanho e data) abre o SQLite ou DuckDB salvo
dele, sem converter nem perguntar ao sair, tambem depois de fechar e abrir o app (a lista fica nas preferencias); se o
Access ou o arquivo salvo mudou, o Access e convertido de novo.

SQLite e Access ficam num DuckDB em memoria enquanto o banco esta aberto (motor das consultas, filtros e
exportacao); arquivos DuckDB sao abertos direto, so leitura.

**Tela**:
- **Tables** (esquerda): lista de tabelas com o nome inteiro (nome longo quebra a linha) e as linhas de cada uma
  (colunas **Table** e **Rows**); **Filter N tables** filtra por nome (300 ms depois da ultima tecla, como a pesquisa
  da aba Data; Enter filtra na hora). Clique ou setas (Home/End) abrem a tabela. **Favoritas**: botao direito numa
  tabela > **Add to favorites** (ou **View > Favorite or unfavorite table**, `Ctrl+D`, na tabela aberta): ela vai para o
  topo da lista, em ordem alfabetica, com "★ " antes do nome; vale pelo nome enquanto o programa estiver aberto.
- Aba **Data**, de cima para baixo (igual nas 4 versoes): uma linha com a pesquisa, **This table | All tables**,
  **Rows** (100/500/1000) e **Columns...**; os filtros por valor, quando houver; a grade; embaixo dela
  "<tabela>: rows 1 to 100 of Y" com as paginas **◀ ▶** (do tamanho de **Rows**; pesquisa e filtros valem em todas; outra
  pesquisa, filtro ou tabela volta a pagina 1). A **pesquisa** (**Search the whole
  table**) roda no banco, na **tabela inteira** (todas as linhas e colunas, nao so as carregadas): a linha aparece
  quando uma mesma celula tem todas as palavras, em qualquer ordem, sem diferenciar maiusculas nem acentos
  (`tension de campo` acha `EXCITACION TENSION DE CAMPO`, RTUNO 50 / PNTNO 9 de RANGER_SOANLG no DB4, fora das 100
  primeiras linhas; `tensao` acha `TENSÃO` mas nao `TENSION`: nao ha busca aproximada). A contagem vira
  "<tabela>: rows 1 to 100 of Y found". A pesquisa roda 300 ms depois da ultima tecla (Enter: na hora).
- Ao lado da pesquisa, **This table | All tables**: em **All tables** o termo e procurado em todas as tabelas (mesma
  regra, em todas as colunas: numeros e datas como texto, como nas outras 3 versoes) e aparece a lista das tabelas com
  o numero de linhas achadas; escolher uma abre essa tabela com a mesma pesquisa. O escopo padrao fica em **Settings >
  Default search scope**.
- **Linhas marcadas** (aba Data): a primeira coluna da grade tem uma caixa por linha (clique, `Espaco` na linha da
  celula escolhida, botao direito ou **Edit > Mark or unmark row**). As marcadas ficam sempre no topo, na ordem da
  tabela, qualquer que seja a pesquisa ou o filtro; embaixo da grade ", N marked" e a caixa **Only marked**. Valem por
  tabela enquanto o arquivo estiver aberto (fechar, abrir outro e F5 limpam). A linha e reconhecida pelo `rowid` do
  DuckDB (tabelas do .duckdb e as copiadas do SQLite e do Access); numa view, por todos os valores (linhas identicas
  marcam juntas).
- Aba **Advanced Search** (`Ctrl+4`): cole uma lista (por exemplo uma coluna do Excel, um termo por linha), escolha **Whole
  value** (a celula inteira, sem espacos nas pontas, igual ao termo; numero casa pelo valor, em formato EUA ou BR:
  216 acha 216.0, "216,0" e "216"; 1234.5 acha "1.234,5"; 216 nao acha 2160) ou **Contains**, sem diferenciar maiusculas, e
  **This table** ou **All tables**; **Search terms** (ou `Ctrl+Enter`) procura no motor, em todas as colunas, com
  progresso e **Cancel**. Mostra o resumo, as tabelas com acerto e a grade da escolhida (coluna **Term** + as colunas
  da tabela, na ordem da lista colada) e os termos nao encontrados (texto copiavel). **Copy the rows found in this
  table** copia todas as linhas achadas com o cabecalho e sem a coluna Term; o relatorio (Export > Term search report)
  sai em Excel, CSV (pasta), SQLite ou DuckDB com a aba **Filter Result** (cada termo, onde achou e quantas linhas,
  tambem os nao encontrados) e uma aba por tabela com acerto.
- **Columns...**: marque e desmarque colunas (busca por nome no topo, caixas em grade que acompanha a janela).
  **Show all** e **Hide all** agem nas colunas listadas (com busca, so nelas). A barra de status mostra "N hidden
  columns". A pesquisa olha todas as colunas e a exportacao sai com todas.
- **Botao direito no cabecalho** (como o menu do Dear ImGui da versao Zig): **Size column to fit** / **Size all
  columns to fit** em toda grade (arrastar a borda direita do cabecalho muda a largura; ajustar volta a caber nome e
  valores). Na aba Data tambem **Hide this column**, **Columns...**, **Show all columns** e a lista das colunas com
  marca: o clique alterna (o menu fica aberto para trocar varias) e a ultima visivel nao sai. Ocultas e larguras
  valem para a tabela aberta enquanto ela estiver aberta.
- **Filter by this value** (botao direito numa celula da aba Data): coluna = valor exato na consulta ao banco
  (`WHERE "coluna" = ?`; celula vazia de NULL vira `IS NULL`). Varios filtros somam (E); os ativos aparecem acima
  da grade (`Filter: SIGLA = 'U9A' x`) com **Clear filters**. Filtros e pesquisa valem juntos.
- Aba **Schema**: colunas da tabela, tipo e se aceita nulo (Yes/No no idioma da tela).
- Aba **SQL**: SQL do DuckDB sobre as tabelas abertas (ex.: `SELECT * FROM "RANGER_SOSTAT" WHERE RTUNO = 2`), so
  leitura: consultas (SELECT, WITH, SHOW, DESCRIBE, SUMMARIZE, PRAGMA de leitura) e EXPLAIN de consulta; o tipo do
  comando vem do DuckDB e qualquer outro (INSERT, CREATE, ATTACH, COPY, SET...) e recusado antes de rodar. O banco, a
  copia em memoria e os arquivos nunca mudam. **Run** ou `Ctrl+Enter`. A grade mostra ate o numero de **Rows**; a exportacao do resultado leva todas as linhas. Erro: a
  grade anterior sai e o erro aparece ao lado do botao e na barra de status; o proximo SQL sem erro limpa os dois.
- **Grade**: clique seleciona a celula; `Ctrl+C` copia o valor; botao direito (ou a tecla de menu) abre **Copy
  value**, **Copy row**, **Copy row with header** (TAB, pronto para colar no Excel). NULL aparece como celula vazia
  (ou `NULL` com **Settings > Show NULL** ligado; so a tela: copiar, pesquisar e exportar nao mudam) e numero inteiro
  sem ".0", como nas outras stacks. As colunas se ajustam ao conteudo; nada e cortado.

**Menu File**: **Open...** (`Ctrl+O`), **Open the typed path**, **Reopen** (`F5`), **Save** (`Ctrl+S`), **Save
as...** (`Ctrl+Shift+S`), **Export** (submenu, abaixo; a mesma lista do botao **Export...**), **Close** (`Ctrl+W`) e
**Exit** (`Ctrl+Q`). Os outros menus: **Edit** (copiar, Log, pesquisar, filtros, marcar), **View** (abas `Ctrl+1` a
`4`, Rows, Columns..., escopo, Only marked rows, lista de tabelas `Ctrl+T`, favorita `Ctrl+D`, Run SQL, Search terms, Log), **Settings**
e **Help**: todo botao da tela tem o seu item.
  - Export (lista fixa; o que nao se aplica fica desabilitado): **Current table**, **Marked rows**, **Current table
    schema**, **Database schema** (CSV ou Excel), **All tables to CSV (one file per table)** (pasta; uma pergunta so
    se algum arquivo ja existe), **SQL result**, **All-tables search result (Excel)** e **Term search report**.
  - Save em SQLite / DuckDB: todas as tabelas, com os tipos. No SQLite
    datas vao como texto ISO e o tipo fica declarado na coluna (o arquivo reabre com os mesmos tipos); decimais
    com mais de 15 digitos (a Moeda do Access e `DECIMAL(19,4)`) vao como numero REAL (tipo declarado
    `REAL_DECIMAL(p,s)`) quando todo valor da coluna cabe exato num DOUBLE, de modo que no sqlite3 `WHERE preco > 20`,
    `ORDER BY` e `SUM` comparam como numero; se algum valor so cabe exato como texto, a coluna fica texto exato
    (`TEXT_DECIMAL(p,s)`, que no sqlite3 compara como texto). Inteiros de 128 bits/UBIGINT ficam como texto exato.
    O mesmo vale para o SQLite convertido do Access.
  - Save em Excel (.xlsx): uma aba por tabela (nome sem `[ ] : * ? / \`, ate 31
    caracteres, repetidos ganham `~2`); tabela com mais de 1.048.575 linhas continua em `<nome> (2)`...
  - **Current table to CSV / Excel** (tabela inteira; com pesquisa ou filtro na aba Data o app pergunta **Whole
    table** ou **Only the N rows found**) e **SQL result to CSV / Excel** (roda de novo o ultimo SQL; arquivo
    sugerido `query.csv` / `query.xlsx`).
  - CSV: UTF-8 com BOM, virgula, aspas quando precisa, NULL vazio, datas `AAAA-MM-DD HH:MM:SS`.
  - O dialogo de salvar abre na pasta do banco aberto e nao sugere o proprio arquivo; gravar por cima do banco aberto
    e recusado. A exportacao roda em segundo plano com barra de progresso e **Cancel**; o arquivo e gravado numa
    pasta temporaria propria ao lado do destino e so no fim recebe o nome escolhido (cancelar ou dar erro nunca
    deixa arquivo pela metade nem mexe no anterior).
  - **Gerar .mdb/.accdb: nao.** Nao ha biblioteca confiavel para gravar Access.

**Menu View > Log**: painel com as mensagens da sessao (hora e texto), selecionavel (`Ctrl+C`) e **Copy all**.
O texto da barra de status tambem pode ser copiado: botao direito > **Copy**.

**Menu Settings**: **Theme** (System, Light, Dark), **Language** (English, Português (Brasil), Español), **Default
search scope** (This table, All tables), **Term matching** (Whole value, Contains: o padrao da aba Terms) e **Show
NULL** (desligado por padrao: a celula NULL fica vazia; ligado, mostra
`NULL`); as escolhas ficam gravadas e valem na hora.

**Menu Help > About mdb2sql** (o titulo do dialogo): versao, build, stack (Rust + Tauri + Svelte), janela (WebView2/WebKitGTK), SQLite e
DuckDB, leitor do Access, gravacao (SQLite, DuckDB, Excel e CSV; .mdb/.accdb nao), autor, licenca e os links do codigo no GitHub e no GitLab (o app so pode abrir esses dois
enderecos).

**Atalhos** (os dos itens de menu; valem quando o item vale): `Ctrl+O` abrir, `F5` abrir de novo o banco, `Ctrl+S`
salvar, `Ctrl+Shift+S` salvar como, `Ctrl+W` fechar, `Ctrl+Q` sair, `Ctrl+F` pesquisar na aba Data, `Ctrl+T` lista de
tabelas, `Ctrl+D` favoritar a tabela aberta, `Ctrl+1`/`2`/`3`/`4` abas Data/Schema/SQL/Terms, `Ctrl+L` log, `Ctrl+Enter` rodar o SQL ou pesquisar os termos
(na aba de cada um), `Ctrl+C` copiar a celula escolhida, `Ctrl+Shift+C` a linha, `Espaco` marcar a linha.

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
  do Access enquanto ele esta aberto (apagado ao fechar, abrir outro ou sair; sobra de queda e apagada na abertura
  seguinte) e o CSV de trabalho do mdbtools durante a leitura. Sem permissao ali, a pasta temporaria do sistema
  (`%SystemRoot%\Temp`, `/tmp`) e, por ultimo, a pasta do Access, sempre na subpasta `mdb2sql-rust-tauri-svelte`.
- Dados do webview e preferencias (tema, idioma, ultima pasta, os SQLite salvos de cada Access: caminho, tamanho e
  data): Windows `%LOCALAPPDATA%\com.mdb2sql.app\`, Linux
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

## Desempenho

Protocolo comum das 4 stacks (REGRA_DESEMPENHO): build release, copias dos bancos, 3 execucoes por caso, mediana,
um caso por processo (pico de memoria do processo). Maquina: Intel Core Ultra 7 258V (8 nucleos), 31,5 GB RAM, SSD
NVMe, Windows 11. "Lista" = ate a lista de tabelas; "1a tabela" = lista + esquema, 100 linhas e contagem da primeira
tabela; a conversao para SQLite termina junto com a lista. Exportar: so o tempo da exportacao, com o Access aberto pelo
ODBC. Antes = 1.3.0 com a releitura do SQLite e 4 mdb-export; depois = sem releitura e min(nucleos - 1, 6) mdb-export.

| Caso (s) | DB4 antes | DB4 depois | DB3 1 antes | DB3 1 depois | Pico de memoria |
| --- | --- | --- | --- | --- | --- |
| Access pelo ODBC: lista / 1a tabela | 18,7 / 18,8 | 10,3 / 10,4 | 20,4 / 20,6 | 11,0 / 11,1 | ~327 MB |
| Access pelo mdbtools: lista / 1a tabela | 49,8 / 49,9 | 35,2 / 35,3 | 76,8 / 77,0 | 41,2 / 41,3 | ~226 MB |
| Reabrir o SQLite salvo | 3,3 | 2,9 | 4,8 | 4,0 | ~207 MB |
| Exportar para SQLite (so a exportacao) | 4,7 | 3,3 | 5,5 | 3,1 | ~329 MB |
| Exportar para DuckDB (so a exportacao) | 3,4 | 3,3 | 4,7 | 3,2 | ~415 MB |
| Abrir o .sqlite de referencia | 4,0 | 3,2 | 3,4 | 3,0 | ~208 MB |
| Abrir o .duckdb de referencia | 0,2 | 0,2 | 0,2 | 0,1 | ~52 MB |

Contagens tabela a tabela iguais a referencia antes e depois (teste com Access real). Nao feito: mostrar a lista de
tabelas antes do fim da conversao (o motor da tela e o DuckDB que a leitura preenche; abrir tabela no meio da carga
pede uma segunda conexao e travas por tabela; ganho so na espera da 1a tela), tabelas grandes primeiro (o mdbtools
nao informa o tamanho antes do mdb-export) e cache ao reabrir o mesmo .accdb (o temporario e salvo ou apagado ao
fechar; salvar o SQLite e reabri-lo ja da o mesmo ganho: ~3 s).

## Limites conhecidos

- Pelo mdbtools o Access demora mais que pelo ODBC (numeros na secao Desempenho); salvar o SQLite e abri-lo nas
  proximas vezes evita reler o Access.
- O mdbtools nao distingue texto vazio de NULL: um campo `""` do Access chega como NULL (pelo ODBC chega `""`).
- SQLite e Access ficam em memoria enquanto abertos (RAM ~ tamanho dos dados); um banco de varios GB nao cabe.
- A pesquisa compara o texto de cada valor como o DuckDB o escreve (ex.: `2.0` para um DOUBLE que a grade mostra `2`).
- Excel: texto com mais de 32.767 caracteres e cortado (limite do Excel); numeros com mais de 15 digitos e datas
  antes de 1900 vao como texto; BLOB vai como texto.
- EXPLAIN so com uma consulta, sozinho no texto e sem comentario (`EXPLAIN SELECT 1; SELECT 2` e recusado): o DuckDB nao diz qual
  comando um EXPLAIN explica, e EXPLAIN ANALYZE roda esse comando.
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
salvar/apagar/limpar o temporario e as pastas de reserva, pesquisa na tabela inteira e em todas as tabelas, aba SQL
so leitura, linhas marcadas, pesquisa de termos e relatorio, exportar e reabrir, Excel, CSV, filtros, Sobre, links
liberados, versoes) e `pnpm --filter mdb2sql-ui test` (`node --test`: catalogos de idioma, nenhum texto fora do
catalogo, nada duplicado, arvore dos menus, ordem Access/SQLite/DuckDB, colunas, filtros, caminhos, marcas, termos).
Com `MDB2SQL_TEST_DB3_DIR` (pasta com copias do DB3 e a lista de termos) o `cargo test` confere a aceitacao da pesquisa
de termos e mede a busca em todas as tabelas. Com `MDB2SQL_TEST_ACCDB`,
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
