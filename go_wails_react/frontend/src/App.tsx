// Visualizador de bancos (Access, SQLite, DuckDB): abre um arquivo, lista tabelas, mostra dados, schema e SQL, exporta
// !T: Single-screen viewer talking to Go through the Wails IPC bridge (window.go.main.App). Every visible text comes
// from the catalogs in ../../i18n (see i18n.ts)

import { Fragment, useEffect, useLayoutEffect, useMemo, useRef, useState, version as reactVersion } from 'react';
import './App.css';
import { LANGS, translate, translateN, type Lang, type T, type TN } from './i18n';

type Row = Record<string, unknown>;
type Column = { name: string; type: string; null: string };
export type Theme = 'system' | 'light' | 'dark';
type View = 'data' | 'schema' | 'sql';
type Scope = 'table' | 'all'; // Data tab search: the open table or all tables
type TableHits = { table: string; rows: number };
type MenuName = 'file' | 'exportBar' | 'view' | 'settings' | 'help';
type QueryResult = { columns: string[]; rows: Row[]; more: boolean };
type Progress = { done: number; total: number; label: string };
type Conversion = { done: boolean; saved: string };
// Linux without X11 (display.go): three short lines, the install command and the README help link
type DisplayWarning = { text: string; missing: string; distro: string; command: string; help: string };
export type AppInfo = {
  version: string;
  build?: string;
  buildDate?: string;
  go: string;
  wails: string;
  duckdb: string;
  access?: string; // reader an Access file would use now: "Access ODBC", "mdbtools" or ""
  mdbtools?: string; // "mdbtools 1.0.1" (embedded) or "mdbtools" (on PATH: mdbtoolsSystem); "" = none
  mdbtoolsSystem?: boolean;
};
export type Filter = { column: string; value: unknown }; // column = exact value, applied in the database query

declare global {
  interface Window {
    go?: {
      main: {
        App: {
          LoadDatabase: (dbPath: string) => Promise<string[]>;
          GetTableData: (tableName: string, limit: number, filters: Filter[], search: string) => Promise<Row[]>;
          GetRowCount: (tableName: string, filters: Filter[], search: string) => Promise<number>;
          GetTableSchema?: (tableName: string) => Promise<Column[]>;
          SelectDatabase?: () => Promise<string>;
          DatabaseName?: () => Promise<string>;
          DatabasePath?: () => Promise<string>;
          SourceKind?: () => Promise<string>;
          StartupPath?: () => Promise<string>;
          GetAppInfo?: () => Promise<AppInfo>;
          RunQuery?: (query: string, limit: number) => Promise<QueryResult>;
          ExportDatabase?: (format: string) => Promise<string>;
          ExportTable?: (table: string, format: string, filters: Filter[], search: string) => Promise<string>;
          ExportQuery?: (query: string, format: string) => Promise<string>;
          CancelJob?: () => Promise<void>;
          GetTheme?: () => Promise<Theme>;
          GetLogOpen?: () => Promise<boolean>;
          SetLogOpen?: (open: boolean) => Promise<void>;
          SetTheme?: (theme: Theme) => Promise<void>;
          GetLanguage?: () => Promise<Lang>;
          SetLanguage?: (lang: Lang) => Promise<void>;
          GetShowNull?: () => Promise<boolean>;
          SetShowNull?: (show: boolean) => Promise<void>;
          GetSearchScope?: () => Promise<Scope>;
          SetSearchScope?: (scope: Scope) => Promise<void>;
          SearchAllTables?: (search: string) => Promise<TableHits[]>;
          TableCounts?: () => Promise<number[]>;
          PendingConversion?: () => Promise<string>;
          RememberedChoice?: () => Promise<string>;
          ResolveConversion?: (choice: string, remember: boolean) => Promise<Conversion>;
          CloseDatabase?: () => Promise<void>;
          DisplayWarning?: () => Promise<DisplayWarning | null>;
        };
      };
    };
    runtime?: {
      BrowserOpenURL?: (url: string) => void;
      ClipboardSetText?: (text: string) => Promise<boolean>;
      EventsOn?: (name: string, cb: (data: any) => void) => () => void;
      OnFileDrop?: (cb: (x: number, y: number, paths: string[]) => void, useDropTarget: boolean) => void;
      OnFileDropOff?: () => void;
      Quit?: () => void;
    };
  }
}

const ROW_LIMITS = [100, 500, 1000]; // more would render too many cells (130-column tables)
const TYPING_PAUSE = 300; // ms without typing before the table list filter and the Data search apply (Enter: at once)
const THEMES: Theme[] = ['system', 'light', 'dark'];
const SCOPES: Scope[] = ['table', 'all'];
const VIEWS: View[] = ['data', 'schema', 'sql']; // tab order: Ctrl+1, Ctrl+2, Ctrl+3

// Window row of About: the WebView2 version from the user agent (Edg/<version>); WebKitGTK on Linux
export function webviewName(userAgent: string): string {
  const edge = /\bEdg\/([\d.]+)/.exec(userAgent);
  return edge ? `WebView2 ${edge[1]}` : /AppleWebKit/.test(userAgent) ? 'WebKitGTK' : '';
}

// How an Access file is read now: the ODBC driver (embedded mdbtools as fallback), mdbtools only, or nothing
function accessReading(info: AppInfo, t: T): string {
  const mdb = info.mdbtools ?? '';
  if (info.access === 'Access ODBC') return mdb ? t('about.accessOdbc', mdb) : t('about.accessOdbcOnly');
  if (info.access === 'mdbtools') return t(info.mdbtoolsSystem ? 'about.accessSystem' : 'about.accessEmbedded', mdb);
  return t('about.reader.none');
}

// Linhas (rotulo, valor) do dialogo Sobre, as do Rust (Build, Stack, Janela, Bancos, Leitura do Access, Autor,
// Licenca, links); versao de wails.json, numero/data do build gravados pelo build, runtimes lidos em execucao. Valor
// que comeca com https:// vira link aberto no navegador padrao.
export function aboutRows(info: AppInfo, t: T, userAgent = navigator.userAgent): [string, string][] {
  const v = (s: string) => s.replace(/^v/, '');
  return [
    [t('about.build'), info.build ? `${info.build} (${info.buildDate})` : 'dev'],
    [t('about.stack'), `Go ${info.go} + Wails ${v(info.wails)} + React ${reactVersion}`],
    [t('about.window'), webviewName(userAgent)],
    [t('about.engines'), `DuckDB ${v(info.duckdb)}`], // SQLite files are read by DuckDB (its sqlite extension)
    [t('about.access'), accessReading(info, t)],
    [t('about.author'), 'Mauricio Menon'],
    [t('about.license'), t('about.licenseText')],
    ['GitHub', 'https://github.com/mauriciomenon/mdb2sql'],
    ['GitLab', 'https://gitlab.com/mauricio.menon/mdb2sql'],
  ];
}

// Texto do filtro ativo: SIGLA = 'U9A' | ID = 7 | NOTE IS NULL
export function filterLabel(f: Filter): string {
  if (f.value === null || f.value === undefined) return `${f.column} IS NULL`;
  return `${f.column} = ${typeof f.value === 'string' ? `'${f.value}'` : String(f.value)}`;
}

// Um filtro por coluna: filtrar de novo a mesma coluna troca o valor (dois valores com AND nao casariam nada)
export const withFilter = (filters: Filter[], f: Filter) => [...filters.filter((x) => x.column !== f.column), f];

export const cellText = (v: unknown) => String(v ?? '');

// Schema > Nullable: Go sends YES/NO; shown translated (Sim/Nao, Si/No, Yes/No)
export const nullableText = (v: string, t: T) => (v === 'YES' ? t('schema.yes') : v === 'NO' ? t('schema.no') : v);

// Text a grid cell shows: NULL as nullText (Settings > Show NULL: "NULL" or empty); copy and search use cellText
export const gridText = (v: unknown, nullText: string) => (v === null || v === undefined ? nullText : String(v));

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

// Linha casa quando UMA celula contem todas as palavras (aba SQL; a aba Data pesquisa no banco, em Go)
export function searchRows(rows: Row[], columns: string[], query: string, index?: string[][]): Row[] {
  const words = searchWords(query);
  if (words.length === 0) return rows;
  const cells = index ?? rowSearchText(rows, columns);
  return rows.filter((_, i) => cells[i].some((cell) => hasAllWords(cell, words)));
}

