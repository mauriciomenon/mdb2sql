// Visualizador de bancos (Access, SQLite, DuckDB): abre um arquivo, lista tabelas, mostra dados, schema e SQL, exporta
// !T: Single-screen viewer talking to Go through the Wails IPC bridge (window.go.main.App). Every visible text comes
// from the catalogs in ../../i18n (see i18n.ts)

import { useEffect, useLayoutEffect, useMemo, useRef, useState, version as reactVersion } from 'react';
import './App.css';
import { LANGS, translate, translateN, type Lang, type T, type TN } from './i18n';

type Row = Record<string, unknown>;
type Column = { name: string; type: string; null: string };
export type Theme = 'system' | 'light' | 'dark';
type View = 'data' | 'schema' | 'sql' | 'terms';
type Scope = 'table' | 'all'; // Data tab search and Terms tab: the open table or all tables
type Match = 'whole' | 'contains'; // Terms tab: the whole cell equals the term, or the cell contains it
type TableHits = { table: string; rows: number };
type MenuName = 'file' | 'edit' | 'exportBar' | 'view' | 'settings' | 'help';
type QueryResult = { columns: string[]; rows: Row[]; more: boolean };
type Progress = { done: number; total: number; label: string };
// answer of a term search (Go: backend.TermsResult): the terms searched, in pasted order, and where each one is
export type TermsResult = {
  terms: string[];
  repeated: number;
  hits: { term: string; table: string; rows: number }[];
  tables: TableHits[];
  notFound: string[];
};
// the running job: a file being opened, an export or save (what = its name; leaving the app asks first) or a term search
type Job = { kind: 'load' | 'export' | 'terms'; text: string; what?: string };
// a question with its buttons in screen order (key: catalog key of the text; the first one has the focus: Enter); cls
// "end" starts the right group
type Question = { title: string; text: string; buttons: { key: string; value: string; cls?: string }[] };
// One line of a menu: a separator, a command (run), a submenu (items) or a check/radio item (checked)
export type MenuItem =
  | { sep: true }
  | {
      label: string;
      kbd?: string;
      on?: boolean; // false = disabled
      run?: () => void;
      items?: MenuItem[];
      checked?: boolean;
      radio?: boolean;
      lang?: string;
      focus?: boolean; // gets the focus when the menu opens
    };
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
  webview?: string; // what draws the window: "WebView2 158.0.4370.33" (runtime API), "WebKitGTK"
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
          SaveDatabase?: (saveAs: boolean) => Promise<string>;
          ExportTable?: (table: string, format: string, filters: Filter[], search: string) => Promise<string>;
          ExportQuery?: (query: string, format: string) => Promise<string>;
          MarkedRows?: (table: string, marks: Row[]) => Promise<Row[]>;
          ExportMarked?: (table: string, format: string, marks: Row[]) => Promise<string>;
          ExportSchema?: (table: string, format: string) => Promise<string>;
          ExportAllCSV?: () => Promise<string>;
          ExportSearch?: (search: string, tables: string[]) => Promise<string>;
          SearchTerms?: (lines: string[], contains: boolean, table: string) => Promise<TermsResult>;
          TermRows?: (table: string, terms: string[], contains: boolean, limit: number) => Promise<QueryResult>;
          ExportTerms?: (res: TermsResult, contains: boolean, format: string) => Promise<string>;
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
          GetTermMatch?: () => Promise<Match>;
          SetTermMatch?: (match: Match) => Promise<void>;
          SearchAllTables?: (search: string) => Promise<TableHits[]>;
          TableCounts?: () => Promise<number[]>;
          PendingConversion?: () => Promise<string>;
          CloseDatabase?: () => Promise<void>;
          Exit?: () => Promise<void>;
          StartupLog?: () => Promise<string[] | null>;
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
const MATCHES: Match[] = ['whole', 'contains'];
const VIEWS: View[] = ['data', 'schema', 'sql', 'terms']; // tab order: Ctrl+1, Ctrl+2, Ctrl+3, Ctrl+4
const TABLE_FORMATS = ['csv', 'xlsx']; // Export > ... > CSV... / Excel (.xlsx)...
const REPORT_FORMATS = ['xlsx', 'csv', 'sqlite', 'duckdb']; // Export > Term search report
// key Go puts in each Data row with the engine's rowid of that row (never a column name): marked rows are told apart by it
export const ROWID = '\u0000rowid';
const NO_ROWS: Row[] = []; // one empty list, so the grid memos keep it between renders
export const sumRows = (hits: TableHits[]) => hits.reduce((n, h) => n + h.rows, 0);

// Table list with favorites (standard item 34): the favorite tables of the list first, in alphabetical order, then the
// others as they were; a favorite name the open file does not have is simply not in the list
export const favoritesFirst = (tables: string[], favorites: Set<string>) => [
  ...tables.filter((tb) => favorites.has(tb)).sort(),
  ...tables.filter((tb) => !favorites.has(tb)),
];

// What tells a row apart from the others of its table: the engine's rowid when Go sent one, else all its values (rows
// equal in every value are then marked together)
export const rowKey = (row: Row, columns: string[]) => (ROWID in row ? `#${row[ROWID]}` : JSON.stringify(columns.map((c) => row[c] ?? null)));

// Terms of the text pasted in the Terms tab: one per line, without the spaces at the ends, empty lines dropped; a term
// already in the list (ignoring case, as the search does) counts as repeated and is searched once (Go: CleanTerms)
export function parseTerms(text: string) {
  const seen = new Set<string>();
  const terms: string[] = [];
  let repeated = 0;
  for (const line of text.split(/\r?\n/)) {
    const term = line.trim();
    if (!term) continue;
    if (seen.has(term.toLowerCase())) repeated++;
    else {
      seen.add(term.toLowerCase());
      terms.push(term);
    }
  }
  return { terms, repeated };
}

// How an Access file is read now: the ODBC driver (embedded mdbtools as fallback), mdbtools only, or nothing
function accessReading(info: AppInfo, t: T): string {
  const mdb = info.mdbtools ?? '';
  if (info.access === 'Access ODBC') return mdb ? t('about.accessOdbc', mdb) : t('about.accessOdbcOnly');
  if (info.access === 'mdbtools') return t(info.mdbtoolsSystem ? 'about.accessSystem' : 'about.accessEmbedded', mdb);
  return t('about.reader.none');
}

