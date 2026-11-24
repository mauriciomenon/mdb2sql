<script>
  // NIVEL BASICO: Visualizador e conversor de bancos (Access, SQLite, DuckDB)
  // Menus: File (exportar, fechar), View (log), Settings (tema, idioma), Help (sobre). Abas: Data, Schema, SQL.
  // Todo texto da tela vem dos catalogos de idioma (i18n.js); i18n.test.js confere que nada fica fora.
  // NIVEL TECNICO: Svelte 5 runes; every backend call goes through Tauri invoke()

  import { invoke } from '@tauri-apps/api/core';
  import { listen } from '@tauri-apps/api/event';
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import { onMount, tick } from 'svelte';
  import Grid from './Grid.svelte';
  import {
    columnCellWidth,
    importantEntry,
    filterLabel,
    fold,
    hasAllWords,
    searchWords,
    setListed,
    statusLine,
    toggleShown,
    visibleColumns,
    withFilter,
  } from './grid.js';
  import { LANGS, describe, translator } from './i18n.js';
  import { defaultSaveDir, dirOf, joinPath, stem, suggestedName } from './paths.js';

  const LIMITS = [100, 500, 1000];
  // null devolve a janela (barra de titulo e webview) ao tema do sistema
  const THEMES = [
    ['theme.system', null],
    ['theme.light', 'light'],
    ['theme.dark', 'dark'],
  ];
  // File > Export: [chave do texto, scope, format]; ordem do app: SQLite, DuckDB, Excel
  const EXPORTS = [
    ['export.dbSqlite', 'database', 'sqlite'],
    ['export.dbDuckdb', 'database', 'duckdb'],
    ['export.dbXlsx', 'database', 'xlsx'],
    ['export.tableCsv', 'table', 'csv'],
    ['export.tableXlsx', 'table', 'xlsx'],
    ['export.sqlCsv', 'sql', 'csv'],
    ['export.sqlXlsx', 'sql', 'xlsx'],
  ];
  // dialogo Abrir, sempre nesta ordem: Access, SQLite, DuckDB
  const OPEN_FILTERS = [
    ['open.all', ['accdb', 'mdb', 'sqlite', 'sqlite3', 'db', 'duckdb']],
    ['open.access', ['accdb', 'mdb']],
    ['open.sqlite', ['sqlite', 'sqlite3', 'db']],
    ['open.duckdb', ['duckdb']],
    ['open.any', ['*']],
  ];
  const TABS = [
    ['data', 'tabs.data'],
    ['schema', 'tabs.schema'],
    ['sql', 'tabs.sql'],
  ];
  // preferencias gravadas no webview (ficam entre execucoes)
  const THEME_KEY = 'mdb2sql.theme';
  const LAST_DIR_KEY = 'mdb2sql.lastDir';
  const LANG_KEY = 'mdb2sql.lang';
  const LOG_KEY = 'mdb2sql.log'; // 'open' = painel de log aberto (padrao: recolhido)
  const NULL_KEY = 'mdb2sql.showNull'; // 'on' = celula NULL mostra "NULL" (padrao, sem valor gravado: vazia)
  const SCOPE_KEY = 'mdb2sql.searchScope'; // 'all' = a pesquisa comeca em Todas as tabelas (padrao: Esta tabela)
  // escopo da pesquisa da aba Data: seletor junto ao campo e Settings > Escopo padrao da busca
  const SCOPES = [
    ['table', 'scope.table'],
    ['all', 'scope.all'],
  ];
  // a pesquisa vai ao banco quando a digitacao para por este tempo
  const SEARCH_DELAY_MS = 300;

  function loadSetting(key) {
    try {
      return localStorage.getItem(key);
    } catch {
      return null; // sem armazenamento: vale o padrao
    }
  }

  function saveSetting(key, value) {
    try {
      if (value) localStorage.setItem(key, value);
      else localStorage.removeItem(key);
    } catch {
      // sem armazenamento: a escolha vale so ate fechar o app
    }
  }

  // idioma: ingles por padrao; a troca vale na hora (todo texto passa por t)
  const storedLang = loadSetting(LANG_KEY);
  let lang = $state(LANGS.some(([code]) => code === storedLang) ? storedLang : LANGS[0][0]);
  let t = $derived(translator(lang));
  const fmt = (n) => Number(n).toLocaleString(lang);
  // Settings > Exibir NULL (so a tela, a gosto do usuario): desligado por padrao, a celula NULL fica vazia; ligado,
  // mostra "NULL". Copiar, pesquisar e exportar nao mudam
  let showNull = $state(loadSetting(NULL_KEY) === 'on');
  let nullText = $derived(showNull ? t('grid.null') : '');

  let openMenu = $state(null); // 'file' | 'view' | 'settings' | 'help'
  let tab = $state('data');
  let themeIndex = $state(0);
  let aboutDialog;
  let aboutInfo = $state.raw(null); // dados do comando about (versoes, build, leitor do Access, links)
  let columnsDialog;
  let progressDialog;
  let progress = $state.raw(null); // { label, done, total, item } da exportacao em andamento
  let convertDialog;
  let x11Dialog;
  let x11 = $state.raw(null); // Linux sem X11: { missing, display, distro, command, link } (backend display.rs)

  let dbPath = $state('');
  let openedPath = $state('');
  let source = $state('');
  let converted = $state(false); // ha SQLite convertido do Access ainda nao salvo nem apagado
  let tables = $state([]);
  let tableText = $state(''); // texto do filtro de tabelas; tableFilter e o que esta valendo na lista
  let tableFilter = $state('');
  let tableTimer;
  let selectedTable = $state('');
  let columns = $state([]); // [{ name, type, null }] na ordem real da tabela
  // raw: linhas so sao trocadas inteiras, sem proxy por celula
  let rows = $state.raw([]);
  let rowCount = $state(0); // linhas da tabela inteira
  let matchCount = $state(0); // linhas que passam pelos filtros e pela pesquisa
  // valem para a tabela aberta; trocar de tabela ou de arquivo zera
  let hidden = $state.raw(new Set()); // nomes das colunas ocultas
  let filters = $state.raw([]); // [{ column, value }] aplicados na consulta ao banco (AND)
  let search = $state(''); // pesquisa na tabela inteira, no banco
  let searchTimer;
  let defaultScope = $state(loadSetting(SCOPE_KEY) === 'all' ? 'all' : 'table');
  let scope = $state(defaultScope); // 'table' (tabela aberta) | 'all' (todas as tabelas)
  let found = $state.raw(null); // { words, tables: [{ table, count }] } da ultima pesquisa em todas as tabelas
  let everywhere = $derived(scope === 'all' && search.trim() !== '');
  let limit = $state(LIMITS[0]);
  let busy = $state(false);

  // status = [chave, valores] da ultima acao; error = { err, context } do ultimo erro (null depois de uma acao ok).
  // Tudo guardado como chave: troca de idioma traduz de novo a barra de status e o log
  let status = $state.raw(['status.noDatabase', {}]);
  let error = $state.raw(null);
  const errorLine = (err, context) => (context ? `${t(context)}: ` : '') + describe(t, err);
  // barra de status: erro do motor em uma linha (statusLine); o texto inteiro fica no log
  let statusText = $derived(t(...status));
  let errorText = $derived(error ? errorLine(error.err, error.context) : '');
  let statusMenu = $state.raw(null); // { x, y } do menu Copiar da barra de status
  // log da sessao: { time, level: 'error' | 'warning' | 'info', key, values } | { ..., err, context } | { ..., render }
  let log = $state.raw([]);
  let logOpen = $state(loadSetting(LOG_KEY) === 'open');
  let seen = $state(0); // entradas do log ja vistas (painel aberto)
  let logArea = $state();
  const entryText = (e) => (e.render ? e.render() : e.err !== undefined ? errorLine(e.err, e.context) : t(e.key, e.values));
  let logText = $derived(log.map((e) => `${e.time}  ${entryText(e)}`).join('\n'));
  // log recolhido: erros e avisos nao vistos; a barra de status mostra o ultimo erro > ultimo aviso > ultima acao
  let unread = $derived(logOpen ? [] : log.slice(seen).filter((e) => e.level !== 'info'));
  let headline = $derived.by(() => {
    const pick = importantEntry(unread);
    if (pick) return { text: statusLine(entryText(pick)), level: pick.level };
    return errorText ? { text: statusLine(errorText), level: 'error' } : { text: statusText, level: 'info' };
  });

  let sql = $state('');
  let sqlResult = $state.raw(null); // { columns, rows, truncated }
  let lastSql = ''; // SQL que gerou sqlResult (o que a exportacao repete)

  // pergunta do SQLite convertido: escolha lembrada so nesta sessao ('save' | 'delete')
  let remembered = null;
  let rememberChoice = $state(false);
  let answer = null; // resolve da pergunta aberta
  let lastSqliteDir = '';

  let visibleTables = $derived.by(() => {
    const words = searchWords(tableFilter);
    return tables.filter((name) => hasAllWords(fold(name), words));
  });
  let shownColumns = $derived(visibleColumns(columns, hidden));
  let columnSearch = $state(''); // busca do dialogo Colunas...
  let listedColumns = $derived.by(() => {
    const words = searchWords(columnSearch);
    return columns.filter((col) => hasAllWords(fold(col.name), words));
  });
  let schemaColumns = $derived(
    ['schema.number', 'schema.column', 'schema.type', 'schema.nullable'].map((key) => ({ name: t(key), type: '' }))
  );
  // aviso de X11 em 3 linhas curtas (dialogo e log): situacao, o fato (sem rotulo "Falta:"), comando da distro (sem comando em
  // distro desconhecida)
  let x11Missing = $derived(
    x11 ? t(x11.missing === 'no_display' ? 'x11.noDisplay' : 'x11.noServer', { display: x11.display }) : ''
  );
  let x11Text = $derived(
    x11 ? [t('x11.wayland'), x11Missing, x11.command ? `${x11.distro}: ${x11.command}` : ''].filter(Boolean).join(' ') : ''
  );
  let aboutRows = $derived.by(() => {
    if (!aboutInfo) return [];
    const access = aboutInfo.access_odbc
      ? 'about.accessOdbc'
      : aboutInfo.mdbtools_embedded
        ? 'about.accessEmbedded'
        : 'about.accessSystem';
    return [
      [t('about.build'), aboutInfo.build],
      [t('about.stack'), aboutInfo.stack],
      [t('about.window'), aboutInfo.webview],
      [t('about.engines'), aboutInfo.engines],
      [t('about.access'), t(access, { version: aboutInfo.mdbtools })],
      [t('about.author'), aboutInfo.author],
      [t('about.license'), t('about.licenseValue')],
    ];
  });

  $effect(() => {
    document.documentElement.lang = lang;
  });
  // o log rola sozinho para a ultima mensagem
  $effect(() => {
    logText;
    if (logArea) logArea.scrollTop = logArea.scrollHeight;
  });

  function note(level, entry) {
    const time = new Date().toLocaleTimeString(lang, { hour12: false });
    log = [...log, { time, level, ...entry }];
  }

  const showStatus = (key, values = {}) => {
    error = null;
    status = [key, values];
    note('info', { key, values });
  };
  // context: chave da frase que vem antes do detalhe do motor ("Could not open the database: <detalhe>")
  const showError = (err, context) => {
    error = { err: String(err), context };
    note('error', error);
  };

  // abre/recolhe o painel de log (seta no log e na barra de status, View > Log, Ctrl+L); a escolha fica gravada
  function setLog(open) {
    openMenu = null;
    logOpen = open;
    seen = log.length;
    saveSetting(LOG_KEY, open ? 'open' : 'closed');
  }

  function canExport(scope) {
    if (busy || !openedPath) return false;
    if (scope === 'table') return !!selectedTable;
    if (scope === 'sql') return !!sqlResult?.columns.length;
    return true;
  }

  function toggleMenu(event, name) {
    event.stopPropagation();
    statusMenu = null;
    openMenu = openMenu === name ? null : name;
  }

  onMount(() => {
    const stored = THEMES.findIndex(([, value]) => value === loadSetting(THEME_KEY));
    if (stored > 0) setTheme(stored);
    const stops = [
      listen('open-progress', ({ payload: p }) => {
        status = [`status.${p.step}`, { done: p.done + 1, total: p.total, item: p.item }];
        if (p.done === 0) note('info', { key: status[0], values: status[1] });
      }),
      listen('export-progress', ({ payload }) => {
        if (progress) progress = { ...progress, ...payload };
      }),
      // fechar a janela com SQLite convertido pendente: o backend segura e pergunta aqui
      listen('close-requested', async () => {
        if (await settleConverted()) await invoke('exit_app');
      }),
    ];
    // Linux sem X11 (janela no Wayland de reserva): aviso a cada abertura, enquanto a condicao existir
    invoke('display_warning').then((warning) => {
      if (!warning) return;
      x11 = warning;
      note('warning', { render: () => `${t('x11.title')}: ${x11Text}` });
      x11Dialog.showModal();
      x11Dialog.querySelector('button.default').focus();
    });
    // caminho da linha de comando ou de MDB2SQL_DB_PATH
    invoke('startup_path').then((path) => {
      if (path) {
        dbPath = path;
        openDatabase();
      }
    });
    return () => stops.forEach((stop) => stop.then((unlisten) => unlisten()));
  });

  // NIVEL BASICO: Pergunta "Salvar o SQLite convertido?" e espera a resposta: 'save', 'delete' ou 'cancel'
  function ask() {
    rememberChoice = false;
    convertDialog.showModal();
    convertDialog.querySelector('button.save').focus(); // o showModal poe o foco na caixa de lembrar
    return new Promise((resolve) => (answer = resolve));
  }

  function reply(choice) {
    convertDialog.close();
    answer?.(choice);
    answer = null;
  }

  // NIVEL BASICO: Antes de fechar o banco, abrir outro ou sair: salva ou apaga o SQLite convertido do Access
  // (pergunta uma vez; a escolha pode valer para o resto da sessao). false = o usuario cancelou
  async function settleConverted() {
    if (!converted) return true;
    if (answer) return false; // a pergunta ja esta aberta
    // dialogo de arquivo cancelado: volta para a pergunta (Esc e o X dela fecham e cancelam tudo)
    let choice = remembered; // a escolha lembrada vale so na primeira volta
    for (let auto = remembered === 'save'; ; auto = false) {
      if (!choice) choice = await ask();
      if (choice === 'cancel') return false;
      try {
        if (choice === 'save') {
          const saved = await saveConverted(auto);
          if (!saved) {
            choice = null;
            continue;
          }
          showStatus('status.sqliteSaved', { path: saved });
        } else {
          await invoke('discard_converted');
          showStatus('status.sqliteDeleted');
        }
        break;
      } catch (err) {
        showError(err);
        return false;
      }
    }
    if (rememberChoice) remembered = choice;
    converted = false;
    return true;
  }

  // NIVEL BASICO: Grava o SQLite convertido: dialogo de salvar na pasta do arquivo de origem, <nome>.sqlite.
  // auto (escolha lembrada): grava direto na ultima pasta usada; se o arquivo ja existe, abre o dialogo
  async function saveConverted(auto) {
    const name = `${stem(openedPath)}.sqlite`;
    const dir = lastSqliteDir || dirOf(openedPath);
    let path = joinPath(dir, name);
    let overwrite = false;
    if (auto) {
      try {
        await invoke('save_converted', { path, overwrite });
        return path;
      } catch (err) {
        if (!String(err).includes('[[err.exists]]')) throw err;
      }
    }
    path = await invoke('plugin:dialog|save', {
      options: {
        title: t('convert.title'),
        defaultPath: path,
        filters: [{ name: t('save.sqlite'), extensions: ['sqlite'] }],
      },
    });
    if (!path) return null; // cancelado
    overwrite = true; // o dialogo de salvar ja perguntou se substitui
    await invoke('save_converted', { path, overwrite });
    lastSqliteDir = dirOf(path);
    return path;
  }

  function resetTable() {
    selectedTable = '';
    hidden = new Set();
    filters = [];
    search = '';
    found = null;
    columns = [];
    rows = [];
    rowCount = 0;
    matchCount = 0;
  }

  // NIVEL BASICO: Abre o banco; caminho vazio usa MDB2SQL_DB_PATH ou data/sample.duckdb
  async function openDatabase(event) {
    event?.preventDefault();
    // "Copiar como caminho" do Windows cola o caminho entre aspas
    const path = dbPath.trim().replace(/^"(.*)"$/, '$1');
    if (!(await settleConverted())) return;
    busy = true;
    showStatus('status.opening');
    try {
      const opened = await invoke('load_database', { dbPath: path });
      tables = opened.tables;
      openedPath = opened.path;
      source = opened.source;
      converted = opened.converted;
      dbPath = opened.path;
      clearTimeout(tableTimer);
      tableText = tableFilter = '';
      sqlResult = null;
      lastSql = '';
      saveSetting(LAST_DIR_KEY, dirOf(opened.path));
      showStatus('status.opened', { path: opened.path, count: fmt(tables.length) });
      note('info', { key: 'status.via', values: { source } });
      resetTable();
      if (tables.length > 0) await openTable(tables[0]);
    } catch (err) {
      showError(err, 'status.openFailed');
    } finally {
      busy = false;
    }
  }

  // NIVEL BASICO: File > Close database
  async function closeDatabase() {
    openMenu = null;
    if (!openedPath || !(await settleConverted())) return;
    try {
      await invoke('close_database');
    } catch (err) {
      showError(err);
      return;
    }
    tables = [];
    openedPath = '';
    source = '';
    converted = false;
    sqlResult = null;
    lastSql = '';
    resetTable();
    showStatus('status.closed');
  }

  // NIVEL BASICO: Seletor de arquivo nativo; o arquivo escolhido e aberto em seguida
  // NIVEL TECNICO: calls the dialog plugin command directly, no npm package for one call
  async function browse() {
    openMenu = null;
    try {
      const picked = await invoke('plugin:dialog|open', {
        options: {
          title: t('open.title'),
          defaultPath: defaultSaveDir(openedPath, loadSetting(LAST_DIR_KEY)) || undefined,
          filters: OPEN_FILTERS.map(([key, extensions]) => ({ name: t(key), extensions })),
        },
      });
      if (!picked) return; // cancelado
      dbPath = String(picked);
      await openDatabase();
    } catch (err) {
      showError(err);
    }
  }

  async function setTheme(index) {
    openMenu = null;
    try {
      await getCurrentWindow().setTheme(THEMES[index][1]);
      themeIndex = index;
      saveSetting(THEME_KEY, THEMES[index][1]);
    } catch (err) {
      showError(err);
    }
  }

  function setLang(code) {
    openMenu = null;
    lang = code;
    saveSetting(LANG_KEY, code);
  }

  // Settings > Escopo padrao da busca: gravado, e passa a valer tambem na pesquisa aberta
  function setDefaultScope(next) {
    openMenu = null;
    defaultScope = next;
    saveSetting(SCOPE_KEY, next === 'all' ? 'all' : null);
    setScope(next);
  }

  function setShowNull(show) {
    openMenu = null;
    showNull = show;
    saveSetting(NULL_KEY, show ? 'on' : 'off');
  }

  // NIVEL TECNICO: __SVELTE_VERSION__ is the bundled Svelte version, injected by vite.config.js
  async function showAbout() {
    openMenu = null;
    try {
      aboutInfo = await invoke('about', { svelteVersion: __SVELTE_VERSION__ });
      aboutDialog.showModal();
      aboutDialog.querySelector('button.default').focus(); // Enter = Fechar (o showModal focaria o 1o link)
    } catch (err) {
      showError(err);
    }
  }

  // NIVEL BASICO: Abre um link do Sobre no navegador padrao
  // NIVEL TECNICO: the opener plugin only accepts the two About URLs (capabilities/default.json);
  // preventDefault keeps the webview itself from leaving the app
  function openLink(event, url) {
    event.preventDefault();
    invoke('plugin:opener|open_url', { url }).catch((err) => showError(err));
  }

  // NIVEL BASICO: Busca schema, linhas e contagens da tabela em paralelo; filtros e pesquisa vao na consulta.
  // Outra tabela comeca sem filtros e com a pesquisa `keep` (a de Todas as tabelas, ao escolher uma achada)
  async function openTable(tableName, keep = '') {
    if (!tableName) return;
    if (tableName !== selectedTable) {
      search = keep;
      hidden = new Set();
      filters = [];
    }
    selectedTable = tableName;
    busy = true;
    error = null;
    try {
      const asked = filters;
      const words = search.trim();
      const narrowed = asked.length > 0 || words !== '';
      const [schema, data, total, matching] = await Promise.all([
        invoke('get_table_schema', { tableName }),
        invoke('get_table_data', { tableName, limit, filters: asked, search: words }),
        invoke('get_row_count', { tableName, filters: [], search: '' }),
        narrowed ? invoke('get_row_count', { tableName, filters: asked, search: words }) : null,
      ]);
      // Ignora resposta atrasada se o usuario ja trocou de tabela, filtro ou pesquisa
      if (tableName !== selectedTable || asked !== filters || words !== search.trim()) return;
      columns = schema;
      rows = data;
      rowCount = total;
      matchCount = matching ?? total;
    } catch (err) {
      showError(err);
    } finally {
      busy = false;
    }
  }

  // lista de tabelas: setas, Home e End trocam a tabela aberta
  async function tableKey(event) {
    const moves = { ArrowDown: 1, ArrowUp: -1, Home: -Infinity, End: Infinity };
    if (!(event.key in moves) || !visibleTables.length) return;
    event.preventDefault();
    const at = visibleTables.indexOf(selectedTable);
    const next = Math.max(0, Math.min(visibleTables.length - 1, (at < 0 ? -1 : at) + moves[event.key]));
    await openTable(visibleTables[next]);
    await tick();
    document.getElementById(`table-${next}`)?.scrollIntoView({ block: 'nearest' });
  }

  // filtro de tabelas e pesquisa da aba Data: valem quando a digitacao para por SEARCH_DELAY_MS; Enter vale na hora
  const delayOf = (event) => (event.key === 'Enter' ? 0 : SEARCH_DELAY_MS);

  function onTableFilter(event) {
    const text = event.currentTarget.value;
    clearTimeout(tableTimer);
    tableTimer = setTimeout(() => (tableFilter = text), delayOf(event));
  }

  function onSearch(event) {
    search = event.currentTarget.value;
    clearTimeout(searchTimer);
    searchTimer = setTimeout(runSearch, delayOf(event));
  }

  // a pesquisa vale para a tabela aberta; em Todas as tabelas (com termo) procura em todas
  function runSearch() {
    if (everywhere) searchAll();
    else openTable(selectedTable);
  }

  // NIVEL BASICO: Todas as tabelas: lista as tabelas com linhas que tem o termo e quantas (backend: mesma regra da
  // pesquisa da tabela, nas colunas de texto). Resposta de um termo que ja mudou e ignorada
  async function searchAll() {
    const words = search.trim();
    busy = true;
    try {
      const tables = await invoke('search_all_tables', { search: words });
      if (words === search.trim()) found = { words, tables };
    } catch (err) {
      showError(err);
    } finally {
      busy = false;
    }
  }

  function setScope(next) {
    scope = next;
    clearTimeout(searchTimer);
    if (search.trim()) runSearch();
  }

  // escolher uma tabela achada abre ela na aba Data com a mesma pesquisa (o escopo volta para Esta tabela)
  function openFound(name) {
    scope = 'table';
    openTable(name, search);
  }

  // NIVEL BASICO: Troca os filtros e refaz a consulta da tabela aberta (as linhas vem do banco ja filtradas)
  // Se a consulta falhar (ex.: valor que o tipo da coluna nao aceita), voltam os filtros de antes,
  // que sao os das linhas que continuam na tela
  async function setFilters(next) {
    const before = filters;
    filters = next;
    await openTable(selectedTable);
    if (error && filters === next) filters = before;
  }

  // acoes do menu de clique direito da grade da aba Data (cabecalho e celula); o menu nao oculta a ultima visivel
  const gridActions = {
    hide: (name) => (hidden = toggleShown(hidden, name, columns.length)),
    columns: () => columnsDialog.showModal(),
    showAll: () => (hidden = new Set()),
    filter: (column, value) => setFilters(withFilter(filters, column, value)),
    clearFilters: () => setFilters([]),
  };

  // NIVEL BASICO: SQL livre; mostra ate o Row limit
  async function runSql() {
    if (!sql.trim()) return;
    busy = true;
    try {
      const query = sql;
      sqlResult = await invoke('run_sql', { sql: query, limit });
      lastSql = query;
      if (sqlResult.columns.length) {
        showStatus('status.query', { rows: fmt(sqlResult.rows.length) + (sqlResult.truncated ? '+' : '') });
      } else {
        showStatus('status.executed');
      }
    } catch (err) {
      showError(err, 'err.sql'); // erro do motor com o prefixo traduzido
    } finally {
      busy = false;
    }
  }

  // NIVEL BASICO: Pergunta onde salvar (pasta do arquivo aberto, senao a ultima usada) e exporta
  // fora da thread da interface, com barra de progresso e Cancelar
  async function startExport(scope, format, labelKey) {
    openMenu = null;
    if (!canExport(scope)) return;
    const label = t(labelKey).replace(/\.\.\.$/, '');
    const base = scope === 'database' ? stem(openedPath) : scope === 'table' ? selectedTable : 'query';
    const dir = defaultSaveDir(openedPath, loadSetting(LAST_DIR_KEY));
    try {
      const path = await invoke('plugin:dialog|save', {
        options: {
          title: label,
          defaultPath: joinPath(dir, suggestedName(base, format, openedPath)),
          filters: [{ name: t(`save.${format}`), extensions: [format] }],
        },
      });
      if (!path) return; // cancelado
      saveSetting(LAST_DIR_KEY, dirOf(path));
      progress = { label, done: 0, total: 0, item: '' };
      progressDialog.showModal();
      await tick();
      progressDialog.querySelector('button.default')?.focus();
      const done = await invoke('export', { scope, format, path, table: selectedTable || null, sql: lastSql || null });
      const values = {
        count: fmt(done.count),
        unit: t(scope === 'database' ? 'status.unitTables' : 'status.unitRows'),
        sheets: fmt(done.sheets ?? 0),
        path,
      };
      showStatus(done.sheets == null ? 'status.exported' : 'status.exportedSheets', values);
    } catch (err) {
      showError(err);
    } finally {
      progress = null;
      progressDialog.close();
    }
  }

  async function copyText(text) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch (err) {
      showError(String(err), 'grid.copyFailed');
      return false;
    }
  }

  // barra de status: clique direito > Copiar (o texto tambem pode ser selecionado com o mouse)
  function openStatusMenu(event) {
    event.preventDefault();
    event.stopPropagation();
    openMenu = null;
    statusMenu = { x: event.clientX, y: event.clientY };
  }

  async function copyStatus() {
    statusMenu = null;
    await copyText(headline.text);
  }

  async function copyLog() {
    if (await copyText(logText)) showStatus('status.logCopied');
  }

  // menu perto da borda: puxa para dentro da janela
  const keepInside = (node) => {
    const box = node.getBoundingClientRect();
    node.style.left = `${Math.max(4, Math.min(box.left, innerWidth - box.width - 4))}px`;
    node.style.top = `${Math.max(4, Math.min(box.top - box.height, innerHeight - box.height - 4))}px`;
  };
  const focusNow = (node) => node.focus();
