// Nada duplicado na tela: cada botao/item de menu aparece uma vez e cada acao tem um lugar so.
// Le o markup dos .svelte (sem navegador), com os textos do catalogo ingles; a tela de verdade fica nas capturas.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import en from './i18n/en.js';

const markup = (file) =>
  readFileSync(new URL(file, import.meta.url), 'utf8')
    .replace(/<script>[\s\S]*?<\/script>/, '')
    .replace(/<style>[\s\S]*?<\/style>/, '');

// {t('chave')} e {t('chave', {...})} viram o texto ingles
const english = (text) => text.replace(/\{t\('([\w.]+)'(?:,[^}]*\})?\)\}/g, (_, key) => en[key] ?? `?${key}`);

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
    const label = english(body.replace(/<kbd>[\s\S]*?<\/kbd>/g, ''))
      .replace(/<[^>]*>|\{[^}]*\}/g, '')
      .replace(/\s+/g, ' ')
      .trim();
    if (label) labels.push(label);
  }
  return labels;
}

const count = (text, needle) => text.split(needle).length - 1;
// Close/Cancel fecham cada um o seu dialogo: o mesmo nome em dialogos diferentes nao e acao repetida
const DIALOG_DISMISS = [en['common.close'], en['common.cancel']];
const repeated = (labels) => labels.filter((label, i) => labels.indexOf(label) !== i && !DIALOG_DISMISS.includes(label));

test('the main window has no repeated button or menu item', () => {
  const app = markup('./App.svelte');
  const labels = buttonLabels(app);
  for (const label of ['Browse...', 'Columns...', 'Close database', 'Copy all', 'Save...', 'Delete']) {
    assert.ok(labels.includes(label), `${label} in ${labels.join(', ')}`);
  }
  assert.deepEqual(repeated(labels), []);
  // uma lista de exportacao so (File > Export) e um jeito so de escolher o arquivo
  assert.equal(count(app, '{#each EXPORTS'), 1);
  assert.equal(count(app, 'startExport('), 1);
  assert.equal(count(app, 'onclick={browse}'), 1);
  assert.equal(count(app, 'onclick={closeDatabase}'), 1);
  assert.equal(count(app, 'onclick={copyLog}'), 1);
  assert.equal(labels.filter((label) => /^export/i.test(label)).length, 0); // nenhum botao Export... fora do menu
});

