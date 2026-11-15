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

// Busca sem diferenciar maiusculas em todas as colunas; busca vazia aceita tudo
export function rowMatches(row, query) {
  const needle = query.trim().toLowerCase();
  return !needle || Object.values(row).some((value) => cellText(value).toLowerCase().includes(needle));
}
