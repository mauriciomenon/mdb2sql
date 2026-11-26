<script>
  // NIVEL BASICO: Visualizador e conversor de bancos (Access, SQLite, DuckDB)
  // Menus: Arquivo, Editar, Exibir, Configuracoes, Ajuda (a arvore esta em menus.js). Abas: Dados, Esquema, SQL, Termos.
  // Todo texto da tela vem dos catalogos de idioma (i18n.js); i18n.test.js confere que nada fica fora.
  // NIVEL TECNICO: Svelte 5 runes; every backend call goes through Tauri invoke()

  import { invoke } from '@tauri-apps/api/core';
  import { listen } from '@tauri-apps/api/event';
  import { getCurrentWebview } from '@tauri-apps/api/webview';
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import { onMount, tick } from 'svelte';
  import Grid from './Grid.svelte';
  import {
    ROW_ID,
    columnCellWidth,
    favoritesFirst,
    importantEntry,
    filterLabel,
    fold,
    gridRows,
    hasAllWords,
    parseTerms,
    resolveContext,
    rowsToTsv,
    searchWords,
    setListed,
    statusLine,
    termsOutcome,
    toggleFavorite,
    toggleMarked,
    toggleShown,
    unreadEntries,
    visibleColumns,
    withFilter,
    withIds,
  } from './grid.js';
  import { LANGS, describe, translator } from './i18n.js';
  import { EXPORT_MENU, LIMITS, MATCHES, MENUS, SCOPES, THEMES } from './menus.js';
  import { SAVE_FORMATS, baseName, defaultSaveDir, dirOf, joinPath, savedEntry, savedFormat, stem, suggestedName, withSaved } from './paths.js';

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
    ['terms', 'tabs.terms'],
  ];
  // preferencias gravadas no webview (ficam entre execucoes)
  const THEME_KEY = 'mdb2sql.theme';
  const LAST_DIR_KEY = 'mdb2sql.lastDir';
  const SAVE_DIR_KEY = 'mdb2sql.lastSaveDir'; // ultima pasta em que o usuario salvou ou exportou (Salvar como...)
  const LANG_KEY = 'mdb2sql.lang';
  const LOG_KEY = 'mdb2sql.log'; // 'open' = painel de log aberto (padrao: recolhido)
  const NULL_KEY = 'mdb2sql.showNull'; // 'on' = celula NULL mostra "NULL" (padrao, sem valor gravado: vazia)
  const SCOPE_KEY = 'mdb2sql.searchScope'; // 'all' = a pesquisa comeca em Todas as tabelas (padrao: Esta tabela)
  const MATCH_KEY = 'mdb2sql.termMatch'; // 'contains' = a pesquisa de termos comeca em Contem (padrao: Valor inteiro)
  // Access ja convertido e salvo (SQLite ou DuckDB): { [chave do Access]: { dest, destKey } } com as chaves de file_key
  // (caminho, tamanho, data). Fica entre execucoes; as 50 mais recentes
  const SAVED_KEY = 'mdb2sql.savedSqlite';
  const SAVED_MAX = 50;
  // pastas de arquivos originais que receberam o SQLite convertido (as pastas temporarias falharam): a limpeza das
  // sobras, ao abrir o app, passa por elas tambem
  const TEMP_KEY = 'mdb2sql.tempDirs';
  // a pesquisa vai ao banco quando a digitacao para por este tempo
  const SEARCH_DELAY_MS = 300;
  const isAccess = (path) => /\.(mdb|accdb)$/i.test(path);

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

  // lista gravada como JSON ([] ou {} se nao ha ou esta estragada)
  function loadJson(key, empty) {
    try {
      const value = JSON.parse(loadSetting(key) || 'null');
      return value && typeof value === 'object' && Array.isArray(value) === Array.isArray(empty) ? value : empty;
    } catch {
      return empty;
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

  let openMenu = $state(null); // menu aberto: id de MENUS ou 'export' (botao Exportar... do topo)
  let subPath = $state.raw([]); // submenus abertos dentro dele, um id por nivel
  let tab = $state('data');
  let themeIndex = $state(0);
  let aboutDialog;
  let aboutInfo = $state.raw(null); // dados do comando about (versoes, build, leitor do Access, links)
  let columnsDialog;
  let progressDialog;
  let progress = $state.raw(null); // { label, path, done, total, item } da exportacao em andamento
  let exportEnd = Promise.resolve(); // termina quando a exportacao em andamento para (sair espera por ela)
  let askDialog;
  let question = $state.raw(null); // pergunta aberta: { title, text, x, buttons: [{ id, label, primary, right }], resolve }
  let quitting = false; // a pergunta de sair (ou o Salvar dela) esta em andamento
  let x11Dialog;
  let x11 = $state.raw(null); // Linux sem X11: { missing, display, distro, command, link } (backend display.rs)

  let dbPath = $state('');
  let pathFocused = $state(false); // campo do caminho em edicao: mostra o texto inteiro, sem cortar o comeco
  let openedPath = $state('');
  let source = $state('');
  let converted = $state(false); // ha SQLite convertido do Access ainda nao salvo (so entao sair pergunta)
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

  // linhas marcadas de cada tabela (Map tabela -> linhas, cada uma com a identidade em ROW_ID), enquanto o arquivo
  // estiver aberto; ficam sempre no topo da grade, qualquer que seja a pesquisa
  let marks = $state.raw(new Map());
  let markedRows = $derived(marks.get(selectedTable) ?? []);
  let onlyMarked = $state(false); // "So as marcadas": a grade mostra so elas
  let showOnly = $derived(onlyMarked && markedRows.length > 0);
  let shownRows = $derived(gridRows(markedRows, rows, showOnly));
  let grid = $state(); // a grade na tela (uma por vez) e a celula escolhida nela: menu Editar
  let cell = $state.raw(null);

  // aba Termos
  let termsText = $state('');
  let termList = $derived(parseTerms(termsText)); // { terms, repeated }
  let defaultMatch = $state(loadSetting(MATCH_KEY) === 'contains' ? 'contains' : 'whole');
  let match = $state(defaultMatch); // 'whole' (valor inteiro) | 'contains'
  let termsScope = $state(defaultScope);
  let termsRun = 0; // numero da pesquisa de termos que vale; a resposta de uma anterior e descartada
  let termsWork = $state.raw(null); // { done, total, item } da pesquisa em andamento
  let termsResult = $state.raw(null); // { terms, tables: [{ table, count }], notFound, found, rows }
  let termsTable = $state(''); // tabela escolhida na lista das que tem acerto
  let termsPage = $state.raw(null); // { columns, rows } dela (ate o limite de linhas)
  let canRunTerms = $derived(!busy && !!openedPath && termList.terms.length > 0 && (termsScope === 'all' || !!selectedTable));

  // status = [chave, valores] da ultima acao; error = { err, context } do ultimo erro (null depois de uma acao ok).
  // Tudo guardado como chave: troca de idioma traduz de novo a barra de status e o log
  let status = $state.raw(['status.noDatabase', {}]);
  let error = $state.raw(null);
  const errorLine = (err, context) => (context ? `${t(context)}: ` : '') + describe(t, err);
  // barra de status: erro do motor em uma linha (statusLine); o texto inteiro fica no log
  let statusText = $derived(t(...status));
  let errorText = $derived(error ? errorLine(error.err, error.context) : '');
  // menu de clique direito: { x, y } da barra de status (Copiar) ou { x, y, table } da lista de tabelas (favoritar)
  let contextMenu = $state.raw(null);
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
  // comando recusado pela aba SQL (so leitura): a frase do catalogo, sem o prefixo de erro de consulta
  const sqlContext = (err) => (String(err).includes('[[err.sqlReadOnly]]') ? undefined : 'err.sql');

  let accessKey = null; // chave do Access aberto (file_key ao abrir): o arquivo salvo dele fica lembrado
  let readFile = ''; // arquivo lido de fato (o arquivo salvo, quando o Access abriu por ele): Salvar nao o sugere

  // tabelas favoritas, pelo nome, so enquanto o programa estiver aberto (fechar, abrir outro e F5 mantem)
  let favorites = $state.raw(new Set());
  // lista de tabelas: o filtro, e as favoritas no topo em ordem alfabetica
  let visibleTables = $derived.by(() => {
    const words = searchWords(tableFilter);
    return favoritesFirst(tables.filter((name) => hasAllWords(fold(name), words)), favorites);
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
      [t('about.write'), t('about.writeValue')],
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

  // abre/recolhe o painel de log (seta no log e na barra de status, Exibir > Log, Ctrl+L); a escolha fica gravada
  function setLog(open) {
    openMenu = null;
    logOpen = open;
    seen = log.length;
    saveSetting(LOG_KEY, open ? 'open' : 'closed');
  }

  // NIVEL BASICO: O que cada exportacao precisa para estar habilitada (a lista e fixa; o que nao se aplica fica
  // desabilitado)
  function canExport(kind) {
    if (busy || !openedPath) return false;
    if (kind === 'table' || kind === 'tableSchema') return !!selectedTable;
    if (kind === 'marked') return markedRows.length > 0;
    if (kind === 'tables') return tables.length > 0;
    if (kind === 'sql') return !!sqlResult?.columns.length;
    if (kind === 'found') return everywhere && !!found?.tables?.length;
    if (kind === 'terms') return !!termsResult;
    return true; // esquema do banco
  }

  // NIVEL BASICO: O que cada item dos menus faz (run), quando fica desabilitado (off) e marcado (on; radio = um de um
  // grupo). Os atalhos passam por aqui: valem quando o item do menu vale
  let commands = $derived.by(() => {
    const open = !!openedPath;
    const onCell = !!grid && !!cell;
    const onData = tab === 'data' && onCell && !!selectedTable;
    const list = {
      open: { run: browse, off: busy },
      openPath: { run: () => openDatabase(), off: busy || !dbPath.trim() },
      reopen: { run: reload, off: busy || !(openedPath || dbPath.trim()) },
      save: { run: () => save(false), off: busy || !open },
      saveAs: { run: () => save(true), off: busy || !open },
      export: { off: busy || !open },
      close: { run: closeDatabase, off: busy || !open },
      exit: { run: quit },
      copyValue: { run: () => grid.copy('value'), off: !onCell },
      copyRow: { run: () => grid.copy('row'), off: !onCell },
      copyRowHeader: { run: () => grid.copy('row-header'), off: !onCell },
      copyLog: { run: copyLog, off: !log.length },
      find: { run: focusSearch, off: !selectedTable },
      filterValue: { run: () => gridActions.filter(cell.col, cell.row[cell.col]), off: !onData },
      clearFilters: { run: () => setFilters([]), off: !filters.length },
      mark: { run: () => toggleMark(cell.row), off: !onData },
      unmarkAll: { run: unmarkAll, off: !markedRows.length },
      'tab.data': { run: () => (tab = 'data') },
      'tab.schema': { run: () => (tab = 'schema') },
      'tab.sql': { run: focusSql },
      'tab.terms': { run: focusTerms },
      limit: {},
      columns: { run: openColumns, off: !selectedTable },
      scope: {},
      onlyMarked: { run: () => (onlyMarked = !showOnly), on: showOnly, off: !markedRows.length },
      goTables: { run: focusTables, off: !tables.length },
      favorite: { run: () => setFavorite(selectedTable), off: !selectedTable },
      runSql: { run: () => ((tab = 'sql'), runSql()), off: busy || !open || !sql.trim() },
      runTerms: { run: () => ((tab = 'terms'), runTerms()), off: !canRunTerms },
      log: { run: () => setLog(!logOpen), on: logOpen },
      theme: {},
      lang: {},
      defaultScope: {},
      match: {},
      showNull: { run: () => setShowNull(!showNull), on: showNull },
      about: { run: showAbout },
    };
    const radio = (id, run, on) => (list[id] = { run, on, radio: true });
    for (const n of LIMITS) radio(`limit.${n}`, () => setLimit(n), limit === n);
    // Exibir > Pesquisar em: o escopo da aba na tela (Termos tem o seu)
    for (const [id] of SCOPES) {
      radio(`scope.${id}`, () => (tab === 'terms' ? (termsScope = id) : setScope(id)), (tab === 'terms' ? termsScope : scope) === id);
      radio(`defaultScope.${id}`, () => setDefaultScope(id), defaultScope === id);
    }
    THEMES.forEach((_, i) => radio(`theme.${i}`, () => setTheme(i), themeIndex === i));
    for (const [code] of LANGS) radio(`lang.${code}`, () => setLang(code), lang === code);
    for (const [id] of MATCHES) radio(`match.${id}`, () => setDefaultMatch(id), defaultMatch === id);
    // Exportar: "export.<o que>" (com submenu de formatos) ou "export.<o que>.<formato>"
    for (const [id, , formats] of EXPORT_MENU) {
      const [, kind, format] = id.split('.');
      list[id] = { off: !canExport(kind) };
      for (const [leaf] of Array.isArray(formats) ? formats : [[id]]) {
        list[leaf] = { run: () => startExport(kind, format ?? leaf.split('.')[2]), off: !canExport(kind) };
      }
    }
    return list;
  });

  // roda o comando de um item de menu ou de um atalho, se estiver habilitado
  function run(id) {
    openMenu = null;
    const command = commands[id];
    if (command?.run && !command.off) command.run();
  }

  function toggleMenu(event, name) {
    event.stopPropagation();
    contextMenu = null;
    subPath = [];
    openMenu = openMenu === name ? null : name;
  }

  // NIVEL BASICO: Caixa com mais de um botao: todos com a mesma largura e altura, a do maior texto nos 3 idiomas (a caixa
  // fica igual em qualquer idioma). labels = [chave, valores] de cada botao, na ordem da tela
  // NIVEL TECNICO: each text is measured in a hidden copy of its own button (same class and font), never in the buttons
  // Svelte renders; the height is the same because every button is one line (nowrap) with the same padding
  function sameSize(actions, labels) {
    const buttons = [...actions.querySelectorAll(':scope > button')];
    let width = 0;
    buttons.forEach((button, i) => {
      const probe = button.cloneNode(false);
      probe.style.cssText = 'position: absolute; visibility: hidden; width: auto';
      actions.append(probe);
      for (const [code] of LANGS) {
        probe.textContent = translator(code)(...labels[i]);
        width = Math.max(width, probe.getBoundingClientRect().width);
      }
      probe.remove();
    });
    for (const button of buttons) button.style.width = `${Math.ceil(width)}px`;
  }

  // NIVEL BASICO: Pergunta com botoes (sair com banco nao salvo, exportacao em andamento, tabela inteira ou so as linhas
  // encontradas). Devolve o id do botao escolhido; Esc e o X da caixa devolvem null
  async function ask(asked) {
    const answer = new Promise((resolve) => (question = { ...asked, resolve }));
    askDialog.showModal();
    await tick();
    sameSize(askDialog.querySelector('.actions'), question.buttons.map(({ key, values }) => [key, values]));
    askDialog.querySelector('button.default')?.focus();
    return answer;
  }

  // dialogo Colunas...: os 3 botoes com a mesma largura (sameSize)
  function openColumns() {
    columnsDialog.showModal();
    sameSize(columnsDialog.querySelector('.actions'), [['columns.showAll'], ['columns.hideAll'], ['common.close']]);
  }

  function reply(id) {
    askDialog.close();
    question?.resolve(id);
    question = null;
  }

  // NIVEL BASICO: Sair do programa (Arquivo > Sair, Ctrl+Q, X da janela, Alt+F4). Exportacao em andamento: pergunta
  // antes de tudo, e Sair cancela a exportacao (sem arquivo pela metade). Access convertido e nao salvo: Salvar /
  // Voltar / Sair (Salvar abre a caixa de salvar; cancelada, a pergunta volta). So aqui se pergunta: fechar o arquivo,
  // abrir outro e reabrir apagam o convertido nao salvo sem perguntar. Pesquisa em andamento: cancelada sem perguntar
  async function quit() {
    openMenu = null;
    if (question) return; // uma pergunta ja esta aberta
    if (progress) {
      const choice = await ask({
        title: t('exportRun.title'),
        text: t('exportRun.text', { name: baseName(progress.path) }),
        buttons: [
          { id: 'back', key: 'common.back', right: true, primary: true },
          { id: 'exit', key: 'file.exit', right: true },
        ],
      });
      if (choice !== 'exit') return;
      await invoke('cancel_export');
      await exportEnd;
    }
    if (quitting) return; // era o Salvar desta pergunta: cancelado, ela volta no quit que a abriu
    quitting = true;
    try {
      while (converted) {
        const choice = await ask({
          title: t('convert.title'),
          text: t('exit.text', { name: baseName(openedPath) }),
          x: true,
          buttons: [
            { id: 'save', key: 'file.save', primary: true },
            { id: 'back', key: 'common.back', right: true },
            { id: 'exit', key: 'file.exit', right: true },
          ],
        });
        if (choice === 'exit') break; // o backend apaga o temporario ao sair
        if (choice !== 'save') return; // Voltar, Esc ou X da caixa
        await save(false, true);
      }
      await invoke('exit_app');
    } finally {
      quitting = false;
    }
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
      listen('terms-progress', ({ payload }) => {
        if (termsWork) termsWork = payload;
      }),
      // fechar a janela com exportacao em andamento ou SQLite convertido nao salvo: o backend segura e pergunta aqui
      listen('close-requested', quit),
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
    // o app caiu antes? os SQLite convertidos que ficaram para tras somem (pastas temporarias e as de originais que
    // receberam um); quantos, no Log
    invoke('clean_stale', { beside: loadJson(TEMP_KEY, []) }).then((count) => {
      saveSetting(TEMP_KEY, null);
      if (count) note('info', { key: 'status.staleRemoved', values: { count: fmt(count) } });
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

  // NIVEL BASICO: Arquivo salvo de cada Access (entre execucoes, como o Go): chave do Access -> { dest, destKey }
  // o arquivo salvo deste Access, se nenhum dos dois mudou (caminho, tamanho e data); senao null e o Access e convertido
  async function savedSqlite(key) {
    const entry = savedEntry(loadJson(SAVED_KEY, {}), key);
    if (!entry) return null;
    return (await invoke('file_key', { path: entry.dest })) === entry.destKey ? entry.dest : null;
  }

  // lembra o arquivo salvo do Access aberto; uma versao antiga do mesmo Access sai da lista
  async function rememberSaved(key, dest) {
    const destKey = key && (await invoke('file_key', { path: dest }));
    if (destKey) saveSetting(SAVED_KEY, JSON.stringify(withSaved(loadJson(SAVED_KEY, {}), key, dest, destKey, SAVED_MAX)));
  }

  // NIVEL BASICO: Arquivo > Salvar (Ctrl+S) e Salvar como... (Ctrl+Shift+S), com qualquer banco aberto: a caixa de
  // salvar nativa com SQLite, DuckDB e Excel, ja marcado o tipo do arquivo aberto (Access e SQLite: SQLite; DuckDB:
  // DuckDB). Salvar comeca na pasta do arquivo original; Salvar como, na ultima pasta em que o usuario salvou ou
  // exportou (sem ela, a do original). Devolve true se salvou. exiting: pedido pela pergunta de sair, que vale mesmo
  // com uma pesquisa ou consulta rodando (sair cancela a pesquisa)
  async function save(asLast, exiting = false) {
    openMenu = null;
    if ((busy && !exiting) || !openedPath) return false;
    const access = isAccess(openedPath);
    const selected = !access && source === 'DuckDB' ? 1 : 0;
    const dir = (asLast && loadSetting(SAVE_DIR_KEY)) || dirOf(openedPath);
    // o nome do original; se for o proprio arquivo aberto (mesma pasta e mesmo nome), "<nome> (copia)"
    const sameDir = dir.toLowerCase() === dirOf(readFile).toLowerCase();
    const name = suggestedName(stem(openedPath), SAVE_FORMATS[selected], sameDir ? readFile : '', (base) => t('save.copyName', { name: base }));
    try {
      const picked = await invoke('save_dialog', {
        title: t('save.title'),
        path: joinPath(dir, name),
        types: SAVE_FORMATS.map((format) => [t(`save.${format}`), format]),
        selected,
      });
      if (!picked) return false; // cancelada
      const { path, format } = savedFormat(...picked);
      saveSetting(SAVE_DIR_KEY, dirOf(path));
      // Access convertido para SQLite: copia o temporario; os outros, o banco inteiro. Os dois com a barra de progresso
      // (sair durante a copia pergunta antes, como numa exportacao)
      const copy = converted && format === 'sqlite';
      if (!(await runExport(t('file.save'), { scope: copy ? 'converted' : 'database', format, path }, copy ? null : 'Tables'))) {
        return false;
      }
      if (access) {
        // SQLite ou DuckDB: abrir de novo o mesmo Access, sem mudanca, abre o arquivo salvo. Salvo (tambem em Excel),
        // sair nao pergunta mais
        if (format !== 'xlsx') await rememberSaved(accessKey, path);
        if (converted) await invoke('discard_converted');
        converted = false;
      }
      return true;
    } catch (err) {
      showError(err);
      return false;
    }
  }

  // outro arquivo (ou nenhum): tabela, pesquisa, filtros, marcas e pesquisa de termos zerados, escopo de volta ao padrao
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
    marks = new Map();
    onlyMarked = false;
    dropTerms();
  }

  // NIVEL BASICO: Abre o banco; caminho vazio usa MDB2SQL_DB_PATH ou data/sample.duckdb
  // chosen: arquivo do dialogo Abrir ou arrastado para a janela. O Access convertido e nao salvo que estava aberto e
  // apagado sem pergunta quando o outro abre (linha no Log)
  async function openDatabase(event, chosen) {
    event?.preventDefault();
    openMenu = null;
    // "Copiar como caminho" do Windows cola o caminho entre aspas
    const path = (chosen ?? dbPath).trim().replace(/^"(.*)"$/, '$1');
    dbPath = path;
    busy = true;
    const discarded = converted ? baseName(openedPath) : '';
    showStatus('status.opening');
    try {
      // Access ja convertido e salvo, sem mudanca: abre o arquivo salvo (nada de converter de novo)
      const key = isAccess(path) ? await invoke('file_key', { path }) : null;
      const saved = await savedSqlite(key);
      const opened = await invoke('load_database', { dbPath: path, saved });
      if (discarded) note('info', { key: 'status.discarded', values: { name: discarded } });
      tables = opened.tables;
      tableRows = new Map(opened.tables.map((name, i) => [name, opened.rows[i]]));
      openedPath = opened.path;
      readFile = opened.file;
      source = opened.source;
      converted = opened.converted;
      accessKey = key;
      if (opened.beside) saveSetting(TEMP_KEY, JSON.stringify([...new Set([...loadJson(TEMP_KEY, []), opened.beside])]));
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

  // NIVEL BASICO: Arquivo > Fechar (Ctrl+W); o Access convertido e nao salvo e apagado sem pergunta (linha no Log)
  async function closeDatabase() {
    openMenu = null;
    if (!openedPath) return;
    try {
      await invoke('close_database');
    } catch (err) {
      showError(err);
      return;
    }
    const name = baseName(openedPath);
    if (converted) note('info', { key: 'status.discarded', values: { name } });
    tables = [];
    tableRows = new Map();
    openedPath = '';
    readFile = '';
    source = '';
    converted = false;
    accessKey = null;
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
    if (termsTable) openTermsTable(termsTable); // o titulo da coluna Termo vem com as linhas
  }

  // Settings > Escopo padrao da busca: gravado, e passa a valer tambem na pesquisa aberta e na aba Termos
  function setDefaultScope(next) {
    openMenu = null;
    defaultScope = next;
    saveSetting(SCOPE_KEY, next === 'all' ? 'all' : null);
    termsScope = next;
    setScope(next);
  }

  // Settings > Comparacao dos termos: gravada, e passa a valer tambem no seletor da aba Termos
  function setDefaultMatch(next) {
    openMenu = null;
    defaultMatch = match = next;
    saveSetting(MATCH_KEY, next === 'contains' ? 'contains' : null);
  }

  function setShowNull(show) {
    openMenu = null;
    showNull = show;
    saveSetting(NULL_KEY, show ? 'on' : 'off');
  }

  // Linhas (100, 500, 1000): vale para a aba Dados, o resultado do SQL e a grade da aba Termos
  function setLimit(next) {
    limit = next;
    openTable(selectedTable);
    if (termsTable) openTermsTable(termsTable);
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

  // NIVEL BASICO: Busca schema, linhas e contagens da tabela em paralelo; filtros e pesquisa vao na consulta. As
  // linhas marcadas da tabela vem a parte (todas, qualquer que seja a pesquisa).
  // Outra tabela comeca sem filtros e com a pesquisa `keep` (a de Todas as tabelas, ao escolher uma achada)
  async function openTable(tableName, keep = '') {
    if (!tableName) return;
    if (tableName !== selectedTable) {
      search = keep;
      hidden = new Set();
      filters = [];
      onlyMarked = false;
      dropFound();
    }
    selectedTable = tableName;
    busy = true;
    error = null;
    try {
      const asked = filters;
      const words = search.trim();
      const narrowed = asked.length > 0 || words !== '';
      const marked = marks.get(tableName);
      const [schema, page, total, matching] = await Promise.all([
        invoke('get_table_schema', { tableName }),
        invoke('get_table_data', { tableName, limit, filters: asked, search: words, marked: (marked ?? []).map((row) => row[ROW_ID]) }),
        invoke('get_row_count', { tableName, filters: [], search: '' }),
        narrowed ? invoke('get_row_count', { tableName, filters: asked, search: words }) : null,
      ]);
      // Ignora resposta atrasada se o usuario ja trocou de tabela, filtro ou pesquisa
      if (tableName !== selectedTable || asked !== filters || words !== search.trim()) return;
      columns = schema;
      rows = withIds(page.rows, page.ids);
      // as marcadas, relidas na ordem da tabela (se o usuario nao marcou outra enquanto a consulta rodava)
      if (marked && marks.get(tableName) === marked) setMarks(tableName, withIds(page.marked, page.marked_ids));
      rowCount = total;
      matchCount = matching ?? total;
    } catch (err) {
      showError(err);
    } finally {
      busy = false;
    }
  }

  // linhas marcadas de uma tabela (lista vazia tira a tabela do Map e desliga "So as marcadas")
  function setMarks(table, list) {
    const next = new Map(marks);
    if (list.length) next.set(table, list);
    else next.delete(table);
    marks = next;
    if (!list.length && table === selectedTable) onlyMarked = false;
  }

  // caixa da linha, Espaco na linha da celula escolhida, menu da celula e Editar > Marcar ou desmarcar linha. Sem
  // rowid (view) a identidade e texto e a marcada entra no fim: a tabela e relida para elas voltarem na ordem dela
  function toggleMark(row) {
    setMarks(selectedTable, toggleMarked(markedRows, row));
    if (typeof row[ROW_ID] !== 'number') openTable(selectedTable);
  }
  const unmarkAll = () => setMarks(selectedTable, []);

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

  // NIVEL BASICO: Todas as tabelas: lista as tabelas com linhas que tem o termo e quantas (backend: a mesma regra da
  // pesquisa da tabela, em todas as colunas). Resposta velha nunca aparece; a pesquisa nova para a antiga no backend.
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
    columns: openColumns,
    showAll: () => (hidden = new Set()),
    filter: (column, value) => setFilters(withFilter(filters, column, value)),
    clearFilters: () => setFilters([]),
  };

  // itens "<formato>..." de um submenu de exportacao, para os menus de clique direito das grades
  const exportItems = (kind, formats) => formats.map((format) => ({ label: t(`format.${format}`), run: () => startExport(kind, format) }));
  // menu da celula da aba Dados, depois de copiar: marcar a linha, exportar as marcadas, desmarcar todas
  let dataExtra = $derived([
    { label: t('edit.mark'), run: toggleMark },
    { label: t('marks.export'), off: !canExport('marked'), items: exportItems('marked', ['csv', 'xlsx']) },
    { label: t('edit.unmarkAll'), off: !markedRows.length, run: unmarkAll },
  ]);
  // menu da celula da aba Termos, depois de copiar: todas as linhas achadas da tabela e o relatorio
  let termsExtra = $derived([
    { label: t('terms.copyHits'), run: copyTermHits },
    { label: t('export.terms'), off: !canExport('terms'), items: exportItems('terms', ['xlsx', 'csv', 'sqlite', 'duckdb']) },
  ]);

  // NIVEL BASICO: SQL da aba SQL (so comandos de leitura); mostra ate o limite de linhas. Sem erro: sai o erro anterior da
  // linha do botao e da barra de baixo. Com erro: sai a grade do SQL anterior (pareceria o resultado deste) e o erro fica
  // nos dois lugares
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
      showError(err, sqlContext(err)); // erro do motor com o prefixo traduzido
    } finally {
      busy = false;
    }
  }

  // esquece a pesquisa de termos (outra pesquisa, outro arquivo): a resposta da que estiver em andamento e descartada
  function dropTerms() {
    termsRun++;
    termsWork = null;
    termsResult = null;
    termsTable = '';
    termsPage = null;
  }

  // NIVEL BASICO: Pesquisar termos (botao e Ctrl+Enter na aba Termos): o backend pesquisa no motor, em todas as colunas
  // das tabelas do escopo, com progresso e Cancelar. Mostra o resumo, as tabelas com acerto (a primeira ja escolhida) e
  // os termos nao encontrados
  async function runTerms() {
    if (!canRunTerms) return;
    dropTerms();
    const run = termsRun;
    const { terms } = termList;
    busy = true;
    termsWork = { done: 0, total: 0, item: '' };
    try {
      const table = termsScope === 'table' ? selectedTable : null;
      const hits = await invoke('search_terms', { terms, whole: match === 'whole', table });
      if (run !== termsRun) return;
      termsResult = { terms, ...termsOutcome(terms, hits) };
      showStatus('terms.summary', termsValues(termsResult));
      if (termsResult.tables.length) await openTermsTable(termsResult.tables[0].table);
    } catch (err) {
      if (run === termsRun) showError(err);
    } finally {
      if (run === termsRun) termsWork = null;
      busy = false;
    }
  }

  const termsValues = (r) => ({ found: fmt(r.found), total: fmt(r.terms.length), rows: fmt(r.rows), tables: fmt(r.tables.length) });

  // linhas achadas da tabela escolhida: a coluna Termo e as colunas da tabela, ate o limite de linhas
  async function openTermsTable(table) {
    termsTable = table;
    const run = termsRun;
    try {
      const page = await invoke('terms_rows', { table, limit, label: t('terms.col') });
      if (run === termsRun && table === termsTable) termsPage = page;
    } catch (err) {
      if (run === termsRun) showError(err);
    }
  }

  // NIVEL BASICO: Copiar as linhas encontradas desta tabela: todas (nao so as da tela), com o cabecalho, separadas por TAB
  // e sem a coluna Termo; colar no Excel da exatamente as linhas achadas
  async function copyTermHits() {
    try {
      const all = await invoke('terms_rows', { table: termsTable, limit: 0, label: t('terms.col') });
      const names = all.columns.slice(1).map((col) => col.name);
      if (await copyText(rowsToTsv(names, all.rows))) showStatus('terms.copied', { count: fmt(all.rows.length) });
    } catch (err) {
      showError(err);
    }
  }

  async function copyNotFound() {
    const list = termsResult.notFound;
    if (await copyText(list.join('\r\n'))) showStatus('terms.copied', { count: fmt(list.length) });
  }

  // nome sugerido, o que vai ao backend e a unidade da frase final de cada exportacao
  const EXPORTS = {
    table: () => ({ name: selectedTable, unit: 'Rows', request: { scope: 'table', table: selectedTable } }),
    marked: () => ({
      name: `${selectedTable}_marcadas`,
      unit: 'Rows',
      request: { scope: 'marked', table: selectedTable, ids: markedRows.map((row) => row[ROW_ID]) },
    }),
    tableSchema: () => ({ name: `${selectedTable}_schema`, unit: 'Rows', request: { scope: 'schema', table: selectedTable, labels: schemaLabels() } }),
    dbSchema: () => ({ name: `${stem(openedPath)}_schema`, unit: 'Rows', request: { scope: 'schema', labels: schemaLabels() } }),
    tables: () => ({ folder: true, unit: 'Tables', request: { scope: 'tables' } }),
    sql: () => ({ name: 'query', unit: 'Rows', request: { scope: 'sql', sql: lastSql } }),
    found: () => ({ name: `${stem(openedPath)}_busca`, unit: 'Tables', request: { scope: 'found', search: search.trim() } }),
    terms: (format) => ({
      name: `${stem(openedPath)}_termos`,
      folder: format === 'csv',
      unit: 'Tables',
      request: { scope: 'terms', labels: ['terms.col', 'terms.status', 'tables.name', 'tables.rows', 'terms.found', 'terms.missing', 'terms.sheetSummary', 'terms.sheetNotFound'].map((key) => t(key)) },
    }),
  };
  // titulos Tabela, Coluna, Tipo, Aceita nulo e os valores Sim e Nao do esquema exportado, no idioma da tela
  const schemaLabels = () => ['tables.name', 'schema.column', 'schema.type', 'schema.nullable', 'schema.yes', 'schema.no'].map((key) => t(key));

  // NIVEL BASICO: Um item de Exportar: pergunta onde salvar (pasta do arquivo aberto, senao a ultima usada) e exporta
  // fora da thread da interface, com barra de progresso e Cancelar. Exportacao para pasta (um CSV por tabela): seletor
  // de pasta e, se algum arquivo ja existe ali, uma pergunta so
  async function startExport(kind, format) {
    openMenu = null;
    if (!canExport(kind)) return;
    const item = EXPORT_MENU.find(([id]) => id.split('.')[1] === kind);
    const label = Array.isArray(item[2]) ? `${t(item[1])} - ${t(`format.${format}`)}` : t(item[1]);
    const title = label.replace(/\.\.\.$/, '');
    const { name, folder, unit, request } = EXPORTS[kind](format);
    // tabela com pesquisa ou filtro na grade (as 4 versoes): a tabela inteira ou so as linhas encontradas
    if (kind === 'table' && !everywhere && (search.trim() || filters.length)) {
      // a pesquisa digitada que ainda espera os 300 ms vale agora: o numero da pergunta e o das linhas exportadas
      clearTimeout(searchTimer);
      await openTable(selectedTable);
      const choice = await ask({
        title,
        buttons: [
          { id: 'all', key: 'export.wholeTable', primary: true },
          { id: 'found', key: 'export.foundRows', values: { count: fmt(matchCount) } },
          { id: 'cancel', key: 'common.cancel', right: true },
        ],
      });
      if (choice !== 'all' && choice !== 'found') return; // Cancelar ou Esc
      if (choice === 'found') Object.assign(request, { filters, search: search.trim() });
    }
    const dir = defaultSaveDir(openedPath, loadSetting(LAST_DIR_KEY));
    try {
      const path = folder
        ? await invoke('plugin:dialog|open', { options: { title, directory: true, defaultPath: dir || undefined } })
        : await invoke('plugin:dialog|save', {
            options: {
              title,
              defaultPath: joinPath(dir, suggestedName(name, format, readFile)),
              filters: [{ name: t(`save.${format}`), extensions: [format] }],
            },
          });
      if (!path) return; // cancelado
      Object.assign(request, { format, path: String(path) });
      saveSetting(LAST_DIR_KEY, folder ? request.path : dirOf(request.path));
      saveSetting(SAVE_DIR_KEY, folder ? request.path : dirOf(request.path));
      if (folder) {
        const existing = await invoke('export_existing', { request });
        const message = t('ask.overwriteMany', { count: fmt(existing) });
        if (existing && (await invoke('plugin:dialog|message', { title, message, kind: 'warning', buttons: 'YesNo' })) !== 'Yes') return;
      }
      await runExport(title, request, unit);
    } catch (err) {
      showError(err);
    }
  }

  // NIVEL BASICO: Roda a exportacao (ou o Salvar do banco inteiro) com a barra de progresso e Cancelar; no fim, a frase
  // com as tabelas ou linhas gravadas (e as abas, se foi Excel); unit null: a copia do SQLite convertido (frase de salvo).
  // Devolve true se gravou
  async function runExport(label, request, unit) {
    let finish;
    exportEnd = new Promise((resolve) => (finish = resolve));
    progress = { label, path: request.path, done: 0, total: 0, item: '' };
    progressDialog.showModal();
    await tick();
    progressDialog.querySelector('button.default')?.focus();
    try {
      const done = await invoke('export', { request });
      const values = { count: fmt(done.count), sheets: fmt(done.sheets ?? 0), path: request.path };
      showStatus(unit ? `status.exported${unit}${done.sheets == null ? '' : 'Sheets'}` : 'status.sqliteSaved', values);
      return true;
    } catch (err) {
      showError(err);
      return false;
    } finally {
      progress = null;
      progressDialog.close();
      finish();
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

  // barra de status: clique direito > Copiar (o texto tambem pode ser selecionado com o mouse); lista de tabelas: clique
  // direito numa tabela > Favoritar / Desfavoritar (table)
  function openStatusMenu(event, table) {
    event.preventDefault();
    event.stopPropagation();
    openMenu = null;
    contextMenu = { x: event.clientX, y: event.clientY, table };
  }

  // Exibir > Favoritar ou desfavoritar tabela (Ctrl+D, tabela atual) e o clique direito na lista
  function setFavorite(table) {
    contextMenu = null;
    favorites = toggleFavorite(favorites, table);
  }

  async function copyStatus() {
    contextMenu = null;
    await copyText(headline.text);
  }

  async function copyLog() {
    if (await copyText(logText)) showStatus('status.logCopied');
  }

  // NIVEL BASICO: Atalhos, os mesmos nas 4 versoes e os dos itens de menu (valem quando o item vale): Ctrl+O abrir, F5
  // reabrir, Ctrl+S salvar, Ctrl+Shift+S salvar como, Ctrl+W fechar, Ctrl+Q sair, Ctrl+F pesquisar, Ctrl+T lista de
  // tabelas, Ctrl+1/2/3/4 abas, Ctrl+L log, Ctrl+Enter executar o SQL ou pesquisar os termos (na aba de cada um); na
  // grade, Ctrl+C copia a celula, Ctrl+Shift+C a linha e Espaco marca a linha (Grid.svelte).
  // Com um dialogo aberto so valem as teclas dele; F5 nunca recarrega a pagina do webview (a tela voltaria do zero)
  function shortcut(e) {
    if (e.key === 'Escape') (openMenu = null), (contextMenu = null);
    if (e.key === 'F5') e.preventDefault();
    const key = e.key.toLowerCase();
    if (document.querySelector('dialog[open]') || e.altKey) {
      // exportacao em andamento (a barra de progresso e um dialogo): Ctrl+Q pergunta antes de sair
      if (e.ctrlKey && key === 'q' && progress) quit();
      return;
    }
    if (e.key === 'F5' && !e.ctrlKey) return run('reopen');
    if (!e.ctrlKey) return;
    const ids = {
      o: 'open',
      s: e.shiftKey ? 'saveAs' : 'save',
      w: 'close',
      q: 'exit',
      f: 'find',
      t: 'goTables',
      d: 'favorite',
      l: 'log',
      1: 'tab.data',
      2: 'tab.schema',
      3: 'tab.sql',
      4: 'tab.terms',
      enter: tab === 'terms' ? 'runTerms' : tab === 'sql' ? 'runSql' : '',
    };
    if (!ids[key]) return;
    e.preventDefault();
    run(ids[key]);
  }

  // F5 e Arquivo > Reabrir: abre de novo o banco aberto (rele a lista de tabelas); sem banco aberto, o caminho do campo
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

  // Ctrl+3: aba SQL com o editor em foco; Ctrl+4: aba Termos com a caixa dos termos em foco
  async function focusSql() {
    tab = 'sql';
    await tick();
    document.querySelector('.sql textarea')?.focus();
  }

  async function focusTerms() {
    tab = 'terms';
    await tick();
    document.querySelector('.terms textarea')?.focus();
  }

  // Ctrl+T: a lista de tabelas em foco (setas, Home e End trocam a tabela)
  const focusTables = () => document.querySelector('.table-list')?.focus();

  // menu perto da borda: puxa para dentro da janela. above: abre acima do ponto (barra de status, embaixo); senao abaixo
  // dele (lista de tabelas: o menu nao cobre a tabela clicada)
  const keepInside = (node, above = true) => {
    const box = node.getBoundingClientRect();
    node.style.left = `${Math.max(4, Math.min(box.left, innerWidth - box.width - 4))}px`;
    node.style.top = `${Math.max(4, Math.min(above ? box.top - box.height : box.top + 4, innerHeight - box.height - 4))}px`;
  };
  // submenu ao lado do item; sem lugar a direita, abre para a esquerda
  const beside = (node) => {
    if (node.getBoundingClientRect().right > innerWidth - 4) node.classList.add('left');
  };
  const focusNow = (node) => node.focus();
</script>

<!-- itens de um menu (e, dentro deles, os submenus): a arvore vem de menus.js e o que cada id faz, de `commands`. A
     lista de exportacao e uma so, mostrada pelo menu Arquivo e pelo botao Exportar... do topo -->
{#snippet menuItems(items, depth)}
  {@const checks = items.some((item) => item !== '-' && commands[item[0]]?.on !== undefined)}
  {#each items as item}
    {#if item === '-'}
      <div class="separator" role="separator"></div>
    {:else}
      {@const [id, text, extra] = item}
      {@const command = commands[id] ?? {}}
      {#if Array.isArray(extra)}
        <div class="submenu-root" role="none" onmouseenter={() => (subPath = [...subPath.slice(0, depth), id])}>
          <button
            type="button"
            role="menuitem"
            aria-haspopup="menu"
            aria-expanded={subPath[depth] === id}
            disabled={command.off}
            onclick={(e) => {
              e.stopPropagation(); // o clique abre o submenu, nao fecha o menu
              subPath = [...subPath.slice(0, depth), id];
            }}
          >
            {#if checks}<span class="check"></span>{/if}{t(text)} <span class="arrow">▸</span>
          </button>
          {#if subPath[depth] === id && !command.off}
            <div class="dropdown sub" role="menu" aria-label={t(text)} use:beside>{@render menuItems(extra, depth + 1)}</div>
          {/if}
        </div>
      {:else}
        <button
          type="button"
          role={command.on === undefined ? 'menuitem' : command.radio ? 'menuitemradio' : 'menuitemcheckbox'}
          aria-checked={command.on}
          disabled={command.off}
          onmouseenter={() => (subPath = subPath.slice(0, depth))}
          onclick={() => run(id)}
        >
          {#if checks}<span class="check">{command.on ? (command.radio ? '●' : '✓') : ''}</span>{/if}{t(text)}{#if extra}<kbd>{t(extra)}</kbd>{/if}
        </button>
      {/if}
    {/if}
  {/each}
{/snippet}

<div class="app">
  <div class="menubar" role="menubar" aria-label={t('menu.main')}>
    {#each MENUS as [id, text, items]}
      <div class="menu-root">
        <button type="button" role="menuitem" aria-haspopup="menu" aria-expanded={openMenu === id} onclick={(e) => toggleMenu(e, id)}>{t(text)}</button>
        {#if openMenu === id}
          <div class="dropdown" role="menu" aria-label={t(text)}>{@render menuItems(items, 0)}</div>
        {/if}
      </div>
    {/each}
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
          <div class="dropdown end" role="menu" aria-label={t('file.export')}>{@render menuItems(EXPORT_MENU, 0)}</div>
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

  <!-- pergunta com botoes: sair com o banco convertido nao salvo (Salvar a esquerda; Voltar e Sair a direita, lado a
       lado), exportacao em andamento ao sair, tabela inteira ou so as linhas encontradas. Esc e o X da caixa nao
       escolhem nada (Voltar, Cancelar) -->
  <dialog
    bind:this={askDialog}
    class="ask"
    aria-labelledby="ask-title"
    oncancel={(e) => {
      e.preventDefault();
      reply(null);
    }}
  >
    {#if question}
      {#if question.x}
        <button type="button" class="dialog-x" aria-label={t('common.back')} title={t('common.back')} onclick={() => reply(null)}>×</button>
      {/if}
      <h2 id="ask-title">{question.title}</h2>
      {#if question.text}<p>{question.text}</p>{/if}
      <div class="actions">
        {#each question.buttons as button, i}
          <button
            type="button"
            class={button.primary ? 'default' : 'secondary'}
            class:close={button.right && !question.buttons[i - 1]?.right}
            onclick={() => reply(button.id)}>{t(button.key, button.values)}</button
          >
        {/each}
      </div>
    {/if}
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
          <div
            id="table-{i}"
            role="option"
            tabindex="-1"
            aria-selected={name === selectedTable}
            class:selected={name === selectedTable}
            onclick={() => openTable(name)}
            oncontextmenu={(e) => openStatusMenu(e, name)}
          >
            <!-- favorita: "★ " antes do nome, na cor do texto -->
            <span class="name">{favorites.has(name) ? '★ ' : ''}{name}</span><span class="rows">{tableRows.get(name) == null ? '' : fmt(tableRows.get(name))}</span>
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
        <select id="row-limit" value={limit} onchange={(e) => setLimit(Number(e.currentTarget.value))}>
          {#each LIMITS as option}
            <option value={option}>{option}</option>
          {/each}
        </select>
      {/snippet}

      <!-- seletor de duas opcoes colado numa caixa so (escopo da pesquisa, comparacao dos termos) -->
      {#snippet choice(options, value, pick, label, tip)}
        <div class="scope" role="radiogroup" aria-label={label} title={tip}>
          {#each options as [id, key]}
            <button type="button" role="radio" aria-checked={value === id} class:active={value === id} onclick={() => pick(id)}>{t(key)}</button>
          {/each}
        </div>
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
              <span class="sql-error">{statusLine(errorLine(sqlError, sqlContext(sqlError)))}</span>
            {:else if sqlResult}
              <span>{t('sql.summary', { rows: fmt(sqlResult.rows.length) + (sqlResult.truncated ? '+' : ''), columns: sqlResult.columns.length })}</span>
            {/if}
            <span class="limit">{@render rowLimit()}</span>
          </div>
        </div>
        {#if sqlResult?.columns.length}
          {#key sqlResult}
            <Grid bind:this={grid} bind:selected={cell} columns={sqlResult.columns} rows={sqlResult.rows} label={t('sql.result')} emptyText={t('sql.noRows')} {t} {nullText} onstatus={showStatus} onerror={showError} />
          {/key}
        {/if}
      {:else if tab === 'terms'}
        <!-- aba Termos, de cima para baixo: (a) a caixa dos termos; (b) Valor inteiro | Contem, Esta tabela | Todas as
             tabelas, Pesquisar termos e a contagem; (c) o resumo (ou o progresso, com Cancelar no lugar do botao); (d) as
             tabelas com acerto e a grade da escolhida; (e) os termos nao encontrados, copiaveis -->
        <div class="terms">
          <textarea bind:value={termsText} rows="8" aria-label={t('tabs.terms')} placeholder={t('terms.hint')} spellcheck="false"></textarea>
          <div class="table-bar terms-bar">
            {@render choice(MATCHES, match, (id) => (match = id), t('settings.match'), t('match.help'))}
            {@render choice(SCOPES, termsScope, (id) => (termsScope = id), t('scope.label'))}
            {#if termsWork}
              <button type="button" class="secondary" onclick={() => invoke('cancel_terms')}>{t('common.cancel')}</button>
            {:else}
              <button type="button" title={t('sql.runTip')} onclick={runTerms} disabled={!canRunTerms}>{t('terms.run')}</button>
            {/if}
            <span>{t('terms.count', { count: fmt(termList.terms.length) })}{termList.repeated ? t('terms.repeated', { count: fmt(termList.repeated) }) : ''}</span>
          </div>
          <p class="table-info">
            {#if termsWork}
              {t('terms.progress', { done: termsWork.total ? termsWork.done + 1 : 0, total: termsWork.total, item: termsWork.item })}
            {:else if termsResult}
              {t('terms.summary', termsValues(termsResult))}
            {/if}
          </p>
        </div>
        {#if termsResult}
          <div class="terms-found">
            <div class="found" role="group" aria-label={t('found.list')}>
              {#each termsResult.tables as f (f.table)}
                <button type="button" class:selected={f.table === termsTable} onclick={() => openTermsTable(f.table)}>{t('found.item', { table: f.table, count: fmt(f.count) })}</button>
              {:else}
                <p>{t('data.noMatch')}</p>
              {/each}
            </div>
            {#if termsPage}
              {#key termsPage}
                <Grid
                  bind:this={grid}
                  bind:selected={cell}
                  columns={termsPage.columns}
                  rows={termsPage.rows}
                  label={t('data.rows', { table: termsTable })}
                  emptyText={t('data.noMatch')}
                  {t}
                  {nullText}
                  onstatus={showStatus}
                  onerror={showError}
                  extra={termsExtra}
                  copySkip={1}
                />
              {/key}
            {/if}
          </div>
          {#if termsPage}
            <p class="table-info">
              {t('data.showingMatches', { table: termsTable, shown: fmt(termsPage.rows.length), matching: fmt(termsResult.tables.find((f) => f.table === termsTable)?.count ?? 0) })}
            </p>
          {/if}
          <section class="not-found" aria-labelledby="not-found-title">
            <div class="log-bar">
              <h2 id="not-found-title">{t('terms.notFound', { count: fmt(termsResult.notFound.length) })}</h2>
              <button type="button" class="secondary" onclick={copyNotFound} disabled={!termsResult.notFound.length}>{t('status.copy')}</button>
            </div>
            <textarea readonly rows="3" value={termsResult.notFound.join('\n')} aria-labelledby="not-found-title" spellcheck="false"></textarea>
          </section>
        {/if}
      {:else if !selectedTable}
        <p class="empty">{t('data.noTable')}</p>
      {:else if tab === 'schema'}
        <div class="table-bar"><h2>{selectedTable}</h2><span>{t('schema.columns', { count: columns.length })}</span></div>
        <!-- Schema: 6 px a mais de cada lado da celula (as colunas ficavam apertadas) -->
        {#key selectedTable}
        <Grid
          bind:this={grid}
          bind:selected={cell}
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
             achadas), com as linhas marcadas sempre no topo; (d) a contagem embaixo e, com marcas, "So as marcadas" -->
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
          {@render choice(SCOPES, scope, setScope, t('scope.label'))}
          <span class="limit">{@render rowLimit()}</span>
          <button type="button" class="secondary columns-button" title={t('columns.tip')} onclick={openColumns}>{t('columns.button')}</button>
        </div>
        {#if everywhere && !showOnly}
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
          bind:this={grid}
          bind:selected={cell}
          columns={shownColumns}
          rows={shownColumns.length ? shownRows : []}
          label={t('data.rows', { table: selectedTable })}
          emptyText={t(!shownColumns.length ? 'data.allHidden' : filters.length || search.trim() ? 'data.noMatch' : 'data.empty')}
          {t}
          {nullText}
          onstatus={showStatus}
          onerror={showError}
          actions={{ ...gridActions, all: columns, hidden, filtered: filters.length > 0 }}
          marks={{ has: (row) => markedRows.includes(row), toggle: toggleMark }}
          extra={dataExtra}
        />
        {/key}
        {/if}
        <!-- (d) "{tabela}: mostrando X de Y linhas" (com busca ou filtro, das encontradas) e ", N marcadas"; em Todas as
             tabelas, o resumo. A direita, so com marcas, a caixa "So as marcadas" (= Exibir > So as linhas marcadas) -->
        <p class="table-info">
          <span>
            {#if showOnly}
              {t('data.showing', { table: selectedTable, shown: fmt(markedRows.length), total: fmt(rowCount) })}
            {:else if everywhere}
              {!found ? t('found.searching') : found.tables ? t('found.summary', { count: fmt(found.tables.length) }) : ''}
            {:else if search.trim() || filters.length}
              {t('data.showingMatches', { table: selectedTable, shown: fmt(rows.length), matching: fmt(matchCount) })}
            {:else}
              {t('data.showing', { table: selectedTable, shown: fmt(rows.length), total: fmt(rowCount) })}
            {/if}{markedRows.length ? t('marks.count', { count: fmt(markedRows.length) }) : ''}
          </span>
          {#if markedRows.length}
            <label class="only-marked"><input type="checkbox" checked={showOnly} onchange={(e) => (onlyMarked = e.currentTarget.checked)} />{t('marks.only')}</label>
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

  {#if contextMenu?.table}
    {@const text = t(favorites.has(contextMenu.table) ? 'fav.remove' : 'fav.add')}
    <div class="context" role="menu" aria-label={text} style="left: {contextMenu.x}px; top: {contextMenu.y}px" use:keepInside={false}>
      <button type="button" role="menuitem" use:focusNow onclick={() => setFavorite(contextMenu.table)}>{text}</button>
    </div>
  {:else if contextMenu}
    <div class="context" role="menu" aria-label={t('status.copy')} style="left: {contextMenu.x}px; top: {contextMenu.y}px" use:keepInside>
      <button type="button" role="menuitem" use:focusNow onclick={copyStatus}>{t('status.copy')}</button>
    </div>
  {/if}
</div>

<svelte:window onclick={() => ((openMenu = null), (contextMenu = null))} onkeydown={shortcut} />

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

  /* submenu (Arquivo > Exportar, os formatos de cada exportacao, Tema, Idioma...): abre ao lado do item, do tamanho
     dos textos; sem lugar a direita, abre para a esquerda */
  .submenu-root {
    position: relative;
    display: flex;
    flex-direction: column;
  }

  .dropdown.sub {
    top: -5px;
    left: 100%;
    min-width: 120px;
  }

  .dropdown.sub:global(.left) {
    right: 100%;
    left: auto;
  }

  .dropdown button:hover:not(:disabled),
  .dropdown button:focus-visible {
    background: var(--row-hover);
  }

  .dropdown .separator {
    margin: 4px 0;
    border-top: 1px solid var(--border);
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

  /* pergunta com botoes (sair, exportacao em andamento, tabela inteira ou linhas encontradas): titulo, frase e os
     botoes numa linha, os da direita lado a lado */
  dialog.ask {
    position: relative;
    width: 460px;
  }

  dialog.ask .actions {
    margin-top: 16px;
  }

  /* X do dialogo: fecha sem escolher, como o Esc */
  dialog.ask .dialog-x {
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

  dialog.ask .dialog-x:hover {
    color: var(--text);
  }

  /* foco inicial sempre visivel no botao padrao (o showModal veio de clique, nao de teclado) */
  dialog.ask button.default:focus {
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

  /* contagem embaixo da grade: uma linha, no texto apagado das outras contagens; a direita, "So as marcadas" */
  .table-info {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    margin: 0;
    color: var(--muted);
    font-size: 12px;
  }

  /* caixa discreta: no tamanho e na cor da contagem */
  .only-marked {
    display: inline-flex;
    flex-shrink: 0;
    align-items: center;
    gap: 6px;
    color: inherit;
    font-size: inherit;
    font-weight: 400;
  }

  .only-marked input {
    margin: 0;
  }

  /* aba Termos: a caixa dos termos, a linha dos seletores e o resumo */
  .terms {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .terms textarea,
  .not-found textarea {
    resize: vertical;
    font-family: Consolas, 'Cascadia Mono', monospace;
    font-size: 12px;
  }

  /* tabelas com acerto ao lado da grade da tabela escolhida */
  .terms-found {
    display: flex;
    flex: 1;
    min-height: 0;
    gap: 8px;
  }

  .terms-found .found {
    flex: 0 0 220px;
  }

  /* termos nao encontrados: titulo com o botao Copiar e a caixa so de leitura */
  .not-found {
    display: flex;
    flex-direction: column;
    gap: 4px;
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

  /* aba Termos: a tabela escolhida, como a tabela escolhida na lista de tabelas */
  .found button.selected {
    background: var(--accent);
    color: var(--accent-text);
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
