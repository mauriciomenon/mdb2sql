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
- Licenca: GPL v2 ou posterior (antes: sem licenca, "proprietaria"). `LICENSE` goes in the zip and the installed
  folder; `pyproject.toml` says `GPL-2.0-or-later`.
- Nothing duplicated: the "Colunas..." and "Limpar filtros" buttons are the same actions as their menu items, the
  toolbar Export button and File > Export share one menu, and each export deletes its progress window when done
  (a test counts buttons, menu items and right-click items by name).

## 1.1.1 (2026-11-16)

- Search: all words in any order, ignoring case and accents; much faster on large tables.
- App icon and version in the window title.

## 1.1.0 (2026-11-15)

- First release of this stack with the three Windows products (single exe, zip, installer).
