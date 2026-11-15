// Visualizador de bancos DuckDB: abre um arquivo, lista tabelas, mostra dados e schema
// !T: Single-screen viewer talking to Go through the Wails IPC bridge (window.go.main.App)

import { useEffect, useMemo, useState } from 'react';
import './App.css';

type Row = Record<string, unknown>;
type Column = { name: string; type: string; null: string };
type Theme = 'auto' | 'light' | 'dark';
type View = 'data' | 'schema';

declare global {
  interface Window {
    go?: {
      main: {
        App: {
          LoadDatabase: (dbPath: string) => Promise<string[]>;
          GetTableData: (tableName: string, limit: number) => Promise<Row[]>;
          GetRowCount: (tableName: string) => Promise<number>;
          GetTableSchema?: (tableName: string) => Promise<Column[]>;
          SelectDatabase?: () => Promise<string>;
        };
      };
    };
  }
}

const ROW_LIMITS = [100, 500, 1000];
const THEMES: Theme[] = ['auto', 'light', 'dark'];

function getWailsBridge() {
  const bridge = window.go?.main?.App;
  if (!bridge) {
    throw new Error('IPC bridge not available');
  }
  return bridge;
}

function savedTheme(): Theme {
  try {
    const t = localStorage.getItem('theme') as Theme;
    return THEMES.includes(t) ? t : 'auto';
  } catch {
    return 'auto';
  }
}

