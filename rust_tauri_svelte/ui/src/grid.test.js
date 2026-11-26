// Roda com: pnpm --filter mdb2sql-ui test  (node --test, sem dependencias)
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import {
  ROW_ID,
  cellText,
  columnCellWidth,
  filterLabel,
  fold,
  gridRows,
  hasAllWords,
  importantEntry,
  favoritesFirst,
  parseTerms,
  resolveContext,
  rowToTsv,
  rowsToTsv,
  searchWords,
  setListed,
  statusLine,
  termsOutcome,
  toggleFavorite,
  toggleHidden,
  toggleMarked,
  toggleShown,
  tsvField,
  unreadEntries,
  visibleColumns,
  withFilter,
  withIds,
} from './grid.js';

// item 31: as marcadas ficam sempre no topo, na ordem da tabela, qualquer que seja a pesquisa; abaixo, as linhas da
// pesquisa de agora sem repetir as marcadas. Exemplo do dono: busca kkk, marca 1 de 3; busca jjj, a de kkk continua no
// topo; marca 1 de jjj; busca hhh, marca 1: 3 marcadas no topo
test('marked rows stay on top in table order, whatever the search', () => {
  const page = (...ids) => withIds(ids.map((id) => ({ n: id })), ids);
  const shown = (marked, rows, only) => gridRows(marked, rows, only).map((row) => row[ROW_ID]);
  const kkk = page(40, 41, 42);
  let marked = toggleMarked([], kkk[1]);
  assert.deepEqual(shown(marked, kkk), [41, 40, 42], 'marked first, not repeated below');
  const jjj = page(7, 8);
  assert.deepEqual(shown(marked, jjj), [41, 7, 8], 'the kkk row stays on top of another search');
  marked = toggleMarked(marked, jjj[0]);
  const hhh = page(90, 91);
  marked = toggleMarked(marked, hhh[1]);
  assert.deepEqual(shown(marked, hhh), [7, 41, 91, 90], '3 marked on top, in table order');
  assert.deepEqual(shown(marked, hhh, true), [7, 41, 91], 'only the marked ones');
  // a mesma linha relida do banco (outro objeto, mesma identidade) desmarca; a lista antiga nao muda
  const before = marked;
  marked = toggleMarked(marked, page(41)[0]);
  assert.deepEqual(shown(marked, []), [7, 91]);
  assert.equal(before.length, 3);
  // tabela sem rowid: a identidade e texto e a linha marcada entra no fim
  const texts = withIds([{ n: 1 }, { n: 2 }], ['b', 'a']);
  assert.deepEqual(toggleMarked(toggleMarked([], texts[0]), texts[1]).map((row) => row[ROW_ID]), ['b', 'a']);
  // a identidade nao e coluna: copiar a linha nao a leva
  assert.equal(rowToTsv(['n'], kkk[0]), '40');
  assert.deepEqual(Object.keys(kkk[0]), ['n']);
});

