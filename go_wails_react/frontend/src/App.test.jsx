import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { vi, beforeEach } from 'vitest';
import App, { aboutLines, progressText, rowToTsv, searchRows, tsvField } from './App.tsx';

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

    fireEvent.click(screen.getByRole('button', { name: /Load Database/i }));

    await waitFor(() => expect(bridge.LoadDatabase).toHaveBeenCalled());
    expect(screen.getByText(/Loaded:/i)).toBeInTheDocument();

    // Should list tables and allow selection
    const tableItem = screen.getAllByText('RANGER_SOACCU')[0];
    expect(tableItem).toBeInTheDocument();
    fireEvent.click(tableItem);

    await waitFor(() => expect(bridge.GetTableData).toHaveBeenCalledWith('RANGER_SOACCU', 100));
    expect(screen.getByText('Alpha')).toBeInTheDocument();
    expect(screen.getByText(/Showing 2 of 2 rows/i)).toBeInTheDocument();
  });

  it('opens the file picked in the native dialog and shows its schema', async () => {
    const SelectDatabase = vi.fn(async () => 'C:\\data\\real.duckdb');
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SelectDatabase } } } });
    render(<App />);

    fireEvent.click(screen.getByRole('button', { name: /Load Database/i }));

    await waitFor(() => expect(bridge.LoadDatabase).toHaveBeenCalledWith('C:\\data\\real.duckdb'));
    expect(await screen.findByText(/Loaded: real\.duckdb \(2 tables\)/)).toBeInTheDocument();

    fireEvent.click(await screen.findByRole('tab', { name: /Schema \(2\)/ }));
    expect(screen.getByText('INTEGER')).toBeInTheDocument();
  });

  it('does nothing when the dialog is cancelled', async () => {
    const SelectDatabase = vi.fn(async () => '');
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, SelectDatabase } } } });
    render(<App />);

    fireEvent.click(screen.getByRole('button', { name: /Load Database/i }));

    await waitFor(() => expect(SelectDatabase).toHaveBeenCalled());
    expect(bridge.LoadDatabase).not.toHaveBeenCalled();
    expect(screen.getByText('No database loaded')).toBeInTheDocument();
  });

  it('shows the real file name when the default database is loaded', async () => {
    const DatabaseName = vi.fn(async () => 'DB4.duckdb');
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, DatabaseName } } } });
    render(<App />);

    fireEvent.click(screen.getByRole('button', { name: 'Sample data' }));

    expect(await screen.findByText(/Loaded: DB4\.duckdb \(2 tables\)/)).toBeInTheDocument();
    expect(bridge.LoadDatabase).toHaveBeenCalledWith('');
  });

  it('shows Help > About with version, build and runtime versions, and closes it', async () => {
    const GetAppInfo = vi.fn(async () => ({
      version: '1.1.0', build: '412', buildDate: '2026-11-15', go: '1.26.10', wails: 'v2.13.0', duckdb: 'v2.0.0',
    }));
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetAppInfo } } } });
    render(<App />);

    fireEvent.click(screen.getByRole('button', { name: 'Help' }));
    fireEvent.click(screen.getByRole('menuitem', { name: 'About' }));

    const dialog = await screen.findByRole('dialog', { name: 'MDB2SQL (Go + Wails + React)' });
    const lines = [...dialog.querySelectorAll('h2, p')].map((el) => el.textContent);
    expect(lines).toEqual([
      'MDB2SQL (Go + Wails + React)',
      'Versao 1.1.0 - build 412 (2026-11-15)',
      'Visualiza e exporta bancos DuckDB, SQLite e Microsoft Access: tabelas, esquema, dados e SQL.',
      `Go 1.26.10, Wails 2.13.0, DuckDB 2.0.0, React ${React.version}`,
      'Autor: Mauricio Menon',
      'Codigo: https://github.com/mauriciomenon/mdb2sql',
    ]);

    fireEvent.click(screen.getByRole('button', { name: 'Close' }));
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    expect(aboutLines({ version: '1.1.0', go: '1', wails: '2', duckdb: '3' })[1]).toBe('Versao 1.1.0 - build dev');
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

  it('exports from File > Export and the Export button, and runs SQL', async () => {
    const ExportDatabase = vi.fn(async () => 'C:\\out\\db.xlsx');
    const ExportQuery = vi.fn(async () => 'C:\\out\\r.csv');
    const RunQuery = vi.fn(async () => ({ columns: ['n', 'n (2)'], rows: [{ n: 1, 'n (2)': 'x' }], more: true }));
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, ExportDatabase, ExportQuery, RunQuery } } } });
    render(<App />);

    fireEvent.click(screen.getByRole('button', { name: 'File' }));
    expect(screen.getByRole('menuitem', { name: /Database as Excel/ })).toBeDisabled(); // nothing open yet
    fireEvent.click(screen.getByRole('button', { name: 'Sample data' }));
    await screen.findByText('Alpha');

    fireEvent.click(screen.getByRole('button', { name: 'File' }));
    fireEvent.click(screen.getByRole('menuitem', { name: /Database as Excel/ }));
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

  it('copies the selected value and row from the context menu and Ctrl+C, and filters rows', async () => {
    const ClipboardSetText = vi.fn(async () => true);
    global.window = Object.assign(window, { runtime: { ClipboardSetText } });
    render(<App />);
    fireEvent.click(screen.getByRole('button', { name: 'Sample data' }));

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
    fireEvent.click(screen.getByRole('button', { name: /Load Database/i }));
    expect(await screen.findByText(/IPC bridge not available/i)).toBeInTheDocument();
  });
});