// Go counts tables when it loads or exports a database and rows when it exports one table or result
export function progressText(verb: string, p: Progress | null, t: T): string {
  if (!p?.label) return verb;
  return p.total > 0 ? t('progress.of', verb, p.label, p.done, p.total) : t('progress.count', verb, p.label, p.done);
}

// Linha do painel Log: hora local HH:MM:SS + texto
export const logLine = (text: string, at = new Date()) => `${at.toTimeString().slice(0, 8)}  ${text}`;
type LogLevel = 'info' | 'warn' | 'error';
// sql: an error of the SQL tab; cleared: a later query ran fine, so the status bar no longer shows it
type LogEntry = { line: string; text: string; level: LogLevel; sql?: boolean; cleared?: boolean };

// First line of a message (the status bar shows one line; the log keeps the whole text)
export const firstLine = (s: string) => s.split(/\r?\n/).find((l) => l.trim() !== '')?.trim() ?? '';

// Engine error of the SQL tab in one line: 'Parser Error: syntax error at or near "selec"\n\nLINE 1...' becomes
// 'syntax error at or near "selec"'
export const sqlErrorSummary = (s: string) => firstLine(s).replace(/^[A-Za-z ]*Error:\s*/, '');

// Log panel height: about 10% of the window, at least 3 lines of the 13 px log font, at most 25% of the window
export const LOG_MIN = 68;
export const clampLogHeight = (h: number, windowHeight: number) => Math.round(Math.max(LOG_MIN, Math.min(h, windowHeight * 0.25)));

// Status bar with the log collapsed: the last unread error, else the last unread warning, else the status
export function statusLine(entries: LogEntry[], readMark: number, status: string, error: string) {
  const unread = entries.slice(readMark).filter((e) => e.level !== 'info' && !e.cleared);
  const pick = unread.findLast((e) => e.level === 'error') ?? unread.findLast((e) => e.level === 'warn');
  return { text: pick?.text ?? (error || status), level: pick?.level ?? (error ? 'error' : 'info'), unread: unread.length };
}

// Keeps a context menu inside the window: a long column list moves it up (taller than the window, it scrolls)
function keepInWindow(el: HTMLElement | null) {
  if (el) el.style.top = `${Math.max(4, Math.min(el.getBoundingClientRect().top, window.innerHeight - el.offsetHeight - 4))}px`;
}

function getWailsBridge() {
  const bridge = window.go?.main?.App;
  if (!bridge) {
    throw new Error('IPC bridge not available');
  }
  return bridge;
}

