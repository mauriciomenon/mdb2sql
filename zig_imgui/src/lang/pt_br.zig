// Portugues (Brasil). Mesmas chaves de en.zig; textos com {..} recebem os mesmos argumentos na mesma ordem.

// janela principal
pub const path_hint = "arquivo do banco (.accdb, .mdb, .sqlite, .duckdb)";
pub const browse = "Procurar...";
pub const open = "Abrir";
pub const export_button = "Exportar...";
pub const no_db = "Nenhum banco aberto";
pub const filter_tables = "Filtrar {d} tabelas";
pub const filter_tables_one = "Filtrar {d} tabela";
pub const search_rule = "Todas as palavras, em qualquer ordem, na mesma célula; ignora maiúsculas e acentos";
pub const col_table = "Tabela";
pub const col_rows = "Linhas";
pub const tab_data = "Dados";
pub const tab_schema = "Esquema";
pub const tab_sql = "SQL";
pub const select_table = "Selecione uma tabela";
pub const search = "Pesquisar na tabela inteira";
pub const columns_button = "Colunas...";
pub const columns_tip = "Pesquisa e exportação usam todas as colunas";
pub const rows_label = "Linhas";
pub const rows_showing = "{s}: mostrando {d} de {d} linhas";
pub const rows_showing_one = "{s}: mostrando {d} de {d} linha";
pub const rows_found = "{s}: mostrando {d} de {d} linhas encontradas";
pub const rows_found_one = "{s}: mostrando {d} de {d} linha encontrada";
pub const hidden_cols = "{d} colunas ocultas";
pub const hidden_cols_one = "{d} coluna oculta";
pub const filters_label = "Filtros:";
pub const remove_filter = "Remover este filtro";
pub const clear_filters = "Limpar filtros";
pub const run = "Executar (Ctrl+Enter)";
pub const sql_hint = "SELECT * FROM ...";
pub const search_rows = "Pesquisar no resultado carregado";
pub const rows_match = "{d} de {d} linhas encontradas";
pub const rows_match_one = "{d} de {d} linha encontrada";
pub const schema_column = "Coluna";
pub const schema_type = "Tipo";
pub const schema_null = "Aceita nulo";
pub const null_text = "NULL";
pub const yes = "Sim";
pub const no = "Não";
pub const scope_table = "Esta tabela";
pub const scope_all = "Todas as tabelas";
pub const global_found = "{d} tabelas com linhas que contêm \"{s}\"";
pub const global_found_one = "{d} tabela com linhas que contêm \"{s}\"";

// menus da grade e dialogo Colunas
pub const filter_by_value = "Filtrar por este valor";
pub const copy_value = "Copiar valor";
pub const copy_row = "Copiar linha";
pub const copy_row_header = "Copiar linha com cabeçalho";
pub const fit_column = "Ajustar coluna";
pub const fit_all_columns = "Ajustar todas as colunas";
pub const hide_column = "Ocultar esta coluna";
pub const show_all_columns = "Mostrar todas as colunas";
pub const show_all = "Mostrar todas";
pub const hide_all = "Ocultar todas";
pub const columns_title = "Colunas de {s}";
pub const sql_result = "Resultado SQL";
pub const find_column = "Filtrar colunas";
pub const columns_shown = "{d} de {d} visíveis";

// menus
pub const menu_file = "Arquivo";
pub const menu_open = "Abrir...";
pub const menu_open_typed = "Abrir o caminho digitado";
pub const menu_reopen = "Reabrir";
pub const menu_save = "Salvar";
pub const menu_save_as = "Salvar como...";
pub const menu_export = "Exportar";
pub const menu_close = "Fechar";
pub const menu_exit = "Sair";
pub const menu_view = "Exibir";
pub const menu_log = "Log";
pub const menu_settings = "Configurações";
pub const menu_theme = "Tema";
pub const theme_system = "Sistema";
pub const theme_light = "Claro";
pub const theme_dark = "Escuro";
pub const menu_language = "Idioma";
pub const menu_search_scope = "Escopo padrão da busca";
pub const menu_show_null = "Exibir NULL";
pub const menu_help = "Ajuda";
pub const menu_about = "Sobre o mdb2sql";
pub const export_table_csv = "Tabela atual para CSV...";
pub const export_table_xlsx = "Tabela atual para Excel (.xlsx)...";
pub const export_schema_csv = "Esquema da tabela atual para CSV...";
pub const export_schema_xlsx = "Esquema da tabela atual para Excel (.xlsx)...";
pub const export_result_csv = "Resultado do SQL para CSV...";
pub const export_result_xlsx = "Resultado do SQL para Excel (.xlsx)...";
pub const export_scope_text = "A busca está ativa em {s}. Exportar:";
pub const export_whole = "Tabela inteira";
pub const export_found = "Só as {d} linhas encontradas";
pub const export_found_one = "Só a {d} linha encontrada";