// Linhas (rotulo, valor) do dialogo Sobre, as do Rust (Build, Stack, Janela, Bancos, Leitura do Access, Gravacao,
// Autor, Licenca, links); versao de wails.json, numero/data do build gravados pelo build, runtimes lidos em execucao.
// Valor que comeca com https:// vira link aberto no navegador padrao.
export function aboutRows(info: AppInfo, t: T): [string, string][] {
  const v = (s: string) => s.replace(/^v/, '');
  return [
    [t('about.build'), info.build ? `${info.build} (${info.buildDate})` : 'dev'],
    [t('about.stack'), `Go ${info.go} + Wails ${v(info.wails)} + React ${reactVersion}`],
    [t('about.window'), info.webview ?? ''],
    [t('about.engines'), `DuckDB ${v(info.duckdb)}`], // SQLite files are read by DuckDB (its sqlite extension)
    [t('about.access'), accessReading(info, t)],
    [t('about.write'), t('about.writeValue')], // .mdb and .accdb cannot be written (standard item 28)
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

// Keeps a context menu inside the window: a long column list moves it up (taller than the window, it scrolls), a
// menu opened near the right edge moves left
function keepInWindow(el: HTMLElement | null) {
  if (!el) return;
  const r = el.getBoundingClientRect();
  el.style.top = `${Math.max(4, Math.min(r.top, window.innerHeight - el.offsetHeight - 4))}px`;
  el.style.left = `${Math.max(4, Math.min(r.left, window.innerWidth - el.offsetWidth - 4))}px`;
}

// a menu drawn from data: commands, check/radio items, separators and submenus (opened by hover or click)
type MenuListProps = { items: MenuItem[]; label: string; className: string; style?: React.CSSProperties; place?: (el: HTMLElement | null) => void };
function MenuList({ items, label, className, style, place }: MenuListProps) {
  const [sub, setSub] = useState(-1);
  // as a native menu: with any check or radio item, every item keeps the column of the check mark
  const checks = items.some((it) => !('sep' in it) && it.checked !== undefined);
  return (
    <div ref={place} className={className} style={style} role="menu" aria-label={label}>
      {items.map((it, i) =>
        'sep' in it ? (
          <hr key={i} />
        ) : it.items ? (
          <div className="menu-root" key={i}>
            <button
              role="menuitem"
              aria-haspopup="menu"
              aria-expanded={sub === i}
              disabled={it.on === false}
              onMouseEnter={() => setSub(i)}
              onClick={(e) => {
                e.stopPropagation(); // the window click handler would close the menu
                setSub(i); // as a native submenu: the click after the hover keeps it open
              }}
            >
              {checks && <span className="check" />}
              {it.label} <span className="sub-arrow">▸</span>
            </button>
            {sub === i && <MenuList items={it.items} label={it.label} className="dropdown sub" />}
          </div>
        ) : (
          <button
            key={i}
            role={it.checked === undefined ? 'menuitem' : it.radio ? 'menuitemradio' : 'menuitemcheckbox'}
            aria-checked={it.checked}
            disabled={it.on === false}
            lang={it.lang}
            autoFocus={it.focus}
            onMouseEnter={() => setSub(-1)}
            onClick={it.run}
          >
            {checks && <span className="check">{it.checked ? '✓' : ''}</span>}
            {it.label}
            {it.kbd && (
              <>
                {' '}
                <kbd>{it.kbd}</kbd>
              </>
            )}
          </button>
        ),
      )}
    </div>
  );
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
  const termsRef = useRef<HTMLTextAreaElement>(null); // Ctrl+4
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
  const [job, setJob] = useState<Job | null>(null); // the running load, export or term search
  const [progress, setProgress] = useState<Progress | null>(null);
  const [theme, setThemeState] = useState<Theme>('system');
  const [showNull, setShowNull] = useState(false); // Settings > Show NULL (off: a NULL cell is empty)
  const [openMenu, setOpenMenu] = useState<MenuName | null>(null);
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
  useEffect(() => setSel(null), [view]); // Edit > Copy... never copies a cell of another tab
  // open context menu: of the selected cell, of a column header (header = column name), of the status bar or of a table
  // of the table list (table = its name)
  const [menu, setMenu] = useState<{ x: number; y: number; header?: string; status?: boolean; table?: string } | null>(null);
  // favorite tables, by name, while the program is open (not saved; another file or F5 keeps them)
  const [favorites, setFavorites] = useState<Set<string>>(new Set());
  const toggleFavorite = (table: string) =>
    setFavorites((old) => {
      const next = new Set(old);
      if (!next.delete(table)) next.add(table);
      return next;
    });
  const [filters, setFilters] = useState<Filter[]>([]); // of the current table, applied by Go in the query
  const [hidden, setHidden] = useState<Set<string>>(new Set()); // hidden columns of the current table
  const [widths, setWidths] = useState<Record<string, number>>({}); // Data columns resized by hand (current table)
  const [colsOpen, setColsOpen] = useState(false); // "Columns..." dialog
  const [sql, setSql] = useState('');
  const [result, setResult] = useState<QueryResult | null>(null);
  const [resultSql, setResultSql] = useState(''); // SQL of the result shown (what "Export SQL result" writes)
  const [logLines, setLogLines] = useState<LogEntry[]>([]);
  const [logOpen, setLogOpen] = useState(false); // collapsed by default
  const [readMark, setReadMark] = useState(0); // log lines before this one were seen
  const [logHeight, setLogHeight] = useState(() => clampLogHeight(Math.round(window.innerHeight * 0.1), window.innerHeight));
  const [displayWarn, setDisplayWarn] = useState<DisplayWarning | null>(null); // Linux: X11 missing, on Wayland
  // question asked on exit (export running, converted SQLite not saved); resolve gets the value of the button (null = Esc, x)
  const [question, setQuestion] = useState<(Question & { resolve: (answer: string | null) => void }) | null>(null);
  const quitting = useRef(false); // the exit questions are open: another X or Ctrl+Q asks nothing more
  // marked rows of the Data tab: per table, the key of each marked row (rowKey) and the row as Go sent it
  const [marks, setMarks] = useState<Record<string, Map<string, Row>>>({});
  const [markedRows, setMarkedRows] = useState<{ table: string; rows: Row[] }>({ table: '', rows: [] }); // in table order
  const [onlyMarked, setOnlyMarked] = useState(false); // View > Only marked rows
  const markReq = useRef(0);
  // Terms tab: the pasted text, Whole value | Contains (default in Settings), This table | All tables, the answer and
  // the rows of the table chosen in its list
  const [termsText, setTermsText] = useState('');
  const [match, setMatch] = useState<Match>('whole');
  const [defaultMatch, setDefaultMatch] = useState<Match>('whole');
  const [termsScope, setTermsScope] = useState<Scope>('table');
  const [termsRes, setTermsRes] = useState<{ res: TermsResult; contains: boolean } | null>(null);
  const [termsTable, setTermsTable] = useState('');
  const [termGrid, setTermGrid] = useState<QueryResult | null>(null);
  const termsReq = useRef(0);
  const termGridReq = useRef(0);
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

  // shortcuts of the menus (standard items 20, 28 and 34): Ctrl+O, Ctrl+S, Ctrl+Shift+S, Ctrl+W, Ctrl+Q, F5, Ctrl+F,
  // Ctrl+T, Ctrl+D, Ctrl+1/2/3/4, Ctrl+L here; Ctrl+Enter in the SQL and Terms fields, Ctrl+C, Ctrl+Shift+C and Space in the grid. The
  // keys are always taken from the webview (F5 would reload the page); with a dialog open they do nothing, and while a
  // job runs only Ctrl+Q works (it asks before leaving)
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const ctrl = (e.ctrlKey || e.metaKey) && !e.altKey;
      const k = e.key.toLowerCase();
      const L = latest.current;
      const action =
        e.key === 'F5' && !e.ctrlKey && !e.altKey && !e.shiftKey ? () => L.reload()
        : !ctrl ? null
        : e.shiftKey ? (k === 's' ? () => L.save(true) : null)
        : k === 'o' ? () => L.loadDatabase()
        : k === 's' ? () => L.save(false)
        : k === 'w' ? () => L.closeDatabase()
        : k === 'f' ? () => L.focusSearch()
        : k === 't' ? () => L.focusTables()
        : k === 'd' ? () => L.toggleFavorite()
        : k === 'q' ? () => L.quit()
        : k === 'l' ? () => toggleLog()
        : ['1', '2', '3', '4'].includes(e.key) ? () => L.showView(VIEWS[Number(e.key) - 1])
        : null;
      if (!action) return;
      e.preventDefault();
      if (!L.modal() && (k === 'q' || !L.busy())) action();
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
          setTermsScope(s);
        }
      })
      .catch(() => {});
    bridge?.GetTermMatch?.()
      .then((m) => {
        if (MATCHES.includes(m)) {
          setDefaultMatch(m);
          setMatch(m);
        }
      })
      .catch(() => {});
    // what Go did before the UI listened (converted files of a crash removed)
    bridge?.StartupLog?.()
      .then((lines) => lines?.forEach((line) => addLog(line)))
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
    // a question (on exit) takes Esc itself: it must not also cancel the export running under it
    if ((!about && !colsOpen && !displayWarn && !job) || question) return;
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
  }, [about, colsOpen, displayWarn, job, question]);

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
      setStatus(done); // in the status bar (and the log), not under the grid (standard item 24)
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
    setTermsScope(s);
    window.go?.main?.App?.SetSearchScope?.(s)?.catch(fail);
  }

  // Settings > Term matching: also applies now; the selector of the Terms tab changes only the current session
  function chooseDefaultMatch(m: Match) {
    setDefaultMatch(m);
    setMatch(m);
    window.go?.main?.App?.SetTermMatch?.(m)?.catch(fail);
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
    // the marks and the term search belong to the file (Close, another file and Reopen clear them)
    setMarks({});
    setOnlyMarked(false);
    termsReq.current++;
    setTermsRes(null);
    setTermsTable('');
  }

  const ask = (q: Question) =>
    new Promise<string | null>((resolve) =>
      setQuestion({
        ...q,
        resolve: (answer) => {
          setQuestion(null);
          resolve(answer);
        },
      }),
    );

  // window close button and Alt+F4: Go keeps the window open and asks the UI (export running or converted SQLite not saved)
  useEffect(() => window.runtime?.EventsOn?.('exit-asked', () => latest.current.quit()), []);

  // File > Exit, Ctrl+Q and the window close button (standard item 27). An export running asks first: Back or Exit
  // (Exit cancels it, no half-written file); a term or table search just stops. Then, with the SQLite converted from an
  // Access file not saved: Save | Back, Exit; Save opens the save dialog, and cancelled there the question comes back.
  async function quit() {
    setOpenMenu(null);
    if (quitting.current) return;
    quitting.current = true;
    try {
      const b = window.go?.main?.App;
      if (job?.kind === 'export') {
        const back = { key: 'btn.back', value: 'back', cls: 'end' };
        if ((await ask({ title: t('exportRun.title'), text: t('exportRun.text', job.what), buttons: [back, { key: 'menu.exit', value: 'exit' }] })) !== 'exit') return;
      }
      if (job) await b?.CancelJob?.();
      for (;;) {
        const name = (await b?.PendingConversion?.()) ?? '';
        if (!name) break;
        const answer = await ask({
          title: t('exit.title'),
          text: t('exit.text', name),
          buttons: [
            { key: 'menu.save', value: 'save', cls: 'primary' },
            { key: 'btn.back', value: 'back', cls: 'end' },
            { key: 'menu.exit', value: 'exit' },
          ],
        });
        if (answer === 'exit') break;
        if (answer !== 'save') return; // Back, Esc or the x of the question
        await save(false);
      }
      if (b?.Exit) await b.Exit(); // Go closes the window; leaving deletes the converted SQLite
      else window.runtime?.Quit?.();
    } finally {
      quitting.current = false;
    }
  }

  // File > Close: nothing is asked; an unsaved converted SQLite is deleted and the Log says so (Go)
  async function closeDatabase() {
    setOpenMenu(null);
    const name = dbName;
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

  // another file (or the same one again, F5): the open one is left without a question (Go deletes its unsaved SQLite)
  async function openPath(path: string) {
    setError('');
    if (path) setPathText(path);
    setJob({ kind: 'load', text: t('job.loading') });
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
      setTermsScope(defaultScopeRef.current);
      setStatus(tn('status.loaded', tableList.length, name, tableList.length));
      if (tableList.length > 0) await loadTable(tableList[0], limit, undefined, '');
    } catch (err) {
      setDbName('');
      setSource('');
      fail(err, t('status.loadError'));
    } finally {
      setJob(null);
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
      setFilters(tableFilters);
      if (!keep) {
        setHidden(new Set());
        setWidths({});
      }
      if (view === 'sql') setView('data');
      const bridge = getWailsBridge();
      const [data, count, cols] = await Promise.all([
        bridge.GetTableData(tableName, rowLimit, tableFilters, find),
        bridge.GetRowCount(tableName, tableFilters, find),
        bridge.GetTableSchema ? bridge.GetTableSchema(tableName) : Promise.resolve([]),
      ]);
      if (req !== tableReq.current) return;
      setRows(data ?? []); // Go sends null for an empty table
      setRowCount(count);
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

  // every export and File > Save ask for the file in Go (native dialog) and run there, with progress events and
  // Cancel; what = the name the status bar and the exit question give it. Returns the file written ("" = none).
  async function runExport(what: string, call: () => Promise<string> | undefined) {
    setOpenMenu(null);
    setError('');
    setJob({ kind: 'export', text: t('job.exporting'), what });
    setProgress(null);
    try {
      const saved = (await call()) ?? '';
      if (saved) setStatus(t('status.exported', what, saved));
      return saved;
    } catch (err) {
      fail(err);
      return '';
    } finally {
      setJob(null);
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

  // File > Save and Save as... (standard item 28): Go asks for the file (SQLite, DuckDB or Excel) and writes it
  const save = (saveAs: boolean) => runExport(dbName, () => bridge?.SaveDatabase?.(saveAs));

  // marked rows (standard item 31): the marks of the table on screen; Go returns those rows in table order
  const tableMarks = marks[shownTable];
  const markList = useMemo(() => [...(tableMarks?.values() ?? [])], [tableMarks]);
  useEffect(() => {
    const req = ++markReq.current;
    const table = shownTable;
    if (markList.length === 0) {
      setMarkedRows({ table, rows: [] });
      return;
    }
    Promise.resolve(window.go?.main?.App?.MarkedRows?.(table, markList))
      .then((found) => req === markReq.current && setMarkedRows({ table, rows: found ?? [] }))
      .catch((err) => req === markReq.current && fail(err));
  }, [markList, shownTable]);
  const shownMarked = markedRows.table === shownTable ? markedRows.rows : NO_ROWS;
  const markCount = shownMarked.length;
  const onlyShown = onlyMarked && markCount > 0;
  useEffect(() => {
    if (markCount === 0) setOnlyMarked(false); // with no mark left the box goes away; the next mark shows every row
  }, [markCount]);
  const isMarked = (row: Row) => !!tableMarks?.has(rowKey(row, tableColumns));
  const toggleMark = (row: Row) =>
    setMarks((old) => {
      const next = new Map(old[shownTable]);
      const key = rowKey(row, tableColumns);
      if (!next.delete(key)) next.set(key, row);
      return { ...old, [shownTable]: next };
    });
  const unmarkAll = () => setMarks((old) => ({ ...old, [shownTable]: new Map() }));
  const exportMarked = (format: string) => runExport(shownTable, () => bridge?.ExportMarked?.(shownTable, format, markList));

  // Terms tab (standard item 32): Go searches every column of the tables in the engine, as a job with progress and
  // Cancel; the answer of an older search never shows
  const termsInfo = useMemo(() => parseTerms(termsText), [termsText]);
  async function runTerms() {
    const b = window.go?.main?.App;
    if (!b?.SearchTerms || termsInfo.terms.length === 0 || tables.length === 0 || busy) return;
    const contains = match === 'contains';
    const req = ++termsReq.current;
    setTermsRes(null);
    setError('');
    setJob({ kind: 'terms', text: t('job.searching') });
    setProgress(null);
    try {
      const res = await b.SearchTerms(termsText.split(/\r?\n/), contains, termsScope === 'table' ? selectedTable : '');
      if (req !== termsReq.current) return;
      setTermsRes({ res, contains });
      setTermsTable(res.tables?.[0]?.table ?? '');
    } catch (err) {
      if (req === termsReq.current) fail(err);
    } finally {
      setJob(null);
    }
  }

  // the rows of the table chosen in the Terms list, limited as in the Data tab (Rows); asked again in another language
  // (Go names the Term column)
  useEffect(() => {
    const req = ++termGridReq.current;
    setTermGrid(null);
    if (!termsRes || !termsTable) return;
    Promise.resolve(window.go?.main?.App?.TermRows?.(termsTable, termsRes.res.terms, termsRes.contains, limit))
      .then((r) => req === termGridReq.current && r && setTermGrid({ columns: r.columns ?? [], rows: r.rows ?? [], more: r.more }))
      .catch((err) => req === termGridReq.current && fail(err));
  }, [termsRes, termsTable, limit, lang]);
  const termsHits = termsRes?.res.tables?.find((h) => h.table === termsTable)?.rows ?? 0;

  // "Copy the rows found in this table": every row found, not only the ones on screen, with the header and without the
  // Term column, so a paste in Excel gives exactly those rows
  async function copyHits() {
    try {
      const found = termsRes && (await window.go?.main?.App?.TermRows?.(termsTable, termsRes.res.terms, termsRes.contains, 0));
      if (!found) return;
      const cols = (found.columns ?? []).slice(1);
      const list = found.rows ?? [];
      await copyText([cols.map(tsvField).join('\t'), ...list.map((r) => rowToTsv(cols, r, false))].join('\r\n'), tn('copied.hits', list.length, list.length));
    } catch (err) {
      fail(err);
    }
  }
  const exportTerms = (format: string) => termsRes && runExport(dbName, () => bridge?.ExportTerms?.(termsRes.res, termsRes.contains, format));

  // the formats of one export: CSV... / Excel (.xlsx)... (and SQLite, DuckDB for the term search report)
  const formats = (list: string[], run: (format: string) => unknown): MenuItem[] => list.map((f) => ({ label: t(`export.${f}`), run: () => run(f) }));
  // the export list (standard item 28), the same under File > Export and the Export... button: a fixed list, what
  // does not apply now is disabled
  const exportItems: MenuItem[] = [
    { label: t('export.table'), on: !!selectedTable, items: formats(TABLE_FORMATS, exportTable) },
    { label: t('export.marked'), on: markList.length > 0, items: formats(TABLE_FORMATS, exportMarked) },
    { label: t('export.tableSchema'), on: !!selectedTable, items: formats(TABLE_FORMATS, (f) => runExport(selectedTable, () => bridge?.ExportSchema?.(selectedTable, f))) },
    { label: t('export.dbSchema'), on: tables.length > 0, items: formats(TABLE_FORMATS, (f) => runExport(dbName, () => bridge?.ExportSchema?.('', f))) },
    { label: t('export.allCsv'), on: tables.length > 0, run: () => runExport(dbName, () => bridge?.ExportAllCSV?.()) },
    { label: t('export.sql'), on: !!resultSql, items: formats(TABLE_FORMATS, (f) => runExport(sqlResultName, () => bridge?.ExportQuery?.(resultSql, f))) },
    { label: t('export.searchAll'), on: !!shownHits?.length, run: () => runExport(dbName, () => bridge?.ExportSearch?.(tableSearch, (shownHits ?? []).map((h) => h.table))) },
    { label: t('export.terms'), on: !!termsRes, items: formats(REPORT_FORMATS, exportTerms) },
  ];

  const visibleTables = useMemo(() => {
    const words = searchWords(tableFilter);
    return favoritesFirst(words.length ? tables.filter((tb) => hasAllWords(normalizeText(tb), words)) : tables, favorites);
  }, [tables, tableFilter, favorites]);

  // schema order = database column order (Go maps reach JS sorted by key); also gives empty tables a header
  // memoized so the search index below is built once per load, not on every keystroke
  const tableColumns = useMemo(() => (schema.length > 0 ? schema.map((c) => c.name) : Object.keys(rows[0] ?? {})), [schema, rows]);
  // Data grid: the marked rows always on top, in table order, then the rows of the search that are not marked (only
  // the marked ones with View > Only marked rows)
  const dataRows = useMemo(() => {
    if (onlyShown) return shownMarked;
    if (shownMarked.length === 0) return rows;
    const keys = new Set(shownMarked.map((r) => rowKey(r, tableColumns)));
    return [...shownMarked, ...rows.filter((r) => !keys.has(rowKey(r, tableColumns)))];
  }, [onlyShown, shownMarked, rows, tableColumns]);
  const gridColumns = useMemo(
    () => (view === 'sql' ? (result?.columns ?? []) : view === 'terms' ? (termGrid?.columns ?? []) : tableColumns),
    [view, result, termGrid, tableColumns],
  );
  const gridRows = useMemo(() => (view === 'sql' ? (result?.rows ?? []) : view === 'terms' ? (termGrid?.rows ?? []) : dataRows), [view, result, termGrid, dataRows]);
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
  const copyColumns = view === 'terms' ? gridColumns.slice(1) : gridColumns; // Terms: without the Term column
  const copyRow = (withHeader: boolean) =>
    sel && copyText(rowToTsv(copyColumns, sel.row, withHeader), t(withHeader ? 'copied.rowHeader' : 'copied.row'));
  const copyLog = () => copyText(logLines.map((e) => e.line).join('\r\n'), t('copied.log'));
  const filterBySel = () => sel && applyFilters(withFilter(filters, { column: sel.col, value: sel.row[sel.col] ?? null }));
  const busy = job !== null;
  const nullText = showNull ? t('cell.null') : '';
  // log collapsed: the most important unread line (error, then warning) takes the status bar
  const shownStatus = logOpen ? { text: error || status, level: error ? 'error' : 'info', unread: 0 } : statusLine(logLines, readMark, status, error);
  const viewName = (v: View) => t(`tab.${v}`); // "Schema" without the column count (standard item 15)

  const reload = () => openPath(openedPath); // nothing open: the default database, as the Python version
  const focusSearch = () => {
    const focus = () => {
      searchRef.current?.focus();
      searchRef.current?.select();
    };
    if (view !== 'terms') return focus();
    setView('data'); // the Terms tab has no search field: the Data search
    setTimeout(focus); // the field exists after this render
  };
  const showView = (v: View) => {
    if (tables.length === 0) return;
    setView(v);
    if (v === 'sql') setTimeout(() => sqlRef.current?.focus()); // the field exists after this render
    if (v === 'terms') setTimeout(() => termsRef.current?.focus());
  };
  // View > Go to the table list (Ctrl+T): the focus on the open table of the list, or on its first table
  const goTables = () => ((document.querySelector('.sidebar [aria-current]') ?? document.querySelector('.sidebar .table-item')) as HTMLElement | null)?.focus();

  latest.current = {
    ...{ openPath, loadDatabase, quit, reload, focusSearch, showView },
    save: (saveAs: boolean) => dbName && save(saveAs),
    closeDatabase: () => dbName && closeDatabase(),
    focusTables: goTables,
    toggleFavorite: () => selectedTable && toggleFavorite(selectedTable),
    modal: () => !!(about || colsOpen || question || exportAsk || displayWarn),
    busy: () => busy,
  };

  // menus drawn from data (standard item 28: every button has a menu item, the same tree in the 4 apps); items are
  // disabled as their button
  const radios = <V,>(values: V[], current: V, label: (v: V) => string, choose: (v: V) => void): MenuItem[] =>
    values.map((v) => ({ label: label(v), checked: v === current, radio: true, run: () => choose(v) }));
  const fileItems: MenuItem[] = [
    { label: t('menu.open'), kbd: 'Ctrl+O', run: () => loadDatabase() },
    { label: t('menu.openTyped'), run: openTyped },
    { label: t('menu.reopen'), kbd: 'F5', run: reload },
    { sep: true },
    { label: t('menu.save'), kbd: 'Ctrl+S', on: !!dbName, run: () => save(false) },
    { label: t('menu.saveAs'), kbd: 'Ctrl+Shift+S', on: !!dbName, run: () => save(true) },
    { label: t('menu.export'), on: tables.length > 0, items: exportItems },
    { sep: true },
    { label: t('menu.close'), kbd: 'Ctrl+W', on: !!dbName, run: () => closeDatabase() },
    { sep: true },
    { label: t('menu.exit'), kbd: 'Ctrl+Q', run: () => quit() },
  ];
  const editItems: MenuItem[] = [
    { label: t('cellmenu.copy'), kbd: 'Ctrl+C', on: !!sel, run: copyCell },
    { label: t('cellmenu.copyRow'), kbd: 'Ctrl+Shift+C', on: !!sel, run: () => copyRow(false) },
    { label: t('cellmenu.copyRowHeader'), on: !!sel, run: () => copyRow(true) },
    { label: t('menu.copyLog'), on: logLines.length > 0, run: copyLog },
    { sep: true },
    { label: t('menu.search'), kbd: 'Ctrl+F', on: tables.length > 0, run: focusSearch },
    { label: t('cellmenu.filter'), on: view === 'data' && !!sel, run: filterBySel },
    { label: t('cellmenu.clear'), on: view === 'data' && filters.length > 0, run: () => applyFilters([]) },
    { sep: true },
    { label: t('menu.mark'), kbd: t('kbd.space'), on: view === 'data' && !!sel, run: () => sel && toggleMark(sel.row) },
    { label: t('menu.unmarkAll'), on: markList.length > 0, run: unmarkAll },
  ];
  const viewItems: MenuItem[] = [
    ...VIEWS.map((v, i): MenuItem => ({ label: viewName(v), kbd: `Ctrl+${i + 1}`, on: tables.length > 0, checked: view === v, radio: true, run: () => showView(v) })),
    { sep: true },
    { label: t('rows.label'), items: radios(ROW_LIMITS, limit, String, changeLimit) },
    { label: t('cols.button'), on: view === 'data' && gridColumns.length > 0, run: () => setColsOpen(true) },
    { label: t('scope.label'), on: view === 'data' && tables.length > 0, items: radios(SCOPES, scope, (s) => t(`scope.${s}`), setScope) },
    { label: t('menu.onlyMarked'), on: markCount > 0, checked: onlyShown, run: () => setOnlyMarked(!onlyShown) },
    { label: t('menu.goTables'), kbd: 'Ctrl+T', on: tables.length > 0, run: goTables },
    { label: t('fav.toggle'), kbd: 'Ctrl+D', on: !!selectedTable, run: () => toggleFavorite(selectedTable) },
    { sep: true },
    { label: t('menu.runSql'), kbd: 'Ctrl+Enter', on: view === 'sql' && !!sql.trim() && !querying, run: () => runSql() },
    { label: t('terms.run'), kbd: 'Ctrl+Enter', on: view === 'terms' && termsInfo.terms.length > 0, run: runTerms },
    { sep: true },
    { label: t('menu.log'), kbd: 'Ctrl+L', checked: logOpen, run: () => toggleLog() },
  ];
  const settingsItems: MenuItem[] = [
    { label: t('menu.theme'), items: radios(THEMES, theme, (th) => t(`theme.${th}`), chooseTheme) },
    { label: t('menu.language'), items: LANGS.map((l) => ({ label: t(`lang.${l}`), lang: l, checked: lang === l, radio: true, run: () => chooseLang(l) })) },
    { label: t('menu.searchScope'), items: radios(SCOPES, defaultScope, (s) => t(`scope.${s}`), chooseDefaultScope) },
    { label: t('menu.termMatch'), items: radios(MATCHES, defaultMatch, (m) => t(`terms.${m}`), chooseDefaultMatch) },
    { label: t('menu.showNull'), checked: showNull, run: () => chooseShowNull(!showNull) },
  ];
  const menus: [MenuName, string, MenuItem[]][] = [
    ['file', t('menu.file'), fileItems],
    ['edit', t('menu.edit'), editItems],
    ['view', t('menu.view'), viewItems],
    ['settings', t('menu.settings'), settingsItems],
    ['help', t('menu.help'), [{ label: t('about.title'), run: openAbout }]],
  ];
  const copyItems: MenuItem[] = [
    { label: t('cellmenu.copy'), kbd: 'Ctrl+C', focus: true, run: copyCell },
    { label: t('cellmenu.copyRow'), kbd: 'Ctrl+Shift+C', run: () => copyRow(false) },
    { label: t('cellmenu.copyRowHeader'), run: () => copyRow(true) },
  ];
  // menu of a grid cell (standard item 14: the value filters, then the copies); Data adds the marks, Terms the copy of
  // every row found and the report
  const cellItems: MenuItem[] =
    view === 'data'
      ? [
          { label: t('cellmenu.filter'), run: filterBySel },
          { label: t('cellmenu.clear'), on: filters.length > 0, run: () => applyFilters([]) },
          { sep: true },
          ...copyItems,
          { sep: true },
          { label: t('menu.mark'), kbd: t('kbd.space'), run: () => sel && toggleMark(sel.row) },
          { label: t('mark.export'), on: markList.length > 0, items: formats(TABLE_FORMATS, exportMarked) },
          { label: t('menu.unmarkAll'), on: markList.length > 0, run: unmarkAll },
        ]
      : view === 'terms'
        ? [...copyItems, { sep: true }, { label: t('terms.copyHits'), run: copyHits }, { label: t('export.terms'), items: formats(REPORT_FORMATS, exportTerms) }]
        : copyItems;

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

  // keys of a grid: Ctrl+C copies the selected cell (unless the user marked text with the mouse: native copy),
  // Ctrl+Shift+C its row, Space marks or unmarks its row (Data tab; on the box itself the box does it)
  const gridKeys = (e: React.KeyboardEvent) => {
    const k = e.key.toLowerCase();
    const ctrl = e.ctrlKey || e.metaKey;
    const action =
      !sel ? null
      : ctrl && k === 'c' && e.shiftKey ? () => copyRow(false)
      : ctrl && k === 'c' && !window.getSelection()?.toString() ? copyCell
      : e.key === ' ' && view === 'data' && !(e.target instanceof HTMLInputElement) ? () => toggleMark(sel.row)
      : null;
    if (!action) return;
    e.preventDefault();
    action();
  };

  const grid = (
    <table>
      <thead>
        <tr>
          {/* Data: the narrow column of the boxes that mark rows, no title (its tip says what it is) */}
          {view === 'data' && <th className="mark" title={t('mark.tip')} />}
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
            {view === 'data' && (
              <td className="mark">
                <input type="checkbox" aria-label={t('mark.tip')} checked={isMarked(row)} onChange={() => toggleMark(row)} />
              </td>
            )}
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
          {menus.map(([name, label, items]) => (
            <div className="menu-root" key={name}>
              {menuButton(name, label)}
              {openMenu === name && <MenuList items={items} label={label} className="dropdown" />}
            </div>
          ))}
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
            {openMenu === 'exportBar' && <MenuList items={exportItems} label={t('menu.export')} className="dropdown right" />}
          </div>
        </div>
      </header>

      <nav className="sidebar" aria-label={t('sidebar.label')}>
        <input
          type="search"
          placeholder={tn('sidebar.filter', tables.length, tables.length)}
          aria-label={tn('sidebar.filter', tables.length, tables.length)}
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
                onContextMenu={(e) => {
                  e.preventDefault();
                  setOpenMenu(null);
                  // the menu key may report no position: open the menu under the table
                  const r = e.currentTarget.getBoundingClientRect();
                  setMenu(e.clientX || e.clientY ? { x: e.clientX, y: e.clientY, table } : { x: r.left + 8, y: r.bottom, table });
                }}
              >
                {/* a favorite: a discreet star before the name, in the text color */}
                <span className="name">{favorites.has(table) ? `★ ${table}` : table}</span>
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
              {/* the Terms tab has its own field and selectors below */}
              {view !== 'terms' && (
                <input
                  ref={searchRef}
                  type="search"
                  className="search"
                  placeholder={view === 'sql' ? t('sql.searchPlaceholder') : t('search.label')}
                  aria-label={view === 'sql' ? t('sql.searchLabel') : t('search.label')}
                  title={t('search.tip')}
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                  onKeyDown={(e) => e.key === 'Enter' && setTableSearch(search.trim())}
                />
              )}
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

            {/* Terms (standard item 32), top to bottom: the terms, one line of selectors, the summary, the tables found
                beside the rows of the chosen one, the terms not found */}
            {view === 'terms' && (
              <>
                <textarea
                  ref={termsRef}
                  className="terms-text"
                  rows={8}
                  aria-label={t('tab.terms')}
                  placeholder={t('terms.hint')}
                  spellCheck={false}
                  value={termsText}
                  onChange={(e) => setTermsText(e.target.value)}
                  onKeyDown={(e) => {
                    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
                      e.preventDefault();
                      runTerms();
                    }
                  }}
                />
                <div className="terms-bar">
                  <div className="tabs" role="radiogroup" aria-label={t('menu.termMatch')} title={t('terms.matchTip')}>
                    {MATCHES.map((m) => (
                      <button key={m} role="radio" aria-checked={match === m} onClick={() => setMatch(m)}>
                        {t(`terms.${m}`)}
                      </button>
                    ))}
                  </div>
                  <div className="tabs" role="radiogroup" aria-label={t('scope.label')}>
                    {SCOPES.map((s) => (
                      <button key={s} role="radio" aria-checked={termsScope === s} onClick={() => setTermsScope(s)}>
                        {t(`scope.${s}`)}
                      </button>
                    ))}
                  </div>
                  <button className="primary" disabled={termsInfo.terms.length === 0} onClick={runTerms} title="Ctrl+Enter">
                    {t('terms.run')}
                  </button>
                  <span className="info">
                    {tn('terms.count', termsInfo.terms.length, termsInfo.terms.length) + (termsInfo.repeated ? tn('terms.repeated', termsInfo.repeated, termsInfo.repeated) : '')}
                  </span>
                </div>
                {termsRes && (
                  <>
                    <p className="info">
                      {t(
                        'terms.summary',
                        tn('terms.found', termsRes.res.terms.length, termsRes.res.terms.length - termsRes.res.notFound.length, termsRes.res.terms.length),
                        tn('terms.rows', sumRows(termsRes.res.tables), sumRows(termsRes.res.tables)),
                        tn('terms.tables', termsRes.res.tables.length, termsRes.res.tables.length),
                      )}
                    </p>
                    <div className="terms-hits">
                      <ul className="hits">
                        {termsRes.res.tables.map((h) => (
                          <li key={h.table}>
                            <button className="table-item" aria-current={h.table === termsTable ? 'true' : undefined} onClick={() => setTermsTable(h.table)}>
                              {t('hits.item', h.table, h.rows)}
                            </button>
                          </li>
                        ))}
                      </ul>
                      <div className="table-container" tabIndex={0} role="region" aria-label={t('grid.region', termsTable, viewName(view))} onKeyDown={gridKeys}>
                        {termGrid && grid}
                      </div>
                    </div>
                    <footer className="info">{termGrid && tn('info.showing', termsHits, termsTable, termGrid.rows.length, termsHits)}</footer>
                    <div className="terms-missing">
                      <h3>{t('terms.notFound', termsRes.res.notFound.length)}</h3>
                      <textarea readOnly rows={4} aria-label={t('terms.notFound', termsRes.res.notFound.length)} value={termsRes.res.notFound.join('\n')} />
                      <button
                        disabled={termsRes.res.notFound.length === 0}
                        onClick={() => copyText(termsRes.res.notFound.join('\r\n'), tn('copied.terms', termsRes.res.notFound.length, termsRes.res.notFound.length))}
                      >
                        {t('status.copy')}
                      </button>
                    </div>
                  </>
                )}
              </>
            )}

            {/* tabIndex: the scroll area must be reachable and scrollable by keyboard */}
            {view !== 'terms' && (
            <div
              className="table-container"
              tabIndex={0}
              role="region"
              aria-label={t('grid.region', view === 'sql' ? t('sql.result') : selectedTable, viewName(view))}
              onKeyDown={gridKeys}
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
            )}

            {view !== 'terms' && (
              <footer className="info">
                {/* with marked rows: their count, and on the right the discreet "Only marked" (View > Only marked rows) */}
                {view === 'data' && !searchAll && markCount > 0 && (
                  <label className="only-marked">
                    <input type="checkbox" checked={onlyShown} onChange={(e) => setOnlyMarked(e.target.checked)} />
                    {t('mark.only')}
                  </label>
                )}
                {view === 'sql'
                  ? result && tn('info.sql', result.rows.length, result.rows.length) + (result.more ? t('info.sqlLimit', limit) : '')
                  : searchAll
                    ? shownHits
                      ? tn('info.searchAll', shownHits.length, shownHits.length, tableSearch)
                      : searching && progressText(t('job.searching'), progress, t)
                    : tn(narrowed ? 'info.found' : 'info.showing', rowCount, shownTable, rows.length, rowCount) + (markCount > 0 ? tn('mark.count', markCount, markCount) : '')}
                {sqlSearching && tn('info.searchSql', visibleRows.length, visibleRows.length, search.trim())}
              </footer>
            )}
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
            <button onClick={copyLog} disabled={logLines.length === 0}>
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
          <span className="badge" title={tn('log.unread', shownStatus.unread, shownStatus.unread)}>
            {shownStatus.unread}
          </span>
        )}
        {hiddenCount > 0 && <span className="source">{tn('hidden', hiddenCount, hiddenCount)}</span>}
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

      {/* table list: add to or remove from the favorites */}
      {menu?.table !== undefined && (
        <MenuList
          key={`${menu.x},${menu.y}`}
          place={keepInWindow}
          items={[{ label: favorites.has(menu.table) ? t('fav.remove') : t('fav.add'), focus: true, run: () => toggleFavorite(menu.table!) }]}
          label={t('sidebar.label')}
          className="menu"
          style={{ left: menu.x, top: menu.y }}
        />
      )}

      {menu && menu.header === undefined && !menu.status && menu.table === undefined && (
        <MenuList
          key={`${menu.x},${menu.y}`}
          place={keepInWindow}
          items={cellItems}
          label={t('cellmenu.label')}
          // in the right half of the window its submenus open to the left
          className={menu.x > window.innerWidth / 2 ? 'menu cell-menu right' : 'menu cell-menu'}
          style={{ left: menu.x, top: menu.y }}
        />
      )}

      {job && (
        <div className="backdrop">
          <div className="about progress" role="dialog" aria-modal="true" aria-label={job.text}>
            <p>{job.kind === 'terms' && progress?.label ? t('terms.progress', progress.done, progress.total, progress.label) : progressText(job.text, progress, t)}</p>
            <progress max={progress?.total || undefined} value={progress?.total ? progress.done : undefined} />
            <button autoFocus onClick={() => bridge?.CancelJob?.()}>
              {t('job.cancel')}
            </button>
          </div>
        </div>
      )}

      {question && <QuestionDialog {...question} t={t} />}

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

// The text of a dialog button, as wide and tall as the longest of all = every text of its row in the 3 languages
// (owner, 26/11: the buttons of a dialog have one size): the other texts sit invisible in the same grid cell
function Sized({ text, all }: { text: string; all: string[] }) {
  return (
    <span className="sized">
      <span>{text}</span>
      {all.map((s, i) => (
        <span key={i} className="ghost" aria-hidden="true">
          {s}
        </span>
      ))}
    </span>
  );
}

// A question on exit (standard item 27): title, text and the buttons in screen order, the first one focused (Enter);
// Esc and the x answer null, as Back
function QuestionDialog({ title, text, buttons, resolve, t }: Question & { resolve: (answer: string | null) => void; t: T }) {
  const all = LANGS.flatMap((l) => buttons.map((b) => translate(l, b.key)));
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && resolve(null);
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  return (
    <div className="backdrop">
      <div className="about conversion" role="dialog" aria-modal="true" aria-labelledby="question-title">
        <div className="dialog-head">
          <h2 id="question-title">{title}</h2>
          <button className="dialog-x" aria-label={t('about.close')} title={t('about.close')} onClick={() => resolve(null)}>
            ×
          </button>
        </div>
        <p>{text}</p>
        <div className="col-actions">
          {buttons.map((b, i) => (
            <button key={b.value} className={b.cls} autoFocus={i === 0} onClick={() => resolve(b.value)}>
              <Sized text={t(b.key)} all={all} />
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

// Table export with the search active: the whole table, only the rows found, or Cancel (Esc)
type ExportAskProps = { table: string; found: number; t: T; tn: TN; onAnswer: (onlyFound: boolean | null) => void };
function ExportAskDialog({ table, found, t, tn, onAnswer }: ExportAskProps) {
  const all = LANGS.flatMap((l) => [translate(l, 'exportAsk.all'), translateN(l, 'exportAsk.found', found, found), translate(l, 'job.cancel')]);
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
            <Sized text={t('exportAsk.all')} all={all} />
          </button>
          <button onClick={() => onAnswer(true)}>
            <Sized text={tn('exportAsk.found', found, found)} all={all} />
          </button>
          <button className="end" onClick={() => onAnswer(null)}>
            <Sized text={t('job.cancel')} all={all} />
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
  const sizes = LANGS.flatMap((l) => ['cols.showAll', 'cols.hideAll', 'cols.close'].map((k) => translate(l, k)));
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
          <button onClick={() => showListed(true)}>
            <Sized text={t('cols.showAll')} all={sizes} />
          </button>
          <button onClick={() => showListed(false)}>
            <Sized text={t('cols.hideAll')} all={sizes} />
          </button>
          <button className="primary end" onClick={onClose}>
            <Sized text={t('cols.close')} all={sizes} />
          </button>
        </div>
      </div>
    </div>
  );
}

export default App;
