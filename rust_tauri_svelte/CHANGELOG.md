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
- Licenca: GPL v2 ou posterior (antes: proprietaria). LICENSE vai no zip e nos instaladores.

## 1.1.1

- Icone proprio do mdb2sql (exe, janela, instaladores) e versao na barra de titulo.
- Busca da aba Data e filtro de tabelas por palavras (todas numa mesma celula, qualquer ordem, sem maiusculas nem
  acentos). Antes a busca procurava o texto exato: texto com espacos repetidos (2.499 valores no DB4, que a grade
  mostra com um espaco so) nao era achado pelo que aparecia na tela, nem `tensao` achava `TENSÃO`.

## 1.1.0

- Abre .duckdb/.sqlite/.mdb/.accdb e exporta para DuckDB, SQLite, Excel e CSV.
