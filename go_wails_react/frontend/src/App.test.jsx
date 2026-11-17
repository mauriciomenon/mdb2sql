import React from 'react';
import { readFileSync } from 'node:fs';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { vi, beforeEach } from 'vitest';
import App, { aboutRows, filterLabel, progressText, rowToTsv, searchRows, tsvField, withFilter } from './App.tsx';

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

    await waitFor(() => expect(bridge.GetTableData).toHaveBeenCalledWith('RANGER_SOACCU', 100, []));
    expect(screen.getByText('Alpha')).toBeInTheDocument();
    expect(screen.getByText(/Showing 2 of 2 rows/i)).toBeInTheDocument();
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
      version: '1.2.0', build: '412', buildDate: '2026-11-17', go: '1.26.10', wails: 'v2.13.0', duckdb: 'v2.0.0', access: 'Access ODBC',
    }));
    const BrowserOpenURL = vi.fn();
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetAppInfo } } }, runtime: { BrowserOpenURL } });
    render(<App />);

    fireEvent.click(screen.getByRole('button', { name: 'Help' }));
    fireEvent.click(screen.getByRole('menuitem', { name: 'About' }));

    const dialog = await screen.findByRole('dialog', { name: 'mdb2sql 1.2.0' });
    expect(dialog.querySelector('.tagline').textContent).toMatch(/^Visualiza e exporta bancos DuckDB, SQLite e Microsoft Access/);
    const rows = [...dialog.querySelectorAll('dl > div')].map((el) => [el.querySelector('dt').textContent, el.querySelector('dd').textContent]);
    expect(rows).toEqual([
      ['Build', '412 (2026-11-17)'],
      ['Stack', `Go 1.26.10 + Wails 2.13.0 + React ${React.version}`],
      ['Banco', 'DuckDB 2.0.0'],
      ['Leitor Access', 'ODBC do Microsoft Access (driver instalado); reserva: mdbtools embutido'],
      ['Autor', 'Mauricio Menon'],
      ['Licenca', 'GPL v2 ou posterior'],
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

    fireEvent.click(screen.getByRole('button', { name: 'Fechar' }));
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    const dev = Object.fromEntries(aboutRows({ version: '1.2.0', go: '1', wails: '2', duckdb: '3', access: 'mdbtools' }));
    expect(dev.Build).toBe('dev');
    expect(dev['Leitor Access']).toMatch(/^mdbtools embutido/);
    delete window.runtime;
  });

  it('hides several columns at once from Colunas... and from the header menu', async () => {
    render(<App />);
    menu('File', 'Open sample data');
    await screen.findByText('Alpha');
    const header = (name) => screen.queryByRole('columnheader', { name });

    expect(screen.getByRole('button', { name: 'Colunas...' }).title).toMatch(/Export continuam usando todas as colunas/);
    fireEvent.click(screen.getByRole('button', { name: 'Colunas...' }));
    const dialog = screen.getByRole('dialog', { name: 'Colunas de RANGER_SOACCU' });
    fireEvent.click(screen.getByRole('checkbox', { name: 'NAME' }));
    expect(header('NAME')).not.toBeInTheDocument();
    expect(screen.queryByText('Alpha')).not.toBeInTheDocument();
    expect(screen.getByText('1 coluna oculta')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Ocultar todas' }));
    expect(screen.getByText('2 colunas ocultas')).toBeInTheDocument();
    expect(header('ID')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Mostrar todas' }));
    expect(screen.getByRole('checkbox', { name: 'NAME' })).toBeChecked();
    fireEvent.click(screen.getByRole('checkbox', { name: 'ID' }));
    fireEvent.click(screen.getByRole('button', { name: 'Fechar' }));
    expect(dialog).not.toBeInTheDocument();
    expect(header('ID')).not.toBeInTheDocument();
    expect(header('NAME')).toBeInTheDocument();

    // the search still looks at the hidden column: ID 2 is only in the hidden ID column
    fireEvent.change(screen.getByLabelText('Search rows'), { target: { value: '2' } });
    expect(screen.getByText('Beta')).toBeInTheDocument();
    expect(screen.queryByText('Alpha')).not.toBeInTheDocument();
    fireEvent.change(screen.getByLabelText('Search rows'), { target: { value: '' } });

    fireEvent.contextMenu(header('NAME'));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Ocultar esta coluna' }));
    expect(screen.getByText('2 colunas ocultas')).toBeInTheDocument();
    // every header is hidden now; the dialog is still reachable from the button
    fireEvent.click(screen.getByRole('button', { name: 'Colunas...' }));
    fireEvent.click(screen.getByRole('checkbox', { name: 'ID' }));
    fireEvent.click(screen.getByRole('button', { name: 'Fechar' }));
    fireEvent.contextMenu(header('ID'));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Mostrar todas' }));
    expect(screen.queryByText(/ocultas?$/)).not.toBeInTheDocument();
    expect(screen.getByText('Alpha')).toBeInTheDocument();

    // another table starts with every column visible
    fireEvent.contextMenu(header('NAME'));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Ocultar esta coluna' }));
    fireEvent.click(screen.getByRole('button', { name: 'RANGER_SOGEN' }));
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOGEN', 100, []));
    await waitFor(() => expect(header('NAME')).toBeInTheDocument());
  });

  it('filters by the right-clicked value in the database query and shows removable chips', async () => {
    const GetRowCount = vi.fn(async (_table, filters) => (filters.length ? 1 : 2));
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetRowCount } } } });
    render(<App />);
    menu('File', 'Open sample data');

    fireEvent.contextMenu(await screen.findByText('Beta'));
    expect(screen.getByRole('menuitem', { name: 'Limpar filtros' })).toBeDisabled();
    fireEvent.click(screen.getByRole('menuitem', { name: 'Filtrar por este valor' }));
    const byName = { column: 'NAME', value: 'Beta' };
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 100, [byName]));
    expect(GetRowCount).toHaveBeenCalledWith('RANGER_SOACCU', [byName]);
    expect(await screen.findByText("Filtro: NAME = 'Beta'")).toBeInTheDocument();
    expect(await screen.findByText(/Showing 2 of 1 rows matching the filters \(2 in the table\)/)).toBeInTheDocument();

    // a second column is ANDed; the row limit keeps the filters
    fireEvent.contextMenu(screen.getByRole('cell', { name: '2' }));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Filtrar por este valor' }));
    const byId = { column: 'ID', value: 2 };
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 100, [byName, byId]));
    expect(await screen.findByText('Filtro: ID = 2')).toBeInTheDocument();
    fireEvent.change(screen.getByRole('combobox'), { target: { value: '500' } });
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 500, [byName, byId]));

    fireEvent.click(screen.getByRole('button', { name: 'Remover filtro NAME' }));
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 500, [byId]));
    await waitFor(() => expect(screen.queryByText("Filtro: NAME = 'Beta'")).not.toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: 'Limpar filtros' }));
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 500, []));
    await waitFor(() => expect(screen.queryByRole('group', { name: 'Filtros ativos' })).not.toBeInTheDocument());

    // changing table clears the filters
    fireEvent.contextMenu(screen.getByText('Beta'));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Filtrar por este valor' }));
    await screen.findByText("Filtro: NAME = 'Beta'");
    fireEvent.click(screen.getByRole('button', { name: 'RANGER_SOGEN' }));
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOGEN', 500, []));
    await waitFor(() => expect(screen.queryByRole('group', { name: 'Filtros ativos' })).not.toBeInTheDocument());
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
    const SourceKind = vi.fn(async () => 'Access ODBC');
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, StartupPath, SourceKind } } } });
    render(<App />);

    await waitFor(() => expect(bridge.LoadDatabase).toHaveBeenCalledWith('C:\\data\\DB4.accdb'));
    expect(await screen.findByText('Opened via Access ODBC')).toBeInTheDocument();
    expect(screen.getByText(/Loaded: DB4\.accdb \(2 tables\)/)).toBeInTheDocument();
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

  it('exports from the Export menu and runs SQL', async () => {
    const ExportDatabase = vi.fn(async () => 'C:\\out\\db.xlsx');
    const ExportQuery = vi.fn(async () => 'C:\\out\\r.csv');
    const RunQuery = vi.fn(async () => ({ columns: ['n', 'n (2)'], rows: [{ n: 1, 'n (2)': 'x' }], more: true }));
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, ExportDatabase, ExportQuery, RunQuery } } } });
    render(<App />);

    fireEvent.click(screen.getByRole('button', { name: 'Export' }));
    expect(screen.getByRole('menuitem', { name: /Database as Excel/ })).toBeDisabled(); // nothing open yet
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
    fireEvent.click(screen.getByRole('menuitem', { name: 'Filtrar por este valor' }));
    await screen.findByText("Filtro: NAME = 'Beta'");

    const names = (role, root = document.body) =>
      [...root.querySelectorAll(role === 'button' ? 'button:not([role])' : `[role="${role}"]`)]
        .filter((el) => !el.closest('.sidebar')) // the table list is data, not actions
        .map((el) => el.getAttribute('aria-label') || el.textContent.trim());
    const all = names('button');
    for (const m of ['File', 'Export', 'Settings', 'Help']) {
      fireEvent.click(screen.getByRole('button', { name: m }));
      all.push(...names('menuitem'), ...names('menuitemradio'));
      fireEvent.click(screen.getByRole('button', { name: m }));
    }
    const dupes = all.filter((n, i) => all.indexOf(n) !== i);
    expect(dupes).toEqual([]);
    expect(all.filter((n) => /export/i.test(n))).toEqual(['Export']); // one Export entry point
    expect(all).toContain('Database as Excel (.xlsx, one sheet per table)');
    expect(all).toContain('Limpar filtros');
    expect(all).toContain('Colunas...');
  });

  it('selects a cell by focus and opens its menu from the keyboard', async () => {
    render(<App />);
    menu('File', 'Open sample data');
    const cell = await screen.findByText('Beta');
    fireEvent.focus(cell);
    expect(cell).toHaveAttribute('aria-selected', 'true');
    fireEvent.contextMenu(cell); // menu key: no mouse position
    expect(screen.getByRole('menu', { name: 'Cell' }).style.left).not.toBe('0px');
    fireEvent.click(screen.getByRole('menuitem', { name: 'Filtrar por este valor' }));
    await waitFor(() => expect(bridge.GetTableData).toHaveBeenLastCalledWith('RANGER_SOACCU', 100, [{ column: 'NAME', value: 'Beta' }]));
  });

  // jsdom has no layout, so the rules themselves are checked: 1.2.0 builds cut "RANGER_SOSTAT" to "RAN..."
  it('never cuts the table name or a column header', () => {
    const css = readFileSync('src/App.css', 'utf8').replace(/\r\n/g, '\n').replace(/\/\*[\s\S]*?\*\//g, '');
    const rule = (sel) => css.match(new RegExp(`(?:^|\\n)${sel.replace(/[.*]/g, '\\$&')} \\{([^}]*)\\}`))?.[1] ?? '';
    const title = rule('.content-bar h2');
    expect(title).toMatch(/flex: none/);
    expect(title).toMatch(/white-space: normal/);
    expect(rule('.content-bar')).toMatch(/flex-wrap: wrap/);
    const cells = rule('th,\ntd');
    expect(cells).toMatch(/white-space: nowrap/);
    expect(cells + rule('th')).not.toMatch(/max-width|text-overflow|overflow: hidden/);
  });

  it('describes progress by table or by row', () => {
    expect(progressText('Loading', null)).toBe('Loading...');
    expect(progressText('Loading', { done: 12, total: 287, label: 'RANGER_SOSTAT' })).toBe('Loading RANGER_SOSTAT - 12 of 287');
    expect(progressText('Exporting', { done: 5000, total: 0, label: 'Result' })).toBe('Exporting Result - 5000');
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
    fireEvent.change(screen.getByLabelText('Filter tables'), { target: { value: 'gen ranger' } });
    expect(screen.queryByRole('button', { name: 'RANGER_SOACCU' })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'RANGER_SOGEN' })).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText('Filter tables'), { target: { value: 'campo tensao' } });
    expect(screen.getByRole('button', { name: 'TENSÃO_CAMPO' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'RANGER_SOGEN' })).not.toBeInTheDocument();
  });

  it('copies the selected value and row from the context menu and Ctrl+C, and filters rows', async () => {
    const ClipboardSetText = vi.fn(async () => true);
    global.window = Object.assign(window, { runtime: { ClipboardSetText } });
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

    fireEvent.change(screen.getByLabelText('Search rows'), { target: { value: 'alp' } });
    expect(screen.queryByText('Beta')).not.toBeInTheDocument();
    expect(screen.getByText(/1 match "alp"/)).toBeInTheDocument();
    delete window.runtime;
  });

  it('handles IPC unavailable gracefully', async () => {
    global.window = Object.assign(window, { go: undefined });
    render(<App />);
    menu('File', 'Open database...');
    expect(await screen.findByText(/IPC bridge not available/i)).toBeInTheDocument();
  });
});