// item 34: favoritas no topo da lista de tabelas, em ordem alfabetica, depois as outras na ordem de sempre; o filtro vale
// para elas (a lista ja vem filtrada) e favorita que nao existe no arquivo aberto nao aparece
test('favorite tables come first, in alphabetical order', () => {
  const tables = ['A_ONE', 'RANGER_SOTEXT', 'B_TWO', 'RANGER_SOEQID', 'RANGER_SOSTAT', 'Z_LAST'];
  let favorites = new Set();
  for (const name of ['RANGER_SOSTAT', 'RANGER_SOEQID', 'RANGER_SOTEXT', 'NOT_IN_THIS_FILE']) favorites = toggleFavorite(favorites, name);
  assert.deepEqual(favoritesFirst(tables, favorites), ['RANGER_SOEQID', 'RANGER_SOSTAT', 'RANGER_SOTEXT', 'A_ONE', 'B_TWO', 'Z_LAST']);
  // filtro "TEXT ONE": so as que passam, favoritas primeiro
  assert.deepEqual(favoritesFirst(['A_ONE', 'RANGER_SOTEXT'], favorites), ['RANGER_SOTEXT', 'A_ONE']);
  // desfavoritar volta a tabela ao lugar de sempre; o Set antigo nao muda
  const fewer = toggleFavorite(favorites, 'RANGER_SOSTAT');
  assert.deepEqual(favoritesFirst(tables, fewer), ['RANGER_SOEQID', 'RANGER_SOTEXT', 'A_ONE', 'B_TWO', 'RANGER_SOSTAT', 'Z_LAST']);
  assert.ok(favorites.has('RANGER_SOSTAT'));
  assert.deepEqual(favoritesFirst(tables, new Set()), tables);
  // na tela: a lista usa a ordem, "★ " antes do nome; nada gravado (fechar e abrir outro mantem: resetTable nao zera)
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  assert.match(app, /return favoritesFirst\(tables\.filter\(\(name\) => hasAllWords\(fold\(name\), words\)\), favorites\);/);
  assert.match(app, /<span class="name">\{favorites\.has\(name\) \? '★ ' : ''\}\{name\}<\/span>/);
  assert.match(app, /oncontextmenu=\{\(e\) => openStatusMenu\(e, name\)\}/);
  // o menu abre abaixo do ponto clicado (nao cobre a tabela); o da barra de status, acima
  assert.match(app, /aria-label=\{text\} style="left: \{contextMenu\.x\}px; top: \{contextMenu\.y\}px" use:keepInside=\{false\}>/);
  assert.match(app, /node\.style\.top = `\$\{Math\.max\(4, Math\.min\(above \? box\.top - box\.height : box\.top \+ 4, innerHeight - box\.height - 4\)\)\}px`;/);
  assert.match(app, /\{@const text = t\(favorites\.has\(contextMenu\.table\) \? 'fav\.remove' : 'fav\.add'\)\}/);
  assert.match(app, /\n {6}favorite: \{ run: \(\) => setFavorite\(selectedTable\), off: !selectedTable \},/);
  assert.doesNotMatch(app.match(/\n {2}function resetTable\(\) \{[\s\S]*?\n {2}\}/)[0], /favorites/);
  assert.doesNotMatch(app, /saveSetting\([^)]*[Ff]avorit/);
});

// item 32: termos = cada linha nao vazia, sem espacos nas pontas; repetidos (sem diferenciar maiusculas, como a
// comparacao) contam uma vez; nada de tratar cabecalho: a 1a linha colada do Excel e um termo como os outros
test('pasted terms: one per non-empty line, trimmed, repeated ones counted once', () => {
  const pasted = 'PNTNAM\r\n  GERADOR A  \r\n\r\nTURBINA B\ngerador a\n\t\nTURBINA B\rC';
  assert.deepEqual(parseTerms(pasted), { terms: ['PNTNAM', 'GERADOR A', 'TURBINA B', 'C'], repeated: 2 });
  assert.deepEqual(parseTerms('  \n\n'), { terms: [], repeated: 0 });
  assert.deepEqual(parseTerms('um termo com espacos dentro'), { terms: ['um termo com espacos dentro'], repeated: 0 });
  // secao 17: os 8 termos do dono colados do Excel (CRLF e a quebra do fim) = 8 termos
  const owner = [
    'GENERADOR CGS VIBRACION ANORMAL 1 CANAL 1',
    'GENERADOR CGS VIBRACION ANORMAL 2 CANAL 1',
    'TURBINA CGI VIBRACION ANORMAL 1 CANAL 1',
    'GENERADOR COJ EMP VIBRACION ANORMAL 1 CANAL 1',
    'GENERADOR COJ EMP VIBRACION ANORMAL 2 CANAL 1',
    'GENERADOR GGB ALIMENTACION CONTROL 24VCC',
    'GENERADOR GGB INTERRUPTORES CONTROL CIRCUITO 2',
    'TURBINA CGI VIBRACION ANORMAL 2 CANAL 1',
  ];
  assert.deepEqual(parseTerms(`${owner.join('\r\n')}\r\n`), { terms: owner, repeated: 0 });
});

// resultado: tabelas com acerto (linhas somadas dos termos), nao encontrados na ordem colada, termos achados e linhas
test('term search outcome: tables with hits, terms not found in pasted order, totals', () => {
  const terms = ['PNTNAM', 'A', 'B', 'C', 'D'];
  const hits = [
    { ord: 1, table: 'RANGER_SOSTAT', count: 2 },
    { ord: 3, table: 'RANGER_SOSTAT', count: 1 },
    { ord: 1, table: 'ZZ', count: 4 },
  ];
  assert.deepEqual(termsOutcome(terms, hits), {
    tables: [{ table: 'RANGER_SOSTAT', count: 3 }, { table: 'ZZ', count: 4 }],
    notFound: ['PNTNAM', 'B', 'D'],
    found: 2,
    rows: 7,
  });
  assert.deepEqual(termsOutcome(['x'], []), { tables: [], notFound: ['x'], found: 0, rows: 0 });
});

