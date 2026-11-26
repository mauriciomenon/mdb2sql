// NIVEL BASICO: Arvore dos menus, a mesma nas 4 versoes do app e nesta ordem: todo botao da tela tem o seu item.
// Item = [id, texto, atalho] ou [id, texto, [subitens]]; '-' = separador. O App.svelte diz o que cada id faz e quando
// fica desabilitado ou marcado; aqui fica so a arvore, que menus.test.js confere contra a lista combinada.
// NIVEL TECNICO: plain module so `node --test` can check the tree without a browser. A text that is not a catalog
// key (100, the name of a language, Ctrl+O) is shown as it is.
import { LANGS } from './i18n.js';

export const LIMITS = [100, 500, 1000];
// null devolve a janela (barra de titulo e webview) ao tema do sistema
export const THEMES = [
  ['theme.system', null],
  ['theme.light', 'light'],
  ['theme.dark', 'dark'],
];
// escopo da pesquisa: seletor junto ao campo (abas Dados e Termos) e Configuracoes > Escopo padrao da busca
export const SCOPES = [
  ['table', 'scope.table'],
  ['all', 'scope.all'],
];
// comparacao da pesquisa de termos: seletor da aba Termos e Configuracoes > Comparacao dos termos
export const MATCHES = [
  ['whole', 'match.whole'],
  ['contains', 'match.contains'],
];

// subitens "<id>.<formato>" com o texto do formato (CSV..., Excel (.xlsx)...)
const formats = (id, ...list) => list.map((format) => [`${id}.${format}`, `format.${format}`]);

// Exportar: lista fixa (o que nao se aplica fica desabilitado), a mesma no menu Arquivo e no botao Exportar...
export const EXPORT_MENU = [
  ['export.table', 'export.table', formats('export.table', 'csv', 'xlsx')],
  ['export.marked', 'export.marked', formats('export.marked', 'csv', 'xlsx')],
  ['export.tableSchema', 'export.tableSchema', formats('export.tableSchema', 'csv', 'xlsx')],
  ['export.dbSchema', 'export.dbSchema', formats('export.dbSchema', 'csv', 'xlsx')],
  ['export.tables.csv', 'export.tablesCsv'],
  ['export.sql', 'export.sql', formats('export.sql', 'csv', 'xlsx')],
  ['export.found.xlsx', 'export.found'],
  ['export.terms', 'export.terms', formats('export.terms', 'xlsx', 'csv', 'sqlite', 'duckdb')],
];

export const MENUS = [
  [
    'file',
    'menu.file',
    [
      ['open', 'file.open', 'Ctrl+O'],
      ['openPath', 'file.openPath'],
      ['reopen', 'file.reopen', 'F5'],
      '-',
      ['save', 'file.save', 'Ctrl+S'],
      ['saveAs', 'file.saveAs', 'Ctrl+Shift+S'],
      ['export', 'file.export', EXPORT_MENU],
      '-',
      ['close', 'file.close', 'Ctrl+W'],
      '-',
      ['exit', 'file.exit', 'Ctrl+Q'],
    ],
  ],
  [
    'edit',
    'menu.edit',
    [
      ['copyValue', 'grid.copyValue', 'Ctrl+C'],
      ['copyRow', 'grid.copyRow', 'Ctrl+Shift+C'],
      ['copyRowHeader', 'grid.copyRowHeader'],
      ['copyLog', 'edit.copyLog'],
      '-',
      ['find', 'edit.find', 'Ctrl+F'],
      ['filterValue', 'grid.filterValue'],
      ['clearFilters', 'grid.clearFilters'],
      '-',
      ['mark', 'edit.mark', 'key.space'],
      ['unmarkAll', 'edit.unmarkAll'],
    ],
  ],
  [
    'view',
    'menu.view',
    [
      ['tab.data', 'tabs.data', 'Ctrl+1'],
      ['tab.schema', 'tabs.schema', 'Ctrl+2'],
      ['tab.sql', 'tabs.sql', 'Ctrl+3'],
      ['tab.terms', 'tabs.terms', 'Ctrl+4'],
      '-',
      ['limit', 'limit.label', LIMITS.map((n) => [`limit.${n}`, String(n)])],
      ['columns', 'columns.button'],
      ['scope', 'scope.label', SCOPES.map(([id, key]) => [`scope.${id}`, key])],
      ['onlyMarked', 'view.onlyMarked'],
      ['goTables', 'view.goTables', 'Ctrl+T'],
      '-',
      ['runSql', 'view.runSql', 'Ctrl+Enter'],
      ['runTerms', 'terms.run', 'Ctrl+Enter'],
      '-',
      ['log', 'view.log', 'Ctrl+L'],
    ],
  ],
  [
    'settings',
    'menu.settings',
    [
      ['theme', 'settings.theme', THEMES.map(([key], i) => [`theme.${i}`, key])],
      ['lang', 'settings.language', LANGS.map(([code, name]) => [`lang.${code}`, name])],
      ['defaultScope', 'settings.searchScope', SCOPES.map(([id, key]) => [`defaultScope.${id}`, key])],
      ['match', 'settings.match', MATCHES.map(([id, key]) => [`match.${id}`, key])],
      ['showNull', 'settings.showNull'],
    ],
  ],
  ['help', 'menu.help', [['about', 'help.about']]],
];

// a arvore em texto, um item por linha com dois espacos por nivel ("Abrir...  Ctrl+O", "--" no separador): o teste
// compara com a lista combinada
export function menuLines(items, t, depth = 0) {
  return items.flatMap((item) => {
    const pad = '  '.repeat(depth);
    if (item === '-') return [`${pad}--`];
    const [, text, extra] = item;
    if (Array.isArray(extra)) return [`${pad}${t(text)} >`, ...menuLines(extra, t, depth + 1)];
    return [`${pad}${t(text)}${extra ? `  ${t(extra)}` : ''}`];
  });
}
