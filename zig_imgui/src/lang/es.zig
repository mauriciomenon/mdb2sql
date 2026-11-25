// Espanol. Mismas claves que en.zig; los textos con {..} reciben los mismos argumentos en el mismo orden.

// ventana principal
pub const path_hint = "archivo de base de datos (.accdb, .mdb, .sqlite, .duckdb)";
pub const browse = "Examinar...";
pub const open = "Abrir";
pub const export_button = "Exportar...";
pub const no_db = "Ninguna base de datos abierta";
pub const filter_tables = "filtrar tablas";
pub const search_rule = "Todas las palabras, en cualquier orden, sin distinguir mayúsculas ni acentos";
pub const col_table = "Tabla";
pub const col_rows = "Filas";
pub const tab_data = "Datos";
pub const tab_schema = "Esquema";
pub const tab_sql = "SQL";
pub const select_table = "Seleccione una tabla";
pub const search = "buscar";
pub const columns_button = "Columnas...";
pub const columns_tip = "Las columnas ocultas siguen en la búsqueda y en la exportación.";
pub const rows_label = "Filas";
pub const rows_showing = "{s}: mostrando {d} de {d} filas";
pub const rows_showing_one = "{s}: mostrando {d} de {d} fila";
pub const rows_found = "{s}: mostrando {d} de {d} filas encontradas";
pub const rows_found_one = "{s}: mostrando {d} de {d} fila encontrada";
pub const hidden_cols = "{d} columnas ocultas";
pub const hidden_cols_one = "{d} columna oculta";
pub const filters_label = "Filtros:";
pub const remove_filter = "Quitar este filtro";
pub const clear_filters = "Quitar filtros";
pub const run = "Ejecutar (Ctrl+Enter)";
pub const search_rows = "buscar en las filas mostradas";
pub const sql_hint = "SELECT * FROM ...";
pub const rows_match = "{d} de {d} filas coinciden";
pub const schema_column = "Columna";
pub const schema_type = "Tipo";
pub const schema_null = "Admite nulo";
pub const null_text = "NULL";
pub const yes = "Sí";
pub const no = "No";
pub const scope_table = "Esta tabla";
pub const scope_all = "Todas las tablas";
pub const global_found = "{d} tablas con filas que contienen \"{s}\"";
pub const global_found_one = "{d} tabla con filas que contienen \"{s}\"";

// menus de la grilla y dialogo Columnas
pub const filter_by_value = "Filtrar por este valor";
pub const copy_value = "Copiar valor";
pub const copy_row = "Copiar fila";
pub const copy_row_header = "Copiar fila con encabezado";
pub const fit_column = "Ajustar columna";
pub const fit_all_columns = "Ajustar todas las columnas";
pub const hide_column = "Ocultar esta columna";
pub const show_all_columns = "Mostrar todas las columnas";
pub const show_all = "Mostrar todas";
pub const hide_all = "Ocultar todas";
pub const columns_title = "Columnas de {s}";
pub const sql_result = "Resultado SQL";
pub const find_column = "buscar columna";
pub const columns_shown = "{d} de {d} visibles";

// menus
pub const menu_file = "Archivo";
pub const menu_open = "Abrir...";
pub const menu_export = "Exportar";
pub const menu_close = "Cerrar";
pub const menu_exit = "Salir";
pub const menu_view = "Ver";
pub const menu_log = "Registro";
pub const menu_settings = "Configuración";
pub const menu_theme = "Tema";
pub const theme_system = "Sistema";
pub const theme_light = "Claro";
pub const theme_dark = "Oscuro";
pub const menu_language = "Idioma";
pub const menu_search_scope = "Ámbito de búsqueda predeterminado";
pub const menu_show_null = "Mostrar NULL";
pub const menu_help = "Ayuda";
pub const menu_about = "Acerca de mdb2sql";
pub const export_db_sqlite = "Base de datos a SQLite (.sqlite)...";
pub const export_db_xlsx = "Base de datos a Excel (.xlsx, una hoja por tabla)...";
pub const export_db_duckdb = "Base de datos a DuckDB (.duckdb)...";
pub const export_table_csv = "Tabla actual a CSV...";
pub const export_table_xlsx = "Tabla actual a Excel (.xlsx)...";
pub const export_schema_csv = "Esquema de la tabla actual a CSV...";
pub const export_schema_xlsx = "Esquema de la tabla actual a Excel (.xlsx)...";
pub const export_result_csv = "Resultado SQL a CSV...";
pub const export_result_xlsx = "Resultado SQL a Excel (.xlsx)...";
pub const export_scope_text = "La búsqueda está activa en {s}. Exportar:";
pub const export_whole = "Tabla entera";
pub const export_found = "Solo las {d} filas encontradas";
pub const export_found_one = "Solo la {d} fila encontrada";

