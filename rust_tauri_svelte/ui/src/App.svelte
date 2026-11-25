<script>
  // NIVEL BASICO: Visualizador e conversor de bancos (Access, SQLite, DuckDB)
  // Menus: File (exportar, fechar), View (log), Settings (tema, idioma), Help (sobre). Abas: Data, Schema, SQL.
  // Todo texto da tela vem dos catalogos de idioma (i18n.js); i18n.test.js confere que nada fica fora.
  // NIVEL TECNICO: Svelte 5 runes; every backend call goes through Tauri invoke()

  import { invoke } from '@tauri-apps/api/core';
  import { listen } from '@tauri-apps/api/event';
  import { getCurrentWebview } from '@tauri-apps/api/webview';
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import { onMount, tick } from 'svelte';
  import Grid from './Grid.svelte';
  import {
    columnCellWidth,
    importantEntry,
    filterLabel,
    fold,
    hasAllWords,
    resolveContext,
    searchWords,
    setListed,
    statusLine,
    toggleShown,
    unreadEntries,
    visibleColumns,
    withFilter,
  } from './grid.js';
  import { LANGS, describe, translator } from './i18n.js';
  import { baseName, defaultSaveDir, dirOf, joinPath, savedEntry, stem, suggestedName, withSaved } from './paths.js';

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
  // Access ja convertido e salvo: { [chave do Access]: { dest, destKey } } com as chaves de file_key (caminho, tamanho,
  // data). Fica entre execucoes; as 50 mais recentes
  const SAVED_KEY = 'mdb2sql.savedSqlite';
  const SAVED_MAX = 50;
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

  let openMenu = $state(null); // 'file' | 'view' | 'settings' | 'help' | 'export' (botao Exportar... do topo)
  let exportSub = $state(false); // submenu Arquivo > Exportar aberto
  let tab = $state('data');
  let themeIndex = $state(0);
  let aboutDialog;
  let aboutInfo = $state.raw(null); // dados do comando about (versoes, build, leitor do Access, links)
  let columnsDialog;
  let progressDialog;
  let progress = $state.raw(null); // { label, done, total, item } da exportacao em andamento
  let convertDialog;
  let rowsDialog;
  let rowsAsk = $state.raw(null); // { label, resolve } da pergunta tabela inteira / so as linhas encontradas
  let x11Dialog;
  let x11 = $state.raw(null); // Linux sem X11: { missing, display, distro, command, link } (backend display.rs)

  let dbPath = $state('');
  let pathFocused = $state(false); // campo do caminho em edicao: mostra o texto inteiro, sem cortar o comeco
  let openedPath = $state('');
  let source = $state('');
  let converted = $state(false); // ha SQLite convertido do Access ainda nao salvo nem apagado
  let tables = $state([]);
  let tableRows = $state.raw(new Map()); // linhas de cada tabela (coluna Linhas da lista), lidas ao abrir o arquivo
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
  // { tables: [{ table, count }] } da pesquisa em todas as tabelas do termo, escopo, tabela e arquivo de agora; null =
  // pesquisando; tables null = falhou (erro na barra de status)
  let found = $state.raw(null);
  let searchRun = 0; // numero da pesquisa em todas as tabelas que vale; a resposta de uma anterior e descartada
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
  // log recolhido: erros e avisos nao vistos nem resolvidos; a barra de status mostra o ultimo erro > ultimo aviso > ultima
  // acao
  let unread = $derived(logOpen ? [] : unreadEntries(log.slice(seen)));
  let headline = $derived.by(() => {
    const pick = importantEntry(unread);
    if (pick) return { text: statusLine(entryText(pick)), level: pick.level };
    return errorText ? { text: statusLine(errorText), level: 'error' } : { text: statusText, level: 'info' };
  });

  let sql = $state('');
  let sqlResult = $state.raw(null); // { columns, rows, truncated }
  let sqlError = $state(''); // erro do ultimo SQL, na linha do botao Executar; some quando um SQL roda sem erro
  let lastSql = ''; // SQL que gerou sqlResult (o que a exportacao repete)
  const SQL_HINT = 'SELECT * FROM ...'; // dica do editor vazio (a mesma nas 4 versoes, SQL nao se traduz)

  // pergunta do SQLite convertido: escolha lembrada so nesta sessao ('save' | 'delete')
  let remembered = null;
  let rememberChoice = $state(false);
  let answer = null; // resolve da pergunta aberta
  let lastSqliteDir = '';
  let convertedKey = null; // chave do Access convertido agora (file_key ao abrir): o SQLite salvo dele fica lembrado
  let readFile = ''; // arquivo lido de fato (o SQLite salvo, quando o Access abriu por ele): a exportacao nao o sugere

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
  // Schema: Coluna, Tipo, Aceita nulo (sem a coluna "#"); a nulidade traduzida (Sim/Nao, Yes/No, Si/No)
  let schemaColumns = $derived(['schema.column', 'schema.type', 'schema.nullable'].map((key) => ({ name: t(key), type: '' })));
  let schemaRows = $derived(
    columns.map((c) =>
      Object.fromEntries(
        [c.name, c.type, t(c.null === 'NO' ? 'schema.no' : 'schema.yes')].map((value, k) => [schemaColumns[k].name, value])
      )
    )
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
    exportSub = false;
    openMenu = openMenu === name ? null : name;
  }

  // NIVEL BASICO: Arquivo > Sair e Ctrl+Q: resolve antes o SQLite convertido (pergunta) e fecha o app
  async function quit() {
    openMenu = null;
    if (await settleConverted()) await invoke('exit_app');
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
      // arquivo arrastado para a janela: abre (o primeiro, se vierem varios); nada com dialogo aberto ou trabalho em curso
      getCurrentWebview().onDragDropEvent(({ payload }) => {
        if (payload.type !== 'drop' || !payload.paths?.length || busy || document.querySelector('dialog[open]')) return;
        openDatabase(null, payload.paths[0]);
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
          await rememberSaved(convertedKey, saved);
          showStatus('status.sqliteSaved', { path: saved });
        } else {
          await invoke('discard_converted');
          showStatus('status.sqliteDeleted', { name: `${stem(openedPath)}.sqlite` });
        }
        break;
      } catch (err) {
        showError(err);
        return false;
      }
    }
    if (rememberChoice) remembered = choice;
    converted = false;
    convertedKey = null;
    return true;
  }

  // NIVEL BASICO: SQLite salvo de cada Access (entre execucoes, como o Go): chave do Access -> { dest, destKey }
  function savedList() {
    try {
      const list = JSON.parse(loadSetting(SAVED_KEY) || '{}');
      return list && typeof list === 'object' ? list : {};
    } catch {
      return {}; // gravado estragado: como se nada tivesse sido salvo
    }
  }

  // o SQLite salvo deste Access, se nenhum dos dois mudou (caminho, tamanho e data); senao null e o Access e convertido
  async function savedSqlite(accessKey) {
    const entry = savedEntry(savedList(), accessKey);
    if (!entry) return null;
    return (await invoke('file_key', { path: entry.dest })) === entry.destKey ? entry.dest : null;
  }

  // lembra o SQLite salvo do Access convertido; uma versao antiga do mesmo Access sai da lista
  async function rememberSaved(accessKey, dest) {
    const destKey = accessKey && (await invoke('file_key', { path: dest }));
    if (destKey) saveSetting(SAVED_KEY, JSON.stringify(withSaved(savedList(), accessKey, dest, destKey, SAVED_MAX)));
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
        title: t('convert.saveTitle'),
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

  // outro arquivo (ou nenhum): tabela, pesquisa e filtros zerados, escopo de volta ao padrao de Settings
  function resetTable() {
    selectedTable = '';
    hidden = new Set();
    filters = [];
    search = '';
    scope = defaultScope;
    dropFound();
    columns = [];
    rows = [];
    rowCount = 0;
    matchCount = 0;
  }

  // NIVEL BASICO: Abre o banco; caminho vazio usa MDB2SQL_DB_PATH ou data/sample.duckdb
  // chosen: arquivo do dialogo Abrir ou arrastado para a janela; o campo so passa a mostra-lo depois da pergunta do SQLite
  // convertido (Cancelar deixa o campo com o arquivo que continua aberto)
  async function openDatabase(event, chosen) {
    event?.preventDefault();
    // "Copiar como caminho" do Windows cola o caminho entre aspas
    const path = (chosen ?? dbPath).trim().replace(/^"(.*)"$/, '$1');
    if (!(await settleConverted())) return;
    dbPath = path;
    busy = true;
    showStatus('status.opening');
    try {
      // Access ja convertido e salvo, sem mudanca: abre o SQLite salvo (nada de converter nem perguntar de novo)
      const accessKey = /\.(mdb|accdb)$/i.test(path) ? await invoke('file_key', { path }) : null;
      const saved = await savedSqlite(accessKey);
      const opened = await invoke('load_database', { dbPath: path, saved });
      tables = opened.tables;
      tableRows = new Map(opened.tables.map((name, i) => [name, opened.rows[i]]));
      openedPath = opened.path;
      readFile = opened.file;
      source = opened.source;
      converted = opened.converted;
      convertedKey = opened.converted ? accessKey : null;
      dbPath = opened.path;
      clearTimeout(tableTimer);
      tableText = tableFilter = '';
      sqlResult = null;
      sqlError = '';
      log = resolveContext(log, 'err.sql'); // erro de SQL do arquivo anterior sai da barra de baixo tambem
      lastSql = '';
      saveSetting(LAST_DIR_KEY, dirOf(opened.path));
      showStatus('status.opened', { name: baseName(opened.path), count: fmt(tables.length) });
      if (saved) note('info', { key: 'status.reused', values: { name: baseName(opened.path), path: saved } });
      note('info', { key: 'status.via', values: { source } });
      resetTable();
      if (tables.length > 0) await openTable(tables[0]);
    } catch (err) {
      showError(err, 'status.openFailed');
    } finally {
      busy = false;
    }
  }

  // NIVEL BASICO: Arquivo > Fechar
  async function closeDatabase() {
    openMenu = null;
    if (!openedPath || !(await settleConverted())) return;
    try {
      await invoke('close_database');
    } catch (err) {
      showError(err);
      return;
    }
    const name = baseName(openedPath);
    tables = [];
    tableRows = new Map();
    openedPath = '';
    readFile = '';
    source = '';
    converted = false;
    sqlResult = null;
    sqlError = '';
    log = resolveContext(log, 'err.sql');
    lastSql = '';
    resetTable();
    showStatus('status.closed', { name });
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
      await openDatabase(null, String(picked));
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
      dropFound();
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
    dropFound();
    clearTimeout(searchTimer);
    searchTimer = setTimeout(runSearch, delayOf(event));
  }

  // a pesquisa vale para a tabela aberta; em Todas as tabelas (com termo) procura em todas
  function runSearch() {
    if (everywhere) searchAll();
    else openTable(selectedTable);
  }

  // esquece o resultado de Todas as tabelas (outro termo, escopo, tabela ou arquivo): a resposta da pesquisa que ainda
  // estiver em andamento e descartada
  function dropFound() {
    searchRun++;
    found = null;
  }

  // NIVEL BASICO: Todas as tabelas: lista as tabelas com linhas que tem o termo e quantas (backend: mesma regra da
  // pesquisa da tabela, nas colunas de texto). Resposta velha nunca aparece; a pesquisa nova para a antiga no backend.
  // Falha: sai o "Pesquisando" e o erro vai para a barra de status
  async function searchAll() {
    dropFound();
    const run = searchRun;
    const words = search.trim();
    busy = true;
    try {
      const tables = await invoke('search_all_tables', { search: words });
      if (run === searchRun) found = { tables };
    } catch (err) {
      if (run === searchRun) {
        found = { tables: null };
        showError(err);
      }
    } finally {
      busy = false;
    }
  }

  function setScope(next) {
    scope = next;
    dropFound();
    // campo vazio: o recarregamento que a digitacao agendou continua (senao a grade ficava filtrada sob o campo vazio)
    if (!search.trim()) return;
    clearTimeout(searchTimer);
    runSearch();
  }

  // escolher uma tabela achada abre ela na aba Data com a mesma pesquisa (o escopo volta para Esta tabela) e sem os
  // filtros por valor: a grade mostra o numero da lista
  function openFound(name) {
    scope = 'table';
    filters = [];
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

  // NIVEL BASICO: SQL livre; mostra ate o Row limit. Sem erro: sai o erro anterior da linha do botao e da barra de baixo.
  // Com erro: sai a grade do SQL anterior (pareceria o resultado deste) e o erro fica nos dois lugares
  async function runSql() {
    if (!sql.trim()) return;
    busy = true;
    try {
      const query = sql;
      sqlResult = await invoke('run_sql', { sql: query, limit });
      lastSql = query;
      sqlError = '';
      log = resolveContext(log, 'err.sql');
      if (sqlResult.columns.length) {
        showStatus('status.query', { rows: fmt(sqlResult.rows.length) + (sqlResult.truncated ? '+' : '') });
      } else {
        showStatus('status.executed');
      }
    } catch (err) {
      sqlResult = null;
      lastSql = '';
      sqlError = String(err);
      showError(err, 'err.sql'); // erro do motor com o prefixo traduzido
    } finally {
      busy = false;
    }
  }

  // NIVEL BASICO: Exportar a tabela com pesquisa ou filtro ativo: 'all' (tabela inteira), 'found' (so as linhas
  // encontradas) ou null (Cancelar, Esc)
  function askRows(label) {
    return new Promise((resolve) => {
      rowsAsk = { label, resolve };
      rowsDialog.showModal();
      rowsDialog.querySelector('button.default').focus();
    });
  }

  function rowsReply(choice) {
    rowsDialog.close();
    rowsAsk?.resolve(choice);
    rowsAsk = null;
  }

  // NIVEL BASICO: Pergunta onde salvar (pasta do arquivo aberto, senao a ultima usada) e exporta
  // fora da thread da interface, com barra de progresso e Cancelar
  async function startExport(scope, format, labelKey) {
    openMenu = null;
    if (!canExport(scope)) return;
    const label = t(labelKey).replace(/\.\.\.$/, '');
    // tabela com pesquisa ou filtro na grade (as 4 versoes): a tabela inteira ou so as linhas encontradas
    let rows = { filters: [], search: '' };
    if (scope === 'table' && !everywhere && (search.trim() || filters.length)) {
      // a pesquisa digitada que ainda espera os 300 ms vale agora: o numero da pergunta e o das linhas exportadas
      clearTimeout(searchTimer);
      await openTable(selectedTable);
      const choice = await askRows(label);
      if (!choice) return; // Cancelar ou Esc
      if (choice === 'found') rows = { filters, search: search.trim() };
    }
    const base = scope === 'database' ? stem(openedPath) : scope === 'table' ? selectedTable : 'query';
    const dir = defaultSaveDir(openedPath, loadSetting(LAST_DIR_KEY));
    try {
      const path = await invoke('plugin:dialog|save', {
        options: {
          title: label,
          defaultPath: joinPath(dir, suggestedName(base, format, readFile)),
          filters: [{ name: t(`save.${format}`), extensions: [format] }],
        },
      });
      if (!path) return; // cancelado
      saveSetting(LAST_DIR_KEY, dirOf(path));
      progress = { label, done: 0, total: 0, item: '' };
      progressDialog.showModal();
      await tick();
      progressDialog.querySelector('button.default')?.focus();
      const done = await invoke('export', { scope, format, path, table: selectedTable || null, sql: lastSql || null, ...rows });
      // tabelas (banco inteiro) ou linhas (tabela, SQL), com o numero de abas se foi Excel; plural pelo numero
      const unit = scope === 'database' ? 'Tables' : 'Rows';
      const values = { count: fmt(done.count), sheets: fmt(done.sheets ?? 0), path };
      showStatus(`status.exported${unit}${done.sheets == null ? '' : 'Sheets'}`, values);
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

  // NIVEL BASICO: Atalhos, os mesmos nas 4 versoes: Ctrl+O abrir, Ctrl+F pesquisar, F5 recarregar o banco, Ctrl+Q sair,
  // Ctrl+1/2/3 abas, Ctrl+L log, Ctrl+Enter rodar o SQL (aba SQL); Ctrl+C na grade copia a celula (Grid.svelte).
  // Com um dialogo aberto so valem as teclas dele; F5 nunca recarrega a pagina do webview (a tela voltaria do zero)
  function shortcut(e) {
    if (e.key === 'Escape') (openMenu = null), (statusMenu = null);
    if (e.key === 'F5') e.preventDefault();
    if (document.querySelector('dialog[open]') || e.altKey) return;
    if (e.key === 'F5' && !e.ctrlKey) return reload();
    if (!e.ctrlKey) return;
    const actions = {
      o: () => !busy && browse(),
      f: focusSearch,
      q: quit,
      l: () => setLog(!logOpen),
      1: () => (tab = 'data'),
      2: () => (tab = 'schema'),
      3: focusSql,
      enter: () => tab === 'sql' && !busy && openedPath && runSql(), // como o botao Executar
    };
    const act = actions[e.key.toLowerCase()];
    if (!act) return;
    e.preventDefault();
    act();
  }

  // F5: abre de novo o banco aberto (rele a lista de tabelas); sem banco aberto, o caminho do campo
  function reload() {
    if (busy) return;
    if (openedPath) dbPath = openedPath;
    if (dbPath.trim()) openDatabase();
  }

  // Ctrl+F: aba Data com o campo de pesquisa em foco e o texto selecionado (sem tabela aberta nao ha campo)
  async function focusSearch() {
    tab = 'data';
    await tick();
    const field = document.querySelector('input.search');
    field?.focus();
    field?.select();
  }

  // Ctrl+3: aba SQL com o editor em foco
  async function focusSql() {
    tab = 'sql';
    await tick();
    document.querySelector('.sql textarea')?.focus();
  }

  // menu perto da borda: puxa para dentro da janela
  const keepInside = (node) => {
    const box = node.getBoundingClientRect();
    node.style.left = `${Math.max(4, Math.min(box.left, innerWidth - box.width - 4))}px`;
    node.style.top = `${Math.max(4, Math.min(box.top - box.height, innerHeight - box.height - 4))}px`;
  };
  const focusNow = (node) => node.focus();
</script>

<!-- lista de exportacao, uma so: botao Exportar... do topo e menu Arquivo; um separador entre banco, tabela e SQL -->
{#snippet exportItems()}
  {#each EXPORTS as [key, scope, format], i}
    {#if i > 0 && scope !== EXPORTS[i - 1][1]}<div class="separator" role="separator"></div>{/if}
    <button type="button" role="menuitem" disabled={!canExport(scope)} onclick={() => startExport(scope, format, key)}>{t(key)}</button>
  {/each}
{/snippet}

<div class="app">
  <div class="menubar" role="menubar" aria-label={t('menu.main')}>
    <div class="menu-root">
      <button type="button" role="menuitem" aria-haspopup="menu" aria-expanded={openMenu === 'file'} onclick={(e) => toggleMenu(e, 'file')}>{t('menu.file')}</button>
      {#if openMenu === 'file'}
        <!-- como o menu Arquivo do Zig: Abrir..., Exportar > (submenu), Fechar, Sair -->
        <div class="dropdown" role="menu" aria-label={t('menu.file')}>
          <button type="button" role="menuitem" disabled={busy} onclick={browse} onmouseenter={() => (exportSub = false)}>
            {t('file.open')} <kbd>{t('file.openKey')}</kbd>
          </button>
          <div class="submenu-root" role="none" onmouseenter={() => (exportSub = true)} onmouseleave={() => (exportSub = false)}>
            <button
              type="button"
              role="menuitem"
              aria-haspopup="menu"
              aria-expanded={exportSub}
              disabled={busy || !openedPath}
              onclick={(e) => {
                e.stopPropagation(); // o clique abre o submenu, nao fecha o menu
                exportSub = !exportSub;
              }}
            >
              {t('file.export')} <span class="arrow">▸</span>
            </button>
            {#if exportSub && !busy && openedPath}
              <div class="dropdown sub" role="menu" aria-label={t('file.export')}>{@render exportItems()}</div>
            {/if}
          </div>
          <button type="button" role="menuitem" disabled={busy || !openedPath} onclick={closeDatabase} onmouseenter={() => (exportSub = false)}>
            {t('file.close')}
          </button>
          <div class="separator" role="separator"></div>
          <button type="button" role="menuitem" onclick={quit}>{t('file.exit')} <kbd>{t('file.exitKey')}</kbd></button>
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
        <!-- ordem das 4 versoes: Tema, Idioma, Escopo padrao da busca, Exibir NULL; cada escolha vale na hora e fica gravada -->
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
          <span class="group">{t('settings.searchScope')}</span>
          {#each SCOPES as [id, key]}
            <button type="button" role="menuitemradio" aria-checked={defaultScope === id} onclick={() => setDefaultScope(id)}>
              <span class="check">{defaultScope === id ? '●' : ''}</span>{t(key)}
            </button>
          {/each}
          <div class="separator" role="separator"></div>
          <button type="button" role="menuitemcheckbox" aria-checked={showNull} onclick={() => setShowNull(!showNull)}>
            <span class="check">{showNull ? '✓' : ''}</span>{t('settings.showNull')}
          </button>
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

  <!-- topo como o do Zig: o caminho ocupa a linha, Procurar... Abrir Exportar... a direita; arrastar um arquivo para a
       janela tambem abre -->
  <header>
    <form onsubmit={openDatabase}>
      <div class="path">
        <input
          id="db-path"
          type="text"
          class:elided={!pathFocused && dbPath}
          bind:value={dbPath}
          aria-label={t('header.database')}
          placeholder={t('header.placeholder')}
          spellcheck="false"
          autocomplete="off"
          onfocus={() => (pathFocused = true)}
          onblur={() => (pathFocused = false)}
        />
        {#if !pathFocused && dbPath}
          <!-- caminho maior que o campo perde o comeco (com ...), nunca o nome do arquivo (ElideLeft do Zig) -->
          <span class="path-view" aria-hidden="true"><bdi dir="ltr">{dbPath}</bdi></span>
        {/if}
      </div>
      <button type="button" class="secondary" onclick={browse} disabled={busy}>{t('header.browse')}</button>
      <button type="submit" disabled={busy}>{t('header.open')}</button>
      <div class="menu-root">
        <button
          type="button"
          class="secondary"
          aria-haspopup="menu"
          aria-expanded={openMenu === 'export'}
          disabled={busy || !openedPath}
          onclick={(e) => toggleMenu(e, 'export')}>{t('header.export')}</button
        >
        {#if openMenu === 'export'}
          <div class="dropdown end" role="menu" aria-label={t('file.export')}>{@render exportItems()}</div>
        {/if}
      </div>
    </form>
  </header>

  <dialog bind:this={aboutDialog} class="about" aria-labelledby="about-title">
    {#if aboutInfo}
      <!-- titulo "Sobre o mdb2sql" (o do Zig, o mesmo do menu); o conteudo e o desta versao -->
      <h2 id="about-title">{t('help.about')} <span class="version">{aboutInfo.version}</span></h2>
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
    <!-- como o dialogo do Go: titulo "SQLite convertido" e a pergunta com o nome do arquivo -->
    <h2 id="convert-title">{t('convert.title')}</h2>
    <p class="file">{t('convert.text', { name: `${stem(openedPath)}.sqlite` })}</p>
    <label class="remember"><input type="checkbox" bind:checked={rememberChoice} /> {t('convert.remember')}</label>
    <div class="actions">
      <button type="button" class="save" onclick={() => reply('save')}>{t('convert.save')}</button>
      <button type="button" class="secondary" onclick={() => reply('delete')}>{t('convert.delete')}</button>
      <button type="button" class="secondary close" onclick={() => reply('cancel')}>{t('common.cancel')}</button>
    </div>
  </dialog>

  <!-- exportar a tabela com pesquisa ou filtro ativo: a tabela inteira ou so as linhas encontradas (Esc = Cancelar) -->
  <dialog
    bind:this={rowsDialog}
    class="ask"
    aria-labelledby="rows-title"
    oncancel={(e) => {
      e.preventDefault();
      rowsReply(null);
    }}
  >
    <h2 id="rows-title">{rowsAsk?.label}</h2>
    <div class="actions">
      <button type="button" class="default" onclick={() => rowsReply('all')}>{t('export.wholeTable')}</button>
      <button type="button" class="secondary" onclick={() => rowsReply('found')}>{t('export.foundRows', { count: fmt(matchCount) })}</button>
      <button type="button" class="secondary close" onclick={() => rowsReply(null)}>{t('common.cancel')}</button>
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
        placeholder={t('tables.filter', { count: fmt(tables.length) })}
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
        <!-- como a lista do Zig: colunas Tabela e Linhas (o titulo fica no alto enquanto a lista rola) -->
        {#if tables.length}
          <div class="table-head" aria-hidden="true"><span>{t('tables.name')}</span><span>{t('tables.rows')}</span></div>
        {/if}
        {#each visibleTables as name, i (name)}
          <div id="table-{i}" role="option" tabindex="-1" aria-selected={name === selectedTable} class:selected={name === selectedTable} onclick={() => openTable(name)}>
            <span class="name">{name}</span><span class="rows">{tableRows.get(name) == null ? '' : fmt(tableRows.get(name))}</span>
          </div>
        {/each}
      </div>
    </nav>

    <main aria-busy={busy}>
      <div class="tabs" role="tablist" aria-label={t('tabs.view')}>
        {#each TABS as [id, key]}
          <button type="button" role="tab" aria-selected={tab === id} class:active={tab === id} onclick={() => (tab = id)}>{t(key)}</button>
        {/each}
      </div>

      <!-- Linhas [100]: na linha da busca da aba Dados e na linha do Executar da aba SQL (uma por vez na tela) -->
      {#snippet rowLimit()}
        <label for="row-limit">{t('limit.label')}</label>
        <select id="row-limit" bind:value={limit} onchange={() => openTable(selectedTable)}>
          {#each LIMITS as option}
            <option value={option}>{option}</option>
          {/each}
        </select>
      {/snippet}

      {#if tab === 'sql'}
        <div class="sql">
          <textarea
            bind:value={sql}
            aria-label={t('sql.label')}
            spellcheck="false"
            placeholder={SQL_HINT}
          ></textarea>
          <div class="table-bar">
            <button type="button" title={t('sql.runTip')} onclick={runSql} disabled={busy || !openedPath || !sql.trim()}>{t('sql.run')}</button>
            {#if sqlError}
              <span class="sql-error">{statusLine(errorLine(sqlError, 'err.sql'))}</span>
            {:else if sqlResult}
              <span>{t('sql.summary', { rows: fmt(sqlResult.rows.length) + (sqlResult.truncated ? '+' : ''), columns: sqlResult.columns.length })}</span>
            {/if}
            <span class="limit">{@render rowLimit()}</span>
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
          rows={schemaRows}
          label={t('schema.label', { table: selectedTable })}
          emptyText={t('data.empty')}
          {t}
          {nullText}
          onstatus={showStatus}
          onerror={showError}
        />
        {/key}
      {:else}
        <!-- aba Dados igual nas 4 versoes (padrao item 24): (a) busca | Esta tabela | Todas as tabelas | Linhas | Colunas...
             numa linha (estreita, quebra como o Go); (b) filtros por valor, so quando houver; (c) a grade (ou as tabelas
             achadas); (d) a contagem embaixo. Nada mais nesta area -->
        <div class="table-bar data-bar">
          <input
            class="search"
            type="search"
            value={search}
            oninput={onSearch}
            onkeydown={(e) => e.key === 'Enter' && onSearch(e)}
            aria-label={t('search.label')}
            placeholder={t('search.placeholder')}
          />
          <!-- escopo da pesquisa: controle segmentado de duas opcoes (o padrao vem de Settings) -->
          <div class="scope" role="radiogroup" aria-label={t('scope.label')}>
            {#each SCOPES as [id, key]}
              <button type="button" role="radio" aria-checked={scope === id} class:active={scope === id} onclick={() => setScope(id)}>{t(key)}</button>
            {/each}
          </div>
          <span class="limit">{@render rowLimit()}</span>
          <button type="button" class="secondary columns-button" title={t('columns.tip')} onclick={() => columnsDialog.showModal()}>{t('columns.button')}</button>
        </div>
        {#if everywhere}
          <!-- Todas as tabelas: as tabelas com linhas achadas; escolher uma abre ela com a mesma pesquisa -->
          <div class="found" role="group" aria-label={t('found.list')}>
            {#if found?.tables}
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
        <!-- (d) "{tabela}: mostrando X de Y linhas" (com busca ou filtro, das encontradas); em Todas as tabelas, o resumo -->
        <p class="table-info">
          {#if everywhere}
            {!found ? t('found.searching') : found.tables ? t('found.summary', { count: fmt(found.tables.length) }) : ''}
          {:else if search.trim() || filters.length}
            {t('data.showingMatches', { table: selectedTable, shown: fmt(rows.length), matching: fmt(matchCount) })}
          {:else}
            {t('data.showing', { table: selectedTable, shown: fmt(rows.length), total: fmt(rowCount) })}
          {/if}
        </p>
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

  <!-- como a barra do Go: a esquerda a seta do log e a linha mais importante (erro > aviso > acao; clique nela abre o
       log); a direita os erros/avisos nao lidos, as colunas ocultas e o modo de leitura -->
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
    {#if unread.length}<span class="badge" title={t('log.unread', { count: unread.length })}>{unread.length}</span>{/if}
    {#if hidden.size}<span class="source">{t(hidden.size === 1 ? 'status.hiddenOne' : 'status.hiddenMany', { count: hidden.size })}</span>{/if}
    {#if source}<span class="source" title={t('status.viaTip')}>{t('status.via', { source })}</span>{/if}
  </footer>

  {#if statusMenu}
    <div class="context" role="menu" aria-label={t('status.copy')} style="left: {statusMenu.x}px; top: {statusMenu.y}px" use:keepInside>
      <button type="button" role="menuitem" use:focusNow onclick={copyStatus}>{t('status.copy')}</button>
    </div>
  {/if}
</div>

<svelte:window onclick={() => ((openMenu = null), (statusMenu = null))} onkeydown={shortcut} />

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
    display: flex;
    align-items: center;
    background: none;
    border-color: transparent;
    color: var(--text);
    font-weight: 400;
    text-align: left;
  }

  /* atalho e seta do submenu na ponta direita do item, como no menu da grade */
  .dropdown kbd,
  .dropdown .arrow {
    margin-left: auto;
    padding-left: 16px;
    color: var(--muted);
    font: inherit;
  }

  /* Arquivo > Exportar: o submenu abre ao lado do item */
  .submenu-root {
    position: relative;
    display: flex;
    flex-direction: column;
  }

  .dropdown.sub {
    top: -5px;
    left: 100%;
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
  }

  form {
    display: flex;
    flex: 1;
    align-items: center;
    gap: 8px;
  }

  /* campo do caminho: ocupa a linha ate os botoes */
  .path {
    position: relative;
    display: flex;
    flex: 1;
    min-width: 0;
  }

  /* fora de foco o texto do campo fica por baixo do .path-view, na mesma letra e no mesmo recuo */
  .path input.elided {
    color: transparent;
  }

  /* ElideLeft: em rtl o que nao cabe sai pelo comeco, com "..." ali; o <bdi> mantem o caminho na ordem normal */
  .path-view {
    position: absolute;
    top: 50%;
    right: 11px;
    left: 11px;
    overflow: hidden;
    direction: rtl;
    text-align: left;
    text-overflow: ellipsis;
    white-space: nowrap;
    pointer-events: none;
    transform: translateY(-50%);
  }

  /* menu do botao Exportar... (no fim da linha): abre para a esquerda, dentro da janela */
  .dropdown.end {
    right: 0;
    left: auto;
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
    margin: 0;
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

  /* lista de tabelas: nome inteiro (quebra a linha, nada cortado) e as linhas a direita, rola so na vertical */
  .table-list {
    flex: 1;
    min-height: 0;
    padding: 0 4px 4px;
    overflow: hidden auto;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 6px;
  }

  /* titulos Tabela | Linhas, presos no alto da lista */
  .table-head {
    position: sticky;
    top: 0;
    display: flex;
    gap: 12px;
    margin-bottom: 4px;
    padding: 6px 6px 4px;
    background: var(--surface);
    border-bottom: 1px solid var(--border);
    color: var(--muted);
    font-size: 11px;
    font-weight: 600;
  }

  .table-list .name {
    min-width: 0;
  }

  .table-head span:last-child,
  .table-list .rows {
    margin-left: auto;
    font-variant-numeric: tabular-nums;
  }

  .table-list:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 1px;
  }

  .table-list [role='option'] {
    display: flex;
    align-items: baseline;
    gap: 12px;
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

  /* exportar a tabela inteira ou so as linhas encontradas: o nome da exportacao e as escolhas numa linha */
  dialog.ask {
    width: 460px;
  }

  dialog.ask .actions {
    margin-top: 16px;
  }

  /* pergunta do SQLite convertido: titulo, nome do arquivo, lembrar, botoes alinhados */
  dialog.convert {
    width: 420px;
  }

  dialog.convert .file {
    margin: 6px 0 12px;
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

  /* janela estreita (720 px): a barra quebra a linha como a do Go; nada cortado, nada de rolagem horizontal */
  .table-bar {
    display: flex;
    flex-wrap: wrap;
    align-items: baseline;
    gap: 6px 12px;
    color: var(--muted);
    font-size: 12px;
  }

  /* linha da busca da aba Dados: campos e botoes alinhados pelo meio */
  .table-bar.data-bar {
    align-items: center;
  }

  /* Linhas [100]: rotulo e lista juntos; na aba SQL, no fim da linha do Executar */
  .limit {
    display: inline-flex;
    flex-shrink: 0;
    align-items: center;
    gap: 6px;
  }

  .limit select {
    padding: 3px 6px;
  }

  .sql .limit {
    margin-left: auto;
  }

  /* contagem embaixo da grade: uma linha, no texto apagado das outras contagens */
  .table-info {
    margin: 0;
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
    padding: 3px 10px;
    font-weight: 400;
  }

  /* escopo da pesquisa: dois botoes colados numa caixa so; o escolhido como a tabela escolhida na lista */
  .table-bar .scope {
    display: inline-flex;
    flex-shrink: 0;
    border: 1px solid var(--border);
    border-radius: 6px;
    overflow: hidden;
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

  /* a busca estica ate o fim da linha (sem largura maxima); com menos de 160 px vai para a linha de baixo (como o Go) */
  .table-bar .search {
    flex: 1 1 160px;
    min-width: 160px;
    padding: 3px 8px;
  }

  /* contagem numa linha so: sem lugar, ela desce inteira */
  .table-bar > span {
    white-space: nowrap;
  }

  /* erro do SQL: texto do motor, pode ser longo; quebra a linha em vez de passar da janela */
  .table-bar > .sql-error {
    min-width: 0;
    white-space: normal;
    overflow-wrap: anywhere;
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

  /* colunas ocultas e modo de leitura no texto da barra, sem destaque (como no Go) */
  .statusbar .source {
    white-space: nowrap;
  }
</style>