// Sobre
pub const about_title = "Sobre o mdb2sql";
pub const about_tagline = "Abre bancos Access, SQLite e DuckDB e exporta para SQLite, DuckDB, Excel e CSV.";
pub const about_build = "Build";
pub const about_stack = "Stack";
pub const about_window = "Janela";
pub const about_database = "Bancos";
pub const about_access = "Leitura do Access";
pub const about_access_win = "mdbtools {s} (incluído) ou o driver ODBC do Access, convertido uma vez para SQLite";
pub const about_access_unix = "mdbtools {s} (incluído), convertido uma vez para SQLite";
pub const about_write = "Gravação";
pub const about_write_value = "SQLite, DuckDB, Excel e CSV. Arquivos .mdb e .accdb não podem ser gravados: o formato do Access é proprietário da Microsoft.";
pub const about_author = "Autor";
pub const about_license = "Licença";
pub const about_license_text = "GPL v2 ou posterior (GPL-2.0-or-later)";
pub const about_open_browser = "Abrir no navegador";

// botoes comuns
pub const close = "Fechar";
pub const cancel = "Cancelar";
pub const copy = "Copiar";
pub const copy_all = "Copiar tudo";
pub const clear = "Limpar";

// SQLite convertido, Salvar e Sair
pub const converted_title = "SQLite convertido";
pub const exit_text = "O banco convertido de {s} não foi salvo. Salvar antes de sair?";
pub const btn_save = "Salvar";
pub const btn_back = "Voltar";
pub const btn_exit = "Sair";
pub const log_discarded = "SQLite convertido de {s} descartado";
pub const export_run_title = "Exportação em andamento";
pub const export_run_text = "Sair cancela a exportação de {s}.";
pub const save_title = "Salvar como SQLite, DuckDB ou Excel (arquivos .mdb e .accdb não podem ser gravados)";
pub const copy_name = "{s} (cópia)";
pub const converted_reused = "{s}: aberto o SQLite salvo dele ({s})";
pub const converted_saved = "SQLite salvo: {s}";
pub const log_stale_removed = "{d} arquivos convertidos de uma sessão anterior removidos";
pub const log_stale_removed_one = "{d} arquivo convertido de uma sessão anterior removido";

// janela Log
pub const log_title = "Log";
pub const log_hide = "Recolher o log (Ctrl+L)";
pub const log_show = "Mostrar o log (Ctrl+L)";
pub const log_unread = "{d} erros ou avisos não lidos";
pub const log_unread_one = "{d} erro ou aviso não lido";

// trabalho em andamento
pub const busy_converting = "Convertendo o banco Access";
pub const busy_opening = "Abrindo o banco";
pub const busy_loading = "Carregando a tabela";
pub const busy_running = "Executando a consulta";
pub const busy_searching = "Pesquisando todas as tabelas";
pub const busy_exporting = "Exportando";
pub const busy_elapsed = "{s} {d:.1} s";
pub const progress_overlay = "{d} / {d} {s}";
pub const unit_tables = "tabelas";
pub const unit_tables_one = "tabela";
pub const unit_rows = "linhas";
pub const unit_rows_one = "linha";

// linha de status
pub const status_loaded = "Aberto: {s} ({d} tabelas)";
pub const status_loaded_one = "Aberto: {s} ({d} tabela)";
pub const source_via = "Aberto via {s}";
pub const source_via_converted = "Aberto via {s}, convertido para SQLite";
pub const source_tip = "Leitor usado para abrir o arquivo";
pub const status_closed = "Fechado: {s}";
pub const status_exported = "Exportadas {d} {s} para {s}{s}{s}";
pub const status_exported_one = "Exportada {d} {s} para {s}{s}{s}";
pub const export_cut_cells = " | {d} células cortadas em 32.767 caracteres";
pub const export_cut_cols = " | {d} colunas além da 16.384ª ficaram de fora";
pub const sql_more_rows = "Mais de {d} linhas: exibindo as primeiras {d} (a exportação grava todas)";
pub const sql_rows = "{d} linhas";
pub const sql_rows_one = "{d} linha";
pub const sql_cols = "{d} colunas";
pub const sql_cols_one = "{d} coluna";
pub const source_access_odbc = "Access ODBC";
pub const source_access_mdbtools = "mdbtools";