// ordem do app em tudo que o usuario ve: Access, SQLite, DuckDB
test('Access comes first, then SQLite, then DuckDB', () => {
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  const order = (text, names) => names.map((n) => text.indexOf(n));
  const isSorted = (list) => list.every((v, i) => v >= 0 && (i === 0 || v > list[i - 1]));
  assert.ok(isSorted(order(app, ["'open.access'", "'open.sqlite'", "'open.duckdb'"])));
  assert.ok(isSorted(order(app, ["'export.dbSqlite'", "'export.dbDuckdb'"])));
  assert.ok(isSorted(order(en['open.all'], ['Access', 'SQLite', 'DuckDB'])));
  assert.ok(isSorted(order(en['header.placeholder'], ['.accdb', '.sqlite', '.duckdb'])));
  assert.ok(isSorted(order(en['about.description'], ['Access', 'SQLite', 'DuckDB'])));
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

// regra do dono: ~65% da janela entre 420 e 900 px, ate 70% da altura, grade de 1 a 6 colunas, so rola na vertical,
// fonte base na lista, busca no topo
test('Columns... dialog is proportional to the window', () => {
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  const rule = (sel) => app.match(new RegExp(`\\n  ${sel.replace(/[.[\]]/g, '\\$&')} \\{([^}]*)\\}`))[1];
  assert.match(rule('dialog.columns'), /width: clamp\(420px, 65vw, 900px\);[\s\S]*max-height: 70vh;/);
  const list = rule('.column-list');
  assert.match(list, /repeat\(auto-fill, minmax\(min\(100%, max\(var\(--cell\), calc\(\(100% - 5 \* 4px\) \/ 6\)\)\), 1fr\)\)/);
  assert.match(list, /overflow: hidden auto;/);
  assert.match(rule('.column-list label'), /font-size: inherit;/);
  const dialog = markup('./App.svelte').match(/<dialog\s+bind:this=\{columnsDialog\}[\s\S]*?<\/dialog>/)[0];
  assert.ok(dialog.indexOf('column-search') < dialog.indexOf('column-list'), 'busca acima da lista');
  // adendo 2: Mostrar/Ocultar todas agem so nas colunas listadas (com a busca do dialogo)
  assert.equal(count(dialog, 'setListed(hidden, listedColumns.map((c) => c.name)'), 2);
});

// adendo 3: nome de tabela e de coluna sempre inteiro, sem "...": quebra a linha em vez de cortar (DB4: tabela
// mais longa RANGER_SOM_AIN_DAY, coluna mais longa CIM_PROGRESS_START_DATE; conferido nas capturas)
test('table and column names are never cut with an ellipsis', () => {
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  const css = app.match(/<style>([\s\S]*)<\/style>/)[1];
  assert.doesNotMatch(css, /text-overflow/);
  assert.match(css, /\.table-list \[role='option'\] \{[^}]*overflow-wrap: anywhere;/);
  assert.match(css, /\.column-list label span \{[^}]*overflow-wrap: anywhere;/);
  assert.doesNotMatch(markup('./App.svelte'), /<select[^>]*size=/); // a lista nativa cortava nomes longos
});

test('the table name above the grid is never squeezed', () => {
  const css = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8').match(/<style>([\s\S]*)<\/style>/)[1];
  assert.match(css, /\.table-bar h2,\s*\.table-bar \.columns-button\s*\{\s*flex-shrink:\s*0;/);
  assert.doesNotMatch(css, /h2[^{]*\{[^}]*(text-overflow|overflow:\s*hidden)/);
});

test('each grid context menu lists an action once', () => {
  const grid = markup('./Grid.svelte');
  const [header, cell] = grid.split('{:else if menu}');
  assert.deepEqual(buttonLabels(header), ['Hide this column', 'Columns...', 'Show all']);
  assert.deepEqual(buttonLabels(cell), ['Copy value', 'Copy row', 'Copy row with header', 'Filter by this value', 'Clear filters']);
});

// log copiavel: View > Log abre o painel (texto selecionavel, Ctrl+C), Copiar tudo; barra de status: botao direito > Copiar
test('log panel and status bar text can be copied', () => {
  const app = markup('./App.svelte');
  assert.match(app, /role="menuitemcheckbox" aria-checked=\{logOpen\} onclick=\{\(\) => setLog\(!logOpen\)\}/);
  assert.match(app, /<textarea bind:this=\{logArea\} readonly value=\{logText\}/);
  assert.match(app, /<footer\s+class="statusbar"[\s\S]*?oncontextmenu=\{openStatusMenu\}/);
  assert.match(app, /onclick=\{copyStatus\}>\{t\('status.copy'\)\}/);
});

// REGRA_X11: aviso curto (3 linhas), link Ajuda clicavel (abre o navegador), comando com botao Copiar, sem URL crua
test('X11 warning is short, with a clickable Help link and a Copy command button', () => {
  const app = markup('./App.svelte');
  const dialog = app.match(/<dialog bind:this=\{x11Dialog\}[\s\S]*?<\/dialog>/)[0];
  assert.match(dialog, /<a href=\{x11\?\.link\} onclick=\{\(e\) => openLink\(e, x11\.link\)\}[\s\S]*?>\{t\('x11\.help'\)\}<\/a>/);
  assert.match(dialog, /<code>\{x11\.command\}<\/code>/);
  assert.match(dialog, /onclick=\{\(\) => copyText\(x11\.command\)\}>\{t\('x11\.copy'\)\}/);
  for (const key of ['x11.wayland', 'x11.missing', 'x11.noDisplay', 'x11.noServer']) {
    assert.doesNotMatch(en[key], /https?:|\.\.\./, key);
    assert.ok(en[key].length <= 45, key);
  }
});

// REGRA_VISUAL "Painel de Log": recolhido por padrao e lembrado, seta no log e na barra, View > Log, Ctrl+L,
// ~15% da altura (4 linhas a 30%), fonte de codigo um passo menor que a base (13 px), linhas sem "..."
test('log panel collapses and expands in one click and remembers the choice', () => {
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  assert.match(app, /let logOpen = \$state\(loadSetting\(LOG_KEY\) === 'open'\);/);
  assert.match(app, /saveSetting\(LOG_KEY, open \? 'open' : 'closed'\)/);
  assert.equal(count(app, 'onclick={() => setLog(false)}'), 1); // seta do cabecalho do log
  assert.equal(count(app, 'onclick={() => setLog(!logOpen)}'), 2); // View > Log e seta da barra de status
  assert.match(app, /e\.ctrlKey && !e\.altKey && e\.key\.toLowerCase\(\) === 'l'/);
  assert.match(app, /onclick=\{\(\) => setLog\(true\)\}>\{headline\.text\}/);
  const css = app.match(/<style>([\s\S]*)<\/style>/)[1];
  assert.match(css, /\.log textarea \{[^}]*height: 15vh;[^}]*min-height: calc\(4 \* 1\.4em \+ 14px\);[^}]*max-height: 30vh;[^}]*font-size: 12px;/);
  for (const [key, text] of Object.entries(en)) if (key.startsWith('status.')) assert.doesNotMatch(text, /\.\.\./, key);
});
