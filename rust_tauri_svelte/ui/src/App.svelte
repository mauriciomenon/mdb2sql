<script>
  // NIVEL BASICO: Visualizador e conversor de bancos (DuckDB, SQLite, Access)
  // Menus: File (abrir, exportar), Settings (tema), Help (sobre). Abas: Data, Schema, SQL.
  // NIVEL TECNICO: Svelte 5 runes; every backend call goes through Tauri invoke()

  import { invoke } from '@tauri-apps/api/core';
  import { listen } from '@tauri-apps/api/event';
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import { onMount } from 'svelte';
  import Grid from './Grid.svelte';
  import { rowMatches } from './grid.js';
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

  let openMenu = $state(null); // 'file' | 'settings' | 'help' | 'export'
  let tab = $state('data');
  let themeIndex = $state(0);
  let aboutDialog;
  let aboutLines = $state([]);
  let progressDialog;
  let progress = $state.raw(null); // { label, done, total, item } da exportacao em andamento

  let dbPath = $state('');
  let openedPath = $state('');
  let source = $state('');
  let tables = $state([]);
  let filter = $state('');
  let selectedTable = $state('');
  let columns = $state([]); // [{ name, type, null }] na ordem real da tabela
  let rows = $state([]);
  let rowCount = $state(0);
  let limit = $state(LIMITS[0]);
  let search = $state('');
  let busy = $state(false);
  let status = $state('No database open');
  let error = $state('');

  let sql = $state('');
  let sqlResult = $state.raw(null); // { columns, rows, truncated }
  let lastSql = ''; // SQL que gerou sqlResult (o que a exportacao repete)

  let visibleTables = $derived(
    tables.filter((t) => t.toLowerCase().includes(filter.trim().toLowerCase()))
  );
  let visibleRows = $derived(rows.filter((row) => rowMatches(row, search)));

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
      aboutLines = await invoke('about', { svelteVersion: __SVELTE_VERSION__ });
      aboutDialog.showModal();
    } catch (err) {
      showError(String(err));
    }
  }

  // NIVEL BASICO: Busca schema, linhas e contagem da tabela em paralelo
  async function openTable(tableName) {
    if (!tableName) return;
    if (tableName !== selectedTable) search = '';
    selectedTable = tableName;
    busy = true;
    error = '';
    try {
      const [schema, data, count] = await Promise.all([
        invoke('get_table_schema', { tableName }),
        invoke('get_table_data', { tableName, limit }),
        invoke('get_row_count', { tableName }),
      ]);
      // Ignora resposta atrasada se o usuario ja trocou de tabela
      if (tableName !== selectedTable) return;
      columns = schema;
      rows = data;
      rowCount = count;
    } catch (err) {
      error = String(err);
    } finally {
      busy = false;
    }
  }

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
          ? `Query returned ${sqlResult.rows.length.toLocaleString()}${sqlResult.truncated ? '+ (Row limit; export gets all)' : ''} rows`
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
        <div class="dropdown" role="menu" aria-label="File">
          <button type="button" role="menuitem" onclick={browse} disabled={busy}>Open...</button>
          <div class="separator" role="separator"></div>
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
        placeholder="Path to a .duckdb, .db, .sqlite, .sqlite3, .mdb or .accdb file"
        spellcheck="false"
        autocomplete="off"
      />
      <button type="button" class="secondary" onclick={browse} disabled={busy}>Browse...</button>
      <button type="submit" disabled={busy}>Open database</button>
    </form>
    <div class="menu-root">
      <button type="button" class="secondary" aria-haspopup="menu" aria-expanded={openMenu === 'export'} disabled={!canExport('database')} onclick={(e) => toggleMenu(e, 'export')}>Export...</button>
      {#if openMenu === 'export'}
        <div class="dropdown right" role="menu" aria-label="Export">
          {#each EXPORTS as [label, scope, format]}
            <button type="button" role="menuitem" disabled={!canExport(scope)} onclick={() => startExport(scope, format, label)}>{label}</button>
          {/each}
        </div>
      {/if}
    </div>
  </header>

  <dialog bind:this={aboutDialog} aria-labelledby="about-title">
    {#each aboutLines as line, i}
      {#if i === 0}
        <h2 id="about-title">{line}</h2>
      {:else}
        <p>{line}</p>
      {/if}
    {/each}
    <button type="button" onclick={() => aboutDialog.close()}>Close</button>
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
          <option value={table}>{table}</option>
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
            aria-label="SQL"
            spellcheck="false"
            placeholder={'SELECT * FROM "' + (selectedTable || 'table') + '" LIMIT 10   (Ctrl+Enter runs)'}
            onkeydown={(e) => e.ctrlKey && e.key === 'Enter' && runSql()}
          ></textarea>
          <div class="table-bar">
            <button type="button" onclick={runSql} disabled={busy || !openedPath || !sql.trim()}>Run SQL</button>
            {#if sqlResult}
              <span>{sqlResult.rows.length.toLocaleString()}{sqlResult.truncated ? '+' : ''} rows, {sqlResult.columns.length} columns</span>
            {/if}
          </div>
        </div>
        {#if sqlResult?.columns.length}
          <Grid columns={sqlResult.columns} rows={sqlResult.rows} label="SQL result" emptyText="No rows" onstatus={showStatus} onerror={showError} />
        {/if}
      {:else if !selectedTable}
        <p class="empty">Open a database (.duckdb, .sqlite, .mdb, .accdb) to browse its tables.</p>
      {:else if tab === 'schema'}
        <div class="table-bar"><h2>{selectedTable}</h2><span>{columns.length} columns</span></div>
        <Grid
          columns={[{ name: '#', type: 'INTEGER' }, { name: 'Column', type: '' }, { name: 'Type', type: '' }, { name: 'Null', type: '' }]}
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
            {:else}
              Showing {rows.length.toLocaleString()} of {rowCount.toLocaleString()} rows,
            {/if}
            {columns.length} columns
          </span>
          <input
            class="search"
            type="search"
            bind:value={search}
            aria-label="Search rows"
            placeholder="Search loaded rows (all columns)"
          />
        </div>
        <Grid
          {columns}
          rows={visibleRows}
          label="Rows of {selectedTable}"
          emptyText={rows.length ? 'No loaded row matches the search' : 'Table is empty'}
          onstatus={showStatus}
          onerror={showError}
        />
      {/if}
    </main>
  </div>

  <footer class="statusbar" class:error role="status" aria-live="polite">
    <span class="message">{error || status}</span>
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

  .dropdown.right {
    left: auto;
    right: 0;
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
    font-size: 12px;
    font-weight: 600;
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
    gap: 20px;
  }

  h1 {
    margin: 0;
    font-size: 18px;
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
    font-size: 12px;
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
    font-size: 13px;
  }

  h2 {
    margin: 0;
    color: var(--text);
    font-size: 16px;
    font-weight: 600;
  }

  .table-bar .search {
    margin-left: auto;
    width: 240px;
    padding: 3px 8px;
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
    font-size: 13px;
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
    font-size: 12px;
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
