# Changelog - MDB2SQL (Python + PyQt6)

## 1.2.0 (2026-11-17)

- Short window title: `mdb2sql 1.2.0 - Python` (`<file> - mdb2sql 1.2.0 - Python` with a file open). The full
  stack moved to Help > Sobre.
- Help > Sobre redesigned: name and version, what the program does, build number and date, stack with versions
  (Python, PyQt6, Qt), libraries, Access readers (ODBC installed or not, bundled mdbtools version), author, license
  and two clickable links (GitHub and GitLab) that open in the default browser.
- Data tab, "Colunas..." button: list with one check box per column, "Mostrar todas", "Ocultar todas", several
  columns hidden or shown in one go. Right-click on a column header: "Ocultar esta coluna", "Colunas...",
  "Mostrar todas". The status bar shows "N colunas ocultas". Hidden columns last until another table or file is
  selected. Search still looks at every column and exports still write every column.
- Data tab, right-click on a cell (also Edit menu): "Filtrar por este valor" and "Limpar filtros". The filter is
  `column = value` (NULL: `IS NULL`) and runs in the database query, so it finds rows beyond the loaded ones and
  still respects "Rows". Several filters add up (AND) and combine with the word search. Active filters are shown
  above the grid, one button each (click removes it), plus "Limpar filtros". Changing table clears them.
  Column names are always quoted and values are always bound parameters.
- Nothing cut with "..." in the grids: each column fits its header name and the longest loaded value (1.1.1 cut
  values at 320 px). Only a value wider than 1,200 px is cut, with the full text in the tooltip.
- Table names are never cut with "...": the Tables panel opens as wide as the longest name (up to 35% of the
  window, then horizontal scroll; the separator still drags) and each name has a tooltip.
- "Colunas..." dialog sized from the window (~65%, 420 to 900 px, height up to 70%), check boxes in a responsive
  grid (1 to 6 per row, recomputed on resize, base font, vertical scroll only), search on top, changes apply at
  once, "Fechar".
- Shorter screen texts: no instructions in placeholders or on the empty window; tooltips are one short line.
- Licenca: GPL v2 ou posterior (antes: sem licenca, "proprietaria"). `LICENSE` goes in the zip and the installed
  folder; `pyproject.toml` says `GPL-2.0-or-later`.
- Nothing duplicated: the "Colunas..." and "Limpar filtros" buttons are the same actions as their menu items, the
  toolbar Export button and File > Export share one menu, and each export deletes its progress window when done
  (a test counts buttons, menu items and right-click items by name).

### Corrigido

- Export: an error or Cancel no longer deletes an existing file with the chosen name. The export is written to a
  temporary file of its own and replaces the target only when it finished.
- Export: Cancel during the last table (or after the last block of rows) ended as success; it is now a cancel.
- Opening another database drops the results still pending from the previous one (table, SQL, and a slower
  earlier open), and clears the old SQL result.

## 1.1.1 (2026-11-16)

- Search: all words in any order, ignoring case and accents; much faster on large tables.
- App icon and version in the window title.

## 1.1.0 (2026-11-15)

- First release of this stack with the three Windows products (single exe, zip, installer).
