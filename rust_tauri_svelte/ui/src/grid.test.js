// Roda com: pnpm --filter mdb2sql-ui test  (node --test, sem dependencias)
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import {
  cellText,
  columnCellWidth,
  filterLabel,
  fold,
  hasAllWords,
  importantEntry,
  rowToTsv,
  searchWords,
  setListed,
  statusLine,
  toggleHidden,
  toggleShown,
  tsvField,
  visibleColumns,
  withFilter,
} from './grid.js';

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
  assert.equal(app.split('{nullText}').length - 1, 3); // Data, Schema e SQL
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
