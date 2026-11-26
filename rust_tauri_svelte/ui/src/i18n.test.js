// Idiomas: os 3 catalogos tem as mesmas chaves e os mesmos {valores}, todo t('chave') usado existe, e nenhum
// texto de tela fica fora do catalogo (texto solto ou atributo fixo no markup dos .svelte).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { CATALOGS, LANGS, describe, translator } from './i18n.js';

const SOURCES = ['./App.svelte', './Grid.svelte'];
const read = (file) => readFileSync(new URL(file, import.meta.url), 'utf8');
// {nome} e {nome|singular|plural}: o nome do valor conta uma vez
const placeholders = (text) => [...new Set([...text.matchAll(/\{(\w+)(?:\|[^}]*)?\}/g)].map((m) => m[1]))].sort();

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
  for (const format of ['sqlite', 'duckdb', 'xlsx', 'csv']) assert.ok(`save.${format}` in CATALOGS.en && `format.${format}` in CATALOGS.en);
  for (const unit of ['Tables', 'Rows']) {
    for (const sheets of ['', 'Sheets']) assert.ok(`status.exported${unit}${sheets}` in CATALOGS.en, unit + sheets);
  }
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

// Schema: o titulo da coluna de nulidade era "Null"/"Nulo" e parecia um valor NULL sobre os YES/NO
test('Schema titles name the nullability column, never just NULL', () => {
  const titles = (code) => ['schema.column', 'schema.type', 'schema.nullable'].map((key) => CATALOGS[code][key]);
  assert.deepEqual(titles('en'), ['Column', 'Type', 'Nullable']);
  assert.deepEqual(titles('pt-BR'), ['Coluna', 'Tipo', 'Aceita nulo']);
  assert.deepEqual(titles('es'), ['Columna', 'Tipo', 'Admite nulo']);
  // padrao item 15: sem a coluna "#" e a nulidade traduzida (o backend manda YES/NO)
  assert.match(read('./App.svelte'), /\['schema\.column', 'schema\.type', 'schema\.nullable'\]\.map/);
  assert.ok(!('schema.number' in CATALOGS.en));
  assert.match(read('./App.svelte'), /t\(c\.null === 'NO' \? 'schema\.no' : 'schema\.yes'\)/);
  const yesNo = (code) => [CATALOGS[code]['schema.yes'], CATALOGS[code]['schema.no']];
  assert.deepEqual([yesNo('pt-BR'), yesNo('es'), yesNo('en')], [['Sim', 'Não'], ['Sí', 'No'], ['Yes', 'No']]);
});

test('license line of the About says GPL v2 or later in each language', () => {
  assert.equal(CATALOGS['pt-BR']['about.licenseValue'], 'GPL v2 ou posterior');
  assert.equal(CATALOGS.en['about.licenseValue'], 'GPL v2 or later');
  assert.equal(CATALOGS.es['about.licenseValue'], 'GPL v2 o posterior');
});

