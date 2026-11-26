// English (default). Same keys in pt_br.zig and es.zig; texts with {..} take the same arguments in the same order.

// main window
pub const path_hint = "database file (.accdb, .mdb, .sqlite, .duckdb)";
pub const open = "Open...";
pub const export_button = "Export...";
pub const no_db = "No database loaded";
pub const filter_tables = "Filter {d} tables";
pub const filter_tables_one = "Filter {d} table";
pub const search_rule = "All words, any order, in one cell; ignores case and accents";
pub const col_table = "Table";
pub const col_rows = "Rows";
pub const tab_data = "Data";
pub const tab_schema = "Schema";
pub const tab_sql = "SQL";
pub const select_table = "Select a table";
pub const search = "Search the whole table";
pub const columns_button = "Columns...";
pub const columns_tip = "Search and export use every column";
pub const rows_label = "Rows";
pub const rows_showing = "{s}: showing {d} of {d} rows";
pub const rows_showing_one = "{s}: showing {d} of {d} row";
pub const rows_page = "{s}: rows {d} to {d} of {d}";
pub const rows_page_one = "{s}: row {d} to {d} of {d}";
pub const rows_page_found = "{s}: rows {d} to {d} of {d} found";
pub const rows_page_found_one = "{s}: row {d} to {d} of {d} found";
pub const page_prev = "Previous";
pub const page_next = "Next";
pub const hidden_cols = "{d} hidden columns";
pub const hidden_cols_one = "{d} hidden column";
pub const filters_label = "Filters:";
pub const remove_filter = "Remove this filter";
pub const clear_filters = "Clear filters";
pub const run = "Run (Ctrl+Enter)";
pub const sql_hint = "SELECT * FROM ...";
pub const search_rows = "Search the loaded result";
pub const rows_match = "{d} of {d} rows match";
pub const rows_match_one = "{d} of {d} row matches";
pub const schema_column = "Column";
pub const schema_type = "Type";
pub const schema_null = "Nullable";
pub const null_text = "NULL";
pub const yes = "Yes";
pub const no = "No";
pub const scope_table = "This table";
pub const scope_all = "All tables";
pub const global_found = "{d} tables with rows matching \"{s}\"";
pub const global_found_one = "{d} table with rows matching \"{s}\"";

// grid menus and Columns dialog
pub const filter_by_value = "Filter by this value";
pub const copy_value = "Copy value";
pub const copy_row = "Copy row";
pub const copy_row_header = "Copy row with header";
pub const fit_column = "Size column to fit";
pub const fit_all_columns = "Size all columns to fit";
pub const hide_column = "Hide this column";
pub const show_all_columns = "Show all columns";
pub const show_all = "Show all";
pub const hide_all = "Hide all";
pub const columns_title = "Columns of {s}";
pub const mark_tip = "Mark rows";
pub const marked_count = ", {d} marked";
pub const marked_count_one = ", {d} marked";
pub const only_marked = "Only marked";
pub const menu_mark = "Mark or unmark row";
pub const menu_unmark_all = "Unmark all rows";
pub const ctx_export_marked = "Export marked rows";
pub const key_space = "Space";
pub const fmt_csv = "CSV...";
pub const fmt_xlsx = "Excel (.xlsx)...";
pub const fmt_sqlite = "SQLite (.sqlite)...";
pub const fmt_duckdb = "DuckDB (.duckdb)...";

// Terms tab (term search)
pub const tab_terms = "Advanced Search";
pub const terms_hint = "Paste the terms, one per line (for example, an Excel column). Example:\ntext1\ntext2\ntext3\nsearches the 3 terms in all tables or only in the selected table.";
pub const match_whole = "Whole value";
pub const match_contains = "Contains";
pub const match_tip = "Whole value: the whole cell equals the term. Contains: the cell contains the term. Case and spaces at the ends do not count.";
pub const menu_term_match = "Term matching";
pub const terms_run = "Search terms";
pub const terms_count = "{d} terms";
pub const terms_count_one = "{d} term";
pub const terms_repeated = ", {d} repeated";
pub const terms_repeated_one = ", {d} repeated";
pub const terms_summary = "{s}: {s} in {s}";
pub const terms_only_in = " (only in {s})";
pub const terms_found = "{d} of {d} terms found";
pub const terms_found_one = "{d} of {d} term found";
pub const terms_rows = "{d} rows";
pub const terms_rows_one = "{d} row";
pub const terms_tables = "{d} tables";
pub const terms_tables_one = "{d} table";
pub const terms_progress = "Searching terms: table {d} of {d} ({s})";
pub const col_term = "Term";
pub const col_status = "Status";
pub const term_found = "Found";
pub const term_not_found = "Not found";
pub const not_found_title = "Not found ({d})";
pub const copy_hits = "Copy the rows found in this table";
pub const sheet_result = "Filter Result";
pub const export_terms = "Advanced Search report";
pub const overwrite_many = "{d} files already exist in this folder. Replace them?";
pub const overwrite_many_one = "{d} file already exists in this folder. Replace it?";
pub const sql_result ="SQL result";
pub const find_column = "Filter columns";
pub const columns_shown = "{d} of {d} shown";

