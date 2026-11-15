// Roda com: pnpm --filter mdb2sql-ui test  (node --test, sem dependencias)
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { cellText, rowMatches, rowToTsv, tsvField } from './grid.js';

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

test('search looks in every column, ignoring case', () => {
  const row = { id: 42, name: 'Ranger', when: '2026-07-14 10:00:00', gone: null };
  assert.ok(rowMatches(row, ''));
  assert.ok(rowMatches(row, '  rang '));
  assert.ok(rowMatches(row, '42'));
  assert.ok(rowMatches(row, '07-14'));
  assert.ok(!rowMatches(row, 'null'));
  assert.ok(!rowMatches(row, 'zzz'));
});
