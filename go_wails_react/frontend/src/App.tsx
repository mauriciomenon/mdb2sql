// Visualizador de bancos (DuckDB, SQLite, Access): abre um arquivo, lista tabelas, mostra dados, schema e SQL, exporta
// !T: Single-screen viewer talking to Go through the Wails IPC bridge (window.go.main.App)

import { useEffect, useMemo, useRef, useState, version as reactVersion } from 'react';
import './App.css';

type Row = Record<string, unknown>;
type Column = { name: string; type: string; null: string };
export type Theme = 'system' | 'light' | 'dark';
type View = 'data' | 'schema' | 'sql';
type MenuName = 'file' | 'settings' | 'help' | 'export';
type QueryResult = { columns: string[]; rows: Row[]; more: boolean };
type Progress = { done: number; total: number; label: string };
export type AppInfo = { version: string; build?: string; buildDate?: string; go: string; wails: string; duckdb: string };

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
          SourceKind?: () => Promise<string>;
          StartupPath?: () => Promise<string>;
          GetAppInfo?: () => Promise<AppInfo>;
          RunQuery?: (query: string, limit: number) => Promise<QueryResult>;
          ExportDatabase?: (format: string) => Promise<string>;
          ExportTable?: (table: string, format: string) => Promise<string>;
          ExportQuery?: (query: string, format: string) => Promise<string>;
          CancelJob?: () => Promise<void>;
          GetTheme?: () => Promise<Theme>;
          SetTheme?: (theme: Theme) => Promise<void>;
        };
      };
    };
    runtime?: {
      BrowserOpenURL?: (url: string) => void;
      ClipboardSetText?: (text: string) => Promise<boolean>;
      EventsOn?: (name: string, cb: (data: Progress) => void) => () => void;
      Quit?: () => void;
    };
  }
}

const ROW_LIMITS = [100, 500, 1000]; // more would render too many cells (130-column tables)
const THEMES: { value: Theme; label: string }[] = [
  { value: 'system', label: 'System' },
  { value: 'light', label: 'Light' },
  { value: 'dark', label: 'Dark' },
];

const REPO_URL = 'https://github.com/mauriciomenon/mdb2sql';