// menus
pub const menu_file = "File";
pub const menu_open = "Open...";
pub const menu_open_typed = "Open the typed path";
pub const menu_reopen = "Reopen";
pub const menu_save = "Save";
pub const menu_save_as = "Save as...";
pub const menu_export = "Export";
pub const menu_close = "Close";
pub const menu_exit = "Exit";
pub const menu_view = "View";
pub const menu_log = "Log";
pub const menu_settings = "Settings";
pub const menu_theme = "Theme";
pub const theme_system = "System";
pub const theme_light = "Light";
pub const theme_dark = "Dark";
pub const menu_language = "Language";
pub const menu_search_scope = "Default search scope";
pub const menu_show_null = "Show NULL";
pub const menu_help = "Help";
pub const menu_about = "About mdb2sql";
pub const export_table = "Current table";
pub const export_marked = "Marked rows";
pub const export_schema = "Current table schema";
pub const export_dbschema = "Database schema";
pub const export_all_csv = "All tables to CSV (one file per table)...";
pub const export_result = "SQL result";
pub const export_global = "All-tables search result (Excel)...";
pub const menu_edit = "Edit";
pub const menu_copy_log = "Copy the whole log";
pub const menu_search = "Search";
pub const menu_search_in = "Search in";
pub const menu_only_marked = "Only marked rows";
pub const menu_goto_tables = "Go to the table list";
pub const fav_add = "Add to favorites";
pub const fav_remove = "Remove from favorites";
pub const fav_toggle = "Favorite or unfavorite table";
pub const menu_run_sql = "Run SQL";
pub const export_scope_text = "The search is active on {s}. Export:";
pub const export_whole = "Whole table";
pub const export_found = "Only the {d} rows found";
pub const export_found_one = "Only the {d} row found";

// About
pub const about_title = "About mdb2sql";
pub const about_version = "Version {s} - commit {s} - {s}";
pub const about_version_dev = "Version {s} - dev";
pub const about_tools = "Tools: SQLite {s}, DuckDB {s}, mdbtools {s}";
pub const about_odbc = "ODBC driver support, if installed.";
pub const about_author_line = "Author: {s}";
pub const about_license_line = "License: GPLv2";
pub const about_open_browser = "Open in the browser";

// common buttons
pub const close = "Close";
pub const cancel = "Cancel";
pub const copy = "Copy";
pub const copy_all = "Copy all";
pub const clear = "Clear";

// converted SQLite, Save and Exit
pub const converted_title = "Converted SQLite file";
pub const exit_text = "The database converted from {s} was not saved. Save before exiting?";
pub const btn_save = "Save";
pub const btn_back = "Back";
pub const btn_exit = "Exit";
pub const log_discarded = "SQLite converted from {s} discarded";
pub const export_run_title = "Export in progress";
pub const export_run_text = "Exiting cancels the export of {s}.";
pub const save_title = "Save as SQLite, DuckDB or Excel (.mdb and .accdb files cannot be written)";
pub const copy_name = "{s} (copy)";
pub const converted_reused = "{s}: opened the {s} saved from it ({s})";
pub const converted_saved = "SQLite saved: {s}";
pub const log_stale_removed = "Removed {d} converted files left by a previous session";
pub const log_stale_removed_one = "Removed {d} converted file left by a previous session";

// Log window
pub const log_title = "Log";
pub const log_hide = "Collapse the log (Ctrl+L)";
pub const log_show = "Show the log (Ctrl+L)";
pub const log_unread = "{d} unread errors or warnings";
pub const log_unread_one = "{d} unread error or warning";

// work in progress
pub const busy_converting = "Converting the Access database";
pub const busy_opening = "Opening the database";
pub const busy_loading = "Loading table";
pub const busy_running = "Running query";
pub const busy_searching = "Searching all tables";
pub const busy_exporting = "Exporting";
pub const busy_elapsed = "{s} {d:.1} s";
pub const progress_overlay = "{d} / {d} {s}";
pub const unit_tables = "tables";
pub const unit_tables_one = "table";
pub const unit_rows = "rows";
pub const unit_rows_one = "row";

