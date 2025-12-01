<script>
  // NIVEL BASICO: Svelte reactive script para table viewer
  // Variaveis aqui sao automaticamente observadas e re-renderizam UI quando mudam

  import { invoke } from '@tauri-apps/api/core';

  // NIVEL BASICO: Estado da aplicacao (reactive variables)
  let tables = [];
  let selectedTable = '';
  let tableData = [];
  let rowCount = 0;
  let status = 'No database loaded';
  let error = '';

  // NIVEL BASICO: Carrega banco de dados e lista tabelas
  async function loadDatabase() {
    try {
      error = '';
      status = 'Loading...';

      // NIVEL BASICO: invoke() chama comando Rust load_database
      // NIVEL TECNICO: Tauri IPC automatically serializes/deserializes JSON
      tables = await invoke('load_database', { dbPath: '' });

      status = `Loaded: sample.duckdb (${tables.length} tables)`;

      // NIVEL BASICO: Carrega primeira tabela automaticamente
      if (tables.length > 0) {
        await loadTable(tables[0]);
      }
    } catch (err) {
      error = err;
      status = 'Error loading database';
    }
  }

  // NIVEL BASICO: Carrega dados de uma tabela especifica
  async function loadTable(tableName) {
    try {
      error = '';
      selectedTable = tableName;

      // NIVEL BASICO: Busca dados e contagem em paralelo
      // NIVEL TECNICO: Promise.all for concurrent Tauri commands
      const [data, count] = await Promise.all([
        invoke('get_table_data', { tableName, limit: 100 }),
        invoke('get_row_count', { tableName }),
      ]);

      tableData = data;
      rowCount = count;
    } catch (err) {
      error = err;
    }
  }

  // NIVEL BASICO: Reactive statement - pega colunas do primeiro row
  // NIVEL TECNICO: Svelte $ syntax runs when dependencies change
  $: columns = tableData.length > 0 ? Object.keys(tableData[0]) : [];
</script>

<!-- NIVEL BASICO: Template Svelte para table viewer -->
<div class="container">
  <h1>MDB2SQL - Feature 1: Load and Display Table</h1>

  <!-- NIVEL BASICO: Controles -->
  <div class="controls">
    <label for="table-select">Table:</label>
    <select
      id="table-select"
      bind:value={selectedTable}
      on:change={() => loadTable(selectedTable)}
      disabled={tables.length === 0}
    >
      {#each tables as table}
        <option value={table}>{table}</option>
      {/each}
    </select>

    <button on:click={loadDatabase}>Load Database</button>

    <span class="status" class:success={!error} class:error={error}>
      {error || status}
    </span>
  </div>

  <!-- NIVEL BASICO: Tabela de dados -->
  {#if tableData.length > 0}
    <div class="table-container">
      <table>
        <thead>
          <tr>
            {#each columns as col}
              <th>{col}</th>
            {/each}
          </tr>
        </thead>
        <tbody>
          {#each tableData as row, idx}
            <!-- NIVEL BASICO: Key unica para evitar re-render incorreto -->
            <!-- NIVEL TECNICO: Prefer stable unique field over index -->
            <tr key={row.UNIQID || row.id || `${selectedTable}_${idx}`}>
              {#each columns as col}
                <td>{row[col] ?? ''}</td>
              {/each}
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}

  <!-- NIVEL BASICO: Info rodape -->
  {#if selectedTable}
    <div class="info">
      {selectedTable}: Showing {tableData.length} of {rowCount} rows
    </div>
  {/if}
</div>

<style>
  /* NIVEL BASICO: CSS scoped para table viewer */
  /* Svelte adiciona hash unico para evitar conflitos globais */

  .container {
    max-width: 1400px;
    margin: 20px auto;
    padding: 20px;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Roboto', sans-serif;
  }

  h1 {
    text-align: center;
    color: #333;
    margin-bottom: 20px;
    font-size: 24px;
  }

  /* NIVEL BASICO: Area de controles (select, button, status) */
  .controls {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 20px;
    padding: 15px;
    background-color: #f5f5f5;
    border-radius: 4px;
  }

  .controls label {
    font-weight: 600;
    color: #555;
  }

  .controls select {
    min-width: 250px;
    padding: 8px 12px;
    border: 1px solid #ccc;
    border-radius: 4px;
    font-size: 14px;
    background-color: white;
    cursor: pointer;
  }

  .controls select:disabled {
    background-color: #e9ecef;
    cursor: not-allowed;
  }

  .controls button {
    padding: 8px 16px;
    background-color: #007bff;
    color: white;
    border: none;
    border-radius: 4px;
    font-size: 14px;
    font-weight: 600;
    cursor: pointer;
    transition: background-color 0.2s;
  }

  .controls button:hover {
    background-color: #0056b3;
  }

  .controls .status {
    margin-left: auto;
    padding: 6px 12px;
    border-radius: 4px;
    font-size: 13px;
    font-weight: 500;
  }

  .controls .status.success {
    color: #155724;
    background-color: #d4edda;
  }

  .controls .status.error {
    color: #721c24;
    background-color: #f8d7da;
  }

  /* NIVEL BASICO: Container da tabela com scroll */
  .table-container {
    overflow: auto;
    max-height: 600px;
    border: 1px solid #ddd;
    border-radius: 4px;
    margin-bottom: 15px;
  }

  /* NIVEL BASICO: Estilos da tabela de dados */
  table {
    width: 100%;
    border-collapse: collapse;
    background-color: white;
  }

  thead {
    position: sticky;
    top: 0;
    background-color: #343a40;
    color: white;
    z-index: 10;
  }

  thead th {
    padding: 12px 8px;
    text-align: left;
    font-weight: 600;
    font-size: 13px;
    border-bottom: 2px solid #dee2e6;
  }

  tbody tr {
    border-bottom: 1px solid #dee2e6;
  }

  tbody tr:hover {
    background-color: #f8f9fa;
  }

  tbody td {
    padding: 10px 8px;
    font-size: 13px;
    color: #333;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 300px;
  }

  /* NIVEL BASICO: Rodape com info de linhas */
  .info {
    text-align: center;
    padding: 10px;
    background-color: #f8f9fa;
    border-radius: 4px;
    font-size: 13px;
    color: #555;
    font-weight: 500;
  }

  /* NIVEL TECNICO: Global body styles for future theme support */
  :global(body) {
    margin: 0;
    background: #ffffff;
    color: #000000;
  }
</style>