// padrao item 23: o mesmo item com o mesmo texto do catalogo do Go (a referencia de redacao), nas 3 linguas. Ficam com o
// texto que o padrao manda em outro lugar: topo e menu Arquivo (Zig), exportacao e menu do cabecalho (Rust/Zig), Sobre
// (Rust, titulo do Zig), "Aberto: ..." (Python/Zig), Todas as tabelas (Rust)
test('texts of the same item match the Go catalog in the 3 languages', (t) => {
  const goDir = new URL('../../../go_wails_react/i18n/', import.meta.url);
  let go;
  try {
    go = Object.fromEntries(['en', 'pt-BR', 'es'].map((code) => [code, JSON.parse(readFileSync(new URL(`${code}.json`, goDir), 'utf8'))]));
  } catch {
    t.skip('catalogo do Go fora deste checkout');
    return;
  }
  const goText = (code, key, ...args) => go[code][key].replace(/\{(\d)\}/g, (_, i) => String(args[i]));
  const same = [
    ['menu.main', 'menu.main'], ['menu.file', 'menu.file'], ['menu.view', 'menu.view'], ['menu.settings', 'menu.settings'],
    ['menu.help', 'menu.help'], ['view.log', 'menu.log'], ['settings.theme', 'menu.theme'], ['settings.language', 'menu.language'],
    ['settings.showNull', 'menu.showNull'], ['settings.searchScope', 'menu.searchScope'], ['edit.find', 'menu.search'], ['theme.system', 'theme.system'],
    ['theme.light', 'theme.light'], ['theme.dark', 'theme.dark'], ['open.title', 'dlg.open'], ['open.all', 'filter.all'],
    ['about.author', 'about.author'], ['about.license', 'about.license'], ['about.licenseValue', 'about.licenseText'],
    ['about.linkTip', 'about.openLink'], ['common.close', 'about.close'], ['common.cancel', 'conv.cancel'],
    ['convert.title', 'conv.title'], ['columns.search', 'cols.filter'],
    ['columns.none', 'cols.none'], ['columns.showAll', 'cols.showAll'], ['columns.hideAll', 'cols.hideAll'],
    ['columns.button', 'cols.button'], ['columns.tip', 'cols.tip'], ['tabs.view', 'tab.label'], ['tabs.data', 'tab.data'],
    ['tabs.sql', 'tab.sql'], ['limit.label', 'rows.label'], ['sql.label', 'sql.label'], ['sql.run', 'sql.run'],
    ['sql.result', 'sql.result'], ['data.allHidden', 'empty.noColumns'], ['data.noMatch', 'empty.noFilterMatch'],
    ['data.empty', 'empty.noRows'], ['search.placeholder', 'search.placeholder'], ['search.label', 'search.label'],
    ['scope.label', 'scope.label'], ['scope.table', 'scope.table'], ['scope.all', 'scope.all'], ['filters.label', 'filters.group'],
    ['filters.removeTip', 'filters.removeTip'], ['filters.clear', 'filters.clear'], ['schema.column', 'schema.column'],
    ['schema.type', 'schema.type'], ['schema.nullable', 'schema.nullable'], ['grid.cell', 'cellmenu.label'],
    ['grid.copyValue', 'cellmenu.copy'], ['grid.copyRow', 'cellmenu.copyRow'], ['grid.copyRowHeader', 'cellmenu.copyRowHeader'],
    ['grid.fitColumn', 'colmenu.fit'], ['grid.fitAll', 'colmenu.fitAll'], ['grid.hideColumn', 'colmenu.hide'],
    ['grid.columns', 'colmenu.columns'], ['grid.showAll', 'colmenu.showAll'], ['grid.filterValue', 'cellmenu.filter'],
    ['grid.clearFilters', 'cellmenu.clear'], ['grid.copiedValue', 'copied.value'], ['grid.copiedRow', 'copied.row'],
    ['grid.copiedRowHeader', 'copied.rowHeader'], ['log.title', 'log.title'], ['log.copyAll', 'log.copyAll'],
    ['log.show', 'log.expand'], ['log.hide', 'log.collapse'], ['status.copy', 'status.copy'], ['status.opening', 'status.loading'],
    ['status.openFailed', 'err.openFailed'], ['status.viaTip', 'status.sourceTip'], ['status.hiddenOne', 'hidden.one'],
    ['status.logCopied', 'copied.log'], ['x11.title', 'display.title'], ['x11.wayland', 'display.wayland'],
    ['x11.noDisplay', 'display.missingServer'], ['x11.copy', 'display.copy'], ['x11.help', 'display.help'],
    ['common.ok', 'display.ok'], ['err.exportCancelled', 'err.exportCancelled'],
  ];
  // [chave daqui, valores, chave do Go, argumentos do Go]
  const filled = [
    ['columns.title', { table: 'T' }, 'cols.title', ['T']],
    ['columns.count', { shown: 2, total: 5 }, 'cols.count', [2, 5]],
    ['filters.remove', { filter: 'F' }, 'filters.remove', ['F']],
    ['status.via', { source: 'S' }, 'status.source', ['S']],
    ['status.hiddenMany', { count: 3 }, 'hidden.many', [3]],
    ['status.closed', { name: 'x.mdb' }, 'status.closed', ['x.mdb']],
    ['status.sqliteSaved', { path: 'P' }, 'log.convertedSaved', ['P']],
    ['status.staleRemoved', { count: 3 }, 'log.staleRemoved', [3]],
    ['tables.filter', { count: 3 }, 'sidebar.filter', [3]],
    ['status.query', { rows: 5 }, 'info.sql', [5]],
    ['log.unread', { count: 2 }, 'log.unread', [2]],
    ['data.showing', { table: 'T', shown: 1, total: 2 }, 'info.showing', ['T', 1, 2]],
  ];
  // um item que o Go deixou de ter (a chave saiu do catalogo dele) nao tem com o que comparar
  const inGo = (code, goKey) => goKey in go[code];
  for (const [code] of LANGS) {
    const tr = translator(code);
    for (const [key, goKey] of same) if (inGo(code, goKey)) assert.equal(tr(key), goText(code, goKey), `${code} ${key} = Go ${goKey}`);
    for (const [key, values, goKey, args] of filled) {
      if (inGo(code, goKey)) assert.equal(tr(key, values), goText(code, goKey, ...args), `${code} ${key}`);
    }
  }
});

