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
  toggleHidden,
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
});

// a grade mostra cellText: igual as outras stacks, DOUBLE inteiro sem ".0" e NULL vazio
test('grid shows whole doubles without .0 and NULL as an empty cell', () => {
  const row = JSON.parse('{"RTUNO": 2.0, "PNTNO": 2316.0, "x": 0.1, "big": "9007199254740993", "n": null}');
  assert.deepEqual(Object.values(row).map(cellText), ['2', '2316', '0.1', '9007199254740993', '']);
  const grid = readFileSync(new URL('./Grid.svelte', import.meta.url), 'utf8');
  assert.match(grid, /<td data-c=\{c\}[^>]*>\{cellText\(value\)\}<\/td>/);
  assert.doesNotMatch(grid, />NULL</);
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
