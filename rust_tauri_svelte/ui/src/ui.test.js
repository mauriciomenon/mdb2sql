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
const DIALOG_DISMISS = [en['common.close'], en['common.cancel'], '×'];
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
  // cabecalho inteiro: a coluna cresce ate caber nome e valores, sem limite nem reticencias (largura fixa so na
  // coluna que o usuario arrasta, em style; Ajustar coluna volta a caber tudo)
  assert.match(th, /white-space:\s*nowrap/);
  for (const [sel, body] of rules.filter(([sel]) => /^(th|td)\b/.test(sel))) {
    assert.doesNotMatch(body, /max-width|text-overflow|overflow:\s*hidden/, sel);
  }
});

// item 5 do dono: seletor de duas opcoes (nada de checkbox) junto a pesquisa da aba Data, o mesmo par em Settings
// (escopo padrao, gravado); Todas as tabelas lista as achadas e escolher uma abre com a mesma pesquisa
test('Data search scope: two-option selector next to the field and its default in Settings', () => {
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  assert.match(app, /const SCOPES = \[\s*\['table', 'scope\.table'\],\s*\['all', 'scope\.all'\],\s*\];/);
  assert.deepEqual([en['scope.table'], en['scope.all']], ['This table', 'All tables']);
  const ui = markup('./App.svelte');
  const bar = ui.slice(ui.indexOf('{#if everywhere}'), ui.indexOf('class="search"'));
  assert.match(bar, /<div class="scope" role="radiogroup" aria-label=\{t\('scope\.label'\)\}>\s*\{#each SCOPES as \[id, key\]\}/);
  assert.match(bar, /role="radio" aria-checked=\{scope === id\}[^>]*onclick=\{\(\) => setScope\(id\)\}/);
  assert.doesNotMatch(bar, /checkbox/);
  const settings = ui.slice(ui.indexOf("openMenu === 'settings'"), ui.indexOf("openMenu === 'help'"));
  assert.match(settings, /\{t\('settings\.searchScope'\)\}[\s\S]*\{#each SCOPES as \[id, key\]\}[\s\S]*onclick=\{\(\) => setDefaultScope\(id\)\}/);
  assert.match(app, /let defaultScope = \$state\(loadSetting\(SCOPE_KEY\) === 'all' \? 'all' : 'table'\);/);
  assert.match(app, /saveSetting\(SCOPE_KEY, next === 'all' \? 'all' : null\);/);
  assert.match(app, /invoke\('search_all_tables', \{ search: words \}\)/);
  assert.match(ui, /onclick=\{\(\) => openFound\(f\.table\)\}>\{t\('found\.item', \{ table: f\.table, count: fmt\(f\.count\) \}\)\}/);
  // decisao 1: a tabela achada abre sem os filtros por valor (a grade mostra o numero da lista)
  assert.match(app, /function openFound\(name\) \{\s*scope = 'table';\s*filters = \[\];\s*openTable\(name, search\);/);
});

// corpo de uma funcao do App.svelte (do nome ate a chave que fecha, com dois espacos de recuo)
const appFunction = (name) =>
  readFileSync(new URL('./App.svelte', import.meta.url), 'utf8').match(
    new RegExp(`\\n  (?:async )?function ${name}\\([^)]*\\) \\{[\\s\\S]*?\\n  \\}`)
  )[0];

// apagar o termo e trocar o escopo antes de 300 ms: o recarregamento agendado continua (a grade ficava filtrada sob o
// campo vazio)
test('switching scope with an empty field keeps the pending table reload', () => {
  assert.match(appFunction('setScope'), /if \(!search\.trim\(\)\) return;\s*clearTimeout\(searchTimer\);\s*runSearch\(\);/);
});

// decisao 4 (igual nas 4 versoes): resposta velha de Todas as tabelas nunca aparece (outro termo, escopo, tabela ou
// arquivo); a pesquisa nova para a antiga no backend (src/backend/tests.rs); falha tira o "Pesquisando" e mostra o erro
test('All tables search: stale answers are dropped and a failure ends the searching state', () => {
  assert.match(appFunction('dropFound'), /searchRun\+\+;\s*found = null;/);
  const all = appFunction('searchAll');
  assert.match(all, /dropFound\(\);\s*const run = searchRun;/);
  assert.equal(count(all, 'if (run === searchRun)'), 2); // resposta e erro
  assert.match(all, /found = \{ tables: null \};\s*showError\(err\);/);
  assert.match(appFunction('onSearch'), /search = event\.currentTarget\.value;\s*dropFound\(\);/);
  assert.match(appFunction('setScope'), /scope = next;\s*dropFound\(\);/);
  assert.match(appFunction('openTable'), /if \(tableName !== selectedTable\) \{[^}]*dropFound\(\);\s*\}/);
  assert.match(appFunction('resetTable'), /dropFound\(\);/);
  const ui = markup('./App.svelte');
  assert.match(ui, /\{!found \? t\('found\.searching'\) : found\.tables \? t\('found\.summary'/);
  assert.match(ui, /\{#if found\?\.tables\}\s*\{#each found\.tables as f/);
});

// decisao 2 (igual nas 4 versoes): outro arquivo limpa a pesquisa e o filtro de tabelas e volta ao escopo de Settings
test('opening another file clears the searches and goes back to the default scope', () => {
  assert.match(appFunction('resetTable'), /search = '';\s*scope = defaultScope;/);
  assert.match(appFunction('openDatabase'), /tableText = tableFilter = '';[^]*resetTable\(\);/);
});

// decisao 3: nenhum caminho deixa a tabela sem coluna visivel (Ocultar todas e a caixa da ultima visivel)
test('the Columns dialog never hides the last visible column', () => {
  const dialog = markup('./App.svelte').match(/<dialog\s+bind:this=\{columnsDialog\}[\s\S]*?<\/dialog>/)[0];
  assert.match(dialog, /disabled=\{!hidden\.has\(col\.name\) && shownColumns\.length === 1\}/);
  assert.match(dialog, /onchange=\{\(\) => \(hidden = toggleShown\(hidden, col\.name, columns\.length\)\)\}/);
  assert.match(dialog, /setListed\(hidden, listedColumns\.map\(\(c\) => c\.name\), true, columns\.length\)/);
});

// decisao 5: a grade (Data, Schema e SQL) usa a fonte do app, Segoe UI 14 px como o Go/Wails; nada menor na grade
test('grid text uses the 14 px app font', () => {
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  assert.match(app, /:global\(body\) \{[^}]*font: 14px\/1\.4 'Segoe UI'/);
  const css = readFileSync(new URL('./Grid.svelte', import.meta.url), 'utf8').match(/<style>([\s\S]*)<\/style>/)[1];
  assert.doesNotMatch(css, /font(-size)?:\s*[\d.]/);
  // o tipo sob o nome da coluna e um <small>: sem inherit o navegador o reduz
  assert.match(css, /th small \{[^}]*font-size: inherit;/);
});

// dono: o filtro de tabelas e a pesquisa da aba Data esperam a digitacao parar (300 ms, igual nas 4 versoes);
// Enter vale na hora; a lista de tabelas usa o texto que ja valeu, nao o que esta sendo digitado
test('table filter and Data search wait 300 ms, Enter runs at once', () => {
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  assert.match(app, /const SEARCH_DELAY_MS = 300;/);
  assert.match(app, /const delayOf = \(event\) => \(event\.key === 'Enter' \? 0 : SEARCH_DELAY_MS\);/);
  assert.match(app, /tableTimer = setTimeout\(\(\) => \(tableFilter = text\), delayOf\(event\)\);/);
  assert.match(app, /searchTimer = setTimeout\(runSearch, delayOf\(event\)\);/);
  assert.match(app, /const words = searchWords\(tableFilter\);/);
  const ui = markup('./App.svelte');
  assert.match(ui, /bind:value=\{tableText\}\s+oninput=\{onTableFilter\}\s+onkeydown=\{\(e\) => e\.key === 'Enter' && onTableFilter\(e\)\}/);
  assert.match(ui, /oninput=\{onSearch\}\s+onkeydown=\{\(e\) => e\.key === 'Enter' && onSearch\(e\)\}/);
});

// dono: colunas do Schema apertadas; so ela ganha 6 px de cada lado da celula (Data e SQL seguem com 10 px)
test('only the Schema grid gets wider cell spacing', () => {
  const app = markup('./App.svelte');
  assert.equal(count(app, '--cell-x='), 1);
  assert.match(app, /<Grid\s+--cell-x="16px"\s+columns=\{schemaColumns\}/);
  const css = readFileSync(new URL('./Grid.svelte', import.meta.url), 'utf8').match(/<style>([\s\S]*)<\/style>/)[1];
  assert.match(css, /\n {2}th \{[^}]*padding: 6px var\(--cell-x, 10px\);/);
  assert.match(css, /\n {2}td \{[^}]*padding: 4px var\(--cell-x, 10px\);/);
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
  assert.deepEqual(buttonLabels(header), ['Size column to fit', 'Size all columns to fit', 'Hide this column', 'Columns...', 'Show all columns']);
  assert.deepEqual(buttonLabels(cell), ['Copy value', 'Copy row', 'Copy row with header', 'Filter by this value', 'Clear filters']);
});

// item 11 do dono, como o menu do cabecalho do ImGui: Ajustar coluna/todas em toda grade (a borda do cabecalho
// arrasta a largura); na aba Data a lista das colunas com marca (clique alterna, menu aberto), sem ocultar a ultima
test('header menu sizes columns in every grid and lists the Data columns to show or hide', () => {
  const code = readFileSync(new URL('./Grid.svelte', import.meta.url), 'utf8');
  assert.match(code, /const th = event\.target\.closest\('th\[data-c\]'\);/); // cabecalho de qualquer grade
  const header = markup('./Grid.svelte').split('{:else if menu}')[0];
  assert.ok(header.indexOf("t('grid.fitAll')") < header.indexOf('{#if actions}'), 'ajustar fora do if actions');
  assert.match(header, /\{#each actions\.all as col \(col\.name\)\}/);
  assert.match(header, /role="menuitemcheckbox"\s+aria-checked=\{shown\}\s+disabled=\{shown && last\}/);
  assert.match(header, /e\.stopPropagation\(\);[^}]*actions\.hide\(col\.name\);/);
  assert.match(header, /disabled=\{last\} onclick=\{\(\) => act\('hide', menu\.header\)\}/);
  assert.match(code, /onpointerdown=\{\(e\) => startResize\(e, col\.name\)\}/);
  assert.equal(count(code, 'style={sized(col.name)}'), 2); // cabecalho e celulas da coluna
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  assert.match(app, /hide: \(name\) => \(hidden = toggleShown\(hidden, name, columns\.length\)\)/);
  assert.match(app, /actions=\{\{ \.\.\.gridActions, all: columns, hidden, filtered: filters\.length > 0 \}\}/);
});

// log copiavel: View > Log abre o painel (texto selecionavel, Ctrl+C), Copiar tudo; barra de status: botao direito > Copiar
test('log panel and status bar text can be copied', () => {
  const app = markup('./App.svelte');
  assert.match(app, /role="menuitemcheckbox" aria-checked=\{logOpen\} onclick=\{\(\) => setLog\(!logOpen\)\}/);
  assert.match(app, /<textarea bind:this=\{logArea\} readonly value=\{logText\}/);
  assert.match(app, /<footer\s+class="statusbar"[\s\S]*?oncontextmenu=\{openStatusMenu\}/);
  assert.match(app, /onclick=\{copyStatus\}>\{t\('status.copy'\)\}/);
});

// padrao item 2 (barra de baixo = Go): seta do log e mensagem a esquerda; nao lidos, colunas ocultas e modo de leitura a
// direita, sem o rotulo da stack (fica no Sobre); ao abrir, "Aberto: <nome> (<n> tabelas)" sem o caminho
test('bottom bar: log arrow and message, then unread, hidden columns and read mode', () => {
  const bar = markup('./App.svelte').match(/<footer[\s\S]*?<\/footer>/)[0];
  const order = ['class="log-toggle"', 'class="message"', 'class="badge"', "'status.hiddenOne'", "t('status.via'"];
  const at = order.map((needle) => bar.indexOf(needle));
  assert.ok(at.every((v, i) => v >= 0 && (i === 0 || v > at[i - 1])), at.join(','));
  assert.doesNotMatch(bar, /app\.stack|class="stack"/);
  assert.ok(!('app.stack' in en));
  assert.match(appFunction('openDatabase'), /showStatus\('status\.opened', \{ name: baseName\(opened\.path\), count: fmt\(tables\.length\) \}\)/);
  assert.equal(en['status.opened'], 'Loaded: {name} ({count} {count|table|tables})');
});

// REGRA_X11: aviso curto (3 linhas), link Ajuda clicavel (abre o navegador), comando com botao Copiar, sem URL crua
test('X11 warning is short, with a clickable Help link and a Copy command button', () => {
  const app = markup('./App.svelte');
  const dialog = app.match(/<dialog bind:this=\{x11Dialog\}[\s\S]*?<\/dialog>/)[0];
  assert.match(dialog, /<a href=\{x11\?\.link\} onclick=\{\(e\) => openLink\(e, x11\.link\)\}[\s\S]*?>\{t\('x11\.help'\)\}<\/a>/);
  assert.match(dialog, /<code>\{x11\.command\}<\/code>/);
  assert.match(dialog, /onclick=\{\(\) => copyText\(x11\.command\)\}>\{t\('x11\.copy'\)\}/);
  for (const key of ['x11.wayland', 'x11.noDisplay', 'x11.noServer']) {
    assert.doesNotMatch(en[key], /https?:|\.\.\./, key);
    assert.ok(en[key].length <= 45, key);
    assert.doesNotMatch(en[key], /Missing|Falta/, key); // o fato direto, sem rotulo
  }
});

// REGRA_VISUAL "Painel de Log": recolhido por padrao e lembrado, seta no log e na barra, View > Log, Ctrl+L,
// ~10% da altura (3 linhas a 25%), fonte de codigo menor (11 px, o minimo do app), linhas sem "..."
test('log panel collapses and expands in one click and remembers the choice', () => {
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  assert.match(app, /let logOpen = \$state\(loadSetting\(LOG_KEY\) === 'open'\);/);
  assert.match(app, /saveSetting\(LOG_KEY, open \? 'open' : 'closed'\)/);
  assert.equal(count(app, 'onclick={() => setLog(false)}'), 1); // seta do cabecalho do log
  assert.equal(count(app, 'onclick={() => setLog(!logOpen)}'), 2); // View > Log e seta da barra de status
  assert.match(app, /e\.ctrlKey && !e\.altKey && e\.key\.toLowerCase\(\) === 'l'/);
  assert.match(app, /onclick=\{\(\) => setLog\(true\)\}>\{headline\.text\}/);
  const css = app.match(/<style>([\s\S]*)<\/style>/)[1];
  assert.match(css, /\.log textarea \{[^}]*height: 10vh;[^}]*min-height: calc\(3 \* 1\.4em \+ 10px\);[^}]*max-height: 25vh;[^}]*font-size: 11px;/);
  for (const [key, text] of Object.entries(en)) if (key.startsWith('status.')) assert.doesNotMatch(text, /\.\.\./, key);
});

// pergunta do SQLite convertido nunca prende: Enter = Salvar..., Esc e X = Cancelar, dialogo de arquivo cancelado volta
// para a pergunta, foco visivel no botao padrao
test('converted SQLite question never traps the user', () => {
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  const dialog = app.match(/<dialog\s+bind:this=\{convertDialog\}[\s\S]*?<\/dialog>/)[0];
  assert.match(dialog, /oncancel=\{\(e\) => \{\s*e\.preventDefault\(\);\s*reply\('cancel'\);/);
  assert.match(dialog, /e\.key === 'Enter' && e\.target\.tagName !== 'BUTTON'[\s\S]*?reply\('save'\)/);
  assert.match(dialog, /class="dialog-x"[^>]*onclick=\{\(\) => reply\('cancel'\)\}>×<\/button>/);
  assert.match(app, /if \(!saved\) \{\s*choice = null;\s*continue;/);
  assert.match(app, /convertDialog\.querySelector\('button\.save'\)\.focus\(\)/);
  assert.match(app, /dialog\.convert button\.save:focus \{\s*outline: 2px solid/);
});

// REGRA_VISUAL "Dialogos: sempre com OK": todo dialogo tem botao visivel de fechar/OK; Enter = botao padrao; Esc fecha
test('every dialog has a visible default button, Enter and Esc', () => {
  const app = markup('./App.svelte');
  const dialogs = [...app.matchAll(/<dialog[\s\S]*?<\/dialog>/g)].map((m) => m[0]);
  assert.equal(dialogs.length, 5); // Sobre, X11, SQLite convertido, Colunas, progresso
  for (const d of dialogs) assert.match(d, /<button type="button" class="[^"]*(default|save)[^"]*"/, d.slice(0, 80));
  const code = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  for (const name of ['aboutDialog', 'x11Dialog', 'progressDialog']) {
    assert.ok(code.includes(`${name}.querySelector('button.default')`), name); // foco inicial no botao padrao
  }
  assert.match(code, /onkeydown=\{\(e\) => e\.key === 'Enter' && columnsDialog\.close\(\)\}/);
  assert.match(code, /oncancel=\{\(e\) => \{\s*e\.preventDefault\(\);\s*invoke\('cancel_export'\);/);
});