// Acerca de
pub const about_title = "Acerca de mdb2sql";
pub const about_tagline = "Abre bases de datos Access, SQLite y DuckDB y exporta a SQLite, DuckDB, Excel y CSV.";
pub const about_build = "Compilación";
pub const about_stack = "Stack";
pub const about_window = "Ventana";
pub const about_database = "Bases de datos";
pub const about_access = "Lectura de Access";
pub const about_access_win = "mdbtools {s} (incluido) o el controlador ODBC de Access, convertido una vez a SQLite";
pub const about_access_unix = "mdbtools {s} (incluido), convertido una vez a SQLite";
pub const about_author = "Autor";
pub const about_license = "Licencia";
pub const about_license_text = "GPL v2 o posterior (GPL-2.0-or-later)";
pub const about_open_browser = "Abrir en el navegador";

// botones comunes
pub const close = "Cerrar";
pub const cancel = "Cancelar";
pub const save = "Guardar...";
pub const delete = "Eliminar";
pub const copy = "Copiar";
pub const copy_all = "Copiar todo";
pub const clear = "Borrar";

// SQLite convertido
pub const converted_title = "SQLite convertido";
pub const converted_text = "¿Guardar el archivo SQLite convertido desde Access ({s})?";
pub const converted_remember = "Recordar en esta sesión";
pub const converted_reused = "{s}: abierto el SQLite guardado de él ({s})";
pub const converted_saved = "SQLite guardado: {s}";
pub const converted_deleted = "SQLite convertido eliminado";

// ventana Registro
pub const log_title = "Registro";
pub const log_hide = "Ocultar el registro (Ctrl+L)";
pub const log_show = "Mostrar el registro (Ctrl+L)";
pub const log_unread = "{d} errores o advertencias sin leer";
pub const log_unread_one = "{d} error o advertencia sin leer";

// trabajo en curso
pub const busy_converting = "Convirtiendo la base de datos Access";
pub const busy_opening = "Abriendo la base de datos";
pub const busy_loading = "Cargando la tabla";
pub const busy_running = "Ejecutando la consulta";
pub const busy_searching = "Buscando en todas las tablas";
pub const busy_exporting = "Exportando";
pub const busy_elapsed = "{s} {d:.1} s";
pub const progress_overlay = "{d} / {d} {s}";
pub const unit_tables = "tablas";
pub const unit_rows = "filas";

// linea de estado
pub const status_loaded = "Abierto: {s} ({d} tablas)";
pub const status_loaded_one = "Abierto: {s} ({d} tabla)";
pub const source_via = "Abierto con {s}";
pub const source_via_converted = "Abierto con {s}, convertido a SQLite";
pub const source_tip = "Lector usado para abrir el archivo";
pub const status_closed = "Cerrado: {s}";
pub const status_exported = "Exportadas {d} {s} a {s}{s}{s}";
pub const export_cut_cells = " | {d} celdas cortadas a 32.767 caracteres";
pub const export_cut_cols = " | {d} columnas después de la 16.384 quedaron fuera";
pub const sql_more_rows = "Más de {d} filas: se muestran las primeras {d} (la exportación escribe todas)";
pub const sql_rows_cols = "{d} filas, {d} columnas";
pub const source_access_odbc = "Access ODBC";
pub const source_access_mdbtools = "mdbtools";

