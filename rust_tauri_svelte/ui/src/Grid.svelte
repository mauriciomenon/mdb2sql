<script>
  // NIVEL BASICO: Grade de dados (tabela aberta ou resultado do SQL) com menu de copia
  // Clique seleciona a celula; botao direito ou tecla de menu abre o menu; Ctrl+C copia o valor
  import { cellText, rowToTsv } from './grid.js';

  // actions (so a grade da aba Data): { hide(nome), columns(), showAll(), filter(nome, valor), clearFilters(),
  // anyHidden, filtered }; sem ele o menu so copia
  let { columns, rows, label, emptyText = 'Table is empty', onstatus, onerror, actions = null } = $props();

  let selected = $state.raw(null); // { row, col }: celula escolhida para copiar
  let menu = $state.raw(null); // { x, y, header }: menu aberto; header = nome da coluna do cabecalho clicado

  // outra tabela, outra busca ou outro resultado: a celula escolhida antes nao vale mais (copiaria dado velho)
  $effect(() => {
    rows;
    selected = null;
    menu = null;
  });

  const isNumeric = (type) => /INT|DOUBLE|FLOAT|DECIMAL|REAL|NUMERIC/i.test(type);
  const focusNow = (node) => node.focus();
  // menu aberto perto da borda: puxa para dentro da janela (senao os ultimos itens ficam cortados)
  const keepInside = (node) => {
    const box = node.getBoundingClientRect();
    node.style.left = `${Math.max(4, Math.min(box.left, innerWidth - box.width - 4))}px`;
    node.style.top = `${Math.max(4, Math.min(box.top, innerHeight - box.height - 4))}px`;
  };

  // NIVEL BASICO: Celula sob o clique (td tem o indice da coluna, tr o da linha)
  function selectCell(event) {
    const td = event.target.closest('td[data-c]');
    if (td) selected = { row: rows[td.parentElement.dataset.r], col: columns[td.dataset.c].name };
  }

  function openMenu(event) {
    event.preventDefault();
    // a tecla de menu do teclado nao tem posicao de mouse: abre no canto da grade
    const box = event.currentTarget.getBoundingClientRect();
    const at = { x: event.clientX || box.left + 40, y: event.clientY || box.top + 40 };
    // clique direito no cabecalho: menu de colunas (ocultar esta, Colunas..., mostrar todas)
    const th = actions && event.target.closest('th[data-c]');
    if (th) {
      menu = { ...at, header: columns[th.dataset.c].name };
      return;
    }
    selectCell(event);
    if (selected) menu = { ...at, header: null };
  }

  // fecha o menu e chama a acao da aba Data
  function act(name, ...args) {
    menu = null;
    actions[name](...args);
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
      onstatus(
        kind === 'value'
          ? `Copied value of ${selected.col}`
          : `Copied row (${names.length} columns${kind === 'row-header' ? ', with header' : ''})`
      );
    } catch (err) {
      onerror(`Copy failed: ${err}`);
    }
  }

  function gridKey(event) {
    // com texto selecionado pelo mouse vale o Ctrl+C normal do navegador
    if (event.ctrlKey && event.key.toLowerCase() === 'c' && selected && !String(getSelection())) {
      event.preventDefault();
      copy('value');
    }
  }
</script>

<!-- tabindex: a area rolavel precisa de foco para rolar pelo teclado -->
<!-- svelte-ignore a11y_no_noninteractive_tabindex, a11y_no_noninteractive_element_interactions, a11y_click_events_have_key_events -->
<div
  class="grid"
  tabindex="0"
  role="region"
  aria-label={label}
  onclick={selectCell}
  oncontextmenu={openMenu}
  onkeydown={gridKey}
