// Arvore dos menus: a mesma nas 4 versoes, nesta ordem (todo botao da tela tem o seu item de menu). Compara a arvore de
// menus.js, com os textos do catalogo pt-BR, com a lista combinada; e confere que todo item tem comando no App.svelte.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { CATALOGS, translator } from './i18n.js';
import { EXPORT_MENU, MENUS, menuLines } from './menus.js';

const EXPORT = [
  'Tabela atual >',
  '  CSV...',
  '  Excel (.xlsx)...',
  'Linhas marcadas >',
  '  CSV...',
  '  Excel (.xlsx)...',
  'Schema da tabela atual >',
  '  CSV...',
  '  Excel (.xlsx)...',
  'Schema do banco >',
  '  CSV...',
  '  Excel (.xlsx)...',
  'Todas as tabelas em CSV (um arquivo por tabela)...',
  'Resultado do SQL >',
  '  CSV...',
  '  Excel (.xlsx)...',
  'Resultado da busca em todas as tabelas (Excel)...',
  'Relatório da Pesquisa Avançada >',
  '  Excel (.xlsx)...',
  '  CSV...',
  '  SQLite (.sqlite)...',
  '  DuckDB (.duckdb)...',
];

const TREE = [
  'Arquivo >',
  '  Abrir...  Ctrl+O',
  '  Abrir o caminho digitado',
  '  Reabrir  F5',
  '  --',
  '  Salvar  Ctrl+S',
  '  Salvar como...  Ctrl+Shift+S',
  '  Exportar >',
  ...EXPORT.map((line) => `    ${line}`),
  '  --',
  '  Fechar  Ctrl+W',
  '  --',
  '  Sair  Ctrl+Q',
  'Editar >',
  '  Copiar valor  Ctrl+C',
  '  Copiar linha  Ctrl+Shift+C',
  '  Copiar linha com cabeçalho',
  '  Copiar todo o Log',
  '  --',
  '  Pesquisar  Ctrl+F',
  '  Filtrar por este valor',
  '  Limpar filtros',
  '  --',
  '  Marcar ou desmarcar linha  Espaço',
  '  Desmarcar todas as linhas',
  'Exibir >',
  '  Dados  Ctrl+1',
  '  Schema  Ctrl+2',
  '  SQL  Ctrl+3',
  '  Pesquisa Avançada  Ctrl+4',
  '  --',
  '  Linhas >',
  '    100',
  '    500',
  '    1000',
  '  Colunas...',
  '  Pesquisar em >',
  '    Esta tabela',
  '    Todas as tabelas',
  '  Só as linhas marcadas',
  '  Ir para a lista de tabelas  Ctrl+T',
  '  Favoritar ou desfavoritar tabela  Ctrl+D',
  '  --',
  '  Executar SQL  Ctrl+Enter',
  '  Pesquisar termos  Ctrl+Enter',
  '  --',
  '  Log  Ctrl+L',
  'Configurações >',
  '  Tema >',
  '    Sistema',
  '    Claro',
  '    Escuro',
  '  Idioma >',
  '    English',
  '    Português (Brasil)',
  '    Español',
  '  Escopo padrão da busca >',
  '    Esta tabela',
  '    Todas as tabelas',
  '  Comparação dos termos >',
  '    Valor inteiro',
  '    Contém',
  '  Exibir NULL',
  'Ajuda >',
  '  Sobre o mdb2sql',
];

test('the menu tree is the agreed one, in this order', () => {
  const pt = translator('pt-BR');
  assert.deepEqual(menuLines(MENUS, pt), TREE);
  // a mesma lista no botao Exportar... do topo
  assert.deepEqual(menuLines(EXPORT_MENU, pt), EXPORT);
  // ingles e espanhol: os itens novos com o texto combinado
  const en = menuLines(MENUS, translator('en'));
  for (const line of ['  Open the typed path', '  Reopen  F5', '  Save  Ctrl+S', '  Save as...  Ctrl+Shift+S', '  Copy the whole log', '  Mark or unmark row  Space', '  Unmark all rows', '  Only marked rows', '  Go to the table list  Ctrl+T', '  Run SQL  Ctrl+Enter', '  Search terms  Ctrl+Enter', '  Advanced Search  Ctrl+4', '    Whole value', '    Contains', '    Advanced Search report >', '    All tables to CSV (one file per table)...', '    All-tables search result (Excel)...']) {
    assert.ok(en.includes(line), `en: ${line}`);
  }
  const es = menuLines(MENUS, translator('es'));
  for (const line of ['  Abrir la ruta escrita', '  Guardar como...  Ctrl+Shift+S', '  Copiar todo el log', '  Marcar o desmarcar fila  Espacio', '  Desmarcar todas las filas', '  Solo las filas marcadas', '  Ir a la lista de tablas  Ctrl+T', '  Ejecutar SQL  Ctrl+Enter', '  Buscar términos  Ctrl+Enter', '  Búsqueda Avanzada  Ctrl+4', '  Comparación de términos >', '    Informe de la Búsqueda Avanzada >']) {
    assert.ok(es.includes(line), `es: ${line}`);
  }
});

// todo item (de qualquer nivel) tem o seu comando no App.svelte e todo texto de item e chave do catalogo, numero,
// nome de idioma ou atalho
test('every menu item has a command and a text', () => {
  const app = readFileSync(new URL('./App.svelte', import.meta.url), 'utf8');
  const commands = app.match(/let commands = \$derived\.by\(\(\) => \{[\s\S]*?\n {2}\}\);/)[0];
  const ids = [];
  const walk = (items) => {
    for (const item of items) {
      if (item === '-') continue;
      const [id, text, extra] = item;
      ids.push(id);
      assert.ok(text in CATALOGS.en || /^\d+$/.test(text) || /^[A-Z]/.test(text), `${id}: ${text}`);
      if (Array.isArray(extra)) walk(extra);
      else if (extra) assert.ok(extra in CATALOGS.en || /^(Ctrl\+|F5$)/.test(extra), `${id}: ${extra}`);
    }
  };
  walk(MENUS.map(([id, text, items]) => [id, text, items]));
  assert.equal(new Set(ids).size, ids.length, 'ids repetidos');
  const menus = MENUS.map(([id]) => id);
  for (const id of ids.filter((id) => !menus.includes(id))) {
    // comandos montados em laco: limit.N, scope.x, defaultScope.x, theme.N, lang.xx, match.x e export.*
    const looped = /^(limit|scope|defaultScope|theme|lang|match)\.|^export\./.test(id);
    const written = new RegExp(`\\n {6}(?:'${id.replace('.', '\\.')}'|${id}): \\{`).test(commands);
    assert.ok(looped || written, `sem comando: ${id}`);
  }
  for (const loop of ['radio(`limit.${n}`', 'radio(`scope.${id}`', 'radio(`defaultScope.${id}`', 'radio(`theme.${i}`', 'radio(`lang.${code}`', 'radio(`match.${id}`', 'for (const [id, , formats] of EXPORT_MENU)']) {
    assert.ok(commands.includes(loop), loop);
  }
  // os atalhos passam pelo mesmo comando do item do menu: valem quando ele vale
  assert.match(app, /function run\(id\) \{\s*openMenu = null;\s*const command = commands\[id\];\s*if \(command\?\.run && !command\.off\) command\.run\(\);/);
});
