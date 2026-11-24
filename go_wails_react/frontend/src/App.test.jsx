import React from 'react';
import { readFileSync } from 'node:fs';
import { act, render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { vi, beforeEach } from 'vitest';
import App, { aboutRows, clampLogHeight, columnCellWidth, filterLabel, gridText, LOG_MIN, logLine, progressText, rowToTsv, searchRows, statusLine, tsvField, withFilter } from './App.tsx';
import { CATALOGS, LANGS, translate } from './i18n';

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

    menu('File', 'Open database...');

    await waitFor(() => expect(bridge.LoadDatabase).toHaveBeenCalled());
    expect(screen.getByText(/Loaded:/i)).toBeInTheDocument();

    // Should list tables and allow selection
    const tableItem = screen.getAllByText('RANGER_SOACCU')[0];
    expect(tableItem).toBeInTheDocument();
    fireEvent.click(tableItem);

    await waitFor(() => expect(bridge.GetTableData).toHaveBeenCalledWith('RANGER_SOACCU', 100, [], ''));
    expect(screen.getByText('Alpha')).toBeInTheDocument();
    expect(screen.getByText(/showing 2 of 2 rows/i)).toBeInTheDocument();
  });

  it('opens the file picked in the native dialog and shows its schema', async () => {
    const SelectDatabase = vi.fn(async () => 'C:\\data\\real.duckdb');
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SelectDatabase } } } });
    render(<App />);

    menu('File', 'Open database...');

    await waitFor(() => expect(bridge.LoadDatabase).toHaveBeenCalledWith('C:\\data\\real.duckdb'));
    expect(await screen.findByText(/Loaded: real\.duckdb \(2 tables\)/)).toBeInTheDocument();

    fireEvent.click(await screen.findByRole('tab', { name: /Schema \(2\)/ }));
    expect(screen.getByText('INTEGER')).toBeInTheDocument();
    // titles from the catalog (never a value or "null"); the nullability values as Go sends them
    const schemaTable = screen.getByRole('columnheader', { name: 'Nullable' }).closest('table');
    expect([...schemaTable.querySelectorAll('th')].map((th) => th.textContent)).toEqual(['Column', 'Type', 'Nullable']);
    expect([...schemaTable.querySelectorAll('tbody tr')].map((tr) => tr.lastChild.textContent)).toEqual(['NO', 'YES']);
    expect(schemaTable.className).toBe('schema'); // wider cell padding than the data grid (App.css)
  });

  it('does nothing when the dialog is cancelled', async () => {
    const SelectDatabase = vi.fn(async () => '');
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SelectDatabase } } } });
    render(<App />);

    menu('File', 'Open database...');

    await waitFor(() => expect(SelectDatabase).toHaveBeenCalled());
    expect(bridge.LoadDatabase).not.toHaveBeenCalled();
    expect(screen.getByText('No database loaded')).toBeInTheDocument();
  });

  it('shows the real file name when the default database is loaded', async () => {
    const DatabaseName = vi.fn(async () => 'DB4.duckdb');
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, DatabaseName } } } });
    render(<App />);

    menu('File', 'Open sample data');

    expect(await screen.findByText(/Loaded: DB4\.duckdb \(2 tables\)/)).toBeInTheDocument();
    expect(bridge.LoadDatabase).toHaveBeenCalledWith('');
  });

  it('shows Help > About with version, build, full stack and the two links opened in the browser', async () => {
    const GetAppInfo = vi.fn(async () => ({
      version: '1.3.0', build: '412', buildDate: '2026-11-17', go: '1.26.10', wails: 'v2.13.0', duckdb: 'v2.0.0', access: 'Access ODBC',
    }));
    const BrowserOpenURL = vi.fn();
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetAppInfo } } }, runtime: { BrowserOpenURL } });
    render(<App />);

    fireEvent.click(screen.getByRole('button', { name: 'Help' }));
    fireEvent.click(screen.getByRole('menuitem', { name: 'About' }));

    const dialog = await screen.findByRole('dialog', { name: 'mdb2sql 1.3.0' });
    // Access first, SQLite second, DuckDB last
    expect(dialog.querySelector('.tagline').textContent).toMatch(/Microsoft Access, SQLite and DuckDB/);
    const rowsShown = [...dialog.querySelectorAll('dl > div')].map((el) => [el.querySelector('dt').textContent, el.querySelector('dd').textContent]);
    expect(rowsShown).toEqual([
      ['Build', '412 (2026-11-17)'],
      ['Stack', `Go 1.26.10 + Wails 2.13.0 + React ${React.version}`],
      ['Engine', 'DuckDB 2.0.0'],
      ['Access reader', 'Access ODBC driver (Windows); embedded mdbtools as fallback'],
      ['Author', 'Mauricio Menon'],
      ['License', 'GPL v2 or later'],
      ['GitHub', 'https://github.com/mauriciomenon/mdb2sql'],
      ['GitLab', 'https://gitlab.com/mauricio.menon/mdb2sql'],
    ]);

    // the links open in the default browser, never inside the app's own webview
    for (const url of ['https://github.com/mauriciomenon/mdb2sql', 'https://gitlab.com/mauricio.menon/mdb2sql']) {
      const link = screen.getByRole('link', { name: url });
      expect(link).toHaveAttribute('href', url);
      expect(fireEvent.click(link)).toBe(false); // default navigation prevented
      expect(BrowserOpenURL).toHaveBeenLastCalledWith(url);
    }
    expect(BrowserOpenURL).toHaveBeenCalledTimes(2);

    fireEvent.click(screen.getByRole('button', { name: 'Close' }));
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    const pt = (key, ...args) => translate('pt-BR', key, ...args);
    const dev = Object.fromEntries(aboutRows({ version: '1.3.0', go: '1', wails: '2', duckdb: '3', access: 'mdbtools' }, pt));
    expect(dev.Build).toBe('dev');
    expect(dev['Leitor Access']).toBe('mdbtools embutido');
    expect(dev['Licença']).toBe('GPL v2 ou posterior');
  });

  it('hides several columns at once from Columns... and from the header menu', async () => {
    render(<App />);
    menu('File', 'Open sample data');
    await screen.findByText('Alpha');
    const header = (name) => screen.queryByRole('columnheader', { name });

    expect(screen.getByRole('button', { name: 'Columns...' }).title).toBe('Search and export use every column');
    fireEvent.click(screen.getByRole('button', { name: 'Columns...' }));
    const dialog = screen.getByRole('dialog', { name: 'Columns of RANGER_SOACCU' });
    fireEvent.click(screen.getByRole('checkbox', { name: 'NAME' }));
    expect(header('NAME')).not.toBeInTheDocument();
    expect(screen.queryByText('Alpha')).not.toBeInTheDocument();
    expect(screen.getByText('1 hidden column')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Hide all' }));
    expect(screen.getByText('2 hidden columns')).toBeInTheDocument();
    expect(header('ID')).not.toBeInTheDocument();
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
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOGEN', 100, [], ''));
    await waitFor(() => expect(header('NAME')).toBeInTheDocument());
  });

  it('resizes a Data column by its header edge; Size column to fit and Size all columns to fit undo it', async () => {
    render(<App />);
    menu('File', 'Open sample data');
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
    expect(items).toEqual(['Size column to fit', 'Size all columns to fit', 'Hide this column', 'Columns...', '✓ID', '✓NAME', 'Show all columns']);
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
    menu('File', 'Open sample data');
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
    fireEvent.click(screen.getByRole('button', { name: 'Show all' })); // ID is visible already; NAME stays hidden
    expect(screen.getByText('1 of 2 visible')).toBeInTheDocument();
    expect(document.querySelector('.col-list').style.getPropertyValue('--col-w')).toBe('150px');

    expect(columnCellWidth(['ID', 'NAME'])).toBe(150); // short names: the 150 px floor (about 4 per row at 1280x800)
    expect(columnCellWidth(['X'.repeat(30)])).toBe(30 * 8 + 44);
    expect(columnCellWidth([])).toBe(150);
  });

  it('searches the whole table in the database (Data tab), after a pause in typing', async () => {
    const GetRowCount = vi.fn(async (_t, _f, search) => (search ? 1 : 2));
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetRowCount } } } });
    render(<App />);
    menu('File', 'Open sample data');
    await screen.findByText('Alpha');
    fireEvent.change(screen.getByLabelText('Search the table'), { target: { value: 'tension de campo' } });
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 100, [], 'tension de campo'), { timeout: 2000 });
    expect(GetRowCount).toHaveBeenCalledWith('RANGER_SOACCU', [], 'tension de campo');
    expect(await screen.findByText(/showing 2 of 1 rows matching \(2 in the table\)/)).toBeInTheDocument();
    // the search stays when another table is chosen
    fireEvent.click(screen.getByRole('button', { name: 'RANGER_SOGEN' }));
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOGEN', 100, [], 'tension de campo'));
    // Enter searches at once, without the pause
    fireEvent.change(screen.getByLabelText('Search the table'), { target: { value: 'u9a' } });
    expect(bridge.GetTableData).not.toHaveBeenLastCalledWith('RANGER_SOGEN', 100, [], 'u9a');
    fireEvent.keyDown(screen.getByLabelText('Search the table'), { key: 'Enter' });
    expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOGEN', 100, [], 'u9a');
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
    menu('File', 'Open sample data');
    await screen.findByText('Alpha');
    const scope = screen.getByRole('radiogroup', { name: 'Search in' });
    expect(within(scope).getAllByRole('radio').map((r) => r.textContent)).toEqual(['This table', 'All tables']);
    expect(within(scope).getByRole('radio', { name: 'This table' })).toHaveAttribute('aria-checked', 'true');
    expect(screen.queryByRole('checkbox')).not.toBeInTheDocument();

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
    const hit = await screen.findByRole('row', { name: 'RANGER_SOGEN 3' });
    expect(screen.getByRole('columnheader', { name: 'Rows found' })).toBeInTheDocument();
    expect(screen.getByText('1 tables with rows matching "tensao"')).toBeInTheDocument();
    expect(bridge.GetTableData).not.toHaveBeenCalledWith('RANGER_SOACCU', 100, [], 'tensao'); // the grid is not queried

    fireEvent.click(within(hit).getByRole('button', { name: 'RANGER_SOGEN' }));
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOGEN', 100, [], 'tensao'));
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
    menu('File', 'Open sample data');
    await screen.findByText('Alpha');
    expect(screen.getByRole('radio', { name: 'All tables' })).toHaveAttribute('aria-checked', 'true');
    fireEvent.click(screen.getByRole('button', { name: 'Settings' }));
    expect(screen.getByText('Default search scope')).toBeInTheDocument();
    expect(screen.getByRole('menuitemradio', { name: /All tables/ })).toHaveAttribute('aria-checked', 'true');
    fireEvent.click(screen.getByRole('menuitemradio', { name: /This table/ }));
    expect(SetSearchScope).toHaveBeenCalledWith('table');
    expect(screen.getByRole('radio', { name: 'This table' })).toHaveAttribute('aria-checked', 'true');
    // the selector beside the search does not change the saved default
    fireEvent.click(screen.getByRole('radio', { name: 'All tables' }));
    expect(SetSearchScope).toHaveBeenCalledTimes(1);
  });

  it('filters by the right-clicked value in the database query and shows removable chips', async () => {
    const GetRowCount = vi.fn(async (_table, filters) => (filters.length ? 1 : 2));
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetRowCount } } } });
    render(<App />);
    menu('File', 'Open sample data');

    fireEvent.contextMenu(await screen.findByText('Beta'));
    expect(screen.getByRole('menuitem', { name: 'Clear filters' })).toBeDisabled();
    fireEvent.click(screen.getByRole('menuitem', { name: 'Filter by this value' }));
    const byName = { column: 'NAME', value: 'Beta' };
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 100, [byName], ''));
    expect(GetRowCount).toHaveBeenCalledWith('RANGER_SOACCU', [byName], '');
    expect(await screen.findByText("Filter: NAME = 'Beta'")).toBeInTheDocument();
    expect(await screen.findByText(/showing 2 of 1 rows matching \(2 in the table\)/)).toBeInTheDocument();

    // a second column is ANDed; the row limit keeps the filters
    fireEvent.contextMenu(screen.getByRole('cell', { name: '2' }));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Filter by this value' }));
    const byId = { column: 'ID', value: 2 };
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 100, [byName, byId], ''));
    expect(await screen.findByText('Filter: ID = 2')).toBeInTheDocument();
    fireEvent.change(screen.getByRole('combobox'), { target: { value: '500' } });
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 500, [byName, byId], ''));

    fireEvent.click(screen.getByRole('button', { name: 'Remove filter NAME' }));
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 500, [byId], ''));
    await waitFor(() => expect(screen.queryByText("Filter: NAME = 'Beta'")).not.toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: 'Clear filters' }));
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 500, [], ''));
    await waitFor(() => expect(screen.queryByRole('group', { name: 'Active filters' })).not.toBeInTheDocument());

    // changing table clears the filters
    fireEvent.contextMenu(screen.getByText('Beta'));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Filter by this value' }));
    await screen.findByText("Filter: NAME = 'Beta'");
    fireEvent.click(screen.getByRole('button', { name: 'RANGER_SOGEN' }));
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOGEN', 500, [], ''));
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

  // the SQLite converted from Access: asked once before another file, Close or Exit; Cancel keeps everything
  it('asks to save or delete the converted SQLite before opening another file, closing or quitting', async () => {
    let pending = '';
    let remembered = '';
    const LoadDatabase = vi.fn(async () => {
      pending = 'DB4.sqlite'; // as if each file opened were an Access file
      return tables;
    });
    const PendingConversion = vi.fn(async () => pending);
    const RememberedChoice = vi.fn(async () => remembered);
    const ResolveConversion = vi.fn(async (choice, remember) => {
      pending = '';
      if (remember) remembered = choice;
      return { done: true, saved: choice === 'save' ? 'C:\\data\\DB4.sqlite' : '' };
    });
    const CloseDatabase = vi.fn(async () => {});
    const Quit = vi.fn();
    global.window = Object.assign(window, {
      go: { main: { App: { ...bridge, LoadDatabase, PendingConversion, RememberedChoice, ResolveConversion, CloseDatabase } } },
      runtime: { Quit },
    });
    render(<App />);
    menu('File', 'Open sample data');
    await screen.findByText('Alpha');
    expect(LoadDatabase).toHaveBeenCalledTimes(1);

    // Cancel: nothing changes, nothing is loaded
    menu('File', 'Open sample data');
    const dialog = await screen.findByRole('dialog', { name: 'Converted SQLite file' });
    expect(dialog.textContent).toMatch(/DB4\.sqlite/);
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
    expect(ResolveConversion).not.toHaveBeenCalled();
    expect(LoadDatabase).toHaveBeenCalledTimes(1);
    expect(screen.getByText('Alpha')).toBeInTheDocument();

    // Delete + remember: resolved once, then the other file opens
    menu('File', 'Open sample data');
    await screen.findByRole('dialog', { name: 'Converted SQLite file' });
    fireEvent.click(screen.getByRole('checkbox', { name: 'Remember for this session' }));
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }));
    await waitFor(() => expect(ResolveConversion).toHaveBeenCalledWith('delete', true));
    await waitFor(() => expect(LoadDatabase).toHaveBeenCalledTimes(2));
    await screen.findByText('Alpha');

    // remembered for the session: Exit does not ask again
    menu('File', 'Exit');
    await waitFor(() => expect(Quit).toHaveBeenCalled());
    expect(ResolveConversion).toHaveBeenLastCalledWith('delete', false);
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();

    // Close database: the remembered choice again, then the file closes
    menu('File', 'Open sample data');
    await screen.findByText('Alpha');
    menu('File', 'Close database');
    await waitFor(() => expect(ResolveConversion).toHaveBeenCalledTimes(3));
    await waitFor(() => expect(CloseDatabase).toHaveBeenCalled());
    expect(await screen.findByText(en('empty.formats'))).toBeInTheDocument();
  });

  // owner got stuck in the exit prompt: Esc and the x always close it (no quit), Enter is Save (focused), and a
  // Save whose file dialog is cancelled asks again, where Esc still works
  it('never traps the user in the save/delete prompt on exit', async () => {
    let pending = '';
    const LoadDatabase = vi.fn(async () => {
      pending = 'DB4.sqlite';
      return tables;
    });
    const ResolveConversion = vi.fn(async () => ({ done: false, saved: '' })); // the file dialog was cancelled
    const Quit = vi.fn();
    global.window = Object.assign(window, {
      go: { main: { App: { ...bridge, LoadDatabase, PendingConversion: vi.fn(async () => pending), RememberedChoice: vi.fn(async () => ''), ResolveConversion } } },
      runtime: { Quit },
    });
    render(<App />);
    menu('File', 'Open sample data');
    await screen.findByText('Alpha');

    menu('File', 'Exit');
    await screen.findByRole('dialog', { name: 'Converted SQLite file' });
    expect(screen.getByRole('button', { name: 'Save...' })).toHaveFocus(); // Enter = Save
    fireEvent.keyDown(window, { key: 'Escape' });
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
    expect(Quit).not.toHaveBeenCalled();

    menu('File', 'Exit');
    await screen.findByRole('dialog', { name: 'Converted SQLite file' });
    fireEvent.click(screen.getByRole('button', { name: 'Close' })); // the dialog's x
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());

    menu('File', 'Exit');
    await screen.findByRole('dialog', { name: 'Converted SQLite file' });
    fireEvent.click(screen.getByRole('button', { name: 'Save...' }));
    await waitFor(() => expect(ResolveConversion).toHaveBeenCalledWith('save', false));
    expect(await screen.findByRole('dialog', { name: 'Converted SQLite file' })).toBeInTheDocument(); // asked again
    fireEvent.keyDown(window, { key: 'Escape' });
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
    expect(Quit).not.toHaveBeenCalled();
    expect(screen.getByText('Alpha')).toBeInTheDocument(); // the file stays open
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
    fireEvent.click(screen.getByRole('menuitem', { name: 'About' }));
    await screen.findByRole('dialog', { name: /mdb2sql/ });
    expect(screen.getByRole('button', { name: 'Close' })).toHaveFocus();
    fireEvent.keyDown(window, { key: 'Escape' });
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());

    menu('File', 'Open sample data');
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
    expect(await screen.findByText('Carregado: DB4.sqlite (2 tabelas)')).toBeInTheDocument();
  });

  it('switches the language from Settings > Language without restarting and saves it', async () => {
    const SetLanguage = vi.fn(async () => {});
    const GetLanguage = vi.fn(async () => 'es');
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SetLanguage, GetLanguage } } } });
    render(<App />);
    expect(await screen.findByRole('button', { name: 'Archivo' })).toBeInTheDocument(); // saved language
    expect(screen.getByText('Ninguna base de datos cargada')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Configuración' }));
    fireEvent.click(screen.getByRole('menuitemradio', { name: /Português/ }));
    expect(SetLanguage).toHaveBeenCalledWith('pt-BR');
    expect(screen.getByRole('button', { name: 'Arquivo' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Exibir' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Configurações' }));
    fireEvent.click(screen.getByRole('menuitemradio', { name: /English/ }));
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
    menu('File', 'Open sample data');
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

  // owner's "Painel de Log": collapsed by default and remembered; arrow, View > Log and Ctrl+L; collapsed, the status
  // bar shows the last unread error (then warning) with a counter, and a click on it expands the log
  it('collapses and expands the log, remembers it, and shows the last unread error in the status bar', async () => {
    const SetLogOpen = vi.fn(async () => {});
    const RunQuery = vi.fn(async () => {
      throw new Error(ENGINE_ERROR);
    });
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SetLogOpen, RunQuery, GetLogOpen: vi.fn(async () => false) } } } });
    render(<App />);
    expect(screen.queryByRole('textbox', { name: 'Log' })).not.toBeInTheDocument(); // collapsed by default
    menu('File', 'Open sample data');
    await screen.findByText('Alpha');
    fireEvent.click(screen.getByRole('tab', { name: 'SQL' }));
    fireEvent.click(screen.getByRole('button', { name: 'Run' }));
    await waitFor(() => expect(screen.getByRole('status').className).toContain('error'));
    // one translated line in the status bar; the engine's full text (LINE 1, caret) only in the log
    expect(screen.getByRole('status').textContent).toBe('SQL query error: syntax error at or near "selec"');
    expect(screen.getByTitle('1 unread errors or warnings').textContent).toBe('1');

    // a later action does not hide the unread error while the log is collapsed
    fireEvent.click(screen.getByRole('tab', { name: 'Data' }));
    expect(screen.getByRole('status').textContent).toMatch(/syntax error/);

    fireEvent.click(screen.getByRole('status')); // click: expands, the error counts as read
    expect(screen.getByRole('textbox', { name: 'Log' }).value).toContain(ENGINE_ERROR);
    expect(SetLogOpen).toHaveBeenLastCalledWith(true);
    expect(screen.queryByTitle(/unread/)).not.toBeInTheDocument();
    expect(screen.getByRole('textbox', { name: 'Log' }).style.height).toMatch(/px$/);

    fireEvent.keyDown(window, { key: 'l', ctrlKey: true }); // Ctrl+L collapses
    expect(screen.queryByRole('textbox', { name: 'Log' })).not.toBeInTheDocument();
    expect(SetLogOpen).toHaveBeenLastCalledWith(false);
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

  it('opens with the log expanded when it was left expanded', async () => {
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetLogOpen: vi.fn(async () => true) } } } });
    render(<App />);
    expect(await screen.findByRole('textbox', { name: 'Log' })).toBeInTheDocument();
  });

  it('leaves NULL cells empty by default; Settings > Show NULL shows NULL and saves the choice', async () => {
    const SetShowNull = vi.fn(async () => {});
    const ClipboardSetText = vi.fn(async () => true);
    const GetTableData = vi.fn(async () => [{ ID: 1, NAME: null }]);
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetTableData, SetShowNull } } }, runtime: { ClipboardSetText } });
    render(<App />);
    menu('File', 'Open sample data');
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
    menu('File', 'Open sample data');
    expect(await screen.findByText('NULL')).toBeInTheDocument();
  });

  it('right-aligns numeric columns, header included', async () => {
    render(<App />);
    menu('File', 'Open sample data');
    await screen.findByText('Alpha');
    expect(screen.getByRole('columnheader', { name: 'ID' }).className).toBe('num');
    expect(screen.getByRole('columnheader', { name: 'NAME' }).className).toBe('');
    expect(screen.getByRole('cell', { name: '2' }).className).toBe('num');
  });

  it('exports from the Export menu and runs SQL', async () => {
    const ExportDatabase = vi.fn(async () => 'C:\\out\\db.xlsx');
    const ExportQuery = vi.fn(async () => 'C:\\out\\r.csv');
    const RunQuery = vi.fn(async () => ({ columns: ['n', 'n (2)'], rows: [{ n: 1, 'n (2)': 'x' }], more: true }));
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, ExportDatabase, ExportQuery, RunQuery } } } });
    render(<App />);

    fireEvent.click(screen.getByRole('button', { name: 'Export' }));
    expect(screen.getByRole('menuitem', { name: /Database as Excel/ })).toBeDisabled(); // nothing open yet
    // SQLite before DuckDB (owner's format order)
    const items = screen.getAllByRole('menuitem').map((el) => el.textContent);
    expect(items.indexOf(en('export.dbSqlite'))).toBeLessThan(items.indexOf(en('export.dbDuckdb')));
    fireEvent.click(screen.getByRole('button', { name: 'Export' }));
    menu('File', 'Open sample data');
    await screen.findByText('Alpha');

    menu('Export', /Database as Excel/);
    await waitFor(() => expect(ExportDatabase).toHaveBeenCalledWith('xlsx'));
    expect(await screen.findByText(/Exported .* to C:\\out\\db\.xlsx/)).toBeInTheDocument();

    fireEvent.click(screen.getByRole('tab', { name: 'SQL' }));
    fireEvent.change(screen.getByLabelText('SQL'), { target: { value: 'select 1' } });
    fireEvent.keyDown(screen.getByLabelText('SQL'), { key: 'Enter', ctrlKey: true });
    await waitFor(() => expect(RunQuery).toHaveBeenCalledWith('select 1', 100));
    expect(await screen.findByText('n (2)')).toBeInTheDocument();
    expect(screen.getByText(/1 rows \(limit 100/)).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Export' }));
    fireEvent.click(screen.getByRole('menuitem', { name: 'SQL result as CSV' }));
    await waitFor(() => expect(ExportQuery).toHaveBeenCalledWith('select 1', 'csv'));
  });

  // owner's rule: no action twice on screen (1.1.1 had Export in File and again as a toolbar button)
  it('shows every button and menu action once', async () => {
    render(<App />);
    menu('File', 'Open sample data');
    await screen.findByText('Alpha');
    fireEvent.contextMenu(screen.getByText('Beta'));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Filter by this value' }));
    await screen.findByText("Filter: NAME = 'Beta'");

    const names = (role, root = document.body) =>
      [...root.querySelectorAll(role === 'button' ? 'button:not([role])' : `[role="${role}"]`)]
        .filter((el) => !el.closest('.sidebar')) // the table list is data, not actions
        .map((el) => el.getAttribute('aria-label') || el.textContent.trim());
    const all = names('button');
    for (const m of ['File', 'Export', 'View', 'Settings', 'Help']) {
      fireEvent.click(screen.getByRole('button', { name: m }));
      all.push(...names('menuitem'), ...names('menuitemradio'), ...names('menuitemcheckbox'));
      fireEvent.click(screen.getByRole('button', { name: m }));
    }
    const dupes = all.filter((n, i) => all.indexOf(n) !== i);
    expect(dupes).toEqual([]);
    expect(all.filter((n) => /export/i.test(n))).toEqual(['Export']); // one Export entry point
    expect(all).toContain('Database as Excel (.xlsx, one sheet per table)');
    expect(all).toContain('Clear filters');
    expect(all).toContain('Columns...');
    // labels and data only: no how-to sentences, no copyright line
    fireEvent.click(screen.getByRole('tab', { name: 'SQL' }));
    const shown = document.body.textContent + [...document.querySelectorAll('[title]')].map((e) => e.title).join(' ');
    expect(shown).not.toMatch(/copyright|press |write a|verifi|lembre|open a database|export writes/i);
  });

  it('selects a cell by focus and opens its menu from the keyboard', async () => {
    render(<App />);
    menu('File', 'Open sample data');
    const cell = await screen.findByText('Beta');
    fireEvent.focus(cell);
    expect(cell).toHaveAttribute('aria-selected', 'true');
    fireEvent.contextMenu(cell); // menu key: no mouse position
    expect(screen.getByRole('menu', { name: 'Cell' }).style.left).not.toBe('0px');
    fireEvent.click(screen.getByRole('menuitem', { name: 'Filter by this value' }));
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 100, [{ column: 'NAME', value: 'Beta' }], ''));
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
    menu('File', 'Open sample data');
    await screen.findByText('Alpha');

    // table B answers late, after table A was chosen again: A stays
    slowTable.armed = true;
    fireEvent.click(screen.getByRole('button', { name: 'RANGER_SOGEN' }));
    fireEvent.click(screen.getByRole('button', { name: 'RANGER_SOACCU' }));
    await waitFor(() => expect(GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 100, [], ''));
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
    fireEvent.click(screen.getByRole('button', { name: 'Export' }));
    expect(screen.getByRole('menuitem', { name: 'SQL result as CSV' })).toBeEnabled();
    fireEvent.click(screen.getByRole('button', { name: 'Export' }));
    menu('File', 'Open sample data');
    await waitFor(() => expect(bridge.LoadDatabase).toHaveBeenCalledTimes(2));
    await screen.findByText('Alpha');
    fireEvent.click(screen.getByRole('button', { name: 'Export' }));
    expect(screen.getByRole('menuitem', { name: 'SQL result as CSV' })).toBeDisabled();
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
    menu('File', 'Open sample data');
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
    menu('File', 'Open sample data');

    fireEvent.contextMenu(await screen.findByText('Beta'));
    fireEvent.click(screen.getByRole('menuitem', { name: /Copy value/ }));
    await waitFor(() => expect(ClipboardSetText).toHaveBeenLastCalledWith('Beta'));
    fireEvent.contextMenu(screen.getByText('Beta'));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Copy row with header' }));
    await waitFor(() => expect(ClipboardSetText).toHaveBeenLastCalledWith('ID\tNAME\r\n2\tBeta'));
    fireEvent.contextMenu(screen.getByText('Beta'));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Copy row' }));
    await waitFor(() => expect(ClipboardSetText).toHaveBeenLastCalledWith('2\tBeta'));

    fireEvent.click(screen.getByText('Alpha'));
    fireEvent.keyDown(screen.getByText('Alpha'), { key: 'c', ctrlKey: true });
    await waitFor(() => expect(ClipboardSetText).toHaveBeenLastCalledWith('Alpha'));

    // the SQL tab searches its loaded result here (the Data tab asks the database)
    fireEvent.click(screen.getByRole('tab', { name: 'SQL' }));
    fireEvent.click(screen.getByRole('button', { name: 'Run' }));
    await screen.findByText('Beta');
    fireEvent.change(screen.getByLabelText('Search the result'), { target: { value: 'alp' } });
    expect(screen.queryByText('Beta')).not.toBeInTheDocument();
    expect(screen.getByText(/1 match "alp"/)).toBeInTheDocument();
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
    menu('File', 'Open database...');
    expect(await screen.findByText(/IPC bridge not available/i)).toBeInTheDocument();
  });
});

