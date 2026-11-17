// Nada duplicado na tela: cada botao/item de menu aparece uma vez e cada acao tem um lugar so.
// Le o markup dos .svelte (sem navegador); a contagem na tela de verdade fica nas capturas do release.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

const markup = (file) =>
  readFileSync(new URL(file, import.meta.url), 'utf8')
    .replace(/<script>[\s\S]*?<\/script>/, '')
    .replace(/<style>[\s\S]*?<\/style>/, '');

// texto fixo de cada <button>; o atributo pode ter "=>" dentro de {}, entao o fim da tag e o ">" fora de chaves
function buttonLabels(text) {
  const labels = [];
  for (let at = text.indexOf('<button'); at >= 0; at = text.indexOf('<button', at + 1)) {
    let i = at;
    for (let depth = 0; i < text.length && !(text[i] === '>' && depth === 0); i++) {
      if (text[i] === '{') depth++;
      if (text[i] === '}') depth--;
    }
    const body = text.slice(i + 1, text.indexOf('</button', i));
    const label = body.replace(/<kbd>[\s\S]*?<\/kbd>/g, '').replace(/<[^>]*>|\{[^}]*\}/g, '').replace(/\s+/g, ' ').trim();
    if (label) labels.push(label);
  }
  return labels;
}

const count = (text, needle) => text.split(needle).length - 1;
const repeated = (labels) => labels.filter((label, i) => labels.indexOf(label) !== i);

test('the main window has no repeated button or menu item', () => {
  const app = markup('./App.svelte');
  const labels = buttonLabels(app);
  assert.ok(labels.includes('Browse...') && labels.includes('Colunas...'), labels.join(', '));
  assert.deepEqual(repeated(labels), []);
  // uma lista de exportacao so (File > Export) e um jeito so de escolher o arquivo
  assert.equal(count(app, '{#each EXPORTS'), 1);
  assert.equal(count(app, 'startExport('), 1);
  assert.equal(count(app, 'onclick={browse}'), 1);
  assert.equal(labels.filter((label) => /^export/i.test(label)).length, 0); // nenhum botao Export... fora do menu
});

// colunas quase so de NULL pareciam transparentes: celula de dado nao pode ter opacity nem cor apagada
test('grid cells, NULL included, keep full contrast', () => {
  const css = readFileSync(new URL('./Grid.svelte', import.meta.url), 'utf8').match(/<style>([\s\S]*)<\/style>/)[1];
  const rules = [...css.matchAll(/([^{}]+)\{([^}]*)\}/g)].map(([, sel, body]) => [sel.replace(/\/\*[\s\S]*?\*\//g, '').trim(), body]);
  const cellRules = rules.filter(([sel]) => /(^|[\s,])(td|\.null|tbody)/.test(sel));
  assert.ok(cellRules.some(([sel]) => sel === '.null'), 'regra .null');
  for (const [sel, body] of cellRules) {
    assert.doesNotMatch(body, /opacity|var\(--muted\)|filter|mask/, sel);
  }
  // o cabecalho fixo fica por cima das celulas que rolam por baixo dele
  const th = rules.find(([sel]) => sel === 'th')[1];
  assert.match(th, /z-index:\s*1/);
  // cabecalho inteiro: a coluna cresce ate caber nome e valores, sem limite nem reticencias
  assert.match(th, /white-space:\s*nowrap/);
  for (const [sel, body] of rules.filter(([sel]) => /^(th|td)\b/.test(sel))) {
    assert.doesNotMatch(body, /max-width|text-overflow|overflow:\s*hidden/, sel);
  }
});

test('the table name above the grid is never squeezed', () => {
  const css = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8').match(/<style>([\s\S]*)<\/style>/)[1];
  assert.match(css, /\.table-bar h2,\s*\.table-bar \.columns-button\s*\{\s*flex-shrink:\s*0;/);
  assert.doesNotMatch(css, /h2[^{]*\{[^}]*(text-overflow|overflow:\s*hidden)/);
});

test('each grid context menu lists an action once', () => {
  const grid = markup('./Grid.svelte');
  const [header, cell] = grid.split('{:else if menu}');
  assert.deepEqual(buttonLabels(header), ['Ocultar esta coluna', 'Colunas...', 'Mostrar todas']);
  assert.deepEqual(buttonLabels(cell), [
    'Copy value',
    'Copy row',
    'Copy row with header',
    'Filtrar por este valor',
    'Limpar filtros',
  ]);
});