</script>

<div class="app">
  <div class="menubar" role="menubar" aria-label={t('menu.main')}>
    <div class="menu-root">
      <button type="button" role="menuitem" aria-haspopup="menu" aria-expanded={openMenu === 'file'} onclick={(e) => toggleMenu(e, 'file')}>{t('menu.file')}</button>
      {#if openMenu === 'file'}
        <!-- cada acao num lugar so: abrir e o Browse... ao lado do caminho, exportar e so este menu (ui.test.js conta) -->
        <div class="dropdown" role="menu" aria-label={t('menu.file')}>
          <span class="group">{t('file.export')}</span>
          {#each EXPORTS as [key, scope, format]}
            <button type="button" role="menuitem" disabled={!canExport(scope)} onclick={() => startExport(scope, format, key)}>{t(key)}</button>
          {/each}
          <div class="separator" role="separator"></div>
          <button type="button" role="menuitem" disabled={busy || !openedPath} onclick={closeDatabase}>{t('file.close')}</button>
        </div>
      {/if}
    </div>
    <div class="menu-root">
      <button type="button" role="menuitem" aria-haspopup="menu" aria-expanded={openMenu === 'view'} onclick={(e) => toggleMenu(e, 'view')}>{t('menu.view')}</button>
      {#if openMenu === 'view'}
        <div class="dropdown" role="menu" aria-label={t('menu.view')}>
          <button type="button" role="menuitemcheckbox" aria-checked={logOpen} onclick={() => setLog(!logOpen)}>
            <span class="check">{logOpen ? '✓' : ''}</span>{t('view.log')} <kbd>{t('view.logKey')}</kbd>
          </button>
        </div>
      {/if}
    </div>
    <div class="menu-root">
      <button type="button" role="menuitem" aria-haspopup="menu" aria-expanded={openMenu === 'settings'} onclick={(e) => toggleMenu(e, 'settings')}>{t('menu.settings')}</button>
      {#if openMenu === 'settings'}
        <div class="dropdown" role="menu" aria-label={t('menu.settings')}>
          <span class="group">{t('settings.theme')}</span>
          {#each THEMES as [key], i}
            <button type="button" role="menuitemradio" aria-checked={themeIndex === i} onclick={() => setTheme(i)}>
              <span class="check">{themeIndex === i ? '●' : ''}</span>{t(key)}
            </button>
          {/each}
          <div class="separator" role="separator"></div>
          <span class="group">{t('settings.language')}</span>
          {#each LANGS as [code, name]}
            <button type="button" role="menuitemradio" aria-checked={lang === code} onclick={() => setLang(code)}>
              <span class="check">{lang === code ? '●' : ''}</span>{name}
            </button>
          {/each}
          <div class="separator" role="separator"></div>
          <button type="button" role="menuitemcheckbox" aria-checked={showNull} onclick={() => setShowNull(!showNull)}>
            <span class="check">{showNull ? '✓' : ''}</span>{t('settings.showNull')}
          </button>
          <div class="separator" role="separator"></div>
          <span class="group">{t('settings.searchScope')}</span>
          {#each SCOPES as [id, key]}
            <button type="button" role="menuitemradio" aria-checked={defaultScope === id} onclick={() => setDefaultScope(id)}>
              <span class="check">{defaultScope === id ? '●' : ''}</span>{t(key)}
            </button>
          {/each}
        </div>
      {/if}
    </div>
    <div class="menu-root">
      <button type="button" role="menuitem" aria-haspopup="menu" aria-expanded={openMenu === 'help'} onclick={(e) => toggleMenu(e, 'help')}>{t('menu.help')}</button>
      {#if openMenu === 'help'}
        <div class="dropdown" role="menu" aria-label={t('menu.help')}>
          <button type="button" role="menuitem" onclick={showAbout}>{t('help.about')}</button>
        </div>
      {/if}
    </div>
  </div>

  <header>
    <h1>{t('app.name')}</h1>
    <form onsubmit={openDatabase}>
      <label for="db-path">{t('header.database')}</label>
      <input id="db-path" type="text" bind:value={dbPath} placeholder={t('header.placeholder')} spellcheck="false" autocomplete="off" />
      <button type="button" class="secondary" onclick={browse} disabled={busy}>{t('header.browse')}</button>
      <button type="submit" disabled={busy}>{t('header.open')}</button>
    </form>
  </header>

  <dialog bind:this={aboutDialog} class="about" aria-labelledby="about-title">
    {#if aboutInfo}
      <h2 id="about-title">{t('app.name')} <span class="version">{aboutInfo.version}</span></h2>
      <p class="tagline">{t('about.description')}</p>
      <dl>
        {#each aboutRows as [label, value]}
          <dt>{label}</dt>
          <dd>{value}</dd>
        {/each}
        {#each aboutInfo.links as [label, url]}
          <dt>{label}</dt>
          <dd>
            <a href={url} title={t('about.linkTip')} onclick={(e) => openLink(e, url)} onauxclick={(e) => e.preventDefault()}>{url}</a>
          </dd>
        {/each}
      </dl>
    {/if}
    <button type="button" class="default" onclick={() => aboutDialog.close()}>{t('common.close')}</button>
  </dialog>

  <!-- Linux: X11 indisponivel, janela no Wayland (reserva); texto selecionavel -->
  <dialog bind:this={x11Dialog} class="x11" aria-labelledby="x11-title">
    <h2 id="x11-title">{t('x11.title')}</h2>
    {#if x11}
      <p>{t('x11.wayland')}</p>
      <p>{x11Missing}</p>
      {#if x11.command}
        <p class="command">
          <span>{x11.distro}:</span>
          <code>{x11.command}</code>
          <button type="button" class="secondary" onclick={() => copyText(x11.command)}>{t('x11.copy')}</button>
        </p>
      {/if}
    {/if}
    <div class="actions">
      <a href={x11?.link} onclick={(e) => openLink(e, x11.link)} onauxclick={(e) => e.preventDefault()}>{t('x11.help')}</a>
      <button type="button" class="close default" onclick={() => x11Dialog.close()}>{t('common.ok')}</button>
    </div>
  </dialog>

  <!-- SQLite convertido do Access: salvar, apagar ou cancelar (Esc = cancelar) -->
  <dialog
    bind:this={convertDialog}
    class="convert"
    aria-labelledby="convert-title"
    oncancel={(e) => {
      e.preventDefault();
      reply('cancel');
    }}
    onkeydown={(e) => {
      // Enter em qualquer ponto (fora dos botoes, que ja respondem ao Enter) = acao padrao, Salvar...
      if (e.key === 'Enter' && e.target.tagName !== 'BUTTON') {
        e.preventDefault();
        reply('save');
      }
    }}
  >
    <button type="button" class="dialog-x" aria-label={t('common.cancel')} title={t('common.cancel')} onclick={() => reply('cancel')}>×</button>
    <h2 id="convert-title">{t('convert.title')}</h2>
    <p class="file">{`${stem(openedPath)}.sqlite`}</p>
    <label class="remember"><input type="checkbox" bind:checked={rememberChoice} /> {t('convert.remember')}</label>
    <div class="actions">
      <button type="button" class="save" onclick={() => reply('save')}>{t('convert.save')}</button>
      <button type="button" class="secondary" onclick={() => reply('delete')}>{t('convert.delete')}</button>
      <button type="button" class="secondary close" onclick={() => reply('cancel')}>{t('common.cancel')}</button>
    </div>
  </dialog>

  <!-- marcar/desmarcar vale na hora; da para trocar varias colunas e fechar. A grade de caixas tem quantas
       colunas couberem (1 a 6) pelo nome mais longo; so rola na vertical. Mostrar/Ocultar todas: so as listadas -->
  <dialog
    bind:this={columnsDialog}
    class="columns"
    aria-labelledby="columns-title"
    onclose={() => (columnSearch = '')}
    style="--cell: {columnCellWidth(columns)}"
  >
    <h2 id="columns-title">{t('columns.title', { table: selectedTable })}</h2>
    <input
      class="column-search"
      type="search"
      bind:value={columnSearch}
      aria-label={t('columns.search')}
      placeholder={t('columns.search')}
      onkeydown={(e) => e.key === 'Enter' && columnsDialog.close()}
    />
    <div class="column-list" role="group" aria-label={t('columns.list')}>
      {#each listedColumns as col (col.name)}
        <label title="{col.name} ({col.type})">
          <input
            type="checkbox"
            checked={!hidden.has(col.name)}
            disabled={!hidden.has(col.name) && shownColumns.length === 1}
            onchange={() => (hidden = toggleShown(hidden, col.name, columns.length))}
          />
          <span>{col.name}</span>
          <small>{col.type}</small>
        </label>
      {:else}
        <p class="none">{t('columns.none')}</p>
      {/each}
    </div>
    <div class="actions">
      <button type="button" class="secondary" onclick={() => (hidden = setListed(hidden, listedColumns.map((c) => c.name), false))}>{t('columns.showAll')}</button>
      <button type="button" class="secondary" onclick={() => (hidden = setListed(hidden, listedColumns.map((c) => c.name), true, columns.length))}>{t('columns.hideAll')}</button>
      <span>{t('columns.count', { shown: shownColumns.length, total: columns.length })}</span>
      <button type="button" class="close default" onclick={() => columnsDialog.close()}>{t('common.close')}</button>
    </div>
  </dialog>

  <!-- Esc = Cancelar a exportacao (o dialogo fecha quando ela para) -->
  <dialog
    bind:this={progressDialog}
    class="progress"
    aria-labelledby="progress-title"
    oncancel={(e) => {
      e.preventDefault();
      invoke('cancel_export');
    }}
  >
    {#if progress}
      <h2 id="progress-title">{progress.label}</h2>
      <progress max={progress.total || 1} value={progress.total ? progress.done : 0}></progress>
      <p>
        {progress.total ? t('progress.count', { done: progress.done, total: progress.total }) : t('progress.starting')}{progress.item
          ? `: ${describe(t, progress.item)}`
          : ''}
      </p>
      <button type="button" class="secondary default" onclick={() => invoke('cancel_export')}>{t('common.cancel')}</button>
    {/if}
  </dialog>

  <div class="workspace">
    <nav aria-label={t('tables.list')}>
      <label for="table-filter">{t('tables.label', { shown: visibleTables.length, total: tables.length })}</label>
      <input
        id="table-filter"
        type="search"
        bind:value={tableText}
        oninput={onTableFilter}
        onkeydown={(e) => e.key === 'Enter' && onTableFilter(e)}
        placeholder={t('tables.filter')}
        disabled={tables.length === 0}
      />
      <!-- nome inteiro sempre (quebra a linha, nada de reticencias); setas, Home e End trocam de tabela -->
      <!-- svelte-ignore a11y_click_events_have_key_events -->
      <div
        class="table-list"
        role="listbox"
        tabindex="0"
        aria-label={t('tables.list')}
        aria-activedescendant={visibleTables.includes(selectedTable) ? `table-${visibleTables.indexOf(selectedTable)}` : undefined}
        onkeydown={tableKey}
      >
        {#each visibleTables as name, i (name)}
          <div id="table-{i}" role="option" tabindex="-1" aria-selected={name === selectedTable} class:selected={name === selectedTable} onclick={() => openTable(name)}>
            {name}
          </div>
        {/each}
      </div>
    </nav>

    <main aria-busy={busy}>
      <div class="tabs" role="tablist" aria-label={t('tabs.view')}>
        {#each TABS as [id, key]}
          <button type="button" role="tab" aria-selected={tab === id} class:active={tab === id} onclick={() => (tab = id)}>{t(key)}</button>
        {/each}
        <span class="spacer"></span>
        <label for="row-limit">{t('limit.label')}</label>
        <select id="row-limit" bind:value={limit} onchange={() => openTable(selectedTable)}>
          {#each LIMITS as option}
            <option value={option}>{option}</option>
          {/each}
        </select>
      </div>

      {#if tab === 'sql'}
        <div class="sql">
          <textarea
            bind:value={sql}
            aria-label={t('sql.label')}
            spellcheck="false"
            placeholder={'SELECT * FROM "' + (selectedTable || 'table') + '" LIMIT 10'}
            onkeydown={(e) => e.ctrlKey && e.key === 'Enter' && runSql()}
          ></textarea>
          <div class="table-bar">
            <button type="button" title={t('sql.runTip')} onclick={runSql} disabled={busy || !openedPath || !sql.trim()}>{t('sql.run')}</button>
            {#if sqlResult}
              <span>{t('sql.summary', { rows: fmt(sqlResult.rows.length) + (sqlResult.truncated ? '+' : ''), columns: sqlResult.columns.length })}</span>
            {/if}
          </div>
        </div>
        {#if sqlResult?.columns.length}
          {#key sqlResult}
            <Grid columns={sqlResult.columns} rows={sqlResult.rows} label={t('sql.result')} emptyText={t('sql.noRows')} {t} {nullText} onstatus={showStatus} onerror={showError} />
          {/key}
        {/if}
      {:else if !selectedTable}
        <p class="empty">{t('data.noTable')}</p>
      {:else if tab === 'schema'}
        <div class="table-bar"><h2>{selectedTable}</h2><span>{t('schema.columns', { count: columns.length })}</span></div>
        <!-- Schema: 6 px a mais de cada lado da celula (as colunas ficavam apertadas) -->
        {#key selectedTable}
        <Grid
          --cell-x="16px"
          columns={schemaColumns}
          rows={columns.map((c, i) => Object.fromEntries([i + 1, c.name, c.type, c.null].map((v, k) => [schemaColumns[k].name, v])))}
          label={t('schema.label', { table: selectedTable })}
          emptyText={t('data.empty')}
          {t}
          {nullText}
          onstatus={showStatus}
          onerror={showError}
        />
        {/key}
      {:else}
        <div class="table-bar">
          {#if everywhere}
            <span>{found?.words === search.trim() ? t('found.summary', { count: fmt(found.tables.length) }) : t('found.searching')}</span>
          {:else}
            <h2>{selectedTable}</h2>
            <span>
              {search.trim() || filters.length
                ? t('data.showingMatches', { shown: fmt(rows.length), matching: fmt(matchCount), total: fmt(rowCount), columns: columns.length })
                : t('data.showing', { shown: fmt(rows.length), total: fmt(rowCount), columns: columns.length })}
            </span>
            <button type="button" class="secondary columns-button" title={t('columns.tip')} onclick={() => columnsDialog.showModal()}>{t('columns.button')}</button>
          {/if}
          <!-- escopo da pesquisa: controle segmentado de duas opcoes (o padrao vem de Settings) -->
          <div class="scope" role="radiogroup" aria-label={t('scope.label')}>
            {#each SCOPES as [id, key]}
              <button type="button" role="radio" aria-checked={scope === id} class:active={scope === id} onclick={() => setScope(id)}>{t(key)}</button>
            {/each}
          </div>
          <input
            class="search"
            type="search"
            value={search}
            oninput={onSearch}
            onkeydown={(e) => e.key === 'Enter' && onSearch(e)}
            aria-label={t('search.label')}
            placeholder={t('search.placeholder')}
          />
        </div>
        {#if everywhere}
          <!-- Todas as tabelas: as tabelas com linhas achadas; escolher uma abre ela com a mesma pesquisa -->
          <div class="found" role="group" aria-label={t('found.list')}>
            {#if found?.words === search.trim()}
              {#each found.tables as f (f.table)}
                <button type="button" onclick={() => openFound(f.table)}>{t('found.item', { table: f.table, count: fmt(f.count) })}</button>
              {:else}
                <p>{t('data.noMatch')}</p>
              {/each}
            {/if}
          </div>
        {:else}
        {#if filters.length}
          <div class="filters" role="group" aria-label={t('filters.label')}>
            <span>{t('filters.prefix')}</span>
            {#each filters as f (f.column)}
              <span class="chip">
                {filterLabel(f)}
                <button
                  type="button"
                  aria-label={t('filters.remove', { filter: filterLabel(f) })}
                  title={t('filters.removeTip')}
                  onclick={() => setFilters(filters.filter((other) => other !== f))}>×</button
                >
              </span>
            {/each}
            <button type="button" class="secondary" onclick={() => setFilters([])}>{t('filters.clear')}</button>
          </div>
        {/if}
        <!-- key: larguras arrastadas a mao valem ate trocar de tabela (de resultado, na aba SQL) -->
        {#key selectedTable}
        <Grid
          columns={shownColumns}
          rows={shownColumns.length ? rows : []}
          label={t('data.rows', { table: selectedTable })}
          emptyText={t(!shownColumns.length ? 'data.allHidden' : filters.length || search.trim() ? 'data.noMatch' : 'data.empty')}
          {t}
          {nullText}
          onstatus={showStatus}
          onerror={showError}
          actions={{ ...gridActions, all: columns, hidden, filtered: filters.length > 0 }}
        />
        {/key}
        {/if}
      {/if}
    </main>
  </div>

  {#if logOpen}
    <section class="log" aria-labelledby="log-title">
      <div class="log-bar">
        <button type="button" class="log-toggle" title={t('log.hide')} aria-label={t('log.hide')} aria-expanded="true" onclick={() => setLog(false)}>▾</button>
        <h2 id="log-title">{t('log.title')}</h2>
        <button type="button" class="secondary" onclick={copyLog} disabled={!log.length}>{t('log.copyAll')}</button>
      </div>
      <textarea bind:this={logArea} readonly value={logText} aria-labelledby="log-title" spellcheck="false"></textarea>
    </section>
  {/if}

  <!-- recolhido: a linha mais importante (erro > aviso > acao); clique nela abre o log -->
  <footer
    class="statusbar"
    class:error={headline.level === 'error'}
    class:warning={headline.level === 'warning'}
    role="status"
    aria-live="polite"
    oncontextmenu={openStatusMenu}
  >
    <button
      type="button"
      class="log-toggle"
      title={t(logOpen ? 'log.hide' : 'log.show')}
      aria-label={t(logOpen ? 'log.hide' : 'log.show')}
      aria-expanded={logOpen}
      onclick={() => setLog(!logOpen)}>{logOpen ? '▾' : '▴'}</button
    >
    <button type="button" class="message" title={t('log.show')} onclick={() => setLog(true)}>{headline.text}</button>
    {#if unread.length}<span class="badge" title={t('log.unreadTip')}>{unread.length}</span>{/if}
    {#if hidden.size}<span class="source">{t(hidden.size === 1 ? 'status.hiddenOne' : 'status.hiddenMany', { count: hidden.size })}</span>{/if}
    {#if source}<span class="source" title={t('status.viaTip')}>{t('status.via', { source })}</span>{/if}
    <span class="stack">{t('app.stack')}</span>
  </footer>

  {#if statusMenu}
    <div class="context" role="menu" aria-label={t('status.copy')} style="left: {statusMenu.x}px; top: {statusMenu.y}px" use:keepInside>
      <button type="button" role="menuitem" use:focusNow onclick={copyStatus}>{t('status.copy')}</button>
    </div>
  {/if}
</div>

<svelte:window
  onclick={() => ((openMenu = null), (statusMenu = null))}
  onkeydown={(e) => {
    if (e.key === 'Escape') (openMenu = null), (statusMenu = null);
    if (e.ctrlKey && !e.altKey && e.key.toLowerCase() === 'l') {
      e.preventDefault();
      setLog(!logOpen);
    }
  }}
/>

<style>
  /* NIVEL BASICO: Cores em variaveis; o tema (Settings > Theme) troca o esquema da janela */
  :global(:root) {
    color-scheme: light dark;
    --bg: #f6f7f9;
    --surface: #ffffff;
    --border: #d5d9e0;
    --text: #1c2330;
    --muted: #5d6778;
    --accent: #1a5fb4;
    --accent-text: #ffffff;
    --row-alt: #f2f4f7;
    --row-hover: #e3edfb;
    --error-bg: #fde8e8;
    --error-text: #9b1c1c;
    --warn-bg: #fdf3d8;
    --warn-text: #7a4b00;
  }

  @media (prefers-color-scheme: dark) {
    :global(:root) {
      --bg: #15181d;
      --surface: #1e2229;
      --border: #363c47;
      --text: #e6e9ee;
      --muted: #9aa4b2;
      --accent: #78aeed;
      --accent-text: #10141a;
      --row-alt: #232831;
      --row-hover: #2b3a50;
      --error-bg: #4a1f1f;
      --error-text: #ffc9c9;
      --warn-bg: #45381a;
      --warn-text: #ffe2a0;
    }
  }

  :global(html),
  :global(body),
  :global(#app) {
    height: 100%;
    margin: 0;
  }

  :global(body) {
    background: var(--bg);
    color: var(--text);
    /* 14px: o tamanho de letra das 4 versoes (o do Go/Wails) */
    font: 14px/1.4 'Segoe UI', system-ui, -apple-system, 'Roboto', sans-serif;
  }

  .app {
    display: flex;
    flex-direction: column;
    height: 100%;
    box-sizing: border-box;
    padding: 0 16px 6px;
    gap: 10px;
  }

  .menubar {
    display: flex;
    gap: 2px;
    margin: 0 -16px;
    padding: 2px 8px;
    background: var(--surface);
    border-bottom: 1px solid var(--border);
  }

  .menubar > .menu-root > button {
    background: none;
    border-color: transparent;
    color: var(--text);
    font-weight: 400;
    padding: 4px 10px;
  }

  .menubar > .menu-root > button:hover,
  .menubar > .menu-root > button[aria-expanded='true'] {
    background: var(--row-hover);
  }

  .menu-root {
    position: relative;
  }

  .dropdown {
    position: absolute;
    z-index: 20;
    top: 100%;
    left: 0;
    display: flex;
    flex-direction: column;
    min-width: 240px;
    padding: 4px;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 6px;
    box-shadow: 0 6px 18px rgb(0 0 0 / 0.3);
  }

  .dropdown button {
    background: none;
    border-color: transparent;
    color: var(--text);
    font-weight: 400;
    text-align: left;
  }

  .dropdown button:hover:not(:disabled),
  .dropdown button:focus-visible {
    background: var(--row-hover);
  }

  .dropdown .separator {
    margin: 4px 0;
    border-top: 1px solid var(--border);
  }

  .dropdown .group {
    padding: 4px 10px 2px;
    color: var(--muted);
    font-size: 11px;
    font-weight: 600;
  }

  .check {
    display: inline-block;
    width: 1.4em;
    color: var(--accent);
  }

  header {
    display: flex;
    align-items: center;
    gap: 20px;
  }

  h1 {
    margin: 0;
    font-size: 17px;
    font-weight: 650;
    letter-spacing: 0.02em;
  }

  form {
    display: flex;
    flex: 1;
    align-items: center;
    gap: 8px;
  }

  label {
    color: var(--muted);
    font-size: 11px;
    font-weight: 600;
  }

  input,
  select,
  button,
  textarea {
    font: inherit;
    color: inherit;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 6px 10px;
  }

  form input {
    flex: 1;
    min-width: 0;
  }

  button {
    background: var(--accent);
    border-color: var(--accent);
    color: var(--accent-text);
    font-weight: 600;
    cursor: pointer;
    white-space: nowrap;
  }

  button.secondary {
    background: var(--surface);
    border-color: var(--border);
    color: var(--text);
  }

  dialog {
    max-width: 640px;
    padding: 20px 24px;
    background: var(--surface);
    color: var(--text);
    border: 1px solid var(--border);
    border-radius: 8px;
    user-select: text;
  }

  dialog::backdrop {
    background: rgb(0 0 0 / 0.45);
  }

  dialog h2 {
    margin-bottom: 4px;
  }

  dialog p {
    margin: 8px 0;
    overflow-wrap: anywhere;
  }

  dialog button {
    display: block;
    margin: 16px 0 0 auto;
  }

  dialog.progress {
    width: 460px;
  }

  /* Sobre: nome e versao em destaque, frase, e os detalhes numa grade de duas colunas alinhadas */
  dialog.about {
    width: 560px;
  }

  dialog.about h2 {
    font-size: 24px;
    letter-spacing: 0.01em;
  }

  .version {
    margin-left: 6px;
    padding: 2px 10px;
    border-radius: 999px;
    background: var(--accent);
    color: var(--accent-text);
    font-size: 14px;
    vertical-align: middle;
  }

  dialog .tagline {
    margin: 6px 0 14px;
    color: var(--muted);
  }

  dl {
    display: grid;
    grid-template-columns: max-content 1fr;
    gap: 7px 18px;
    margin: 0;
    padding-top: 14px;
    border-top: 1px solid var(--border);
  }

  dt {
    color: var(--muted);
    font-size: 11px;
    font-weight: 600;
    line-height: 20px;
  }

  dd {
    margin: 0;
    overflow-wrap: anywhere;
  }

  dd a {
    color: var(--accent);
    text-decoration: underline;
    cursor: pointer;
  }

  dd a:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 2px;
  }

  /* Colunas...: ~65% da janela (420 a 900 px), ate 70% da altura; titulo, busca e botoes fixos, so a lista rola */
  dialog.columns {
    box-sizing: border-box;
    width: clamp(420px, 65vw, 900px);
    max-width: calc(100vw - 32px);
    max-height: 70vh;
  }

  dialog.columns[open] {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .column-search {
    padding: 4px 8px;
  }

  dialog .actions {
    display: flex;
    align-items: center;
    gap: 8px;
    color: var(--muted);
  }

  dialog .actions button {
    margin: 0;
    padding: 4px 12px;
  }

  dialog .actions .close {
    margin-left: auto;
  }

  /* grade responsiva: cada caixa tem a largura do nome mais longo (--cell, de columnCellWidth), de 1 a 6 por linha */
  .column-list {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(min(100%, max(var(--cell), calc((100% - 5 * 4px) / 6))), 1fr));
    align-content: start;
    gap: 2px 4px;
    min-height: 0;
    padding: 4px;
    overflow: hidden auto;
    border: 1px solid var(--border);
    border-radius: 6px;
  }

  .column-list label {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
    padding: 3px 6px;
    border-radius: 4px;
    color: var(--text);
    font-size: inherit;
    font-weight: 400;
    cursor: pointer;
  }

  /* nome inteiro, sem reticencias: nome maior que a caixa quebra a linha */
  .column-list label span {
    min-width: 0;
    overflow-wrap: anywhere;
  }

  .column-list label:hover {
    background: var(--row-hover);
  }

  .column-list small {
    margin-left: auto;
    color: var(--muted);
    font-size: 11px;
    letter-spacing: 0.04em;
  }

  .column-list .none {
    grid-column: 1 / -1;
    margin: 8px;
    color: var(--muted);
  }

  dialog.progress progress {
    width: 100%;
    margin-top: 12px;
  }

  button:disabled,
  select:disabled,
  input:disabled {
    opacity: 0.55;
    cursor: not-allowed;
  }

  :is(input, select, button, textarea):focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 1px;
  }

  .workspace {
    display: flex;
    flex: 1;
    min-height: 0;
    gap: 12px;
  }

  nav {
    display: flex;
    flex-direction: column;
    gap: 6px;
    width: 250px;
    flex-shrink: 0;
  }

  /* lista de tabelas: nome inteiro (quebra a linha, nada cortado), rola so na vertical */
  .table-list {
    flex: 1;
    min-height: 0;
    padding: 4px;
    overflow: hidden auto;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 6px;
  }

  .table-list:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 1px;
  }

  .table-list [role='option'] {
    padding: 4px 6px;
    border-radius: 4px;
    overflow-wrap: anywhere;
    cursor: pointer;
  }

  .table-list [role='option']:hover {
    background: var(--row-hover);
  }

  .table-list [role='option'].selected {
    background: var(--accent);
    color: var(--accent-text);
  }

  /* View > Log: mensagens da sessao, selecionaveis (Ctrl+C) */
  .log {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .log-bar {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .log-bar button {
    padding: 2px 10px;
    font-weight: 400;
  }

  /* ~10% da altura, de 3 linhas a 25%; a borda de baixo do campo redimensiona; fonte de codigo no minimo do app */
  .log textarea {
    height: 10vh;
    min-height: calc(3 * 1.4em + 10px);
    max-height: 25vh;
    padding: 4px 8px;
    resize: vertical;
    font-family: Consolas, 'Cascadia Mono', monospace;
    font-size: 11px;
    line-height: 1.4;
    white-space: pre;
  }

  /* cabecalho do log compacto (rotulo do tamanho dos outros rotulos), para o painel ficar baixo */
  .log-bar h2 {
    margin-right: auto;
    color: var(--muted);
    font-size: 11px;
  }

  /* seta de abrir/recolher o log: discreta, sem caixa */
  .log-toggle {
    padding: 0 6px;
    border-color: transparent;
    background: none;
    color: var(--muted);
    font-weight: 400;
    line-height: 1;
  }

  .log-toggle:hover {
    color: var(--text);
  }

  /* menu Copiar da barra de status */
  .context {
    position: fixed;
    z-index: 30;
    display: flex;
    flex-direction: column;
    min-width: 140px;
    padding: 4px;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 6px;
    box-shadow: 0 6px 18px rgb(0 0 0 / 0.3);
  }

  .context button {
    background: none;
    border-color: transparent;
    color: var(--text);
    font-weight: 400;
    text-align: left;
  }

  .context button:hover,
  .context button:focus-visible {
    background: var(--row-hover);
  }

  dialog.x11 {
    width: 520px;
  }

  dialog.x11 p {
    margin: 4px 0;
  }

  /* comando selecionavel, em fonte de codigo, com o botao Copiar ao lado */
  dialog.x11 .command {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px;
    margin-top: 10px;
  }

  dialog.x11 code {
    padding: 2px 6px;
    border: 1px solid var(--border);
    border-radius: 4px;
    font-family: Consolas, 'Cascadia Mono', monospace;
    user-select: all;
  }

  dialog.x11 .command button {
    margin: 0;
    padding: 2px 10px;
    font-weight: 400;
  }

  dialog.x11 .actions {
    margin-top: 16px;
  }

  dialog.x11 .actions a {
    color: var(--accent);
  }

  /* pergunta do SQLite convertido: titulo, nome do arquivo, lembrar, botoes alinhados */
  dialog.convert {
    width: 420px;
  }

  dialog.convert .file {
    margin: 6px 0 12px;
    color: var(--muted);
  }

  dialog.convert .remember {
    display: flex;
    align-items: center;
    gap: 8px;
    color: var(--text);
    font-size: inherit;
    font-weight: 400;
  }

  dialog.convert .actions {
    margin-top: 16px;
  }

  dialog.convert {
    position: relative;
  }

  /* X do dialogo: fecha e cancela, como o Esc */
  dialog.convert .dialog-x {
    position: absolute;
    top: 8px;
    right: 10px;
    margin: 0;
    padding: 0 8px;
    border-color: transparent;
    background: none;
    color: var(--muted);
    font-size: 16px;
    font-weight: 400;
    line-height: 1.4;
  }

  dialog.convert .dialog-x:hover {
    color: var(--text);
  }

  /* foco inicial sempre visivel no botao padrao (o showModal veio de clique, nao de teclado) */
  dialog.convert button.save:focus {
    outline: 2px solid var(--text);
    outline-offset: 2px;
  }


  main {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-width: 0;
    gap: 8px;
  }

  .tabs {
    display: flex;
    align-items: center;
    gap: 4px;
    border-bottom: 1px solid var(--border);
  }

  .tabs button {
    background: none;
    border: none;
    border-bottom: 2px solid transparent;
    border-radius: 0;
    color: var(--muted);
  }

  .tabs button.active {
    color: var(--text);
    border-bottom-color: var(--accent);
  }

  .tabs .spacer {
    flex: 1;
  }

  .tabs select {
    padding: 3px 6px;
  }

  .table-bar {
    display: flex;
    align-items: baseline;
    gap: 12px;
    color: var(--muted);
    font-size: 12px;
  }

  h2 {
    margin: 0;
    color: var(--text);
    font-size: 15px;
    font-weight: 600;
  }

  .table-bar .columns-button {
    margin-left: auto;
    padding: 3px 10px;
    font-weight: 400;
  }

  /* escopo da pesquisa: dois botoes colados numa caixa so; o escolhido como a tabela escolhida na lista */
  .table-bar .scope {
    display: inline-flex;
    flex-shrink: 0;
    margin-left: auto;
    border: 1px solid var(--border);
    border-radius: 6px;
    overflow: hidden;
  }

  .table-bar .columns-button + .scope {
    margin-left: 0;
  }

  .scope button {
    padding: 3px 10px;
    border: none;
    border-radius: 0;
    background: var(--surface);
    color: var(--text);
    font-weight: 400;
  }

  .scope button + button {
    border-left: 1px solid var(--border);
  }

  .scope button.active {
    background: var(--accent);
    color: var(--accent-text);
  }

  /* Todas as tabelas: lista das tabelas achadas, como a lista de tabelas (nome inteiro, rola so na vertical) */
  .found {
    display: flex;
    flex: 1;
    flex-direction: column;
    min-height: 0;
    padding: 4px;
    overflow: hidden auto;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 6px;
  }

  .found button {
    flex-shrink: 0;
    padding: 4px 6px;
    border: none;
    border-radius: 4px;
    background: none;
    color: var(--text);
    font-weight: 400;
    text-align: left;
    white-space: normal;
    overflow-wrap: anywhere;
  }

  .found button:hover {
    background: var(--row-hover);
  }

  .found p {
    margin: 4px 6px;
    color: var(--muted);
  }

  /* a busca encolhe antes de empurrar o botao ou quebrar a barra */
  .table-bar .search {
    flex: 0 1 400px;
    min-width: 140px;
    padding: 3px 8px;
  }

  /* contagem numa linha so: a busca encolhe antes (ate 140 px) */
  .table-bar > span {
    white-space: nowrap;
  }

  .table-bar h2,
  .table-bar .columns-button {
    flex-shrink: 0;
  }

  /* filtros ativos (clique direito > Filtrar por este valor), um chip por filtro */
  .filters {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px;
    color: var(--muted);
    font-size: 12px;
  }

  .chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 2px 4px 2px 10px;
    border: 1px solid var(--accent);
    border-radius: 999px;
    background: var(--row-hover);
    color: var(--text);
    font-family: Consolas, 'Cascadia Mono', monospace;
  }

  .chip button {
    padding: 0 6px;
    border: none;
    border-radius: 999px;
    background: none;
    color: var(--muted);
    line-height: 18px;
  }

  .chip button:hover {
    background: var(--accent);
    color: var(--accent-text);
  }

  .filters > button {
    padding: 2px 10px;
    font-weight: 400;
  }

  .sql {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .sql textarea {
    min-height: 90px;
    resize: vertical;
    font-family: Consolas, 'Cascadia Mono', monospace;
    font-size: 12px;
  }

  .empty {
    margin: auto;
    color: var(--muted);
  }

  .statusbar {
    display: flex;
    gap: 16px;
    padding: 4px 10px;
    border-radius: 6px;
    background: var(--surface);
    border: 1px solid var(--border);
    color: var(--muted);
    font-size: 11px;
  }

  .statusbar.error {
    background: var(--error-bg);
    border-color: var(--error-text);
    color: var(--error-text);
  }

  .statusbar {
    align-items: center;
  }

  .statusbar .message {
    flex: 1;
    padding: 0;
    border: none;
    background: none;
    color: inherit;
    font: inherit;
    text-align: left;
    overflow-wrap: anywhere;
    white-space: normal;
    cursor: pointer;
  }

  .statusbar.warning {
    background: var(--warn-bg);
    border-color: var(--warn-text);
    color: var(--warn-text);
  }

  /* contador de erros/avisos nao lidos: numero na cor do fundo sobre um circulo na cor do texto da barra */
  .statusbar .badge {
    padding: 0 7px;
    border-radius: 999px;
    background: var(--muted);
    color: var(--surface);
    font-weight: 600;
  }

  .statusbar.error .badge {
    background: var(--error-text);
    color: var(--error-bg);
  }

  .statusbar.warning .badge {
    background: var(--warn-text);
    color: var(--warn-bg);
  }

  .statusbar .source {
    font-weight: 600;
    color: var(--text);
    white-space: nowrap;
  }

  .statusbar.error .source {
    color: inherit;
  }

  .statusbar .stack {
    white-space: nowrap;
  }
</style>
