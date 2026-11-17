# Changelog - mdb2sql (Rust + Tauri + Svelte)

## 1.2.0

- Titulo curto: `mdb2sql 1.2.0 - Rust`; os detalhes foram para o About.
- About novo: nome e versao em destaque, build, stack com versoes (Rust + Tauri + Svelte), WebView2, DuckDB,
  SQLite, leitor do Access, autor, licenca e links clicaveis para GitHub e GitLab (plugin opener do Tauri,
  liberado so para esses dois enderecos).
- **Colunas...**: ocultar e mostrar varias colunas de uma vez (Mostrar todas / Ocultar todas); botao direito no
  cabecalho: Ocultar esta coluna, Colunas..., Mostrar todas. "N colunas ocultas" na barra de status. Busca e
  exportacao continuam com todas as colunas.
- Botao direito na celula > **Filtrar por este valor**: coluna = valor exato na consulta ao banco (valor por
  parametro, NULL vira IS NULL), varios filtros somam, chips com remover um a um e Limpar filtros; contagem de
  linhas filtradas.
- Sem acoes repetidas: saiu o botao Export... da barra (repetia File > Export) e o File > Open... (repetia o
  Browse...). Teste conta os botoes e itens de menu.
- Correcao: colunas quase so de NULL (ex.: as depois de PNTNAM no RANGER_SOSTAT) pareciam transparentes; o NULL
  tinha cor apagada e opacity 0,7. Agora so italico, com o mesmo contraste das outras celulas (claro e escuro), e
  o cabecalho fixo nao deixa mais o texto das linhas passar por cima dele.
- Dialogo **Colunas...** proporcional a janela: ~65% da largura (420 a 900 px), ate 70% da altura, busca no topo,
  caixas em grade de 1 a 6 colunas pela largura do nome mais longo, fonte base, rolagem so vertical.
- Textos um passo menores (base 14 -> 13 px; titulos, grade e notas na mesma proporcao; nada abaixo de 11 px).
- Nome da tabela acima da grade e cabecalhos de coluna sempre inteiros (a coluna cresce ate caber nome e
  valores, sem limite); teste confere. Nome longo na lista de tabelas ganha dica com o nome inteiro.
- Correcao: o menu do botao direito perto da borda da janela era cortado; agora fica dentro da janela.
- Licenca: GPL v2 ou posterior (antes: proprietaria). LICENSE vai no zip e nos instaladores.

## 1.1.1

- Icone proprio do mdb2sql (exe, janela, instaladores) e versao na barra de titulo.
- Busca da aba Data e filtro de tabelas por palavras (todas numa mesma celula, qualquer ordem, sem maiusculas nem
  acentos). Antes a busca procurava o texto exato: texto com espacos repetidos (2.499 valores no DB4, que a grade
  mostra com um espaco so) nao era achado pelo que aparecia na tela, nem `tensao` achava `TENSÃO`.

## 1.1.0

- Abre .duckdb/.sqlite/.mdb/.accdb e exporta para DuckDB, SQLite, Excel e CSV.
