// Nada duplicado na tela: cada botao/item de menu aparece uma vez e cada acao tem um lugar so.
// Le o markup dos .svelte (sem navegador), com os textos do catalogo ingles; a tela de verdade fica nas capturas.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import en from './i18n/en.js';
import CATALOG_ES from './i18n/es.js';
import CATALOG_PT from './i18n/pt-BR.js';

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
// Copiar (texto do Go): o comando do aviso de X11 e a linha da barra de status, cada um no seu lugar
// "tabela (n)" (o texto do catalogo sem os valores fica "()"): a lista da busca em todas as tabelas (Dados) e a das
// tabelas com acerto (Termos), uma em cada aba, no mesmo formato (BRIEF 7d)
const DIALOG_DISMISS = [en['common.close'], en['common.cancel'], '×', en['x11.copy'], '()'];
const repeated = (labels) => labels.filter((label, i) => labels.indexOf(label) !== i && !DIALOG_DISMISS.includes(label));

test('the main window has no repeated button or menu item', () => {
  const app = markup('./App.svelte');
  const labels = buttonLabels(app);
  for (const label of ['Browse...', 'Open', 'Export...', 'Columns...', 'Run', 'Search terms', 'Copy all']) {
    assert.ok(labels.includes(label), `${label} in ${labels.join(', ')}`);
  }
  assert.deepEqual(repeated(labels), []);
  // os menus saem todos da arvore de menus.js (menus.test.js), desenhados por um snippet so; a lista de exportacao e
  // uma so (EXPORT_MENU), mostrada pelo menu Arquivo (dentro de MENUS) e pelo botao Exportar... do topo
  assert.equal(count(app, '{#snippet menuItems(items, depth)}'), 1);
  assert.equal(count(app, '{@render menuItems(items, 0)}'), 1);
  assert.equal(count(app, '{@render menuItems(EXPORT_MENU, 0)}'), 1);
  assert.match(app, /\{#each MENUS as \[id, text, items\]\}/);
  const code = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  // cada botao da tela tem o seu item de menu com a mesma acao
  assert.equal(count(app, 'onclick={browse}'), 1); // Procurar... do topo = Arquivo > Abrir...
  assert.match(code, /\n {6}open: \{ run: browse, off: busy \},/);
  assert.match(app, /<form onsubmit=\{openDatabase\}>/); // Abrir do topo = Arquivo > Abrir o caminho digitado
  assert.match(code, /\n {6}openPath: \{ run: \(\) => openDatabase\(\), off: busy \|\| !dbPath\.trim\(\) \},/);
  assert.match(code, /\n {6}close: \{ run: closeDatabase, off: busy \|\| !open \},/);
  assert.equal(count(app, 'onclick={copyLog}'), 1); // Copiar tudo do Log = Editar > Copiar todo o Log
  assert.match(code, /\n {6}copyLog: \{ run: copyLog, off: !log\.length \},/);
  assert.deepEqual(labels.filter((label) => /^export/i.test(label)), ['Export...']);
});

// padrao item 17: exportar a tabela com pesquisa ou filtro ativo pergunta "tabela inteira" ou "so as N linhas
// encontradas"; a escolha manda (ou nao) os filtros e a pesquisa ao backend; Cancelar/Esc nao exporta
test('exporting a searched table asks: whole table or only the rows found', () => {
  const code = appFunction('startExport');
  // a pesquisa que ainda esperava os 300 ms vale antes da pergunta (o numero mostrado e o exportado)
  assert.match(code, /if \(kind === 'table' && !everywhere && \(search\.trim\(\) \|\| filters\.length\)\) \{\s*(?:\/\/[^\n]*\n\s*)?clearTimeout\(searchTimer\);\s*await openTable\(selectedTable\);\s*const choice = await ask\(\{/);
  assert.match(code, /\{ id: 'all', key: 'export\.wholeTable', primary: true \},\s*\{ id: 'found', key: 'export\.foundRows', values: \{ count: fmt\(matchCount\) \} \},\s*\{ id: 'cancel', key: 'common\.cancel', right: true \},/);
  assert.match(code, /if \(choice !== 'all' && choice !== 'found'\) return;[^\n]*\n\s*if \(choice === 'found'\) Object\.assign\(request, \{ filters, search: search\.trim\(\) \}\);/);
  assert.match(appFunction('runExport'), /const done = await invoke\('export', \{ request \}\);/);
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  assert.match(app, /sql: \(\) => \(\{ name: 'query', unit: 'Rows', request: \{ scope: 'sql', sql: lastSql \} \}\),/); // query.csv / query.xlsx
});

// BRIEF secao 4: nomes sugeridos e o que cada exportacao manda; as de pasta (um CSV por tabela) usam o seletor de pasta
// e perguntam uma vez so se algum arquivo ja existe ali
test('each export sends its request and suggests its name', () => {
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  const exports = app.match(/const EXPORTS = \{[\s\S]*?\n {2}\};/)[0];
  assert.match(exports, /name: `\$\{selectedTable\}_marcadas`,\s*unit: 'Rows',\s*request: \{ scope: 'marked', table: selectedTable, ids: markedRows\.map\(\(row\) => row\[ROW_ID\]\) \},/);
  assert.match(exports, /tableSchema: \(\) => \(\{ name: `\$\{selectedTable\}_schema`, unit: 'Rows', request: \{ scope: 'schema', table: selectedTable, labels: schemaLabels\(\) \} \}\),/);
  assert.match(exports, /dbSchema: \(\) => \(\{ name: `\$\{stem\(openedPath\)\}_schema`, unit: 'Rows', request: \{ scope: 'schema', labels: schemaLabels\(\) \} \}\),/);
  assert.match(exports, /tables: \(\) => \(\{ folder: true, unit: 'Tables', request: \{ scope: 'tables' \} \}\),/);
  assert.match(exports, /name: `\$\{stem\(openedPath\)\}_termos`,\s*folder: format === 'csv',/);
  assert.match(app, /const schemaLabels = \(\) => \['tables\.name', 'schema\.column', 'schema\.type', 'schema\.nullable', 'schema\.yes', 'schema\.no'\]\.map\(\(key\) => t\(key\)\);/);
  assert.match(exports, /\['terms\.col', 'terms\.status', 'tables\.name', 'tables\.rows', 'terms\.found', 'terms\.missing', 'terms\.sheetSummary', 'terms\.sheetNotFound'\]\.map\(\(key\) => t\(key\)\)/);
  const start = appFunction('startExport');
  assert.match(start, /\? await invoke\('plugin:dialog\|open', \{ options: \{ title, directory: true, defaultPath: dir \|\| undefined \} \}\)/);
  assert.match(start, /const existing = await invoke\('export_existing', \{ request \}\);\s*const message = t\('ask\.overwriteMany', \{ count: fmt\(existing\) \}\);\s*if \(existing && \(await invoke\('plugin:dialog\|message', \{ title, message, kind: 'warning', buttons: 'YesNo' \}\)\) !== 'Yes'\) return;/);
  // o que nao se aplica fica desabilitado: sem marcas, sem resultado de SQL, sem busca em todas as tabelas, sem termos
  const can = appFunction('canExport');
  assert.match(can, /if \(kind === 'marked'\) return markedRows\.length > 0;/);
  assert.match(can, /if \(kind === 'sql'\) return !!sqlResult\?\.columns\.length;/);
  assert.match(can, /if \(kind === 'found'\) return everywhere && !!found\?\.tables\?\.length;/);
  assert.match(can, /if \(kind === 'terms'\) return !!termsResult;/);
});

// padrao item 6 (= Zig): a lista de tabelas tem as colunas Tabela e Linhas; as linhas vem do backend ao abrir
test('table list shows the row count of each table', () => {
  const ui = markup('./App.svelte');
  const list = ui.match(/<div\s+class="table-list"[\s\S]*?\{\/each\}/)[0];
  assert.match(list, /<div class="table-head" aria-hidden="true"><span>\{t\('tables\.name'\)\}<\/span><span>\{t\('tables\.rows'\)\}<\/span><\/div>/);
  // tabela que nao deu para contar (null): celula vazia, nunca um 0 que nao e verdade
  assert.match(list, /<span class="name">\{name\}<\/span><span class="rows">\{tableRows\.get\(name\) == null \? '' : fmt\(tableRows\.get\(name\)\)\}<\/span>/);
  assert.match(appFunction('openDatabase'), /tableRows = new Map\(opened\.tables\.map\(\(name, i\) => \[name, opened\.rows\[i\]\]\)\);/);
  assert.match(appFunction('closeDatabase'), /tableRows = new Map\(\);/);
  assert.deepEqual([en['tables.name'], en['tables.rows'], CATALOG_PT['tables.rows'], CATALOG_ES['tables.rows']], ['Table', 'Rows', 'Linhas', 'Filas']);
  const main = readFileSync(new URL('../../src/main.rs', import.meta.url), 'utf8');
  // o titulo so muda depois da lista e das contagens (uma falha ali nao deixa o titulo do arquivo novo)
  assert.match(main, /let tables = manager\.list_tables\(\)\?;\s*let rows = manager\.table_rows\(&tables\)\?;\s*show_title\(&app, Some\(&opened\)\);/);
});

// padrao item 21: Sobre = conteudo desta versao (Build, Stack, Janela, Bancos, Leitura do Access, Autor, Licenca, links)
// com o titulo do Zig, "Sobre o mdb2sql" (o mesmo do menu Ajuda), nas 3 linguas
test('About: title About mdb2sql and the rows of this stack', () => {
  const ui = markup('./App.svelte');
  const about = ui.match(/<dialog bind:this=\{aboutDialog\}[\s\S]*?<\/dialog>/)[0];
  assert.match(about, /<h2 id="about-title">\{t\('help\.about'\)\} <span class="version">\{aboutInfo\.version\}<\/span><\/h2>/);
  const pt = (key) => (key in en ? (CATALOG_PT[key] ?? '') : '');
  assert.deepEqual([pt('help.about'), en['help.about'], CATALOG_ES['help.about']], ['Sobre o mdb2sql', 'About mdb2sql', 'Acerca de mdb2sql']);
  const code = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  assert.match(code, /\n {6}about: \{ run: showAbout \},/); // Ajuda > Sobre o mdb2sql (menus.js)
  const rows = [...code.match(/let aboutRows = \$derived\.by\(\(\) => \{[\s\S]*?\n {2}\}\);/)[0].matchAll(/\[t\('(about\.\w+)'\)/g)].map((m) => m[1]);
  // item 28: a linha Gravacao logo depois de Leitura do Access (nao se grava em .mdb/.accdb)
  assert.deepEqual(rows, ['about.build', 'about.stack', 'about.window', 'about.engines', 'about.access', 'about.write', 'about.author', 'about.license']);
  assert.match(code, /\[t\('about\.write'\), t\('about\.writeValue'\)\],/);
  // rotulos traduzidos como no Sobre do Zig (Stack = Tecnologia / Tecnologia; Build fica, como no Go e no Zig)
  assert.deepEqual(rows.map(pt), ['Build', 'Tecnologia', 'Janela', 'Bancos', 'Leitura do Access', 'Gravação', 'Autor', 'Licença']);
  assert.deepEqual([en['about.stack'], CATALOG_ES['about.stack'], CATALOG_ES['about.build']], ['Stack', 'Tecnología', 'Compilación']);
});

// item 27: a pergunta do banco convertido so ao sair do programa (Arquivo > Sair, Ctrl+Q, X da janela, Alt+F4): Salvar a
// esquerda; Voltar e Sair a direita, lado a lado; Esc e o X da caixa = Voltar; Salvar cancelado: a pergunta volta.
// Fechar o arquivo, abrir outro e reabrir (F5) nao perguntam: o convertido nao salvo some e o Log recebe a linha
test('the converted database question is asked only on exit', () => {
  const quit = appFunction('quit');
  assert.match(quit, /while \(converted\) \{\s*const choice = await ask\(\{\s*title: t\('convert\.title'\),\s*text: t\('exit\.text', \{ name: baseName\(openedPath\) \}\),\s*x: true,/);
  assert.match(quit, /\{ id: 'save', key: 'file\.save', primary: true \},\s*\{ id: 'back', key: 'common\.back', right: true \},\s*\{ id: 'exit', key: 'file\.exit', right: true \},/);
  // dono 26/11: Salvar, Voltar e Sair (e os botoes de toda caixa com mais de um) com a mesma largura e altura, a do maior
  // texto nos 3 idiomas; medida numa copia escondida de cada botao, com o texto de cada idioma
  assert.match(appFunction('ask'), /await tick\(\);\s*sameSize\(askDialog\.querySelector\('\.actions'\), question\.buttons\.map\(\(\{ key, values \}\) => \[key, values\]\)\);/);
  const same = appFunction('sameSize');
  assert.match(same, /for \(const \[code\] of LANGS\) \{\s*probe\.textContent = translator\(code\)\(\.\.\.labels\[i\]\);\s*width = Math\.max\(width, probe\.getBoundingClientRect\(\)\.width\);/);
  assert.match(same, /for \(const button of buttons\) button\.style\.width = `\$\{Math\.ceil\(width\)\}px`;/);
  assert.match(appFunction('openColumns'), /sameSize\(columnsDialog\.querySelector\('\.actions'\), \[\['columns\.showAll'\], \['columns\.hideAll'\], \['common\.close'\]\]\);/);
  assert.match(markup('./App.svelte'), /onclick=\{\(\) => reply\(button\.id\)\}>\{t\(button\.key, button\.values\)\}/);
  // Salvar vale mesmo com pesquisa ou consulta rodando (save ignora busy so quando vem daqui)
  assert.match(quit, /if \(choice === 'exit'\) break;[^\n]*\n\s*if \(choice !== 'save'\) return;[^\n]*\n\s*await save\(false, true\);\s*\}\s*await invoke\('exit_app'\);/);
  assert.match(readFileSync(new URL('./App.svelte', import.meta.url), 'utf8'), /if \(\(busy && !exiting\) \|\| !openedPath\) return false;/);
  // exportacao em andamento: antes de tudo, Voltar / Sair; Sair cancela a exportacao e espera ela parar. Se a exportacao
  // era o Salvar da pergunta de sair, a pergunta volta no quit que a abriu (uma pergunta de sair por vez)
  assert.match(quit, /if \(progress\) \{\s*const choice = await ask\(\{\s*title: t\('exportRun\.title'\),\s*text: t\('exportRun\.text', \{ name: baseName\(progress\.path\) \}\),/);
  assert.match(quit, /if \(choice !== 'exit'\) return;\s*await invoke\('cancel_export'\);\s*await exportEnd;\s*\}\s*if \(quitting\) return;[^\n]*\n\s*quitting = true;\s*try \{\s*while \(converted\)/);
  assert.match(quit, /\} finally \{\s*quitting = false;\s*\}/);
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  assert.match(app, /listen\('close-requested', quit\),/);
  assert.match(app, /\n {6}exit: \{ run: quit \},/);
  // a caixa: Esc e X nao escolhem nada (null = Voltar); o primeiro botao da direita vai para a ponta (os da direita
  // ficam lado a lado); foco no botao padrao
  const dialog = app.match(/<dialog\s+bind:this=\{askDialog\}[\s\S]*?<\/dialog>/)[0];
  assert.match(dialog, /oncancel=\{\(e\) => \{\s*e\.preventDefault\(\);\s*reply\(null\);/);
  assert.match(dialog, /class="dialog-x"[^>]*onclick=\{\(\) => reply\(null\)\}>×<\/button>/);
  assert.match(dialog, /class=\{button\.primary \? 'default' : 'secondary'\}\s*class:close=\{button\.right && !question\.buttons\[i - 1\]\?\.right\}/);
  assert.match(app, /askDialog\.querySelector\('button\.default'\)\?\.focus\(\)/);
  assert.match(app, /dialog\.ask button\.default:focus \{\s*outline: 2px solid/);
  assert.doesNotMatch(dialog, /checkbox/);
  // sem pergunta ao fechar, abrir outro ou reabrir: so a linha do Log (status.discarded), depois que deu certo
  assert.doesNotMatch(app, /settleConverted/);
  assert.match(appFunction('openDatabase'), /const discarded = converted \? baseName\(openedPath\) : '';[\s\S]*const opened = await invoke\('load_database', \{ dbPath: path, saved \}\);\s*if \(discarded\) note\('info', \{ key: 'status\.discarded', values: \{ name: discarded \} \}\);/);
  assert.match(appFunction('closeDatabase'), /await invoke\('close_database'\);[\s\S]*if \(converted\) note\('info', \{ key: 'status\.discarded', values: \{ name \} \}\);/);
  const main = readFileSync(new URL('../../src/main.rs', import.meta.url), 'utf8');
  // X da janela e Alt+F4: o backend segura o fechamento so com exportacao em andamento ou convertido nao salvo
  assert.match(main, /let pending = state\.exporting\.load\(Ordering::SeqCst\) \|\| state\.converted\.lock\(\)\.unwrap\(\)\.is_some\(\);\s*if !state\.exiting\.load\(Ordering::SeqCst\) && pending \{\s*api\.prevent_close\(\);/);
});

// padrao item 20 e BRIEF secao 4: os atalhos sao os dos itens de menu e valem quando o item vale (passam por run(id));
// F5 nunca recarrega a pagina do webview; com dialogo aberto os atalhos da janela nao valem (menos Ctrl+Q durante a
// exportacao, que pergunta antes de sair)
test('keyboard shortcuts are those of the menu items', () => {
  const code = appFunction('shortcut');
  const keys = Object.fromEntries([...code.matchAll(/\n {6}(\w+): ([^\n]+),/g)].map((m) => [m[1], m[2]]));
  assert.deepEqual(keys, {
    o: "'open'",
    s: "e.shiftKey ? 'saveAs' : 'save'",
    w: "'close'",
    q: "'exit'",
    f: "'find'",
    t: "'goTables'",
    l: "'log'",
    1: "'tab.data'",
    2: "'tab.schema'",
    3: "'tab.sql'",
    4: "'tab.terms'",
    enter: "tab === 'terms' ? 'runTerms' : tab === 'sql' ? 'runSql' : ''",
  });
  assert.match(code, /if \(e\.key === 'F5'\) e\.preventDefault\(\);/);
  assert.match(code, /if \(document\.querySelector\('dialog\[open\]'\) \|\| e\.altKey\) \{[^}]*if \(e\.ctrlKey && key === 'q' && progress\) quit\(\);\s*return;\s*\}\s*if \(e\.key === 'F5' && !e\.ctrlKey\) return run\('reopen'\);/);
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  // Ctrl+Enter e os outros valem como o botao de cada um: nada durante uma abertura ou consulta
  assert.match(app, /\n {6}runSql: \{ run: \(\) => \(\(tab = 'sql'\), runSql\(\)\), off: busy \|\| !open \|\| !sql\.trim\(\) \},/);
  assert.match(app, /\n {6}runTerms: \{ run: \(\) => \(\(tab = 'terms'\), runTerms\(\)\), off: !canRunTerms \},/);
  assert.match(app, /\n {6}reopen: \{ run: reload, off: busy \|\| !\(openedPath \|\| dbPath\.trim\(\)\) \},/);
  assert.match(appFunction('reload'), /if \(openedPath\) dbPath = openedPath;\s*if \(dbPath\.trim\(\)\) openDatabase\(\);/);
  assert.match(markup('./App.svelte'), /<svelte:window onclick=\{[^}]*\} onkeydown=\{shortcut\} \/>/);
  // Ctrl+Enter so pela janela (o editor tinha o seu e rodaria duas vezes)
  assert.doesNotMatch(markup('./App.svelte').match(/<textarea\s+bind:value=\{sql\}[\s\S]*?<\/textarea>/)[0], /onkeydown/);
  assert.doesNotMatch(markup('./App.svelte').match(/<textarea bind:value=\{termsText\}[\s\S]*?<\/textarea>/)[0], /onkeydown/);
  // na grade: Ctrl+C copia a celula, Ctrl+Shift+C a linha, Espaco marca a linha da celula escolhida
  const grid = readFileSync(new URL('./Grid.svelte', import.meta.url), 'utf8');
  assert.match(grid, /event\.ctrlKey && event\.key\.toLowerCase\(\) === 'c' && selected/);
  assert.match(grid, /copy\(event\.shiftKey \? 'row' : 'value'\);/);
  assert.match(grid, /if \(event\.key === ' ' && marks && selected && event\.target\.tagName !== 'INPUT'\) \{\s*event\.preventDefault\(\);\s*marks\.toggle\(selected\.row\);/);
});

// padrao item 1 (topo = Zig): so o campo do caminho e Procurar... Abrir Exportar... (sem titulo nem rotulo); caminho
// longo mostra o fim (o comeco sai com "..."); arquivo arrastado para a janela abre
test('top bar: path field, Browse..., Open, Export... and drag and drop', () => {
  const header = markup('./App.svelte').match(/<header>[\s\S]*?<\/header>/)[0];
  assert.doesNotMatch(header, /<h1|<label/);
  assert.deepEqual(buttonLabels(header), ['Browse...', 'Open', 'Export...']);
  assert.ok(header.indexOf('id="db-path"') < header.indexOf("t('header.browse')"));
  assert.match(header, /aria-label=\{t\('header\.database'\)\}/);
  assert.match(header, /<span class="path-view" aria-hidden="true"><bdi dir="ltr">\{dbPath\}<\/bdi><\/span>/);
  const code = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  const view = code.match(/\n {2}\.path-view \{([^}]*)\}/)[1];
  assert.match(view, /direction: rtl;[\s\S]*text-overflow: ellipsis;[\s\S]*white-space: nowrap;/);
  assert.match(code, /\.path input\.elided \{\s*color: transparent;/);
  assert.match(code, /onDragDropEvent\(\(\{ payload \}\) => \{\s*if \(payload\.type !== 'drop'[^\n]*\n\s*openDatabase\(null, payload\.paths\[0\]\);/);
  // arquivo escolhido ou arrastado vai para o campo e abre (abrir outro nao pergunta mais nada)
  assert.match(appFunction('openDatabase'), /const path = \(chosen \?\? dbPath\)\.trim\(\)[^\n]*\n\s*dbPath = path;/);
  assert.match(appFunction('browse'), /await openDatabase\(null, String\(picked\)\);/);
  assert.equal(en['header.open'], 'Open');
});

// ordem do app em tudo que o usuario ve: Access, SQLite, DuckDB
test('Access comes first, then SQLite, then DuckDB', () => {
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  const order = (text, names) => names.map((n) => text.indexOf(n));
  const isSorted = (list) => list.every((v, i) => v >= 0 && (i === 0 || v > list[i - 1]));
  assert.ok(isSorted(order(app, ["'open.access'", "'open.sqlite'", "'open.duckdb'"])));
  const paths = readFileSync(new URL('./paths.js', import.meta.url), 'utf8');
  assert.match(paths, /export const SAVE_FORMATS = \['sqlite', 'duckdb', 'xlsx'\];/); // tipos da caixa de salvar
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
  const menus = readFileSync(new URL('./menus.js', import.meta.url), 'utf8');
  assert.match(menus, /export const SCOPES = \[\s*\['table', 'scope\.table'\],\s*\['all', 'scope\.all'\],\s*\];/);
  assert.deepEqual([en['scope.table'], en['scope.all']], ['This table', 'All tables']);
  const ui = markup('./App.svelte');
  const bar = ui.match(/<div class="table-bar data-bar">[\s\S]*?\n {8}<\/div>/)[0];
  // o seletor de duas opcoes e um so (snippet choice), usado pela busca da aba Dados e pela aba Termos
  assert.match(bar, /\{@render choice\(SCOPES, scope, setScope, t\('scope\.label'\)\)\}/);
  assert.match(ui, /<div class="scope" role="radiogroup" aria-label=\{label\} title=\{tip\}>\s*\{#each options as \[id, key\]\}\s*<button type="button" role="radio" aria-checked=\{value === id\} class:active=\{value === id\} onclick=\{\(\) => pick\(id\)\}>/);
  assert.doesNotMatch(bar, /checkbox/);
  // Configuracoes > Escopo padrao da busca: os mesmos dois (menus.js), gravado
  assert.match(menus, /\['defaultScope', 'settings\.searchScope', SCOPES\.map\(\(\[id, key\]\) => \[`defaultScope\.\$\{id\}`, key\]\)\],/);
  assert.match(app, /radio\(`defaultScope\.\$\{id\}`, \(\) => setDefaultScope\(id\), defaultScope === id\);/);
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
  assert.match(app, /<Grid\s+bind:this=\{grid\}\s+bind:selected=\{cell\}\s+--cell-x="16px"\s+columns=\{schemaColumns\}/);
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
  // "..." so no caminho do arquivo no topo (padrao item 1), nunca em nome de tabela ou coluna
  assert.deepEqual([...css.matchAll(/([^{}]+)\{[^}]*text-overflow/g)].map((m) => m[1].replace(/\/\*[\s\S]*?\*\//g, '').trim()), ['.path-view']);
  assert.match(css, /\.table-list \[role='option'\] \{[^}]*overflow-wrap: anywhere;/);
  assert.match(css, /\.column-list label span \{[^}]*overflow-wrap: anywhere;/);
  assert.doesNotMatch(markup('./App.svelte'), /<select[^>]*size=/); // a lista nativa cortava nomes longos
});

// padrao item 24: aba Dados de cima para baixo: (a) busca | Esta tabela | Todas as tabelas | Linhas [100] | Colunas...
// numa linha; (b) filtros so com filtro; (c) a grade (ou as tabelas achadas); (d) "{tabela}: mostrando X de Y linhas"
// embaixo. Sem nome nem contagem acima da grade; Linhas sai da linha das abas
test('Data tab layout: search line, filters, grid, count line', () => {
  const ui = markup('./App.svelte');
  const data = ui.slice(ui.indexOf('<div class="table-bar data-bar">'), ui.indexOf('</main>'));
  const bar = data.match(/<div class="table-bar data-bar">[\s\S]*?\n {8}<\/div>/)[0];
  const order = ['class="search"', '{@render choice(SCOPES, scope, setScope', '{@render rowLimit()}', "t('columns.button')"].map((s) => bar.indexOf(s));
  assert.ok(order.every((v, i) => v >= 0 && (i === 0 || v > order[i - 1])), order.join(','));
  assert.doesNotMatch(bar, /<h2|t\('data\.showing/);
  const at = ['class="table-bar data-bar"', '{#if filters.length}', '<Grid', '<p class="table-info">'].map((s) => data.indexOf(s));
  assert.ok(at.every((v, i) => v >= 0 && (i === 0 || v > at[i - 1])), at.join(','));
  assert.match(data, /<p class="table-info">[\s\S]*t\('data\.showingMatches', \{ table: selectedTable, shown: fmt\(rows\.length\), matching: fmt\(matchCount\) \}\)[\s\S]*t\('data\.showing', \{ table: selectedTable, shown: fmt\(rows\.length\), total: fmt\(rowCount\) \}\)/);
  const tabs = ui.match(/<div class="tabs"[\s\S]*?<\/div>/)[0];
  assert.doesNotMatch(tabs, /<select|rowLimit|limit\.label/);
  assert.equal(count(ui, '{@render rowLimit()}'), 2); // aba Dados e linha do Executar da aba SQL
  assert.equal(en['data.showing'], '{table}: showing {shown} of {total} {total|row|rows}');
  // 1280 px: a linha inteira cabe (a busca estica e nada tem margem automatica empurrando para a linha de baixo)
  const css = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8').match(/<style>([\s\S]*)<\/style>/)[1];
  assert.doesNotMatch(css.match(/\n {2}\.table-bar \.scope \{[^}]*\}/)[0], /margin-left: auto/);
  assert.doesNotMatch(css.match(/\n {2}\.table-bar \.columns-button \{[^}]*\}/)[0], /margin-left: auto/);
});

// padrao item 8 (= Go): a 720 px a barra da aba Data quebra a linha (nada cortado, sem rolagem horizontal); a busca estica
// sem largura maxima (base 160 px, como o Go)
test('narrow window: the Data bar wraps and the search stretches', () => {
  const css = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8').match(/<style>([\s\S]*)<\/style>/)[1];
  assert.match(css, /\n {2}\.table-bar \{[^}]*flex-wrap: wrap;/);
  const search = css.match(/\n {2}\.table-bar \.search \{([^}]*)\}/)[1];
  assert.match(search, /flex: 1 1 160px;/);
  assert.match(search, /min-width: 160px;/);
  assert.doesNotMatch(search, /max-width|400px/);
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
  // padrao item 14 (= Go): primeiro os filtros por valor (so na aba Data), depois copiar celula / linha / com cabecalho
  // depois de copiar, os itens de quem usa a grade (texto vindo de fora; a seta e a do item com submenu)
  assert.deepEqual(buttonLabels(cell), ['Filter by this value', 'Clear filters', 'Copy value', 'Copy row', 'Copy row with header', '▸']);
  assert.ok(cell.indexOf('{#if actions}') < cell.indexOf("t('grid.filterValue')") && cell.indexOf('{/if}') < cell.indexOf("t('grid.copyValue')"));
  assert.match(cell, /use:focusNow onclick=\{\(\) => copy\('value'\)\}/);
  assert.ok(cell.indexOf("t('grid.copyRowHeader')") < cell.indexOf('{#each extra as entry, i}'));
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  // aba Dados (item 31): marcar ou desmarcar a linha, Exportar linhas marcadas > CSV... / Excel (.xlsx)..., Desmarcar todas
  assert.match(app, /let dataExtra = \$derived\(\[\s*\{ label: t\('edit\.mark'\), run: toggleMark \},\s*\{ label: t\('marks\.export'\), off: !canExport\('marked'\), items: exportItems\('marked', \['csv', 'xlsx'\]\) \},\s*\{ label: t\('edit\.unmarkAll'\), off: !markedRows\.length, run: unmarkAll \},\s*\]\);/);
  // aba Termos (item 32): os 3 copiar de sempre, as linhas encontradas da tabela e o relatorio nos 4 formatos
  assert.match(app, /let termsExtra = \$derived\(\[\s*\{ label: t\('terms\.copyHits'\), run: copyTermHits \},\s*\{ label: t\('export\.terms'\), off: !canExport\('terms'\), items: exportItems\('terms', \['xlsx', 'csv', 'sqlite', 'duckdb'\]\) \},\s*\]\);/);
});

// item 31: primeira coluna da grade de Dados = caixa de marcar, estreita e sem titulo (dica no cabecalho); as marcadas
// no topo; embaixo da grade ", N marcadas" e, so com marcas, a caixa "So as marcadas" (= Exibir > So as linhas marcadas)
test('Data grid: mark column, marked rows on top, only-marked box', () => {
  const grid = markup('./Grid.svelte');
  assert.match(grid, /\{#if marks\}<th class="mark" title=\{t\('marks\.tip'\)\}><\/th>\{\/if\}\s*\{#each columns as col, c \(c\)\}/);
  assert.match(grid, /<td class="mark"><input type="checkbox" aria-label=\{t\('marks\.tip'\)\} checked=\{marks\.has\(row\)\} onchange=\{\(\) => marks\.toggle\(row\)\} \/><\/td>/);
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  assert.match(app, /let shownRows = \$derived\(gridRows\(markedRows, rows, showOnly\)\);/);
  assert.match(app, /rows=\{shownColumns\.length \? shownRows : \[\]\}/);
  assert.match(app, /marks=\{\{ has: \(row\) => markedRows\.includes\(row\), toggle: toggleMark \}\}\s*extra=\{dataExtra\}/);
  // as marcas sao por tabela e duram enquanto o arquivo estiver aberto: fechar, abrir outro e reabrir limpam
  assert.match(appFunction('resetTable'), /marks = new Map\(\);\s*onlyMarked = false;/);
  // "So as marcadas" desliga quando a tabela fica sem marcas e ao trocar de tabela (nao volta ligado sozinho)
  assert.match(appFunction('setMarks'), /if \(!list\.length && table === selectedTable\) onlyMarked = false;/);
  assert.match(appFunction('openTable'), /filters = \[\];\s*onlyMarked = false;/);
  // sem rowid (view) a marcada entraria no fim: a tabela e relida e elas voltam na ordem dela
  assert.match(appFunction('toggleMark'), /setMarks\(selectedTable, toggleMarked\(markedRows, row\)\);\s*if \(typeof row\[ROW_ID\] !== 'number'\) openTable\(selectedTable\);/);
  // a consulta manda as identidades das marcadas e recebe as linhas delas a parte (qualquer que seja a pesquisa)
  assert.match(appFunction('openTable'), /marked: \(marked \?\? \[\]\)\.map\(\(row\) => row\[ROW_ID\]\) \}\),/);
  assert.match(appFunction('openTable'), /rows = withIds\(page\.rows, page\.ids\);[^\n]*\n[^\n]*\n\s*if \(marked && marks\.get\(tableName\) === marked\) setMarks\(tableName, withIds\(page\.marked, page\.marked_ids\)\);/);
  const ui = markup('./App.svelte');
  const info = ui.slice(ui.lastIndexOf('<p class="table-info">'), ui.indexOf('</main>'));
  assert.match(info, /\{markedRows\.length \? t\('marks\.count', \{ count: fmt\(markedRows\.length\) \}\) : ''\}/);
  assert.match(info, /\{#if markedRows\.length\}\s*<label class="only-marked"><input type="checkbox" checked=\{showOnly\} onchange=\{\(e\) => \(onlyMarked = e\.currentTarget\.checked\)\} \/>\{t\('marks\.only'\)\}<\/label>\s*\{\/if\}/);
  assert.match(app, /\n {6}onlyMarked: \{ run: \(\) => \(onlyMarked = !showOnly\), on: showOnly, off: !markedRows\.length \},/);
  assert.match(app, /\n {6}mark: \{ run: \(\) => toggleMark\(cell\.row\), off: !onData \},/);
  assert.match(app, /\n {6}unmarkAll: \{ run: unmarkAll, off: !markedRows\.length \},/);
});

// item 32: aba Termos de cima para baixo: (a) a caixa dos termos com a dica; (b) Valor inteiro | Contem, Esta tabela |
// Todas as tabelas, Pesquisar termos (Cancelar enquanto roda) e a contagem; (c) o resumo ou o progresso; (d) as tabelas
// com acerto e a grade da escolhida; (e) os nao encontrados, so leitura, com Copiar. Resultado velho nunca aparece
test('Terms tab: box, selectors, summary, tables with hits and grid, terms not found', () => {
  const ui = markup('./App.svelte');
  const terms = ui.slice(ui.indexOf("{:else if tab === 'terms'}"), ui.indexOf('{:else if !selectedTable}'));
  const order = [
    '<textarea bind:value={termsText} rows="8"',
    "{@render choice(MATCHES, match, (id) => (match = id), t('settings.match'), t('match.help'))}",
    "{@render choice(SCOPES, termsScope, (id) => (termsScope = id), t('scope.label'))}",
    "onclick={runTerms} disabled={!canRunTerms}>{t('terms.run')}",
    "t('terms.count'",
    "t('terms.summary'",
    '<div class="terms-found">',
    "t('found.item'",
    '<Grid',
    "t('data.showingMatches'",
    "t('terms.notFound'",
    "<textarea readonly rows=\"3\" value={termsResult.notFound.join('\\n')}",
  ].map((needle) => terms.indexOf(needle));
  assert.ok(order.every((v, i) => v >= 0 && (i === 0 || v > order[i - 1])), order.join(','));
  assert.match(terms, /placeholder=\{t\('terms\.hint'\)\}/);
  assert.match(terms, /\{#if termsWork\}\s*<button type="button" class="secondary" onclick=\{\(\) => invoke\('cancel_terms'\)\}>\{t\('common\.cancel'\)\}<\/button>/);
  assert.match(terms, /t\('terms\.progress', \{ done: termsWork\.total \? termsWork\.done \+ 1 : 0, total: termsWork\.total, item: termsWork\.item \}\)/);
  assert.match(terms, /onclick=\{copyNotFound\} disabled=\{!termsResult\.notFound\.length\}>\{t\('status\.copy'\)\}/);
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  assert.match(app, /\['terms', 'tabs\.terms'\],\s*\];/); // a aba depois de SQL
  // o padrao dos seletores vem de Configuracoes: Comparacao dos termos (inicial Valor inteiro) e Escopo padrao da busca
  assert.match(app, /let defaultMatch = \$state\(loadSetting\(MATCH_KEY\) === 'contains' \? 'contains' : 'whole'\);\s*let match = \$state\(defaultMatch\);[^\n]*\n\s*let termsScope = \$state\(defaultScope\);/);
  const run = appFunction('runTerms');
  assert.match(run, /dropTerms\(\);\s*const run = termsRun;/);
  assert.match(run, /const hits = await invoke\('search_terms', \{ terms, whole: match === 'whole', table \}\);\s*if \(run !== termsRun\) return;/);
  assert.match(run, /if \(termsResult\.tables\.length\) await openTermsTable\(termsResult\.tables\[0\]\.table\);/); // a primeira ja escolhida
  assert.match(appFunction('dropTerms'), /termsRun\+\+;\s*termsWork = null;\s*termsResult = null;/);
  assert.match(appFunction('resetTable'), /dropTerms\(\);/);
  // a grade: limite de linhas como em Dados (Linhas 100/500/1000)
  assert.match(appFunction('openTermsTable'), /const page = await invoke\('terms_rows', \{ table, limit, label: t\('terms\.col'\) \}\);\s*if \(run === termsRun && table === termsTable\) termsPage = page;/);
  assert.match(appFunction('setLimit'), /limit = next;\s*openTable\(selectedTable\);\s*if \(termsTable\) openTermsTable\(termsTable\);/);
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
  // Exibir > Log (menus.js) e item marcavel: o snippet dos menus desenha menuitemcheckbox para todo comando com `on`
  assert.match(readFileSync(new URL('./menus.js', import.meta.url), 'utf8'), /\['log', 'view\.log', 'Ctrl\+L'\],/);
  assert.match(readFileSync(new URL('./App.svelte', import.meta.url), 'utf8'), /\n {6}log: \{ run: \(\) => setLog\(!logOpen\), on: logOpen \},/);
  assert.match(app, /role=\{command\.on === undefined \? 'menuitem' : command\.radio \? 'menuitemradio' : 'menuitemcheckbox'\}\s*aria-checked=\{command\.on\}/);
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
  assert.equal(count(app, 'onclick={() => setLog(!logOpen)}'), 1); // seta da barra de status
  assert.match(app, /\n {6}log: \{ run: \(\) => setLog\(!logOpen\), on: logOpen \},/); // Exibir > Log e Ctrl+L
  assert.match(appFunction('shortcut'), /\n\s*l: 'log',/);
  assert.match(app, /onclick=\{\(\) => setLog\(true\)\}>\{headline\.text\}/);
  const css = app.match(/<style>([\s\S]*)<\/style>/)[1];
  assert.match(css, /\.log textarea \{[^}]*height: 10vh;[^}]*min-height: calc\(3 \* 1\.4em \+ 10px\);[^}]*max-height: 25vh;[^}]*font-size: 11px;/);
  for (const [key, text] of Object.entries(en)) if (key.startsWith('status.')) assert.doesNotMatch(text, /\.\.\./, key);
});

// REGRA_VISUAL "Dialogos: sempre com OK": todo dialogo tem botao visivel de fechar/OK; Enter = botao padrao; Esc fecha
test('every dialog has a visible default button, Enter and Esc', () => {
  const app = markup('./App.svelte');
  const dialogs = [...app.matchAll(/<dialog[\s\S]*?<\/dialog>/g)].map((m) => m[0]);
  // Sobre, X11, pergunta com botoes (sair, exportacao em andamento, tabela inteira/linhas encontradas), Colunas, progresso
  assert.equal(dialogs.length, 5);
  // a pergunta desenha os botoes da lista: o primary e o padrao (toda pergunta de App.svelte tem um)
  for (const d of dialogs) assert.match(d, /<button type="button" class="[^"]*default[^"]*"|class=\{button\.primary \? 'default' : 'secondary'\}/, d.slice(0, 80));
  const code = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  for (const asked of code.matchAll(/await ask\(\{[\s\S]*?buttons: \[([\s\S]*?)\],/g)) assert.equal(count(asked[1], 'primary: true'), 1, asked[1]);
  for (const name of ['aboutDialog', 'x11Dialog', 'progressDialog', 'askDialog']) {
    assert.ok(code.includes(`${name}.querySelector('button.default')`), name); // foco inicial no botao padrao
  }
  assert.match(code, /onkeydown=\{\(e\) => e\.key === 'Enter' && columnsDialog\.close\(\)\}/);
  assert.match(code, /oncancel=\{\(e\) => \{\s*e\.preventDefault\(\);\s*invoke\('cancel_export'\);/);
});
