// Roda com: pnpm --filter mdb2sql-ui test  (node --test, sem dependencias)
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { CATALOGS, translator } from './i18n.js';
import { SAVE_FORMATS, baseName, defaultSaveDir, dirOf, extOf, joinPath, savedEntry, savedFormat, stem, suggestedName, withSaved } from './paths.js';

// padrao item 22: Access ja convertido e salvo, lembrado entre execucoes pela chave caminho|tamanho|data (a do backend);
// o mesmo arquivo sem mudanca acha o arquivo salvo (SQLite ou DuckDB); mudou (outra chave), converte de novo; a versao
// velha sai da lista
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
  // destino .duckdb tambem fica lembrado
  list = withSaved(list, v2, 'D:\\dados\\DB4.duckdb', 'd:\\dados\\db4.duckdb|70|5', 50);
  assert.equal(savedEntry(list, v2).dest, 'D:\\dados\\DB4.duckdb');
  // a tela: abre pelo arquivo salvo quando as duas chaves batem; lembra ao salvar em SQLite ou DuckDB (Excel nao)
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  assert.match(app, /const saved = await savedSqlite\(key\);\s*const opened = await invoke\('load_database', \{ dbPath: path, saved \}\);/);
  assert.match(app, /return \(await invoke\('file_key', \{ path: entry\.dest \}\)\) === entry\.destKey \? entry\.dest : null;/);
  assert.match(app, /if \(format !== 'xlsx'\) await rememberSaved\(accessKey, path\);\s*if \(converted\) await invoke\('discard_converted'\);\s*converted = false;/);
  assert.match(app, /converted = opened\.converted;\s*accessKey = key;/);
  // BRIEF secao 13 b: a linha do Log diz o formato real do salvo (o que o backend leu do arquivo: SQLite ou DuckDB)
  assert.match(app, /source = opened\.source;/);
  assert.match(app, /note\('info', \{ key: 'status\.reused', values: \{ name: baseName\(opened\.path\), format: source, path: saved \} \}\)/);
});

// item 28: Salvar e Salvar como: SQLite, DuckDB e Excel nesta ordem, ja marcado o tipo do aberto; o tipo gravado e o da
// extensao digitada, senao o marcado na caixa (e o caminho ganha a extensao)
test('Save: types in app order, the format comes from the typed extension or the selected type', () => {
  assert.deepEqual(SAVE_FORMATS, ['sqlite', 'duckdb', 'xlsx']);
  assert.deepEqual(savedFormat('D:\\x\\DB3.sqlite', 0), { path: 'D:\\x\\DB3.sqlite', format: 'sqlite' });
  assert.deepEqual(savedFormat('D:\\x\\DB3.DUCKDB', 0), { path: 'D:\\x\\DB3.DUCKDB', format: 'duckdb' }, 'typed extension wins');
  assert.deepEqual(savedFormat('D:\\x\\copia', 2), { path: 'D:\\x\\copia.xlsx', format: 'xlsx' });
  assert.deepEqual(savedFormat('D:\\x\\v1.2', 1), { path: 'D:\\x\\v1.2.duckdb', format: 'duckdb' }, 'unknown extension: the selected type');
  assert.equal(extOf('C:\\a.b\\noext'), '');
  assert.equal(extOf('/tmp/x.SQLite'), 'sqlite');
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  const save = app.match(/\n {2}async function save\(asLast[^)]*\) \{[\s\S]*?\n {2}\}/)[0];
  // Access e SQLite: SQLite marcado; DuckDB: DuckDB (um Access reaberto pelo .duckdb salvo continua SQLite)
  assert.match(save, /const selected = !access && source === 'DuckDB' \? 1 : 0;/);
  // Salvar: pasta do original; Salvar como: a ultima pasta em que salvou ou exportou (sem ela, a do original)
  assert.match(save, /const dir = \(asLast && loadSetting\(SAVE_DIR_KEY\)\) \|\| dirOf\(openedPath\);/);
  // "(copia)" so quando a sugestao e o proprio arquivo lido (Salvar como em outra pasta sugere o nome do original)
  assert.match(save, /const sameDir = dir\.toLowerCase\(\) === dirOf\(readFile\)\.toLowerCase\(\);\s*const name = suggestedName\(stem\(openedPath\), SAVE_FORMATS\[selected\], sameDir \? readFile : ''/);
  assert.match(save, /title: t\('save\.title'\),\s*path: joinPath\(dir, name\),\s*types: SAVE_FORMATS\.map\(\(format\) => \[t\(`save\.\$\{format\}`\), format\]\),\s*selected,/);
  // Access convertido em SQLite: copia o temporario; os outros casos: a exportacao do banco, com progresso e Cancelar
  // (a copia tambem com a barra de progresso: sair durante ela pergunta, como numa exportacao)
  assert.match(save, /const copy = converted && format === 'sqlite';\s*if \(!\(await runExport\(t\('file\.save'\), \{ scope: copy \? 'converted' : 'database', format, path \}, copy \? null : 'Tables'\)\)\) \{\s*return false;/);
  assert.match(app, /showStatus\(unit \? `status\.exported\$\{unit\}\$\{done\.sheets == null \? '' : 'Sheets'\}` : 'status\.sqliteSaved', values\);/);
  const main = readFileSync(new URL('../../src/main.rs', import.meta.url), 'utf8');
  assert.match(main, /"converted" => \{[\s\S]*?export::via_partial\(target, \|partial\| std::fs::copy\(&source, partial\)/);
  assert.match(app, /saveSetting\(SAVE_DIR_KEY, folder \? request\.path : dirOf\(request\.path\)\);/); // exportar tambem lembra a pasta
  assert.equal(CATALOGS['pt-BR']['save.title'], 'Salvar como SQLite, DuckDB ou Excel (arquivos .mdb e .accdb não podem ser gravados)');
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
  // o nome sugerido e o proprio arquivo aberto: "<nome> (copia)" no idioma da tela
  const copy = (lang) => (name) => translator(lang)('save.copyName', { name });
  assert.equal(suggestedName('DB4', 'duckdb', 'D:\\d\\db4.DUCKDB', copy('pt-BR')), 'DB4 (cópia).duckdb');
  assert.equal(suggestedName('DB4', 'sqlite', 'D:\\d\\DB4.sqlite', copy('en')), 'DB4 (copy).sqlite');
  assert.equal(suggestedName('DB4', 'sqlite', 'D:\\d\\DB4.sqlite', copy('es')), 'DB4 (copia).sqlite');
  assert.equal(suggestedName('DB4', 'sqlite', 'D:\\d\\DB4.accdb', copy('pt-BR')), 'DB4.sqlite');
  assert.equal(suggestedName('a/b:c', 'csv', ''), 'a_b_c.csv');
  assert.equal(suggestedName('', 'xlsx', ''), 'export.xlsx');
});