// erros
pub const canceled = "Cancelado";
pub const err_not_db = "Não é um arquivo de banco: use .accdb, .mdb, .sqlite, .sqlite3, .db ou .duckdb";
pub const err_cannot_write = "Não foi possível gravar o arquivo: ele está aberto em outro programa ou a pasta é somente leitura ({t})";
pub const err_generic = "Erro: {t}";
pub const err_sql = "Erro na consulta SQL: {s}";
pub const sql_read_only = "A aba SQL só lê o banco: este comando não é permitido";
pub const err_db = "Erro no banco: {s}";
pub const err_plain = "{s}";
pub const err_worker = "Não foi possível iniciar a tarefa em segundo plano: {t}";
pub const err_settings = "Não foi possível salvar as configurações: {t}";
pub const err_choose_other = "Escolha outro arquivo: este é o banco que está aberto";
pub const err_table_name_long = "Nome de tabela longo demais";
pub const err_save_sqlite = "Não foi possível salvar o arquivo SQLite: {t}";
pub const err_no_dialog = "Diálogo de arquivos indisponível (falta o zenity): digite o caminho na caixa";
pub const err_file_not_found = "Arquivo não encontrado";
pub const err_reader_name = "MDB2SQL_ACCESS_READER deve ser odbc, mdbtools ou auto";
pub const err_reader_forced = "O leitor do Access definido em MDB2SQL_ACCESS_READER não está disponível neste computador";
pub const err_no_reader = "Não é possível abrir arquivos Access: falta a pasta mdbtools ao lado do programa";
pub const err_temp_dir = "Não foi possível criar a pasta temporária {s} ({t})";
pub const err_tool_run = "{s} não pôde ser executado: {t}";
pub const err_tool_failed = "{s} falhou: {s}";
pub const err_export_table = "mdb-export falhou na tabela {s}";
pub const err_sqlite_missing = "Suporte a SQLite ausente: sqlite_scanner.duckdb_extension não está ao lado do programa";
pub const err_internal = "Erro interno, o programa será fechado:\n{s}";
pub const err_start = "O MDB2SQL não pôde iniciar: {t}{s}";
pub const err_opengl = "\nO driver de vídeo precisa suportar OpenGL 3.3 (área de trabalho remota ou máquina virtual sem 3D podem não suportar).";

// modo de exibicao no Linux (X11 primeiro, Wayland como reserva)
pub const display_title = "Modo de exibição";
pub const display_headline = "X11 indisponível; usando Wayland.";
pub const display_no_server = "Servidor X não definido (DISPLAY)";
pub const display_not_installed = "{s} não instalada";
pub const display_help = "Ajuda";
pub const display_none = "mdb2sql: não foi possível abrir a janela: nem X11 nem Wayland disponíveis ({t}). Ajuda: {s}\n";
pub const ok = "OK";

// dialogos de abrir e salvar
pub const dlg_databases = "Bancos de dados";
pub const dlg_all_files = "Todos os arquivos";

// ajuda da linha de comando (caixa de mensagem)
pub const usage =
    \\uso: mdb2sql-zig [arquivo.accdb|.mdb|.sqlite|.sqlite3|.db|.duckdb] [--table NOME] [--sql "SELECT ..."]
    \\                 [--search TEXTO] [--cell LINHA,COLUNA] [--theme system|dark|light] [--lang en|pt_br|es]
    \\                 [--about] [--menu NOME] [--export TIPO]
    \\  sem arquivo: a variável de ambiente MDB2SQL_DB_PATH, se existir
    \\  MDB2SQL_ACCESS_READER=odbc|mdbtools força o leitor de arquivos .accdb/.mdb
    \\  as opções definem o estado inicial: tabela selecionada, SQL a executar, pesquisa da aba Dados,
    \\  célula selecionada com o menu de cópia aberto, cores e idioma (só nesta execução),
    \\  Sobre aberto, um menu aberto (File, View, Settings, Help, Export)
    \\  --export db_sqlite|db_xlsx|db_duckdb|table_csv|table_xlsx|result_csv|result_xlsx
    \\  abre o diálogo de salvar dessa exportação quando o arquivo é carregado
    \\
;