// Linhas do dialogo Sobre; versao de wails.json, numero/data do build gravados pelo build, runtimes lidos em execucao
// !T: Text is Portuguese on purpose (owner's spec); the last line ends with REPO_URL, rendered as a link
export function aboutLines(info: AppInfo): string[] {
  const v = (s: string) => s.replace(/^v/, '');
  const build = info.build ? `build ${info.build} (${info.buildDate})` : 'build dev';
  return [
    'MDB2SQL (Go + Wails + React)',
    `Versao ${info.version} - ${build}`,
    'Visualiza e exporta bancos DuckDB, SQLite e Microsoft Access: tabelas, esquema, dados e SQL.',
    `Go ${info.go}, Wails ${v(info.wails)}, DuckDB ${v(info.duckdb)}, React ${reactVersion}`,
    'Autor: Mauricio Menon',
    `Codigo: ${REPO_URL}`,
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

// Go counts tables when it loads or exports a database and rows when it exports one table or result
export function progressText(verb: string, p: Progress | null): string {
  if (!p?.label) return `${verb}...`;
  return p.total > 0 ? `${verb} ${p.label} - ${p.done} of ${p.total}` : `${verb} ${p.label} - ${p.done}`;
}

function getWailsBridge() {
  const bridge = window.go?.main?.App;
  if (!bridge) {
    throw new Error('IPC bridge not available');
  }
  return bridge;
}

function App() {
  const [tables, setTables] = useState<string[]>([]);
  const [dbName, setDbName] = useState('');
  const [source, setSource] = useState('');
  const [filter, setFilter] = useState('');
  const [selectedTable, setSelectedTable] = useState('');
  const [rows, setRows] = useState<Row[]>([]);
  const [rowCount, setRowCount] = useState(0);
  const [schema, setSchema] = useState<Column[]>([]);
  const [view, setView] = useState<View>('data');
  const [limit, setLimit] = useState(ROW_LIMITS[0]);
  const [status, setStatus] = useState('No database loaded');
  const [error, setError] = useState('');
  const [job, setJob] = useState(''); // verb of the running load/export ("" = none)
  const [progress, setProgress] = useState<Progress | null>(null);
  const [theme, setThemeState] = useState<Theme>('system');
  const [openMenu, setOpenMenu] = useState<MenuName | null>(null);
  const [about, setAbout] = useState<string[] | null>(null);
  const [search, setSearch] = useState('');
  const [sel, setSel] = useState<{ row: Row; col: string } | null>(null); // selected cell
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null); // open copy menu
  const [copied, setCopied] = useState('');
  const [sql, setSql] = useState('');
  const [result, setResult] = useState<QueryResult | null>(null);
  const [resultSql, setResultSql] = useState(''); // SQL of the result shown (what "Export SQL result" writes)
  const started = useRef(false);

  useEffect(() => {
    if (!menu && !openMenu) return;
    const close = () => {
      setMenu(null);
      setOpenMenu(null);
    };
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && close();
    window.addEventListener('click', close);
    window.addEventListener('keydown', onKey);
    return () => {
      window.removeEventListener('click', close);
      window.removeEventListener('keydown', onKey);
    };
  }, [menu, openMenu]);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
  }, [theme]);

  useEffect(() => window.runtime?.EventsOn?.('progress', setProgress), []);

  // startup: saved theme and the file from the command line or MDB2SQL_DB_PATH
  useEffect(() => {
    if (started.current) return; // StrictMode runs effects twice in development
    started.current = true;
    const bridge = window.go?.main?.App;
    bridge?.GetTheme?.().then((t) => t && setThemeState(t)).catch(() => {});
    bridge?.StartupPath?.().then((p) => p && openPath(p)).catch(fail);
  }, []);

  useEffect(() => {
    if (!about) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setAbout(null);
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [about]);

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

  function chooseTheme(t: Theme) {
    setThemeState(t);
    window.go?.main?.App?.SetTheme?.(t)?.catch(fail);
  }

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
    try {
      const bridge = getWailsBridge();
      let path = '';
      if (pick && bridge.SelectDatabase) {
        path = await bridge.SelectDatabase();
        if (!path) return; // dialog cancelled
      }
      await openPath(path);
    } catch (err) {
      fail(err, 'Error loading database');
    }
  }

  async function openPath(path: string) {
    setError('');
    setJob('Loading');
    setProgress(null);
    setStatus('Loading...');
    try {
      const bridge = getWailsBridge();
      setTables([]);
      setSelectedTable('');
      setRows([]);
      setSchema([]);
      setResult(null);
      const tableList = (await bridge.LoadDatabase(path)) ?? [];
      // Go knows which file an empty path resolved to (MDB2SQL_DB_PATH or the bundled sample)
      const name = (await bridge.DatabaseName?.()) || path.split(/[\\/]/).pop() || 'sample.duckdb';
      setSource((await bridge.SourceKind?.()) || '');
      setDbName(name);
      setTables(tableList);
      setFilter('');
      setStatus(`Loaded: ${name} (${tableList.length} tables)`);
      if (tableList.length > 0) {
        await loadTable(tableList[0], limit);
        setSql(`SELECT * FROM "${tableList[0].replace(/"/g, '""')}" LIMIT 100`);
      }
    } catch (err) {
      setDbName('');
      setSource('');
      fail(err, 'Error loading database');
    } finally {
      setJob('');
    }
  }

  async function loadTable(tableName: string, rowLimit: number) {
    try {
      setError('');
      setSelectedTable(tableName);
      setSel(null);
      setCopied('');
      if (view === 'sql') setView('data');
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
    if (view === 'sql') runSql(rowLimit);
    else if (selectedTable) loadTable(selectedTable, rowLimit);
  }

  async function runSql(rowLimit = limit) {
    if (!sql.trim()) return;
    setError('');
    setSel(null);
    try {
      const bridge = getWailsBridge();
      if (!bridge.RunQuery) throw new Error('IPC bridge not available');
      const res = await bridge.RunQuery(sql, rowLimit);
      setResult({ columns: res.columns ?? [], rows: res.rows ?? [], more: res.more });
      setResultSql(sql);
    } catch (err) {
      setResult(null);
      fail(err);
    }
  }

  // every export asks for the file in Go (native dialog) and runs there, with progress events and Cancel
  async function runExport(what: string, call: () => Promise<string> | undefined) {
    setOpenMenu(null);
    setError('');
    setJob('Exporting');
    setProgress(null);
    try {
      const saved = await call();
      if (saved) setStatus(`Exported ${what} to ${saved}`);
    } catch (err) {
      fail(err);
    } finally {
      setJob('');
    }
  }

  const bridge = window.go?.main?.App;
  const exportItems = [
    { label: 'Database as DuckDB (.duckdb)', on: tables.length > 0, run: () => runExport(dbName, () => bridge?.ExportDatabase?.('duckdb')) },
    { label: 'Database as SQLite (.sqlite)', on: tables.length > 0, run: () => runExport(dbName, () => bridge?.ExportDatabase?.('sqlite')) },
    { label: 'Database as Excel (.xlsx, one sheet per table)', on: tables.length > 0, run: () => runExport(dbName, () => bridge?.ExportDatabase?.('xlsx')) },
    { label: 'Current table as CSV', on: !!selectedTable, run: () => runExport(selectedTable, () => bridge?.ExportTable?.(selectedTable, 'csv')) },
    { label: 'Current table as Excel (.xlsx)', on: !!selectedTable, run: () => runExport(selectedTable, () => bridge?.ExportTable?.(selectedTable, 'xlsx')) },
    { label: 'SQL result as CSV', on: !!resultSql, run: () => runExport('SQL result', () => bridge?.ExportQuery?.(resultSql, 'csv')) },
    { label: 'SQL result as Excel (.xlsx)', on: !!resultSql, run: () => runExport('SQL result', () => bridge?.ExportQuery?.(resultSql, 'xlsx')) },
  ];

  const visibleTables = useMemo(() => {
    const f = filter.trim().toLowerCase();
    return f ? tables.filter((t) => t.toLowerCase().includes(f)) : tables;
  }, [tables, filter]);

  // schema order = database column order (Go maps reach JS sorted by key); also gives empty tables a header
  const tableColumns = schema.length > 0 ? schema.map((c) => c.name) : Object.keys(rows[0] ?? {});
  const gridColumns = view === 'sql' ? (result?.columns ?? []) : tableColumns;
  const gridRows = view === 'sql' ? (result?.rows ?? []) : rows;
  const visibleRows = useMemo(() => searchRows(gridRows, gridColumns, search), [gridRows, gridColumns, search]);
  const copyCell = () => sel && copyText(cellText(sel.row[sel.col]), 'value');
  const copyRow = (withHeader: boolean) =>
    sel && copyText(rowToTsv(gridColumns, sel.row, withHeader), withHeader ? 'row with header' : 'row');
  const busy = job !== '';

  const toggleMenu = (name: MenuName) => (e: React.MouseEvent) => {
    e.stopPropagation(); // the window click handler would close it again
    setMenu(null);
    setOpenMenu(openMenu === name ? null : name);
  };

  const exportMenu = (
    <div className="dropdown" role="menu" aria-label="Export">
      {exportItems.map((it) => (
        <button key={it.label} role="menuitem" disabled={!it.on || busy} onClick={it.run}>
          {it.label}
        </button>
      ))}
    </div>
  );

  const grid = (
    <table>
      <thead>
        <tr>
          {gridColumns.map((col) => (
            <th key={col} scope="col">
              {col}
            </th>
          ))}
        </tr>
      </thead>
      <tbody>
        {visibleRows.map((row, idx) => (
          <tr key={idx} className={sel?.row === row ? 'selected' : undefined}>
            {gridColumns.map((col) => (
              <td
                key={col}
                className={typeof row[col] === 'number' ? 'num' : undefined}
                aria-selected={sel?.row === row && sel.col === col ? 'true' : undefined}
                onClick={() => setSel({ row, col })}
                onContextMenu={(e) => {
                  e.preventDefault();
                  setOpenMenu(null);
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
  );

  return (
    <div className="app">
      <header className="top">
        <nav className="menubar" aria-label="Main menu">
          <div className="menu-root">
            <button aria-haspopup="menu" aria-expanded={openMenu === 'file'} onClick={toggleMenu('file')}>
              File
            </button>
            {openMenu === 'file' && (
              <div className="dropdown" role="menu" aria-label="File">
                <button role="menuitem" disabled={busy} onClick={() => loadDatabase(true)}>
                  Open database...
                </button>
                <button role="menuitem" disabled={busy} onClick={() => loadDatabase(false)}>
                  Open sample data
                </button>
                <hr />
                <p className="menu-title">Export</p>
                {exportItems.map((it) => (
                  <button key={it.label} role="menuitem" disabled={!it.on || busy} onClick={it.run}>
                    {it.label}
                  </button>
                ))}
                <hr />
                <button role="menuitem" onClick={() => window.runtime?.Quit?.()}>
                  Exit
                </button>
              </div>
            )}
          </div>
          <div className="menu-root">
            <button aria-haspopup="menu" aria-expanded={openMenu === 'settings'} onClick={toggleMenu('settings')}>
              Settings
            </button>
            {openMenu === 'settings' && (
              <div className="dropdown" role="menu" aria-label="Settings">
                <p className="menu-title">Theme</p>
                {THEMES.map((t) => (
                  <button key={t.value} role="menuitemradio" aria-checked={theme === t.value} onClick={() => chooseTheme(t.value)}>
                    <span className="check">{theme === t.value ? '✓' : ''}</span>
                    {t.label}
                  </button>
                ))}
              </div>
            )}
          </div>
          <div className="menu-root">
            <button aria-haspopup="menu" aria-expanded={openMenu === 'help'} onClick={toggleMenu('help')}>
              Help
            </button>
            {openMenu === 'help' && (
              <div className="dropdown" role="menu" aria-label="Help">
                <button role="menuitem" onClick={openAbout}>
                  About
                </button>
              </div>
            )}
          </div>
        </nav>
        <div className="toolbar">
          <h1>mdb2sql</h1>
          <button className="primary" onClick={() => loadDatabase(true)} disabled={busy}>
            Load database
          </button>
          <button onClick={() => loadDatabase(false)} disabled={busy} title="MDB2SQL_DB_PATH or data/sample.duckdb">
            Sample data
          </button>
          <div className="menu-root">
            <button aria-haspopup="menu" aria-expanded={openMenu === 'export'} onClick={toggleMenu('export')} disabled={busy}>
              Export
            </button>
            {openMenu === 'export' && exportMenu}
          </div>
        </div>
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
                title={table}
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
        {tables.length === 0 ? (
          <p className="empty">Open a database (.duckdb, .db, .sqlite, .mdb, .accdb) to browse its tables.</p>
        ) : (
          <>
            <div className="content-bar">
              <h2>{view === 'sql' ? 'SQL' : selectedTable}</h2>
              <div className="tabs" role="tablist" aria-label="Table view">
                {(['data', 'schema', 'sql'] as View[]).map((v) => (
                  <button key={v} role="tab" aria-selected={view === v} onClick={() => setView(v)}>
                    {v === 'data' ? 'Data' : v === 'schema' ? `Schema (${schema.length})` : 'SQL'}
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

            {view === 'sql' && (
              <div className="sql-bar">
                <textarea
                  aria-label="SQL"
                  spellCheck={false}
                  value={sql}
                  onChange={(e) => setSql(e.target.value)}
                  onKeyDown={(e) => {
                    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
                      e.preventDefault();
                      runSql();
                    }
                  }}
                />
                <button className="primary" onClick={() => runSql()} title="Ctrl+Enter">
                  Run
                </button>
              </div>
            )}

            {/* tabIndex: the scroll area must be reachable and scrollable by keyboard */}
            <div
              className="table-container"
              tabIndex={0}
              role="region"
              aria-label={`${view === 'sql' ? 'SQL result' : selectedTable} ${view}`}
              onKeyDown={(e) => {
                // Ctrl+C copies the selected cell, unless the user marked text with the mouse (native copy)
                if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'c' && sel && !window.getSelection()?.toString()) {
                  e.preventDefault();
                  copyCell();
                }
              }}
            >
              {view === 'schema' ? (
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
              ) : (
                grid
              )}
              {view === 'data' && visibleRows.length === 0 && (
                <p className="empty">{rows.length === 0 ? 'This table has no rows.' : 'No loaded row matches the search.'}</p>
              )}
              {view === 'sql' && !result && <p className="empty">Write a query and press Run (Ctrl+Enter).</p>}
            </div>

            <footer className="info">
              {view === 'sql'
                ? result && `SQL result: ${result.rows.length} rows${result.more ? ` (limit ${limit}; export writes all rows)` : ''}`
                : `${selectedTable}: Showing ${rows.length} of ${rowCount} rows`}
              {search.trim() && view !== 'schema' && ` - ${visibleRows.length} match "${search.trim()}"`}
              {copied && ` - ${copied}`}
            </footer>
          </>
        )}
      </main>

      <footer className="statusbar">
        <p className={error ? 'status error' : 'status'} role="status" aria-live="polite" title={error || status}>
          {error || status}
        </p>
        {source && <span className="source" title="Reader used to open the file">Opened via {source}</span>}
      </footer>

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

      {busy && (
        <div className="backdrop">
          <div className="about progress" role="dialog" aria-modal="true" aria-label={job}>
            <p>{progressText(job, progress)}</p>
            <progress max={progress?.total || undefined} value={progress?.total ? progress.done : undefined} />
            <button autoFocus onClick={() => bridge?.CancelJob?.()}>
              Cancel
            </button>
          </div>
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
