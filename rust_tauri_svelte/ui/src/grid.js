// NIVEL BASICO: Logica da grade sem interface: texto para copiar e busca nas linhas carregadas
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

// novo Set com a coluna trocada de lado (oculta <-> visivel); o Set antigo nao muda
export function toggleHidden(hidden, name) {
  const next = new Set(hidden);
  if (!next.delete(name)) next.add(name);
  return next;
}

// texto da barra de status; nada oculto = vazio
export function hiddenStatus(count) {
  return count ? `${count} ${count === 1 ? 'coluna oculta' : 'colunas ocultas'}` : '';
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

// texto de cada celula dobrado uma vez por linha carregada, nao a cada tecla digitada
const foldedRows = new WeakMap();

function foldedCells(row) {
  let cells = foldedRows.get(row);
  if (!cells) foldedRows.set(row, (cells = Object.values(row).map((value) => fold(cellText(value)))));
  return cells;
}

// NIVEL BASICO: A linha aparece quando UMA celula tem todas as palavras (qualquer ordem, sem
// diferenciar maiusculas nem acentos); a celula e comparada pelo texto que a grade mostra (NULL vazio).
// Palavras separadas tambem acham texto com varios espacos seguidos, que a grade mostra como um so
export function rowMatches(row, words) {
  return !words.length || foldedCells(row).some((cell) => hasAllWords(cell, words));
}
