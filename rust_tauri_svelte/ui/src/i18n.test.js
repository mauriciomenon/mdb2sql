// Idiomas: os 3 catalogos tem as mesmas chaves e os mesmos {valores}, todo t('chave') usado existe, e nenhum
// texto de tela fica fora do catalogo (texto solto ou atributo fixo no markup dos .svelte).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { CATALOGS, LANGS, describe, translator } from './i18n.js';

const SOURCES = ['./App.svelte', './Grid.svelte'];
const read = (file) => readFileSync(new URL(file, import.meta.url), 'utf8');
const placeholders = (text) => [...text.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();

test('the three catalogs have the same keys and the same {values}', () => {
  assert.deepEqual(LANGS.map(([code]) => code), ['en', 'pt-BR', 'es']);
  const en = CATALOGS.en;
  for (const [code] of LANGS) {
    const catalog = CATALOGS[code];
    assert.deepEqual(Object.keys(catalog).sort(), Object.keys(en).sort(), code);
    for (const [key, text] of Object.entries(catalog)) {
      assert.ok(text.trim(), `${code} ${key} vazio`);
      assert.deepEqual(placeholders(text), placeholders(en[key]), `${code} ${key}`);
    }
  }
});

test('every key used in the screens exists in the catalog', () => {
  for (const file of [...SOURCES, './App.svelte']) {
    for (const [, key] of read(file).matchAll(/\bt\('([\w.]+)'/g)) assert.ok(key in CATALOGS.en, `${file}: ${key}`);
  }
  // chaves montadas no codigo: [[chave]] do backend, status.<step> do progresso, save.<formato>
  const backend = ['main.rs', 'backend/db_manager.rs', 'backend/export.rs']
    .map((file) => readFileSync(new URL(`../../src/${file}`, import.meta.url), 'utf8'))
    .join(' ');
  for (const step of ['read', 'convert', 'load']) assert.ok(`status.${step}` in CATALOGS.en);
  for (const format of ['sqlite', 'duckdb', 'xlsx', 'csv']) assert.ok(`save.${format}` in CATALOGS.en);
  for (const [, key] of backend.matchAll(/\[\[(\w+\.[\w.]+)\]\]/g)) assert.ok(key in CATALOGS.en, `backend: ${key}`);
});

test('no screen text outside the catalogs', () => {
  for (const file of SOURCES) {
    let text = read(file)
      .replace(/<script>[\s\S]*?<\/script>/, '')
      .replace(/<style>[\s\S]*?<\/style>/, '')
      .replace(/<!--[\s\S]*?-->/g, '');
    // expressoes {...} (com chaves dentro) saem; o que sobra entre tags tem de ser so simbolo
    let previous;
    do {
      previous = text;
      text = text.replace(/\{[^{}]*\}/g, '');
    } while (text !== previous);
    for (const [, attr, value] of text.matchAll(/\b(title|placeholder|aria-label|alt)="([^"]*)"/g)) {
      assert.doesNotMatch(value, /\p{L}{2,}/u, `${file}: ${attr}="${value}" fora do catalogo`);
    }
    for (const [, between] of text.matchAll(/>([^<]+)</g)) {
      assert.doesNotMatch(between, /\p{L}/u, `${file}: texto "${between.trim()}" fora do catalogo`);
    }
  }
});

// tela sem instrucao, sem tom professoral e sem copyright; dica de uma linha curta
test('catalog texts are short and plain', () => {
  const preachy = /verifique|lembre-se|aten[cç][aã]o|make sure|remember to|please|by the way|copyright|\(c\) 20/i;
  for (const [code, catalog] of Object.entries(CATALOGS)) {
    for (const [key, text] of Object.entries(catalog)) {
      assert.doesNotMatch(text, preachy, `${code} ${key}`);
      if (key.endsWith('Tip')) assert.ok(text.length <= 45 && !text.includes('. '), `${code} ${key}: ${text}`);
    }
  }
});

test('license line of the About says GPL v2 or later in each language', () => {
  assert.equal(CATALOGS['pt-BR']['about.licenseValue'], 'GPL v2 ou posterior');
  assert.equal(CATALOGS.en['about.licenseValue'], 'GPL v2 or later');
  assert.equal(CATALOGS.es['about.licenseValue'], 'GPL v2 o posterior');
});

test('translator fills {values}, falls back to English, describes backend keys', () => {
  const pt = translator('pt-BR');
  assert.equal(pt('status.hiddenMany', { count: 3 }), '3 colunas ocultas');
  assert.equal(translator('xx')('menu.file'), 'File');
  assert.equal(pt('missing.key'), 'missing.key');
  assert.equal(describe(pt, '[[err.unsupported]] .txt'), 'Tipo de arquivo não suportado: .txt');
  assert.equal(describe(translator('es'), 'T1: [[err.exportCancelled]]'), 'T1: Exportación cancelada');
  assert.equal(describe(pt, 'Binder Error: x'), 'Binder Error: x');
});
