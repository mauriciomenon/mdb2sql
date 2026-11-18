// NIVEL BASICO: Logica da grade sem interface: texto para copiar, colunas ocultas, filtros e busca por palavras
// NIVEL TECNICO: plain module so `node --test` can run it without a browser

// Valor de uma celula como texto puro (NULL vira vazio)
export function cellText(value) {
  return value === null || value === undefined ? '' : String(value);
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

// Mostrar todas (hide = false) / Ocultar todas (hide = true) so nas colunas listadas no dialogo Colunas...
// (com busca, so as que aparecem); devolve um Set novo
export function setListed(hidden, names, hide) {
  const next = new Set(hidden);
  for (const name of names) {
    if (hide) next.add(name);
    else next.delete(name);
  }
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

// NIVEL BASICO: Log recolhido: a linha que a barra de status mostra entre as nao lidas: o ultimo erro, senao o ultimo
// aviso; null quando nao ha nenhum (a barra mostra a ultima acao)
export function importantEntry(entries) {
  return entries.findLast((e) => e.level === 'error') ?? entries.findLast((e) => e.level === 'warning') ?? null;
}