// BRIEF de 25/11, secao 8: os textos novos, identicos nas 4 versoes, nas 3 linguas (valores de exemplo nos {campos})
test('new texts of Save, exit, marked rows and Terms are the agreed ones', () => {
  const texts = [
    ['exit.text', { name: 'DB3.accdb' }, 'O banco convertido de DB3.accdb não foi salvo. Salvar antes de sair?', 'The database converted from DB3.accdb was not saved. Save before exiting?', 'La base de datos convertida de DB3.accdb no se guardó. ¿Guardar antes de salir?'],
    ['file.save', {}, 'Salvar', 'Save', 'Guardar'],
    ['common.back', {}, 'Voltar', 'Back', 'Volver'],
    ['file.exit', {}, 'Sair', 'Exit', 'Salir'],
    ['status.discarded', { name: 'DB3.accdb' }, 'SQLite convertido de DB3.accdb descartado', 'SQLite converted from DB3.accdb discarded', 'SQLite convertido de DB3.accdb descartado'],
    ['exportRun.title', {}, 'Exportação em andamento', 'Export in progress', 'Exportación en curso'],
    ['exportRun.text', { name: 'x.csv' }, 'Sair cancela a exportação de x.csv.', 'Exiting cancels the export of x.csv.', 'Salir cancela la exportación de x.csv.'],
    ['save.title', {}, 'Salvar como SQLite, DuckDB ou Excel (arquivos .mdb e .accdb não podem ser gravados)', 'Save as SQLite, DuckDB or Excel (.mdb and .accdb files cannot be written)', 'Guardar como SQLite, DuckDB o Excel (los archivos .mdb y .accdb no se pueden escribir)'],
    ['save.copyName', { name: 'DB3' }, 'DB3 (cópia)', 'DB3 (copy)', 'DB3 (copia)'],
    ['about.write', {}, 'Gravação', 'Writing', 'Escritura'],
    ['about.writeValue', {}, 'SQLite, DuckDB, Excel e CSV. Arquivos .mdb e .accdb não podem ser gravados: o formato do Access é proprietário da Microsoft.', 'SQLite, DuckDB, Excel and CSV. .mdb and .accdb files cannot be written: the Access format is proprietary to Microsoft.', 'SQLite, DuckDB, Excel y CSV. Los archivos .mdb y .accdb no se pueden escribir: el formato de Access es propiedad de Microsoft.'],
    ['ask.overwriteMany', { count: 3 }, '3 arquivos já existem nesta pasta. Substituir?', '3 files already exist in this folder. Replace them?', '3 archivos ya existen en esta carpeta. ¿Reemplazarlos?'],
    ['ask.overwriteMany', { count: 1 }, '1 arquivo já existe nesta pasta. Substituir?', '1 file already exists in this folder. Replace it?', '1 archivo ya existe en esta carpeta. ¿Reemplazarlo?'],
    ['err.sqlReadOnly', {}, 'A aba SQL só lê o banco: este comando não é permitido', 'The SQL tab only reads the database: this command is not allowed', 'La pestaña SQL solo lee la base de datos: este comando no está permitido'],
    ['marks.tip', {}, 'Marcar linhas', 'Mark rows', 'Marcar filas'],
    ['marks.count', { count: 3 }, ', 3 marcadas', ', 3 marked', ', 3 marcadas'],
    ['marks.count', { count: 1 }, ', 1 marcada', ', 1 marked', ', 1 marcada'],
    ['marks.only', {}, 'Só as marcadas', 'Only marked', 'Solo las marcadas'],
    ['marks.export', {}, 'Exportar linhas marcadas', 'Export marked rows', 'Exportar filas marcadas'],
    // BRIEF secao 13 e: o texto de fundo da caixa de termos com o exemplo, uma linha por termo
    [
      'terms.hint',
      {},
      'Cole os termos, um por linha (por exemplo, uma coluna do Excel). Exemplo:\ntexto1\ntexto2\ntexto3\npesquisa os 3 termos em todas as tabelas ou só na tabela selecionada.',
      'Paste the terms, one per line (for example, an Excel column). Example:\ntext1\ntext2\ntext3\nsearches the 3 terms in all tables or only in the selected table.',
      'Pegue los términos, uno por línea (por ejemplo, una columna de Excel). Ejemplo:\ntexto1\ntexto2\ntexto3\nbusca los 3 términos en todas las tablas o solo en la tabla seleccionada.',
    ],
    ['match.help', {}, 'Valor inteiro: a célula inteira é igual ao termo. Contém: a célula contém o termo. Maiúsculas e espaços nas pontas não contam.', 'Whole value: the whole cell equals the term. Contains: the cell contains the term. Case and spaces at the ends do not count.', 'Valor completo: la celda entera es igual al término. Contiene: la celda contiene el término. Mayúsculas y espacios en los extremos no cuentan.'],
    ['settings.match', {}, 'Comparação dos termos', 'Term matching', 'Comparación de términos'],
    ['terms.count', { count: 9 }, '9 termos', '9 terms', '9 términos'],
    ['terms.count', { count: 1 }, '1 termo', '1 term', '1 término'],
    ['terms.repeated', { count: 2 }, ', 2 repetidos', ', 2 repeated', ', 2 repetidos'],
    ['terms.repeated', { count: 1 }, ', 1 repetido', ', 1 repeated', ', 1 repetido'],
    ['terms.summary', { found: 8, total: 9, rows: 8, tables: 1 }, '8 de 9 termos encontrados: 8 linhas em 1 tabela', '8 of 9 terms found: 8 rows in 1 table', '8 de 9 términos encontrados: 8 filas en 1 tabla'],
    ['terms.summary', { found: 1, total: 1, rows: 1, tables: 2 }, '1 de 1 termo encontrado: 1 linha em 2 tabelas', '1 of 1 term found: 1 row in 2 tables', '1 de 1 término encontrado: 1 fila en 2 tablas'],
    // secao 17: com Esta tabela o resumo diz onde pesquisou
    ['terms.summaryIn', { found: 0, total: 8, rows: 0, tables: 0, table: 'T' }, '0 de 8 termos encontrados: 0 linhas em 0 tabelas (só em T)', '0 of 8 terms found: 0 rows in 0 tables (only in T)', '0 de 8 términos encontrados: 0 filas en 0 tablas (solo en T)'],
    ['terms.progress', { done: 2, total: 287, item: 'T' }, 'Pesquisando termos: tabela 2 de 287 (T)', 'Searching terms: table 2 of 287 (T)', 'Buscando términos: tabla 2 de 287 (T)'],
    ['terms.notFound', { count: 1 }, 'Não encontrados (1)', 'Not found (1)', 'No encontrados (1)'],
    ['terms.copyHits', {}, 'Copiar as linhas encontradas desta tabela', 'Copy the rows found in this table', 'Copiar las filas encontradas en esta tabla'],
    // item 34 (BRIEF secao 11)
    // BRIEF secao 13 b: o Log diz o formato real do arquivo salvo
    ['status.reused', { name: 'DB3.accdb', format: 'DuckDB', path: 'P' }, 'DB3.accdb: aberto o DuckDB salvo dele (P)', 'DB3.accdb: opened the DuckDB saved from it (P)', 'DB3.accdb: abierto el DuckDB guardado de él (P)'],
    // BRIEF secao 13 g: "Copiar todo el log" (a aba se chama Log nos 3 idiomas)
    ['edit.copyLog', {}, 'Copiar todo o Log', 'Copy the whole log', 'Copiar todo el log'],
    ['view.log', {}, 'Log', 'Log', 'Log'],
    // BRIEF secao 13 d: a aba Termos vira Pesquisa Avancada (Exibir Ctrl+4 e o relatorio em Exportar); o botao fica
    ['tabs.terms', {}, 'Pesquisa Avançada', 'Advanced Search', 'Búsqueda Avanzada'],
    ['export.terms', {}, 'Relatório da Pesquisa Avançada', 'Advanced Search report', 'Informe de la Búsqueda Avanzada'],
    ['terms.run', {}, 'Pesquisar termos', 'Search terms', 'Buscar términos'],
    // BRIEF secao 13 c: a aba e tudo que dizia esquema na tela viram "Schema"
    ['tabs.schema', {}, 'Schema', 'Schema', 'Schema'],
    ['export.tableSchema', {}, 'Schema da tabela atual', 'Current table schema', 'Schema de la tabla actual'],
    ['export.dbSchema', {}, 'Schema do banco', 'Database schema', 'Schema de la base de datos'],
    ['schema.label', { table: 'T' }, 'Schema de T', 'Schema of T', 'Schema de T'],
    ['fav.add', {}, 'Favoritar', 'Add to favorites', 'Añadir a favoritas'],
    ['fav.remove', {}, 'Desfavoritar', 'Remove from favorites', 'Quitar de favoritas'],
    ['view.favorite', {}, 'Favoritar ou desfavoritar tabela', 'Favorite or unfavorite table', 'Marcar o desmarcar tabla favorita'],
  ];
  const [pt, en, es] = ['pt-BR', 'en', 'es'].map(translator);
  for (const [key, values, inPt, inEn, inEs] of texts) {
    assert.deepEqual([pt(key, values), en(key, values), es(key, values)], [inPt, inEn, inEs], key);
  }
  // "Lembrar nesta sessao" saiu da tela, do codigo e do catalogo; os 3 "Banco para ..." sairam de Exportar
  // secao 13 c: nenhum texto da tela diz "esquema"
  for (const [code, catalog] of Object.entries(CATALOGS)) {
    assert.deepEqual(Object.entries(catalog).filter(([, text]) => /esquema/i.test(text)), [], code);
  }
  for (const gone of ['convert.remember', 'convert.text', 'convert.delete', 'export.dbSqlite', 'export.dbDuckdb', 'export.dbXlsx']) {
    assert.ok(!(gone in CATALOGS.en), gone);
  }
  assert.doesNotMatch(read('./App.svelte'), /rememberChoice|remembered\b/);
});

