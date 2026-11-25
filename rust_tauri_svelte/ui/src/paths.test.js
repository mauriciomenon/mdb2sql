// Roda com: pnpm --filter mdb2sql-ui test  (node --test, sem dependencias)
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { baseName, defaultSaveDir, dirOf, joinPath, savedEntry, stem, suggestedName, withSaved } from './paths.js';

// padrao item 22: Access ja convertido e salvo, lembrado entre execucoes pela chave caminho|tamanho|data (a do backend);
// o mesmo arquivo sem mudanca acha o SQLite salvo; mudou (outra chave), converte de novo; a versao velha sai da lista
test('a saved conversion is found by the Access key and replaced when the Access changes', () => {
  const v1 = 'd:\\dados\\db4.accdb|100|1';
  const v2 = 'd:\\dados\\db4.accdb|120|2';
  let list = withSaved({}, v1, 'D:\\dados\\DB4.sqlite', 'd:\\dados\\db4.sqlite|50|3', 50);
  assert.deepEqual(savedEntry(list, v1), { dest: 'D:\\dados\\DB4.sqlite', destKey: 'd:\\dados\\db4.sqlite|50|3' });
  assert.equal(savedEntry(list, v2), null, 'changed Access: convert again');
  assert.equal(savedEntry(list, null), null);
  list = withSaved(list, 'e:\\x.mdb|1|1', 'E:\\x.sqlite', 'e:\\x.sqlite|1|1', 50);
  list = withSaved(list, v2, 'D:\\dados\\DB4.sqlite', 'd:\\dados\\db4.sqlite|60|4', 50);
  assert.deepEqual(Object.keys(list), ['e:\\x.mdb|1|1', v2], 'old version of the same Access removed');
  assert.deepEqual(Object.keys(withSaved(list, 'f:\\y.mdb|1|1', 'F:\\y.sqlite', 'k', 2)), [v2, 'f:\\y.mdb|1|1']);
  assert.equal(savedEntry({ [v1]: { dest: 'x' } }, v1), null, 'entry without its own key is ignored');
  // a tela: abre pelo SQLite salvo quando as duas chaves batem; lembra ao salvar; o dialogo e o do Go
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  assert.match(app, /const saved = await savedSqlite\(accessKey\);\s*const opened = await invoke\('load_database', \{ dbPath: path, saved \}\);/);
  assert.match(app, /return \(await invoke\('file_key', \{ path: entry\.dest \}\)\) === entry\.destKey \? entry\.dest : null;/);
  assert.match(app, /await rememberSaved\(convertedKey, saved\);/);
  assert.match(app, /convertedKey = opened\.converted \? accessKey : null;/);
  assert.match(app, /<p class="file">\{t\('convert\.text', \{ name: `\$\{stem\(openedPath\)\}\.sqlite` \}\)\}<\/p>/);
});

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
