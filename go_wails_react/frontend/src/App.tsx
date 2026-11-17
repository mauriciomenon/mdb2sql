// Visualizador de bancos (DuckDB, SQLite, Access): abre um arquivo, lista tabelas, mostra dados, schema e SQL, exporta
// !T: Single-screen viewer talking to Go through the Wails IPC bridge (window.go.main.App)

import { Fragment, useEffect, useMemo, useRef, useState, version as reactVersion } from 'react';
import './App.css';

type Row = Record<string, unknown>;
type Column = { name: string; type: string; null: string };
export type Theme = 'system' | 'light' | 'dark';
type View = 'data' | 'schema' | 'sql';
type MenuName = 'file' | 'settings' | 'help' | 'export';
type QueryResult = { columns: string[]; rows: Row[]; more: boolean };
type Progress = { done: number; total: number; label: string };
export type AppInfo = { version: string; build?: string; buildDate?: string; go: string; wails: string; duckdb: string; access?: string };
export type Filter = { column: string; value: unknown }; // column = exact value, applied in the database query

declare global {
  interface Window {
    go?: {
      main: {
        App: {
          LoadDatabase: (dbPath: string) => Promise<string[]>;
          GetTableData: (tableName: string, limit: number, filters: Filter[]) => Promise<Row[]>;
          GetRowCount: (tableName: string, filters: Filter[]) => Promise<number>;
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

const ABOUT_TAGLINE = 'Visualiza e exporta bancos DuckDB, SQLite e Microsoft Access: tabelas, esquema, dados e SQL.';
const ACCESS_READERS: Record<string, string> = {
  'Access ODBC': 'ODBC do Microsoft Access (driver instalado); reserva: mdbtools embutido',
  mdbtools: 'mdbtools embutido (driver ODBC do Access nao instalado)',
};

// Linhas (rotulo, valor) do dialogo Sobre; versao de wails.json, numero/data do build gravados pelo build, runtimes
// lidos em execucao. Valor que comeca com https:// vira link aberto no navegador padrao.
// !T: Text is Portuguese on purpose (owner's spec)
export function aboutRows(info: AppInfo): [string, string][] {
  const v = (s: string) => s.replace(/^v/, '');
  return [
    ['Build', info.build ? `${info.build} (${info.buildDate})` : 'dev'],
    ['Stack', `Go ${info.go} + Wails ${v(info.wails)} + React ${reactVersion}`],
    ['Banco', `DuckDB ${v(info.duckdb)}`],
    ['Leitor Access', ACCESS_READERS[info.access ?? ''] ?? 'indisponivel neste computador'],
    ['Autor', 'Mauricio Menon'],
    ['Licenca', 'GPL v2 ou posterior'],
    ['GitHub', 'https://github.com/mauriciomenon/mdb2sql'],
    ['GitLab', 'https://gitlab.com/mauricio.menon/mdb2sql'],
  ];
}

// Texto do filtro ativo: Filtro: SIGLA = 'U9A' | ID = 7 | NOTE IS NULL
export function filterLabel(f: Filter): string {
  if (f.value === null || f.value === undefined) return `${f.column} IS NULL`;
  return `${f.column} = ${typeof f.value === 'string' ? `'${f.value}'` : String(f.value)}`;
}

// Um filtro por coluna: filtrar de novo a mesma coluna troca o valor (dois valores com AND nao casariam nada)
export const withFilter = (filters: Filter[], f: Filter) => [...filters.filter((x) => x.column !== f.column), f];

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

// Minusculas sem acentos (NFD e remove as marcas combinantes): "EXCITAÇÃO" -> "excitacao", "ñ" -> "n"
export const normalizeText = (s: string) => s.toLowerCase().normalize('NFD').replace(/\p{M}/gu, '');

// Palavras da busca ja normalizadas; vazio = sem filtro
export const searchWords = (query: string) => normalizeText(query).split(/\s+/).filter(Boolean);

// Casa quando TODAS as palavras aparecem no texto (uma celula ou um nome de tabela), em qualquer ordem
export const hasAllWords = (text: string, words: string[]) => words.every((w) => text.includes(w));

// Celulas normalizadas de cada linha; montado uma vez por carga, nao a cada tecla
export const rowSearchText = (rows: Row[], columns: string[]) =>
  rows.map((r) => columns.map((c) => normalizeText(cellText(r[c]))));

// Linha casa quando UMA celula contem todas as palavras (palavras so em celulas diferentes nao casam)
export function searchRows(rows: Row[], columns: string[], query: string, index?: string[][]): Row[] {
  const words = searchWords(query);
  if (words.length === 0) return rows;
  const cells = index ?? rowSearchText(rows, columns);
  return rows.filter((_, i) => cells[i].some((cell) => hasAllWords(cell, words)));
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
  const [about, setAbout] = useState<AppInfo | null>(null);
  const [search, setSearch] = useState('');
  const [sel, setSel] = useState<{ row: Row; col: string } | null>(null); // selected cell
  // open context menu: of the selected cell, or of a column header (header = column name)
  const [menu, setMenu] = useState<{ x: number; y: number; header?: string } | null>(null);
  const [filters, setFilters] = useState<Filter[]>([]); // of the current table, applied by Go in the query
  const [totalCount, setTotalCount] = useState(0); // rows of the table without filters
  const [hidden, setHidden] = useState<Set<string>>(new Set()); // hidden columns of the current table
  const [colsOpen, setColsOpen] = useState(false); // "Colunas..." dialog
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
    if (!about && !colsOpen) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return;
      setAbout(null);
      setColsOpen(false);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [about, colsOpen]);

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
      setAbout(await bridge.GetAppInfo());
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

  // keep = filtros a manter (mesma tabela: novo limite ou filtro); sem keep e outra tabela: filtros e colunas ocultas zeram
  async function loadTable(tableName: string, rowLimit: number, keep?: Filter[]) {
    const tableFilters = keep ?? [];
    try {
      setError('');
      setSelectedTable(tableName);
      setSel(null);
      setCopied('');
      setFilters(tableFilters);
      if (!keep) setHidden(new Set());
      if (view === 'sql') setView('data');
      const bridge = getWailsBridge();
      const [data, count, cols, total] = await Promise.all([
        bridge.GetTableData(tableName, rowLimit, tableFilters),
        bridge.GetRowCount(tableName, tableFilters),
        bridge.GetTableSchema ? bridge.GetTableSchema(tableName) : Promise.resolve([]),
        tableFilters.length > 0 ? bridge.GetRowCount(tableName, []) : null,
      ]);
      setRows(data ?? []); // Go sends null for an empty table
      setRowCount(count);
      setTotalCount(total ?? count);
      setSchema(cols ?? []);
    } catch (err) {
      fail(err);
    }
  }

  const applyFilters = (next: Filter[]) => loadTable(selectedTable, limit, next);

  const setColumnHidden = (col: string, hide: boolean) =>
    setHidden((old) => {
      const next = new Set(old);
      if (hide) next.add(col);
      else next.delete(col);
      return next;
    });

  function changeLimit(rowLimit: number) {
    setLimit(rowLimit);
    if (view === 'sql') runSql(rowLimit);
    else if (selectedTable) loadTable(selectedTable, rowLimit, filters);
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
    { group: 'db', label: 'Database as DuckDB (.duckdb)', on: tables.length > 0, run: () => runExport(dbName, () => bridge?.ExportDatabase?.('duckdb')) },
    { group: 'db', label: 'Database as SQLite (.sqlite)', on: tables.length > 0, run: () => runExport(dbName, () => bridge?.ExportDatabase?.('sqlite')) },
    { group: 'db', label: 'Database as Excel (.xlsx, one sheet per table)', on: tables.length > 0, run: () => runExport(dbName, () => bridge?.ExportDatabase?.('xlsx')) },
    { group: 'table', label: 'Current table as CSV', on: !!selectedTable, run: () => runExport(selectedTable, () => bridge?.ExportTable?.(selectedTable, 'csv')) },
    { group: 'table', label: 'Current table as Excel (.xlsx)', on: !!selectedTable, run: () => runExport(selectedTable, () => bridge?.ExportTable?.(selectedTable, 'xlsx')) },
    { group: 'sql', label: 'SQL result as CSV', on: !!resultSql, run: () => runExport('SQL result', () => bridge?.ExportQuery?.(resultSql, 'csv')) },
    { group: 'sql', label: 'SQL result as Excel (.xlsx)', on: !!resultSql, run: () => runExport('SQL result', () => bridge?.ExportQuery?.(resultSql, 'xlsx')) },
  ];

  const visibleTables = useMemo(() => {
    const words = searchWords(filter);
    return words.length ? tables.filter((t) => hasAllWords(normalizeText(t), words)) : tables;
  }, [tables, filter]);

  // schema order = database column order (Go maps reach JS sorted by key); also gives empty tables a header
  // memoized so the search index below is built once per load, not on every keystroke
  const tableColumns = useMemo(() => (schema.length > 0 ? schema.map((c) => c.name) : Object.keys(rows[0] ?? {})), [schema, rows]);
  const gridColumns = useMemo(() => (view === 'sql' ? (result?.columns ?? []) : tableColumns), [view, result, tableColumns]);
  const gridRows = useMemo(() => (view === 'sql' ? (result?.rows ?? []) : rows), [view, result, rows]);
  const searching = search.trim() !== '';
  const searchIndex = useMemo(() => (searching ? rowSearchText(gridRows, gridColumns) : undefined), [searching, gridRows, gridColumns]);
  const visibleRows = useMemo(() => searchRows(gridRows, gridColumns, search, searchIndex), [gridRows, gridColumns, search, searchIndex]);
  // hidden columns only leave the Data grid: search, copy row and exports still use every column
  const shownColumns = useMemo(() => (view === 'data' ? gridColumns.filter((c) => !hidden.has(c)) : gridColumns), [view, gridColumns, hidden]);
  const hiddenCount = gridColumns.length - shownColumns.length;
  const copyCell = () => sel && copyText(cellText(sel.row[sel.col]), 'value');
  const copyRow = (withHeader: boolean) =>
    sel && copyText(rowToTsv(gridColumns, sel.row, withHeader), withHeader ? 'row with header' : 'row');
  const busy = job !== '';

  const toggleMenu = (name: MenuName) => (e: React.MouseEvent) => {
    e.stopPropagation(); // the window click handler would close it again
    setMenu(null);
    setOpenMenu(openMenu === name ? null : name);
  };

  const grid = (
    <table>
      <thead>
        <tr>
          {shownColumns.map((col) => (
            <th
              key={col}
              scope="col"
              onContextMenu={
                view === 'data'
                  ? (e) => {
                      e.preventDefault();
                      setOpenMenu(null);
                      setMenu({ x: e.clientX, y: e.clientY, header: col });
                    }
                  : undefined
              }
            >
              {col}
            </th>
          ))}
        </tr>
      </thead>
      <tbody>
        {visibleRows.map((row, idx) => (
          <tr key={idx} className={sel?.row === row ? 'selected' : undefined}>
            {shownColumns.map((col) => (
              <td
                key={col}
                className={typeof row[col] === 'number' ? 'num' : undefined}
                aria-selected={sel?.row === row && sel.col === col ? 'true' : undefined}
                tabIndex={-1} // focusable: keyboard and UI Automation can select a cell and open its menu (menu key)
                onFocus={() => setSel({ row, col })}
                onClick={() => setSel({ row, col })}
                onContextMenu={(e) => {
                  e.preventDefault();
                  setOpenMenu(null);
                  setSel({ row, col });
                  // the menu key may report no position: open the menu under the cell
                  const r = e.currentTarget.getBoundingClientRect();
                  setMenu(e.clientX || e.clientY ? { x: e.clientX, y: e.clientY } : { x: r.left + 8, y: r.bottom });
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
                <button role="menuitem" disabled={busy} onClick={() => loadDatabase(false)} title="MDB2SQL_DB_PATH or data/sample.duckdb">
                  Open sample data
                </button>
                <hr />
                <button role="menuitem" onClick={() => window.runtime?.Quit?.()}>
                  Exit
                </button>
              </div>
            )}
          </div>
          {/* every action lives in one place only: no toolbar copies of the menu items */}
          <div className="menu-root">
            <button aria-haspopup="menu" aria-expanded={openMenu === 'export'} onClick={toggleMenu('export')}>
              Export
            </button>
            {openMenu === 'export' && (
              <div className="dropdown" role="menu" aria-label="Export">
                {exportItems.map((it, i) => (
                  <Fragment key={it.label}>
                    {i > 0 && exportItems[i - 1].group !== it.group && <hr />}
                    <button role="menuitem" disabled={!it.on || busy} onClick={it.run}>
                      {it.label}
                    </button>
                  </Fragment>
                ))}
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
      </header>

      <nav className="sidebar" aria-label="Tables">
        <input
          type="search"
          placeholder={`Filter ${tables.length} tables`}
          aria-label="Filter tables"
          title="All words, any order, ignores case and accents"
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
          <p className="empty">File &gt; Open database: .duckdb, .db, .sqlite, .mdb, .accdb</p>
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
                title="Shows the loaded rows (see Rows) with a cell that contains every word, in any order; ignores case and accents"
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
              <button
                onClick={() => setColsOpen(true)}
                disabled={view !== 'data' || gridColumns.length === 0}
                title="Mostrar ou ocultar colunas. A pesquisa e o Export continuam usando todas as colunas."
              >
                Colunas...
              </button>
            </div>

            {view === 'data' && filters.length > 0 && (
              <div className="filters" role="group" aria-label="Filtros ativos">
                {filters.map((f) => (
                  <span key={f.column} className="chip">
                    <span title={`Filtro: ${filterLabel(f)}`}>Filtro: {filterLabel(f)}</span>
                    <button
                      aria-label={`Remover filtro ${f.column}`}
                      title="Remover este filtro"
                      onClick={() => applyFilters(filters.filter((x) => x !== f))}
                    >
                      ×
                    </button>
                  </span>
                ))}
                <button onClick={() => applyFilters([])}>Limpar filtros</button>
              </div>
            )}

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
                <p className="empty">
                  {rows.length > 0 ? 'No loaded row matches the search.' : filters.length > 0 ? 'No row matches the filters.' : 'This table has no rows.'}
                </p>
              )}
              {view === 'data' && visibleRows.length > 0 && shownColumns.length === 0 && (
                <p className="empty">Todas as colunas estao ocultas (Colunas... &gt; Mostrar todas).</p>
              )}
              {view === 'sql' && !result && <p className="empty">Write a query and press Run (Ctrl+Enter).</p>}
            </div>

            <footer className="info">
              {view === 'sql'
                ? result && `SQL result: ${result.rows.length} rows${result.more ? ` (limit ${limit}; export writes all rows)` : ''}`
                : `${selectedTable}: Showing ${rows.length} of ${rowCount} rows` +
                  (filters.length > 0 ? ` matching the filters (${totalCount} in the table)` : '')}
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
        {hiddenCount > 0 && (
          <span className="source" title="Colunas... > Mostrar todas">
            {hiddenCount} {hiddenCount === 1 ? 'coluna oculta' : 'colunas ocultas'}
          </span>
        )}
        {source && <span className="source" title="Reader used to open the file">Opened via {source}</span>}
      </footer>

      {menu?.header !== undefined && (
        <div
          className="menu"
          role="menu"
          aria-label="Coluna"
          style={{ left: Math.min(menu.x, window.innerWidth - 220), top: Math.min(menu.y, window.innerHeight - 120) }}
        >
          <button role="menuitem" autoFocus onClick={() => setColumnHidden(menu.header!, true)}>
            Ocultar esta coluna
          </button>
          <button role="menuitem" onClick={() => setColsOpen(true)}>
            Colunas...
          </button>
          <button role="menuitem" disabled={hiddenCount === 0} onClick={() => setHidden(new Set())}>
            Mostrar todas
          </button>
        </div>
      )}

      {menu && menu.header === undefined && (
        <div
          className="menu"
          role="menu"
          aria-label="Cell"
          style={{ left: Math.min(menu.x, window.innerWidth - 220), top: Math.min(menu.y, window.innerHeight - 190) }}
        >
          {view === 'data' && (
            <>
              <button role="menuitem" onClick={() => sel && applyFilters(withFilter(filters, { column: sel.col, value: sel.row[sel.col] ?? null }))}>
                Filtrar por este valor
              </button>
              <button role="menuitem" disabled={filters.length === 0} onClick={() => applyFilters([])}>
                Limpar filtros
              </button>
              <hr />
            </>
          )}
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
            <h2 id="about-title">
              mdb2sql <span className="version">{about.version}</span>
            </h2>
            <p className="tagline">{ABOUT_TAGLINE}</p>
            <dl>
              {aboutRows(about).map(([label, value]) => (
                <div key={label}>
                  <dt>{label}</dt>
                  <dd>
                    {value.startsWith('https://') ? (
                      <a
                        href={value}
                        title="Abrir no navegador padrao"
                        onClick={(e) => {
                          e.preventDefault(); // never navigate the app's own webview away
                          window.runtime?.BrowserOpenURL?.(value);
                        }}
                      >
                        {value}
                      </a>
                    ) : (
                      value
                    )}
                  </dd>
                </div>
              ))}
            </dl>
            <button className="primary" autoFocus onClick={() => setAbout(null)}>
              Fechar
            </button>
          </div>
        </div>
      )}

      {colsOpen && (
        <div className="backdrop" onClick={(e) => e.target === e.currentTarget && setColsOpen(false)}>
          <div className="about columns" role="dialog" aria-modal="true" aria-labelledby="cols-title">
            <h2 id="cols-title">Colunas de {selectedTable}</h2>
            <p className="tagline" title="A pesquisa e o Export continuam usando todas as colunas.">
              {shownColumns.length} de {gridColumns.length} visiveis
            </p>
            <div className="col-actions">
              <button onClick={() => setHidden(new Set())}>Mostrar todas</button>
              <button onClick={() => setHidden(new Set(gridColumns))}>Ocultar todas</button>
            </div>
            <div className="col-list">
              {gridColumns.map((col) => (
                <label key={col} title={col}>
                  <input type="checkbox" checked={!hidden.has(col)} onChange={(e) => setColumnHidden(col, !e.target.checked)} />
                  {col}
                </label>
              ))}
            </div>
            <button className="primary" autoFocus onClick={() => setColsOpen(false)}>
              Fechar
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

export default App;