function App() {
  const [lang, setLang] = useState<Lang>('en');
  // t reads the language when called, not when its render ran: work started by an older render (the startup file)
  // finishes in the current language
  const langRef = useRef<Lang>(lang);
  langRef.current = lang;
  const t: T = (key, ...args) => translate(langRef.current, key, ...args);
  const tn: TN = (key, n, ...args) => translateN(langRef.current, key, n, ...args); // "1 tabela", "2 tabelas"
  const [tables, setTables] = useState<string[]>([]);
  const [counts, setCounts] = useState<Record<string, number>>({}); // rows of each table (table list, as Zig)
  const [dbName, setDbName] = useState('');
  const [pathText, setPathText] = useState(''); // path field of the top bar (Open/Enter opens it)
  const [pathFocused, setPathFocused] = useState(false);
  const pathRef = useRef<HTMLInputElement>(null);
  const [pathElided, setPathElided] = useState(false); // path longer than the field: its start is hidden
  const [openedPath, setOpenedPath] = useState(''); // the open file, which F5 opens again
  const searchRef = useRef<HTMLInputElement>(null); // Ctrl+F
  const sqlRef = useRef<HTMLTextAreaElement>(null); // Ctrl+3
  const [source, setSource] = useState('');
  const [converted, setConverted] = useState(false);
  const [filter, setFilter] = useState('');
  const [tableFilter, setTableFilter] = useState(''); // filter applied to the table list, after a pause
  const [selectedTable, setSelectedTable] = useState('');
  const [rows, setRows] = useState<Row[]>([]);
  const [rowCount, setRowCount] = useState(0);
  const [schema, setSchema] = useState<Column[]>([]);
  const [view, setView] = useState<View>('data');
  const [limit, setLimit] = useState(ROW_LIMITS[0]);
  const [status, setStatusText] = useState(() => translate('en', 'status.none'));
  const [error, setErrorText] = useState('');
  const [job, setJob] = useState(''); // verb of the running load/export ("" = none)
  const [progress, setProgress] = useState<Progress | null>(null);
  const [theme, setThemeState] = useState<Theme>('system');
  const [showNull, setShowNull] = useState(false); // Settings > Show NULL (off: a NULL cell is empty)
  const [openMenu, setOpenMenu] = useState<MenuName | null>(null);
  const [subOpen, setSubOpen] = useState(false); // File > Export submenu
  useEffect(() => setSubOpen(false), [openMenu]);
  const [about, setAbout] = useState<AppInfo | null>(null);
  const [search, setSearch] = useState('');
  const [tableSearch, setTableSearch] = useState(''); // search applied in the database (Data tab), after a pause
  const [scope, setScope] = useState<Scope>('table'); // where the Data tab searches now
  const [defaultScope, setDefaultScope] = useState<Scope>('table'); // Settings > Default search scope
  const defaultScopeRef = useRef<Scope>('table'); // the same, for openPath started by an older render (startup file)
  // "All tables" result and the search it answers (null = searching or failed)
  const [hits, setHits] = useState<{ search: string; tables: TableHits[] } | null>(null);
  const [searching, setSearching] = useState(false);
  const [sel, setSel] = useState<{ row: Row; col: string } | null>(null); // selected cell
  // open context menu: of the selected cell, of a column header (header = column name) or of the status bar
  const [menu, setMenu] = useState<{ x: number; y: number; header?: string; status?: boolean } | null>(null);
  const [filters, setFilters] = useState<Filter[]>([]); // of the current table, applied by Go in the query
  const [totalCount, setTotalCount] = useState(0); // rows of the table without filters and search
  const [hidden, setHidden] = useState<Set<string>>(new Set()); // hidden columns of the current table
  const [widths, setWidths] = useState<Record<string, number>>({}); // Data columns resized by hand (current table)
  const [colsOpen, setColsOpen] = useState(false); // "Columns..." dialog
  const [copied, setCopied] = useState('');
  const [sql, setSql] = useState('');
  const [result, setResult] = useState<QueryResult | null>(null);
  const [resultSql, setResultSql] = useState(''); // SQL of the result shown (what "Export SQL result" writes)
  const [logLines, setLogLines] = useState<LogEntry[]>([]);
  const [logOpen, setLogOpen] = useState(false); // collapsed by default
  const [readMark, setReadMark] = useState(0); // log lines before this one were seen
  const [logHeight, setLogHeight] = useState(() => clampLogHeight(Math.round(window.innerHeight * 0.1), window.innerHeight));
  const [displayWarn, setDisplayWarn] = useState<DisplayWarning | null>(null); // Linux: X11 missing, on Wayland
  // "save or delete the converted SQLite" question; resolve gets the answer (null = cancel)
  const [ask, setAsk] = useState<{ name: string; resolve: (a: { choice: string; remember: boolean } | null) => void } | null>(null);
  // "whole table or only the n rows found?" before a table export with the search active; resolve(true) = rows found
  const [exportAsk, setExportAsk] = useState<{ table: string; found: number; resolve: (found: boolean | null) => void } | null>(null);
  const started = useRef(false);
  // the functions of the latest render, for listeners registered once (file drop, keyboard shortcuts)
  const latest = useRef<Record<string, (...args: any[]) => unknown>>({});
  // request numbers: an answer that is not the latest one (another table, query or file since) is dropped
  const tableReq = useRef(0);
  const sqlReq = useRef(0);
  const searchReq = useRef(0);
  const countReq = useRef(0);
  const loadedFind = useRef(''); // search of the last table request
  const [shownFind, setShownFind] = useState(''); // search of the rows shown in the Data tab
  const [shownTable, setShownTable] = useState(''); // table of the rows shown (the counts below belong to it)
  const [querying, setQuerying] = useState(false);

  // the log keeps the full text; short = the one line the status bar shows for it
  const addLog = (text: string, level: LogLevel = 'info', short = firstLine(text), sql = false) =>
    setLogLines((old) => [...old, { line: logLine(text), text: short, level, sql }]);
  // every status and error also goes to the Log panel
  const setStatus = (text: string) => {
    setStatusText(text);
    addLog(text);
  };
  const setError = (text: string, short = firstLine(text)) => {
    setErrorText(short);
    if (text) addLog(text, 'error', short);
  };
  // collapse/expand (log header arrow, status bar, View > Log, Ctrl+L); remembered by Go between sessions. What
  // was in the log when it is opened or closed counts as read.
  const logCount = useRef(0);
  logCount.current = logLines.length;
  const toggleLog = (open?: boolean) =>
    setLogOpen((old) => {
      const next = open ?? !old;
      setReadMark(logCount.current);
      if (next !== old) window.go?.main?.App?.SetLogOpen?.(next)?.catch(() => {});
      return next;
    });

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

  useEffect(() => {
    document.documentElement.lang = lang;
  }, [lang]);

  useEffect(() => window.runtime?.EventsOn?.('progress', setProgress), []);
  useEffect(() => window.runtime?.EventsOn?.('log', (text: string) => addLog(text)), []);

  // shortcuts of the Python version (standard item 20): Ctrl+O, Ctrl+F, F5, Ctrl+Q, Ctrl+1/2/3, Ctrl+L here; Ctrl+Enter
  // in the SQL field and Ctrl+C in the grid. The keys are always taken from the webview (F5 would reload the page);
  // with a dialog open they do nothing
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const ctrl = (e.ctrlKey || e.metaKey) && !e.altKey && !e.shiftKey;
      const k = e.key.toLowerCase();
      const action =
        e.key === 'F5' && !e.ctrlKey && !e.altKey && !e.shiftKey ? () => latest.current.reload()
        : !ctrl ? null
        : k === 'o' ? () => latest.current.loadDatabase()
        : k === 'f' ? () => latest.current.focusSearch()
        : k === 'q' ? () => latest.current.quit()
        : k === 'l' ? () => toggleLog()
        : e.key === '1' || e.key === '2' || e.key === '3' ? () => latest.current.showView(VIEWS[Number(e.key) - 1])
        : null;
      if (!action) return;
      e.preventDefault();
      if (!latest.current.modal()) action();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  // a file dragged onto the window opens, as the path field + Open (Go resolves the dropped file's full path)
  useEffect(() => {
    window.runtime?.OnFileDrop?.((_x, _y, paths) => paths?.[0] && latest.current.openPath(paths[0]), false);
    return () => window.runtime?.OnFileDropOff?.();
  }, []);

  // path field as ImGui ElideLeft (Zig): a path longer than the field shows its end, the file name, with "..." in
  // front; with the focus it scrolls as any field
  useLayoutEffect(() => {
    const el = pathRef.current;
    if (!el) return;
    const fit = () => {
      if (!pathFocused) el.scrollLeft = el.scrollWidth;
      setPathElided(!pathFocused && el.scrollWidth > el.clientWidth);
    };
    fit();
    window.addEventListener('resize', fit);
    return () => window.removeEventListener('resize', fit);
  }, [pathText, pathFocused]);

  // dragging the top border of the Log panel resizes it (10% of the window by default, 3 lines to 25%)
  function startLogResize(e: React.MouseEvent) {
    e.preventDefault();
    const startY = e.clientY;
    const startH = logHeight;
    const move = (ev: MouseEvent) => setLogHeight(clampLogHeight(startH + startY - ev.clientY, window.innerHeight));
    const up = () => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  }

  // dragging the right edge of a Data header sets the column width (header menu > Size column to fit undoes it)
  function startColResize(e: React.MouseEvent<HTMLElement>, col: string) {
    e.preventDefault();
    e.stopPropagation();
    const startX = e.clientX;
    const startW = e.currentTarget.parentElement!.getBoundingClientRect().width;
    const move = (ev: MouseEvent) => setWidths((old) => ({ ...old, [col]: Math.max(24, Math.round(startW + ev.clientX - startX)) }));
    const up = () => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  }

  // startup: saved theme and language, then the file from the command line or MDB2SQL_DB_PATH
  useEffect(() => {
    if (started.current) return; // StrictMode runs effects twice in development
    started.current = true;
    const bridge = window.go?.main?.App;
    bridge?.GetLogOpen?.().then((open) => open && setLogOpen(true)).catch(() => {});
    bridge?.GetTheme?.().then((th) => th && setThemeState(th)).catch(() => {});
    bridge?.GetShowNull?.().then((show) => setShowNull(show === true)).catch(() => {});
    bridge?.GetSearchScope?.()
      .then((s) => {
        if (SCOPES.includes(s)) {
          defaultScopeRef.current = s;
          setDefaultScope(s);
          setScope(s);
        }
      })
      .catch(() => {});
    const langLoaded = Promise.resolve(bridge?.GetLanguage?.())
      .then((l) => {
        if (l && LANGS.includes(l)) {
          langRef.current = l; // before the re-render: the startup file below already speaks it
          setLang(l);
          setStatusText(translate(l, 'status.none'));
        }
      })
      .catch(() => {});
    // Linux without X11: the warning of display.go, shown once per start and kept in the log
    bridge?.DisplayWarning?.()
      .then((w) => {
        if (w?.text) {
          setDisplayWarn(w);
          addLog([w.text, w.missing, w.command ? `${w.distro}: ${w.command}` : ''].filter(Boolean).join(' '), 'warn');
        }
      })
      .catch(() => {});
    langLoaded
      .then(() => bridge?.StartupPath?.())
      .then((p) => p && openPath(p))
      .catch(fail);
  }, []);

  useEffect(() => {
    if (!about && !colsOpen && !displayWarn && !job) return;
    // Esc closes every dialog (the progress window: Cancel); each one also has its own OK/Close/Cancel button
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return;
      setAbout(null);
      setColsOpen(false);
      setDisplayWarn(null);
      if (job) window.go?.main?.App?.CancelJob?.();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [about, colsOpen, displayWarn, job]);

  // the Data tab searches the whole table in the database: wait for a pause in typing, then query
  useEffect(() => {
    const id = setTimeout(() => setTableSearch(search.trim()), TYPING_PAUSE);
    return () => clearTimeout(id);
  }, [search]);

  useEffect(() => {
    const id = setTimeout(() => setTableFilter(filter), TYPING_PAUSE);
    return () => clearTimeout(id);
  }, [filter]);

  // "All tables": Go counts the matching rows of every table; the list replaces the grid. Another term, scope or
  // file drops the running search's answer; a failure shows its error and ends "Searching"
  const searchAll = scope === 'all' && view === 'data' && tableSearch !== '' && tables.length > 0;
  useEffect(() => {
    const req = ++searchReq.current;
    setHits(null);
    setSearching(searchAll);
    if (!searchAll) return;
    setProgress(null); // Go sends one progress event per table counted
    Promise.resolve(window.go?.main?.App?.SearchAllTables?.(tableSearch))
      .then((found) => req === searchReq.current && setHits({ search: tableSearch, tables: found ?? [] }))
      .catch((err) => req === searchReq.current && fail(err))
      .finally(() => req === searchReq.current && setSearching(false));
  }, [searchAll, tableSearch, tables]);
  // the list of the search typed now only (the effect above clears an older one after this render)
  const shownHits = hits?.search === tableSearch ? hits.tables : null;

  // (a search typed in the SQL tab reaches the table when the Data or Schema tab comes back)
  useEffect(() => {
    if (selectedTable && view !== 'sql' && !searchAll && loadedFind.current !== tableSearch) loadTable(selectedTable, limit, filters, tableSearch);
  }, [tableSearch, view, searchAll]);

  async function copyText(text: string, done: string) {
    try {
      // the Wails clipboard goes through Go/Win32, so it does not depend on webview clipboard permissions
      if (window.runtime?.ClipboardSetText) await window.runtime.ClipboardSetText(text);
      else await navigator.clipboard.writeText(text);
      setCopied(done);
      addLog(done);
    } catch (err) {
      fail(err);
    }
  }

  function chooseTheme(th: Theme) {
    setThemeState(th);
    window.go?.main?.App?.SetTheme?.(th)?.catch(fail);
  }

  function chooseLang(l: Lang) {
    setLang(l);
    window.go?.main?.App?.SetLanguage?.(l)?.catch(fail);
  }

  function chooseShowNull(show: boolean) {
    setShowNull(show);
    window.go?.main?.App?.SetShowNull?.(show)?.catch(fail);
  }

  // the default also applies now; the selector beside the search changes only the current session
  function chooseDefaultScope(s: Scope) {
    defaultScopeRef.current = s;
    setDefaultScope(s);
    setScope(s);
    window.go?.main?.App?.SetSearchScope?.(s)?.catch(fail);
  }

  // a table of the "All tables" list opens in the Data tab with the same search
  function openHit(table: string) {
    setScope('table');
    loadTable(table, limit, undefined, tableSearch);
  }

  async function openAbout() {
    try {
      const bridge = getWailsBridge();
      if (!bridge.GetAppInfo) throw new Error(t('err.bridge'));
      setAbout(await bridge.GetAppInfo());
    } catch (err) {
      fail(err);
    }
  }

  function fail(err: unknown, newStatus?: string) {
    setError(err instanceof Error ? err.message : String(err));
    if (newStatus) setStatusText(newStatus);
  }

  // nothing of the previous file may survive: pending answers, rows, SQL result and what Export would write
  function clearDatabase() {
    tableReq.current++;
    sqlReq.current++;
    searchReq.current++;
    countReq.current++;
    setQuerying(false);
    setTables([]);
    setCounts({});
    setSelectedTable('');
    setRows([]);
    setSchema([]);
    setFilters([]);
    setSel(null);
    setResult(null);
    setResultSql('');
    setDbName('');
    setOpenedPath('');
    setSource('');
    setConverted(false);
  }

  // Before closing the file, opening another or quitting: the SQLite converted from an Access file is saved or
  // deleted (asked once; "remember" keeps the answer for the session). false = cancelled, keep everything open.
  async function settleConversion(): Promise<boolean> {
    const bridge = window.go?.main?.App;
    const name = (await bridge?.PendingConversion?.()) ?? '';
    if (!name || !bridge?.ResolveConversion) return true;
    const remembered = (await bridge.RememberedChoice?.()) ?? '';
    // Esc, the dialog's x and Cancel give null: nothing happens (the app does not quit). A Save whose file
    // dialog was cancelled asks again, with Esc still working.
    for (;;) {
      const answer: { choice: string; remember: boolean } | null = remembered
        ? { choice: remembered, remember: false }
        : await new Promise((resolve) => setAsk({ name, resolve }));
      setAsk(null);
      if (!answer) return false;
      try {
        const res = await bridge.ResolveConversion(answer.choice, answer.remember);
        if (res.done) {
          clearDatabase();
          return true;
        }
        if (remembered) return false;
      } catch (err) {
        clearDatabase(); // Go closed the database before the error (a failed move or delete)
        fail(err);
        return true;
      }
    }
  }

  // window close button: Go stops the close and asks the UI; then quit for real
  useEffect(
    () =>
      window.runtime?.EventsOn?.('conversion-pending', async () => {
        if (await settleConversion()) window.runtime?.Quit?.();
      }),
    [],
  );

  async function quit() {
    setOpenMenu(null);
    if (await settleConversion()) window.runtime?.Quit?.();
  }

  async function closeDatabase() {
    setOpenMenu(null);
    const name = dbName;
    if (!(await settleConversion())) return;
    try {
      clearDatabase(); // first: Go stops the running search or query, and their "cancelled" answers must be dropped
      await window.go?.main?.App?.CloseDatabase?.();
      setStatus(t('status.closed', name));
    } catch (err) {
      fail(err);
    }
  }

  // File > Open..., Browse... and Ctrl+O: the native file dialog, then the file chosen opens
  async function loadDatabase() {
    setError('');
    try {
      const bridge = getWailsBridge();
      if (!bridge.SelectDatabase) throw new Error(t('err.bridge'));
      const path = await bridge.SelectDatabase();
      if (!path) return; // dialog cancelled
      await openPath(path);
    } catch (err) {
      fail(err, t('status.loadError'));
    }
  }

  // the path of the top bar field: an empty field opens the default database (MDB2SQL_DB_PATH or the sample)
  const openTyped = () => openPath(pathText.trim());

  async function openPath(path: string) {
    setError('');
    if (!(await settleConversion())) return;
    if (path) setPathText(path);
    setJob(t('job.loading'));
    setProgress(null);
    setStatusText(t('status.loading'));
    try {
      const bridge = getWailsBridge();
      clearDatabase();
      const tableList = (await bridge.LoadDatabase(path)) ?? [];
      // Go knows which file an empty path resolved to (MDB2SQL_DB_PATH or the bundled sample)
      const name = (await bridge.DatabaseName?.()) || path.split(/[\\/]/).pop() || 'sample.duckdb';
      const opened = (await bridge.DatabasePath?.()) || path;
      setPathText(opened);
      setOpenedPath(opened);
      setSource((await bridge.SourceKind?.()) || '');
      setConverted(!!(await bridge.PendingConversion?.()));
      setDbName(name);
      setTables(tableList);
      // the row counts come after the list (a file with many tables shows at once); another file drops them
      const req = ++countReq.current;
      Promise.resolve(bridge.TableCounts?.())
        .then((c) => req === countReq.current && c && setCounts(Object.fromEntries(tableList.map((tb, i) => [tb, c[i]]))))
        .catch((err) => req === countReq.current && fail(err));
      // another file starts clean: no table list filter, no Data search, the search scope of Settings
      setFilter('');
      setTableFilter('');
      setSearch('');
      setTableSearch('');
      setScope(defaultScopeRef.current);
      setStatus(tn('status.loaded', tableList.length, name, tableList.length));
      if (tableList.length > 0) await loadTable(tableList[0], limit, undefined, '');
    } catch (err) {
      setDbName('');
      setSource('');
      fail(err, t('status.loadError'));
    } finally {
      setJob('');
    }
  }

  // keep = filtros a manter (mesma tabela: novo limite ou filtro); sem keep e outra tabela: filtros e colunas ocultas
  // zeram. find = pesquisa da aba Data, feita no banco sobre a tabela inteira
  async function loadTable(tableName: string, rowLimit: number, keep?: Filter[], find = tableSearch) {
    const tableFilters = keep ?? [];
    const req = ++tableReq.current;
    loadedFind.current = find;
    try {
      setError('');
      setSelectedTable(tableName);
      setSel(null);
      setCopied('');
      setFilters(tableFilters);
      if (!keep) {
        setHidden(new Set());
        setWidths({});
      }
      if (view === 'sql') setView('data');
      const bridge = getWailsBridge();
      const narrowed = tableFilters.length > 0 || find !== '';
      const [data, count, cols, total] = await Promise.all([
        bridge.GetTableData(tableName, rowLimit, tableFilters, find),
        bridge.GetRowCount(tableName, tableFilters, find),
        bridge.GetTableSchema ? bridge.GetTableSchema(tableName) : Promise.resolve([]),
        narrowed ? bridge.GetRowCount(tableName, [], '') : null,
      ]);
      if (req !== tableReq.current) return;
      setRows(data ?? []); // Go sends null for an empty table
      setRowCount(count);
      setTotalCount(total ?? count);
      setSchema(cols ?? []);
      setShownFind(find);
      setShownTable(tableName);
    } catch (err) {
      if (req === tableReq.current) fail(err);
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
    // Go runs one query at a time: this one cancels the previous, whose answer is dropped here
    const req = ++sqlReq.current;
    setQuerying(true);
    try {
      const bridge = getWailsBridge();
      if (!bridge.RunQuery) throw new Error(t('err.bridge'));
      const res = await bridge.RunQuery(sql, rowLimit);
      if (req !== sqlReq.current) return;
      setResult({ columns: res.columns ?? [], rows: res.rows ?? [], more: res.more });
      setResultSql(sql);
      // a query that ran fine takes the earlier SQL error off the status bar (the log keeps it)
      setLogLines((old) => (old.some((e) => e.sql && !e.cleared) ? old.map((e) => (e.sql ? { ...e, cleared: true } : e)) : old));
    } catch (err) {
      if (req !== sqlReq.current) return;
      setResult(null); // an error clears the old grid
      setResultSql('');
      // status bar: one translated line; the engine's full text (LINE 1, carets) goes to the log
      const full = err instanceof Error ? err.message : String(err);
      const short = t('sql.error', sqlErrorSummary(full));
      setErrorText(short);
      addLog(full, 'error', short, true);
    } finally {
      if (req === sqlReq.current) setQuerying(false);
    }
  }

  // every export asks for the file in Go (native dialog) and runs there, with progress events and Cancel
  async function runExport(what: string, call: () => Promise<string> | undefined) {
    setOpenMenu(null);
    setError('');
    setJob(t('job.exporting'));
    setProgress(null);
    try {
      const saved = await call();
      if (saved) setStatus(t('status.exported', what, saved));
    } catch (err) {
      fail(err);
    } finally {
      setJob('');
    }
  }

  // the current table to CSV/Excel; with the Data search or value filters on, first asks: the whole table or only the
  // n rows found (standard item 17)
  async function exportTable(format: string) {
    setOpenMenu(null);
    const table = selectedTable;
    const keep = shownTable === table && (filters.length > 0 || shownFind !== '') ? { filters, find: shownFind } : null;
    let onlyFound = false;
    if (keep) {
      const answer = await new Promise<boolean | null>((resolve) => setExportAsk({ table, found: rowCount, resolve }));
      setExportAsk(null);
      if (answer === null) return; // Cancel or Esc
      onlyFound = answer;
    }
    await runExport(table, () => bridge?.ExportTable?.(table, format, onlyFound ? keep!.filters : [], onlyFound ? keep!.find : ''));
  }

  const bridge = window.go?.main?.App;
  const sqlResultName = t('sql.result');
  const exportItems = [
    { group: 'db', label: t('export.dbSqlite'), on: tables.length > 0, run: () => runExport(dbName, () => bridge?.ExportDatabase?.('sqlite')) },
    { group: 'db', label: t('export.dbDuckdb'), on: tables.length > 0, run: () => runExport(dbName, () => bridge?.ExportDatabase?.('duckdb')) },
    { group: 'db', label: t('export.dbXlsx'), on: tables.length > 0, run: () => runExport(dbName, () => bridge?.ExportDatabase?.('xlsx')) },
    { group: 'table', label: t('export.tableCsv'), on: !!selectedTable, run: () => exportTable('csv') },
    { group: 'table', label: t('export.tableXlsx'), on: !!selectedTable, run: () => exportTable('xlsx') },
    { group: 'sql', label: t('export.sqlCsv'), on: !!resultSql, run: () => runExport(sqlResultName, () => bridge?.ExportQuery?.(resultSql, 'csv')) },
    { group: 'sql', label: t('export.sqlXlsx'), on: !!resultSql, run: () => runExport(sqlResultName, () => bridge?.ExportQuery?.(resultSql, 'xlsx')) },
  ];

  // the export list: the Export... button of the top bar and File > Export open the same items
  const exportMenu = (className: string) => (
    <div className={className} role="menu" aria-label={t('menu.export')}>
      {exportItems.map((it, i) => (
        <Fragment key={it.label}>
          {i > 0 && exportItems[i - 1].group !== it.group && <hr />}
          <button role="menuitem" disabled={!it.on || busy} onClick={it.run}>
            {it.label}
          </button>
        </Fragment>
      ))}
    </div>
  );

  const visibleTables = useMemo(() => {
    const words = searchWords(tableFilter);
    return words.length ? tables.filter((tb) => hasAllWords(normalizeText(tb), words)) : tables;
  }, [tables, tableFilter]);

  // schema order = database column order (Go maps reach JS sorted by key); also gives empty tables a header
  // memoized so the search index below is built once per load, not on every keystroke
  const tableColumns = useMemo(() => (schema.length > 0 ? schema.map((c) => c.name) : Object.keys(rows[0] ?? {})), [schema, rows]);
  const gridColumns = useMemo(() => (view === 'sql' ? (result?.columns ?? []) : tableColumns), [view, result, tableColumns]);
  const gridRows = useMemo(() => (view === 'sql' ? (result?.rows ?? []) : rows), [view, result, rows]);
  // SQL tab: the search filters the loaded result here; Data tab: Go already returned only the matching rows
  const sqlSearching = view === 'sql' && search.trim() !== '';
  const searchIndex = useMemo(() => (sqlSearching ? rowSearchText(gridRows, gridColumns) : undefined), [sqlSearching, gridRows, gridColumns]);
  const visibleRows = useMemo(
    () => (sqlSearching ? searchRows(gridRows, gridColumns, search, searchIndex) : gridRows),
    [sqlSearching, gridRows, gridColumns, search, searchIndex],
  );
  // hidden columns only leave the Data grid: search, copy row and exports still use every column
  const shownColumns = useMemo(() => (view === 'data' ? gridColumns.filter((c) => !hidden.has(c)) : gridColumns), [view, gridColumns, hidden]);
  // numeric columns are right-aligned, header included (cells: by their value type)
  const numericCols = useMemo(() => new Set(gridColumns.filter((c) => gridRows.some((r) => typeof r[c] === 'number'))), [gridColumns, gridRows]);
  const hiddenCount = gridColumns.length - shownColumns.length;
  // a column resized by hand keeps its width and cuts its cells (no "..."); the others fit their content
  const colStyle = (col: string): React.CSSProperties | undefined => {
    const w = view === 'data' ? widths[col] : undefined;
    return w ? { width: w, minWidth: w, maxWidth: w, overflow: 'hidden' } : undefined;
  };
  // the search of the rows on screen, not of the one being typed: the counts below belong to those rows
  const narrowed = filters.length > 0 || shownFind !== '';
  const copyCell = () => sel && copyText(cellText(sel.row[sel.col]), t('copied.value'));
  const copyRow = (withHeader: boolean) =>
    sel && copyText(rowToTsv(gridColumns, sel.row, withHeader), t(withHeader ? 'copied.rowHeader' : 'copied.row'));
  const busy = job !== '';
  const nullText = showNull ? t('cell.null') : '';
  // log collapsed: the most important unread line (error, then warning) takes the status bar
  const shownStatus = logOpen ? { text: error || status, level: error ? 'error' : 'info', unread: 0 } : statusLine(logLines, readMark, status, error);
  const viewName = (v: View) => t(`tab.${v}`); // "Esquema" without the column count (standard item 15)

  latest.current = {
    ...{ openPath, loadDatabase, quit },
    reload: () => openPath(openedPath), // nothing open: the default database, as the Python version
    focusSearch: () => {
      searchRef.current?.focus();
      searchRef.current?.select();
    },
    showView: (v: View) => {
      if (tables.length === 0) return;
      setView(v);
      if (v === 'sql') setTimeout(() => sqlRef.current?.focus()); // the field exists after this render
    },
    modal: () => !!(about || colsOpen || ask || exportAsk || displayWarn || busy),
  };

  const toggleMenu = (name: MenuName) => (e: React.MouseEvent) => {
    e.stopPropagation(); // the window click handler would close it again
    setMenu(null);
    setOpenMenu(openMenu === name ? null : name);
  };

  const menuButton = (name: MenuName, label: string) => (
    <button aria-haspopup="menu" aria-expanded={openMenu === name} onClick={toggleMenu(name)}>
      {label}
    </button>
  );

  const grid = (
    <table>
      <thead>
        <tr>
          {shownColumns.map((col) => (
            <th
              key={col}
              scope="col"
              className={numericCols.has(col) ? 'num' : undefined}
              style={colStyle(col)}
              title={col}
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
              {view === 'data' && <span className="col-resize" onMouseDown={(e) => startColResize(e, col)} />}
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
                style={colStyle(col)}
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
                {gridText(row[col], nullText)}
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
        <nav className="menubar" aria-label={t('menu.main')}>
          <div className="menu-root">
            {menuButton('file', t('menu.file'))}
            {openMenu === 'file' && (
              // as the Zig version: Open..., Export >, Close, Exit
              <div className="dropdown" role="menu" aria-label={t('menu.file')}>
                <button role="menuitem" disabled={busy} onClick={() => loadDatabase()} onMouseEnter={() => setSubOpen(false)}>
                  {t('menu.open')} <kbd>Ctrl+O</kbd>
                </button>
                <div className="menu-root">
                  <button
                    role="menuitem"
                    aria-haspopup="menu"
                    aria-expanded={subOpen}
                    disabled={busy || tables.length === 0}
                    onMouseEnter={() => setSubOpen(true)}
                    onClick={(e) => {
                      e.stopPropagation(); // the window click handler would close the File menu
                      setSubOpen(!subOpen);
                    }}
                  >
                    {t('menu.export')} <span className="sub-arrow">▸</span>
                  </button>
                  {subOpen && exportMenu('dropdown sub')}
                </div>
                <button role="menuitem" disabled={busy || !dbName} onClick={closeDatabase} onMouseEnter={() => setSubOpen(false)}>
                  {t('menu.close')}
                </button>
                <hr />
                <button role="menuitem" onClick={quit} onMouseEnter={() => setSubOpen(false)}>
                  {t('menu.exit')} <kbd>Ctrl+Q</kbd>
                </button>
              </div>
            )}
          </div>
          <div className="menu-root">
            {menuButton('view', t('menu.view'))}
            {openMenu === 'view' && (
              <div className="dropdown" role="menu" aria-label={t('menu.view')}>
                <button role="menuitemcheckbox" aria-checked={logOpen} onClick={() => toggleLog()}>
                  <span className="check">{logOpen ? '✓' : ''}</span>
                  {t('menu.log')}
                </button>
              </div>
            )}
          </div>
          <div className="menu-root">
            {menuButton('settings', t('menu.settings'))}
            {openMenu === 'settings' && (
              <div className="dropdown" role="menu" aria-label={t('menu.settings')}>
                <p className="menu-title">{t('menu.theme')}</p>
                {THEMES.map((th) => (
                  <button key={th} role="menuitemradio" aria-checked={theme === th} onClick={() => chooseTheme(th)}>
                    <span className="check">{theme === th ? '✓' : ''}</span>
                    {t(`theme.${th}`)}
                  </button>
                ))}
                <hr />
                <p className="menu-title">{t('menu.language')}</p>
                {LANGS.map((l) => (
                  <button key={l} role="menuitemradio" aria-checked={lang === l} lang={l} onClick={() => chooseLang(l)}>
                    <span className="check">{lang === l ? '✓' : ''}</span>
                    {t(`lang.${l}`)}
                  </button>
                ))}
                <hr />
                <p className="menu-title">{t('menu.searchScope')}</p>
                {SCOPES.map((s) => (
                  <button key={s} role="menuitemradio" aria-checked={defaultScope === s} onClick={() => chooseDefaultScope(s)}>
                    <span className="check">{defaultScope === s ? '✓' : ''}</span>
                    {t(`scope.${s}`)}
                  </button>
                ))}
                <hr />
                <button role="menuitemcheckbox" aria-checked={showNull} onClick={() => chooseShowNull(!showNull)}>
                  <span className="check">{showNull ? '✓' : ''}</span>
                  {t('menu.showNull')}
                </button>
              </div>
            )}
          </div>
          <div className="menu-root">
            {menuButton('help', t('menu.help'))}
            {openMenu === 'help' && (
              <div className="dropdown" role="menu" aria-label={t('menu.help')}>
                <button role="menuitem" onClick={openAbout}>
                  {t('menu.about')}
                </button>
              </div>
            )}
          </div>
        </nav>
        {/* path bar as in Zig: the field takes the line, Browse... Open Export... on the right */}
        <div className="pathbar">
          <div className={pathElided ? 'path elided' : 'path'}>
            <input
              ref={pathRef}
              type="text"
              spellCheck={false}
              placeholder={t('top.path')}
              aria-label={t('top.path')}
              value={pathText}
              disabled={busy}
              onChange={(e) => setPathText(e.target.value)}
              onKeyDown={(e) => e.key === 'Enter' && openTyped()}
              onFocus={() => setPathFocused(true)}
              onBlur={() => setPathFocused(false)}
            />
          </div>
          <button disabled={busy} onClick={() => loadDatabase()}>
            {t('top.browse')}
          </button>
          <button disabled={busy} onClick={openTyped}>
            {t('top.open')}
          </button>
          <div className="menu-root">
            <button aria-haspopup="menu" aria-expanded={openMenu === 'exportBar'} disabled={busy || tables.length === 0} onClick={toggleMenu('exportBar')}>
              {t('top.export')}
            </button>
            {openMenu === 'exportBar' && exportMenu('dropdown right')}
          </div>
        </div>
      </header>

      <nav className="sidebar" aria-label={t('sidebar.label')}>
        <input
          type="search"
          placeholder={t('sidebar.filter', tables.length)}
          aria-label={t('sidebar.filter', tables.length)}
          title={t('search.tip')}
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && setTableFilter(filter)}
          disabled={tables.length === 0}
        />
        {/* as Zig: the table name and its row count */}
        {tables.length > 0 && (
          <div className="table-head">
            <span>{t('sidebar.table')}</span>
            <span>{t('sidebar.rows')}</span>
          </div>
        )}
        <ul>
          {visibleTables.map((table) => (
            <li key={table}>
              <button
                className="table-item"
                title={table}
                aria-label={table}
                aria-current={table === selectedTable ? 'true' : undefined}
                onClick={() => loadTable(table, limit)}
              >
                <span className="name">{table}</span>
                {table in counts && <span className="count">{counts[table]}</span>}
              </button>
            </li>
          ))}
        </ul>
        {tables.length > 0 && visibleTables.length === 0 && <p className="empty">{t('sidebar.noMatch')}</p>}
      </nav>

      <main className="content">
        {tables.length === 0 ? (
          <p className="empty">{t('empty.formats')}</p>
        ) : (
          <>
            <div className="content-bar">
              <h2>{view === 'sql' ? t('tab.sql') : selectedTable}</h2>
              <div className="tabs" role="tablist" aria-label={t('tab.label')}>
                {VIEWS.map((v) => (
                  <button key={v} role="tab" aria-selected={view === v} onClick={() => setView(v)}>
                    {viewName(v)}
                  </button>
                ))}
              </div>
              <input
                ref={searchRef}
                type="search"
                className="search"
                placeholder={view === 'sql' ? t('sql.searchPlaceholder') : t('search.placeholder')}
                aria-label={view === 'sql' ? t('sql.searchLabel') : t('search.label')}
                title={t('search.tip')}
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                onKeyDown={(e) => e.key === 'Enter' && setTableSearch(search.trim())}
              />
              {view === 'data' && (
                <div className="tabs" role="radiogroup" aria-label={t('scope.label')}>
                  {SCOPES.map((s) => (
                    <button key={s} role="radio" aria-checked={scope === s} onClick={() => setScope(s)}>
                      {t(`scope.${s}`)}
                    </button>
                  ))}
                </div>
              )}
              <label className="field">
                {t('rows.label')}
                <select value={limit} onChange={(e) => changeLimit(Number(e.target.value))}>
                  {ROW_LIMITS.map((n) => (
                    <option key={n} value={n}>
                      {n}
                    </option>
                  ))}
                </select>
              </label>
              <button onClick={() => setColsOpen(true)} disabled={view !== 'data' || gridColumns.length === 0} title={t('cols.tip')}>
                {t('cols.button')}
              </button>
            </div>

            {view === 'data' && filters.length > 0 && (
              <div className="filters" role="group" aria-label={t('filters.group')}>
                {filters.map((f) => (
                  <span key={f.column} className="chip">
                    <span>{t('filters.chip', filterLabel(f))}</span>
                    <button
                      aria-label={t('filters.remove', f.column)}
                      title={t('filters.removeTip')}
                      onClick={() => applyFilters(filters.filter((x) => x !== f))}
                    >
                      ×
                    </button>
                  </span>
                ))}
                <button onClick={() => applyFilters([])}>{t('filters.clear')}</button>
              </div>
            )}

            {view === 'sql' && (
              <div className="sql-bar">
                <textarea
                  ref={sqlRef}
                  aria-label={t('sql.label')}
                  placeholder={t('sql.placeholder')}
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
                {querying ? (
                  <button onClick={() => bridge?.CancelJob?.()}>{t('sql.cancel')}</button>
                ) : (
                  <button className="primary" onClick={() => runSql()} title="Ctrl+Enter">
                    {t('sql.run')}
                  </button>
                )}
              </div>
            )}

            {/* tabIndex: the scroll area must be reachable and scrollable by keyboard */}
            <div
              className="table-container"
              tabIndex={0}
              role="region"
              aria-label={t('grid.region', view === 'sql' ? t('sql.result') : selectedTable, viewName(view))}
              onKeyDown={(e) => {
                // Ctrl+C copies the selected cell, unless the user marked text with the mouse (native copy)
                if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'c' && sel && !window.getSelection()?.toString()) {
                  e.preventDefault();
                  copyCell();
                }
              }}
            >
              {searchAll ? (
                shownHits &&
                (shownHits.length > 0 ? (
                  // as Python and Rust: "table (n)"; a click opens the table with the same search
                  <ul className="hits">
                    {shownHits.map((h) => (
                      <li key={h.table}>
                        <button className="table-item" onClick={() => openHit(h.table)}>
                          {t('hits.item', h.table, h.rows)}
                        </button>
                      </li>
                    ))}
                  </ul>
                ) : (
                  <p className="empty">{t('sidebar.noMatch')}</p>
                ))
              ) : view === 'schema' ? (
                <table className="schema">
                  <thead>
                    <tr>
                      <th scope="col">{t('schema.column')}</th>
                      <th scope="col">{t('schema.type')}</th>
                      <th scope="col">{t('schema.nullable')}</th>
                    </tr>
                  </thead>
                  <tbody>
                    {schema.map((col) => (
                      <tr key={col.name}>
                        <td>{col.name}</td>
                        <td>{col.type}</td>
                        <td>{nullableText(col.null, t)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              ) : (
                grid
              )}
              {view === 'data' && !searchAll && visibleRows.length === 0 && <p className="empty">{narrowed ? t('empty.noFilterMatch') : t('empty.noRows')}</p>}
              {view === 'data' && !searchAll && visibleRows.length > 0 && shownColumns.length === 0 && <p className="empty">{t('empty.noColumns')}</p>}
            </div>

            <footer className="info">
              {view === 'sql'
                ? result && t('info.sql', result.rows.length) + (result.more ? t('info.sqlLimit', limit) : '')
                : searchAll
                  ? shownHits
                    ? t('info.searchAll', shownHits.length, tableSearch)
                    : searching && progressText(t('job.searching'), progress, t)
                  : t('info.showing', shownTable, rows.length, rowCount) + (narrowed ? t('info.filtered', totalCount) : '')}
              {sqlSearching && t('info.searchSql', visibleRows.length, search.trim())}
              {copied && ` - ${copied}`}
            </footer>
          </>
        )}
      </main>

      {logOpen && (
        <section className="log" aria-label={t('log.title')}>
          <div className="log-resize" role="separator" aria-orientation="horizontal" title={t('log.resize')} onMouseDown={startLogResize} />
          <div className="log-bar">
            <button className="log-toggle" aria-label={t('log.collapse')} title={`${t('log.collapse')} (Ctrl+L)`} onClick={() => toggleLog(false)}>
              ▾
            </button>
            <h2>{t('log.title')}</h2>
            <button onClick={() => copyText(logLines.map((e) => e.line).join('\r\n'), t('copied.log'))} disabled={logLines.length === 0}>
              {t('log.copyAll')}
            </button>
          </div>
          {/* read-only text: select with the mouse or Ctrl+A, copy with Ctrl+C */}
          <textarea
            readOnly
            spellCheck={false}
            aria-label={t('log.title')}
            style={{ height: logHeight }}
            value={logLines.map((e) => e.line).join('\n')}
          />
        </section>
      )}

      <footer
        className="statusbar"
        onContextMenu={(e) => {
          e.preventDefault();
          setOpenMenu(null);
          setMenu({ x: e.clientX, y: e.clientY, status: true });
        }}
      >
        {!logOpen && (
          <button className="log-toggle" aria-label={t('log.expand')} title={`${t('log.expand')} (Ctrl+L)`} onClick={() => toggleLog(true)}>
            ▴
          </button>
        )}
        <p
          className={shownStatus.level === 'error' ? 'status error' : shownStatus.level === 'warn' ? 'status warn' : 'status'}
          role="status"
          aria-live="polite"
          onClick={() => !logOpen && !window.getSelection()?.toString() && toggleLog(true)}
        >
          {shownStatus.text}
        </p>
        {shownStatus.unread > 0 && (
          <span className="badge" title={t('log.unread', shownStatus.unread)}>
            {shownStatus.unread}
          </span>
        )}
        {hiddenCount > 0 && <span className="source">{hiddenCount === 1 ? t('hidden.one') : t('hidden.many', hiddenCount)}</span>}
        {source && (
          <span className="source" title={t('status.sourceTip')}>
            {converted ? t('status.sourceConverted', source) : t('status.source', source)}
          </span>
        )}
      </footer>

      {menu?.status && (
        <div className="menu" role="menu" aria-label={t('status.copy')} style={{ left: Math.min(menu.x, window.innerWidth - 220), top: Math.min(menu.y, window.innerHeight - 50) }}>
          <button role="menuitem" autoFocus onClick={() => copyText(shownStatus.text, t('copied.status'))}>
            {t('status.copy')}
          </button>
        </div>
      )}

      {/* header menu in the order of Rust (Grid.svelte): fit, fit all, hide, Columns..., show all, then the columns with a
          check mark; the last visible column cannot be hidden here (its header is what opens this menu) */}
      {menu?.header !== undefined && (
        <div
          key={`${menu.x},${menu.y}`}
          ref={keepInWindow}
          className="menu"
          role="menu"
          aria-label={t('colmenu.label')}
          style={{ left: Math.min(menu.x, window.innerWidth - 220), top: menu.y }}
        >
          <button
            role="menuitem"
            autoFocus
            onClick={() =>
              setWidths((old) => {
                const { [menu.header!]: _, ...rest } = old;
                return rest;
              })
            }
          >
            {t('colmenu.fit')}
          </button>
          <button role="menuitem" onClick={() => setWidths({})}>
            {t('colmenu.fitAll')}
          </button>
          <hr />
          <button role="menuitem" disabled={shownColumns.length < 2} onClick={() => setColumnHidden(menu.header!, true)}>
            {t('colmenu.hide')}
          </button>
          <button role="menuitem" onClick={() => setColsOpen(true)}>
            {t('colmenu.columns')}
          </button>
          <button role="menuitem" disabled={hiddenCount === 0} onClick={() => setHidden(new Set())}>
            {t('colmenu.showAll')}
          </button>
          <hr />
          {gridColumns.map((col) => {
            const shown = !hidden.has(col);
            return (
              <button key={col} role="menuitemcheckbox" aria-checked={shown} disabled={shown && shownColumns.length < 2} onClick={() => setColumnHidden(col, shown)}>
                <span className="check">{shown ? '✓' : ''}</span>
                {col}
              </button>
            );
          })}
        </div>
      )}

      {menu && menu.header === undefined && !menu.status && (
        <div
          className="menu"
          role="menu"
          aria-label={t('cellmenu.label')}
          style={{ left: Math.min(menu.x, window.innerWidth - 220), top: Math.min(menu.y, window.innerHeight - 190) }}
        >
          {view === 'data' && (
            <>
              <button role="menuitem" onClick={() => sel && applyFilters(withFilter(filters, { column: sel.col, value: sel.row[sel.col] ?? null }))}>
                {t('cellmenu.filter')}
              </button>
              <button role="menuitem" disabled={filters.length === 0} onClick={() => applyFilters([])}>
                {t('cellmenu.clear')}
              </button>
              <hr />
            </>
          )}
          <button role="menuitem" autoFocus onClick={copyCell}>
            {t('cellmenu.copy')} <kbd>Ctrl+C</kbd>
          </button>
          <button role="menuitem" onClick={() => copyRow(false)}>
            {t('cellmenu.copyRow')}
          </button>
          <button role="menuitem" onClick={() => copyRow(true)}>
            {t('cellmenu.copyRowHeader')}
          </button>
        </div>
      )}

      {busy && (
        <div className="backdrop">
          <div className="about progress" role="dialog" aria-modal="true" aria-label={job}>
            <p>{progressText(job, progress, t)}</p>
            <progress max={progress?.total || undefined} value={progress?.total ? progress.done : undefined} />
            <button autoFocus onClick={() => bridge?.CancelJob?.()}>
              {t('job.cancel')}
            </button>
          </div>
        </div>
      )}

      {ask && <ConversionDialog name={ask.name} t={t} onAnswer={ask.resolve} />}

      {exportAsk && <ExportAskDialog table={exportAsk.table} found={exportAsk.found} t={t} tn={tn} onAnswer={exportAsk.resolve} />}

      {displayWarn && (
        <div className="backdrop">
          <div className="about conversion" role="alertdialog" aria-modal="true" aria-labelledby="display-title">
            <h2 id="display-title">{t('display.title')}</h2>
            <p>
              {displayWarn.text}
              <br />
              {displayWarn.missing}
            </p>
            {displayWarn.command && (
              <p className="display-cmd">
                <span>{displayWarn.distro}: </span>
                <code>{displayWarn.command}</code>
                <button onClick={() => copyText(displayWarn.command, t('copied.value'))}>{t('display.copy')}</button>
              </p>
            )}
            <div className="col-actions">
              <a
                className="help-link"
                href={displayWarn.help}
                onClick={(e) => {
                  e.preventDefault(); // the default browser, never the app's own webview
                  window.runtime?.BrowserOpenURL?.(displayWarn.help);
                }}
              >
                {t('display.help')}
              </a>
              <button className="primary end" autoFocus onClick={() => setDisplayWarn(null)}>
                {t('display.ok')}
              </button>
            </div>
          </div>
        </div>
      )}

      {about && (
        <div className="backdrop" onClick={(e) => e.target === e.currentTarget && setAbout(null)}>
          <div className="about" role="dialog" aria-modal="true" aria-labelledby="about-title">
            <h2 id="about-title">
              {t('about.title')} <span className="version">{about.version}</span>
            </h2>
            <p className="tagline">{t('about.tagline')}</p>
            <dl>
              {aboutRows(about, t).map(([label, value]) => (
                <div key={label}>
                  <dt>{label}</dt>
                  <dd>
                    {value.startsWith('https://') ? (
                      <a
                        href={value}
                        title={t('about.openLink')}
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
              {t('about.close')}
            </button>
          </div>
        </div>
      )}

      {colsOpen && (
        <ColumnsDialog table={selectedTable} columns={gridColumns} hidden={hidden} setHidden={setHidden} onClose={() => setColsOpen(false)} t={t} />
      )}
    </div>
  );
}

// "Save or delete the converted SQLite?": Save... (dialog in Go), Delete, Cancel; remember = for this session only
function ConversionDialog({ name, t, onAnswer }: { name: string; t: T; onAnswer: (a: { choice: string; remember: boolean } | null) => void }) {
  const [remember, setRemember] = useState(false);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onAnswer(null);
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  return (
    <div className="backdrop">
      <div className="about conversion" role="dialog" aria-modal="true" aria-labelledby="conv-title">
        <div className="dialog-head">
          <h2 id="conv-title">{t('conv.title')}</h2>
          <button className="dialog-x" aria-label={t('about.close')} title={t('about.close')} onClick={() => onAnswer(null)}>
            ×
          </button>
        </div>
        <p>{t('conv.text', name)}</p>
        <label className="remember">
          <input type="checkbox" checked={remember} onChange={(e) => setRemember(e.target.checked)} />
          {t('conv.remember')}
        </label>
        <div className="col-actions">
          <button className="primary" autoFocus onClick={() => onAnswer({ choice: 'save', remember })}>
            {t('conv.save')}
          </button>
          <button onClick={() => onAnswer({ choice: 'delete', remember })}>{t('conv.delete')}</button>
          <button className="end" onClick={() => onAnswer(null)}>
            {t('conv.cancel')}
          </button>
        </div>
      </div>
    </div>
  );
}

// Table export with the search active: the whole table, only the rows found, or Cancel (Esc)
type ExportAskProps = { table: string; found: number; t: T; tn: TN; onAnswer: (onlyFound: boolean | null) => void };
function ExportAskDialog({ table, found, t, tn, onAnswer }: ExportAskProps) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onAnswer(null);
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  return (
    <div className="backdrop">
      <div className="about conversion" role="dialog" aria-modal="true" aria-labelledby="export-ask-title">
        <h2 id="export-ask-title">{t('exportAsk.title', table)}</h2>
        <div className="col-actions">
          <button autoFocus onClick={() => onAnswer(false)}>
            {t('exportAsk.all')}
          </button>
          <button onClick={() => onAnswer(true)}>{tn('exportAsk.found', found, found)}</button>
          <button className="end" onClick={() => onAnswer(null)}>
            {t('job.cancel')}
          </button>
        </div>
      </div>
    </div>
  );
}

// Minimum width of one checkbox cell of "Columns...": longest name (~8 px per character at the 14 px base font)
// plus box and gaps, at least 150 px; the CSS grid fits as many as the dialog allows, 1 to 6 (about 4 at 1280x800)
export const columnCellWidth = (columns: string[]) => Math.max(150, Math.max(0, ...columns.map((c) => c.length)) * 8 + 44);

type ColumnsDialogProps = {
  table: string;
  columns: string[];
  hidden: Set<string>;
  setHidden: (update: (old: Set<string>) => Set<string>) => void;
  onClose: () => void;
  t: T;
};

// "Columns...": search on top, responsive checkbox grid (vertical scroll only), buttons in one row
function ColumnsDialog({ table, columns, hidden, setHidden, onClose, t }: ColumnsDialogProps) {
  const [query, setQuery] = useState('');
  const listed = useMemo(() => {
    const words = searchWords(query);
    return words.length ? columns.filter((c) => hasAllWords(normalizeText(c), words)) : columns;
  }, [columns, query]);
  const visible = columns.filter((c) => !hidden.has(c)).length;
  // Show/Hide all act on the listed columns only (all of them when the search is empty); one column always stays
  // visible: hiding every one keeps the first listed
  const showListed = (show: boolean) =>
    setHidden((old) => {
      if (show) return new Set([...old].filter((c) => !listed.includes(c)));
      const next = new Set([...old, ...listed]);
      if (columns.every((c) => next.has(c))) next.delete(listed[0]);
      return next;
    });
  const toggle = (col: string, show: boolean) =>
    setHidden((old) => {
      const next = new Set(old);
      if (show) next.delete(col);
      else next.add(col);
      return next;
    });
  return (
    <div className="backdrop" onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className="about columns" role="dialog" aria-modal="true" aria-labelledby="cols-title">
        <h2 id="cols-title">{t('cols.title', table)}</h2>
        <div className="col-top">
          <input
            type="search"
            placeholder={t('cols.filter')}
            aria-label={t('cols.filter')}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && onClose()} // Enter = the default button (Close)
            autoFocus
          />
          <span className="col-count">{t('cols.count', visible, columns.length)}</span>
        </div>
        <div className="col-list" style={{ '--col-w': `${columnCellWidth(columns)}px` } as React.CSSProperties}>
          {listed.map((col) => (
            <label key={col} title={col}>
              <input
                type="checkbox"
                checked={!hidden.has(col)}
                disabled={visible === 1 && !hidden.has(col)}
                onChange={(e) => toggle(col, e.target.checked)}
              />
              <span>{col}</span>
            </label>
          ))}
          {listed.length === 0 && <p className="empty">{t('cols.none')}</p>}
        </div>
        <div className="col-actions">
          <button onClick={() => showListed(true)}>{t('cols.showAll')}</button>
          <button onClick={() => showListed(false)}>{t('cols.hideAll')}</button>
          <button className="primary end" onClick={onClose}>
            {t('cols.close')}
          </button>
        </div>
      </div>
    </div>
  );
}

export default App;
