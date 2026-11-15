<script>
  // NIVEL BASICO: Visualizador de tabelas DuckDB (abre banco, lista tabelas, mostra linhas)
  // NIVEL TECNICO: Svelte 5 runes; every backend call goes through Tauri invoke()

  import { invoke } from '@tauri-apps/api/core';

  const LIMITS = [100, 500, 1000];

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

  const isNumeric = (type) => /INT|DOUBLE|FLOAT|DECIMAL|REAL|NUMERIC/i.test(type);

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

  // NIVEL BASICO: Busca schema, linhas e contagem da tabela em paralelo
  async function openTable(tableName) {
    if (!tableName) return;
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
      <button type="submit" disabled={busy}>Open database</button>
    </form>
  </header>

  <p class="status" class:error role="status" aria-live="polite">
    {error || status}
  </p>

  <div class="workspace">
    <nav aria-label="Tables">
      <label for="table-filter">Tables ({visibleTables.length}/{tables.length})</label>
      <input
        id="table-filter"
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
            Showing {rows.length.toLocaleString()} of {rowCount.toLocaleString()} rows,
            {columns.length} columns
          </span>
          <label for="row-limit">Row limit</label>
          <select id="row-limit" bind:value={limit} onchange={() => openTable(selectedTable)}>
            {#each LIMITS as option}
              <option value={option}>{option}</option>
            {/each}
          </select>
        </div>

        <!-- tabindex: a area rolavel precisa de foco para rolar pelo teclado -->
        <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
        <div class="grid" tabindex="0" role="region" aria-label="Rows of {selectedTable}">
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
              {#each rows as row}
                <tr>
                  {#each columns as col (col.name)}
                    {@const value = row[col.name]}
                    {#if value === null || value === undefined}
                      <td class="null">NULL</td>
                    {:else}
                      <td class:num={isNumeric(col.type)} title={String(value)}>{value}</td>
                    {/if}
                  {/each}
                </tr>
              {:else}
                <tr><td class="null" colspan={Math.max(columns.length, 1)}>Table is empty</td></tr>
              {/each}
            </tbody>
          </table>
        </div>
      {:else}
        <p class="empty">Open a DuckDB database to browse its tables.</p>
      {/if}
    </main>
  </div>

  <footer>Rust + Tauri v2 + Svelte</footer>
</div>

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

  .table-bar label {
    margin-left: auto;
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