// Copiar as linhas encontradas: cabecalho e linhas separados por TAB, sem linha a mais (nem no fim)
test('found rows are copied with the header and no extra line', () => {
  const rows = [{ Termo: 'A', id: 1, name: 'x\ty' }, { Termo: 'B', id: 2, name: null }];
  assert.equal(rowsToTsv(['id', 'name'], rows), 'id\tname\r\n1\t"x\ty"\r\n2\t');
  assert.equal(rowsToTsv(['id'], []), 'id');
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  // todas as linhas achadas (limit 0), sem a coluna Termo (a primeira)
  assert.match(app, /invoke\('terms_rows', \{ table: termsTable, limit: 0, label: t\('terms\.col'\) \}\);\s*const names = all\.columns\.slice\(1\)\.map\(\(col\) => col\.name\);/);
  assert.match(app, /extra=\{termsExtra\}\s*copySkip=\{1\}/);
  const grid = readFileSync(new URL('./Grid.svelte', import.meta.url), 'utf8');
  assert.match(grid, /const names = columns\.slice\(copySkip\)\.map\(\(col\) => col\.name\);/);
});

// padrao item 16: SQL que roda sem erro tira o erro de SQL anterior da barra de baixo e do contador (outros erros ficam)
test('a SQL run without error clears the earlier SQL error from the status bar', () => {
  const log = [
    { level: 'error', context: 'status.openFailed', n: 1 },
    { level: 'error', context: 'err.sql', n: 2 },
    { level: 'info', key: 'status.query', n: 3 },
  ];
  assert.equal(importantEntry(unreadEntries(log)).n, 2);
  const after = resolveContext(log, 'err.sql');
  assert.deepEqual(unreadEntries(after).map((e) => e.n), [1]);
  assert.equal(importantEntry(unreadEntries(after)).n, 1);
  assert.equal(after.length, 3); // o texto continua no log
  assert.equal(log[1].resolved, undefined); // o log antigo nao muda
});

