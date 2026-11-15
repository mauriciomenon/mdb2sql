// Visualizador de bancos DuckDB: abre um arquivo, lista tabelas, mostra dados e schema
// !T: Single-screen viewer talking to Go through the Wails IPC bridge (window.go.main.App)

import { useEffect, useMemo, useState, version as reactVersion } from 'react';
import './App.css';

type Row = Record<string, unknown>;
type Column = { name: string; type: string; null: string };
type Theme = 'auto' | 'light' | 'dark';
type View = 'data' | 'schema';
export type AppInfo = { version: string; go: string; wails: string; duckdb: string };

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
          DatabaseName?: () => Promise<string>;
          GetAppInfo?: () => Promise<AppInfo>;
        };
      };
    };
    runtime?: { BrowserOpenURL?: (url: string) => void; ClipboardSetText?: (text: string) => Promise<boolean> };
  }
}

const ROW_LIMITS = [100, 500, 1000];
const THEMES: Theme[] = ['auto', 'light', 'dark'];

const REPO_URL = 'https://github.com/mauriciomenon/mdb2sql';

// Linhas do dialogo Sobre; a versao vem de wails.json (via Go) e as versoes de runtime sao lidas em execucao
// !T: Text is Portuguese on purpose (owner's spec); the last line ends with REPO_URL, rendered as a link
export function aboutLines(info: AppInfo): string[] {
  const v = (s: string) => s.replace(/^v/, '');
  return [
    'MDB2SQL (Go + Wails + React)',
    `Versão ${info.version}`,
    'Visualizador de bancos DuckDB convertidos de Microsoft Access: tabelas, esquema, dados e consultas.',
    `Go ${info.go}, Wails ${v(info.wails)}, DuckDB ${v(info.duckdb)}, React ${reactVersion}`,
    'Autor: Mauricio Menon',
    `Código: ${REPO_URL}`,
  ];
}

export const cellText = (v: unknown) => String(v ?? '');