>
  <table>
    <thead>
      <tr>
        {#each columns as col, c (c)}
          <th scope="col" data-c={c} class:num={isNumeric(col.type)}>
            {col.name}
            <small>{col.type}</small>
          </th>
        {/each}
      </tr>
    </thead>
    <tbody>
      {#each rows as row, r}
        <tr data-r={r}>
          {#each columns as col, c (c)}
            {@const value = row[col.name]}
            {@const isSelected = selected?.row === row && selected.col === col.name}
            {#if value === null || value === undefined}
              <td data-c={c} class="null" class:selected={isSelected}>NULL</td>
            {:else}
              <td data-c={c} class:num={isNumeric(col.type)} class:selected={isSelected}>{value}</td>
            {/if}
          {/each}
        </tr>
      {:else}
        <tr>
          <td class="null" colspan={Math.max(columns.length, 1)}>{emptyText}</td>
        </tr>
      {/each}
    </tbody>
  </table>
</div>

{#if menu?.header}
  <div class="menu" role="menu" aria-label="Coluna {menu.header}" style="left: {menu.x}px; top: {menu.y}px" use:keepInside>
    <button type="button" role="menuitem" use:focusNow onclick={() => act('hide', menu.header)}>Ocultar esta coluna</button>
    <button type="button" role="menuitem" onclick={() => act('columns')}>Colunas...</button>
    <button type="button" role="menuitem" disabled={!actions.anyHidden} onclick={() => act('showAll')}>Mostrar todas</button>
  </div>
{:else if menu}
  <div class="menu" role="menu" aria-label="Cell" style="left: {menu.x}px; top: {menu.y}px" use:keepInside>
    <button type="button" role="menuitem" use:focusNow onclick={() => copy('value')}>
      Copy value <kbd>Ctrl+C</kbd>
    </button>
    <button type="button" role="menuitem" onclick={() => copy('row')}>Copy row</button>
    <button type="button" role="menuitem" onclick={() => copy('row-header')}>Copy row with header</button>
    {#if actions}
      <div class="separator" role="separator"></div>
      <button type="button" role="menuitem" onclick={() => act('filter', selected.col, selected.row[selected.col])}>
        Filtrar por este valor
      </button>
      <button type="button" role="menuitem" disabled={!actions.filtered} onclick={() => act('clearFilters')}>Limpar filtros</button>
    {/if}
  </div>
{/if}

<svelte:window
  onclick={() => (menu = null)}
  onkeydown={(event) => event.key === 'Escape' && (menu = null)}
/>

<style>
  .grid {
    flex: 1;
    min-height: 0;
    overflow: auto;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 6px;
  }

  .grid:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 1px;
  }

  table {
    border-collapse: separate;
    border-spacing: 0;
    font-size: 12px;
    font-variant-numeric: tabular-nums;
  }

  /* z-index: o cabecalho fixo fica sempre por cima das celulas que rolam por baixo dele */
  th {
    position: sticky;
    top: 0;
    z-index: 1;
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
    font-size: 11px;
    font-weight: 500;
    letter-spacing: 0.04em;
  }

  /* sem largura maxima: a coluna cresce ate caber o valor inteiro (nenhum campo cortado) */
  td {
    padding: 4px 10px;
    border-bottom: 1px solid var(--border);
    white-space: nowrap;
  }

  tbody tr:nth-child(even) {
    background: var(--row-alt);
  }

  tbody tr:hover {
    background: var(--row-hover);
  }

  td.selected {
    outline: 2px solid var(--accent);
    outline-offset: -2px;
    background: var(--row-hover);
  }

  .num {
    text-align: right;
  }

  /* NULL so em italico, com a mesma cor e contraste das outras celulas: com cor apagada e opacity as colunas
     quase so de NULL (as depois de PNTNAM no RANGER_SOSTAT) pareciam transparentes */
  .null {
    font-style: italic;
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
    font: inherit;
    padding: 6px 10px;
    border-radius: 6px;
    background: none;
    border: 1px solid transparent;
    color: var(--text);
    text-align: left;
    cursor: pointer;
  }

  .menu button:hover:not(:disabled),
  .menu button:focus-visible {
    background: var(--row-hover);
  }

  .menu button:disabled {
    opacity: 0.55;
    cursor: not-allowed;
  }

  .menu .separator {
    margin: 4px 0;
    border-top: 1px solid var(--border);
  }

  .menu kbd {
    color: var(--muted);
    font: inherit;
    font-size: 11px;
  }
</style>