// padrao item 23: plural certo ("1 tabela", "2 tabelas", "0 tabelas") nas 3 linguas; cada forma escolhida pelo numero
// que o proprio texto mostra
test('counts agree in number', () => {
  const pt = translator('pt-BR');
  const en = translator('en');
  const es = translator('es');
  assert.equal(pt('schema.columns', { count: 1 }), '1 coluna');
  assert.equal(pt('schema.columns', { count: 0 }), '0 colunas');
  assert.equal(pt('data.showing', { table: 'T', shown: 1, total: 1 }), 'T: mostrando 1 de 1 linha');
  assert.equal(pt('data.showing', { table: 'T', shown: '1', total: '1.234' }), 'T: mostrando 1 de 1.234 linhas');
  assert.equal(pt('data.showingMatches', { table: 'T', shown: 1, matching: 1 }), 'T: mostrando 1 de 1 linha encontrada');
  assert.equal(es('data.showingMatches', { table: 'T', shown: 10, matching: 10 }), 'T: mostrando 10 de 10 filas encontradas');
  assert.equal(en('sql.summary', { rows: '1', columns: 3 }), '1 row, 3 columns');
  assert.equal(en('sql.summary', { rows: '100+', columns: 1 }), '100+ rows, 1 column');
  assert.equal(es('found.summary', { count: 1 }), '1 tabla con filas encontradas');
  assert.equal(pt('status.exportedRowsSheets', { count: 1, sheets: 1, path: 'x' }), '1 linha exportada em 1 aba para x');
  assert.equal(pt('export.foundRows', { count: '1' }), 'Só 1 linha encontrada');
  assert.equal(pt('export.foundRows', { count: '1.234' }), 'Só as 1.234 linhas encontradas');
  assert.equal(es('export.foundRows', { count: 1 }), 'Solo 1 fila encontrada');
  assert.equal(en('export.foundRows', { count: 1 }), 'Only 1 row found');
  assert.equal(en('export.foundRows', { count: 2 }), 'Only the 2 rows found');
  for (const [code, catalog] of Object.entries(CATALOGS)) {
    for (const [key, text] of Object.entries(catalog)) {
      for (const [marker, name] of text.matchAll(/\{(\w+)\|[^}]*\}/g)) {
        assert.match(marker, /^\{\w+\|[^|}]+\|[^|}]+\}$/, `${code} ${key}: ${marker}`);
        assert.ok(text.includes(`{${name}}`), `${code} ${key}: ${name} sem o numero`);
      }
    }
  }
});

test('translator fills {values}, falls back to English, describes backend keys', () => {
  const pt = translator('pt-BR');
  assert.equal(pt('status.hiddenMany', { count: 3 }), '3 colunas ocultas');
  assert.equal(translator('xx')('menu.file'), 'File');
  assert.equal(pt('missing.key'), 'missing.key');
  assert.equal(describe(pt, '[[err.unsupported]] .txt'), 'Formato de banco não suportado: .txt');
  assert.equal(describe(translator('es'), 'T1: [[err.exportCancelled]]'), 'T1: Exportación cancelada');
  // falha da pesquisa em todas as tabelas: frase no idioma da tela, detalhe do motor igual
  assert.equal(describe(pt, '[[err.countRows]] z: Invalid Input Error: test'), 'Não foi possível contar as linhas de z: Invalid Input Error: test');
  assert.equal(describe(pt, 'Binder Error: x'), 'Binder Error: x');
});