// erro do SQL na linha do botao (texto do motor com o prefixo traduzido), a grade velha sai; dica "SELECT * FROM ..."
test('SQL tab: error on the Run line, the old grid leaves, hint SELECT * FROM ...', () => {
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  const run = app.match(/\n {2}async function runSql\(\) \{[\s\S]*?\n {2}\}/)[0];
  assert.match(run, /lastSql = query;\s*sqlError = '';\s*log = resolveContext\(log, 'err\.sql'\);/);
  assert.match(run, /catch \(err\) \{\s*sqlResult = null;\s*lastSql = '';\s*sqlError = String\(err\);\s*showError\(err, sqlContext\(err\)\);/);
  assert.match(app, /\{#if sqlError\}\s*<span class="sql-error">\{statusLine\(errorLine\(sqlError, sqlContext\(sqlError\)\)\)\}<\/span>\s*\{:else if sqlResult\}/);
  // erro do motor: prefixo "Erro na consulta SQL"; comando recusado (aba so de leitura): so a frase do catalogo
  assert.match(app, /const sqlContext = \(err\) => \(String\(err\)\.includes\('\[\[err\.sqlReadOnly\]\]'\) \? undefined : 'err\.sql'\);/);
  assert.match(app, /const SQL_HINT = 'SELECT \* FROM \.\.\.';/);
  // abrir outro arquivo ou fechar tira o erro de SQL da linha do botao e da barra de baixo, juntos
  for (const name of ['openDatabase', 'closeDatabase']) {
    const body = app.match(new RegExp(`\\n {2}async function ${name}\\([^)]*\\) \\{[\\s\\S]*?\\n {2}\\}`))[0];
    assert.match(body, /sqlError = '';\s*log = resolveContext\(log, 'err\.sql'\);/, name);
  }
  assert.match(app, /placeholder=\{SQL_HINT\}/);
});

test('several columns are hidden at once and shown again, order kept', () => {
  const columns = [{ name: 'id' }, { name: 'SIGLA' }, { name: 'note' }];
  let hidden = new Set();
  assert.deepEqual(visibleColumns(columns, hidden), columns);
  const before = hidden;
  hidden = toggleHidden(toggleHidden(hidden, 'note'), 'id');
  assert.equal(before.size, 0); // o Set antigo nao muda (a tela so reage a um Set novo)
  assert.deepEqual(visibleColumns(columns, hidden), [{ name: 'SIGLA' }]);
  hidden = toggleHidden(hidden, 'id');
  assert.deepEqual(visibleColumns(columns, hidden).map((c) => c.name), ['id', 'SIGLA']);
  assert.deepEqual(visibleColumns(columns, new Set(['id', 'SIGLA', 'note'])), []);
});

// menu do cabecalho: a lista alterna as colunas, uma ou varias, mas a ultima visivel nunca sai
test('the header menu hides several columns but never the last visible one', () => {
  let hidden = toggleShown(toggleShown(new Set(), 'a', 3), 'b', 3);
  assert.deepEqual([...hidden], ['a', 'b']);
  assert.equal(toggleShown(hidden, 'c', 3), hidden); // c e a ultima visivel: fica
  hidden = toggleShown(hidden, 'a', 3); // mostrar de novo continua valendo
  assert.deepEqual([...hidden], ['b']);
  assert.equal(toggleShown(new Set(), 'x', 1).size, 0); // tabela de uma coluna so
});

// Colunas... com busca: Mostrar/Ocultar todas valem so para as colunas listadas; as outras ficam como estavam
test('Show all / Hide all act only on the listed (searched) columns', () => {
  let hidden = new Set(['note']);
  hidden = setListed(hidden, ['RTUNO', 'RTUNAM'], true);
  assert.deepEqual([...hidden].sort(), ['RTUNAM', 'RTUNO', 'note']);
  hidden = setListed(hidden, ['RTUNO'], false);
  assert.deepEqual([...hidden].sort(), ['RTUNAM', 'note']);
  const before = hidden;
  assert.notEqual(setListed(before, [], true), before); // sempre um Set novo
  assert.deepEqual([...before].sort(), ['RTUNAM', 'note']);
  // decisao 3: Ocultar todas deixa uma visivel, a primeira listada (tabela de 4 colunas)
  const all = ['RTUNO', 'RTUNAM', 'note', 'id'];
  assert.deepEqual([...setListed(new Set(), all, true, 4)].sort(), ['RTUNAM', 'id', 'note']);
  assert.deepEqual([...setListed(new Set(['RTUNO', 'id']), ['RTUNAM', 'note'], true, 4)].sort(), ['RTUNO', 'id', 'note']);
  assert.deepEqual([...setListed(new Set(), ['note'], true, 4)], ['note']); // sobram outras visiveis: oculta
  assert.equal(setListed(new Set(), ['x'], true, 1).size, 0); // tabela de uma coluna so
});

// a grade mostra cellText: igual as outras stacks, DOUBLE inteiro sem ".0"; NULL e o texto de Settings > Exibir NULL
// (desligado por padrao: vazio; ligado: "NULL"); texto vazio continua vazio e copiar continua com NULL vazio
test('grid shows whole doubles without .0 and NULL as the Show NULL setting says', () => {
  const row = JSON.parse('{"RTUNO": 2.0, "PNTNO": 2316.0, "x": 0.1, "big": "9007199254740993", "n": null, "e": ""}');
  const shown = (nullText) => Object.values(row).map((v) => cellText(v, nullText));
  assert.deepEqual(shown('NULL'), ['2', '2316', '0.1', '9007199254740993', 'NULL', '']);
  assert.deepEqual(shown(''), ['2', '2316', '0.1', '9007199254740993', '', '']);
  assert.equal(rowToTsv(['n', 'x'], row), '\t0.1'); // copiar: NULL vazio
  const grid = readFileSync(new URL('./Grid.svelte', import.meta.url), 'utf8');
  assert.match(grid, /<td data-c=\{c\}[^>]*>\{cellText\(value, nullText\)\}<\/td>/);
  assert.doesNotMatch(grid, />NULL</);
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  assert.match(app, /let showNull = \$state\(loadSetting\(NULL_KEY\) === 'on'\);/); // desligado por padrao (sem valor), gravado
  assert.match(app, /saveSetting\(NULL_KEY, show \? 'on' : 'off'\);/);
  assert.equal(app.split('{nullText}').length - 1, 4); // Data, Schema, SQL e Termos
});

test('Columns... cell fits the longest name and type', () => {
  const columns = [{ name: 'RTUNO', type: 'DOUBLE' }, { name: 'PNTNAM', type: 'VARCHAR' }];
  assert.equal(columnCellWidth(columns), 'calc(7.2ch + 7ch + 44px)');
  assert.equal(columnCellWidth([]), 'calc(1.2ch + 1ch + 44px)'); // tabela sem colunas nao quebra o CSS
});

test('filters add up, one per column, and keep the value type', () => {
  let filters = withFilter([], 'SIGLA', 'U9A');
  filters = withFilter(filters, 'RTUNO', 2);
  filters = withFilter(filters, 'note', undefined); // celula sem valor = NULL
  assert.deepEqual(filters, [
    { column: 'SIGLA', value: 'U9A' },
    { column: 'RTUNO', value: 2 },
    { column: 'note', value: null },
  ]);
  filters = withFilter(filters, 'SIGLA', 'U18A'); // mesma coluna: troca o valor
  assert.deepEqual(filters.map(filterLabel), ['RTUNO = 2', 'note IS NULL', "SIGLA = 'U18A'"]);
  assert.equal(filterLabel({ column: 'ok', value: false }), 'ok = false');
  assert.equal(filterLabel({ column: 'n', value: '2' }), "n = '2'"); // texto '2' nao e o numero 2
});

test('plain values are copied unchanged, NULL as empty', () => {
  assert.equal(tsvField('abc'), 'abc');
  assert.equal(tsvField(12.5), '12.5');
  assert.equal(tsvField(0), '0');
  assert.equal(tsvField(false), 'false');
  assert.equal(tsvField(null), '');
  assert.equal(cellText(undefined), '');
});

test('TAB, line breaks and quotes inside a value are quoted for Excel', () => {
  assert.equal(tsvField('a\tb'), '"a\tb"');
  assert.equal(tsvField('line1\nline2'), '"line1\nline2"');
  assert.equal(tsvField('cr\r\nlf'), '"cr\r\nlf"');
  assert.equal(tsvField('say "hi"'), '"say ""hi"""');
});

test('row is TAB-separated in column order, header optional', () => {
  const names = ['id', 'name', 'note'];
  const row = { note: 'x\ty', id: 1, name: null };
  assert.equal(rowToTsv(names, row), '1\t\t"x\ty"');
  assert.equal(rowToTsv(names, row, true), 'id\tname\tnote\r\n1\t\t"x\ty"');
});


test('table filter uses the same words rule', () => {
  const tables = ['RANGER_SOANLG', 'RANGER_SOSTAT', 'Medição Área'];
  const pick = (query) => tables.filter((t) => hasAllWords(fold(t), searchWords(query)));
  assert.deepEqual(pick('anlg ranger'), ['RANGER_SOANLG']);
  assert.deepEqual(pick('area medicao'), ['Medição Área']);
  assert.deepEqual(pick(''), tables);
});

test('collapsed log shows the last error, else the last warning, else nothing', () => {
  const e = (level, n) => ({ level, n });
  assert.equal(importantEntry([e('warning', 1), e('error', 2), e('warning', 3), e('info', 4)]).n, 2);
  assert.equal(importantEntry([e('error', 1), e('error', 2)]).n, 2);
  assert.equal(importantEntry([e('info', 1), e('warning', 2), e('warning', 3)]).n, 3);
  assert.equal(importantEntry([e('info', 1)]), null);
  assert.equal(importantEntry([]), null);
});

test('engine errors show one line in the status bar, with the translated prefix', () => {
  const duck = 'SQL query error: Parser Error: syntax error at or near "selec"\n\nLINE 1: selec 1\n        ^';
  assert.equal(statusLine(duck), 'SQL query error: syntax error at or near "selec"');
  assert.equal(statusLine('Erro na consulta SQL: Catalog Error: Table with name x does not exist!'), 'Erro na consulta SQL: Table with name x does not exist!');
  assert.equal(statusLine('Opened via mdbtools → SQLite'), 'Opened via mdbtools → SQLite');
});
