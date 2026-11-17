<script>
  // NIVEL BASICO: Visualizador e conversor de bancos (DuckDB, SQLite, Access)
  // Menus: File (abrir, exportar), Settings (tema), Help (sobre). Abas: Data, Schema, SQL.
  // NIVEL TECNICO: Svelte 5 runes; every backend call goes through Tauri invoke()

  import { invoke } from '@tauri-apps/api/core';
  import { listen } from '@tauri-apps/api/event';
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import { onMount } from 'svelte';
  import Grid from './Grid.svelte';
  import {
    columnCellWidth,
    filterLabel,
    fold,
    hasAllWords,
    hiddenStatus,
    rowMatches,
    searchWords,
    toggleHidden,
    visibleColumns,
    withFilter,
  } from './grid.js';
  import { defaultSaveDir, dirOf, joinPath, stem, suggestedName } from './paths.js';

  const LIMITS = [100, 500, 1000];
  // null devolve a janela (barra de titulo e webview) ao tema do sistema
  const THEMES = [
    ['System', null],
    ['Light', 'light'],
    ['Dark', 'dark'],
  ];
  // File > Export: [texto, scope, format]
  const EXPORTS = [
    ['Database to DuckDB (.duckdb)...', 'database', 'duckdb'],
    ['Database to SQLite (.sqlite)...', 'database', 'sqlite'],
    ['Database to Excel (.xlsx, one sheet per table)...', 'database', 'xlsx'],
    ['Current table to CSV...', 'table', 'csv'],
    ['Current table to Excel (.xlsx)...', 'table', 'xlsx'],
    ['SQL result to CSV...', 'sql', 'csv'],
    ['SQL result to Excel (.xlsx)...', 'sql', 'xlsx'],
  ];
  const FILTERS = {
    duckdb: 'DuckDB database',
    sqlite: 'SQLite database',
    xlsx: 'Excel workbook',
    csv: 'CSV, UTF-8',
  };
  const OPEN_EXTENSIONS = ['duckdb', 'db', 'sqlite', 'sqlite3', 'mdb', 'accdb'];
  // preferencias gravadas no WebView2 (ficam entre execucoes)
  const THEME_KEY = 'mdb2sql.theme';
  const LAST_DIR_KEY = 'mdb2sql.lastDir';

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

  let openMenu = $state(null); // 'file' | 'settings' | 'help'
  let tab = $state('data');
  let themeIndex = $state(0);
  let aboutDialog;
  let aboutInfo = $state.raw(null); // { name, version, description, rows: [[rotulo, valor]], links: [[nome, url]] }
  let columnsDialog;
  let progressDialog;
  let progress = $state.raw(null); // { label, done, total, item } da exportacao em andamento

  let dbPath = $state('');
  let openedPath = $state('');
  let source = $state('');
  let tables = $state([]);
  let filter = $state('');
  let selectedTable = $state('');
  let columns = $state([]); // [{ name, type, null }] na ordem real da tabela
  // raw: linhas so sao trocadas inteiras; sem proxy por celula, e a busca guarda o texto por linha
  let rows = $state.raw([]);
  let rowCount = $state(0); // linhas da tabela inteira
  let matchCount = $state(0); // linhas que passam pelos filtros (sem filtro = rowCount)
  // valem para a tabela aberta; trocar de tabela ou de arquivo zera os dois
  let hidden = $state.raw(new Set()); // nomes das colunas ocultas
  let filters = $state.raw([]); // [{ column, value }] aplicados na consulta ao banco (AND)
  let limit = $state(LIMITS[0]);
  let search = $state('');
  let busy = $state(false);
  let status = $state('No database open');
  let error = $state('');

  let sql = $state('');
  let sqlResult = $state.raw(null); // { columns, rows, truncated }
  let lastSql = ''; // SQL que gerou sqlResult (o que a exportacao repete)

  let visibleTables = $derived.by(() => {
    const words = searchWords(filter);
    return tables.filter((t) => hasAllWords(fold(t), words));
  });
  let visibleRows = $derived.by(() => {
    const words = searchWords(search);
    return rows.filter((row) => rowMatches(row, words));
  });
  let shownColumns = $derived(visibleColumns(columns, hidden));
  let columnSearch = $state(''); // busca do dialogo Colunas...
  let listedColumns = $derived.by(() => {
    const words = searchWords(columnSearch);
    return columns.filter((col) => hasAllWords(fold(col.name), words));
  });

  const showStatus = (text) => {
    error = '';
    status = text;
  };
  const showError = (text) => (error = text);

  function canExport(scope) {
    if (busy || !openedPath) return false;
    if (scope === 'table') return !!selectedTable;
    if (scope === 'sql') return !!sqlResult?.columns.length;
    return true;
  }

  function toggleMenu(event, name) {
    event.stopPropagation();
    openMenu = openMenu === name ? null : name;
  }

  onMount(() => {
    const stored = THEMES.findIndex(([, value]) => value === loadSetting(THEME_KEY));
    if (stored > 0) setTheme(stored);
    const stops = [
      listen('open-progress', ({ payload }) => {
        status = `Reading table ${payload.done + 1} of ${payload.total}: ${payload.item}`;
      }),
      listen('export-progress', ({ payload }) => {
        if (progress) progress = { ...progress, ...payload };
      }),
    ];
    // caminho da linha de comando ou de MDB2SQL_DB_PATH
    invoke('startup_path').then((path) => {
      if (path) {
        dbPath = path;
        openDatabase();
      }
    });
    return () => stops.forEach((stop) => stop.then((unlisten) => unlisten()));
  });

  // NIVEL BASICO: Abre o banco; caminho vazio usa MDB2SQL_DB_PATH ou data/sample.duckdb
  async function openDatabase(event) {
    event?.preventDefault();
    // "Copiar como caminho" do Windows cola o caminho entre aspas
    const path = dbPath.trim().replace(/^"(.*)"$/, '$1');
    busy = true;
    showStatus('Opening database...');
    try {
      const opened = await invoke('load_database', { dbPath: path });
      tables = opened.tables;
      openedPath = opened.path;
      source = opened.source;
      dbPath = opened.path;
      filter = '';
      sqlResult = null;
      saveSetting(LAST_DIR_KEY, dirOf(opened.path));
      showStatus(`${opened.path}: ${tables.length} tables`);
      selectedTable = '';
      hidden = new Set();
      filters = [];
      columns = [];
      rows = [];
      rowCount = 0;
      if (tables.length > 0) await openTable(tables[0]);
    } catch (err) {
      error = String(err);
      status = 'Could not open database';
    } finally {
      busy = false;
    }
  }

  // NIVEL BASICO: Seletor de arquivo nativo; o arquivo escolhido e aberto em seguida
  // NIVEL TECNICO: calls the dialog plugin command directly, no npm package for one call
  async function browse() {
    openMenu = null;
    try {
      const picked = await invoke('plugin:dialog|open', {
        options: {
          title: 'Open database',
          defaultPath: defaultSaveDir(openedPath, loadSetting(LAST_DIR_KEY)) || undefined,
          filters: [
            { name: 'Databases (DuckDB, SQLite, Access)', extensions: OPEN_EXTENSIONS },
            { name: 'All files', extensions: ['*'] },
          ],
        },
      });
      if (!picked) return; // cancelado
      dbPath = String(picked);
      await openDatabase();
    } catch (err) {
      showError(String(err));
    }
  }

  async function setTheme(index) {
    openMenu = null;
    try {
      await getCurrentWindow().setTheme(THEMES[index][1]);
      themeIndex = index;
      saveSetting(THEME_KEY, THEMES[index][1]);
    } catch (err) {
      showError(String(err));
    }
  }

  // NIVEL TECNICO: __SVELTE_VERSION__ is the bundled Svelte version, injected by vite.config.js
  async function showAbout() {
    openMenu = null;
    try {
      aboutInfo = await invoke('about', { svelteVersion: __SVELTE_VERSION__ });
      aboutDialog.showModal();
    } catch (err) {
      showError(String(err));
    }
  }

  // NIVEL BASICO: Abre um link do Sobre no navegador padrao
  // NIVEL TECNICO: the opener plugin only accepts the two About URLs (capabilities/default.json);
  // preventDefault keeps the webview itself from leaving the app
  function openLink(event, url) {
    event.preventDefault();
    invoke('plugin:opener|open_url', { url }).catch((err) => showError(String(err)));
  }

  // NIVEL BASICO: Busca schema, linhas e contagens da tabela em paralelo; os filtros vao na consulta
  async function openTable(tableName) {
    if (!tableName) return;
    if (tableName !== selectedTable) {
      search = '';
      hidden = new Set();
      filters = [];
    }
    selectedTable = tableName;
    busy = true;
    error = '';
    try {
      const asked = filters;
      const [schema, data, total, matching] = await Promise.all([
        invoke('get_table_schema', { tableName }),
        invoke('get_table_data', { tableName, limit, filters: asked }),
        invoke('get_row_count', { tableName, filters: [] }),
        asked.length ? invoke('get_row_count', { tableName, filters: asked }) : null,
      ]);
      // Ignora resposta atrasada se o usuario ja trocou de tabela ou de filtro
      if (tableName !== selectedTable || asked !== filters) return;
      columns = schema;
      rows = data;
      rowCount = total;
      matchCount = matching ?? total;
    } catch (err) {
      error = String(err);
    } finally {
      busy = false;
    }
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

  // acoes do menu de clique direito da grade da aba Data (cabecalho e celula)
  const gridActions = {
    hide: (name) => (hidden = toggleHidden(hidden, name)),
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
      showStatus(
        sqlResult.columns.length
          ? `Query returned ${sqlResult.rows.length.toLocaleString()}${sqlResult.truncated ? '+' : ''} rows`
          : 'Statement executed'
      );
    } catch (err) {
      showError(String(err));
    } finally {
      busy = false;
    }
  }

  // NIVEL BASICO: Pergunta onde salvar (pasta do arquivo aberto, senao a ultima usada) e exporta
  // fora da thread da interface, com barra de progresso e Cancelar
  async function startExport(scope, format, label) {
    openMenu = null;
    if (!canExport(scope)) return;
    const base = scope === 'database' ? stem(openedPath) : scope === 'table' ? selectedTable : 'query';
    const dir = defaultSaveDir(openedPath, loadSetting(LAST_DIR_KEY));
    try {
      const path = await invoke('plugin:dialog|save', {
        options: {
          title: `Export ${label.replace('...', '')}`,
          defaultPath: joinPath(dir, suggestedName(base, format, openedPath)),
          filters: [{ name: FILTERS[format], extensions: [format] }],
        },
      });
      if (!path) return; // cancelado
      saveSetting(LAST_DIR_KEY, dirOf(path));
      progress = { label: label.replace('...', ''), done: 0, total: 0, item: '' };
      progressDialog.showModal();
      showStatus(await invoke('export', { scope, format, path, table: selectedTable || null, sql: lastSql || null }));
    } catch (err) {
      showError(String(err));
    } finally {
      progress = null;
      progressDialog.close();
    }
  }
