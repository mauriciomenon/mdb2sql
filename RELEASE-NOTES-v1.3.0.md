# MDB2SQL 1.3.0 (2026-11-18)

Same release for the four stacks: python_pyqt6, go_wails_react, rust_tauri_svelte, zig_imgui.
Products for Windows 11 amd64 (single exe, zip, installer) and, new, Debian amd64 (.deb and .zip).

## Access first, nothing to install
- `.accdb` and `.mdb` open without Access, ODBC driver or runtime: mdbtools 1.0.1 ships inside the program.
  The Windows Access ODBC driver is used only when it is already installed (faster); `MDB2SQL_ACCESS_READER=mdbtools`
  forces mdbtools.
- The Access file is converted once into a SQLite file and read from there. Closing the file, opening another or
  quitting asks: Save (default `<name>.sqlite` next to the Access file), Delete or Cancel. Enter saves, Esc and
  the window close button cancel. Leftovers of a crashed run are removed at the next start.
- Order everywhere: Access, SQLite, DuckDB.
- Numbers keep numeric types in the SQLite file (Currency and decimals are REAL), so filters, ORDER BY and SUM
  are numeric. Exact up to 15 significant digits.
- Checked on real files: DB4 and DB3 (287 tables; 113,962 and 113,826 rows) equal the reference conversions
  table by table, through mdbtools and through ODBC.

## Faster
- mdb-export runs in parallel and the SQLite is written in one transaction. DB4 through mdbtools: about
  70 s → 33-40 s; through ODBC: about 17-37 s → 7-10 s (varies by stack).

## Screen
- Languages: English (default), Português (Brasil), Español (Settings > Language).
- Log panel at the bottom, collapsed by default (View > Log, Ctrl+L); when collapsed the status bar shows the last
  error, warning or action. Text is selectable and copyable. Database errors show in one line; the full text is in
  the log.
- Search runs in the database over the whole table. "Hide all" / "Show all" act only on the listed columns.
- Every dialog has an OK/Close button (Enter / Esc). Arrows use →; numeric columns are right-aligned.

## Linux (Debian amd64)
- X11 first, Wayland only as fallback, with a short warning naming what is missing and the install command for the
  distribution (README section "Linux: X11 e Wayland").

## Known limits
- mdbtools reads empty text as NULL (ODBC keeps "").
- macOS, Arch and BSD packages are not part of this release.

License: GPL-2.0-or-later.
