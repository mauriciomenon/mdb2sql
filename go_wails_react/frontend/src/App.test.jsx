import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { vi, beforeEach } from 'vitest';
import App, { rowToTsv, searchRows, tsvField } from './App.tsx';

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

  it('shows the About dialog with app and runtime versions, and closes it', async () => {
    const GetAppInfo = vi.fn(async () => ({ version: '1.0.1', go: '1.26.10', wails: 'v2.13.0', duckdb: 'v2.0.0' }));
    global.window = Object.assign(window, { go: { main: { App: { ...bridge, GetAppInfo } } } });
    render(<App />);

    fireEvent.click(screen.getByRole('button', { name: 'About' }));

    const dialog = await screen.findByRole('dialog', { name: 'MDB2SQL (Go + Wails + React)' });
    const lines = [...dialog.querySelectorAll('h2, p')].map((el) => el.textContent);
    expect(lines).toEqual([
      'MDB2SQL (Go + Wails + React)',
      'Versao 1.0.1',
      'Visualizador de bancos DuckDB convertidos de Microsoft Access: tabelas, esquema, dados e consultas.',
      `Go 1.26.10, Wails 2.13.0, DuckDB 2.0.0, React ${React.version}`,
      'Autor: Mauricio Menon',
      'Codigo: https://github.com/mauriciomenon/mdb2sql',
    ]);

    fireEvent.click(screen.getByRole('button', { name: 'Close' }));
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
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