// status line
pub const status_loaded = "Loaded: {s} ({d} tables)";
pub const status_loaded_one = "Loaded: {s} ({d} table)";
pub const source_via = "Opened via {s}";
pub const source_via_converted = "Opened via {s}, converted to SQLite";
pub const source_tip = "Reader used to open the file";
pub const status_closed = "Closed: {s}";
pub const status_exported = "Exported {d} {s} to {s}{s}{s}";
pub const status_exported_one = "Exported {d} {s} to {s}{s}{s}";
pub const export_cut_cells = " | {d} cells cut to 32,767 characters";
pub const export_cut_cols = " | {d} columns past 16,384 left out";
pub const sql_more_rows = "More than {d} rows: showing the first {d} (the export writes all of them)";
pub const sql_rows = "{d} rows";
pub const sql_rows_one = "{d} row";
pub const sql_cols = "{d} columns";
pub const sql_cols_one = "{d} column";
pub const source_access_odbc = "Access ODBC";
pub const source_access_mdbtools = "mdbtools";

// errors
pub const canceled = "Canceled";
pub const err_not_db = "Not a database file: use .accdb, .mdb, .sqlite, .sqlite3, .db or .duckdb";
pub const err_cannot_write = "Cannot write the file: it is open in another program or the folder is read-only ({t})";
pub const err_generic = "Error: {t}";
pub const err_sql = "SQL query error: {s}";
pub const sql_read_only = "The SQL tab only reads the database: this command is not allowed";
pub const err_db = "Database error: {s}";
pub const err_plain = "{s}";
pub const err_worker = "Could not start the worker thread: {t}";
pub const err_settings = "Could not save the settings: {t}";
pub const err_choose_other = "Choose another file: this one is the database that is open";
pub const err_table_name_long = "Table name too long";
pub const err_save_sqlite = "Could not save the SQLite file: {t}";
pub const err_no_dialog = "File dialog not available (zenity is missing): type the path in the box";
pub const err_file_not_found = "File not found: {s}";
pub const err_reader_name = "MDB2SQL_ACCESS_READER must be odbc, mdbtools or auto";
pub const err_reader_forced = "The Access reader set by MDB2SQL_ACCESS_READER is not available on this computer";
pub const err_no_reader = "Cannot open Access files: the mdbtools folder next to the program is missing";
pub const err_temp_dir = "Cannot create the temporary folder {s} ({t})";
pub const err_tool_run = "{s} could not run: {t}";
pub const err_tool_failed = "{s} failed: {s}";
pub const err_export_table = "mdb-export failed on table {s}";
pub const err_sqlite_missing = "SQLite support missing: sqlite_scanner.duckdb_extension is not next to the program";
pub const err_internal = "Internal error, the program will close:\n{s}";
pub const err_start = "MDB2SQL could not start: {t}{s}";
pub const err_opengl = "\nThe graphics driver must support OpenGL 3.3 (a remote desktop or a virtual machine without 3D may not).";

// Linux display mode (X11 first, Wayland as fallback)
pub const display_title = "Display mode";
pub const display_headline = "X11 unavailable; using Wayland.";
pub const display_no_server = "X server not set (DISPLAY)";
pub const display_not_installed = "{s} not installed";
pub const display_help = "Help";
pub const display_none = "mdb2sql: cannot open a window: neither X11 nor Wayland is available ({t}). Help: {s}\n";
pub const ok = "OK";

// open and save dialogs
pub const dlg_databases = "Databases";
pub const dlg_all_files = "All files";

// command line help (message box)
pub const usage =
    \\usage: mdb2sql-zig [file.accdb|.mdb|.sqlite|.sqlite3|.db|.duckdb] [--table NAME] [--sql "SELECT ..."]
    \\                   [--search TEXT] [--cell ROW,COL] [--theme system|dark|light] [--lang en|pt_br|es]
    \\                   [--about] [--menu NAME] [--export KIND]
    \\  no file argument: the MDB2SQL_DB_PATH environment variable, if set
    \\  MDB2SQL_ACCESS_READER=odbc|mdbtools forces the reader of .accdb/.mdb files
    \\  the flags set the start state: selected table, SQL to run, search text of the Data tab,
    \\  grid cell selected with its copy menu open, colors and language (this run only),
    \\  About open, a menu open (File, Edit, View, Settings, Help, Export)
    \\  --export db_sqlite|db_xlsx|db_duckdb|table_csv|table_xlsx|result_csv|result_xlsx
    \\  opens the save dialog of that export when the file is loaded
    \\
;
