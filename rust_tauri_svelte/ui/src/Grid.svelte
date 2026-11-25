<script>
  // NIVEL BASICO: Grade de dados (tabela aberta, esquema ou resultado do SQL) com menu de copia e de colunas
  // Clique seleciona a celula; botao direito ou tecla de menu abre o menu; Ctrl+C copia o valor.
  // Cabecalho: arrastar a borda direita muda a largura; botao direito > Ajustar coluna / Ajustar todas as colunas
  import { cellText, rowToTsv } from './grid.js';

  // actions (so a grade da aba Data): { hide(nome), columns(), showAll(), filter(nome, valor), clearFilters(),
  // all (todas as colunas da tabela), hidden (Set das ocultas), filtered }; sem ele o menu so copia e ajusta colunas
  // t: traducao do idioma escolhido (i18n.js); nullText: texto da celula NULL na grade (Settings > Exibir NULL)
  let { columns, rows, label, emptyText, t, onstatus, onerror, actions = null, nullText = '' } = $props();

  let selected = $state.raw(null); // { row, col }: celula escolhida para copiar
  let menu = $state.raw(null); // { x, y, header }: menu aberto; header = nome da coluna do cabecalho clicado
  // largura (px) das colunas arrastadas pela borda do cabecalho; sem entrada, a coluna cabe o conteudo inteiro
  let widths = $state({});
  let last = $derived(columns.length === 1); // so uma coluna na tela: o menu nao deixa oculta-la

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

  // coluna arrastada: largura fixa e o que passa fica escondido (sem "..."); Ajustar coluna volta ao conteudo inteiro
  const sized = (name) => {
    const w = widths[name];
    return w ? `box-sizing: border-box; width: ${w}px; min-width: ${w}px; max-width: ${w}px; overflow: hidden` : undefined;
  };

  // a borda fica sob o ponteiro enquanto ele arrasta; 24 px no minimo
  function startResize(event, name) {
    event.preventDefault();
    const grip = event.currentTarget;
    const start = event.clientX - grip.parentElement.getBoundingClientRect().width;
    grip.setPointerCapture(event.pointerId);
    grip.onpointermove = (e) => (widths[name] = Math.max(24, Math.round(e.clientX - start)));
    grip.onlostpointercapture = () => (grip.onpointermove = null);
  }

  // Ajustar coluna (name) / Ajustar todas as colunas (null): a largura volta a caber cabecalho e valores
  function fit(name) {
    menu = null;
    if (name) delete widths[name];
    else widths = {};
  }

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
    // clique direito no cabecalho: menu de colunas (ajustar; na aba Data tambem ocultar e mostrar)
    const th = event.target.closest('th[data-c]');
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
      // chave + valores: o log da tela traduz de novo se o idioma mudar
      if (kind === 'value') onstatus('grid.copiedValue', { column: selected.col });
      else onstatus(kind === 'row-header' ? 'grid.copiedRowHeader' : 'grid.copiedRow', { count: names.length });
    } catch (err) {
      onerror(String(err), 'grid.copyFailed');
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
          <!-- coluna estreitada a mao: o nome inteiro fica na dica -->
          <th scope="col" data-c={c} class:num={isNumeric(col.type)} style={sized(col.name)} title={widths[col.name] ? col.name : undefined}>
            {col.name}
            <small>{col.type}</small>
            <!-- svelte-ignore a11y_no_static_element_interactions -->
            <span class="grip" aria-hidden="true" onpointerdown={(e) => startResize(e, col.name)}></span>
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
            <!-- como nas outras stacks: NULL mostra nullText ("NULL" ou vazio), DOUBLE inteiro sem ".0" (o JSON 2.0 chega
                 como 2); copiar continua com o valor real (NULL vazio) -->
            <td data-c={c} class:num={isNumeric(col.type)} class:selected={isSelected} style={sized(col.name)}>{cellText(value, nullText)}</td>
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
  <!-- como o menu do cabecalho do Dear ImGui (versao Zig): ajustar largura; na aba Data tambem ocultar/mostrar. A lista
       marca as colunas visiveis, o clique alterna e o menu fica aberto (varias de uma vez); a ultima visivel nao sai -->
  <div class="menu" role="menu" aria-label={t('grid.columnMenu', { name: menu.header })} style="left: {menu.x}px; top: {menu.y}px" use:keepInside>
    <button type="button" role="menuitem" use:focusNow onclick={() => fit(menu.header)}>{t('grid.fitColumn')}</button>
    <button type="button" role="menuitem" onclick={() => fit(null)}>{t('grid.fitAll')}</button>
    {#if actions}
      <div class="separator" role="separator"></div>
      <button type="button" role="menuitem" disabled={last} onclick={() => act('hide', menu.header)}>{t('grid.hideColumn')}</button>
      <button type="button" role="menuitem" onclick={() => act('columns')}>{t('grid.columns')}</button>
      <button type="button" role="menuitem" disabled={!actions.hidden.size} onclick={() => act('showAll')}>{t('grid.showAll')}</button>
      <div class="separator" role="separator"></div>
      <div class="list">
        {#each actions.all as col (col.name)}
          {@const shown = !actions.hidden.has(col.name)}
          <button
            type="button"
            role="menuitemcheckbox"
            aria-checked={shown}
            disabled={shown && last}
            onclick={(e) => {
              e.stopPropagation(); // o clique nao fecha o menu
              actions.hide(col.name);
            }}><span class="check">{shown ? '✓' : ''}</span>{col.name}</button
          >
        {/each}
      </div>
    {/if}
  </div>
{:else if menu}
  <!-- como o menu da celula do Go: na aba Data primeiro os filtros por valor, depois copiar (foco em Copiar valor) -->
  <div class="menu" role="menu" aria-label={t('grid.cell')} style="left: {menu.x}px; top: {menu.y}px" use:keepInside>
    {#if actions}
      <button type="button" role="menuitem" onclick={() => act('filter', selected.col, selected.row[selected.col])}>
        {t('grid.filterValue')}
      </button>
      <button type="button" role="menuitem" disabled={!actions.filtered} onclick={() => act('clearFilters')}>{t('grid.clearFilters')}</button>
      <div class="separator" role="separator"></div>
    {/if}
    <button type="button" role="menuitem" use:focusNow onclick={() => copy('value')}>
      {t('grid.copyValue')} <kbd>{t('grid.copyKey')}</kbd>
    </button>
    <button type="button" role="menuitem" onclick={() => copy('row')}>{t('grid.copyRow')}</button>
    <button type="button" role="menuitem" onclick={() => copy('row-header')}>{t('grid.copyRowHeader')}</button>
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

  /* texto da grade na fonte do app (Segoe UI 14 px, a do Go/Wails), cabecalho, tipo e menus tambem */
  table {
    border-collapse: separate;
    border-spacing: 0;
    font-variant-numeric: tabular-nums;
  }

  /* z-index: o cabecalho fixo fica sempre por cima das celulas que rolam por baixo dele */
  th {
    position: sticky;
    top: 0;
    z-index: 1;
    background: var(--surface);
    border-bottom: 2px solid var(--border);
    /* --cell-x: espaco de cada lado da celula; a grade do Schema passa um pouco mais */
    padding: 6px var(--cell-x, 10px);
    text-align: left;
    font-weight: 600;
    white-space: nowrap;
  }

  /* borda direita do cabecalho: arrastar muda a largura da coluna (so o cursor muda, nada desenhado) */
  .grip {
    position: absolute;
    top: 0;
    right: 0;
    width: 6px;
    height: 100%;
    cursor: col-resize;
  }

  /* inherit: sem isso o navegador poe <small> em "smaller" (11,67 px) */
  th small {
    display: block;
    color: var(--muted);
    font-size: inherit;
    font-weight: 500;
    letter-spacing: 0.04em;
  }

  /* sem largura maxima: a coluna cresce ate caber o valor inteiro (nenhum campo cortado) */
  td {
    padding: 4px var(--cell-x, 10px);
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

  /* menu alto (tabela com muitas colunas): cabe na janela e so a lista de colunas rola */
  .menu {
    position: fixed;
    z-index: 10;
    display: flex;
    flex-direction: column;
    max-height: calc(100vh - 8px);
    box-sizing: border-box;
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

  .menu .list {
    display: flex;
    flex-direction: column;
    min-height: 0;
    overflow-y: auto;
  }

  .menu button {
    flex-shrink: 0;
  }

  /* marca da coluna visivel a esquerda do nome, como os itens marcados dos menus do app */
  .menu .list button {
    justify-content: flex-start;
    gap: 0;
  }

  .check {
    display: inline-block;
    width: 1.4em;
    color: var(--accent);
  }

  .menu kbd {
    color: var(--muted);
    font: inherit;
  }
</style>