// one catalog per language with the same keys; every text of the screen comes from them
describe('language catalogs', () => {
  const source = readFileSync('src/App.tsx', 'utf8');

  it('have the same keys in the three languages, none empty', () => {
    const keys = Object.keys(CATALOGS.en).sort();
    for (const l of LANGS) {
      expect(Object.keys(CATALOGS[l]).sort()).toEqual(keys);
      expect(Object.entries(CATALOGS[l]).filter(([, v]) => !v.trim())).toEqual([]);
    }
  });

  it('hold every key the screen uses', () => {
    const used = [...source.matchAll(/\bt\(\s*'([^']+)'/g)].map((m) => m[1]);
    used.push(...['system', 'light', 'dark'].map((th) => `theme.${th}`), ...LANGS.map((l) => `lang.${l}`), 'scope.table', 'scope.all');
    expect(used.length).toBeGreaterThan(80);
    expect(used.filter((k) => !(k in CATALOGS.en))).toEqual([]);
  });

  // shortcut: a text check of the JSX (no parser); it catches literal words between tags and in title,
  // placeholder and aria-label; key names (Ctrl+C), symbols and data (mdb2sql, GitHub links) are allowed
  it('leave no literal UI text in App.tsx', () => {
    const jsx = source.replace(/\r\n/g, '\n');
    const allowed = new Set(['mdb2sql', 'Ctrl+C', 'Ctrl+Enter']);
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
