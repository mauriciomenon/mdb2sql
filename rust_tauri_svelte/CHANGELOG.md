# Changelog - mdb2sql (Rust + Tauri + Svelte)

## 1.3.0

### Novo

- **Access sem nada instalado**: .accdb/.mdb abre pelo mdbtools 1.0.1 que vai dentro do exe (Windows e agora
  Linux); o driver ODBC do Access so e usado no Windows e se existir. `MDB2SQL_ACCESS_READER=mdbtools` forca o
  mdbtools. A leitura pelo mdbtools roda ate 4 mdb-export ao mesmo tempo (DB4: ~2x mais rapida).
- **Conversao para SQLite**: ao abrir um Access o app grava uma vez um SQLite (arquivo, nao memoria) e le dali, com
  os tipos (inteiro, decimal exato, texto, data, booleano, binario) e os NULL. Ao fechar o banco, abrir outro ou
  sair o app pergunta: **Save...** (padrao ao lado do Access, `<nome>.sqlite`), **Delete** ou **Cancel**;
  "Remember for this session" repete a escolha ate fechar o app. Temporario nunca fica orfao: se o app cair, a
  proxima abertura apaga.
- **Pesquisa na tabela inteira**: a busca da aba Data roda no banco (todas as linhas e colunas, mesma regra: todas
  as palavras na mesma celula, sem maiusculas nem acentos), com "N of M matching rows".
- **Idiomas**: ingles (padrao), portugues (Brasil) e espanhol em Settings > Language, gravado; troca na hora.
  Todos os textos em catalogos (`ui/src/i18n/`); teste confere as chaves e que nenhum texto fica fora.
- **Log**: View > Log mostra as mensagens da sessao com hora, selecionaveis (Ctrl+C) e **Copy all**; botao
  direito na barra de status > **Copy**.
- **File > Close database**.
- **Debian amd64**: `build_debian_amd64_wsl.ps1` (pelo WSL) / `build_debian_amd64.sh` geram .deb e .zip, com o
  mdbtools dentro do binario.

### Mudado

- Ordem em tudo que aparece: Access, SQLite, DuckDB (dialogo Abrir, exportacao, Sobre, README).
- Lista de tabelas e seletor de colunas mostram o nome inteiro (quebra a linha; nada de "...").
- Colunas...: **Show all**/**Hide all** agem so nas colunas listadas pela busca do dialogo.
- O temporario da exportacao fica numa pasta propria, criada de forma exclusiva ao lado do destino.
- odbc-api so no Windows (o pacote Linux nao depende do unixODBC).
- Linux: X11 primeiro (`GDK_BACKEND=x11,wayland` quando o usuario nao definiu), Wayland so de reserva, com aviso
  "Display mode" e o comando da distro quando o X11 falta (README, secao "Linux: X11 e Wayland").

### Corrigido

- Campo Moeda (Currency) do Access pelo mdbtools perdia a 3a e a 4a casa (`1234567.8912` virava `1234567.89`).
- SQLite (convertido do Access e Exportar > SQLite): Moeda e decimais com mais de 15 digitos iam como texto, e no
  sqlite3 `WHERE preco > 20`, `ORDER BY` e `SUM` comparavam como texto (nwind: 47 linhas e soma 1670.87 em vez de
  37 e 1695.11). Agora vao como REAL quando cabem exatos num DOUBLE (`REAL_DECIMAL(p,s)`).

## 1.2.0

### Novo

- Titulo curto: `mdb2sql 1.2.0 - Rust`; os detalhes foram para o About.
- About novo: nome e versao em destaque, build, stack com versoes (Rust + Tauri + Svelte), WebView2, DuckDB,
  SQLite, leitor do Access, autor, licenca e links clicaveis para GitHub e GitLab (plugin opener do Tauri,
  liberado so para esses dois enderecos).
- **Colunas...**: ocultar e mostrar varias colunas de uma vez (Mostrar todas / Ocultar todas); botao direito no
  cabecalho: Ocultar esta coluna, Colunas..., Mostrar todas. "N colunas ocultas" na barra de status. Busca e
  exportacao continuam com todas as colunas. O dialogo acompanha a janela: ~65% da largura (420 a 900 px), ate
  70% da altura, busca no topo, caixas em grade de 1 a 6 colunas pelo nome mais longo, rolagem so vertical.
- Botao direito na celula > **Filtrar por este valor**: coluna = valor exato na consulta ao banco (valor por
  parametro, NULL vira IS NULL), varios filtros somam, chips com remover um a um e Limpar filtros; contagem de
  linhas filtradas.
- Licenca: GPL v2 ou posterior (antes: proprietaria). LICENSE vai no zip e nos instaladores.

### Mudado

- Sem acoes repetidas: saiu o botao Export... da barra (repetia File > Export) e o File > Open... (repetia o
  Browse...). Teste conta os botoes e itens de menu.
- Sem instrucoes na tela: campos e avisos so com rotulos curtos (ex.: "Search loaded rows", "Filter tables");
  atalho e detalhe ficam em dica de uma linha ou no README.
- Textos um passo menores (base 14 -> 13 px; titulos, grade e notas na mesma proporcao; nada abaixo de 11 px).
- Grade igual as outras stacks: NULL aparece como celula vazia e DOUBLE inteiro sem ".0" (so na tela; copiar,
  filtrar e exportar nao mudam).

### Corrigido

- Exportar apagava um arquivo do usuario que tivesse o nome do temporario (`<nome>.partial` e `.partial.wal`).
  Agora o temporario tem nome unico por exportacao e o destino anterior so e trocado no sucesso.
- Exportar para SQLite arredondava decimais com mais de 15 digitos, HUGEINT/UHUGEINT e UBIGINT acima de 2^63
  (a afinidade do SQLite convertia o texto em REAL). Agora ficam como texto exato e reabrem com o tipo DuckDB.
- Inteiros acima de 2^53 (BIGINT/UBIGINT) perdiam digitos na grade, na copia e no filtro (Number do
  JavaScript); agora vao como texto. UHUGEINT aparecia como `UHugeInt(...)`.
- Colunas quase so de NULL (ex.: as depois de PNTNAM no RANGER_SOSTAT) pareciam transparentes (cor apagada e
  opacity 0,7) e o texto das linhas passava por cima do cabecalho fixo.
- Nome da tabela acima da grade e cabecalhos de coluna sempre inteiros (a coluna cresce ate caber nome e
  valores); nome longo na lista de tabelas ganha dica com o nome inteiro.
- O menu do botao direito perto da borda da janela era cortado; agora fica dentro da janela.

## 1.1.1

- Icone proprio do mdb2sql (exe, janela, instaladores) e versao na barra de titulo.
- Busca da aba Data e filtro de tabelas por palavras (todas numa mesma celula, qualquer ordem, sem maiusculas nem
  acentos). Antes a busca procurava o texto exato: texto com espacos repetidos (2.499 valores no DB4, que a grade
  mostra com um espaco so) nao era achado pelo que aparecia na tela, nem `tensao` achava `TENSÃO`.

## 1.1.0

- Abre .duckdb/.sqlite/.mdb/.accdb e exporta para DuckDB, SQLite, Excel e CSV.
