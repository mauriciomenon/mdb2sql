// Roda com: pnpm --filter mdb2sql-ui test  (node --test, sem dependencias)
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { baseName, defaultSaveDir, dirOf, joinPath, stem, suggestedName } from './paths.js';

test('save dialog starts in the folder of the open file, else in the last folder used', () => {
  assert.equal(defaultSaveDir('D:\\dados\\DB4.accdb', 'E:\\outra'), 'D:\\dados');
  assert.equal(defaultSaveDir('/srv/db/x.sqlite', '/tmp'), '/srv/db');
  assert.equal(defaultSaveDir('', 'E:\\outra'), 'E:\\outra');
  assert.equal(defaultSaveDir(null, null), '');
});

test('paths split and join on Windows and Unix separators', () => {
  assert.equal(dirOf('C:\\a\\b\\c.duckdb'), 'C:\\a\\b');
  assert.equal(dirOf('c.duckdb'), '');
  assert.equal(baseName('C:\\a\\b\\c.duckdb'), 'c.duckdb');
  assert.equal(stem('C:\\a\\2026-07-14 DB4.accdb'), '2026-07-14 DB4');
  assert.equal(stem('noext'), 'noext');
  assert.equal(joinPath('C:\\a', 'x.csv'), 'C:\\a\\x.csv');
  assert.equal(joinPath('C:\\', 'x.csv'), 'C:\\x.csv');
  assert.equal(joinPath('/tmp', 'x.csv'), '/tmp/x.csv');
  assert.equal(joinPath('', 'x.csv'), 'x.csv');
});

test('suggested name never points at the open file and has no invalid characters', () => {
  assert.equal(suggestedName('2026-07-14 DB4', 'duckdb', 'D:\\d\\2026-07-14 DB4.accdb'), '2026-07-14 DB4.duckdb');
  assert.equal(suggestedName('DB4', 'duckdb', 'D:\\d\\db4.DUCKDB'), 'DB4 (export).duckdb');
  assert.equal(suggestedName('a/b:c', 'csv', ''), 'a_b_c.csv');
  assert.equal(suggestedName('', 'xlsx', ''), 'export.xlsx');
});