// Regra de colagem do Excel/Sheets: campo com TAB, quebra de linha ou aspas vai entre aspas, com aspas dobradas
// !T: Without the quoting, a TAB or line break inside a value would shift the pasted cells
export function tsvField(v: unknown): string {
  const s = cellText(v);
  return /[\t\r\n"]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

export function rowToTsv(columns: string[], row: Row, withHeader: boolean): string {
  const line = columns.map((c) => tsvField(row[c])).join('\t');
  return withHeader ? `${columns.map(tsvField).join('\t')}\r\n${line}` : line;
}

// Busca sem diferenciar maiusculas em todas as colunas das linhas carregadas
export function searchRows(rows: Row[], columns: string[], query: string): Row[] {
  const q = query.trim().toLowerCase();
  return q ? rows.filter((r) => columns.some((c) => cellText(r[c]).toLowerCase().includes(q))) : rows;
}

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
  const [about, setAbout] = useState<string[] | null>(null);
  const [search, setSearch] = useState('');
  const [sel, setSel] = useState<{ row: Row; col: string } | null>(null); // selected cell
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null); // open copy menu
  const [copied, setCopied] = useState('');

  useEffect(() => {
    if (!menu) return;
    const close = () => setMenu(null);
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && close();
    window.addEventListener('click', close);
    window.addEventListener('keydown', onKey);
    return () => {
      window.removeEventListener('click', close);
      window.removeEventListener('keydown', onKey);
    };
  }, [menu]);

  async function copyText(text: string, what: string) {
    try {
      // the Wails clipboard goes through Go/Win32, so it does not depend on webview clipboard permissions
      if (window.runtime?.ClipboardSetText) await window.runtime.ClipboardSetText(text);
      else await navigator.clipboard.writeText(text);
      setCopied(`Copied ${what}`);
    } catch (err) {
      fail(err);
    }
  }

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    try {
      localStorage.setItem('theme', theme);
    } catch {
      // storage blocked: theme just does not persist
    }
  }, [theme]);

  useEffect(() => {
    if (!about) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setAbout(null);
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [about]);

  async function openAbout() {
    try {
      const bridge = getWailsBridge();
      if (!bridge.GetAppInfo) throw new Error('IPC bridge not available');
      setAbout(aboutLines(await bridge.GetAppInfo()));
    } catch (err) {
      fail(err);
    }
  }

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
      // Go knows which file an empty path resolved to (MDB2SQL_DB_PATH or the bundled sample)
      const name = (await bridge.DatabaseName?.()) || path.split(/[\\/]/).pop() || 'sample.duckdb';
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
      setSel(null);
      setCopied('');
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
  const visibleRows = useMemo(() => searchRows(rows, columns, search), [rows, schema, search]);
  const copyCell = () => sel && copyText(cellText(sel.row[sel.col]), 'value');
  const copyRow = (withHeader: boolean) =>
    sel && copyText(rowToTsv(columns, sel.row, withHeader), withHeader ? 'row with header' : 'row');

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
        <button onClick={openAbout}>About</button>
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
              <input
                type="search"
                className="search"
                placeholder="Search loaded rows"
                aria-label="Search rows"
                title="Finds text in any column of the rows loaded now (see Rows)"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
              />
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
            <div
              className="table-container"
              tabIndex={0}
              role="region"
              aria-label={`${selectedTable} ${view}`}
              onKeyDown={(e) => {
                // Ctrl+C copies the selected cell, unless the user marked text with the mouse (native copy)
                if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'c' && sel && !window.getSelection()?.toString()) {
                  e.preventDefault();
                  copyCell();
                }
              }}
            >
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
                    {visibleRows.map((row, idx) => (
                      <tr key={idx} className={sel?.row === row ? 'selected' : undefined}>
                        {columns.map((col) => (
                          <td
                            key={col}
                            className={typeof row[col] === 'number' ? 'num' : undefined}
                            aria-selected={sel?.row === row && sel.col === col ? 'true' : undefined}
                            onClick={() => setSel({ row, col })}
                            onContextMenu={(e) => {
                              e.preventDefault();
                              setSel({ row, col });
                              setMenu({ x: e.clientX, y: e.clientY });
                            }}
                          >
                            {cellText(row[col])}
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
              {view === 'data' && visibleRows.length === 0 && (
                <p className="empty">{rows.length === 0 ? 'This table has no rows.' : 'No loaded row matches the search.'}</p>
              )}
            </div>

            <footer className="info">
              {selectedTable}: Showing {rows.length} of {rowCount} rows
              {search.trim() && ` - ${visibleRows.length} match "${search.trim()}"`}
              {copied && ` - ${copied}`}
            </footer>
          </>
        )}
      </main>

      {menu && (
        <div
          className="menu"
          role="menu"
          aria-label="Copy"
          style={{ left: Math.min(menu.x, window.innerWidth - 220), top: Math.min(menu.y, window.innerHeight - 120) }}
        >
          <button role="menuitem" autoFocus onClick={copyCell}>
            Copy value <kbd>Ctrl+C</kbd>
          </button>
          <button role="menuitem" onClick={() => copyRow(false)}>
            Copy row
          </button>
          <button role="menuitem" onClick={() => copyRow(true)}>
            Copy row with header
          </button>
        </div>
      )}

      {about && (
        <div className="backdrop" onClick={(e) => e.target === e.currentTarget && setAbout(null)}>
          <div className="about" role="dialog" aria-modal="true" aria-labelledby="about-title">
            <h2 id="about-title">{about[0]}</h2>
            {about.slice(1).map((line) =>
              line.endsWith(REPO_URL) ? (
                <p key={line}>
                  {line.slice(0, -REPO_URL.length)}
                  <a
                    href={REPO_URL}
                    onClick={(e) => {
                      e.preventDefault(); // never navigate the app's own webview away
                      window.runtime?.BrowserOpenURL?.(REPO_URL);
                    }}
                  >
                    {REPO_URL}
                  </a>
                </p>
              ) : (
                <p key={line}>{line}</p>
              ),
            )}
            <button className="primary" autoFocus onClick={() => setAbout(null)}>
              Close
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

export default App;
