// NIVEL BASICO: Logica da grade sem interface: texto para copiar, colunas ocultas, filtros e busca por palavras
// NIVEL TECNICO: plain module so `node --test` can run it without a browser

// Valor de uma celula como texto puro; NULL vira nullText (vazio para copiar; na grade, "NULL" com Settings > Exibir NULL)
export function cellText(value, nullText = '') {
  return value === null || value === undefined ? nullText : String(value);
}

// Campo no formato que o Excel entende ao colar: TAB, quebra de linha ou aspas dentro do valor
// exigem o campo entre aspas, com as aspas internas dobradas
export function tsvField(value) {
  const text = cellText(value);
  return /[\t\r\n"]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

// Linha inteira separada por TAB, na ordem das colunas; withHeader poe os nomes na linha de cima
export function rowToTsv(columnNames, row, withHeader = false) {
  const line = columnNames.map((name) => tsvField(row[name])).join('\t');
  return withHeader ? `${columnNames.map(tsvField).join('\t')}\r\n${line}` : line;
}

// Varias linhas com o cabecalho, sem nenhuma linha a mais: colar no Excel da exatamente o cabecalho e as linhas
export function rowsToTsv(columnNames, rows) {
  return [columnNames.map(tsvField).join('\t'), ...rows.map((row) => rowToTsv(columnNames, row))].join('\r\n');
}

// NIVEL BASICO: Linhas marcadas (aba Dados). Cada linha leva a identidade que o backend deu (rowid do DuckDB ou, sem
// ele, o resumo de todos os valores) numa chave que nao e coluna; as marcas de uma tabela sao um Set de identidades
export const ROW_ID = Symbol('row id');

// linhas do backend com a identidade de cada uma (`ids` na mesma ordem)
export function withIds(rows, ids) {
  rows.forEach((row, i) => (row[ROW_ID] = ids[i]));
  return rows;
}

// o que a grade mostra: as marcadas no topo (ordem da tabela) e, abaixo, as linhas da pesquisa sem repetir as marcadas;
// only = so as marcadas
export function gridRows(marked, page, only = false) {
  if (only) return marked;
  const ids = new Set(marked.map((row) => row[ROW_ID]));
  return [...marked, ...page.filter((row) => !ids.has(row[ROW_ID]))];
}

// marca ou desmarca a linha: devolve a lista nova de marcadas (a antiga nao muda). rowid e numero e cresce na ordem
// da tabela, entao a lista fica nessa ordem; identidade de texto (tabela sem rowid) entra no fim
export function toggleMarked(marked, row) {
  const id = row[ROW_ID];
  if (marked.some((other) => other[ROW_ID] === id)) return marked.filter((other) => other[ROW_ID] !== id);
  const next = [...marked, row];
  return typeof id === 'number' ? next.sort((a, b) => a[ROW_ID] - b[ROW_ID]) : next;
}

// NIVEL BASICO: Pesquisa de termos. Termos = cada linha nao vazia do texto colado, sem espacos nas pontas; repetido
// (sem diferenciar maiusculas, como a comparacao) e pesquisado uma vez e contado em `repeated`. A primeira linha
// colada do Excel (o titulo da coluna) e um termo como os outros
export function parseTerms(text) {
  const seen = new Set();
  const terms = [];
  let repeated = 0;
  for (const line of text.split(/\r?\n|\r/)) {
    const term = line.trim();
    if (!term) continue;
    const key = term.toLowerCase();
    if (seen.has(key)) repeated++;
    else terms.push(term);
    seen.add(key);
  }
  return { terms, repeated };
}

// resultado da pesquisa (hits = [{ ord, table, count }] do backend, na ordem das tabelas): tabelas com acerto e as
// linhas de cada uma, termos nao encontrados na ordem colada, quantos termos foram achados e o total de linhas
export function termsOutcome(terms, hits) {
  const tables = [];
  const found = new Set();
  for (const { ord, table, count } of hits) {
    found.add(ord);
    const last = tables.at(-1);
    if (last?.table === table) last.count += count;
    else tables.push({ table, count });
  }
  return {
    tables,
    notFound: terms.filter((_, ord) => !found.has(ord)),
    found: found.size,
    rows: tables.reduce((sum, t) => sum + t.count, 0),
  };
}

// NIVEL BASICO: Colunas ocultas: `hidden` e um Set com os nomes; a grade recebe so as visiveis
// (pesquisa e exportacao continuam com todas)
export function visibleColumns(columns, hidden) {
  return columns.filter((col) => !hidden.has(col.name));
}

// largura de uma caixa do dialogo Colunas... (CSS): caixa + nome mais longo + tipo mais longo. Em `ch` (largura
// do "0"): maiusculas do Segoe UI tem ~1,2ch e o tipo, menor, ~1ch por letra
export function columnCellWidth(columns) {
  const longest = (key) => Math.max(1, ...columns.map((col) => String(col[key] ?? '').length));
  return `calc(${(longest('name') * 1.2).toFixed(1)}ch + ${longest('type')}ch + 44px)`;
}

// novo Set com a coluna trocada de lado (oculta <-> visivel); o Set antigo nao muda
export function toggleHidden(hidden, name) {
  const next = new Set(hidden);
  if (!next.delete(name)) next.add(name);
  return next;
}

// menu do cabecalho: como toggleHidden, menos para a ultima coluna visivel (total = colunas da tabela), que fica
export function toggleShown(hidden, name, total) {
  return !hidden.has(name) && total - hidden.size <= 1 ? hidden : toggleHidden(hidden, name);
}

// Mostrar todas (hide = false) / Ocultar todas (hide = true) so nas colunas listadas no dialogo Colunas...
// (com busca, so as que aparecem); devolve um Set novo. Ocultar nunca deixa a tabela (total colunas) sem coluna
// visivel: com todas ocultas, a primeira listada volta (como no Zig)
export function setListed(hidden, names, hide, total = Infinity) {
  const next = new Set(hidden);
  for (const name of names) {
    if (hide) next.add(name);
    else next.delete(name);
  }
  if (hide && next.size >= total) next.delete(names[0]);
  return next;
}

// NIVEL BASICO: Filtros da grade: lista de { column, value } somados com AND na consulta ao banco.
// Filtrar de novo pela mesma coluna troca o valor (dois valores diferentes na mesma coluna nao achariam nada)
export function withFilter(filters, column, value) {
  return [...filters.filter((f) => f.column !== column), { column, value: value ?? null }];
}

// como o filtro aparece na tela: SIGLA = 'U9A', RTUNO = 2, NOTA IS NULL
export function filterLabel({ column, value }) {
  if (value === null) return `${column} IS NULL`;
  return `${column} = ${typeof value === 'string' ? `'${value}'` : value}`;
}

// NIVEL BASICO: Texto para comparar na busca: minusculas e sem acento (ç vira c, ã vira a)
// NIVEL TECNICO: NFD splits a letter from its accent, \p{M} drops the accent marks
export function fold(text) {
  return text.toLowerCase().normalize('NFD').replace(/\p{M}/gu, '');
}

// Palavras da busca (separadas por espaco), ja sem acento e em minusculas; busca vazia = nenhuma palavra
export function searchWords(query) {
  return fold(query).split(/\s+/).filter(Boolean);
}

// true quando o texto (ja dobrado por fold) contem todas as palavras, em qualquer ordem
export function hasAllWords(text, words) {
  return words.every((word) => text.includes(word));
}

// NIVEL BASICO: Log recolhido: entradas que contam como nao lidas (erros e avisos ainda nao resolvidos)
export function unreadEntries(entries) {
  return entries.filter((e) => e.level !== 'info' && !e.resolved);
}

// Erros de um contexto (ex.: 'err.sql') resolvidos: um SQL que rodou depois sem erro tira o erro anterior da barra de
// status e do contador; o texto continua no log
export function resolveContext(entries, context) {
  return entries.map((e) => (e.context === context && !e.resolved ? { ...e, resolved: true } : e));
}

// NIVEL BASICO: Log recolhido: a linha que a barra de status mostra entre as nao lidas: o ultimo erro, senao o ultimo
// aviso; null quando nao ha nenhum (a barra mostra a ultima acao)
export function importantEntry(entries) {
  return entries.findLast((e) => e.level === 'error') ?? entries.findLast((e) => e.level === 'warning') ?? null;
}

// NIVEL BASICO: Erro do motor (DuckDB/SQLite) na barra de status: uma linha so, com o prefixo traduzido e sem o tipo
// do motor ("Parser Error: "); o texto inteiro (LINE 1, ^^^) fica no log
export function statusLine(text) {
  return text.split('\n')[0].replace(/^([^:]+: )[A-Z][A-Za-z ]* Error: /, '$1');
}
