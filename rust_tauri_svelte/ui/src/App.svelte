<script>
  // NIVEL BASICO: Svelte reactive script
  // Variaveis aqui sao automaticamente observadas e re-renderizam UI quando mudam

  import { invoke } from '@tauri-apps/api/tauri';

  let name = '';
  let greetMsg = '';

  // NIVEL BASICO: Funcao async chama comando Rust
  // invoke() faz IPC (Inter-Process Communication) Rust <-> JavaScript
  async function greet() {
    greetMsg = await invoke('greet', { name });
  }

  // NIVEL TECNICO: Reactive statement, executa quando name muda
  // $: console.log('name changed to:', name);
</script>

<!-- NIVEL BASICO: Template Svelte, similar a HTML mas com superpoderes -->
<!-- bind:value faz two-way binding (input altera variavel e vice-versa) -->
<main>
  <h1>MDB2SQL</h1>

  <div class="row">
    <input
      type="text"
      bind:value={name}
      placeholder="Enter your name"
    />
    <button on:click={greet}>Greet</button>
  </div>

  {#if greetMsg}
    <p>{greetMsg}</p>
  {/if}
</main>

<style>
  /* NIVEL BASICO: CSS scoped para este componente apenas */
  /* Svelte adiciona hash unico para evitar conflitos globais */

  main {
    text-align: center;
    padding: 2rem;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  }

  .row {
    display: flex;
    gap: 0.5rem;
    justify-content: center;
    margin: 1rem 0;
  }

  input {
    padding: 0.5rem;
    border: 1px solid #ccc;
    border-radius: 4px;
  }

  button {
    padding: 0.5rem 1rem;
    background: #0066cc;
    color: white;
    border: none;
    border-radius: 4px;
    cursor: pointer;
  }

  button:hover {
    background: #0052a3;
  }

  p {
    margin-top: 1rem;
    font-weight: bold;
    color: #0066cc;
  }

  /* NIVEL TECNICO: Preparing for future theme support */
  :global(body) {
    margin: 0;
    background: #ffffff;
    color: #000000;
  }
</style>