</script>

<div class="app">
  <div class="menubar" role="menubar" aria-label="Main menu">
    <div class="menu-root">
      <button type="button" role="menuitem" aria-haspopup="menu" aria-expanded={openMenu === 'file'} onclick={(e) => toggleMenu(e, 'file')}>File</button>
      {#if openMenu === 'file'}
        <!-- cada acao num lugar so: abrir e o Browse... ao lado do caminho, exportar e so este menu (ui.test.js conta) -->
        <div class="dropdown" role="menu" aria-label="File">
          <span class="group">Export</span>
          {#each EXPORTS as [label, scope, format]}
            <button type="button" role="menuitem" disabled={!canExport(scope)} onclick={() => startExport(scope, format, label)}>{label}</button>
          {/each}
        </div>
      {/if}
    </div>
    <div class="menu-root">
      <button type="button" role="menuitem" aria-haspopup="menu" aria-expanded={openMenu === 'settings'} onclick={(e) => toggleMenu(e, 'settings')}>Settings</button>
      {#if openMenu === 'settings'}
        <div class="dropdown" role="menu" aria-label="Settings">
          <span class="group">Theme</span>
          {#each THEMES as [name], i}
            <button type="button" role="menuitemradio" aria-checked={themeIndex === i} onclick={() => setTheme(i)}>
              <span class="check">{themeIndex === i ? '●' : ''}</span>{name}
            </button>
          {/each}
        </div>
      {/if}
    </div>
    <div class="menu-root">
      <button type="button" role="menuitem" aria-haspopup="menu" aria-expanded={openMenu === 'help'} onclick={(e) => toggleMenu(e, 'help')}>Help</button>
      {#if openMenu === 'help'}
        <div class="dropdown" role="menu" aria-label="Help">
          <button type="button" role="menuitem" onclick={showAbout}>About MDB2SQL</button>
        </div>
      {/if}
    </div>
  </div>

  <header>
    <h1>MDB2SQL</h1>
    <form onsubmit={openDatabase}>
      <label for="db-path">Database</label>
      <input
        id="db-path"
        type="text"
        bind:value={dbPath}
        placeholder=".duckdb, .db, .sqlite, .sqlite3, .mdb, .accdb"
        spellcheck="false"
        autocomplete="off"
      />
      <button type="button" class="secondary" onclick={browse} disabled={busy}>Browse...</button>
      <button type="submit" disabled={busy}>Open database</button>
    </form>
  </header>

  <dialog bind:this={aboutDialog} class="about" aria-labelledby="about-title">
    {#if aboutInfo}
      <h2 id="about-title">{aboutInfo.name} <span class="version">{aboutInfo.version}</span></h2>
      <p class="tagline">{aboutInfo.description}</p>
      <dl>
        {#each aboutInfo.rows as [label, value]}
          <dt>{label}</dt>
          <dd>{value}</dd>
        {/each}
        {#each aboutInfo.links as [label, url]}
          <dt>{label}</dt>
          <dd>
            <a href={url} title="Abrir no navegador" onclick={(e) => openLink(e, url)} onauxclick={(e) => e.preventDefault()}>{url}</a>
          </dd>
        {/each}
      </dl>
    {/if}
    <button type="button" onclick={() => aboutDialog.close()}>Close</button>
  </dialog>

  <!-- marcar/desmarcar vale na hora; da para trocar varias colunas e fechar. A grade de caixas tem quantas
       colunas couberem (1 a 6) pelo nome mais longo; so rola na vertical -->
  <dialog
    bind:this={columnsDialog}
    class="columns"
    aria-labelledby="columns-title"
    onclose={() => (columnSearch = '')}
    style="--cell: {columnCellWidth(columns)}"
  >
    <h2 id="columns-title">Colunas de {selectedTable}</h2>
    <input class="column-search" type="search" bind:value={columnSearch} aria-label="Procurar coluna" placeholder="Procurar coluna" />
    <div class="column-list" role="group" aria-label="Colunas visiveis">
      {#each listedColumns as col (col.name)}
        <label title="{col.name} ({col.type})">
          <input type="checkbox" checked={!hidden.has(col.name)} onchange={() => (hidden = toggleHidden(hidden, col.name))} />
          <span>{col.name}</span>
          <small>{col.type}</small>
        </label>
      {:else}
        <p class="none">Nenhuma coluna com esse nome</p>
      {/each}
    </div>
    <div class="actions">
      <button type="button" class="secondary" onclick={() => (hidden = new Set())}>Mostrar todas</button>
      <button type="button" class="secondary" onclick={() => (hidden = new Set(columns.map((c) => c.name)))}>Ocultar todas</button>
      <span>{shownColumns.length} de {columns.length} visiveis</span>
      <button type="button" class="close" onclick={() => columnsDialog.close()}>Fechar</button>
    </div>
  </dialog>

  <!-- Esc nao fecha: a exportacao para pelo botao Cancel -->
  <dialog bind:this={progressDialog} class="progress" aria-labelledby="progress-title" oncancel={(e) => e.preventDefault()}>
    {#if progress}
      <h2 id="progress-title">{progress.label}</h2>
      <progress max={progress.total || 1} value={progress.total ? progress.done : 0}></progress>
      <p>{progress.total ? `${progress.done} of ${progress.total}` : 'Starting'}{progress.item ? `: ${progress.item}` : ''}</p>
      <button type="button" class="secondary" onclick={() => invoke('cancel_export')}>Cancel</button>
    {/if}
  </dialog>

  <div class="workspace">
    <nav aria-label="Tables">
      <label for="table-filter">Tables ({visibleTables.length}/{tables.length})</label>
      <input
        id="table-filter"
        aria-label="Filter tables"
        type="search"
        bind:value={filter}
        placeholder="Filter tables"
        disabled={tables.length === 0}
      />
      <!-- NIVEL TECNICO: native listbox gives arrow keys and type-ahead for free -->
      <select
        size="2"
        aria-label="Table list"
        bind:value={selectedTable}
        onchange={() => openTable(selectedTable)}
        disabled={tables.length === 0}
      >
        {#each visibleTables as table (table)}
          <option value={table} title={table}>{table}</option>
        {/each}
      </select>
    </nav>

    <main aria-busy={busy}>
      <div class="tabs" role="tablist" aria-label="View">
        {#each [['data', 'Data'], ['schema', 'Schema'], ['sql', 'SQL']] as [id, name]}
          <button type="button" role="tab" aria-selected={tab === id} class:active={tab === id} onclick={() => (tab = id)}>{name}</button>
        {/each}
        <span class="spacer"></span>
        <label for="row-limit">Row limit</label>
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
            aria-label="SQL query"
            spellcheck="false"
            placeholder={'SELECT * FROM "' + (selectedTable || 'table') + '" LIMIT 10'}
            onkeydown={(e) => e.ctrlKey && e.key === 'Enter' && runSql()}
          ></textarea>
          <div class="table-bar">
            <button type="button" title="Ctrl+Enter" onclick={runSql} disabled={busy || !openedPath || !sql.trim()}>Run SQL</button>
            {#if sqlResult}
              <span>{sqlResult.rows.length.toLocaleString()}{sqlResult.truncated ? '+' : ''} rows, {sqlResult.columns.length} columns</span>
            {/if}
          </div>
        </div>
        {#if sqlResult?.columns.length}
          <Grid columns={sqlResult.columns} rows={sqlResult.rows} label="SQL result" emptyText="No rows" onstatus={showStatus} onerror={showError} />
        {/if}
      {:else if !selectedTable}
        <p class="empty">No table open</p>
      {:else if tab === 'schema'}
        <div class="table-bar"><h2>{selectedTable}</h2><span>{columns.length} columns</span></div>
        <Grid
          columns={[{ name: '#', type: '' }, { name: 'Column', type: '' }, { name: 'Type', type: '' }, { name: 'Null', type: '' }]}
          rows={columns.map((c, i) => ({ '#': i + 1, Column: c.name, Type: c.type, Null: c.null }))}
          label="Schema of {selectedTable}"
          onstatus={showStatus}
          onerror={showError}
        />
      {:else}
        <div class="table-bar">
          <h2>{selectedTable}</h2>
          <span>
            {#if search.trim()}
              {visibleRows.length.toLocaleString()} matches in {rows.length.toLocaleString()} loaded rows,
            {:else if filters.length}
              Showing {rows.length.toLocaleString()} of {matchCount.toLocaleString()} filtered rows
              ({rowCount.toLocaleString()} in the table),
            {:else}
              Showing {rows.length.toLocaleString()} of {rowCount.toLocaleString()} rows,
            {/if}
            {columns.length} columns
          </span>
          <button
            type="button"
            class="secondary columns-button"
            title="A exportacao leva todas as colunas"
            onclick={() => columnsDialog.showModal()}>Colunas...</button
          >
          <input
            class="search"
            type="search"
            bind:value={search}
            aria-label="Search rows"
            placeholder="Search loaded rows"
          />
        </div>
        {#if filters.length}
          <div class="filters" role="group" aria-label="Filtros ativos">
            <span>Filtro:</span>
            {#each filters as f (f.column)}
              <span class="chip">
                {filterLabel(f)}
                <button
                  type="button"
                  aria-label="Remover filtro {filterLabel(f)}"
                  title="Remover este filtro"
                  onclick={() => setFilters(filters.filter((other) => other !== f))}>×</button
                >
              </span>
            {/each}
            <button type="button" class="secondary" onclick={() => setFilters([])}>Limpar filtros</button>
          </div>
        {/if}
        <Grid
          columns={shownColumns}
          rows={shownColumns.length ? visibleRows : []}
          label="Rows of {selectedTable}"
          emptyText={!shownColumns.length
            ? 'Todas as colunas ocultas'
            : filters.length && !rows.length
              ? 'Nenhuma linha com este filtro'
              : rows.length
                ? 'No loaded row matches the search'
                : 'Table is empty'}
          onstatus={showStatus}
          onerror={showError}
          actions={{ ...gridActions, anyHidden: hidden.size > 0, filtered: filters.length > 0 }}
        />
      {/if}
    </main>
  </div>

  <footer class="statusbar" class:error role="status" aria-live="polite">
    <span class="message">{error || status}</span>
    {#if hidden.size}<span class="source">{hiddenStatus(hidden.size)}</span>{/if}
    {#if source}<span class="source" title="How the file was read">Opened via {source}</span>{/if}
    <span class="stack">Rust + Tauri v2 + Svelte</span>
  </footer>
</div>

<svelte:window onclick={() => (openMenu = null)} onkeydown={(e) => e.key === 'Escape' && (openMenu = null)} />

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
    font: 13px/1.4 'Segoe UI', system-ui, -apple-system, 'Roboto', sans-serif;
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

  .column-list label span {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
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

  nav select {
    flex: 1;
    min-height: 0;
    padding: 4px;
  }

  nav option {
    padding: 4px 6px;
    border-radius: 4px;
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

  /* a busca encolhe antes de empurrar o botao ou quebrar a barra */
  .table-bar .search {
    flex: 0 1 400px;
    min-width: 140px;
    padding: 3px 8px;
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

  .statusbar .message {
    flex: 1;
    overflow-wrap: anywhere;
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