function App() {
  const [tables, setTables] = useState<string[]>([]);
  const [filter, setFilter] = useState('');
  const [selectedTable, setSelectedTable] = useState('');
  const [rows, setRows] = useState<Row[]>([]);
  const [rowCount, setRowCount] = useState(0);
  const [schema, setSchema] = useState<Column[]>([]);
  const [view, setView] = useState<View>('data');
  const [limit, setLimit] = useState(ROW_LIMITS[0]);
  const [status, setStatus] = useState('No database loaded');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [theme, setTheme] = useState<Theme>(savedTheme);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    try {
      localStorage.setItem('theme', theme);
    } catch {
      // storage blocked: theme just does not persist
    }
  }, [theme]);

  function fail(err: unknown, newStatus?: string) {
    setError(err instanceof Error ? err.message : String(err));
    if (newStatus) setStatus(newStatus);
  }

  // pick=true abre o seletor de arquivo; pick=false usa o banco padrao (MDB2SQL_DB_PATH ou data/sample.duckdb)
  async function loadDatabase(pick: boolean) {
    setError('');
    setBusy(true);
    try {
      const bridge = getWailsBridge();
      let path = '';
      if (pick && bridge.SelectDatabase) {
        path = await bridge.SelectDatabase();
        if (!path) return; // dialog cancelled
      }
      setStatus('Loading...');
      const tableList = (await bridge.LoadDatabase(path)) ?? [];
      const name = path ? path.split(/[\\/]/).pop() : 'sample.duckdb';
      setTables(tableList);
      setFilter('');
      setRows([]);
      setSchema([]);
      setSelectedTable('');
      setStatus(`Loaded: ${name} (${tableList.length} tables)`);
      if (tableList.length > 0) {
        await loadTable(tableList[0], limit);
      }
    } catch (err) {
      fail(err, 'Error loading database');
    } finally {
      setBusy(false);
    }
  }

  async function loadTable(tableName: string, rowLimit: number) {
    try {
      setError('');
      setSelectedTable(tableName);
      const bridge = getWailsBridge();
      const [data, count, cols] = await Promise.all([
        bridge.GetTableData(tableName, rowLimit),
        bridge.GetRowCount(tableName),
        bridge.GetTableSchema ? bridge.GetTableSchema(tableName) : Promise.resolve([]),
      ]);
      setRows(data ?? []); // Go sends null for an empty table
      setRowCount(count);
      setSchema(cols ?? []);
    } catch (err) {
      fail(err);
    }
  }

  function changeLimit(rowLimit: number) {
    setLimit(rowLimit);
    if (selectedTable) loadTable(selectedTable, rowLimit);
  }

  const visibleTables = useMemo(() => {
    const f = filter.trim().toLowerCase();
    return f ? tables.filter((t) => t.toLowerCase().includes(f)) : tables;
  }, [tables, filter]);

  // schema order = database column order (Go maps reach JS sorted by key); also gives empty tables a header
  const columns = schema.length > 0 ? schema.map((c) => c.name) : Object.keys(rows[0] ?? {});

  return (
    <div className="app">
      <header className="toolbar">
        <h1>mdb2sql</h1>
        <button className="primary" onClick={() => loadDatabase(true)} disabled={busy}>
          Load database
        </button>
        <button onClick={() => loadDatabase(false)} disabled={busy} title="MDB2SQL_DB_PATH or data/sample.duckdb">
          Sample data
        </button>
        <p className={error ? 'status error' : 'status'} role="status" aria-live="polite">
          {error || status}
        </p>
        <label className="field">
          Theme
          <select value={theme} onChange={(e) => setTheme(e.target.value as Theme)}>
            {THEMES.map((t) => (
              <option key={t} value={t}>
                {t}
              </option>
            ))}
          </select>
        </label>
      </header>

      <nav className="sidebar" aria-label="Tables">
        <input
          type="search"
          placeholder={`Filter ${tables.length} tables`}
          aria-label="Filter tables"
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          disabled={tables.length === 0}
        />
        <ul>
          {visibleTables.map((table) => (
            <li key={table}>
              <button
                className="table-item"
                aria-current={table === selectedTable ? 'true' : undefined}
                onClick={() => loadTable(table, limit)}
              >
                {table}
              </button>
            </li>
          ))}
        </ul>
        {tables.length > 0 && visibleTables.length === 0 && <p className="empty">No table matches.</p>}
      </nav>

      <main className="content">
        {!selectedTable ? (
          <p className="empty">Load a DuckDB database (.duckdb, .db, .sqlite) to browse its tables.</p>
        ) : (
          <>
            <div className="content-bar">
              <h2>{selectedTable}</h2>
              <div className="tabs" role="tablist" aria-label="Table view">
                {(['data', 'schema'] as View[]).map((v) => (
                  <button key={v} role="tab" aria-selected={view === v} onClick={() => setView(v)}>
                    {v === 'data' ? 'Data' : `Schema (${schema.length})`}
                  </button>
                ))}
              </div>
              <label className="field">
                Rows
                <select value={limit} onChange={(e) => changeLimit(Number(e.target.value))}>
                  {ROW_LIMITS.map((n) => (
                    <option key={n} value={n}>
                      {n}
                    </option>
                  ))}
                </select>
              </label>
            </div>

            {/* tabIndex: the scroll area must be reachable and scrollable by keyboard */}
            <div className="table-container" tabIndex={0} role="region" aria-label={`${selectedTable} ${view}`}>
              {view === 'data' ? (
                <table>
                  <thead>
                    <tr>
                      {columns.map((col) => (
                        <th key={col} scope="col">
                          {col}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {rows.map((row, idx) => (
                      <tr key={idx}>
                        {columns.map((col) => (
                          <td key={col} className={typeof row[col] === 'number' ? 'num' : undefined}>
                            {String(row[col] ?? '')}
                          </td>
                        ))}
                      </tr>
                    ))}
                  </tbody>
                </table>
              ) : (
                <table>
                  <thead>
                    <tr>
                      <th scope="col">Column</th>
                      <th scope="col">Type</th>
                      <th scope="col">Nullable</th>
                    </tr>
                  </thead>
                  <tbody>
                    {schema.map((col) => (
                      <tr key={col.name}>
                        <td>{col.name}</td>
                        <td>{col.type}</td>
                        <td>{col.null}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
              {view === 'data' && rows.length === 0 && <p className="empty">This table has no rows.</p>}
            </div>

            <footer className="info">
              {selectedTable}: Showing {rows.length} of {rowCount} rows
            </footer>
          </>
        )}
      </main>
    </div>
  );
}

export default App;
