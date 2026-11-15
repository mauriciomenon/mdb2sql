<script>
  // NIVEL BASICO: Visualizador de tabelas DuckDB (abre banco, lista tabelas, mostra linhas)
  // NIVEL TECNICO: Svelte 5 runes; every backend call goes through Tauri invoke()

  import { invoke } from '@tauri-apps/api/core';
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import { cellText, rowMatches, rowToTsv } from './grid.js';

  const LIMITS = [100, 500, 1000];
  // null devolve a janela (barra de titulo e webview) ao tema do sistema
  const THEMES = [
    ['System', null],
    ['Light', 'light'],
    ['Dark', 'dark'],
  ];

  let search = $state('');
  let selected = $state.raw(null); // { row, col }: celula escolhida para copiar
  let menu = $state.raw(null); // { x, y } do menu de copia aberto
  let themeIndex = $state(0);
  let aboutDialog;
  let aboutLines = $state([]);

  let dbPath = $state('');
  let tables = $state([]);
  let filter = $state('');
  let selectedTable = $state('');
  let columns = $state([]); // [{ name, type, null }] na ordem real da tabela
  let rows = $state([]);
  let rowCount = $state(0);
  let limit = $state(LIMITS[0]);
  let busy = $state(false);
  let status = $state('No database open');
  let error = $state('');

  let visibleTables = $derived(
    tables.filter((t) => t.toLowerCase().includes(filter.trim().toLowerCase()))
  );

  let visibleRows = $derived(rows.filter((row) => rowMatches(row, search)));

  // NIVEL BASICO: Celula sob o clique (td tem o indice da coluna, tr o da linha visivel)
  function selectCell(event) {
    const td = event.target.closest('td[data-c]');
    if (td) selected = { row: visibleRows[td.parentElement.dataset.r], col: columns[td.dataset.c].name };
  }

  function openMenu(event) {
    event.preventDefault();
    selectCell(event);
    if (!selected) return;
    // a tecla de menu do teclado nao tem posicao de mouse: abre no canto da grade
    const box = event.currentTarget.getBoundingClientRect();
    menu = { x: event.clientX || box.left + 40, y: event.clientY || box.top + 40 };
  }

  // NIVEL BASICO: kind = 'value' (celula), 'row' ou 'row-header' (linha separada por TAB)
  async function copy(kind) {
    menu = null;
    if (!selected) return;
    const names = columns.map((col) => col.name);
    const text =
      kind === 'value'
        ? cellText(selected.row[selected.col])
        : rowToTsv(names, selected.row, kind === 'row-header');
    try {
      await navigator.clipboard.writeText(text);
      error = '';
      status =
        kind === 'value'
          ? `Copied value of ${selected.col}`
          : `Copied row (${names.length} columns${kind === 'row-header' ? ', with header' : ''})`;
    } catch (err) {
      error = `Copy failed: ${err}`;
    }
  }

  function gridKey(event) {
    // com texto selecionado pelo mouse vale o Ctrl+C normal do navegador
    if (event.ctrlKey && event.key.toLowerCase() === 'c' && selected && !String(getSelection())) {
      event.preventDefault();
      copy('value');
    }
  }

  const focusNow = (node) => node.focus();

  const isNumeric =(type) => /INT|DOUBLE|FLOAT|DECIMAL|REAL|NUMERIC/i.test(type);

  // NIVEL BASICO: Abre o banco; caminho vazio usa MDB2SQL_DB_PATH ou data/sample.duckdb
  async function openDatabase(event) {
    event?.preventDefault();
    // "Copiar como caminho" do Windows cola o caminho entre aspas
    const path = dbPath.trim().replace(/^"(.*)"$/, '$1');
    busy = true;
    error = '';
    status = 'Opening database...';
    try {
      tables = await invoke('load_database', { dbPath: path });
      filter = '';
      status = `${path || 'Default database'}: ${tables.length} tables`;
      if (tables.length > 0) {
        await openTable(tables[0]);
      } else {
        selectedTable = '';
        columns = [];
        rows = [];
        rowCount = 0;
      }
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
    try {
      const picked = await invoke('plugin:dialog|open', {
        options: {
          title: 'Open DuckDB database',
          filters: [{ name: 'DuckDB database', extensions: ['duckdb', 'db'] }],
        },
      });
      if (!picked) return; // cancelado
      dbPath = String(picked);
      await openDatabase();
    } catch (err) {
      error = String(err);
    }
  }

  async function cycleTheme() {
    const next = (themeIndex + 1) % THEMES.length;
    try {
      await getCurrentWindow().setTheme(THEMES[next][1]);
      themeIndex = next;
    } catch (err) {
      error = String(err);
    }
  }

  // NIVEL TECNICO: __SVELTE_VERSION__ is the bundled Svelte version, injected by vite.config.js
  async function showAbout() {
    try {
      const svelteVersion = __SVELTE_VERSION__;
      aboutLines = await invoke('about', { svelteVersion });
      aboutDialog.showModal();
    } catch (err) {
      error = String(err);
    }
  }

  // NIVEL BASICO: Busca schema, linhas e contagem da tabela em paralelo
  async function openTable(tableName) {
    if (!tableName) return;
    if (tableName !== selectedTable) search = '';
    selected = null;
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
</script>

<div class="app">
  <header>
    <h1>MDB2SQL</h1>
    <form onsubmit={openDatabase}>
      <label for="db-path">Database</label>
      <input
        id="db-path"
        type="text"
        bind:value={dbPath}
        placeholder="Path to a .duckdb file (empty: MDB2SQL_DB_PATH or data/sample.duckdb)"
        spellcheck="false"
        autocomplete="off"
      />
      <button type="button" class="secondary" onclick={browse} disabled={busy}>Browse...</button>
      <button type="submit" disabled={busy}>Open database</button>
    </form>
    <button type="button" class="secondary" onclick={cycleTheme}>
      Theme: {THEMES[themeIndex][0]}
    </button>
    <button type="button" class="secondary" onclick={showAbout}>About</button>
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

  <p class="status" class:error role="status" aria-live="polite">
    {error || status}
  </p>

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
      {#if selectedTable}
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
          <label for="row-limit">Row limit</label>
          <select id="row-limit" bind:value={limit} onchange={() => openTable(selectedTable)}>
            {#each LIMITS as option}
              <option value={option}>{option}</option>
            {/each}
          </select>
        </div>

        <!-- tabindex: a area rolavel precisa de foco para rolar pelo teclado -->
        <!-- clique seleciona a celula; botao direito ou tecla de menu abre o menu de copia; Ctrl+C copia o valor -->
        <!-- svelte-ignore a11y_no_noninteractive_tabindex, a11y_no_noninteractive_element_interactions, a11y_click_events_have_key_events -->
        <div
          class="grid"
          tabindex="0"
          role="region"
          aria-label="Rows of {selectedTable}"
          onclick={selectCell}
          oncontextmenu={openMenu}
          onkeydown={gridKey}
        >
          <table>
            <thead>
              <tr>
                {#each columns as col (col.name)}
                  <th scope="col" class:num={isNumeric(col.type)}>
                    {col.name}
                    <small>{col.type}</small>
                  </th>
                {/each}
              </tr>
            </thead>
            <tbody>
              {#each visibleRows as row, r}
                <tr data-r={r}>
                  {#each columns as col, c (col.name)}
                    {@const value = row[col.name]}
                    {@const isSelected = selected?.row === row && selected.col === col.name}
                    {#if value === null || value === undefined}
                      <td data-c={c} class="null" class:selected={isSelected}>NULL</td>
                    {:else}
                      <td
                        data-c={c}
                        class:num={isNumeric(col.type)}
                        class:selected={isSelected}
                        title={String(value)}>{value}</td
                      >
                    {/if}
                  {/each}
                </tr>
              {:else}
                <tr>
                  <td class="null" colspan={Math.max(columns.length, 1)}>
                    {rows.length ? 'No loaded row matches the search' : 'Table is empty'}
                  </td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      {:else}
        <p class="empty">Open a DuckDB database to browse its tables.</p>
      {/if}
    </main>
  </div>

  {#if menu}
    <div class="menu" role="menu" aria-label="Copy" style="left: {menu.x}px; top: {menu.y}px">
      <button type="button" role="menuitem" use:focusNow onclick={() => copy('value')}>
        Copy value <kbd>Ctrl+C</kbd>
      </button>
      <button type="button" role="menuitem" onclick={() => copy('row')}>Copy row</button>
      <button type="button" role="menuitem" onclick={() => copy('row-header')}>
        Copy row with header
      </button>
    </div>
  {/if}

  <footer>Rust + Tauri v2 + Svelte</footer>
</div>

<svelte:window
  onclick={() => (menu = null)}
  onkeydown={(event) => event.key === 'Escape' && (menu = null)}
/>

<style>
  /* NIVEL BASICO: Cores em variaveis; tema claro/escuro segue o sistema operacional */
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
    padding: 12px 16px 6px;
    gap: 10px;
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
  button {
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
  }

  button {
    white-space: nowrap;
  }

  button.secondary {
    background: var(--surface);
    border-color: var(--border);
    color: var(--text);
  }

  dialog {
    max-width: 560px;
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

  button:disabled,
  select:disabled,
  input:disabled {
    opacity: 0.55;
    cursor: not-allowed;
  }

  :is(input, select, button, .grid):focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 1px;
  }

  .status {
    margin: 0;
    padding: 6px 10px;
    border-radius: 6px;
    background: var(--surface);
    border: 1px solid var(--border);
    color: var(--muted);
    font-size: 13px;
    overflow-wrap: anywhere;
  }

  .status.error {
    background: var(--error-bg);
    border-color: var(--error-text);
    color: var(--error-text);
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

  td.selected {
    outline: 2px solid var(--accent);
    outline-offset: -2px;
    background: var(--row-hover);
  }

  .menu {
    position: fixed;
    z-index: 10;
    display: flex;
    flex-direction: column;
    min-width: 200px;
    padding: 4px;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 6px;
    box-shadow: 0 6px 18px rgb(0 0 0 / 0.3);
  }

  .menu button {
    display: flex;
    justify-content: space-between;
    gap: 16px;
    background: none;
    border-color: transparent;
    color: var(--text);
    font-weight: 400;
    text-align: left;
  }

  .menu button:hover,
  .menu button:focus-visible {
    background: var(--row-hover);
  }

  .menu kbd {
    color: var(--muted);
    font: inherit;
    font-size: 12px;
  }

  .table-bar select {
    padding: 3px 6px;
  }

  .grid {
    flex: 1;
    min-height: 0;
    overflow: auto;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 6px;
  }

  table {
    border-collapse: separate;
    border-spacing: 0;
    font-size: 13px;
    font-variant-numeric: tabular-nums;
  }

  th {
    position: sticky;
    top: 0;
    background: var(--surface);
    border-bottom: 2px solid var(--border);
    padding: 6px 10px;
    text-align: left;
    font-weight: 600;
    white-space: nowrap;
  }

  th small {
    display: block;
    color: var(--muted);
    font-size: 10px;
    font-weight: 500;
    letter-spacing: 0.04em;
  }

  td {
    padding: 4px 10px;
    border-bottom: 1px solid var(--border);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 320px;
  }

  tbody tr:nth-child(even) {
    background: var(--row-alt);
  }

  tbody tr:hover {
    background: var(--row-hover);
  }

  .num {
    text-align: right;
  }

  .null {
    color: var(--muted);
    font-style: italic;
    opacity: 0.7;
  }

  .empty {
    margin: auto;
    color: var(--muted);
  }

  footer {
    color: var(--muted);
    font-size: 11px;
    text-align: right;
  }
</style>
