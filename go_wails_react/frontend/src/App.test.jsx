import React from 'react';
import { readFileSync } from 'node:fs';
import { act, render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { vi, beforeEach } from 'vitest';
import App, { aboutLines, clampLogHeight, columnCellWidth, favoritesFirst, filterLabel, gridText, LOG_MIN, logLine, nullableText, parseTerms, progressText, ROWID, rowKey, rowToTsv, searchRows, statusLine, tsvField, withFilter } from './App.tsx';
import { CATALOGS, LANGS, translate, translateN } from './i18n';

const tables = ['RANGER_SOACCU', 'RANGER_SOGEN'];
const rows = [
  { ID: 1, NAME: 'Alpha' },
  { ID: 2, NAME: 'Beta' },
];

const bridge = {
  LoadDatabase: vi.fn(async () => tables),
  GetTableData: vi.fn(async () => rows),
  GetRowCount: vi.fn(async () => rows.length),
  GetTableSchema: vi.fn(async () => [
    { name: 'ID', type: 'INTEGER', null: 'NO' },
    { name: 'NAME', type: 'TEXT', null: 'YES' },
  ]),
};

const en = (key, ...args) => translate('en', key, ...args);

// a DuckDB parser error as the SQL tab receives it: several lines, the caret under the error
const ENGINE_ERROR = 'Parser Error: syntax error at or near "selec"\n\nLINE 1: selec 1\n        ^';

// opens a menubar menu and clicks one of its items
const menu = (name, item) => {
  fireEvent.click(screen.getByRole('button', { name }));
  fireEvent.click(screen.getByRole('menuitem', { name: item }));
};

// the item of an open menu with this label (after its check mark, before its submenu arrow or shortcut); the last
// one: a submenu item
const item = (text) => {
  const name = new RegExp(`^✓?${text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}( ▸| (Ctrl\\+|F5|Space|Espaço).*)?$`);
  return ['menuitem', 'menuitemradio', 'menuitemcheckbox'].flatMap((role) => screen.queryAllByRole(role, { name })).at(-1);
};

// opens a menubar menu or the Export... button, hovers each submenu of the path and clicks its last item
const pick = (button, ...path) => {
  fireEvent.click(screen.getByRole('button', { name: button }));
  for (const name of path.slice(0, -1)) fireEvent.mouseEnter(item(name));
  fireEvent.click(item(path.at(-1)));
};

// the visible texts of the buttons of a dialog (a sized button also holds, invisible, the texts that set its size)
const buttonTexts = (el) => within(el).getAllByRole('button').map((b) => (b.querySelector('.sized > span') ?? b).textContent);
// the hidden texts that size a button (owner 26/11: every button of a dialog as large as the longest text in the 3 languages)
const sizers = (b) => [...b.querySelectorAll('.sized > .ghost')].map((g) => g.textContent);

// the items of a menu as shown: a separator is "--", a submenu its name with the arrow
const menuTree = (menuEl) =>
  [...menuEl.children].map((el) => (el.tagName === 'HR' ? '--' : el.classList.contains('menu-root') ? el.querySelector('button').textContent : el.textContent));

// opens a database as a path typed in the path bar and Enter (Open..., F5 and File > Reopen with nothing open are the
// file dialog since standard 14); the field found by its class, in any language
const openDefault = () => {
  const field = document.querySelector('.pathbar input');
  fireEvent.change(field, { target: { value: 'C:\\data\\sample.duckdb' } });
  fireEvent.keyDown(field, { key: 'Enter' });
};

// File > Open... (the native file dialog)
const OPEN_DIALOG = /^Open\.\.\./;

beforeEach(() => {
  bridge.LoadDatabase.mockClear();
  bridge.GetTableData.mockClear();
  bridge.GetRowCount.mockClear();
  bridge.GetTableSchema.mockClear();
  global.window = Object.assign(window, {
    go: { main: { App: bridge } },
  });
  delete window.runtime;
});

describe('App IPC flow', () => {
  it('loads database via IPC and renders rows', async () => {
    render(<App />);

    openDefault();

    await waitFor(() => expect(bridge.LoadDatabase).toHaveBeenCalled());
    expect(await screen.findByText(/Loaded:/i)).toBeInTheDocument();

    // Should list tables and allow selection
    const tableItem = screen.getAllByText('RANGER_SOACCU')[0];
    expect(tableItem).toBeInTheDocument();
    fireEvent.click(tableItem);

    await waitFor(() => expect(bridge.GetTableData).toHaveBeenCalledWith('RANGER_SOACCU', 100, [], '', 0));
    expect(screen.getByText('Alpha')).toBeInTheDocument();
    expect(screen.getByText(/rows 1 to 2 of 2/)).toBeInTheDocument();
  });

  it('opens the file picked in the native dialog and shows its schema', async () => {
    const SelectDatabase = vi.fn(async () => 'C:\\data\\real.duckdb');
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SelectDatabase } } } });
    render(<App />);

    menu('File', OPEN_DIALOG);

    await waitFor(() => expect(bridge.LoadDatabase).toHaveBeenCalledWith('C:\\data\\real.duckdb'));
    expect(await screen.findByText(/Loaded: real\.duckdb \(2 tables\)/)).toBeInTheDocument();

    // standard item 15: the tab says "Schema" without the column count; the nullability values are translated
    fireEvent.click(await screen.findByRole('tab', { name: 'Schema' }));
    expect(screen.getByText('INTEGER')).toBeInTheDocument();
    const schemaTable = screen.getByRole('columnheader', { name: 'Nullable' }).closest('table');
    expect([...schemaTable.querySelectorAll('th')].map((th) => th.textContent)).toEqual(['Column', 'Type', 'Nullable']);
    expect([...schemaTable.querySelectorAll('tbody tr')].map((tr) => tr.lastChild.textContent)).toEqual(['No', 'Yes']);
    expect(schemaTable.className).toBe('schema'); // 6 px more on each side than the data grid (App.css)
    const pt = (key, ...args) => translate('pt-BR', key, ...args);
    const es = (key, ...args) => translate('es', key, ...args);
    expect(['YES', 'NO'].map((v) => nullableText(v, pt))).toEqual(['Sim', 'Não']);
    expect(['YES', 'NO'].map((v) => nullableText(v, es))).toEqual(['Sí', 'No']);
    expect(pt('tab.schema')).toBe('Schema'); // owner: Schema in the 3 languages
    expect(translate('es', 'export.dbSchema')).toBe('Schema de la base de datos');
  });

  // standard items 1 and 14: the path bar (field, Open..., Export...): Enter opens the typed path, Open... and Enter on
  // an empty field the file dialog (no Browse... any more); a file dropped on the window opens
  it('opens the path typed in the top bar, the one picked by Open... and a dropped file', async () => {
    const SelectDatabase = vi.fn(async () => 'C:\\data\\picked.sqlite');
    let drop;
    const OnFileDrop = vi.fn((cb, useDropTarget) => {
      drop = cb;
      expect(useDropTarget).toBe(false); // the whole window takes the drop
    });
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SelectDatabase } } }, runtime: { OnFileDrop } });
    render(<App />);
    const field = screen.getByRole('textbox', { name: 'Database file (.accdb, .mdb, .sqlite, .duckdb)' });
    expect(screen.getByRole('button', { name: 'Export...' })).toBeDisabled(); // nothing open yet

    fireEvent.change(field, { target: { value: '  C:\\data\\typed.duckdb ' } });
    fireEvent.keyDown(field, { key: 'Enter' });
    await waitFor(() => expect(bridge.LoadDatabase).toHaveBeenLastCalledWith('C:\\data\\typed.duckdb'));
    await screen.findByText('Alpha');
    expect(field).toHaveValue('C:\\data\\typed.duckdb');

    expect(screen.queryByRole('button', { name: 'Browse...' })).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Open...' }));
    await waitFor(() => expect(SelectDatabase).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(bridge.LoadDatabase).toHaveBeenLastCalledWith('C:\\data\\picked.sqlite'));
    await waitFor(() => expect(field).toHaveValue('C:\\data\\picked.sqlite'));

    await act(async () => {
      drop(10, 10, ['C:\\data\\dropped.mdb']);
    });
    await waitFor(() => expect(bridge.LoadDatabase).toHaveBeenLastCalledWith('C:\\data\\dropped.mdb'));
    await waitFor(() => expect(field).toHaveValue('C:\\data\\dropped.mdb'));

    // Enter on an empty field opens the file dialog, never an empty path
    const calls = bridge.LoadDatabase.mock.calls.length;
    fireEvent.change(field, { target: { value: '  ' } });
    fireEvent.keyDown(field, { key: 'Enter' });
    await waitFor(() => expect(SelectDatabase).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(bridge.LoadDatabase).toHaveBeenCalledTimes(calls + 1));
    expect(bridge.LoadDatabase).toHaveBeenLastCalledWith('C:\\data\\picked.sqlite');

    fireEvent.click(screen.getByRole('button', { name: 'Export...' }));
    expect(within(screen.getByRole('menu', { name: 'Export' })).getByRole('menuitem', { name: /^Current table ▸/ })).toBeEnabled();

    // File > Open the typed path is the Open button
    fireEvent.click(screen.getByRole('button', { name: 'Export...' }));
    fireEvent.change(field, { target: { value: 'C:\\data\\menu.duckdb' } });
    pick('File', 'Open the typed path');
    await waitFor(() => expect(bridge.LoadDatabase).toHaveBeenLastCalledWith('C:\\data\\menu.duckdb'));
  });

  // standard 17 (defect found by the owner 26/11): the Advanced Search starts in All tables whatever the default scope
  // of the Data tab (here This table): the owner's 8 terms pasted from Excel (CRLF) are found in RANGER_SOEQID and
  // RANGER_SOSTAT without touching anything; with This table the summary says where it looked
  it('searches the pasted terms in all tables even when the Data tab defaults to This table', async () => {
    const terms = [
      'GENERADOR CGS VIBRACION ANORMAL 1 CANAL 1', 'GENERADOR CGS VIBRACION ANORMAL 2 CANAL 1', 'TURBINA CGI VIBRACION ANORMAL 1 CANAL 1',
      'GENERADOR COJ EMP VIBRACION ANORMAL 1 CANAL 1', 'GENERADOR COJ EMP VIBRACION ANORMAL 2 CANAL 1', 'GENERADOR GGB ALIMENTACION CONTROL 24VCC',
      'GENERADOR GGB INTERRUPTORES CONTROL CIRCUITO 2', 'TURBINA CGI VIBRACION ANORMAL 2 CANAL 1',
    ];
    const all = {
      terms, repeated: 0, notFound: [],
      hits: terms.flatMap((term) => [{ term, table: 'RANGER_SOEQID', rows: 1 }, { term, table: 'RANGER_SOSTAT', rows: 1 }]),
      tables: [{ table: 'RANGER_SOEQID', rows: 8 }, { table: 'RANGER_SOSTAT', rows: 8 }],
    };
    const SearchTerms = vi.fn(async (_lines, _contains, table) => (table ? { terms, repeated: 0, hits: [], tables: [], notFound: terms } : all));
    const TermRows = vi.fn(async () => ({ columns: ['Term'], rows: [], more: false }));
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SearchTerms, TermRows, GetSearchScope: vi.fn(async () => 'table') } } } });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    await waitFor(() => expect(screen.getByRole('radio', { name: 'This table' })).toHaveAttribute('aria-checked', 'true')); // the Data tab
    fireEvent.click(screen.getByRole('tab', { name: 'Advanced Search' }));
    expect(screen.getByRole('radio', { name: 'All tables' })).toHaveAttribute('aria-checked', 'true');
    fireEvent.change(screen.getByLabelText('Advanced Search'), { target: { value: terms.join('\r\n') + '\r\n' } });
    fireEvent.click(screen.getByRole('button', { name: 'Search' }));
    await waitFor(() => expect(SearchTerms).toHaveBeenCalledTimes(1));
    const [lines, contains, table] = SearchTerms.mock.calls[0];
    expect([lines.map((l) => l.trim()).filter(Boolean), contains, table]).toEqual([terms, false, '']);
    expect(await screen.findByText('8 of 8 terms found: 16 rows in 2 tables')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('radio', { name: 'This table' }));
    fireEvent.click(screen.getByRole('button', { name: 'Search' }));
    await waitFor(() => expect(SearchTerms).toHaveBeenLastCalledWith(expect.any(Array), false, 'RANGER_SOACCU'));
    expect(await screen.findByText('0 of 8 terms found: 0 rows in 0 tables (only in RANGER_SOACCU)')).toBeInTheDocument();
    expect(translate('pt-BR', 'terms.onlyIn', 'X')).toBe('(só em X)');
    expect(translate('es', 'terms.onlyIn', 'X')).toBe('(solo en X)');
  });

  // standard items 20 and 28: the shortcuts of the menus
  it('has the shortcuts Ctrl+O, Ctrl+S, Ctrl+Shift+S, Ctrl+W, Ctrl+F, Ctrl+T, F5, Ctrl+Q and Ctrl+1/2/3/4', async () => {
    const SelectDatabase = vi.fn(async () => '');
    const DatabasePath = vi.fn(async () => 'C:\\data\\db.duckdb');
    const SaveDatabase = vi.fn(async () => '');
    const CloseDatabase = vi.fn(async () => {});
    const Quit = vi.fn();
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SelectDatabase, DatabasePath, SaveDatabase, CloseDatabase } } }, runtime: { Quit } });
    render(<App />);
    const key = (init) => fireEvent.keyDown(window, init);

    expect(key({ key: 'F5' })).toBe(false); // never the webview's page reload
    await waitFor(() => expect(SelectDatabase).toHaveBeenCalledTimes(1)); // nothing open: the file dialog (standard 14)
    pick('File', 'Reopen'); // the same from the menu
    await waitFor(() => expect(SelectDatabase).toHaveBeenCalledTimes(2));
    expect(bridge.LoadDatabase).not.toHaveBeenCalled(); // the dialog was cancelled: no default database
    openDefault();
    await screen.findByText('Alpha');
    key({ key: 'F5' });
    await waitFor(() => expect(bridge.LoadDatabase).toHaveBeenLastCalledWith('C:\\data\\db.duckdb')); // the open file again
    await screen.findByText('Alpha');

    key({ key: 'o', ctrlKey: true });
    await waitFor(() => expect(SelectDatabase).toHaveBeenCalled());
    key({ key: 'f', ctrlKey: true });
    expect(screen.getByLabelText('Search the table')).toHaveFocus();
    key({ key: '2', ctrlKey: true });
    expect(screen.getByRole('tab', { name: /Schema/ })).toHaveAttribute('aria-selected', 'true');
    key({ key: '3', ctrlKey: true });
    await waitFor(() => expect(screen.getByLabelText('SQL')).toHaveFocus());
    key({ key: '4', ctrlKey: true });
    expect(screen.getByRole('tab', { name: 'Advanced Search' })).toHaveAttribute('aria-selected', 'true');
    await waitFor(() => expect(screen.getByLabelText('Advanced Search')).toHaveFocus());
    key({ key: 'f', ctrlKey: true }); // the Terms tab has no search field: back to Data, on its search
    await waitFor(() => expect(screen.getByLabelText('Search the table')).toHaveFocus());
    key({ key: '1', ctrlKey: true });
    expect(screen.getByRole('tab', { name: 'Data' })).toHaveAttribute('aria-selected', 'true');
    key({ key: 't', ctrlKey: true });
    expect(screen.getByRole('button', { name: 'RANGER_SOACCU' })).toHaveFocus();

    const idle = () => waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
    key({ key: 's', ctrlKey: true });
    await waitFor(() => expect(SaveDatabase).toHaveBeenLastCalledWith(false));
    await idle();
    key({ key: 'S', ctrlKey: true, shiftKey: true });
    await waitFor(() => expect(SaveDatabase).toHaveBeenLastCalledWith(true));
    await idle();
    key({ key: 'w', ctrlKey: true });
    await waitFor(() => expect(CloseDatabase).toHaveBeenCalled());
    await screen.findByText(en('empty.formats'));
    key({ key: 's', ctrlKey: true }); // nothing open: Save is disabled, its key too
    expect(SaveDatabase).toHaveBeenCalledTimes(2);
    key({ key: 'q', ctrlKey: true });
    await waitFor(() => expect(Quit).toHaveBeenCalled());
  });

  // standard item 6: the table list shows each table's row count, as Zig; the counts of a closed file never show
  it('shows the row count of each table in the table list', async () => {
    let late;
    const TableCounts = vi
      .fn()
      .mockImplementationOnce(async () => [2, 3])
      .mockImplementationOnce(() => new Promise((resolve) => (late = resolve)));
    const CloseDatabase = vi.fn(async () => {});
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, TableCounts, CloseDatabase } } } });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    const list = screen.getByRole('navigation', { name: 'Tables' });
    await waitFor(() => expect(within(list).getByRole('button', { name: 'RANGER_SOGEN' }).textContent).toBe('RANGER_SOGEN3'));
    expect(within(list).getByRole('button', { name: 'RANGER_SOACCU' }).querySelector('.count').textContent).toBe('2');
    expect(list.querySelector('.table-head').textContent).toBe('TableRows');

    openDefault(); // the second count answers after the file was closed: dropped
    await waitFor(() => expect(TableCounts).toHaveBeenCalledTimes(2));
    menu('File', /^Close/);
    await waitFor(() => expect(CloseDatabase).toHaveBeenCalled());
    await act(async () => late([7, 8]));
    expect(list.querySelector('.count')).toBeNull();
  });

  // standard item 24: Data tab from top to bottom - one line (search, This table | All tables, Rows, Columns...), the
  // filters line only with value filters, the grid, one line under it; nothing else (the copy notice goes to the status bar)
  it('lays out the Data tab as the standard: one bar, filters only when set, the grid and one line under it', async () => {
    const GetRowCount = vi.fn(async (_t, filters, search) => (filters.length || search ? 1 : 2));
    const ClipboardSetText = vi.fn(async () => true);
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetRowCount } } }, runtime: { ClipboardSetText } });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    const content = document.querySelector('.content');
    const parts = () => [...content.children].map((el) => el.className);
    expect(parts()).toEqual(['content-bar', 'table-container', 'info']);
    const bar = content.querySelector('.content-bar');
    const search = within(bar).getByLabelText('Search the table');
    expect(search).toHaveAttribute('placeholder', 'Search the table');
    expect(within(bar).getByRole('radiogroup', { name: 'Search in' })).toBeInTheDocument();
    expect(within(bar).getByRole('combobox')).toBeInTheDocument();
    expect(within(bar).getByRole('button', { name: 'Columns...' })).toBeInTheDocument();
    expect(content.querySelector('.info').textContent).toBe('RANGER_SOACCU: rows 1 to 2 of 2◀▶');

    fireEvent.contextMenu(screen.getByText('Beta'));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Filter by this value' }));
    await screen.findByText("Filter: NAME = 'Beta'");
    expect(parts()).toEqual(['content-bar', 'filters', 'table-container', 'info']);
    await waitFor(() => expect(content.querySelector('.info').textContent).toBe('RANGER_SOACCU: row 1 of 1 found◀▶'));

    fireEvent.contextMenu(screen.getByText('Beta'));
    fireEvent.click(screen.getByRole('menuitem', { name: /Copy value/ }));
    await waitFor(() => expect(screen.getByRole('status').textContent).toBe('Copied value'));
    expect(content.querySelector('.info').textContent).toBe('RANGER_SOACCU: row 1 of 1 found◀▶');
  });

  it('does nothing when the dialog is cancelled', async () => {
    const SelectDatabase = vi.fn(async () => '');
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SelectDatabase } } } });
    render(<App />);

    menu('File', OPEN_DIALOG);

    await waitFor(() => expect(SelectDatabase).toHaveBeenCalled());
    expect(bridge.LoadDatabase).not.toHaveBeenCalled();
    expect(screen.getByText('No database loaded')).toBeInTheDocument();
  });

  it('shows the real file name when the default database is loaded', async () => {
    const DatabaseName = vi.fn(async () => 'DB4.duckdb');
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, DatabaseName } } } });
    render(<App />);

    openDefault();

    expect(await screen.findByText(/Loaded: DB4\.duckdb \(2 tables\)/)).toBeInTheDocument();
    expect(bridge.LoadDatabase).toHaveBeenCalledWith('C:\\data\\sample.duckdb');
  });

  // standard 18b (owner 26/11): the About of the 4 versions, only these lines in this order (technical text), then the
  // GitHub / GitLab links, opened in the default browser
  it('shows Help > About with the lines of the 4 versions and the two links opened in the browser', async () => {
    const commit = '0123456789abcdef0123456789abcdef01234567';
    const GetAppInfo = vi.fn(async () => ({
      version: '1.3.0', commit, buildDate: '2026-11-26', go: '1.26.11', wails: 'v2.13.0', webview: 'WebView2 158.0.4370.33', duckdb: 'v2.0.0', sqlite: '3.38.1', mdbtools: 'mdbtools 1.0.1',
    }));
    const BrowserOpenURL = vi.fn();
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetAppInfo } } }, runtime: { BrowserOpenURL } });
    render(<App />);

    fireEvent.click(screen.getByRole('button', { name: 'Help' }));
    fireEvent.click(screen.getByRole('menuitem', { name: 'About mdb2sql' }));

    const dialog = await screen.findByRole('dialog', { name: 'About mdb2sql' });
    expect([...dialog.querySelectorAll('p')].map((p) => p.textContent)).toEqual([
      'MDB2SQL (Go)',
      `Version 1.3.0 - commit ${commit} - 2026-11-26`,
      'Go 1.26.11, Wails 2.13.0, WebView2 158.0.4370.33',
      'Tools: SQLite 3.38.1, DuckDB 2.0.0, mdbtools 1.0.1',
      'ODBC driver support, if installed.',
      'Author: Mauricio Menon',
      'License: GPLv2',
      'GitHub / GitLab',
    ]);

    // the links open in the default browser, never inside the app's own webview
    for (const [name, url] of [['GitHub', 'https://github.com/mauriciomenon/mdb2sql'], ['GitLab', 'https://gitlab.com/mauricio.menon/mdb2sql']]) {
      const link = screen.getByRole('link', { name });
      expect(link).toHaveAttribute('href', url);
      expect(fireEvent.click(link)).toBe(false); // default navigation prevented
      expect(BrowserOpenURL).toHaveBeenLastCalledWith(url);
    }
    expect(BrowserOpenURL).toHaveBeenCalledTimes(2);

    fireEvent.click(screen.getByRole('button', { name: 'Close' }));
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    // outside a build: "dev"; no SQLite extension: DuckDB only
    const pt = (key, ...args) => translate('pt-BR', key, ...args);
    expect(aboutLines({ version: '1.3.0', go: '1', wails: 'v2', duckdb: 'v3', webview: 'WebKitGTK' }, pt)).toEqual([
      'MDB2SQL (Go)', 'Versão 1.3.0 - dev', 'Go 1, Wails 2, WebKitGTK', 'Ferramentas: DuckDB 3', 'Suporte ao driver ODBC, caso instalado.',
      'Autor: Mauricio Menon', 'Licença: GPLv2',
    ]);
    expect(translate('es', 'about.tools', 'x') + ' ' + translate('es', 'about.odbc')).toBe('Herramientas: x Soporte del controlador ODBC, si está instalado.');
    expect(pt('about.title')).toBe('Sobre o mdb2sql');
    // the version line with the 40-digit commit fits (640 px); a narrow window breaks it between words, not in the date
    const css = readFileSync('src/App.css', 'utf8').replace(/\r\n/g, '\n').replace(/\/\*[\s\S]*?\*\//g, '');
    const rule = (sel) => css.match(new RegExp(`(?:^|\\n)${sel.replace(/[.*]/g, '\\$&')} \\{([^}]*)\\}`))?.[1] ?? '';
    expect(rule('.about')).toMatch(/max-width: 640px;/);
    expect(rule('.about p')).toMatch(/overflow-wrap: break-word;/);
  });

  it('hides several columns at once from Columns... and from the header menu', async () => {
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    const header = (name) => screen.queryByRole('columnheader', { name });

    expect(screen.getByRole('button', { name: 'Columns...' }).title).toBe('Search and export use every column');
    fireEvent.click(screen.getByRole('button', { name: 'Columns...' }));
    const dialog = screen.getByRole('dialog', { name: 'Columns of RANGER_SOACCU' });
    fireEvent.click(screen.getByRole('checkbox', { name: 'NAME' }));
    expect(header('NAME')).not.toBeInTheDocument();
    expect(screen.queryByText('Alpha')).not.toBeInTheDocument();
    expect(screen.getByText('1 hidden column')).toBeInTheDocument();
    // one column always stays: Hide all keeps the first listed, and the box of the last visible one is disabled
    fireEvent.click(screen.getByRole('button', { name: 'Hide all' }));
    expect(screen.getByText('1 hidden column')).toBeInTheDocument();
    expect(header('ID')).toBeInTheDocument();
    expect(screen.getByRole('checkbox', { name: 'ID' })).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: 'Show all' }));
    expect(screen.getByRole('checkbox', { name: 'NAME' })).toBeChecked();
    fireEvent.click(screen.getByRole('checkbox', { name: 'ID' }));
    fireEvent.click(screen.getByRole('button', { name: 'Close' }));
    expect(dialog).not.toBeInTheDocument();
    expect(header('ID')).not.toBeInTheDocument();
    expect(header('NAME')).toBeInTheDocument();

    // header menu: the columns with a check mark (a click toggles one); the last visible one cannot be hidden there
    fireEvent.contextMenu(header('NAME'));
    expect(screen.getByRole('menuitem', { name: 'Hide this column' })).toBeDisabled();
    expect(screen.getByRole('menuitemcheckbox', { name: /NAME/ })).toBeDisabled();
    expect(screen.getByRole('menuitemcheckbox', { name: /ID/ })).toHaveAttribute('aria-checked', 'false');
    fireEvent.click(screen.getByRole('menuitemcheckbox', { name: /ID/ }));
    expect(header('ID')).toBeInTheDocument();
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
    fireEvent.contextMenu(header('ID'));
    fireEvent.click(screen.getByRole('menuitemcheckbox', { name: /NAME/ }));
    expect(screen.getByText('1 hidden column')).toBeInTheDocument();
    fireEvent.contextMenu(header('ID'));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Show all columns' }));
    expect(screen.queryByText(/hidden columns?$/)).not.toBeInTheDocument();
    expect(screen.getByText('Alpha')).toBeInTheDocument();

    // another table starts with every column visible
    fireEvent.contextMenu(header('NAME'));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Hide this column' }));
    fireEvent.click(screen.getByRole('button', { name: 'RANGER_SOGEN' }));
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOGEN', 100, [], '', 0));
    await waitFor(() => expect(header('NAME')).toBeInTheDocument());
  });

  it('resizes a Data column by its header edge; Size column to fit and Size all columns to fit undo it', async () => {
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    const header = (name) => screen.getByRole('columnheader', { name });
    const drag = (name, dx) => {
      fireEvent.mouseDown(header(name).querySelector('.col-resize'), { clientX: 100 });
      fireEvent.mouseMove(window, { clientX: 100 + dx });
      fireEvent.mouseUp(window);
    };
    drag('NAME', 40); // jsdom has no layout: the header starts at 0 px
    expect(header('NAME').style.maxWidth).toBe('40px');
    expect(screen.getByText('Beta').style.maxWidth).toBe('40px'); // its cells too
    drag('ID', 10);
    expect(header('ID').style.width).toBe('24px'); // never narrower than 24 px

    fireEvent.contextMenu(header('NAME'));
    const items = [...screen.getByRole('menu', { name: 'Column' }).querySelectorAll('button')].map((b) => b.textContent);
    // standard item 13: the order of Rust, "Show all columns" before the column list (disabled: none hidden)
    expect(items).toEqual(['Size column to fit', 'Size all columns to fit', 'Hide this column', 'Columns...', 'Show all columns', '✓ID', '✓NAME']);
    expect(screen.getByRole('menuitem', { name: 'Show all columns' })).toBeDisabled();
    const menuBox = screen.getByRole('menu', { name: 'Column' });
    expect([...menuBox.children].map((el) => el.tagName)).toEqual(['BUTTON', 'BUTTON', 'HR', 'BUTTON', 'BUTTON', 'BUTTON', 'HR', 'BUTTON', 'BUTTON']);
    fireEvent.click(screen.getByRole('menuitem', { name: 'Size column to fit' }));
    expect(header('NAME').style.width).toBe('');
    expect(header('ID').style.width).toBe('24px');
    fireEvent.contextMenu(header('NAME'));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Size all columns to fit' }));
    expect(header('ID').style.width).toBe('');

    // the widths belong to the open table: another table starts fitted
    drag('ID', 60);
    fireEvent.click(screen.getByRole('button', { name: 'RANGER_SOGEN' }));
    await waitFor(() => expect(header('ID').style.width).toBe(''));
  });

  it('Show all / Hide all act only on the columns the dialog search lists', async () => {
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    fireEvent.click(screen.getByRole('button', { name: 'Columns...' }));
    expect(screen.getByLabelText('Filter columns')).toHaveFocus();
    fireEvent.change(screen.getByLabelText('Filter columns'), { target: { value: 'na' } });
    expect(screen.queryByRole('checkbox', { name: 'ID' })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Hide all' })); // only the listed ones
    expect(screen.getByText('1 of 2 visible')).toBeInTheDocument();
    expect(screen.queryByRole('columnheader', { name: 'NAME' })).not.toBeInTheDocument();
    expect(screen.getByRole('columnheader', { name: 'ID' })).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText('Filter columns'), { target: { value: 'id' } });
    fireEvent.click(screen.getByRole('button', { name: 'Hide all' })); // ID is the last visible one: it stays
    expect(screen.getByText('1 of 2 visible')).toBeInTheDocument();
    expect(screen.getByRole('columnheader', { name: 'ID' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Show all' })); // ID is visible already; NAME stays hidden
    expect(screen.getByText('1 of 2 visible')).toBeInTheDocument();
    expect(document.querySelector('.col-list').style.getPropertyValue('--col-w')).toBe('150px');

    expect(columnCellWidth(['ID', 'NAME'])).toBe(150); // short names: the 150 px floor (about 4 per row at 1280x800)
    expect(columnCellWidth(['X'.repeat(30)])).toBe(30 * 8 + 44);
    expect(columnCellWidth([])).toBe(150);
  });

  it('searches the whole table in the database (Data tab), after a pause in typing', async () => {
    const GetRowCount = vi.fn(async (_t, _f, search) => (search ? 1 : 2));
    // Settings > Default search scope chosen This table (the default is All tables since standard 18a)
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetRowCount, GetSearchScope: vi.fn(async () => 'table') } } } });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    fireEvent.change(screen.getByLabelText('Search the table'), { target: { value: 'tension de campo' } });
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 100, [], 'tension de campo', 0), { timeout: 2000 });
    expect(GetRowCount).toHaveBeenCalledWith('RANGER_SOACCU', [], 'tension de campo');
    expect(await screen.findByText(/row 1 of 1 found$/)).toBeInTheDocument();
    // the search stays when another table is chosen
    fireEvent.click(screen.getByRole('button', { name: 'RANGER_SOGEN' }));
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOGEN', 100, [], 'tension de campo', 0));
    // Enter searches at once, without the pause
    fireEvent.change(screen.getByLabelText('Search the table'), { target: { value: 'u9a' } });
    expect(bridge.GetTableData).not.toHaveBeenLastCalledWith('RANGER_SOGEN', 100, [], 'u9a', 0);
    fireEvent.keyDown(screen.getByLabelText('Search the table'), { key: 'Enter' });
    expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOGEN', 100, [], 'u9a', 0);
  });

  it('searches all tables from the Data tab and opens a table of the list with the same search', async () => {
    let answer;
    const SearchAllTables = vi.fn(() => new Promise((resolve) => (answer = resolve)));
    let goProgress;
    const EventsOn = vi.fn((name, cb) => {
      if (name === 'progress') goProgress = cb;
      return () => {};
    });
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SearchAllTables } } }, runtime: { EventsOn } });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    const scope = screen.getByRole('radiogroup', { name: 'Search in' });
    expect(within(scope).getAllByRole('radio').map((r) => r.textContent)).toEqual(['This table', 'All tables']);
    // standard 18a: All tables by default, with nothing chosen in Settings
    expect(within(scope).getByRole('radio', { name: 'All tables' })).toHaveAttribute('aria-checked', 'true');
    expect(screen.queryByRole('checkbox', { name: /tables/ })).not.toBeInTheDocument();

    fireEvent.click(within(scope).getByRole('radio', { name: 'All tables' }));
    expect(SearchAllTables).not.toHaveBeenCalled(); // nothing to search yet: the table stays
    expect(screen.getByText('Alpha')).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText('Search the table'), { target: { value: 'tensao' } });
    fireEvent.keyDown(screen.getByLabelText('Search the table'), { key: 'Enter' });
    await waitFor(() => expect(SearchAllTables).toHaveBeenCalledWith('tensao'));
    // while Go counts, the line under the grid shows the table being counted
    act(() => goProgress({ done: 1, total: 2, label: 'RANGER_SOACCU' }));
    expect(screen.getByText('Searching RANGER_SOACCU - 1 of 2')).toBeInTheDocument();
    await act(async () => answer([{ table: 'RANGER_SOGEN', rows: 3 }]));
    // standard item 10: a list of "table (n)" (Python and Rust), no 2-column table
    const hit = await screen.findByRole('button', { name: 'RANGER_SOGEN (3)' });
    expect(hit.closest('ul').className).toBe('hits');
    expect(screen.queryByRole('columnheader')).not.toBeInTheDocument();
    expect(screen.getByText('1 table with rows matching "tensao"')).toBeInTheDocument();
    expect(bridge.GetTableData).not.toHaveBeenCalledWith('RANGER_SOACCU', 100, [], 'tensao', 0); // the grid is not queried

    fireEvent.click(hit);
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOGEN', 100, [], 'tensao', 0));
    expect(within(scope).getByRole('radio', { name: 'This table' })).toHaveAttribute('aria-checked', 'true');
    expect(await screen.findByText('Alpha')).toBeInTheDocument();

    SearchAllTables.mockImplementationOnce(async () => []);
    fireEvent.click(within(scope).getByRole('radio', { name: 'All tables' }));
    expect(await screen.findByText('No table matches.')).toBeInTheDocument();
  });

  it('keeps the default search scope in Settings and applies it', async () => {
    const SetSearchScope = vi.fn(async () => {});
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SetSearchScope, GetSearchScope: vi.fn(async () => 'all') } } } });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    expect(screen.getByRole('radio', { name: 'All tables' })).toHaveAttribute('aria-checked', 'true');
    fireEvent.click(screen.getByRole('button', { name: 'Settings' }));
    fireEvent.mouseEnter(item('Default search scope'));
    expect(screen.getByRole('menuitemradio', { name: /All tables/ })).toHaveAttribute('aria-checked', 'true');
    fireEvent.click(screen.getByRole('menuitemradio', { name: /This table/ }));
    expect(SetSearchScope).toHaveBeenCalledWith('table');
    expect(screen.getByRole('radio', { name: 'This table' })).toHaveAttribute('aria-checked', 'true');
    // the selector beside the search does not change the saved default
    fireEvent.click(screen.getByRole('radio', { name: 'All tables' }));
    expect(SetSearchScope).toHaveBeenCalledTimes(1);
  });

  // audit 2026-11-24: an older "All tables" answer never shows; a failed search shows its error and ends "Searching"
  it('drops the answer of an older All tables search and ends Searching when the search fails', async () => {
    const answers = [];
    const SearchAllTables = vi.fn(() => new Promise((resolve, reject) => answers.push({ resolve, reject })));
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SearchAllTables, GetSearchScope: vi.fn(async () => 'all') } } } });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    const box = screen.getByLabelText('Search the table');
    const searchFor = (text) => {
      fireEvent.change(box, { target: { value: text } });
      fireEvent.keyDown(box, { key: 'Enter' });
    };
    searchFor('ana');
    await waitFor(() => expect(SearchAllTables).toHaveBeenLastCalledWith('ana'));
    searchFor('bob'); // a new term before the answer
    await waitFor(() => expect(SearchAllTables).toHaveBeenLastCalledWith('bob'));
    await act(async () => answers[0].resolve([{ table: 'RANGER_SOGEN', rows: 9 }]));
    expect(screen.queryByRole('button', { name: 'RANGER_SOGEN (9)' })).not.toBeInTheDocument();
    expect(screen.getByText('Searching')).toBeInTheDocument();
    searchFor(''); // the term erased: the grid comes back and the answer of "bob" is dropped too
    await act(async () => answers[1].resolve([{ table: 'RANGER_SOGEN', rows: 5 }]));
    expect(screen.queryByRole('button', { name: 'RANGER_SOGEN (5)' })).not.toBeInTheDocument();
    expect(await screen.findByText('Alpha')).toBeInTheDocument();

    searchFor('zed');
    await waitFor(() => expect(SearchAllTables).toHaveBeenLastCalledWith('zed'));
    expect(screen.getByText('Searching')).toBeInTheDocument();
    await act(async () => answers[2].reject(new Error('Could not count the rows: boom')));
    expect(screen.queryByText('Searching')).not.toBeInTheDocument();
    expect(screen.getByText('Could not count the rows: boom')).toBeInTheDocument();
  });

  // decision 1 (same in the 4 apps): a table opened from the All tables list shows the count listed, so its value
  // filters are cleared, also when it is the table open now
  it('opens a table of the All tables list without its value filters', async () => {
    const SearchAllTables = vi.fn(async () => [{ table: 'RANGER_SOACCU', rows: 2 }]);
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SearchAllTables } } } });
    render(<App />);
    openDefault();
    fireEvent.contextMenu(await screen.findByText('Beta'));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Filter by this value' }));
    await screen.findByText("Filter: NAME = 'Beta'");
    fireEvent.click(screen.getByRole('radio', { name: 'All tables' }));
    fireEvent.change(screen.getByLabelText('Search the table'), { target: { value: 'a' } });
    fireEvent.keyDown(screen.getByLabelText('Search the table'), { key: 'Enter' });
    const hit = await screen.findByRole('button', { name: 'RANGER_SOACCU (2)' });
    fireEvent.click(hit);
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 100, [], 'a', 0));
    expect(screen.queryByRole('group', { name: 'Active filters' })).not.toBeInTheDocument();
  });

  // Go stops a running search when the file closes, and its "cancelled" answer arrives before Close returns
  it('closes the file during an All tables search without showing the cancelled search as an error', async () => {
    let cancelSearch;
    const SearchAllTables = vi.fn(() => new Promise((_, reject) => (cancelSearch = reject)));
    const CloseDatabase = vi.fn(async () => {
      cancelSearch(new Error('Could not count the rows: context canceled'));
      await new Promise((r) => setTimeout(r, 0));
    });
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SearchAllTables, CloseDatabase, GetSearchScope: vi.fn(async () => 'all') } } } });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    fireEvent.change(screen.getByLabelText('Search the table'), { target: { value: 'ana' } });
    fireEvent.keyDown(screen.getByLabelText('Search the table'), { key: 'Enter' });
    await waitFor(() => expect(SearchAllTables).toHaveBeenCalledWith('ana'));
    menu('File', /^Close/);
    await waitFor(() => expect(CloseDatabase).toHaveBeenCalled());
    expect(await screen.findByText('Closed sample.duckdb')).toBeInTheDocument();
    expect(screen.queryByText(/context canceled/)).not.toBeInTheDocument();
  });

  // audit 2026-11-24: the search of the previous file ran again on the next one
  it('opens another file with no Data search, no table list filter and the search scope of Settings', async () => {
    const SearchAllTables = vi.fn(async () => [{ table: 'RANGER_SOGEN', rows: 1 }]);
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SearchAllTables, GetSearchScope: vi.fn(async () => 'all') } } } });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    fireEvent.change(screen.getByLabelText('Search the table'), { target: { value: 'ana' } });
    fireEvent.keyDown(screen.getByLabelText('Search the table'), { key: 'Enter' });
    await screen.findByRole('button', { name: 'RANGER_SOGEN (1)' });
    fireEvent.click(screen.getByRole('radio', { name: 'This table' }));
    fireEvent.change(screen.getByLabelText('Filter 2 tables'), { target: { value: 'gen' } });

    openDefault();
    await waitFor(() => expect(bridge.LoadDatabase).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 100, [], '', 0));
    expect(screen.getByLabelText('Search the table')).toHaveValue('');
    expect(screen.getByLabelText('Filter 2 tables')).toHaveValue('');
    expect(screen.getByRole('radio', { name: 'All tables' })).toHaveAttribute('aria-checked', 'true');
    expect(await screen.findByText('Alpha')).toBeInTheDocument();
    expect(SearchAllTables).toHaveBeenCalledTimes(1);
  });

  it('filters by the right-clicked value in the database query and shows removable chips', async () => {
    const GetRowCount = vi.fn(async (_table, filters) => (filters.length ? 1 : 2));
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetRowCount } } } });
    render(<App />);
    openDefault();

    fireEvent.contextMenu(await screen.findByText('Beta'));
    expect(screen.getByRole('menuitem', { name: 'Clear filters' })).toBeDisabled();
    fireEvent.click(screen.getByRole('menuitem', { name: 'Filter by this value' }));
    const byName = { column: 'NAME', value: 'Beta' };
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 100, [byName], '', 0));
    expect(GetRowCount).toHaveBeenCalledWith('RANGER_SOACCU', [byName], '');
    expect(await screen.findByText("Filter: NAME = 'Beta'")).toBeInTheDocument();
    expect(await screen.findByText(/row 1 of 1 found$/)).toBeInTheDocument();

    // a second column is ANDed; the row limit keeps the filters
    fireEvent.contextMenu(screen.getByRole('cell', { name: '2' }));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Filter by this value' }));
    const byId = { column: 'ID', value: 2 };
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 100, [byName, byId], '', 0));
    expect(await screen.findByText('Filter: ID = 2')).toBeInTheDocument();
    fireEvent.change(screen.getByRole('combobox'), { target: { value: '500' } });
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 500, [byName, byId], '', 0));

    fireEvent.click(screen.getByRole('button', { name: 'Remove filter NAME' }));
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 500, [byId], '', 0));
    await waitFor(() => expect(screen.queryByText("Filter: NAME = 'Beta'")).not.toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: 'Clear filters' }));
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 500, [], '', 0));
    await waitFor(() => expect(screen.queryByRole('group', { name: 'Active filters' })).not.toBeInTheDocument());

    // changing table clears the filters
    fireEvent.contextMenu(screen.getByText('Beta'));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Filter by this value' }));
    await screen.findByText("Filter: NAME = 'Beta'");
    fireEvent.click(screen.getByRole('button', { name: 'RANGER_SOGEN' }));
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOGEN', 500, [], '', 0));
    await waitFor(() => expect(screen.queryByRole('group', { name: 'Active filters' })).not.toBeInTheDocument());
  });

  it('labels filters and keeps one filter per column', () => {
    expect(filterLabel({ column: 'SIGLA', value: 'U9A' })).toBe("SIGLA = 'U9A'");
    expect(filterLabel({ column: 'ID', value: 7 })).toBe('ID = 7');
    expect(filterLabel({ column: 'NOTE', value: null })).toBe('NOTE IS NULL');
    const a = { column: 'A', value: 1 };
    expect(withFilter([a, { column: 'B', value: 'x' }], { column: 'B', value: null })).toEqual([a, { column: 'B', value: null }]);
  });

  it('opens the startup file and shows the reader in the status bar', async () => {
    const StartupPath = vi.fn(async () => 'C:\\data\\DB4.accdb');
    const SourceKind = vi.fn(async () => 'mdbtools');
    const PendingConversion = vi.fn(async () => 'DB4.sqlite');
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, StartupPath, SourceKind, PendingConversion } } } });
    render(<App />);

    await waitFor(() => expect(bridge.LoadDatabase).toHaveBeenCalledWith('C:\\data\\DB4.accdb'));
    expect(await screen.findByText('Opened via mdbtools, converted to SQLite')).toBeInTheDocument();
    expect(screen.getByText(/Loaded: DB4\.accdb \(2 tables\)/)).toBeInTheDocument();
  });

  // standard item 27: another file, F5 and Close never ask (Go deletes the unsaved SQLite and logs it); leaving the app
  // with the converted SQLite not saved asks Save | Back, Exit. Esc and the x are Back; a Save cancelled in the file
  // dialog asks again; the Go log lines of the startup (leftovers removed) reach the Log
  it('asks only on exit about the converted SQLite: Save on the left, Back and Exit on the right', async () => {
    let pending = '';
    const LoadDatabase = vi.fn(async () => {
      pending = 'DB3.accdb'; // as if each file opened were an Access file
      return tables;
    });
    const SaveDatabase = vi.fn(async () => '');
    const CloseDatabase = vi.fn(async () => {});
    const Exit = vi.fn(async () => {});
    const StartupLog = vi.fn(async () => ['1 converted file from an earlier session removed']);
    global.window = Object.assign(window, {
      go: { main: { App: { ...bridge, LoadDatabase, PendingConversion: vi.fn(async () => pending), SaveDatabase, CloseDatabase, Exit, StartupLog } } },
    });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    fireEvent.keyDown(window, { key: 'F5' }); // the same file again: no question
    await waitFor(() => expect(LoadDatabase).toHaveBeenCalledTimes(2));
    await screen.findByText('Alpha');
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();

    const exitQuestion = async () => {
      menu('File', /^Exit/);
      return screen.findByRole('dialog', { name: 'Converted SQLite file' });
    };
    let dialog = await exitQuestion();
    expect(dialog.textContent).toContain('The database converted from DB3.accdb was not saved. Save before exiting?');
    expect(buttonTexts(dialog)).toEqual(['×', 'Save', 'Back', 'Exit']);
    // Save, Back and Exit of one size: each one sized by the same texts, the three of them in the three languages
    const sized = within(dialog).getAllByRole('button').slice(1).map(sizers);
    expect(sized[0]).toEqual(['Save', 'Back', 'Exit', 'Salvar', 'Voltar', 'Sair', 'Guardar', 'Volver', 'Salir']);
    expect(sized.every((s) => s.join() === sized[0].join())).toBe(true);
    expect(within(dialog).getByRole('button', { name: 'Save' })).toHaveFocus(); // Enter = Save
    expect(within(dialog).getByRole('button', { name: 'Back' }).className).toBe('end'); // Back and Exit on the right
    expect(dialog.textContent).not.toMatch(/Remember/);
    fireEvent.keyDown(window, { key: 'Escape' });
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
    dialog = await exitQuestion();
    fireEvent.click(within(dialog).getByRole('button', { name: 'Close' })); // the x
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
    dialog = await exitQuestion();
    fireEvent.click(within(dialog).getByRole('button', { name: 'Back' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
    expect(Exit).not.toHaveBeenCalled();
    expect(screen.getByText('Alpha')).toBeInTheDocument(); // the file stays open

    // Save cancelled in the file dialog: the question comes back; saved: the app leaves
    dialog = await exitQuestion();
    fireEvent.click(within(dialog).getByRole('button', { name: 'Save' }));
    await waitFor(() => expect(SaveDatabase).toHaveBeenCalledWith(false));
    dialog = await screen.findByRole('dialog', { name: 'Converted SQLite file' });
    SaveDatabase.mockImplementationOnce(async () => {
      pending = '';
      return 'C:\\data\\DB3.sqlite';
    });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Save' }));
    await waitFor(() => expect(Exit).toHaveBeenCalledTimes(1));
    expect(screen.getByRole('status').textContent).toBe('Exported sample.duckdb to C:\\data\\DB3.sqlite');

    // Exit: leaves without saving (Go deletes the temporary SQLite); Close asks nothing
    pending = 'DB3.accdb';
    dialog = await exitQuestion();
    fireEvent.click(within(dialog).getByRole('button', { name: 'Exit' }));
    await waitFor(() => expect(Exit).toHaveBeenCalledTimes(2));
    menu('File', /^Close/);
    await waitFor(() => expect(CloseDatabase).toHaveBeenCalled());
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Show the log' }));
    expect(screen.getByRole('textbox', { name: 'Log' }).value).toContain('1 converted file from an earlier session removed');
  });

  // standard item 27: the window closed (or Ctrl+Q) during an export asks first, Back or Exit; Exit cancels the export
  it('asks Back or Exit when leaving during an export, and Exit cancels it', async () => {
    let exitAsked;
    let finish;
    const EventsOn = vi.fn((name, cb) => {
      if (name === 'exit-asked') exitAsked = cb;
      return () => {};
    });
    const ExportTable = vi.fn(() => new Promise((resolve) => (finish = resolve)));
    const CancelJob = vi.fn(async () => finish(''));
    const Exit = vi.fn(async () => {});
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, ExportTable, CancelJob, Exit, PendingConversion: vi.fn(async () => '') } } }, runtime: { EventsOn } });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    pick('Export...', 'Current table', 'CSV...');
    await waitFor(() => expect(ExportTable).toHaveBeenCalled());

    act(() => {
      exitAsked(); // the window close button: Go asks the UI
    });
    let dialog = await screen.findByRole('dialog', { name: 'Export in progress' });
    expect(dialog.textContent).toContain('Exiting cancels the export of RANGER_SOACCU.');
    expect(buttonTexts(dialog)).toEqual(['×', 'Back', 'Exit']);
    fireEvent.keyDown(window, { key: 'Escape' }); // Back: the export goes on
    await waitFor(() => expect(screen.queryByRole('dialog', { name: 'Export in progress' })).not.toBeInTheDocument());
    expect(CancelJob).not.toHaveBeenCalled();
    expect(screen.getByRole('dialog', { name: 'Exporting' })).toBeInTheDocument();

    fireEvent.keyDown(window, { key: 'q', ctrlKey: true }); // Ctrl+Q works during the export
    dialog = await screen.findByRole('dialog', { name: 'Export in progress' });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Exit' }));
    await waitFor(() => expect(Exit).toHaveBeenCalled());
    expect(CancelJob).toHaveBeenCalled();
  });

  // owner: every dialog has a visible OK/Close button; Enter = default, Esc = close
  it('gives every dialog a close button, Enter for the default and Esc to close', async () => {
    const GetAppInfo = vi.fn(async () => ({ version: '1.3.0', go: '1', wails: '2', duckdb: '3' }));
    const DisplayWarning = vi.fn(async () => ({ text: 'X11 unavailable; using Wayland.', missing: 'X server not set (DISPLAY)', distro: 'Debian', command: '', help: 'https://x' }));
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetAppInfo, DisplayWarning } } } });
    render(<App />);
    const warn = await screen.findByRole('alertdialog', { name: 'Display mode' });
    expect(screen.getByRole('button', { name: 'OK' })).toHaveFocus();
    fireEvent.keyDown(window, { key: 'Escape' });
    expect(warn).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Help' }));
    fireEvent.click(screen.getByRole('menuitem', { name: 'About mdb2sql' }));
    await screen.findByRole('dialog', { name: /mdb2sql/ });
    expect(screen.getByRole('button', { name: 'Close' })).toHaveFocus();
    fireEvent.keyDown(window, { key: 'Escape' });
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());

    openDefault();
    await screen.findByText('Alpha');
    fireEvent.click(screen.getByRole('button', { name: 'Columns...' }));
    expect(screen.getByRole('button', { name: 'Close' })).toBeInTheDocument();
    fireEvent.keyDown(screen.getByLabelText('Filter columns'), { key: 'Enter' });
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Columns...' }));
    fireEvent.keyDown(window, { key: 'Escape' });
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
  });

  it('keeps the theme in Settings > Theme and saves the choice', async () => {
    const SetTheme = vi.fn(async () => {});
    const GetTheme = vi.fn(async () => 'light');
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SetTheme, GetTheme } } } });
    render(<App />);
    await waitFor(() => expect(document.documentElement.dataset.theme).toBe('light'));
    expect(screen.queryByRole('combobox', { name: /Theme/ })).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Settings' }));
    fireEvent.mouseEnter(item('Theme'));
    expect(screen.getByRole('menuitemradio', { name: /Light/ })).toHaveAttribute('aria-checked', 'true');
    fireEvent.click(screen.getByRole('menuitemradio', { name: /Dark/ }));

    expect(SetTheme).toHaveBeenCalledWith('dark');
    expect(document.documentElement.dataset.theme).toBe('dark');
  });

  // the startup file was opened by the first render, whose texts were English: pt-BR got "Loaded: ... (2 tables)"
  it('speaks the saved language when it opens the file of the command line', async () => {
    const StartupPath = vi.fn(async () => 'C:\\data\\DB4.sqlite');
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, StartupPath, GetLanguage: vi.fn(async () => 'pt-BR') } } } });
    render(<App />);
    expect(await screen.findByText('Aberto: DB4.sqlite (2 tabelas)')).toBeInTheDocument();
  });

  // standard item 2: "Aberto: {name} ({n} tabelas)", the verb of Python and Zig, with the right plural
  it('says Aberto with the file name and the table count, singular for one table', async () => {
    const LoadDatabase = vi.fn(async () => ['ONLY']);
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, LoadDatabase, GetLanguage: vi.fn(async () => 'pt-BR') } } } });
    render(<App />);
    expect(await screen.findByText('Nenhum banco aberto')).toBeInTheDocument();
    openDefault();
    expect(await screen.findByText('Aberto: sample.duckdb (1 tabela)')).toBeInTheDocument();
    expect(translate('en', 'status.loaded', 'x.mdb', 2)).toBe('Loaded: x.mdb (2 tables)');
    expect(translateN('es', 'status.loaded', 1, 'x.mdb', 1)).toBe('Abierto: x.mdb (1 tabla)');
    expect(translateN('es', 'status.loaded', 0, 'x.mdb', 0)).toBe('Abierto: x.mdb (0 tablas)');
  });

  it('switches the language from Settings > Language without restarting and saves it', async () => {
    const SetLanguage = vi.fn(async () => {});
    const GetLanguage = vi.fn(async () => 'es');
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SetLanguage, GetLanguage } } } });
    render(<App />);
    expect(await screen.findByRole('button', { name: 'Archivo' })).toBeInTheDocument(); // saved language
    expect(screen.getByText('Ninguna base de datos abierta')).toBeInTheDocument();

    pick('Configuración', 'Idioma', 'Português (Brasil)');
    expect(SetLanguage).toHaveBeenCalledWith('pt-BR');
    expect(screen.getByRole('button', { name: 'Arquivo' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Exibir' })).toBeInTheDocument();
    pick('Configurações', 'Idioma', 'English');
    expect(screen.getByRole('button', { name: 'File' })).toBeInTheDocument();
  });

  it('keeps the session messages in View > Log, selectable, with Copy all; the status bar copies on right-click', async () => {
    const ClipboardSetText = vi.fn(async () => true);
    let goLog;
    const EventsOn = vi.fn((name, cb) => {
      if (name === 'log') goLog = cb;
      return () => {};
    });
    global.window = Object.assign(window, { runtime: { ClipboardSetText, EventsOn } });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    goLog('DB4.accdb converted to SQLite with mdbtools in 12s');

    fireEvent.click(screen.getByRole('button', { name: 'View' }));
    fireEvent.click(screen.getByRole('menuitemcheckbox', { name: /Log/ }));
    const log = screen.getByRole('textbox', { name: 'Log' });
    expect(log).toHaveAttribute('readonly');
    expect(log.value).toMatch(/^\d\d:\d\d:\d\d {2}Loaded: sample\.duckdb \(2 tables\)$/m);
    expect(log.value).toMatch(/converted to SQLite with mdbtools in 12s$/m);
    fireEvent.click(screen.getByRole('button', { name: 'Copy all' }));
    await waitFor(() => expect(ClipboardSetText).toHaveBeenLastCalledWith(log.value.replace(/\n/g, '\r\n')));

    fireEvent.contextMenu(screen.getByRole('status'));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Copy' }));
    await waitFor(() => expect(ClipboardSetText).toHaveBeenLastCalledWith(screen.getByRole('status').textContent));

    fireEvent.click(screen.getByRole('button', { name: 'Collapse the log' }));
    expect(screen.queryByRole('textbox', { name: 'Log' })).not.toBeInTheDocument();
    expect(logLine('x', new Date(2026, 0, 2, 3, 4, 5))).toBe('03:04:05  x');
  });

  // owner's "Painel de Log": collapsed when the app opens (standard 18d); arrow, View > Log and Ctrl+L; collapsed, the
  // status bar shows the last unread error (then warning) with a counter, and a click on it expands the log
  it('collapses and expands the log and shows the last unread error in the status bar', async () => {
    const RunQuery = vi.fn(async () => {
      throw new Error(ENGINE_ERROR);
    });
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, RunQuery } } } });
    render(<App />);
    expect(screen.queryByRole('textbox', { name: 'Log' })).not.toBeInTheDocument(); // collapsed by default
    openDefault();
    await screen.findByText('Alpha');
    fireEvent.click(screen.getByRole('tab', { name: 'SQL' }));
    fireEvent.change(screen.getByLabelText('SQL'), { target: { value: 'select * from t' } });
    fireEvent.click(screen.getByRole('button', { name: 'Run' }));
    await waitFor(() => expect(screen.getByRole('status').className).toContain('error'));
    // one translated line in the status bar; the engine's full text (LINE 1, caret) only in the log
    expect(screen.getByRole('status').textContent).toBe('SQL query error: syntax error at or near "selec"');
    expect(screen.getByTitle('1 unread error or warning').textContent).toBe('1');

    // a later action does not hide the unread error while the log is collapsed
    fireEvent.click(screen.getByRole('tab', { name: 'Data' }));
    expect(screen.getByRole('status').textContent).toMatch(/syntax error/);

    fireEvent.click(screen.getByRole('status')); // click: expands, the error counts as read
    expect(screen.getByRole('textbox', { name: 'Log' }).value).toContain(ENGINE_ERROR);
    expect(screen.queryByTitle(/unread/)).not.toBeInTheDocument();
    expect(screen.getByRole('textbox', { name: 'Log' }).style.height).toMatch(/px$/);

    fireEvent.keyDown(window, { key: 'l', ctrlKey: true }); // Ctrl+L collapses
    expect(screen.queryByRole('textbox', { name: 'Log' })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Show the log' })); // the status bar arrow expands
    expect(screen.getByRole('textbox', { name: 'Log' })).toBeInTheDocument();

    expect(clampLogHeight(10, 800)).toBe(LOG_MIN); // at least 3 lines
    expect(clampLogHeight(500, 800)).toBe(200); // at most 25% of the window
    expect(clampLogHeight(80, 800)).toBe(80);
    const entries = [
      { line: '', text: 'w', level: 'warn' },
      { line: '', text: 'e', level: 'error' },
      { line: '', text: 'ok', level: 'info' },
    ];
    expect(statusLine(entries, 0, 'ok', '')).toEqual({ text: 'e', level: 'error', unread: 2 });
    expect(statusLine(entries, 2, 'ok', '')).toEqual({ text: 'ok', level: 'info', unread: 0 });
    expect(statusLine(entries.slice(0, 1), 0, 'ok', '')).toEqual({ text: 'w', level: 'warn', unread: 1 });
  });

  // standard item 16: the SQL field starts empty with the hint; a query that runs fine takes the earlier error off the
  // status bar, and an error clears the old grid
  it('starts the SQL field empty and clears the earlier SQL error after a good query', async () => {
    const RunQuery = vi.fn(async (q) => {
      if (q === 'bad') throw new Error(ENGINE_ERROR);
      return { columns: ['n'], rows: [{ n: 'good' }], more: false };
    });
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, RunQuery } } } });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    fireEvent.click(screen.getByRole('tab', { name: 'SQL' }));
    const field = screen.getByLabelText('SQL');
    expect(field).toHaveValue('');
    expect(field).toHaveAttribute('placeholder', 'SELECT * FROM ...');
    const run = (q) => {
      fireEvent.change(field, { target: { value: q } });
      fireEvent.keyDown(field, { key: 'Enter', ctrlKey: true });
    };
    run('ok');
    expect(await screen.findByText('good')).toBeInTheDocument();
    run('bad');
    await waitFor(() => expect(screen.getByRole('status').textContent).toBe('SQL query error: syntax error at or near "selec"'));
    expect(screen.queryByText('good')).not.toBeInTheDocument(); // the old grid is gone
    expect(screen.getByTitle('1 unread error or warning')).toBeInTheDocument();
    run('ok');
    expect(await screen.findByText('good')).toBeInTheDocument();
    await waitFor(() => expect(screen.getByRole('status').className).not.toContain('error'));
    expect(screen.getByRole('status').textContent).toBe('Loaded: sample.duckdb (2 tables)');
    expect(screen.queryByTitle(/unread/)).not.toBeInTheDocument();
  });

  // standard 18d: the Log is collapsed when the app opens, also if an older version left it expanded
  it('opens with the log collapsed', async () => {
    const GetLogOpen = vi.fn(async () => true); // what an older Go would still answer
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetLogOpen } } } });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    expect(screen.queryByRole('textbox', { name: 'Log' })).not.toBeInTheDocument();
    expect(GetLogOpen).not.toHaveBeenCalled();
  });

  it('leaves NULL cells empty by default; Settings > Show NULL shows NULL and saves the choice', async () => {
    const SetShowNull = vi.fn(async () => {});
    const ClipboardSetText = vi.fn(async () => true);
    const GetTableData = vi.fn(async () => [{ ID: 1, NAME: null }]);
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetTableData, SetShowNull } } }, runtime: { ClipboardSetText } });
    render(<App />);
    openDefault();
    await screen.findByRole('cell', { name: '1' });
    expect(screen.queryByText('NULL')).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Settings' }));
    expect(screen.getByRole('menuitemcheckbox', { name: /Show NULL/ })).toHaveAttribute('aria-checked', 'false');
    fireEvent.click(screen.getByRole('menuitemcheckbox', { name: /Show NULL/ }));
    expect(SetShowNull).toHaveBeenCalledWith(true);
    const cell = screen.getByText('NULL');
    fireEvent.contextMenu(cell);
    fireEvent.click(screen.getByRole('menuitem', { name: /Copy value/ }));
    await waitFor(() => expect(ClipboardSetText).toHaveBeenLastCalledWith('')); // display only: copy keeps the real value
    expect(gridText(null, '')).toBe('');
    expect(gridText(0, 'NULL')).toBe('0');
  });

  it('starts with NULL shown when Show NULL was left on', async () => {
    const GetTableData = vi.fn(async () => [{ ID: 1, NAME: null }]);
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetTableData, GetShowNull: vi.fn(async () => true) } } } });
    render(<App />);
    openDefault();
    expect(await screen.findByText('NULL')).toBeInTheDocument();
  });

  it('right-aligns numeric columns, header included', async () => {
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    expect(screen.getByRole('columnheader', { name: 'ID' }).className).toBe('num');
    expect(screen.getByRole('columnheader', { name: 'NAME' }).className).toBe('');
    expect(screen.getByRole('cell', { name: '2' }).className).toBe('num');
  });

  // standard item 28: every button has a menu item; the menu tree of the standard (the same in the 4 apps), the Export
  // list also under the Export... button; pt-BR with no English
  it('has the menu tree of the standard, in English and in pt-BR', async () => {
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    const tree = (button, name = button) => {
      fireEvent.click(screen.getByRole('button', { name: button }));
      const items = menuTree(screen.getByRole('menu', { name }));
      fireEvent.click(screen.getByRole('button', { name: button }));
      return items;
    };
    expect(tree('File')).toEqual(['Open... Ctrl+O', 'Open the typed path', 'Reopen F5', '--', 'Save Ctrl+S', 'Save as... Ctrl+Shift+S', 'Export ▸', '--', 'Close Ctrl+W', '--', 'Exit Ctrl+Q']);
    expect(tree('Edit')).toEqual([
      'Copy value Ctrl+C', 'Copy row Ctrl+Shift+C', 'Copy row with header', 'Copy the whole log', '--',
      'Search Ctrl+F', 'Filter by this value', 'Clear filters', '--', 'Mark or unmark row Space', 'Unmark all rows',
    ]);
    expect(tree('View')).toEqual([
      '✓Data Ctrl+1', 'Schema Ctrl+2', 'SQL Ctrl+3', 'Advanced Search Ctrl+4', '--', 'Rows ▸', 'Columns...', 'Search in ▸', 'Only marked rows',
      'Go to the table list Ctrl+T', 'Favorite or unfavorite table Ctrl+D', '--', 'Run SQL Ctrl+Enter', 'Search terms Enter', '--', 'Log Ctrl+L',
    ]);
    expect(tree('Settings')).toEqual(['Theme ▸', 'Language ▸', 'Default search scope ▸', 'Term matching ▸', 'Show NULL']);
    expect(tree('Help')).toEqual(['About mdb2sql']);
    const exportList = [
      'Current table ▸', 'Marked rows ▸', 'Current table schema ▸', 'Database schema ▸', 'All tables to CSV (one file per table)...',
      'SQL result ▸', 'All-tables search result (Excel)...', 'Advanced Search report ▸',
    ];
    expect(tree('Export...', 'Export')).toEqual(exportList);
    fireEvent.click(screen.getByRole('button', { name: 'File' }));
    fireEvent.mouseEnter(item('Export'));
    expect(menuTree(screen.getByRole('menu', { name: 'Export' }))).toEqual(exportList);
    fireEvent.mouseEnter(item('Current table'));
    expect(menuTree(screen.getByRole('menu', { name: 'Current table' }))).toEqual(['CSV...', 'Excel (.xlsx)...']);
    fireEvent.click(screen.getByRole('button', { name: 'View' }));
    fireEvent.mouseEnter(item('Rows'));
    expect(menuTree(screen.getByRole('menu', { name: 'Rows' }))).toEqual(['✓100', '500', '1000']);
    fireEvent.mouseEnter(item('Search in'));
    expect(menuTree(screen.getByRole('menu', { name: 'Search in' }))).toEqual(['This table', '✓All tables']); // standard 18a
    fireEvent.click(screen.getByRole('button', { name: 'Settings' }));
    fireEvent.mouseEnter(item('Term matching'));
    expect(menuTree(screen.getByRole('menu', { name: 'Term matching' }))).toEqual(['✓Whole value', 'Contains']);
    fireEvent.click(screen.getByRole('button', { name: 'Settings' }));
    // labels and data only: no how-to sentences, no copyright line
    fireEvent.click(screen.getByRole('tab', { name: 'Advanced Search' }));
    const shown = document.body.textContent + [...document.querySelectorAll('[title], [placeholder]')].map((e) => e.title || e.placeholder).join(' ');
    expect(shown).not.toMatch(/copyright|press |write a|verifi|lembre|open a database|export writes/i);

    pick('Settings', 'Language', 'Português (Brasil)');
    expect(tree('Arquivo')).toEqual([
      'Abrir... Ctrl+O', 'Abrir o caminho digitado', 'Reabrir F5', '--', 'Salvar Ctrl+S', 'Salvar como... Ctrl+Shift+S', 'Exportar ▸', '--',
      'Fechar Ctrl+W', '--', 'Sair Ctrl+Q',
    ]);
    expect(tree('Editar')).toEqual([
      'Copiar valor Ctrl+C', 'Copiar linha Ctrl+Shift+C', 'Copiar linha com cabeçalho', 'Copiar todo o Log', '--',
      'Pesquisar Ctrl+F', 'Filtrar por este valor', 'Limpar filtros', '--', 'Marcar ou desmarcar linha Espaço', 'Desmarcar todas as linhas',
    ]);
    expect(tree('Exibir')).toEqual([
      'Dados Ctrl+1', 'Schema Ctrl+2', 'SQL Ctrl+3', '✓Pesquisa Avançada Ctrl+4', '--', 'Linhas ▸', 'Colunas...', 'Pesquisar em ▸', 'Só as linhas marcadas',
      'Ir para a lista de tabelas Ctrl+T', 'Favoritar ou desfavoritar tabela Ctrl+D', '--', 'Executar SQL Ctrl+Enter', 'Pesquisar termos Enter', '--', 'Log Ctrl+L',
    ]);
    expect(tree('Configurações')).toEqual(['Tema ▸', 'Idioma ▸', 'Escopo padrão da busca ▸', 'Comparação dos termos ▸', 'Exibir NULL']);
    expect(tree('Ajuda')).toEqual(['Sobre o mdb2sql']);
    expect(tree('Exportar...', 'Exportar')).toEqual([
      'Tabela atual ▸', 'Linhas marcadas ▸', 'Schema da tabela atual ▸', 'Schema do banco ▸', 'Todas as tabelas em CSV (um arquivo por tabela)...',
      'Resultado do SQL ▸', 'Resultado da busca em todas as tabelas (Excel)...', 'Relatório da Pesquisa Avançada ▸',
    ]);
  });

  // owner 26/11 (13h): pages in the Data tab, as large as the Rows list; the line says which rows of how many; previous
  // and next are disabled at the ends; another search goes back to the first page
  it('pages through a table of more than 1000 rows, the last page short', async () => {
    const total = (search) => (search ? 3 : 1050);
    const GetTableData = vi.fn(async (_t, limit, _f, search, offset) =>
      Array.from({ length: Math.max(0, Math.min(limit, total(search) - offset)) }, (_, i) => ({ ID: offset + i + 1, NAME: 'n' })),
    );
    const GetRowCount = vi.fn(async (_t, _f, search) => total(search));
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetTableData, GetRowCount, GetSearchScope: vi.fn(async () => 'table') } } } });
    render(<App />);
    openDefault();
    await screen.findByText('RANGER_SOACCU: rows 1 to 100 of 1,050');
    const prev = () => screen.getByRole('button', { name: 'Previous page' });
    const next = () => screen.getByRole('button', { name: 'Next page' });
    expect(prev()).toBeDisabled();
    fireEvent.change(screen.getByRole('combobox'), { target: { value: '500' } });
    await screen.findByText('RANGER_SOACCU: rows 1 to 500 of 1,050');
    fireEvent.click(next());
    await screen.findByText('RANGER_SOACCU: rows 501 to 1,000 of 1,050');
    expect(GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 500, [], '', 500);
    fireEvent.click(next());
    await screen.findByText('RANGER_SOACCU: rows 1,001 to 1,050 of 1,050');
    expect(document.querySelectorAll('.table-container tbody tr')).toHaveLength(50);
    expect(next()).toBeDisabled();
    expect(prev()).toBeEnabled();
    fireEvent.click(prev());
    await screen.findByText('RANGER_SOACCU: rows 501 to 1,000 of 1,050');
    // a search: the first page again, the rows found
    fireEvent.change(screen.getByLabelText('Search the table'), { target: { value: 'n' } });
    fireEvent.keyDown(screen.getByLabelText('Search the table'), { key: 'Enter' });
    await screen.findByText('RANGER_SOACCU: rows 1 to 3 of 3 found');
    expect(GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 500, [], 'n', 0);
    expect(next()).toBeDisabled();
    expect(translateN('pt-BR', 'info.page', 36804, 'T', '1', '100', (36804).toLocaleString('pt-BR'))).toBe('T: linhas 1 a 100 de 36.804');
  });

  // standard item 34: favorite tables first in the table list, in alphabetical order, with a star; right-click a table
  // or View > Favorite or unfavorite table (Ctrl+D, the open table); kept by name while the program is open
  it('puts the favorite tables first in the table list, from its right-click menu and Ctrl+D', async () => {
    const LoadDatabase = vi.fn(async () => ['RANGER_SOACCU', 'RANGER_SOGEN', 'RANGER_SOSTAT']);
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, LoadDatabase } } } });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    const list = screen.getByRole('navigation', { name: 'Tables' });
    const names = () => [...list.querySelectorAll('.table-item .name')].map((el) => el.textContent);
    expect(names()).toEqual(['RANGER_SOACCU', 'RANGER_SOGEN', 'RANGER_SOSTAT']);

    fireEvent.contextMenu(within(list).getByRole('button', { name: 'RANGER_SOSTAT' }));
    fireEvent.click(item('Add to favorites'));
    expect(names()).toEqual(['★ RANGER_SOSTAT', 'RANGER_SOACCU', 'RANGER_SOGEN']);
    fireEvent.keyDown(window, { key: 'd', ctrlKey: true }); // the open table, RANGER_SOACCU
    expect(names()).toEqual(['★ RANGER_SOACCU', '★ RANGER_SOSTAT', 'RANGER_SOGEN']);
    fireEvent.change(screen.getByLabelText('Filter 3 tables'), { target: { value: 'stat' } });
    await waitFor(() => expect(names()).toEqual(['★ RANGER_SOSTAT'])); // the filter applies to the favorites too

    // another file keeps them by name; a name the file does not have is not shown
    LoadDatabase.mockImplementation(async () => ['RANGER_SOGEN', 'RANGER_SOSTAT']);
    openDefault();
    await waitFor(() => expect(names()).toEqual(['★ RANGER_SOSTAT', 'RANGER_SOGEN']));
    fireEvent.contextMenu(within(list).getByRole('button', { name: 'RANGER_SOSTAT' }));
    fireEvent.click(item('Remove from favorites'));
    pick('View', 'Favorite or unfavorite table'); // the open table, RANGER_SOGEN
    expect(names()).toEqual(['★ RANGER_SOGEN', 'RANGER_SOSTAT']);
    expect(favoritesFirst(['B', 'A', 'C', 'D'], new Set(['D', 'B', 'X']))).toEqual(['B', 'D', 'A', 'C']);
    expect(translate('pt-BR', 'fav.add')).toBe('Favoritar');
  });

  // standard item 28: File > Save and Save as... (Go asks for the file: SQLite, DuckDB or Excel), disabled with nothing
  // open, and the new exports of the list: table and database schema, all tables to CSV, SQL result, All tables search
  it('saves from File > Save and Save as... and runs the exports of the list', async () => {
    const SaveDatabase = vi.fn(async (saveAs) => (saveAs ? 'D:\\other\\db.xlsx' : 'C:\\data\\db.sqlite'));
    const ExportSchema = vi.fn(async (table, format) => `C:\\out\\${table || 'db'}_schema.${format}`);
    const ExportAllCSV = vi.fn(async () => 'C:\\out');
    const ExportQuery = vi.fn(async () => 'C:\\out\\query.csv');
    const ExportSearch = vi.fn(async () => 'C:\\out\\db_busca.xlsx');
    const SearchAllTables = vi.fn(async () => [{ table: 'RANGER_SOGEN', rows: 3 }]);
    const RunQuery = vi.fn(async () => ({ columns: ['n'], rows: [{ n: 1 }], more: false }));
    global.window = Object.assign(window, {
      go: { main: { App: { ...bridge, SaveDatabase, ExportSchema, ExportAllCSV, ExportQuery, ExportSearch, SearchAllTables, RunQuery } } },
    });
    render(<App />);
    fireEvent.click(screen.getByRole('button', { name: 'File' }));
    for (const name of ['Save', 'Save as...', 'Export', 'Close']) expect(item(name)).toBeDisabled(); // nothing open
    fireEvent.click(screen.getByRole('button', { name: 'File' }));
    openDefault();
    await screen.findByText('Alpha');
    const idle = () => waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());

    pick('File', 'Save');
    await waitFor(() => expect(SaveDatabase).toHaveBeenLastCalledWith(false));
    expect(await screen.findByText('Exported sample.duckdb to C:\\data\\db.sqlite')).toBeInTheDocument();
    pick('File', 'Save as...');
    await waitFor(() => expect(SaveDatabase).toHaveBeenLastCalledWith(true));
    await idle();

    pick('File', 'Export', 'Current table schema', 'Excel (.xlsx)...');
    await waitFor(() => expect(ExportSchema).toHaveBeenLastCalledWith('RANGER_SOACCU', 'xlsx'));
    await idle();
    pick('Export...', 'Database schema', 'CSV...');
    await waitFor(() => expect(ExportSchema).toHaveBeenLastCalledWith('', 'csv'));
    await idle();
    pick('Export...', en('export.allCsv'));
    await waitFor(() => expect(ExportAllCSV).toHaveBeenCalled());
    await idle();

    fireEvent.click(screen.getByRole('tab', { name: 'SQL' }));
    fireEvent.change(screen.getByLabelText('SQL'), { target: { value: 'select 1' } });
    pick('View', 'Run SQL');
    await waitFor(() => expect(RunQuery).toHaveBeenCalledWith('select 1', 100));
    await screen.findByText(/SQL result: 1 row/);
    pick('Export...', 'SQL result', 'CSV...');
    await waitFor(() => expect(ExportQuery).toHaveBeenCalledWith('select 1', 'csv'));
    await idle();

    // the All tables search result: Excel, one sheet per table found (Go)
    fireEvent.click(screen.getByRole('tab', { name: 'Data' }));
    fireEvent.click(screen.getByRole('radio', { name: 'All tables' }));
    fireEvent.change(screen.getByLabelText('Search the table'), { target: { value: 'gen' } });
    fireEvent.keyDown(screen.getByLabelText('Search the table'), { key: 'Enter' });
    await screen.findByRole('button', { name: 'RANGER_SOGEN (3)' });
    pick('Export...', en('export.searchAll'));
    await waitFor(() => expect(ExportSearch).toHaveBeenCalledWith('gen', ['RANGER_SOGEN']));
  });

  // standard item 31: a box per row; the marked rows stay on top of the grid, in table order, during other searches;
  // Only marked, the count under the grid, the cell menu and the export of the marked rows
  it('keeps the marked rows on top during other searches, with Only marked, the count and their export', async () => {
    const all = ['kkk', 'jjj', 'hhh', 'ggg'].map((NAME, i) => ({ [ROWID]: i + 1, ID: i + 1, NAME }));
    const GetTableData = vi.fn(async (_t, _l, _f, search) => all.filter((r) => !search || r.NAME === search));
    const GetRowCount = vi.fn(async (_t, _f, search) => (search ? 1 : all.length));
    const MarkedRows = vi.fn(async (_t, marks) => all.filter((r) => marks.some((m) => m[ROWID] === r[ROWID])));
    const ExportMarked = vi.fn(async () => 'C:\\out\\RANGER_SOACCU_marcadas.csv');
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetTableData, GetRowCount, MarkedRows, ExportMarked, GetSearchScope: vi.fn(async () => 'table') } } } });
    render(<App />);
    openDefault();
    await screen.findByText('ggg');
    const names = () => [...document.querySelectorAll('.table-container tbody tr')].map((tr) => tr.cells[2].textContent);
    const searchFor = (text) => {
      fireEvent.change(screen.getByLabelText('Search the table'), { target: { value: text } });
      fireEvent.keyDown(screen.getByLabelText('Search the table'), { key: 'Enter' });
    };
    const mark = document.querySelector('th.mark');
    expect([mark.textContent, mark.title]).toEqual(['', 'Mark rows']); // no title, a tip

    // the owner's example: search kkk, mark it (its box); search jjj, mark it (Space); search hhh, mark it (Edit menu)
    searchFor('kkk');
    await waitFor(() => expect(names()).toEqual(['kkk']));
    fireEvent.click(screen.getByRole('checkbox', { name: 'Mark rows' }));
    searchFor('jjj');
    await waitFor(() => expect(names()).toEqual(['kkk', 'jjj']));
    fireEvent.click(screen.getByText('jjj'));
    fireEvent.keyDown(screen.getByText('jjj'), { key: ' ' });
    searchFor('hhh');
    await waitFor(() => expect(names()).toEqual(['kkk', 'jjj', 'hhh']));
    fireEvent.click(screen.getByText('hhh'));
    pick('Edit', 'Mark or unmark row');
    searchFor('ggg');
    await waitFor(() => expect(names()).toEqual(['kkk', 'jjj', 'hhh', 'ggg']));
    expect(screen.getAllByRole('checkbox', { name: 'Mark rows' }).map((c) => c.checked)).toEqual([true, true, true, false]);
    const info = document.querySelector('.info');
    expect(info.textContent).toBe('Only marked' + 'RANGER_SOACCU: row 1 of 1 found, 3 marked' + '◀▶');

    // Only marked (the box under the grid and View > Only marked rows)
    fireEvent.click(screen.getByRole('checkbox', { name: 'Only marked' }));
    expect(names()).toEqual(['kkk', 'jjj', 'hhh']);
    fireEvent.click(screen.getByRole('button', { name: 'View' }));
    expect(item('Only marked rows')).toHaveAttribute('aria-checked', 'true');
    fireEvent.click(item('Only marked rows'));
    expect(names()).toEqual(['kkk', 'jjj', 'hhh', 'ggg']);

    pick('Export...', 'Marked rows', 'CSV...');
    await waitFor(() => expect(ExportMarked).toHaveBeenCalledWith('RANGER_SOACCU', 'csv', [all[0], all[1], all[2]]));
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());

    // the cell menu of Data: filters, copies, then the marks
    fireEvent.contextMenu(screen.getByText('ggg'));
    expect(menuTree(screen.getByRole('menu', { name: 'Cell' }))).toEqual([
      'Filter by this value', 'Clear filters', '--', 'Copy value Ctrl+C', 'Copy row Ctrl+Shift+C', 'Copy row with header', '--',
      'Mark or unmark row Space', 'Export marked rows ▸', 'Unmark all rows',
    ]);
    fireEvent.click(item('Unmark all rows'));
    await waitFor(() => expect(names()).toEqual(['ggg']));
    expect(screen.queryByRole('checkbox', { name: 'Only marked' })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Export...' }));
    expect(item('Marked rows')).toBeDisabled();

    // identity of a row: the engine's rowid; without one, all its values (equal rows are marked together)
    expect(rowKey({ [ROWID]: 7, A: 1 }, ['A'])).toBe('#7');
    expect(rowKey({ A: 1, B: null }, ['A', 'B'])).toBe(rowKey({ B: null, A: 1 }, ['A', 'B']));
    expect(rowKey({ A: 1, B: null }, ['A', 'B'])).not.toBe(rowKey({ A: 1, B: 2 }, ['A', 'B']));
    expect(translateN('pt-BR', 'mark.count', 1, 1)).toBe(', 1 marcada');
  });

  // standard item 32: the pasted terms (count, repeats), Whole value | Contains and This table | All tables (defaults of
  // Settings), progress, the summary, the tables found, the rows of the chosen one (its own columns, each row once:
  // standard 19d), the terms not found with Copy, the copies and the report
  it('searches the pasted terms and shows the tables found, their rows and the terms not found', async () => {
    const res = {
      terms: ['TENSAO', 'PNTNAM', 'U9A'],
      repeated: 1,
      hits: [
        { term: 'TENSAO', table: 'RANGER_SOSTAT', rows: 2 },
        { term: 'U9A', table: 'RANGER_SOGEN', rows: 1 },
        { term: 'U9A', table: 'RANGER_SOSTAT', rows: 1 },
      ],
      tables: [
        { table: 'RANGER_SOGEN', rows: 1 },
        { table: 'RANGER_SOSTAT', rows: 2 }, // row 2, found by TENSAO and U9A, once
      ],
      notFound: ['PNTNAM'],
    };
    let answer;
    const SearchTerms = vi.fn(() => new Promise((resolve) => (answer = resolve)));
    const stat = [
      { ID: 1, NAME: 'a' },
      { ID: 2, NAME: 'b' },
    ];
    const TermRows = vi.fn(async (table) => ({ columns: ['ID', 'NAME'], rows: table === 'RANGER_SOGEN' ? [{ ID: 7, NAME: 'g' }] : stat, more: false }));
    const ExportTerms = vi.fn(async () => 'C:\\out\\sample - Advanced Search.xlsx');
    const SetTermMatch = vi.fn(async () => {});
    const ClipboardSetText = vi.fn(async () => true);
    let goProgress;
    const EventsOn = vi.fn((name, cb) => {
      if (name === 'progress') goProgress = cb;
      return () => {};
    });
    global.window = Object.assign(window, {
      go: { main: { App: { ...bridge, SearchTerms, TermRows, ExportTerms, SetTermMatch, GetTermMatch: vi.fn(async () => 'contains'), GetSearchScope: vi.fn(async () => 'all') } } },
      runtime: { ClipboardSetText, EventsOn },
    });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    fireEvent.click(screen.getByRole('tab', { name: 'Advanced Search' }));
    const box = screen.getByLabelText('Advanced Search');
    // owner 26/11 (13e): the hint shows an example, one term per line
    expect(box.getAttribute('placeholder').split('\n')).toEqual([
      'Paste the terms, one per line (for example, an Excel column). Example:', 'text1', 'text2', 'text3',
      'searches the 3 terms in all tables or only in the selected table.',
    ]);
    expect(translate('pt-BR', 'terms.hint').split('\n')[4]).toBe('pesquisa os 3 termos em todas as tabelas ou só na tabela selecionada.');
    expect(screen.getByRole('radio', { name: 'Contains' })).toHaveAttribute('aria-checked', 'true'); // Settings > Term matching
    expect(screen.getByRole('radio', { name: 'All tables' })).toHaveAttribute('aria-checked', 'true'); // Default search scope
    expect(screen.getByRole('radiogroup', { name: 'Term matching' }).title).toMatch(/^Whole value: the whole cell equals the term/);
    fireEvent.change(box, { target: { value: 'TENSAO\n  pntnam \n\nU9A\ntensao' } });
    // standard 21: under the box, the input lines at the left (the 4 with text, the repeat too); at the right the
    // options, then Search at the end; the output bar waits for a result (Clear works on the text already)
    expect(document.querySelector('.terms-bar .info').textContent).toBe('4 input lines');
    const labels = (els) => els.map((el) => el.getAttribute('aria-label') ?? el.className ?? '');
    const options = [...document.querySelector('.terms-options').children];
    expect(labels(options)).toEqual(['Term matching', 'terms-sep', 'Search in', 'terms-sep', '']);
    expect(options[4].textContent).toBe('Search');
    const out = () => [...document.querySelector('.terms-out').querySelectorAll(':scope > button, :scope > .menu-root > button')];
    expect(out().map((b) => [b.textContent, b.disabled])).toEqual([['Copy rows', true], ['Save/Export...', true], ['Clear', false]]);
    expect(document.querySelector('.terms-result').textContent).toBe(''); // empty before a search
    // Ctrl+Enter starts a new line where the cursor is, Enter searches
    box.setSelectionRange(box.value.length, box.value.length);
    fireEvent.keyDown(box, { key: 'Enter', ctrlKey: true });
    expect(box).toHaveValue('TENSAO\n  pntnam \n\nU9A\ntensao\n');
    expect(SearchTerms).not.toHaveBeenCalled();
    fireEvent.keyDown(box, { key: 'Enter' });
    await waitFor(() => expect(SearchTerms).toHaveBeenCalledWith(['TENSAO', '  pntnam ', '', 'U9A', 'tensao', ''], true, ''));
    act(() => goProgress({ done: 1, total: 2, label: 'RANGER_SOGEN' }));
    expect(screen.getByText('Searching terms: table 1 of 2 (RANGER_SOGEN)')).toBeInTheDocument();
    await act(async () => answer(res));
    expect(await screen.findByText('2 of 3 terms found: 3 rows in 2 tables')).toBeInTheDocument();
    // standard 21: the three blocks; the summary is the first line of the result frame
    expect([...document.querySelector('.terms').children].map((el) => el.className)).toEqual(['terms-input', 'terms-result', 'terms-out']);
    expect(document.querySelector('.terms-result').firstElementChild.textContent).toBe('2 of 3 terms found: 3 rows in 2 tables');
    expect(out().map((b) => b.disabled)).toEqual([false, false, false]);

    // the first table found is chosen; its rows, its own columns, limited as in Data (Rows)
    await waitFor(() => expect(TermRows).toHaveBeenLastCalledWith('RANGER_SOGEN', res.terms, true, 100));
    expect(screen.getByRole('button', { name: 'RANGER_SOGEN (1)' })).toHaveAttribute('aria-current', 'true');
    fireEvent.click(screen.getByRole('button', { name: 'RANGER_SOSTAT (2)' }));
    await waitFor(() => expect(TermRows).toHaveBeenLastCalledWith('RANGER_SOSTAT', res.terms, true, 100));
    await waitFor(() => expect([...document.querySelectorAll('.terms-hits th')].map((th) => th.textContent)).toEqual(['ID', 'NAME']));
    expect(document.querySelectorAll('.terms-hits tbody tr')).toHaveLength(2);
    expect(screen.getByText('RANGER_SOSTAT: showing 2 of 2 rows')).toBeInTheDocument();

    // not found: one per line, in pasted order, with Copy
    expect(screen.getByRole('heading', { name: 'Not found (1)' })).toBeInTheDocument();
    expect(screen.getByRole('textbox', { name: 'Not found (1)' })).toHaveValue('PNTNAM');
    fireEvent.click(screen.getByRole('button', { name: 'Copy' }));
    await waitFor(() => expect(ClipboardSetText).toHaveBeenLastCalledWith('PNTNAM'));

    // the copies have the columns of the table; "Copy the rows found" copies every row found, with the header
    fireEvent.contextMenu(screen.getByText('a'));
    expect(menuTree(screen.getByRole('menu', { name: 'Cell' }))).toEqual([
      'Copy value Ctrl+C', 'Copy row Ctrl+Shift+C', 'Copy row with header', '--', 'Copy the rows found in this table', 'Advanced Search report ▸',
    ]);
    fireEvent.click(item('Copy row with header'));
    await waitFor(() => expect(ClipboardSetText).toHaveBeenLastCalledWith('ID\tNAME\r\n1\ta'));
    fireEvent.contextMenu(screen.getByText('a'));
    fireEvent.click(item('Copy the rows found in this table'));
    await waitFor(() => expect(ClipboardSetText).toHaveBeenLastCalledWith('ID\tNAME\r\n1\ta\r\n2\tb'));
    expect(TermRows).toHaveBeenLastCalledWith('RANGER_SOSTAT', res.terms, true, 0);
    expect(screen.getByRole('status').textContent).toBe('Copied 2 rows');

    // the report: cell menu and Export
    fireEvent.contextMenu(screen.getByText('a'));
    fireEvent.mouseEnter(item('Advanced Search report'));
    expect(menuTree(screen.getByRole('menu', { name: 'Advanced Search report' }))).toEqual(['Excel (.xlsx)...', 'CSV...', 'SQLite (.sqlite)...', 'DuckDB (.duckdb)...']);
    fireEvent.click(item('Excel (.xlsx)...'));
    await waitFor(() => expect(ExportTerms).toHaveBeenCalledWith(res, true, 'xlsx'));
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
    pick('Export...', 'Advanced Search report', 'DuckDB (.duckdb)...');
    await waitFor(() => expect(ExportTerms).toHaveBeenLastCalledWith(res, true, 'duckdb'));
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());

    // standard 21, the output bar: Copy rows (the rows of the chosen table, as "Copy the rows found") and
    // Save/Export... (the 4 formats of the report, as Export > Advanced Search report)
    const copies = ClipboardSetText.mock.calls.length;
    fireEvent.click(screen.getByRole('button', { name: 'Copy rows' }));
    await waitFor(() => expect(ClipboardSetText).toHaveBeenCalledTimes(copies + 1));
    expect(ClipboardSetText).toHaveBeenLastCalledWith('ID\tNAME\r\n1\ta\r\n2\tb');
    fireEvent.click(screen.getByRole('button', { name: 'Save/Export...' }));
    expect(menuTree(screen.getByRole('menu', { name: 'Advanced Search report' }))).toEqual(['Excel (.xlsx)...', 'CSV...', 'SQLite (.sqlite)...', 'DuckDB (.duckdb)...']);
    fireEvent.click(screen.getByRole('menuitem', { name: 'SQLite (.sqlite)...' }));
    await waitFor(() => expect(ExportTerms).toHaveBeenLastCalledWith(res, true, 'sqlite'));
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());

    // Settings > Term matching also applies now
    pick('Settings', 'Term matching', 'Whole value');
    expect(SetTermMatch).toHaveBeenCalledWith('whole');
    expect(screen.getByRole('radio', { name: 'Whole value' })).toHaveAttribute('aria-checked', 'true');
    // a new search: the old answer leaves at once
    fireEvent.keyDown(box, { key: 'Enter' });
    expect(screen.queryByText('2 of 3 terms found: 3 rows in 2 tables')).not.toBeInTheDocument();
    await waitFor(() => expect(SearchTerms).toHaveBeenLastCalledWith(expect.any(Array), false, ''));
    // Clear (standard 21): the terms and the result go; the answer of the search still running shows nothing
    fireEvent.click(screen.getByRole('button', { name: 'Clear' }));
    expect(box).toHaveValue('');
    await act(async () => answer(res));
    expect(document.querySelector('.terms-result').textContent).toBe('');
    expect(out().map((b) => b.disabled)).toEqual([true, true, true]);

    // terms: one per line, trimmed, empty lines dropped, a repeat (ignoring case) searched once; the right plural
    expect(parseTerms(' a \nA\n\nb\r\nB ')).toEqual({ terms: ['a', 'b'], repeated: 2 });
    // owner 26/11 (13d): the tab is the Advanced Search in the 3 languages, and so is its report
    expect(LANGS.map((l) => translate(l, 'tab.terms'))).toEqual(['Advanced Search', 'Pesquisa Avançada', 'Búsqueda Avanzada']);
    expect(translate('es', 'export.terms')).toBe('Informe de la Búsqueda Avanzada');
    const pt = (key, n, ...args) => translateN('pt-BR', key, n, ...args);
    expect(pt('terms.lines', 1, 1) + ' / ' + pt('terms.lines', 8, 8)).toBe('1 linha de entrada / 8 linhas de entrada');
    expect(translate('pt-BR', 'terms.summary', pt('terms.found', 1, 1, 1), pt('terms.rows', 1, 1), pt('terms.tables', 1, 1))).toBe('1 de 1 termo encontrado: 1 linha em 1 tabela');
    expect(translate('pt-BR', 'terms.summary', pt('terms.found', 3, 2, 3), pt('terms.rows', 8, 8), pt('terms.tables', 2, 2))).toBe('2 de 3 termos encontrados: 8 linhas em 2 tabelas');
  });

  // standard item 17: texts of Rust/Zig; with the search active a table export asks: whole table or only the rows found
  it('asks whole table or only the rows found before exporting a searched table', async () => {
    const ExportTable = vi.fn(async () => 'C:\\out\\t.csv');
    const GetRowCount = vi.fn(async (_t, _f, search) => (search ? 1 : 2));
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, ExportTable, GetRowCount, GetSearchScope: vi.fn(async () => 'table') } } } });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    const exportCsv = () => pick('Export...', 'Current table', 'CSV...');
    exportCsv(); // no search: no question
    await waitFor(() => expect(ExportTable).toHaveBeenLastCalledWith('RANGER_SOACCU', 'csv', [], ''));

    fireEvent.change(screen.getByLabelText('Search the table'), { target: { value: 'alp' } });
    fireEvent.keyDown(screen.getByLabelText('Search the table'), { key: 'Enter' });
    await screen.findByText(/row 1 of 1 found/);
    exportCsv();
    const dialog = await screen.findByRole('dialog', { name: 'Export RANGER_SOACCU' });
    expect(buttonTexts(dialog)).toEqual(['Whole table', 'Only the 1 row found', 'Cancel']);
    fireEvent.click(within(dialog).getByRole('button', { name: 'Only the 1 row found' }));
    await waitFor(() => expect(ExportTable).toHaveBeenLastCalledWith('RANGER_SOACCU', 'csv', [], 'alp'));
    exportCsv();
    fireEvent.click(await screen.findByRole('button', { name: 'Whole table' }));
    await waitFor(() => expect(ExportTable).toHaveBeenLastCalledWith('RANGER_SOACCU', 'csv', [], ''));
    expect(ExportTable).toHaveBeenCalledTimes(3);
    exportCsv();
    await screen.findByRole('dialog', { name: 'Export RANGER_SOACCU' });
    fireEvent.keyDown(window, { key: 'Escape' }); // Esc = Cancel: nothing exported
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
    expect(ExportTable).toHaveBeenCalledTimes(3);
    expect(translateN('pt-BR', 'exportAsk.found', 5, 5)).toBe('Só as 5 linhas encontradas');
    expect(translate('pt-BR', 'export.table')).toBe('Tabela atual');
  });

  it('selects a cell by focus and opens its menu from the keyboard', async () => {
    render(<App />);
    openDefault();
    const cell = await screen.findByText('Beta');
    fireEvent.focus(cell);
    expect(cell).toHaveAttribute('aria-selected', 'true');
    fireEvent.contextMenu(cell); // menu key: no mouse position
    expect(screen.getByRole('menu', { name: 'Cell' }).style.left).not.toBe('0px');
    fireEvent.click(screen.getByRole('menuitem', { name: 'Filter by this value' }));
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 100, [{ column: 'NAME', value: 'Beta' }], '', 0));
  });

  // jsdom has no layout, so the rules themselves are checked: 1.2.0 cut "RANGER_SOSTAT" to "RAN..." and the table
  // list and the Columns... list used "..." for long names
  it('never cuts a name with "...": table title, headers, table list, Columns... list', () => {
    const css = readFileSync('src/App.css', 'utf8').replace(/\r\n/g, '\n').replace(/\/\*[\s\S]*?\*\//g, '');
    const rule = (sel) => css.match(new RegExp(`(?:^|\\n)${sel.replace(/[.*]/g, '\\$&')} \\{([^}]*)\\}`))?.[1] ?? '';
    const title = rule('.content-bar h2');
    expect(title).toMatch(/flex: none/);
    expect(title).toMatch(/white-space: normal/);
    expect(rule('.content-bar')).toMatch(/flex-wrap: wrap/);
    const cells = rule('th,\ntd');
    expect(cells).toMatch(/white-space: nowrap/);
    expect(cells + rule('th')).not.toMatch(/max-width|text-overflow|overflow: hidden/);
    expect(css).not.toMatch(/text-overflow/);
    for (const sel of ['.table-item', '.col-list label span']) {
      expect(rule(sel)).toMatch(/overflow-wrap: anywhere/);
      expect(rule(sel)).not.toMatch(/nowrap|overflow: hidden/);
    }
  });

  // coordinator 26/11: the box of the terms and the one of the terms not found use the app font (Segoe UI 14 px), not
  // the monospace of a textarea, as in the Python and Zig versions
  it('writes the term boxes in the app font', () => {
    const css = readFileSync('src/App.css', 'utf8').replace(/\r\n/g, '\n').replace(/\/\*[\s\S]*?\*\//g, '');
    const rule = (sel) => css.match(new RegExp(`(?:^|\\n)${sel.replace(/[.*]/g, '\\$&')} \\{([^}]*)\\}`))?.[1] ?? '';
    expect(rule('.terms-missing textarea')).toMatch(/font: inherit;/);
    expect(rule('.terms-missing textarea')).not.toMatch(/monospace|Consolas/);
  });

  // standard 18e (owner 26/11): one font, Segoe UI 14 px, in every tab, box, grid and label: the body sets it, every
  // other rule inherits it (SQL box, Log, titles included); no monospace, no other size
  it('uses one font, Segoe UI 14 px, everywhere', () => {
    const css = readFileSync('src/App.css', 'utf8').replace(/\r\n/g, '\n').replace(/\/\*[\s\S]*?\*\//g, '');
    const fonts = [...css.matchAll(/\bfont:\s*([^;]+);/g)].map((m) => m[1]);
    expect(fonts.filter((f) => f !== 'inherit')).toEqual(["14px/1.4 'Segoe UI', system-ui, -apple-system, 'Roboto', sans-serif"]);
    expect([...new Set([...css.matchAll(/\bfont-size:\s*([^;]+);/g)].map((m) => m[1]))].sort()).toEqual(['14px', 'inherit']);
    expect(css).not.toMatch(/monospace|Consolas|font-family/);
  });

  // coordinator 26/11: the title "Not found (n)" is not bold, as in the Python and Zig versions
  it('writes the not found title not bold', () => {
    const css = readFileSync('src/App.css', 'utf8').replace(/\r\n/g, '\n').replace(/\/\*[\s\S]*?\*\//g, '');
    const rule = (sel) => css.match(new RegExp(`(?:^|\\n)${sel.replace(/[.*]/g, '\\$&')} \\{([^}]*)\\}`))?.[1] ?? '';
    expect(rule('.terms-missing h3')).toMatch(/font-weight: normal;/);
  });

  // owner 26/11 (13f): no button larger than the others to show rank: the Run button of the SQL tab keeps its height
  // (not stretched to the SQL field), the default button is not bold, Run and Search terms look as the rest
  it('makes no button larger than the others', async () => {
    const css = readFileSync('src/App.css', 'utf8').replace(/\r\n/g, '\n').replace(/\/\*[\s\S]*?\*\//g, '');
    const rule = (sel) => css.match(new RegExp(`(?:^|\\n)${sel.replace(/[.*]/g, '\\$&')} \\{([^}]*)\\}`))?.[1] ?? '';
    expect(rule('.sql-bar')).toMatch(/align-items: flex-start/);
    expect(rule('button.primary') + rule('.sized > .ghost')).not.toMatch(/font-weight|padding|font-size/);
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    fireEvent.click(screen.getByRole('tab', { name: 'SQL' }));
    expect(screen.getByRole('button', { name: 'Run' }).className).toBe('');
    fireEvent.click(screen.getByRole('tab', { name: 'Advanced Search' }));
    expect(screen.getByRole('button', { name: 'Search' }).className).toBe('');
  });

  // audit items 3 and 16: late answers of an older table, query or file must not show, and Export must not
  // keep the SQL of the previous file
  it('drops late answers and forgets the previous file', async () => {
    const later = () => {
      let resolve;
      const promise = new Promise((r) => (resolve = r));
      return { promise, resolve };
    };
    const slowTable = later();
    const slowQuery = later();
    const GetTableData = vi.fn(async (table) => (table === 'RANGER_SOGEN' && slowTable.armed ? slowTable.promise : rows));
    const RunQuery = vi.fn((q) => (q === 'slow' ? slowQuery.promise : Promise.resolve({ columns: ['n'], rows: [{ n: 'fast' }], more: false })));
    const CancelJob = vi.fn(async () => {});
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetTableData, RunQuery, CancelJob } } } });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');

    // table B answers late, after table A was chosen again: A stays
    slowTable.armed = true;
    fireEvent.click(screen.getByRole('button', { name: 'RANGER_SOGEN' }));
    fireEvent.click(screen.getByRole('button', { name: 'RANGER_SOACCU' }));
    await waitFor(() => expect(GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 100, [], '', 0));
    slowTable.resolve([{ ID: 9, NAME: 'Late' }]);
    await screen.findByText('Alpha');
    expect(screen.queryByText('Late')).not.toBeInTheDocument();

    // a slow query replaced by a fast one: Cancel while running, the late slow answer is dropped
    fireEvent.click(screen.getByRole('tab', { name: 'SQL' }));
    fireEvent.change(screen.getByLabelText('SQL'), { target: { value: 'slow' } });
    fireEvent.click(screen.getByRole('button', { name: 'Run' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Cancel' }));
    expect(CancelJob).toHaveBeenCalled();
    fireEvent.change(screen.getByLabelText('SQL'), { target: { value: 'fast' } });
    fireEvent.keyDown(screen.getByLabelText('SQL'), { key: 'Enter', ctrlKey: true });
    expect(await screen.findByText('fast')).toBeInTheDocument();
    slowQuery.resolve({ columns: ['n'], rows: [{ n: 'slow answer' }], more: false });
    await waitFor(() => expect(screen.getByRole('button', { name: 'Run' })).toBeInTheDocument());
    expect(screen.queryByText('slow answer')).not.toBeInTheDocument();

    // another file: the SQL result of the previous one can no longer be exported
    fireEvent.click(screen.getByRole('button', { name: 'Export...' }));
    expect(item('SQL result')).toBeEnabled();
    fireEvent.click(screen.getByRole('button', { name: 'Export...' }));
    openDefault();
    await waitFor(() => expect(bridge.LoadDatabase).toHaveBeenCalledTimes(2));
    await screen.findByText('Alpha');
    fireEvent.click(screen.getByRole('button', { name: 'Export...' }));
    expect(item('SQL result')).toBeDisabled();
  });

  it('describes progress by table or by row', () => {
    expect(progressText('Loading', null, en)).toBe('Loading'); // no "..." (owner's rule)
    expect(progressText('Loading', { done: 12, total: 287, label: 'RANGER_SOSTAT' }, en)).toBe('Loading RANGER_SOSTAT - 12 of 287');
    expect(progressText('Exporting', { done: 5000, total: 0, label: 'Result' }, en)).toBe('Exporting Result - 5000');
  });

  it('formats a row as TAB-separated text that pastes right in Excel', () => {
    const row = { ID: 7, NAME: 'a\tb', NOTE: 'line1\nline2', Q: 'say "hi"', N: null };
    const cols = ['ID', 'NAME', 'NOTE', 'Q', 'N'];
    expect(tsvField('plain text')).toBe('plain text');
    expect(rowToTsv(cols, row, false)).toBe('7\t"a\tb"\t"line1\nline2"\t"say ""hi"""\t');
    expect(rowToTsv(['ID', 'N'], row, true)).toBe('ID\tN\r\n7\t');
    expect(rowToTsv(['A\tB'], { 'A\tB': 1 }, true)).toBe('"A\tB"\r\n1');
  });

  it('searches every column, ignoring case', () => {
    expect(searchRows(rows, ['ID', 'NAME'], ' BET ')).toEqual([rows[1]]);
    expect(searchRows(rows, ['ID', 'NAME'], '1')).toEqual([rows[0]]);
    expect(searchRows(rows, ['ID', 'NAME'], '')).toBe(rows);
  });

  it('finds rows with one cell holding every word, in any order, ignoring accents', () => {
    const pts = [
      { ID: 1, PNTNAM: 'EXCITAÇÃO TENSÃO DE CAMPO', SUB: 'U9A' },
      { ID: 2, PNTNAM: 'TENSÃO BARRA', SUB: 'CAMPO NOVO' },
      { ID: 3, PNTNAM: 'Excitação', SUB: 'Peña' },
      { ID: 4, PNTNAM: 'TENSÃO DE LINHA', SUB: 'U18A' },
    ];
    const cols = ['ID', 'PNTNAM', 'SUB'];
    const ids = (q) => searchRows(pts, cols, q).map((r) => r.ID);
    expect(ids('tensao de campo')).toEqual([1]);
    expect(ids('campo tensao')).toEqual([1]); // row 2 has the words only in two different cells: no match
    expect(ids('barra tensao')).toEqual([2]);
    expect(ids('EXCITAÇÃO TENSÃO DE CAMPO')).toEqual([1]); // the exact phrase still matches
    expect(ids('tensao de campo u18a')).toEqual([]); // one missing word excludes the row
    expect(ids('EXCITACAO')).toEqual([1, 3]);
    expect(ids('pena')).toEqual([3]);
    expect(searchRows(pts, cols, '   ')).toBe(pts);
  });

  it('filters the table list with the same word rule', async () => {
    global.window = Object.assign(window, {
      go: { main: { App: { ...bridge, LoadDatabase: vi.fn(async () => ['RANGER_SOACCU', 'RANGER_SOGEN', 'TENSÃO_CAMPO']) } } },
    });
    render(<App />);
    openDefault();
    await screen.findByText('Alpha');
    // applied after a 300 ms pause in typing, like the Data search
    fireEvent.change(screen.getByLabelText('Filter 3 tables'), { target: { value: 'gen ranger' } });
    expect(screen.getByRole('button', { name: 'RANGER_SOACCU' })).toBeInTheDocument();
    await waitFor(() => expect(screen.queryByRole('button', { name: 'RANGER_SOACCU' })).not.toBeInTheDocument());
    expect(screen.getByRole('button', { name: 'RANGER_SOGEN' })).toBeInTheDocument();
    // Enter applies it at once
    fireEvent.change(screen.getByLabelText('Filter 3 tables'), { target: { value: 'campo tensao' } });
    fireEvent.keyDown(screen.getByLabelText('Filter 3 tables'), { key: 'Enter' });
    expect(screen.getByRole('button', { name: 'TENSÃO_CAMPO' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'RANGER_SOGEN' })).not.toBeInTheDocument();
  });

  it('copies the selected value and row from the context menu and Ctrl+C, and searches a SQL result', async () => {
    const ClipboardSetText = vi.fn(async () => true);
    const RunQuery = vi.fn(async () => ({ columns: ['ID', 'NAME'], rows, more: false }));
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, RunQuery } } }, runtime: { ClipboardSetText } });
    render(<App />);
    openDefault();

    fireEvent.contextMenu(await screen.findByText('Beta'));
    fireEvent.click(screen.getByRole('menuitem', { name: /Copy value/ }));
    await waitFor(() => expect(ClipboardSetText).toHaveBeenLastCalledWith('Beta'));
    fireEvent.contextMenu(screen.getByText('Beta'));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Copy row with header' }));
    await waitFor(() => expect(ClipboardSetText).toHaveBeenLastCalledWith('ID\tNAME\r\n2\tBeta'));
    fireEvent.contextMenu(screen.getByText('Beta'));
    fireEvent.click(item('Copy row'));
    await waitFor(() => expect(ClipboardSetText).toHaveBeenLastCalledWith('2\tBeta'));

    fireEvent.click(screen.getByText('Alpha'));
    fireEvent.keyDown(screen.getByText('Alpha'), { key: 'c', ctrlKey: true });
    await waitFor(() => expect(ClipboardSetText).toHaveBeenLastCalledWith('Alpha'));

    // the SQL tab searches its loaded result here (the Data tab asks the database)
    fireEvent.click(screen.getByRole('tab', { name: 'SQL' }));
    fireEvent.change(screen.getByLabelText('SQL'), { target: { value: 'select * from t' } });
    fireEvent.click(screen.getByRole('button', { name: 'Run' }));
    await screen.findByText('Beta');
    fireEvent.change(screen.getByLabelText('Search the result'), { target: { value: 'alp' } });
    expect(screen.queryByText('Beta')).not.toBeInTheDocument();
    expect(screen.getByText(/ - 1 matches "alp"/)).toBeInTheDocument();
  });

  it('shows the Linux display warning at start: 3 short lines, Copy for the command, Help link, and the log', async () => {
    const help = 'https://github.com/mauriciomenon/mdb2sql/blob/master/go_wails_react/README.md#linux-x11-e-wayland';
    const w = { text: 'X11 unavailable; using Wayland.', missing: 'X server not set (DISPLAY)', distro: 'Debian GNU/Linux 13 (trixie)', command: 'sudo apt install xwayland', help };
    const DisplayWarning = vi.fn(async () => w);
    const ClipboardSetText = vi.fn(async () => true);
    const BrowserOpenURL = vi.fn();
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, DisplayWarning } } }, runtime: { ClipboardSetText, BrowserOpenURL } });
    render(<App />);
    const dialog = await screen.findByRole('alertdialog', { name: 'Display mode' });
    expect(dialog.textContent).toContain('X11 unavailable; using Wayland.');
    expect(dialog.textContent).toContain('Debian GNU/Linux 13 (trixie): sudo apt install xwayland');
    expect(dialog.textContent).not.toContain('http'); // the link is a word, not a raw URL
    fireEvent.click(screen.getByRole('button', { name: 'Copy' }));
    await waitFor(() => expect(ClipboardSetText).toHaveBeenLastCalledWith('sudo apt install xwayland'));
    expect(fireEvent.click(screen.getByRole('link', { name: 'Help' }))).toBe(false);
    expect(BrowserOpenURL).toHaveBeenCalledWith(help);
    fireEvent.click(screen.getByRole('button', { name: 'OK' }));
    expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'View' }));
    fireEvent.click(screen.getByRole('menuitemcheckbox', { name: /Log/ }));
    expect(screen.getByRole('textbox', { name: 'Log' }).value).toContain('X11 unavailable; using Wayland. X server not set (DISPLAY)');
  });

  it('handles IPC unavailable gracefully', async () => {
    global.window = Object.assign(window, { go: undefined });
    render(<App />);
    menu('File', OPEN_DIALOG);
    expect(await screen.findByText(/IPC bridge not available/i)).toBeInTheDocument();
  });
});