// errores
pub const canceled = "Cancelado";
pub const err_not_db = "No es un archivo de base de datos: use .accdb, .mdb, .sqlite, .sqlite3, .db o .duckdb";
pub const err_cannot_write = "No se puede escribir el archivo: está abierto en otro programa o la carpeta es de solo lectura ({t})";
pub const err_generic = "Error: {t}";
pub const err_sql = "Error en la consulta SQL: {s}";
pub const err_db = "Error de la base de datos: {s}";
pub const err_plain = "{s}";
pub const err_worker = "No se pudo iniciar la tarea en segundo plano: {t}";
pub const err_settings = "No se pudo guardar la configuración: {t}";
pub const err_choose_other = "Elija otro archivo: este es la base de datos abierta";
pub const err_table_name_long = "Nombre de tabla demasiado largo";
pub const err_save_sqlite = "No se pudo guardar el archivo SQLite: {t}";
pub const err_no_dialog = "Diálogo de archivos no disponible (falta zenity): escriba la ruta en el cuadro";
pub const err_file_not_found = "Archivo no encontrado";
pub const err_reader_name = "MDB2SQL_ACCESS_READER debe ser odbc, mdbtools o auto";
pub const err_reader_forced = "El lector de Access definido en MDB2SQL_ACCESS_READER no está disponible en este equipo";
pub const err_no_reader = "No se pueden abrir archivos Access: falta la carpeta mdbtools junto al programa";
pub const err_temp_dir = "No se puede crear la carpeta temporal {s} ({t})";
pub const err_tool_run = "No se pudo ejecutar {s}: {t}";
pub const err_tool_failed = "{s} falló: {s}";
pub const err_export_table = "mdb-export falló en la tabla {s}";
pub const err_sqlite_missing = "Falta el soporte de SQLite: sqlite_scanner.duckdb_extension no está junto al programa";
pub const err_internal = "Error interno, el programa se cerrará:\n{s}";
pub const err_start = "MDB2SQL no pudo iniciar: {t}{s}";
pub const err_opengl = "\nEl controlador de video debe admitir OpenGL 3.3 (un escritorio remoto o una máquina virtual sin 3D puede no admitirlo).";

// modo de visualizacion en Linux (X11 primero, Wayland como reserva)
pub const display_title = "Modo de visualización";
pub const display_headline = "X11 no disponible; usando Wayland.";
pub const display_no_server = "Servidor X no definido (DISPLAY)";
pub const display_not_installed = "{s} no instalada";
pub const display_help = "Ayuda";
pub const display_none = "mdb2sql: no se pudo abrir la ventana: ni X11 ni Wayland están disponibles ({t}). Ayuda: {s}\n";
pub const ok = "Aceptar";

// dialogos de abrir y guardar
pub const dlg_databases = "Bases de datos";
pub const dlg_all_files = "Todos los archivos";

// ayuda de la linea de comandos (cuadro de mensaje)
pub const usage =
    \\uso: mdb2sql-zig [archivo.accdb|.mdb|.sqlite|.sqlite3|.db|.duckdb] [--table NOMBRE] [--sql "SELECT ..."]
    \\                 [--search TEXTO] [--cell FILA,COLUMNA] [--theme system|dark|light] [--lang en|pt_br|es]
    \\                 [--about] [--menu NOMBRE] [--export TIPO]
    \\  sin archivo: la variable de entorno MDB2SQL_DB_PATH, si existe
    \\  MDB2SQL_ACCESS_READER=odbc|mdbtools fuerza el lector de archivos .accdb/.mdb
    \\  las opciones fijan el estado inicial: tabla seleccionada, SQL a ejecutar, búsqueda de la pestaña Datos,
    \\  celda seleccionada con su menú de copia abierto, colores e idioma (solo en esta ejecución),
    \\  Acerca de abierto, un menú abierto (File, View, Settings, Help, Export)
    \\  --export db_sqlite|db_xlsx|db_duckdb|table_csv|table_xlsx|result_csv|result_xlsx
    \\  abre el diálogo de guardar de esa exportación al cargar el archivo
    \\
;
