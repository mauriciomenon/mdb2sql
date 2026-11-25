// English (default). Same keys in pt_br.zig and es.zig; texts with {..} take the same arguments in the same order.

// main window
pub const path_hint = "database file (.accdb, .mdb, .sqlite, .duckdb)";
pub const browse = "Browse...";
pub const open = "Open";
pub const export_button = "Export...";
pub const no_db = "No database loaded";
pub const filter_tables = "filter tables";
pub const search_rule = "All words, any order, ignoring case and accents";
pub const col_table = "Table";
pub const col_rows = "Rows";
pub const tab_data = "Data";
pub const tab_schema = "Schema";
pub const tab_sql = "SQL";
pub const select_table = "Select a table";
pub const search = "search";
pub const columns_button = "Columns...";
pub const columns_tip = "Hidden columns are still searched and exported.";
pub const rows_label = "Rows";
pub const rows_showing = "{s}: showing {d} of {d} rows";
pub const rows_showing_one = "{s}: showing {d} of {d} row";
pub const rows_found = "{s}: showing {d} of {d} rows matching ({d} in the table)";
pub const rows_found_one = "{s}: showing {d} of {d} row matching ({d} in the table)";
pub const hidden_cols = "{d} hidden columns";
pub const hidden_cols_one = "{d} hidden column";
pub const filters_label = "Filters:";
pub const remove_filter = "Remove this filter";
pub const clear_filters = "Clear filters";
pub const run = "Run (Ctrl+Enter)";
pub const search_rows = "search the rows shown";
pub const sql_hint = "SELECT * FROM ...";
pub const rows_match = "{d} of {d} rows match";
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
pub const sql_result = "SQL result";
pub const find_column = "find a column";
pub const columns_shown = "{d} of {d} shown";

// menus
pub const menu_file = "File";
pub const menu_open = "Open...";
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
pub const export_db_sqlite = "Database to SQLite (.sqlite)...";
pub const export_db_xlsx = "Database to Excel (.xlsx, one sheet per table)...";
pub const export_db_duckdb = "Database to DuckDB (.duckdb)...";
pub const export_table_csv = "Current table to CSV...";
pub const export_table_xlsx = "Current table to Excel (.xlsx)...";
pub const export_schema_csv = "Current table schema to CSV...";
pub const export_schema_xlsx = "Current table schema to Excel (.xlsx)...";
pub const export_result_csv = "Current SQL result to CSV...";
pub const export_result_xlsx = "Current SQL result to Excel (.xlsx)...";
pub const export_scope_text = "The search is active on {s}. Export:";
pub const export_whole = "Whole table";
pub const export_found = "Only the {d} rows found";
pub const export_found_one = "Only the {d} row found";

// About
pub const about_title = "About mdb2sql";
pub const about_tagline = "Opens Access, SQLite and DuckDB databases, searches them and exports to SQLite, Excel, CSV and DuckDB.";
pub const about_build = "Build";
pub const about_stack = "Stack";
pub const about_window = "Window";
pub const about_database = "Database";
pub const about_access = "Access reader";
pub const about_access_win = "mdbtools {s} (included) or the Access ODBC driver, converted once to SQLite";
pub const about_access_unix = "mdbtools {s} (included), converted once to SQLite";
pub const about_author = "Author";
pub const about_license = "License";
pub const about_license_text = "GPL v2 or later (GPL-2.0-or-later)";
pub const about_open_browser = "Open in the browser";

// common buttons
pub const close = "Close";
pub const cancel = "Cancel";
pub const save = "Save...";
pub const delete = "Delete";
pub const copy = "Copy";
pub const copy_all = "Copy all";
pub const clear = "Clear";

// converted SQLite
pub const converted_title = "Converted SQLite";
pub const converted_text = "{s} was converted to SQLite to be read. Keep the converted file?";
pub const converted_save_tip = "Saves {s}.sqlite, next to the source file by default";
pub const converted_saved = "SQLite saved: {s}";
pub const converted_deleted = "Converted SQLite deleted";

// Log window
pub const log_title = "Log";
pub const log_hide = "Hide the log (Ctrl+L)";
pub const log_show = "Show the log (Ctrl+L)";
pub const log_unread = "{d} unread errors or warnings";
pub const log_unread_one = "{d} unread error or warning";

// work in progress
pub const busy_converting = "Converting the Access database";
pub const busy_opening = "Opening database";
pub const busy_loading = "Loading table";
pub const busy_running = "Running query";
pub const busy_searching = "Searching all tables";
pub const busy_exporting = "Exporting";
pub const busy_elapsed = "{s} {d:.1} s";
pub const progress_overlay = "{d} / {d} {s}";
pub const unit_tables = "tables";
pub const unit_rows = "rows";

// status line
pub const status_loaded = "Loaded: {s} ({d} tables)";
pub const status_loaded_one = "Loaded: {s} ({d} table)";
pub const source_via = "Opened via {s}";
pub const source_via_converted = "Opened via {s}, converted to SQLite";
pub const source_tip = "Reader used to open the file";
pub const status_closed = "Closed: {s}";
pub const status_exported = "Exported {d} {s} to {s}{s}{s}";
pub const export_cut_cells = " | {d} cells cut to 32,767 characters";
pub const export_cut_cols = " | {d} columns past 16,384 left out";
pub const sql_more_rows = "More than {d} rows: showing the first {d} (the export writes all of them)";
pub const sql_rows_cols = "{d} rows, {d} columns";
pub const source_access_odbc = "Access ODBC";
pub const source_access_mdbtools = "mdbtools";

// errors
pub const canceled = "Canceled";
pub const err_not_db = "Not a database file: use .accdb, .mdb, .sqlite, .sqlite3, .db or .duckdb";
pub const err_cannot_write = "Cannot write the file: it is open in another program or the folder is read-only ({t})";
pub const err_generic = "Error: {t}";
pub const err_sql = "SQL query error: {s}";
pub const err_db = "Database error: {s}";
pub const err_plain = "{s}";
pub const err_worker = "Could not start the worker thread: {t}";
pub const err_settings = "Could not save the settings: {t}";
pub const err_choose_other = "Choose another file: this one is the database that is open";
pub const err_table_name_long = "Table name too long";
pub const err_save_sqlite = "Could not save the SQLite file: {t}";
pub const err_no_dialog = "File dialog not available (zenity is missing): type the path in the box";
pub const err_file_not_found = "File not found";
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
    \\  About open, a menu open (File, View, Settings, Help, Export)
    \\  --export db_sqlite|db_xlsx|db_duckdb|table_csv|table_xlsx|result_csv|result_xlsx
    \\  opens the save dialog of that export when the file is loaded
    \\
;