// one catalog per language with the same keys; every text of the screen comes from them
describe('language catalogs', () => {
  // owner 26/11 (13g): the Log is called Log in the 3 languages; in Spanish its copy is "Copiar todo el log"
  it('call the Log Log in the 3 languages', () => {
    expect(LANGS.map((l) => translate(l, 'log.title'))).toEqual(['Log', 'Log', 'Log']);
    expect(translate('es', 'menu.copyLog')).toBe('Copiar todo el log');
  });

  const source = readFileSync('src/App.tsx', 'utf8');

  it('have the same keys in the three languages, none empty', () => {
    const keys = Object.keys(CATALOGS.en).sort();
    for (const l of LANGS) {
      expect(Object.keys(CATALOGS[l]).sort()).toEqual(keys);
      expect(Object.entries(CATALOGS[l]).filter(([, v]) => !v.trim())).toEqual([]);
    }
  });

  // standard item 23: the right plural, "1 tabela" / "2 tabelas"
  it('use the singular for a count of one', () => {
    const pt = (key, n, ...args) => translateN('pt-BR', key, n, ...args);
    expect(pt('sidebar.filter', 1, 1)).toBe('Filtrar 1 tabela');
    expect(pt('sidebar.filter', 3, 3)).toBe('Filtrar 3 tabelas');
    expect(pt('info.found', 1, 'T', 1, 1)).toBe('T: mostrando 1 de 1 linha encontrada');
    expect(pt('info.found', 3, 'T', 3, 3)).toBe('T: mostrando 3 de 3 linhas encontradas');
    expect(pt('info.showing', 2, 'T', 2, 2)).toBe('T: mostrando 2 de 2 linhas');
    expect(pt('info.sql', 1, 1)).toBe('Resultado SQL: 1 linha');
    expect(pt('info.searchAll', 1, 1, 'x')).toBe('1 tabela com linhas que contêm "x"');
    expect(pt('log.unread', 1, 1)).toBe('1 erro ou aviso não lido');
    // a .one text always has its plural key
    expect(Object.keys(CATALOGS.en).filter((k) => k.endsWith('.one') && !(k.slice(0, -4) in CATALOGS.en))).toEqual([]);
  });

  it('hold every key the screen uses', () => {
    const used = [...source.matchAll(/\btn?\(\s*'([^']+)'/g)].map((m) => m[1]);
    used.push(...['system', 'light', 'dark'].map((th) => `theme.${th}`), ...LANGS.map((l) => `lang.${l}`), 'scope.table', 'scope.all', 'tab.data', 'tab.schema', 'tab.sql', 'tab.terms', 'btn.back', 'terms.whole', 'terms.contains', ...['csv', 'xlsx', 'sqlite', 'duckdb'].map((f) => `export.${f}`));
    expect(used.length).toBeGreaterThan(80);
    expect(used.filter((k) => !(k in CATALOGS.en))).toEqual([]);
  });

  // shortcut: a text check of the JSX (no parser); it catches literal words between tags and in title,
  // placeholder and aria-label; key names (Ctrl+C), symbols and data (mdb2sql, GitHub links) are allowed
  it('leave no literal UI text in App.tsx', () => {
    const jsx = source.replace(/\r\n/g, '\n');
    const allowed = new Set(['mdb2sql', 'Ctrl+C', 'Ctrl+Enter', 'Ctrl+O', 'Ctrl+Q', 'Enter']); // key names, never translated
    const word = /[A-Za-zÀ-ÖØ-öø-ÿ]/;
    // text right after an opening or closing tag, on the same line
    const between = [...jsx.matchAll(/<\/?[a-zA-Z][^<>]*>([^<>{}\n]+)</g)].map((m) => m[1].trim()).filter((s) => word.test(s));
    const attrs = [...jsx.matchAll(/\b(?:title|placeholder|aria-label)="([^"]*)"/g)].map((m) => m[1]).filter((s) => word.test(s));
    // a line that is only words (JSX text on its own line); a lone identifier is code (`grid`, `value`)
    const lines = jsx
      .split('\n')
      .map((l) => l.trim())
      .filter((l) => /^[A-Za-zÀ-ÖØ-öø-ÿ][\w\s.,!?'À-ÖØ-öø-ÿ-]*$/.test(l) && !/^[A-Za-z_]\w*$/.test(l));
    expect([...between, ...attrs, ...lines].filter((s) => !allowed.has(s))).toEqual([]);
  });
});
