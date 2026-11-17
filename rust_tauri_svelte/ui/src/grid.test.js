// Roda com: pnpm --filter mdb2sql-ui test  (node --test, sem dependencias)
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  cellText,
  filterLabel,
  fold,
  hasAllWords,
  hiddenStatus,
  rowMatches,
  rowToTsv,
  searchWords,
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
  assert.equal(hiddenStatus(hidden.size), '2 colunas ocultas');
  hidden = toggleHidden(hidden, 'id');
  assert.deepEqual(visibleColumns(columns, hidden).map((c) => c.name), ['id', 'SIGLA']);
  assert.equal(hiddenStatus(hidden.size), '1 coluna oculta');
  assert.equal(hiddenStatus(0), '');
  assert.deepEqual(visibleColumns(columns, new Set(['id', 'SIGLA', 'note'])), []);
});

test('hidden columns are still searched', () => {
  const row = { id: 1, SIGLA: 'U9A' };
  assert.ok(rowMatches(row, searchWords('u9a'))); // a busca olha a linha inteira, nao so as colunas visiveis
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

const matches = (row, query) => rowMatches(row, searchWords(query));

test('search looks in every column as displayed, ignoring case', () => {
  const row = { id: 42, name: 'Ranger', when: '2026-07-14 10:00:00', on: false, ratio: 0.5, gone: null };
  assert.ok(matches(row, '  rang '));
  assert.ok(matches(row, '42'));
  assert.ok(matches(row, '07-14 10:00'));
  assert.ok(matches(row, 'false'));
  assert.ok(matches(row, '0.5'));
  assert.ok(!matches(row, 'null')); // NULL e so marcador da grade, nao dado
  assert.ok(!matches(row, 'zzz'));
});

test('empty query returns every row', () => {
  const rows = [{ a: 'x' }, { a: null }, {}];
  assert.equal(rows.filter((row) => matches(row, '')).length, 3);
  assert.equal(rows.filter((row) => matches(row, ' \t ')).length, 3);
});

test('all words, any order, ignoring case and accents, inside one cell', () => {
  const row = { id: 7, PNTNAM: 'EXCITAÇÃO TENSÃO DE CAMPO' };
  assert.ok(matches(row, 'tensao de campo'));
  assert.ok(matches(row, 'campo tensao'));
  assert.ok(matches(row, 'EXCITAÇÃO TENSÃO DE CAMPO')); // a frase exata continua achando
  assert.ok(matches({ x: 'Excitação' }, 'EXCITACAO'));
  assert.ok(matches({ x: 'Año de la señal' }, 'ano senal'));
  assert.ok(!matches(row, 'tensao rotor')); // falta uma palavra: fora
});

test('words found only in different cells do not match', () => {
  const row = { RTUNAM: 'U18A TENSÃO', PNTNAM: 'CAMPO' };
  assert.ok(!matches(row, 'tensao campo'));
  assert.ok(matches(row, 'tensao u18a'));
});

// causa do "nao achou": a grade junta espacos seguidos num so; quem busca pelo texto que ve nao achava nada
test('text with repeated spaces is found by the single-spaced text the grid shows', () => {
  const row = { TMPNAM: 'BP_50   TEMPERATURA AMBIENTE ELEV 144', PNTNAM: 'GERADOR  FREQUENCIA\nDA UNIDADE' };
  assert.ok(matches(row, 'BP_50 TEMPERATURA AMBIENTE'));
  assert.ok(matches(row, 'gerador frequencia da unidade'));
});

test('table filter uses the same words rule', () => {
  const tables = ['RANGER_SOANLG', 'RANGER_SOSTAT', 'Medição Área'];
  const pick = (query) => tables.filter((t) => hasAllWords(fold(t), searchWords(query)));
  assert.deepEqual(pick('anlg ranger'), ['RANGER_SOANLG']);
  assert.deepEqual(pick('area medicao'), ['Medição Área']);
  assert.deepEqual(pick(''), tables);
});
