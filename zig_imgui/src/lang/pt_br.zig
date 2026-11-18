// Portugues (Brasil). Mesmas chaves de en.zig; textos com {..} recebem os mesmos argumentos na mesma ordem.

// janela principal
pub const path_hint = "arquivo do banco (.accdb, .mdb, .sqlite, .duckdb)";
pub const browse = "Procurar...";
pub const open = "Abrir";
pub const export_button = "Exportar...";
pub const no_db = "Nenhum banco aberto";
pub const filter_tables = "filtrar tabelas";
pub const search_rule = "Todas as palavras, em qualquer ordem, sem diferenciar maiúsculas e acentos";
pub const col_table = "Tabela";
pub const col_rows = "Linhas";
pub const tab_data = "Dados";
pub const tab_schema = "Esquema";
pub const tab_sql = "SQL";
pub const select_table = "Selecione uma tabela";
pub const search = "pesquisar";
pub const prev = "← Anterior";
pub const next = "Próxima →";
pub const columns_button = "Colunas...";
pub const columns_tip = "Colunas ocultas continuam na pesquisa e na exportação.";
pub const page_line = "{s}: página {d} de {d} | linhas {d}-{d} de {d}{s}{s}";
pub const filtered = " (filtrado)";
pub const hidden_one = " | 1 coluna oculta";
pub const hidden_many = " | {d} colunas ocultas";
pub const filters_label = "Filtros:";
pub const remove_filter = "Remover este filtro";
pub const clear_filters = "Limpar filtros";
pub const run = "Executar (Ctrl+Enter)";
pub const search_rows = "pesquisar nas linhas exibidas";
pub const rows_match = "{d} de {d} linhas encontradas{s}";
pub const schema_column = "Coluna";
pub const schema_type = "Tipo";
pub const schema_null = "Nulo";

// menus da grade e dialogo Colunas
pub const filter_by_value = "Filtrar por este valor";
pub const copy_value = "Copiar valor";
pub const copy_row = "Copiar linha (separada por TAB)";
pub const copy_header = "Copiar linha com o cabeçalho";
pub const hide_column = "Ocultar esta coluna";
pub const show_all = "Mostrar todas";
pub const hide_all = "Ocultar todas";
pub const columns_title = "Colunas";
pub const find_column = "procurar coluna";
pub const columns_shown = "{d} de {d} visíveis";

// menus
pub const menu_file = "Arquivo";
pub const menu_open = "Abrir...";
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
pub const menu_help = "Ajuda";
pub const menu_about = "Sobre o mdb2sql";
pub const export_db_sqlite = "Banco para SQLite (.sqlite)...";
pub const export_db_xlsx = "Banco para Excel (.xlsx, uma aba por tabela)...";
pub const export_db_duckdb = "Banco para DuckDB (.duckdb)...";
pub const export_table_csv = "Tabela atual para CSV...";
pub const export_table_xlsx = "Tabela atual para Excel (.xlsx)...";
pub const export_schema_csv = "Esquema da tabela atual para CSV...";
pub const export_schema_xlsx = "Esquema da tabela atual para Excel (.xlsx)...";
pub const export_result_csv = "Resultado do SQL para CSV...";
pub const export_result_xlsx = "Resultado do SQL para Excel (.xlsx)...";

// Sobre
pub const about_title = "Sobre o mdb2sql";
pub const about_tagline = "Abre bancos Access, SQLite e DuckDB, pesquisa e exporta para SQLite, Excel, CSV e DuckDB.";
pub const about_build = "Build";
pub const about_stack = "Tecnologia";
pub const about_window = "Janela";
pub const about_database = "Banco de dados";
pub const about_access = "Leitor do Access";
pub const about_access_win = "mdbtools {s} (incluído) ou o driver ODBC do Access, convertido uma vez para SQLite";
pub const about_access_unix = "mdbtools {s} (incluído), convertido uma vez para SQLite";
pub const about_author = "Autor";
pub const about_license = "Licença";
pub const about_license_text = "GPL v2 ou posterior (GPL-2.0-or-later)";
pub const about_open_browser = "Abrir no navegador";

// botoes comuns
pub const close = "Fechar";
pub const cancel = "Cancelar";
pub const save = "Salvar...";
pub const delete = "Apagar";
pub const copy = "Copiar";
pub const copy_all = "Copiar tudo";
pub const clear = "Limpar";

// SQLite convertido
pub const converted_title = "SQLite convertido";
pub const converted_text = "{s} foi convertido para SQLite para a leitura. Manter o arquivo convertido?";
pub const converted_save_tip = "Salva {s}.sqlite, por padrão ao lado do arquivo de origem";
pub const converted_saved = "SQLite salvo: {s}";
pub const converted_deleted = "SQLite convertido apagado";

// janela Log
pub const log_title = "Log";
pub const log_hide = "Recolher o log (Ctrl+L)";
pub const log_show = "Mostrar o log (Ctrl+L)";
pub const log_unread = "({d} novos)";

// trabalho em andamento
pub const busy_converting = "Convertendo o banco Access";
pub const busy_opening = "Abrindo o banco";
pub const busy_loading = "Carregando a tabela";
pub const busy_running = "Executando a consulta";
pub const busy_exporting = "Exportando";
pub const busy_elapsed = "{s} {d:.1} s";
pub const progress_overlay = "{d} / {d} {s}";
pub const unit_tables = "tabelas";
pub const unit_rows = "linhas";

// linha de status
pub const status_loaded = "Aberto: {s} ({d} tabelas) - lido com {s}";
pub const status_loaded_access = "Aberto: {s} ({d} tabelas) - lido com {s}, convertido para SQLite";
pub const status_closed = "Fechado: {s}";
pub const status_exported = "Exportadas {d} {s} para {s}{s}{s}";
pub const export_cut_cells = " | {d} células cortadas em 32.767 caracteres";
pub const export_cut_cols = " | {d} colunas além da 16.384ª ficaram de fora";
pub const sql_more_rows = "Mais de {d} linhas: exibindo as primeiras {d} (a exportação grava todas)";
pub const sql_rows_cols = "{d} linhas, {d} colunas";
pub const source_access_odbc = "Access ODBC";
pub const source_access_mdbtools = "mdbtools";

// erros
pub const canceled = "Cancelado";
pub const err_not_db = "Não é um arquivo de banco: use .accdb, .mdb, .sqlite, .sqlite3, .db ou .duckdb";
pub const err_cannot_write = "Não foi possível gravar o arquivo: ele está aberto em outro programa ou a pasta é somente leitura ({t})";
pub const err_generic = "Erro: {t}";
pub const err_sql = "Erro na consulta SQL: {s}";
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
