#[cfg(test)]
#[allow(clippy::module_inception)] // backend::tests::tests: the wrapper keeps the cfg(test) in this file
mod tests {
    use crate::backend::access::{self, Reader, choose_reader, parse_pg_schema, pg_to_duck};
    use crate::backend::converted;
    use crate::backend::db_manager::{DBManager, Filter, Step, search_condition, where_clause};
    use serde_json::json;
    use crate::backend::export::{self, EXCEL_MAX_DATA_ROWS, SheetNamer, Source, Summary};
    use crate::backend::sqlite_io::duck_type;
    use std::fs::File;
    use std::path::{Path, PathBuf};
    use tempfile::tempdir;

    fn no_progress() -> impl FnMut(Step, usize, usize, &str) {
        |_, _, _, _| {}
    }

    fn ok_progress() -> impl FnMut(usize, usize, &str) -> Result<(), String> {
        |_, _, _| Ok(())
    }

    // banco DuckDB pequeno com os tipos que importam (inteiro, texto com virgula/aspas, data, hora, decimal...)
    fn sample_duckdb(dir: &Path) -> PathBuf {
        let path = dir.join("real.duckdb");
        let conn = duckdb::Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE points (id INTEGER, name VARCHAR, ts TIMESTAMP, d DATE, t TIME, n DECIMAL(10,2), u UINTEGER, ok BOOLEAN, x DOUBLE);
             INSERT INTO points VALUES
               (1, 'a, \"b\"', TIMESTAMP '2026-07-14 10:00:00', DATE '2024-02-29', TIME '23:59:58.5', 12.30, 7, true, 0.1),
               (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
             CREATE TABLE \"Other table\" AS SELECT range AS k FROM range(5);",
        )
        .unwrap();
        path
    }

    #[test]
    fn validate_database_path_rejects_bad_ext() {
        let manager = DBManager::new();
        let dir = tempdir().unwrap();
        let path = dir.path().join("file.txt");
        File::create(&path).unwrap();

        let err = manager.validate_database_path(path.to_str().unwrap());
        assert!(err.unwrap_err().contains("[[err.unsupported]] ."));
    }

    // BRIEF secao 14: arquivo que nao existe, pasta ou caminho relativo (nunca resolvido contra a pasta do exe): so
    // "Arquivo nao encontrado: {caminho}", sem o texto do sistema (GetFileAttributesEx, os error...)
    #[test]
    fn missing_file_gives_only_the_short_not_found_message() {
        let manager = DBManager::new();
        let dir = tempdir().unwrap();
        let missing = dir.path().join("nao_existe.sqlite").to_string_lossy().into_owned();
        let folder = dir.path().join("data");
        std::fs::create_dir(&folder).unwrap();
        let folder = folder.to_string_lossy().into_owned();
        for path in [missing.as_str(), folder.as_str(), "data", r"data\sample.duckdb"] {
            assert_eq!(manager.connect(path, &mut no_progress()).err(), Some(format!("[[err.badPath]] {path}")), "{path}");
        }
    }

    #[test]
    fn load_sample_duckdb_lists_tables_and_rows() {
        let manager = DBManager::new();
        let path = PathBuf::from("../data/sample.duckdb");
        if !path.exists() {
            eprintln!("sample.duckdb not found, skipping");
            return;
        }
        let path = path.canonicalize().unwrap(); // caminho relativo nao abre (secao 14)
        manager.connect(path.to_str().unwrap(), &mut no_progress()).expect("connect sample");
        let tables = manager.list_tables().expect("list tables");
        assert!(!tables.is_empty(), "expected tables in sample.duckdb, got none");
        let rows = manager.query_table(&tables[0], 2, &[], "").expect("query rows");
        assert!(!rows.is_empty());
        assert!(manager.get_row_count(&tables[0], &[], "").unwrap() >= rows.len() as i64);
    }

    // Nao depende de data/sample.duckdb (ignorado pelo git): cria o banco no teste
    #[test]
    fn connect_opens_real_file_read_only() {
        let dir = tempdir().unwrap();
        let path = sample_duckdb(dir.path());

        let manager = DBManager::new();
        let source = manager.connect(path.to_str().unwrap(), &mut no_progress()).expect("connect").source;
        assert_eq!(source, "DuckDB");
        assert_eq!(manager.list_tables().unwrap(), vec!["Other table", "points"]);
        assert_eq!(manager.get_row_count("points", &[], "").unwrap(), 2);
        // coluna Linhas da lista de tabelas (padrao item 6), na ordem da lista
        assert_eq!(manager.table_rows(&manager.list_tables().unwrap()).unwrap(), [Some(5), Some(2)]);

        let schema = manager.get_table_schema("points").unwrap();
        let names: Vec<&str> = schema.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["id", "name", "ts", "d", "t", "n", "u", "ok", "x"]);

        let rows = manager.query_table("points", 10, &[], "").unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["id"], 1);
        assert!(rows[1]["name"].is_null());
        // datas e horas saem como texto ISO, nao na forma de debug do Rust
        assert_eq!(rows[0]["ts"], "2026-07-14 10:00:00");
        assert_eq!(rows[0]["d"], "2024-02-29");
        assert_eq!(rows[0]["t"], "23:59:58.5");
        assert_eq!(rows[0]["n"], "12.30");
        assert_eq!(rows[0]["u"], 7);
        assert!(manager.query_table("missing", 10, &[], "").is_err());

        // somente leitura: o SQL livre nao consegue gravar no arquivo aberto (recusado antes de rodar)
        let insert = manager.run_sql("INSERT INTO points VALUES (3, 'x', NULL, NULL, NULL, NULL, NULL, NULL, NULL)", 10);
        assert_eq!(insert.unwrap_err(), "[[err.sqlReadOnly]]");
        let result = manager.run_sql("SELECT id, name FROM points ORDER BY id", 1).unwrap();
        assert_eq!(result.columns.len(), 2);
        assert_eq!(result.rows.len(), 1);
        assert!(result.truncated);
    }

    // coluna Linhas: uma tabela que nao da para contar (view de um .duckdb sobre um CSV que sumiu) fica sem numero e o
    // arquivo abre mesmo assim; as outras tabelas tem o numero
    #[test]
    fn a_table_that_cannot_be_counted_does_not_stop_the_open() {
        let dir = tempdir().unwrap();
        let csv = dir.path().join("gone.csv");
        std::fs::write(&csv, "a\n1\n").unwrap();
        let path = dir.path().join("views.duckdb");
        let conn = duckdb::Connection::open(&path).unwrap();
        conn.execute_batch(&format!(
            "CREATE TABLE t AS SELECT range AS k FROM range(3); CREATE VIEW v AS SELECT * FROM read_csv('{}');",
            csv.to_string_lossy().replace('\'', "''")
        ))
        .unwrap();
        drop(conn);
        std::fs::remove_file(&csv).unwrap();
        let manager = DBManager::new();
        manager.connect(path.to_str().unwrap(), &mut no_progress()).unwrap();
        let tables = manager.list_tables().unwrap();
        assert_eq!(tables, ["t", "v"]);
        assert_eq!(manager.table_rows(&tables).unwrap(), [Some(3), None]);
    }

    fn filter(column: &str, value: serde_json::Value) -> Filter {
        Filter { column: column.to_string(), value }
    }

    // nome de coluna sempre citado (aspas dobradas), valor sempre por parametro, NULL vira IS NULL
    #[test]
    fn filter_sql_quotes_columns_and_binds_values() {
        use duckdb::types::Value as P;
        assert_eq!(where_clause(&[]).unwrap(), (String::new(), vec![]));
        let (sql, params) = where_clause(&[
            filter("si\"gla", json!("O'Brien \"x\"; DROP TABLE t --")),
            filter("gone", json!(null)),
            filter("id", json!(5)),
            filter("x", json!(0.5)),
            filter("ok", json!(true)),
        ])
        .unwrap();
        assert_eq!(sql, " WHERE \"si\"\"gla\" = ? AND \"gone\" IS NULL AND \"id\" = ? AND \"x\" = ? AND \"ok\" = ?");
        assert_eq!(
            params,
            vec![P::Text("O'Brien \"x\"; DROP TABLE t --".into()), P::BigInt(5), P::Double(0.5), P::Boolean(true)]
        );
        assert!(where_clause(&[filter("id", json!([1]))]).is_err());
    }

    // os mesmos filtros num arquivo DuckDB e num SQLite: texto com aspas, inteiro, NULL e a soma (AND)
    #[test]
    fn filters_run_in_the_query_on_duckdb_and_sqlite() {
        let dir = tempdir().unwrap();
        let ddl = "CREATE TABLE t (id INTEGER, \"si\"\"gla\" VARCHAR, note VARCHAR);
                   INSERT INTO t VALUES (1, 'U9A', 'a'), (2, 'O''Brien \"x\"', 'b'), (3, NULL, 'c'), (4, 'U9A', NULL), (5, 'u9a', 'a');";
        let duck = dir.path().join("f.duckdb");
        duckdb::Connection::open(&duck).unwrap().execute_batch(ddl).unwrap();
        let lite = dir.path().join("f.sqlite");
        rusqlite::Connection::open(&lite).unwrap().execute_batch(ddl).unwrap();

        for path in [duck, lite] {
            let manager = DBManager::new();
            manager.connect(path.to_str().unwrap(), &mut no_progress()).unwrap();
            let ids = |filters: &[Filter]| -> Vec<i64> {
                let rows = manager.query_table("t", 100, filters, "").unwrap();
                assert_eq!(manager.get_row_count("t", filters, "").unwrap(), rows.len() as i64, "{path:?}");
                rows.iter().map(|r| r["id"].as_i64().unwrap()).collect()
            };
            assert_eq!(ids(&[filter("si\"gla", json!("U9A"))]), [1, 4], "{path:?}"); // exato: 'u9a' fica fora
            assert_eq!(ids(&[filter("si\"gla", json!("O'Brien \"x\""))]), [2]);
            assert_eq!(ids(&[filter("si\"gla", json!(null))]), [3]);
            assert_eq!(ids(&[filter("id", json!(4))]), [4]);
            assert_eq!(ids(&[filter("si\"gla", json!("U9A")), filter("note", json!(null))]), [4]);
            // valor que seria injecao se fosse concatenado: e so um texto que nenhuma linha tem
            assert_eq!(ids(&[filter("si\"gla", json!("' OR 1=1 --"))]), Vec::<i64>::new());
            assert_eq!(manager.get_row_count("t", &[], "").unwrap(), 5);
            assert_eq!(manager.table_rows(&["t".to_string()]).unwrap(), [Some(5)], "{path:?}");
            // o limite Rows continua valendo com filtro
            assert_eq!(manager.query_table("t", 1, &[filter("si\"gla", json!("U9A"))], "").unwrap().len(), 1);
            assert!(manager.query_table("t", 10, &[filter("missing", json!(1))], "").is_err());
        }
    }

    // o valor volta como a grade mostrou (texto para data, hora, decimal) e compara no tipo da coluna
    #[test]
    fn filter_by_the_value_the_grid_shows_matches_every_type() {
        let dir = tempdir().unwrap();
        let manager = DBManager::new();
        manager.connect(sample_duckdb(dir.path()).to_str().unwrap(), &mut no_progress()).unwrap();
        let first = manager.query_table("points", 1, &[], "").unwrap().remove(0);
        for (column, value) in first.as_object().unwrap() {
            let filters = [filter(column, value.clone())];
            assert_eq!(manager.get_row_count("points", &filters, "").unwrap(), 1, "{column} = {value}");
        }
    }

    #[test]
    fn temporal_values_format_as_iso_text() {
        use crate::backend::db_manager::{format_date, format_time, format_timestamp};
        assert_eq!(format_timestamp(0), "1970-01-01 00:00:00");
        assert_eq!(format_timestamp(-1), "1969-12-31 23:59:59.999999");
        assert_eq!(format_timestamp(951_782_400_000_000), "2000-02-29 00:00:00");
        assert_eq!(format_date(-719_162), "0001-01-01");
        assert_eq!(format_date(19_782), "2024-02-29");
        assert_eq!(format_time(3_661_000_000), "01:01:01");
    }

    // exporta para .sqlite e .duckdb e reabre cada um pelo caminho normal: mesmas tabelas, linhas e tipos
    #[test]
    fn export_to_sqlite_and_duckdb_round_trips() {
        let dir = tempdir().unwrap();
        let manager = DBManager::new();
        manager.connect(sample_duckdb(dir.path()).to_str().unwrap(), &mut no_progress()).unwrap();
        let conn = manager.export_connection().unwrap();

        for (format, label) in [("sqlite", "SQLite"), ("duckdb", "DuckDB")] {
            let out = dir.path().join(format!("out.{format}"));
            let summary = export::export_database(&conn, format, &out, &mut ok_progress()).unwrap();
            assert_eq!(summary, Summary { count: 2, sheets: None });
            assert!(!dir.path().join(format!("out.{format}.partial")).exists());

            let reopened = DBManager::new();
            assert_eq!(reopened.connect(out.to_str().unwrap(), &mut no_progress()).unwrap().source, label);
            assert_eq!(reopened.list_tables().unwrap(), vec!["Other table", "points"]);
            assert_eq!(reopened.get_row_count("Other table", &[], "").unwrap(), 5);
            let types: Vec<String> = reopened.get_table_schema("points").unwrap().into_iter().map(|c| c.col_type).collect();
            assert_eq!(types, ["INTEGER", "VARCHAR", "TIMESTAMP", "DATE", "TIME", "DECIMAL(10,2)", "UINTEGER", "BOOLEAN", "DOUBLE"], "{format}");
            let rows = reopened.query_table("points", 10, &[], "").unwrap();
            assert_eq!(rows[0]["name"], "a, \"b\"");
            assert_eq!(rows[0]["ts"], "2026-07-14 10:00:00");
            assert_eq!(rows[0]["n"], "12.30");
            assert_eq!(rows[0]["ok"], true);
            assert_eq!(rows[0]["x"], 0.1);
            assert!(rows[1]["ts"].is_null());
        }
        // a exportacao nunca sobrescreve o banco aberto (o comando confere antes); um cancelamento apaga o .partial
        let out = dir.path().join("cancel.duckdb");
        let err = export::export_database(&conn, "duckdb", &out, &mut |_, _, _| Err("Export cancelled".into()));
        assert_eq!(err.unwrap_err(), "Export cancelled");
        assert!(!out.exists() && !dir.path().join("cancel.duckdb.partial").exists());
    }

    // .db com cabecalho de SQLite abre como SQLite
    #[test]
    fn db_extension_detects_sqlite_files() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("legacy.db");
        let lite = rusqlite::Connection::open(&path).unwrap();
        lite.execute_batch("CREATE TABLE t (a INTEGER, b TEXT, c); INSERT INTO t VALUES (1, 'x', 'free'), (2, NULL, 3.5);")
            .unwrap();
        drop(lite);
        let manager = DBManager::new();
        assert_eq!(manager.connect(path.to_str().unwrap(), &mut no_progress()).unwrap().source, "SQLite");
        assert_eq!(manager.get_row_count("t", &[], "").unwrap(), 2);
    }

    // coluna INTEGER com texto dentro (o SQLite deixa): a tabela entra inteira como texto
    #[test]
    fn sqlite_values_outside_declared_type_fall_back_to_text() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("loose.sqlite");
        let lite = rusqlite::Connection::open(&path).unwrap();
        lite.execute_batch("CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1), ('abc');").unwrap();
        drop(lite);
        let manager = DBManager::new();
        manager.connect(path.to_str().unwrap(), &mut no_progress()).unwrap();
        let rows = manager.query_table("t", 10, &[], "").unwrap();
        assert_eq!((rows[0]["a"].clone(), rows[1]["a"].clone()), ("1".into(), "abc".into()));
    }

    #[test]
    fn sqlite_declared_types_map_to_duckdb() {
        assert_eq!(duck_type("REAL_DECIMAL(19,4)"), "DECIMAL(19,4)");
        for (declared, duck) in [
            ("INTEGER", "INTEGER"),
            ("int(11)", "BIGINT"),
            ("NUMERIC(10, 0)", "DECIMAL(10,0)"),
            ("decimal(60,2)", "DOUBLE"),
            ("REAL", "DOUBLE"),
            ("TEXT", "VARCHAR"),
            ("", "VARCHAR"),
            ("DATETIME", "TIMESTAMP"),
            ("TIMESTAMP", "TIMESTAMP"),
            ("BOOLEAN", "BOOLEAN"),
            ("BLOB", "BLOB"),
            ("whatever", "VARCHAR"),
            ("UHUGEINT", "UHUGEINT"),
            ("TEXT_HUGE128", "HUGEINT"),
            ("TEXT_UBIG64", "UBIGINT"),
            ("TEXT_DECIMAL(38,10)", "DECIMAL(38,10)"),
        ] {
            assert_eq!(duck_type(declared), duck, "{declared}");
        }
    }

    #[test]
    fn sheet_names_follow_excel_rules_and_never_repeat() {
        let mut namer = SheetNamer::default();
        assert_eq!(namer.name("RANGER_SOSTAT", 1), "RANGER_SOSTAT");
        assert_eq!(namer.name("RANGER_SOSTAT", 2), "RANGER_SOSTAT (2)");
        // repetido sem diferenciar maiusculas
        assert_eq!(namer.name("ranger_sostat", 1), "ranger_sostat~2");
        // caracteres proibidos e apostrofos nas pontas
        assert_eq!(namer.name("a/b:c*d?e[f]g\\h", 1), "a_b_c_d_e_f_g_h");
        assert_eq!(namer.name("'quoted'", 1), "quoted");
        assert_eq!(namer.name("", 1), "Sheet");
        assert_eq!(namer.name("History", 1), "History~2");
        // corte em 31 (contando UTF-16) e colisao depois do corte
        let long = "A_VERY_LONG_TABLE_NAME_THAT_GOES_ON_1";
        let first = namer.name(long, 1);
        assert_eq!(first, "A_VERY_LONG_TABLE_NAME_THAT_GOE");
        let second = namer.name("A_VERY_LONG_TABLE_NAME_THAT_GOES_ON_2", 1);
        assert_eq!(second, "A_VERY_LONG_TABLE_NAME_THAT_G~2");
        let part = namer.name(long, 12);
        assert_eq!(part, "A_VERY_LONG_TABLE_NAME_THA (12)");
        let emoji = namer.name(&"\u{1F600}".repeat(20), 1);
        assert_eq!(emoji.encode_utf16().count(), 30);
        for name in [first, second, part, emoji] {
            assert!(name.encode_utf16().count() <= 31, "{name}");
        }
    }

    // tabela maior que o limite continua em "<nome> (2)", ...; sem linhas fica so o cabecalho
    #[test]
    fn rows_past_the_limit_continue_in_new_sheets() {
        let conn = duckdb::Connection::open_in_memory().unwrap();
        conn.execute_batch("CREATE TABLE big AS SELECT range AS id FROM range(5); CREATE TABLE empty (id INTEGER);").unwrap();
        let mut wb = rust_xlsxwriter::Workbook::new();
        let mut namer = SheetNamer::default();
        let mut tick = || Ok(());
        let sheets = export::write_sheets(&mut wb, &mut namer, &conn, "big", "SELECT * FROM big", &[], 2, &mut tick).unwrap();
        assert_eq!(sheets, [("big".to_string(), 2), ("big (2)".to_string(), 2), ("big (3)".to_string(), 1)]);
        let sheets = export::write_sheets(&mut wb, &mut namer, &conn, "empty", "SELECT * FROM empty", &[], 2, &mut tick).unwrap();
        assert_eq!(sheets, [("empty".to_string(), 0)]);
        assert_eq!(EXCEL_MAX_DATA_ROWS, 1_048_575);
        let dir = tempdir().unwrap();
        wb.save(dir.path().join("parts.xlsx")).unwrap();
    }

    // CSV: BOM UTF-8, cabecalho, virgula/aspas entre aspas, NULL vazio; xlsx de uma tabela e do banco
    #[test]
    fn table_and_result_exports_write_csv_and_xlsx() {
        let dir = tempdir().unwrap();
        let manager = DBManager::new();
        manager.connect(sample_duckdb(dir.path()).to_str().unwrap(), &mut no_progress()).unwrap();
        let conn = manager.export_connection().unwrap();

        let csv = dir.path().join("points.csv");
        let table = Source::Table("points".into());
        assert_eq!(export::export_source(&conn, &table, "csv", &csv, &mut ok_progress()).unwrap(), Summary { count: 2, sheets: None });
        let text = std::fs::read_to_string(&csv).unwrap();
        let mut lines = text.split("\r\n");
        assert_eq!(lines.next().unwrap(), "\u{FEFF}id,name,ts,d,t,n,u,ok,x");
        assert_eq!(lines.next().unwrap(), "1,\"a, \"\"b\"\"\",2026-07-14 10:00:00,2024-02-29,23:59:58.5,12.30,7,true,0.1");
        assert_eq!(lines.next().unwrap(), "2,,,,,,,,");

        // padrao item 17: "so as N linhas encontradas" = as linhas da grade com a pesquisa e os filtros (mesma regra da
        // contagem); CSV e Excel
        let (cond, params) = manager.rows_where("points", &[], "B").unwrap();
        assert_eq!(manager.get_row_count("points", &[], "B").unwrap(), 1);
        let found = Source::Rows("points".into(), cond, params);
        let found_csv = dir.path().join("found.csv");
        assert_eq!(export::export_source(&conn, &found, "csv", &found_csv, &mut ok_progress()).unwrap(), Summary { count: 1, sheets: None });
        let text = std::fs::read_to_string(&found_csv).unwrap();
        assert_eq!(text.split("\r\n").filter(|l| !l.is_empty()).count(), 2, "header and the one row found: {text}");
        let found_xlsx = dir.path().join("found.xlsx");
        assert_eq!(export::export_source(&conn, &found, "xlsx", &found_xlsx, &mut ok_progress()).unwrap(), Summary { count: 1, sheets: Some(1) });
        let (cond, params) = manager.rows_where("points", &[filter("id", json!(2))], "").unwrap();
        let by_value = Source::Rows("points".into(), cond, params);
        assert_eq!(export::export_source(&conn, &by_value, "csv", &found_csv, &mut ok_progress()).unwrap(), Summary { count: 1, sheets: None });
        assert!(std::fs::read_to_string(&found_csv).unwrap().contains("\r\n2,,,,,,,,\r\n"));
        assert!(manager.rows_where("missing", &[], "x").is_err());

        let sql = Source::Sql("SELECT k FROM \"Other table\" WHERE k > 2;".into());
        let xlsx = dir.path().join("result.xlsx");
        assert_eq!(export::export_source(&conn, &sql, "xlsx", &xlsx, &mut ok_progress()).unwrap(), Summary { count: 2, sheets: Some(1) });
        let all = dir.path().join("all.xlsx");
        assert_eq!(export::export_database(&conn, "xlsx", &all, &mut ok_progress()).unwrap(), Summary { count: 2, sheets: Some(2) });
        assert!(xlsx.metadata().unwrap().len() > 0 && all.metadata().unwrap().len() > 0);
    }

    #[test]
    fn access_reader_prefers_odbc_then_mdbtools() {
        let tools: Result<PathBuf, String> = Ok(PathBuf::from("cache"));
        let broken: Result<PathBuf, String> = Err("disk full".into());
        assert_eq!(choose_reader(None, true, &tools), Ok(Reader::Odbc));
        assert_eq!(choose_reader(None, false, &tools), Ok(Reader::Mdbtools));
        assert_eq!(choose_reader(Some(""), false, &tools), Ok(Reader::Mdbtools));
        assert_eq!(choose_reader(Some("MDBTOOLS"), true, &tools), Ok(Reader::Mdbtools));
        assert_eq!(choose_reader(Some("odbc"), true, &broken), Ok(Reader::Odbc));
        // sem nenhum: diz o que instalar
        let err = choose_reader(None, false, &broken).unwrap_err();
        assert!(err.contains("Microsoft Access Database Engine 2016 Redistributable") && err.contains("disk full"), "{err}");
        assert!(choose_reader(Some("odbc"), false, &tools).unwrap_err().contains("not installed"));
        assert!(choose_reader(Some("mdbtools"), true, &broken).unwrap_err().contains("disk full"));
        assert!(choose_reader(Some("jet"), true, &tools).unwrap_err().contains("must be odbc or mdbtools"));
        assert_eq!(Reader::Odbc.label(), "Access ODBC");
        assert_eq!(Reader::Mdbtools.label(), "mdbtools");
    }

    #[test]
    fn mdb_schema_types_map_to_duckdb() {
        let sql = "CREATE TABLE IF NOT EXISTS \"ranger_sostat\"\n (\n\t\"rtuno\"\t\t\tNUMERIC (10, 0), \n\t\"pntnam\"\t\t\tVARCHAR (48), \n\
                   \t\"intrat\"\t\t\tDOUBLE PRECISION, \n\t\"when\"\t\t\tTIMESTAMP WITHOUT TIME ZONE, \n\t\"pic\"\t\t\tBYTEA, \n\
                   \t\"ok\"\t\t\tBOOLEAN\n);\n\nCREATE TABLE IF NOT EXISTS \"other\"\n (\n\t\"memo\"\t\t\tTEXT\n);\n";
        let tables = parse_pg_schema(sql);
        assert_eq!(tables["ranger_sostat"], ["DECIMAL(10,0)", "VARCHAR", "DOUBLE", "TIMESTAMP", "BLOB", "BOOLEAN"]);
        assert_eq!(tables["other"], ["VARCHAR"]);
        assert_eq!(pg_to_duck("REAL"), "FLOAT");
        assert_eq!(pg_to_duck("SERIAL"), "INTEGER");
        assert_eq!(pg_to_duck("NUMERIC (60, 2)"), "DOUBLE");
        // Moeda: o mdbtools declara NUMERIC(15,2) mas exporta 4 casas
        assert_eq!(pg_to_duck("NUMERIC(15,2)"), "DECIMAL(19,4)");
        assert_eq!(pg_to_duck("NUMERIC (15, 2)"), "DECIMAL(15,2)");
    }

    // Banco Access real (fora do git): MDB2SQL_TEST_ACCDB=<copia do .accdb> e MDB2SQL_TEST_DUCKDB=<conversao de
    // referencia .duckdb>; MDB2SQL_TEST_SQLITE=<referencia .sqlite> (opcional). Abre pelo mdbtools (e pelo ODBC se
    // o driver existir), confere tabelas e linhas do SQLite convertido contra as referencias, compara os leitores
    // celula a celula e testa a pesquisa na tabela inteira. Sem as variaveis o teste nao faz nada.
    #[test]
    fn real_access_file_converts_to_sqlite_like_the_reference() {
        let (Ok(accdb), Ok(reference)) = (std::env::var("MDB2SQL_TEST_ACCDB"), std::env::var("MDB2SQL_TEST_DUCKDB")) else {
            eprintln!("MDB2SQL_TEST_ACCDB/MDB2SQL_TEST_DUCKDB not set, skipping");
            return;
        };
        let reference_sqlite = std::env::var("MDB2SQL_TEST_SQLITE").ok();
        let conn = duckdb::Connection::open_in_memory().unwrap();
        conn.execute_batch(&format!("ATTACH '{reference}' AS ref (READ_ONLY)")).unwrap();
        let tables: Vec<String> = conn
            .prepare("SELECT table_name FROM duckdb_tables() WHERE database_name = 'ref' ORDER BY 1")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        let q = |t: &str| format!("\"{}\"", t.replace('"', "\"\""));
        let count = |sql: String| -> i64 { conn.query_row(&sql, [], |r| r.get(0)).unwrap_or_else(|e| panic!("{sql}: {e}")) };
        let lite_count = |lite: &rusqlite::Connection, t: &str| -> i64 {
            lite.query_row(&format!("SELECT count(*) FROM {}", q(t)), [], |r| r.get(0)).unwrap_or_else(|e| panic!("{t}: {e}"))
        };
        let reference_lite = reference_sqlite.as_ref().map(|p| rusqlite::Connection::open(p).unwrap());

        let dir = tempdir().unwrap();
        let readers: Vec<&str> = if access::odbc_installed() { vec!["mdbtools", "odbc"] } else { vec!["mdbtools"] };
        for reader in &readers {
            let manager = DBManager::new();
            let started = std::time::Instant::now();
            // tempo de cada etapa (ler o Access, gravar o SQLite, carregar), para o README
            let mut step_started = (Step::Read, std::time::Instant::now());
            let opened = manager
                .connect_with(&accdb, Some(reader), &mut |step, _, _, _| {
                    if step != step_started.0 {
                        eprintln!("{reader} {:?}: {:?}", step_started.0, step_started.1.elapsed());
                        step_started = (step, std::time::Instant::now());
                    }
                })
                .unwrap();
            eprintln!("{reader} {:?}: {:?}", step_started.0, step_started.1.elapsed());
            let lite_path = opened.converted.as_ref().expect("Access opens through a converted SQLite").path().to_path_buf();
            let lite = rusqlite::Connection::open_with_flags(&lite_path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
            let lite_tables: Vec<String> = lite
                .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
                .unwrap()
                .query_map([], |r| r.get(0))
                .unwrap()
                .collect::<Result<_, _>>()
                .unwrap();
            assert_eq!(lite_tables, tables, "{reader}: tables of the converted SQLite");
            let mut rows = 0;
            for t in &tables {
                let expected = count(format!("SELECT count(*) FROM ref.{}", q(t)));
                assert_eq!(lite_count(&lite, t), expected, "{reader} {t}");
                if let Some(other) = &reference_lite {
                    assert_eq!(lite_count(other, t), expected, "reference .sqlite x .duckdb {t}");
                }
                assert_eq!(manager.get_row_count(t, &[], "").unwrap(), expected, "{reader} session {t}");
                rows += expected;
            }
            eprintln!(
                "{reader}: {}, {} tables, {rows} rows = reference, in {:?}",
                opened.source,
                tables.len(),
                started.elapsed()
            );
            drop(lite);
            let out = dir.path().join(format!("{reader}.duckdb"));
            export::export_database(&manager.export_connection().unwrap(), "duckdb", &out, &mut ok_progress()).unwrap();
            conn.execute_batch(&format!("ATTACH '{}' AS {reader} (READ_ONLY)", out.display())).unwrap();

            // pesquisa na tabela inteira: termo alem das 100 primeiras linhas, todas as palavras na mesma celula
            if *reader == "mdbtools" {
                let mut found = Vec::new();
                for t in &tables {
                    let hits = manager.get_row_count(t, &[], "tension de campo").unwrap();
                    if hits > 0 {
                        let first_page = manager.query_table(t, 100, &[], "").unwrap();
                        let in_first_page = first_page.iter().any(|row| {
                            row.as_object().unwrap().values().any(|v| v.as_str().is_some_and(|s| s.contains("TENSION DE CAMPO")))
                        });
                        assert_eq!(manager.query_table(t, 1000, &[], "campo TENSIÓN").unwrap().len() as i64, hits, "{t}");
                        found.push((t.clone(), hits, in_first_page));
                    }
                }
                eprintln!("search \"tension de campo\": {found:?}");
                assert!(found.iter().any(|(_, _, first)| !first), "a hit beyond the first 100 rows");
                // "Todas as tabelas" acha as mesmas tabelas com as mesmas contagens (o termo so existe em texto)
                let started = std::time::Instant::now();
                let mut everywhere: Vec<(String, i64)> =
                    manager.search_tables("tension de campo", &|| false).unwrap().into_iter().map(|f| (f.table, f.count)).collect();
                eprintln!("search in all {} tables: {:?}", tables.len(), started.elapsed());
                everywhere.sort();
                let mut expected: Vec<(String, i64)> = found.iter().map(|(t, n, _)| (t.clone(), *n)).collect();
                expected.sort();
                assert_eq!(everywhere, expected);
                // adendo: o ponto RTUNO 50 / PNTNO 9 (texto em espanhol) e achado por "tension de campo" e nao por
                // "tensao de campo" (portugues; sem busca aproximada). Outras linhas do DB4 tem TENSÃO em portugues.
                if tables.iter().any(|t| t == "RANGER_SOANLG") {
                    let point = [filter("RTUNO", json!(50)), filter("PNTNO", json!(9))];
                    let rows = manager.query_table("RANGER_SOANLG", 10, &point, "tension de campo").unwrap();
                    eprintln!("RANGER_SOANLG RTUNO 50 PNTNO 9: {rows:?}");
                    assert!(!rows.is_empty());
                    assert_eq!(manager.get_row_count("RANGER_SOANLG", &point, "tensao de campo").unwrap(), 0);
                }
            }
        }
        if readers.len() == 2 {
            let mut differences = Vec::new();
            for t in &tables {
                let t = q(t);
                let diff = count(format!(
                    "SELECT count(*) FROM ((SELECT * FROM odbc.{t} EXCEPT ALL SELECT * FROM mdbtools.{t}) \
                     UNION ALL (SELECT * FROM mdbtools.{t} EXCEPT ALL SELECT * FROM odbc.{t}))"
                ));
                if diff != 0 {
                    differences.push(format!("{t}: {diff}"));
                }
            }
            eprintln!("{} tables, readers differ in: {differences:?}", tables.len());
            assert!(differences.is_empty(), "{differences:?}");
        }
    }

    // .mdb pequeno versionado (tests/data/sample.mdb, scripts/make_test_mdb.ps1): pelo mdbtools vira um SQLite
    // com os tipos e os NULL preservados, e o app le dali. Roda em qualquer maquina com o mdbtools (embutido ou PATH).
    #[test]
    fn sample_mdb_converts_to_sqlite_with_types_and_nulls() {
        let manager = DBManager::new();
        // caminho completo: relativo nao abre (BRIEF secao 14)
        let mdb = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests").join("data").join("sample.mdb");
        let opened = manager.connect_with(mdb.to_str().unwrap(), Some("mdbtools"), &mut no_progress()).unwrap();
        assert_eq!(opened.source, "mdbtools → SQLite");
        assert_eq!(manager.list_tables().unwrap(), ["Empty", "Sample Types"]);
        assert_eq!(manager.get_row_count("Empty", &[], "").unwrap(), 0);

        let lite_path = opened.converted.as_ref().unwrap().path().to_path_buf();
        assert!(lite_path.starts_with(&converted::temp_dirs(None)[0]));
        let lite = rusqlite::Connection::open_with_flags(&lite_path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        let declared: Vec<(String, String)> = lite
            .prepare("SELECT name, type FROM pragma_table_info('Sample Types')")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        let declared: Vec<String> = declared.into_iter().map(|(n, t)| format!("{n} {t}")).collect();
        assert_eq!(
            declared,
            [
                "id INTEGER",
                "tiny SMALLINT",
                "small INTEGER",
                "price REAL_DECIMAL(19,4)",
                "exact TEXT_DECIMAL(18,4)",
                "ratio DOUBLE",
                "name VARCHAR",
                "note VARCHAR",
                "happened TIMESTAMP",
                "flag BOOLEAN",
                "raw BLOB"
            ]
        );
        // no arquivo: decimal exato como texto, NULL como NULL, binario como BLOB
        let (exact, raw, null_name): (String, Vec<u8>, Option<String>) = lite
            .query_row(
                "SELECT exact, raw, (SELECT name FROM \"Sample Types\" WHERE id = 2) FROM \"Sample Types\" WHERE id = 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!((exact.as_str(), raw, null_name), ("12345678901234.5683", vec![0, 1, 254, 255], None));
        // Moeda que cabe num DOUBLE vai como numero: o sqlite3 compara e soma como numero (nao como texto)
        let (price_type, over_20, total): (String, i64, f64) = lite
            .query_row(
                "SELECT (SELECT typeof(price) FROM \"Sample Types\" WHERE id = 1), count(*), sum(price) FROM \"Sample Types\" WHERE price > 20",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!((price_type.as_str(), over_20, total), ("real", 1, 1234567.8912));
        // o decimal de 18 digitos nao cabe num DOUBLE: fica texto exato
        let exact_type: String = lite.query_row("SELECT typeof(exact) FROM \"Sample Types\" WHERE id = 1", [], |r| r.get(0)).unwrap();
        assert_eq!(exact_type, "text");
        drop(lite);

        // o que o app mostra veio do SQLite e tem os tipos do Access
        let schema: Vec<String> = manager.get_table_schema("Sample Types").unwrap().into_iter().map(|c| c.col_type).collect();
        assert_eq!(
            schema,
            [
                "INTEGER", "SMALLINT", "INTEGER", "DECIMAL(19,4)", "DECIMAL(18,4)", "DOUBLE", "VARCHAR", "VARCHAR",
                "TIMESTAMP", "BOOLEAN", "BLOB"
            ]
        );
        let rows = manager.query_table("Sample Types", 10, &[], "").unwrap();
        assert_eq!(rows.len(), 3);
        let first = &rows[0];
        assert_eq!(first["id"], json!(1));
        assert_eq!(first["tiny"], json!(255));
        assert_eq!(first["price"], json!("1234567.8912"));
        assert_eq!(first["exact"], json!("12345678901234.5683"));
        assert_eq!(first["ratio"], json!(0.1));
        assert_eq!(first["name"], json!("Ação, \"aspas\""));
        assert_eq!(first["note"].as_str().unwrap().lines().collect::<Vec<_>>(), ["linha 1", "linha 2"]);
        assert_eq!(first["happened"], json!("2026-07-14 10:30:05"));
        assert_eq!(first["flag"], json!(true));
        // NULL do Access continua NULL (o Sim/Nao do Access nunca e nulo)
        let second = rows[1].as_object().unwrap();
        for (column, value) in second {
            match column.as_str() {
                "id" => assert_eq!(value, &json!(2)),
                "flag" => assert_eq!(value, &json!(false)),
                _ => assert_eq!(value, &json!(null), "{column}"),
            }
        }
        assert_eq!(rows[2]["happened"], json!("1899-12-30 00:00:00"));
        assert_eq!(rows[2]["price"], json!("-0.0001"));
        // shortcut: o mdbtools exporta texto vazio igual a NULL (limite do mdb-export); o ODBC le ""
        assert_eq!(rows[2]["name"], json!(null));

        // pesquisa no banco: palavras na mesma celula, sem acento e sem maiusculas
        assert_eq!(manager.get_row_count("Sample Types", &[], "acao ASPAS").unwrap(), 1);
        assert_eq!(manager.get_row_count("Sample Types", &[], "acao linha").unwrap(), 0);

        // o temporario some quando o Converted vai embora (Apagar, fechar ou sair)
        drop(opened);
        assert!(!lite_path.exists());
    }

    // Moeda/decimal no SQLite convertido: quem abre o arquivo no sqlite3 (ou outro programa) compara e soma como
    // numero, nao como texto. nwind.mdb do mdbtestdata (copia fora do git): MDB2SQL_TEST_NWIND=<copia>.
    // Esperado (Products.UnitPrice, Moeda): 37 linhas > 20, soma 1695.11, maiores 263.5, 123.79, 97.0
    #[test]
    fn currency_in_the_converted_sqlite_compares_as_a_number() {
        let Ok(nwind) = std::env::var("MDB2SQL_TEST_NWIND") else {
            eprintln!("MDB2SQL_TEST_NWIND not set, skipping");
            return;
        };
        let manager = DBManager::new();
        let opened = manager.connect_with(&nwind, Some("mdbtools"), &mut no_progress()).unwrap();
        let lite = rusqlite::Connection::open_with_flags(
            opened.converted.as_ref().unwrap().path(),
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .unwrap();
        let declared: String =
            lite.query_row("SELECT type FROM pragma_table_info('Products') WHERE name = 'UnitPrice'", [], |r| r.get(0)).unwrap();
        let types: Vec<(String, i64)> = lite
            .prepare("SELECT typeof(UnitPrice), count(*) FROM Products GROUP BY 1 ORDER BY 1")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        let (count, sum): (i64, f64) =
            lite.query_row("SELECT count(*), sum(UnitPrice) FROM Products WHERE UnitPrice > 20", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        let top: Vec<rusqlite::types::Value> = lite
            .prepare("SELECT UnitPrice FROM Products ORDER BY UnitPrice DESC LIMIT 3")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        eprintln!("sqlite3: UnitPrice {declared}, typeof {types:?}, > 20: {count} rows, sum {sum:.2}, top {top:?}");
        // a mesma conta na aba SQL do app (DuckDB sobre o SQLite carregado)
        let app = manager
            .run_sql("SELECT count(*) AS n, sum(UnitPrice) AS s FROM Products WHERE UnitPrice > 20", 10)
            .unwrap();
        let app_top = manager.run_sql("SELECT UnitPrice FROM Products ORDER BY UnitPrice DESC LIMIT 3", 10).unwrap();
        eprintln!("app SQL tab: {:?} top {:?}", app.rows, app_top.rows);
        assert_eq!(types, [("real".to_string(), 77)]);
        assert_eq!((count, format!("{sum:.2}")), (37, "1695.11".to_string()));
        assert_eq!(top, [263.5, 123.79, 97.0].map(rusqlite::types::Value::Real));
        assert_eq!(app.rows[0]["n"], json!(37));
        assert_eq!(app.rows[0]["s"], json!("1695.1100"));
        let app_top: Vec<&serde_json::Value> = app_top.rows.iter().map(|r| &r["UnitPrice"]).collect();
        assert_eq!(app_top, [&json!("263.5000"), &json!("123.7900"), &json!("97.0000")]);
    }

    // REGRA_DESEMPENHO: um caso por processo (o pico de memoria e do processo inteiro). Roda so com
    // MDB2SQL_BENCH_CASE = odbc | mdbtools | open | export_sqlite | export_duckdb e MDB2SQL_BENCH_PATH = arquivo;
    // MDB2SQL_BENCH_SAVE = onde copiar o SQLite convertido (para medir depois o "reabrir o SQLite salvo").
    // Imprime "BENCH caso lista=s tabela1=s total=s pico_mb=N" (scripts de medicao no tmp, nao no repo).
    #[test]
    fn bench_open_protocol() {
        let (Ok(case), Ok(path)) = (std::env::var("MDB2SQL_BENCH_CASE"), std::env::var("MDB2SQL_BENCH_PATH")) else {
            return;
        };
        let started = std::time::Instant::now();
        let manager = DBManager::new();
        let reader = match case.as_str() {
            "odbc" | "mdbtools" => Some(case.as_str()),
            _ => None,
        };
        let opened = manager.connect_with(&path, reader, &mut no_progress()).unwrap();
        let tables = manager.list_tables().unwrap();
        let list = started.elapsed().as_secs_f64();
        // primeira tabela visivel: o que a tela pede ao abrir (esquema, 100 linhas, contagem)
        manager.get_table_schema(&tables[0]).unwrap();
        manager.query_table(&tables[0], 100, &[], "").unwrap();
        manager.get_row_count(&tables[0], &[], "").unwrap();
        let first = started.elapsed().as_secs_f64();
        let mut total = first;
        if let Some(format) = case.strip_prefix("export_") {
            let out = tempdir().unwrap();
            let t = std::time::Instant::now();
            export::export_database(&manager.export_connection().unwrap(), format, &out.path().join(format!("x.{format}")), &mut ok_progress())
                .unwrap();
            total = t.elapsed().as_secs_f64(); // so a exportacao
        }
        if let (Ok(save), Some(lite)) = (std::env::var("MDB2SQL_BENCH_SAVE"), opened.converted.as_ref()) {
            std::fs::copy(lite.path(), save).unwrap();
        }
        let peak = if cfg!(windows) {
            let out = std::process::Command::new("powershell")
                .args(["-NoProfile", "-Command", &format!("(Get-Process -Id {}).PeakWorkingSet64", std::process::id())])
                .output()
                .unwrap();
            String::from_utf8_lossy(&out.stdout).trim().parse::<u64>().unwrap_or(0) / 1_048_576
        } else {
            0
        };
        println!("BENCH {case} lista={list:.1} tabela1={first:.1} total={total:.1} pico_mb={peak} tabelas={}", tables.len());
    }

    // REGRA_X11: (ambiente, os-release, servidor X) -> (backend, aviso)
    #[test]
    fn linux_display_prefers_x11_and_warns_on_wayland_fallback() {
        use crate::backend::display::{BACKENDS, Decision, DisplayWarning, HELP_LINK, decide};
        let run = |vars: &[(&str, &str)], os: &str, x_alive: bool| {
            let vars: Vec<(String, String)> = vars.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
            let env = move |name: &str| vars.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone());
            decide(&env, os, &|socket| {
                assert_eq!(socket, "/tmp/.X11-unix/X0");
                x_alive
            })
        };
        let debian = "PRETTY_NAME=\"Debian GNU/Linux 13 (trixie)\"\nID=debian\n";
        let warning = |missing, display: &str, distro: &str, command| Decision::Use {
            backend: BACKENDS,
            warning: Some(DisplayWarning { missing, display: display.into(), distro: distro.into(), command, link: HELP_LINK }),
        };
        // escolha do usuario: respeitada, sem aviso
        assert_eq!(run(&[("GDK_BACKEND", "wayland")], debian, false), Decision::UserChoice);
        // X11 respondendo: x11 primeiro, sem aviso; DISPLAY remoto nao e testado
        assert_eq!(run(&[("DISPLAY", ":0")], debian, true), Decision::Use { backend: "x11,wayland", warning: None });
        assert_eq!(run(&[("DISPLAY", "host:10")], debian, false), Decision::Use { backend: BACKENDS, warning: None });
        // sem DISPLAY, com Wayland: reserva + aviso com o comando da distro
        let wayland = [("WAYLAND_DISPLAY", "wayland-0")];
        assert_eq!(
            run(&wayland, debian, true),
            warning("no_display", "", "Debian GNU/Linux 13 (trixie)", Some("sudo apt install xwayland"))
        );
        // DISPLAY definido mas sem servidor X
        assert_eq!(
            run(&[("DISPLAY", ":0.0"), ("WAYLAND_DISPLAY", "wayland-0")], debian, false),
            warning("no_server", ":0.0", "Debian GNU/Linux 13 (trixie)", Some("sudo apt install xwayland"))
        );
        let families = [
            ("PRETTY_NAME=\"Ubuntu 24.04 LTS\"\nID=ubuntu\nID_LIKE=debian\n", Some("sudo apt install xwayland")),
            ("PRETTY_NAME=\"Fedora Linux 43\"\nID=fedora\n", Some("sudo dnf install xorg-x11-server-Xwayland")),
            ("PRETTY_NAME=\"Rocky Linux 10\"\nID=\"rocky\"\nID_LIKE=\"rhel centos fedora\"\n", Some("sudo dnf install xorg-x11-server-Xwayland")),
            ("PRETTY_NAME=\"Arch Linux\"\nID=arch\n", Some("sudo pacman -S xorg-xwayland")),
            ("PRETTY_NAME=\"openSUSE Tumbleweed\"\nID=\"opensuse-tumbleweed\"\nID_LIKE=\"opensuse suse\"\n", Some("sudo zypper install xwayland")),
            ("PRETTY_NAME=\"NixOS 25.11\"\nID=nixos\n", None),
        ];
        for (os, command) in families {
            let Decision::Use { warning: Some(w), .. } = run(&wayland, os, true) else { panic!("{os}") };
            assert_eq!(w.command, command, "{os}");
            assert!(os.contains(&w.distro), "{os}");
        }
        assert_eq!(run(&wayland, "", true), warning("no_display", "", "Linux", None));
        // sem X11 e sem Wayland: erro (o processo sai com codigo 1)
        assert_eq!(run(&[], debian, false), Decision::NoDisplay);
        assert_eq!(run(&[("DISPLAY", ":0")], debian, false), Decision::NoDisplay);
    }

    // Salvar copia o SQLite convertido (gravacao segura de main.rs save_converted); erro deixa o temporario; o
    // temporario some quando o Converted vai embora (salvo, fechar, abrir outro, sair); restos de processos mortos somem
    #[test]
    fn converted_sqlite_is_saved_discarded_and_cleaned() {
        let dir = tempdir().unwrap();
        let path = converted::new_temp_path("t.sqlite", None).unwrap();
        rusqlite::Connection::open(&path).unwrap().execute_batch("CREATE TABLE t (x)").unwrap();
        let lite = converted::Converted::new(path);
        let temp = lite.path().to_path_buf();
        let copy = |target: &Path| export::via_partial(target, |partial| std::fs::copy(lite.path(), partial).map(|_| ()).map_err(|e| e.to_string()));
        let target = dir.path().join("saved.sqlite");
        copy(&target).unwrap();
        assert!(target.is_file() && temp.is_file());
        assert!(copy(&dir.path().join("missing folder").join("x.sqlite")).is_err());
        assert!(temp.is_file(), "a failed save keeps the temporary");
        drop(lite);
        assert!(!temp.exists());
        let saved = rusqlite::Connection::open(&target).unwrap();
        assert_eq!(saved.query_row("SELECT count(*) FROM t", [], |r| r.get::<_, i64>(0)).unwrap(), 0);

        // limpeza da proxima abertura: so arquivos "<pid>-..." de processo que nao existe mais; os deste ficam
        let stale = dir.path().join("4294967294-1-old.sqlite");
        let own = dir.path().join(format!("{}-1-mine.sqlite", std::process::id()));
        let other = dir.path().join("notes.txt");
        for f in [&stale, &own, &other] {
            File::create(f).unwrap();
        }
        assert_eq!(converted::clean_stale(dir.path()), 1);
        assert!(!stale.exists() && own.exists() && other.exists());
        converted::remove_own(dir.path());
        assert!(!own.exists() && other.exists());
    }

    // padrao item 22: a chave (caminho, tamanho, data) reconhece o mesmo arquivo sem mudanca entre execucoes; mudou o
    // conteudo ou a data, a chave muda e o Access e convertido de novo
    #[test]
    fn file_key_changes_when_the_file_changes() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("Banco.accdb");
        std::fs::write(&path, b"abc").unwrap();
        let key = converted::file_key(&path).expect("key of an existing file");
        assert_eq!(converted::file_key(&path), Some(key.clone()), "same file, same key");
        // o mesmo arquivo por outro caminho (relativo, com ..) da a mesma chave
        let other_way = dir.path().join("sub").join("..").join("Banco.accdb");
        std::fs::create_dir(dir.path().join("sub")).unwrap();
        assert_eq!(converted::file_key(&other_way), Some(key.clone()));
        assert!(key.contains("|3|"), "{key}"); // tamanho em bytes
        if cfg!(windows) {
            assert_eq!(key, key.to_lowercase(), "Windows: path in lowercase");
        }
        std::fs::write(&path, b"abcd").unwrap();
        assert_ne!(converted::file_key(&path), Some(key), "changed file, new key");
        assert_eq!(converted::file_key(&dir.path().join("missing.accdb")), None);
        assert_eq!(converted::file_key(dir.path()), None, "a folder has no key");
    }

    // nomes de temporario reservados de forma exclusiva: chamadas seguidas nunca repetem nem reaproveitam arquivo
    #[test]
    fn temporary_names_are_reserved_exclusively() {
        let a = converted::new_temp_path("x.csv", None).unwrap();
        let b = converted::new_temp_path("x.csv", None).unwrap();
        assert_ne!(a, b);
        assert!(a.is_file() && b.is_file());
        let _ = std::fs::remove_file(a);
        let _ = std::fs::remove_file(b);
    }

    #[test]
    fn search_matches_all_words_in_one_cell_ignoring_case_and_accents() {
        let col = |name: &str, kind: &str| (name.to_string(), kind.to_string());
        assert!(search_condition(&[col("a", "VARCHAR")], "   ").is_none());
        let (sql, params) = search_condition(&[col("co\"l", "VARCHAR"), col("b", "INTEGER")], "1 2").unwrap();
        assert_eq!(params.len(), 4);
        assert!(sql.contains("CAST(\"co\"\"l\" AS VARCHAR)") && sql.contains(" OR ") && sql.contains(" AND "), "{sql}");
        // numero ja sai em minusculas e sem acento: sem lower(strip_accents()) na celula (so nas palavras)
        assert!(sql.contains("contains(lower(strip_accents(CAST(\"co\"\"l\" AS VARCHAR)))") && sql.contains("contains(CAST(\"b\" AS VARCHAR)"), "{sql}");
        // palavra com letra que numero, data e booleano nunca escrevem ("campo"): essas colunas ficam fora; sem coluna, FALSE
        let (sql, params) = search_condition(&[col("n", "INTEGER"), col("s", "VARCHAR")], "campo 7").unwrap();
        assert!(!sql.contains("\"n\"") && sql.contains("\"s\"") && params.len() == 2, "{sql}");
        assert_eq!(search_condition(&[col("n", "DATE")], "campo").unwrap().0, "FALSE");
        // cada tipo com os seus caracteres: "U9A" nao cabe em numero, data, hora nem booleano; "238" so nao cabe em booleano
        let kinds = ["INTEGER", "DECIMAL(10,0)", "DOUBLE", "DATE", "TIME", "TIMESTAMP", "BOOLEAN"].map(|kind| col(kind, kind));
        assert_eq!(search_condition(&kinds, "U9A").unwrap().0, "FALSE");
        let (sql, _) = search_condition(&kinds, "238").unwrap();
        assert!(!sql.contains("\"BOOLEAN\"") && sql.matches("CAST(").count() == 6, "{sql}");
        for (kind, word) in [("DOUBLE", "1E+20"), ("DOUBLE", "-inf"), ("BOOLEAN", "False"), ("TIMESTAMP", "10:00:00+00"), ("BOOLEAN", "fálse")] {
            assert!(search_condition(&[col("n", kind)], word).unwrap().0.contains("\"n\""), "{kind} {word}");
        }
        let dir = tempdir().unwrap();
        let path = dir.path().join("s.duckdb");
        duckdb::Connection::open(&path)
            .unwrap()
            .execute_batch(
                "CREATE TABLE t AS SELECT range AS id, CASE WHEN range = 500 THEN 'EXCITAÇÃO TENSÃO DE CAMPO' \
                 ELSE 'outro' END AS label, CASE WHEN range = 501 THEN 'campo' END AS a, \
                 CASE WHEN range = 501 THEN 'tensao' END AS b FROM range(1000)",
            )
            .unwrap();
        let manager = DBManager::new();
        manager.connect(path.to_str().unwrap(), &mut no_progress()).unwrap();
        // linha 500 nao esta nas 100 carregadas, mas a pesquisa roda na tabela inteira
        assert_eq!(manager.get_row_count("t", &[], "campo tensao").unwrap(), 1, "same cell only (501 splits the words)");
        assert_eq!(manager.query_table("t", 100, &[], "Tensão campo").unwrap()[0]["id"], json!(500));
        assert_eq!(manager.get_row_count("t", &[], "50").unwrap(), 20, "numbers match as text: 50, 150..950, 500..509");
        assert_eq!(manager.get_row_count("t", &[filter("label", json!("outro"))], "campo").unwrap(), 1);
        assert_eq!(manager.get_row_count("t", &[], "zzz").unwrap(), 0);
    }

    // "Todas as tabelas": mesma regra da pesquisa de uma tabela (todas as palavras numa celula, sem maiusculas nem
    // acentos), em todas as colunas (numeros como texto, como nas outras 3 versoes), na ordem da lista; DuckDB anexado e
    // SQLite copiado para a memoria
    #[test]
    fn search_in_all_tables_counts_matching_rows_per_table() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("all.duckdb");
        duckdb::Connection::open(&path)
            .unwrap()
            .execute_batch(
                "CREATE TABLE b_points (id INTEGER, label VARCHAR, note VARCHAR);
                 INSERT INTO b_points VALUES (1, 'EXCITAÇÃO TENSÃO', NULL), (2, 'outro', 'tensao de campo'), (3, 'nada', NULL);
                 CREATE TABLE a_codes (code INTEGER, name VARCHAR);
                 INSERT INTO a_codes VALUES (7, 'Tensão'), (8, 'x');
                 CREATE TABLE c_numbers (tensao INTEGER, n INTEGER);
                 INSERT INTO c_numbers VALUES (1, 7);
                 CREATE TABLE d_kinds (x DOUBLE, b BOOLEAN, d DATE, ts TIMESTAMP);
                 INSERT INTO d_kinds VALUES (1e20, true, DATE '2024-01-02', TIMESTAMP '2024-03-04 05:06:08');",
            )
            .unwrap();
        let manager = DBManager::new();
        assert!(manager.search_tables("x", &|| false).unwrap_err().contains("[[err.noDatabase]]"));
        manager.connect(path.to_str().unwrap(), &mut no_progress()).unwrap();
        let found = |s: &str| -> Vec<(String, i64)> {
            manager.search_tables(s, &|| false).unwrap().into_iter().map(|f| (f.table, f.count)).collect()
        };
        assert_eq!(found("TENSAO"), [("a_codes".to_string(), 1), ("b_points".to_string(), 2)]);
        assert_eq!(found("campo tensão"), [("b_points".to_string(), 1)]);
        assert_eq!(found("  "), []);
        // numeros tambem: a_codes.code 7 e c_numbers.n 7 (b_points.id nao tem 7)
        assert_eq!(found("7"), [("a_codes".to_string(), 1), ("c_numbers".to_string(), 1)]);
        // abrir a tabela achada com a mesma pesquisa da a mesma contagem
        assert_eq!(manager.get_row_count("b_points", &[], "TENSAO").unwrap(), 2);
        assert_eq!(manager.get_row_count("c_numbers", &[], "7").unwrap(), 1);
        // tipos que nao passam por lower(strip_accents()): o texto deles ja e o dobrado (maiusculas da busca valem)
        for search in ["E+20", "TRUE", "trué", "2024-01-02", "05:06:08", "2024-03-04 05:06"] {
            assert_eq!(found(search), [("d_kinds".to_string(), 1)], "{search}");
        }

        let lite = dir.path().join("all.sqlite");
        let conn = rusqlite::Connection::open(&lite).unwrap();
        conn.execute_batch("CREATE TABLE t (id INTEGER, s TEXT); INSERT INTO t VALUES (1, 'Tensão'), (2, NULL);").unwrap();
        drop(conn);
        manager.connect(lite.to_str().unwrap(), &mut no_progress()).unwrap();
        assert_eq!(found("tensao"), [("t".to_string(), 1)]);
    }

    // decisao 4 (4 versoes): uma pesquisa nova para a antiga entre uma tabela e outra; falha ao contar sai com a frase
    // do catalogo ([[chave]], traduzida na tela) e o nome da tabela
    #[test]
    fn search_in_all_tables_stops_between_tables_and_reports_failures() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("stop.duckdb");
        duckdb::Connection::open(&path)
            .unwrap()
            .execute_batch(
                "CREATE TABLE a (s VARCHAR); INSERT INTO a VALUES ('foo');
                 CREATE TABLE b (s VARCHAR); INSERT INTO b VALUES ('foo');
                 CREATE VIEW z AS SELECT CAST(error('test') AS VARCHAR) AS s;",
            )
            .unwrap();
        let manager = DBManager::new();
        manager.connect(path.to_str().unwrap(), &mut no_progress()).unwrap();
        // a pesquisa nova chega enquanto a tabela a e contada: b nao e contada
        let asked = std::cell::Cell::new(0);
        let stop = || {
            asked.set(asked.get() + 1);
            asked.get() > 1
        };
        assert_eq!(manager.search_tables("foo", &stop).unwrap_err(), "[[err.searchCancelled]]");
        assert_eq!(asked.get(), 2);
        let err = manager.search_tables("foo", &|| false).unwrap_err();
        assert!(err.starts_with("[[err.countRows]] z: ") && err.contains("test"), "{err}");
        assert!(!err.contains("Failed"), "{err}");
    }

    // auditoria externa 2: arquivo do usuario com o nome do temporario ("out.csv.partial") nao pode sumir, e o
    // destino anterior fica intacto se a exportacao falhar
    #[test]
    fn export_keeps_user_files_named_like_the_temporary() {
        let dir = tempdir().unwrap();
        let manager = DBManager::new();
        manager.connect(sample_duckdb(dir.path()).to_str().unwrap(), &mut no_progress()).unwrap();
        let conn = manager.export_connection().unwrap();
        let table = Source::Table("points".into());
        for format in ["csv", "duckdb"] {
            let out = dir.path().join(format!("out.{format}"));
            let user_files = [format!("out.{format}.partial"), format!("out.{format}.partial.wal")];
            // pasta do usuario com o nome que a exportacao tentaria primeiro: e pulada, nunca reaproveitada nem apagada
            let taken = dir.path().join(format!(".out.{format}.{}-0.partial", std::process::id()));
            std::fs::create_dir(&taken).unwrap();
            std::fs::write(taken.join("keep.txt"), "do usuario").unwrap();
            for name in &user_files {
                std::fs::write(dir.path().join(name), "do usuario").unwrap();
            }
            std::fs::write(&out, "anterior").unwrap();
            let failed = if format == "csv" {
                export::export_source(&conn, &table, "csv", &out, &mut |_, _, _| Err("Export cancelled".into()))
            } else {
                export::export_database(&conn, "duckdb", &out, &mut |_, _, _| Err("Export cancelled".into()))
            };
            assert!(failed.is_err());
            assert_eq!(std::fs::read_to_string(&out).unwrap(), "anterior", "{format}");
            let done = if format == "csv" {
                export::export_source(&conn, &table, "csv", &out, &mut ok_progress())
            } else {
                export::export_database(&conn, "duckdb", &out, &mut ok_progress())
            };
            done.unwrap();
            assert_ne!(std::fs::read(&out).unwrap(), b"anterior");
            for name in &user_files {
                assert_eq!(std::fs::read_to_string(dir.path().join(name)).unwrap(), "do usuario", "{name}");
            }
            // nenhum temporario da exportacao sobra na pasta
            let left: Vec<String> = std::fs::read_dir(dir.path())
                .unwrap()
                .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
                .filter(|n| n.trim_start_matches('.').starts_with(&format!("out.{format}")))
                .filter(|n| !user_files.contains(n) && *n != format!("out.{format}") && dir.path().join(n) != taken)
                .collect();
            assert!(left.is_empty(), "{left:?}");
            assert_eq!(std::fs::read_to_string(taken.join("keep.txt")).unwrap(), "do usuario");
        }
    }

    // auditoria externa 4: decimal longo, inteiros de 128 bits e UBIGINT acima do i64 voltam exatos do .sqlite
    #[test]
    fn sqlite_export_keeps_long_decimals_and_huge_integers_exact() {
        let dir = tempdir().unwrap();
        let src = dir.path().join("big.duckdb");
        duckdb::Connection::open(&src)
            .unwrap()
            .execute_batch(
                "CREATE TABLE big (d DECIMAL(38,10), h HUGEINT, u UBIGINT, uh UHUGEINT, small DECIMAL(10,2));
                 INSERT INTO big VALUES
                   (1234567890123456789012345678.0123456789, 170141183460469231731687303715884105727,
                    18446744073709551615, 340282366920938463463374607431768211455, 12.30),
                   (-0.0000000001, -170141183460469231731687303715884105728, 1, 0, NULL);",
            )
            .unwrap();
        let manager = DBManager::new();
        manager.connect(src.to_str().unwrap(), &mut no_progress()).unwrap();
        let out = dir.path().join("big.sqlite");
        export::export_database(&manager.export_connection().unwrap(), "sqlite", &out, &mut ok_progress()).unwrap();

        let reopened = DBManager::new();
        reopened.connect(out.to_str().unwrap(), &mut no_progress()).unwrap();
        let types: Vec<String> = reopened.get_table_schema("big").unwrap().into_iter().map(|c| c.col_type).collect();
        assert_eq!(types, ["DECIMAL(38,10)", "HUGEINT", "UBIGINT", "UHUGEINT", "DECIMAL(10,2)"]);
        let rows = reopened.query_table("big", 10, &[], "").unwrap();
        assert_eq!(rows[0]["d"], "1234567890123456789012345678.0123456789");
        assert_eq!(rows[0]["h"], "170141183460469231731687303715884105727");
        assert_eq!(rows[0]["u"], "18446744073709551615");
        assert_eq!(rows[0]["uh"], "340282366920938463463374607431768211455");
        assert_eq!(rows[0]["small"], "12.30");
        assert_eq!(rows[1]["d"], "-0.0000000001");
        assert_eq!(rows[1]["h"], "-170141183460469231731687303715884105728");
        assert_eq!(rows[1]["u"], 1);
    }

    // auditoria externa 12: inteiro fora de Number.MAX_SAFE_INTEGER vai como texto (o JavaScript perderia digitos)
    #[test]
    fn integers_beyond_javascript_safe_range_go_as_text() {
        use crate::backend::db_manager::value_to_json;
        use duckdb::types::ValueRef as V;
        assert_eq!(value_to_json(V::BigInt(9_007_199_254_740_991)), json!(9_007_199_254_740_991_i64));
        assert_eq!(value_to_json(V::BigInt(-9_007_199_254_740_991)), json!(-9_007_199_254_740_991_i64));
        assert_eq!(value_to_json(V::BigInt(9_007_199_254_740_993)), json!("9007199254740993"));
        assert_eq!(value_to_json(V::BigInt(i64::MIN)), json!("-9223372036854775808"));
        assert_eq!(value_to_json(V::UBigInt(u64::MAX)), json!("18446744073709551615"));
        assert_eq!(value_to_json(V::UBigInt(7)), json!(7));
        assert_eq!(value_to_json(V::UHugeInt(u128::MAX)), json!("340282366920938463463374607431768211455"));
        // o filtro pelo texto mostrado acha a linha exata (nao a vizinha que o double confundiria)
        let dir = tempdir().unwrap();
        let path = dir.path().join("ids.duckdb");
        duckdb::Connection::open(&path)
            .unwrap()
            .execute_batch("CREATE TABLE t (id BIGINT); INSERT INTO t VALUES (9007199254740992), (9007199254740993);")
            .unwrap();
        let manager = DBManager::new();
        manager.connect(path.to_str().unwrap(), &mut no_progress()).unwrap();
        let rows = manager.query_table("t", 10, &[filter("id", json!("9007199254740993"))], "").unwrap();
        assert_eq!(rows, [json!({ "id": "9007199254740993" })]);
    }

    // item 29: o SQLite convertido vai para a primeira pasta em que der para criar arquivo: a temporaria do usuario, a
    // do sistema, a do original (subpasta propria em todas); sobras de processos mortos somem ao iniciar, tambem ao
    // lado de originais (so a subpasta do app)
    #[test]
    fn temp_folder_falls_back_to_the_next_one() {
        let dir = tempdir().unwrap();
        let blocked = dir.path().join("a file");
        std::fs::write(&blocked, "x").unwrap();
        // pasta "dentro" de um arquivo nao da para criar: vai para a seguinte
        let dirs = [blocked.join("sub"), dir.path().join("second"), dir.path().join("third")];
        let file = converted::new_temp_in(&dirs, "x.sqlite").unwrap();
        assert_eq!(file.parent().unwrap(), dirs[1]);
        assert!(file.file_name().unwrap().to_string_lossy().starts_with(&format!("{}-", std::process::id())));
        assert!(converted::new_temp_in(&dirs[..1], "x.sqlite").is_err(), "no folder left");
        let beside = dir.path().join("orig");
        let all = converted::temp_dirs(Some(&beside));
        assert_eq!(all[0], std::env::temp_dir().join("mdb2sql-rust-tauri-svelte"));
        assert_eq!(all.last().unwrap(), &beside.join("mdb2sql-rust-tauri-svelte"));
        if cfg!(windows) {
            let system = PathBuf::from(std::env::var_os("SystemRoot").unwrap()).join("Temp").join("mdb2sql-rust-tauri-svelte");
            assert_eq!(all, [all[0].clone(), system, beside.join("mdb2sql-rust-tauri-svelte")]);
        }
        // ao lado do original: Converted::beside diz a pasta (a interface guarda para a limpeza)
        let lite = converted::Converted::new(converted::new_temp_in(&all[2..], "y.sqlite").unwrap());
        assert_eq!(lite.beside(), Some(all[2].as_path()));
        drop(lite);
        assert!(!all[2].exists(), "the empty subfolder beside the original goes too");
        // limpeza ao iniciar: a sobra ao lado do original (pasta guardada pela interface) some com a subpasta; pasta que
        // nao e a subpasta do app nao e tocada
        std::fs::create_dir_all(&all[2]).unwrap();
        let stale = all[2].join("4294967294-1-old.sqlite");
        let other = dir.path().join("second").join("4294967294-1-other.sqlite");
        File::create(&stale).unwrap();
        File::create(&other).unwrap();
        let removed = converted::clean_all(&[all[2].to_string_lossy().into_owned(), dirs[1].to_string_lossy().into_owned()]);
        assert!(removed >= 1 && !stale.exists() && !all[2].exists() && other.exists(), "{removed}");
    }

    // item 33: a aba SQL roda so comandos de leitura (tipo do comando pelo DuckDB); os outros sao recusados antes de
    // rodar e o banco, a copia e a memoria nunca mudam (EXPLAIN ANALYZE de escrita tambem nao)
    #[test]
    fn sql_tab_runs_only_read_statements() {
        let dir = tempdir().unwrap();
        let lite = dir.path().join("ro.sqlite");
        rusqlite::Connection::open(&lite).unwrap().execute_batch("CREATE TABLE t (id INTEGER, s TEXT); INSERT INTO t VALUES (1, 'a'), (2, 'b');").unwrap();
        let copy = dir.path().join("copy.csv");
        let copy_sql = copy.to_string_lossy().replace('\'', "''");
        for path in [lite.clone(), sample_duckdb(dir.path())] {
            let manager = DBManager::new();
            manager.connect(path.to_str().unwrap(), &mut no_progress()).unwrap();
            let table = if path == lite { "t" } else { "points" };
            let reads = [
                format!("SELECT * FROM {table}"),
                format!("WITH x AS (SELECT * FROM {table}) SELECT count(*) FROM x"),
                format!("FROM {table}"),
                "VALUES (1, 2)".to_string(),
                "SHOW TABLES".to_string(),
                format!("DESCRIBE {table}"),
                format!("SUMMARIZE {table}"),
                format!("PRAGMA table_info('{table}')"),
                "PRAGMA show_tables".to_string(),
                format!("EXPLAIN SELECT * FROM {table}"),
                format!("EXPLAIN ANALYZE SELECT * FROM {table}"),
                format!("  explain   analyze FROM {table};"),
                format!("EXPLAIN (ANALYZE) SELECT * FROM {table}"),
                format!("SELECT 1; SELECT count(*) FROM {table}"),
            ];
            for sql in &reads {
                assert!(manager.run_sql(sql, 10).is_ok(), "{sql}: {:?}", manager.run_sql(sql, 10).err());
            }
            let writes = [
                format!("INSERT INTO {table} (id) VALUES (3)"),
                format!("UPDATE {table} SET id = 9"),
                format!("DELETE FROM {table}"),
                "CREATE TABLE u (x INTEGER)".to_string(),
                "CREATE TEMP TABLE u AS SELECT 1".to_string(),
                "CREATE VIEW v AS SELECT 1".to_string(),
                format!("DROP TABLE {table}"),
                format!("ALTER TABLE {table} ADD COLUMN z INTEGER"),
                "ATTACH ':memory:' AS other".to_string(),
                format!("COPY {table} TO '{copy_sql}'"),
                "SET threads = 1".to_string(),
                "PRAGMA threads = 1".to_string(),
                "CALL pragma_version()".to_string(),
                "USE memory".to_string(),
                "BEGIN TRANSACTION".to_string(),
                "CHECKPOINT".to_string(),
                "INSTALL json".to_string(),
                "LOAD json".to_string(),
                format!("EXPORT DATABASE '{}'", dir.path().join("exp").to_string_lossy().replace('\'', "''")),
                format!("SELECT 1; DROP TABLE {table}"),
                // EXPLAIN ANALYZE roda o comando que explica: so vale com uma consulta (COPY ... TO gravaria o arquivo
                // mesmo na transacao so de leitura)
                format!("EXPLAIN ANALYZE INSERT INTO {table} (id) VALUES (3)"),
                format!("explain analyse DELETE FROM {table}"),
                format!("EXPLAIN (ANALYZE) DELETE FROM {table}"),
                "EXPLAIN ANALYZE CREATE TABLE u AS SELECT 1".to_string(),
                format!("EXPLAIN ANALYZE COPY {table} TO '{copy_sql}'"),
                format!("/* x */ EXPLAIN -- y\n ANALYZE /* z */ COPY {table} TO '{copy_sql}';"),
                format!("EXPLAIN COPY {table} TO '{copy_sql}'"),
                format!("EXPLAIN SELECT 1; EXPLAIN ANALYZE COPY {table} TO '{copy_sql}'"),
                // o DuckDB aninha /* */: comentario num EXPLAIN e recusado (revisao: estes passavam como SELECT 1)
                format!("EXPLAIN ANALYZE /* /* */ SELECT 1 -- */ COPY {table} TO '{copy_sql}'"),
                format!("EXPLAIN (ANALYZE /* ) SELECT 1 -- */) COPY {table} TO '{copy_sql}'"),
                format!("EXPLAIN (ANALYZE /* ) -- */) COPY {table} TO '{copy_sql}'"),
                format!("-- c\n explain /* c */ analyze FROM {table};"),
            ];
            for sql in &writes {
                assert_eq!(manager.run_sql(sql, 10).err().as_deref(), Some("[[err.sqlReadOnly]]"), "{sql}");
            }
            assert_eq!(manager.get_row_count(table, &[], "").unwrap(), 2, "{table}");
            assert_eq!(manager.list_tables().unwrap().len(), if path == lite { 1 } else { 2 });
            assert!(!copy.exists(), "EXPLAIN ANALYZE COPY wrote a file");
            // erro do banco: o texto do DuckDB, nao a recusa
            let typo = manager.run_sql("SELEC 1", 10).unwrap_err();
            assert!(typo.contains("syntax error") && !typo.contains("sqlReadOnly"), "{typo}");
            assert!(manager.run_sql("SELECT * FROM missing_table", 10).unwrap_err().contains("missing_table"));
            // a exportacao do resultado usa a mesma recusa (main.rs export "sql")
            assert_eq!(manager.check_read_only(&format!("DELETE FROM {table}")).err().as_deref(), Some("[[err.sqlReadOnly]]"));
            assert!(manager.check_read_only(&format!("SELECT * FROM {table}")).is_ok());
        }
    }

    // item 31: identidade da linha marcada = rowid do DuckDB (tabela do .duckdb, SQLite e Access copiados para a
    // memoria); view sem rowid: todos os valores (linhas identicas marcam juntas). As marcadas voltam inteiras, na ordem
    // da tabela, qualquer que seja a pesquisa, e a exportacao delas leva so elas
    #[test]
    fn marked_rows_come_back_by_rowid_or_by_all_values() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("marks.duckdb");
        duckdb::Connection::open(&path)
            .unwrap()
            .execute_batch(
                "CREATE TABLE p AS SELECT range AS id, 'kkk' || range AS s FROM range(5);
                 CREATE TABLE d (s VARCHAR, n INTEGER); INSERT INTO d VALUES ('x', 1), ('x', 1), ('y', 2);
                 CREATE VIEW dv AS SELECT * FROM d;",
            )
            .unwrap();
        let lite = dir.path().join("marks.sqlite");
        rusqlite::Connection::open(&lite).unwrap().execute_batch("CREATE TABLE p (id INTEGER, s TEXT); INSERT INTO p VALUES (0, 'kkk0'), (1, 'kkk1'), (2, 'kkk2'), (3, 'kkk3'), (4, 'kkk4');").unwrap();
        for file in [&path, &lite] {
            let manager = DBManager::new();
            manager.connect(file.to_str().unwrap(), &mut no_progress()).unwrap();
            let page = manager.table_page("p", 2, 0, &[], "", &[]).unwrap();
            assert_eq!(page.ids, [json!(0), json!(1)], "rowid");
            assert!(page.rows[0].get("mdb2sql id").is_none(), "the id is not a column");
            // marca as linhas 4 e 2 (fora da pagina); outra pesquisa: elas voltam na ordem da tabela, alem da pagina
            let marked = [json!(4), json!(2)];
            let page = manager.table_page("p", 2, 0, &[], "kkk1", &marked).unwrap();
            assert_eq!(page.rows, [json!({ "id": 1, "s": "kkk1" })]);
            assert_eq!(page.marked_ids, [json!(2), json!(4)]);
            assert_eq!(page.marked, [json!({ "id": 2, "s": "kkk2" }), json!({ "id": 4, "s": "kkk4" })]);
            let (filter, params) = manager.marked_where("p", &marked).unwrap();
            let out = dir.path().join("p_marcadas.csv");
            let conn = manager.export_connection().unwrap();
            let done = export::export_source(&conn, &Source::Rows("p".into(), filter, params), "csv", &out, &mut ok_progress()).unwrap();
            assert_eq!(done.count, 2);
            assert_eq!(std::fs::read_to_string(&out).unwrap(), "\u{FEFF}id,s\r\n2,kkk2\r\n4,kkk4\r\n");
            assert!(manager.marked_where("p", &[]).is_err());
        }
        // view: identidade = todos os valores; as duas linhas ('x', 1) marcam juntas
        let manager = DBManager::new();
        manager.connect(path.to_str().unwrap(), &mut no_progress()).unwrap();
        let page = manager.table_page("dv", 10, 0, &[], "", &[]).unwrap();
        assert!(page.ids.iter().all(|id| id.is_string()));
        assert_eq!(page.ids[0], page.ids[1]);
        assert_ne!(page.ids[0], page.ids[2]);
        let page = manager.table_page("dv", 10, 0, &[], "y", &[page.ids[0].clone()]).unwrap();
        assert_eq!(page.rows.len(), 1);
        assert_eq!(page.marked, [json!({ "s": "x", "n": 1 }), json!({ "s": "x", "n": 1 })]);
    }

    // item 32: pesquisa de termos em todas as colunas (numeros e datas como texto). Valor inteiro: celula sem espacos nas
    // pontas igual ao termo, sem maiusculas; Contem: a celula contem o termo. Acertos na ordem da lista colada, depois da
    // tabela; linha achada por 2 termos aparece 2 vezes; nao encontrados ficam de fora. Relatorio em xlsx, SQLite,
    // DuckDB e CSV com Resumo, uma tabela por tabela com acerto e Nao encontrados
    #[test]
    fn term_search_finds_whole_values_and_contained_text() {
        use crate::backend::terms::{self, TermHit};
        let dir = tempdir().unwrap();
        let path = dir.path().join("terms.duckdb");
        duckdb::Connection::open(&path)
            .unwrap()
            .execute_batch(
                "CREATE TABLE a_pts (rtu INTEGER, pnt INTEGER, name VARCHAR);
                 INSERT INTO a_pts VALUES (50, 300, 'GENERADOR X'), (50, 238, 'Generador X'), (50, 242, '  generador y  '), (51, 1, 'OTRO');
                 CREATE TABLE b_other (code VARCHAR, n DOUBLE, d DATE);
                 INSERT INTO b_other VALUES ('GENERADOR Y', 1.5, DATE '2024-01-02'), (NULL, NULL, NULL);
                 CREATE TABLE c_empty (z VARCHAR);",
            )
            .unwrap();
        let manager = DBManager::new();
        manager.connect(path.to_str().unwrap(), &mut no_progress()).unwrap();
        let tables = manager.list_tables().unwrap();
        // a interface manda os termos sem repetidos e sem espacos nas pontas, na ordem colada
        let terms: Vec<String> = ["PNTNAM", "generador x", "GENERADOR Y", "238", "2024-01-02", "Y"].map(String::from).to_vec();
        let hit = |ord: usize, table: &str, count: i64| TermHit { ord, table: table.to_string(), count };

        let conn = manager.export_connection().unwrap();
        let whole = terms::search(&conn, &terms, true, &tables, &mut ok_progress()).unwrap();
        assert_eq!(whole, [hit(1, "a_pts", 2), hit(2, "a_pts", 1), hit(3, "a_pts", 1), hit(2, "b_other", 1), hit(4, "b_other", 1)]);
        let rows = terms::rows(&conn, "a_pts", "Termo", usize::MAX).unwrap();
        let names: Vec<&str> = rows.columns.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["Termo", "rtu", "pnt", "name"]);
        // ordem: o termo na ordem colada, depois a ordem da tabela; o termo como foi colado
        let found: Vec<(String, i64)> = rows.rows.iter().map(|r| (r["Termo"].as_str().unwrap().to_string(), r["pnt"].as_i64().unwrap())).collect();
        assert_eq!(found, [("generador x".into(), 300), ("generador x".into(), 238), ("GENERADOR Y".into(), 242), ("238".into(), 238)]);
        assert_eq!(terms::rows(&conn, "a_pts", "Termo", 2).unwrap().rows.len(), 2, "the grid limit");

        // Contem: "Y" acha as duas linhas de GENERADOR Y (que tambem achou por inteiro): cada uma aparece 2 vezes
        let conn = manager.export_connection().unwrap();
        let contains = terms::search(&conn, &terms, false, &tables, &mut ok_progress()).unwrap();
        assert_eq!(
            contains,
            [hit(1, "a_pts", 2), hit(2, "a_pts", 1), hit(3, "a_pts", 1), hit(5, "a_pts", 1), hit(2, "b_other", 1), hit(4, "b_other", 1), hit(5, "b_other", 1)]
        );
        // so esta tabela
        let conn = manager.export_connection().unwrap();
        assert_eq!(terms::search(&conn, &terms, true, &["b_other".to_string()], &mut ok_progress()).unwrap(), [hit(2, "b_other", 1), hit(4, "b_other", 1)]);
        // Cancelar (o progresso devolve erro) para a pesquisa
        let conn = manager.export_connection().unwrap();
        assert!(terms::search(&conn, &terms, true, &tables, &mut |_, _, _| Err("[[err.searchCancelled]]".into())).is_err());

        // relatorio da pesquisa por inteiro
        let conn = manager.export_connection().unwrap();
        terms::search(&conn, &terms, true, &tables, &mut ok_progress()).unwrap();
        // BRIEF secao 13 i: uma aba "Resultado Filtro" com tudo (encontrados e nao encontrados) e uma por tabela, sem sufixo
        let labels: Vec<String> = ["Termo", "Situação", "Tabela", "Linhas", "Encontrado", "Não encontrado", "Resultado Filtro"].map(String::from).to_vec();
        let with_hits = ["a_pts".to_string(), "b_other".to_string()];
        let names = terms::report(&conn, &with_hits, &labels).unwrap();
        assert_eq!(names, ["Resultado Filtro", "a_pts", "b_other"]);
        let out = dir.path().join("rel.sqlite");
        export::write_tables(&conn, &names, "sqlite", &out, &mut ok_progress()).unwrap();
        let rel = rusqlite::Connection::open(&out).unwrap();
        let summary: Vec<(String, String, String, i64)> = rel
            .prepare("SELECT \"Termo\", \"Situação\", \"Tabela\", \"Linhas\" FROM \"Resultado Filtro\"")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        let line = |t: &str, s: &str, tb: &str, n: i64| (t.to_string(), s.to_string(), tb.to_string(), n);
        assert_eq!(
            summary,
            [
                line("PNTNAM", "Não encontrado", "", 0),
                line("generador x", "Encontrado", "a_pts", 2),
                line("GENERADOR Y", "Encontrado", "a_pts", 1),
                line("GENERADOR Y", "Encontrado", "b_other", 1),
                line("238", "Encontrado", "a_pts", 1),
                line("2024-01-02", "Encontrado", "b_other", 1),
                line("Y", "Não encontrado", "", 0),
            ]
        );
        let cols: Vec<String> = rel.prepare("SELECT name FROM pragma_table_info('a_pts')").unwrap().query_map([], |r| r.get(0)).unwrap().collect::<Result<_, _>>().unwrap();
        assert_eq!(cols, ["Termo", "rtu", "pnt", "name"]);
        assert_eq!(rel.query_row("SELECT count(*) FROM a_pts", [], |r| r.get::<_, i64>(0)).unwrap(), 4);
        drop(rel);
        for format in ["duckdb", "xlsx"] {
            let file = dir.path().join(format!("rel.{format}"));
            let done = export::write_tables(&conn, &names, format, &file, &mut ok_progress()).unwrap();
            assert_eq!(done.count, 3);
            assert!(file.is_file());
        }
        let folder = dir.path().join("csv");
        std::fs::create_dir(&folder).unwrap();
        export::export_folder(&conn, &names, &folder, &mut ok_progress()).unwrap();
        let result = std::fs::read_to_string(folder.join("Resultado Filtro.csv")).unwrap();
        assert!(result.starts_with("\u{FEFF}Termo,Situação,Tabela,Linhas\r\nPNTNAM,Não encontrado,,0\r\n"), "{result}");
        assert_eq!(export::csv_files(&folder, &terms::report_names(&with_hits, "Resultado Filtro")).iter().filter(|f| f.exists()).count(), 3);
        // a tabela de verdade nao mudou (as views do relatorio sao temporarias da conexao da pesquisa)
        assert_eq!(manager.get_row_count("a_pts", &[], "").unwrap(), 4);
        assert_eq!(manager.get_table_schema("a_pts").unwrap().len(), 3);
    }

    // BRIEF secao 13 a: Valor inteiro com numeros, regra frouxa (dados em formato EUA e BR/Europa): termo e celula casam
    // quando alguma leitura de um e igual a alguma do outro. Casam: 216 com 216.0, "216,0" e "216"; 0,1 com 0.1; 1234.5
    // com "1.234,5"; 1,234 com 1234 e com 1.234. Nao casam: 216 com 2160 nem com 216.5. Texto que nao e numero: como antes
    #[test]
    fn term_whole_value_reads_numbers_loosely() {
        use crate::backend::terms::{self, TermHit};
        let dir = tempdir().unwrap();
        let path = dir.path().join("numbers.duckdb");
        duckdb::Connection::open(&path)
            .unwrap()
            .execute_batch(
                "CREATE TABLE n (i INTEGER, d DOUBLE, m DECIMAL(10,2), s VARCHAR);
                 INSERT INTO n VALUES (216, 0.1, 1234.50, '216,0'), (2160, 216.5, 7.00, '1.234,5'), (NULL, NULL, 1.23, 'abc'),
                   (1234, NULL, NULL, '1,234.567'), (NULL, NULL, NULL, '216'),
                   (NULL, NULL, NULL, '12,34,567'), (NULL, NULL, NULL, '1234,567');",
            )
            .unwrap();
        let manager = DBManager::new();
        manager.connect(path.to_str().unwrap(), &mut no_progress()).unwrap();
        let hit = |ord: usize, count: i64| TermHit { ord, table: "n".to_string(), count };
        let search = |terms: &[&str]| {
            let terms: Vec<String> = terms.iter().map(|t| t.to_string()).collect();
            terms::search(&manager.export_connection().unwrap(), &terms, true, &["n".to_string()], &mut ok_progress()).unwrap()
        };
        // "216": linha 1 (i 216 e o texto "216,0") e linha 5 ("216"); nunca 2160 nem 216.5 (linha 2)
        // "0,1": d 0.1; "1234.5": m 1234.50 e o texto "1.234,5"; "1,234": i 1234 (linha 4) e m 1.23 nao; "1234567": "1,234.567"
        // nao: e 1234.567, e "12,34,567" (milhar so em grupos de 3: nao e numero) e "1234,567" (1234.567) tambem nao, como no
        // Python; "abc": texto; "216.50": d 216.5; "1": nunca "0,1" (0.1) nem 1.23
        let hits = search(&["216", "0,1", "1234.5", "1,234", "1234567", "abc", "216.50", "2.160", "1"]);
        assert_eq!(hits, [hit(0, 2), hit(1, 1), hit(2, 2), hit(3, 1), hit(5, 1), hit(6, 1), hit(7, 1)]);
        // sem termo numerico, so o texto (o caminho de antes)
        assert_eq!(search(&["ABC", "zzz"]), [hit(0, 1)]);
    }

    // revisao do Python (B1): funcao de tabela que anexa ou grava nao passa pela aba SQL so leitura. Aqui as extensoes
    // nao carregam sozinhas (sqlite_attach nem existe) e o resto roda numa transacao so de leitura: nada e criado
    #[test]
    fn sql_tab_table_functions_never_attach_or_write() {
        let dir = tempdir().unwrap();
        let manager = DBManager::new();
        manager.connect(sample_duckdb(dir.path()).to_str().unwrap(), &mut no_progress()).unwrap();
        let other = dir.path().join("outro.sqlite");
        let file = other.to_string_lossy().replace('\'', "''");
        for sql in [
            format!("SELECT * FROM sqlite_attach('{file}', overwrite=true)"),
            format!("SELECT * FROM sqlite_attach('{file}')"),
            format!("SELECT * FROM query('COPY points TO ''{file}''')"),
            format!("SELECT * FROM query('ATTACH ''{file}'' AS x')"),
        ] {
            assert!(manager.run_sql(&sql, 10).is_err(), "{sql}");
            assert!(!other.exists(), "{sql}");
        }
        assert_eq!(manager.list_tables().unwrap(), ["Other table", "points"]);
        // e o motor segue sem nenhum banco anexado alem do aberto
        let attached = manager.run_sql("SELECT database_name FROM duckdb_databases() WHERE NOT internal ORDER BY 1", 10).unwrap();
        assert_eq!(attached.rows, [json!({ "database_name": "memory" }), json!({ "database_name": "src" })]);
    }

    // revisao do Python (B2): tabela com uma coluna chamada como a coluna do termo (Termo, term, TÉRMINO) nao quebra a
    // grade nem a copia: a coluna do termo ganha "_" e as da tabela ficam inteiras
    #[test]
    fn term_column_never_collides_with_a_table_column() {
        use crate::backend::terms;
        let dir = tempdir().unwrap();
        let path = dir.path().join("cols.duckdb");
        duckdb::Connection::open(&path)
            .unwrap()
            .execute_batch("CREATE TABLE t (\"Termo\" VARCHAR, \"Termo_\" VARCHAR, v INTEGER); INSERT INTO t VALUES ('a', 'b', 1);")
            .unwrap();
        let manager = DBManager::new();
        manager.connect(path.to_str().unwrap(), &mut no_progress()).unwrap();
        let conn = manager.export_connection().unwrap();
        terms::search(&conn, &["A".to_string()], true, &["t".to_string()], &mut ok_progress()).unwrap();
        for label in ["Termo", "termo"] {
            let rows = terms::rows(&conn, "t", label, usize::MAX).unwrap();
            let names: Vec<&str> = rows.columns.iter().map(|c| c.name.as_str()).collect();
            let term = format!("{label}__");
            assert_eq!(names, [term.as_str(), "Termo", "Termo_", "v"], "{label}");
            assert_eq!(rows.rows, [json!({ term: "A", "Termo": "a", "Termo_": "b", "v": 1 })]);
        }
    }

    // revisao do Python (P1): as marcadas voltam na ordem da tabela (ORDER BY rowid) tambem numa tabela grande, lida em
    // paralelo
    #[test]
    fn marked_rows_of_a_big_table_come_in_table_order() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("big.duckdb");
        duckdb::Connection::open(&path).unwrap().execute_batch("CREATE TABLE b AS SELECT range AS id FROM range(1000000)").unwrap();
        let manager = DBManager::new();
        manager.connect(path.to_str().unwrap(), &mut no_progress()).unwrap();
        let marked = [json!(999_000), json!(5), json!(500_000), json!(130_000)];
        let page = manager.table_page("b", 1, 0, &[], "", &marked).unwrap();
        assert_eq!(page.marked_ids, [json!(5), json!(130_000), json!(500_000), json!(999_000)]);
        let (filter, _) = manager.marked_where("b", &marked).unwrap();
        assert!(filter.ends_with(" ORDER BY rowid"), "{filter}");
    }

    // BRIEF secao 13 h: paginas da aba Dados (o tamanho e a lista Linhas): tabela com mais de 1000 linhas, a ultima
    // pagina incompleta; a pesquisa vale para todas as paginas; as marcadas vem em toda pagina
    #[test]
    fn data_pages_walk_the_whole_table_and_the_search() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("pages.duckdb");
        duckdb::Connection::open(&path)
            .unwrap()
            .execute_batch("CREATE TABLE p AS SELECT range AS id, CASE WHEN range % 2 = 0 THEN 'even' ELSE 'odd' END AS s FROM range(2500)")
            .unwrap();
        let manager = DBManager::new();
        manager.connect(path.to_str().unwrap(), &mut no_progress()).unwrap();
        let ids = |rows: &[serde_json::Value]| rows.iter().map(|r| r["id"].as_i64().unwrap()).collect::<Vec<_>>();
        let first = manager.table_page("p", 1000, 0, &[], "", &[]).unwrap();
        assert_eq!((first.rows.len(), ids(&first.rows)[0]), (1000, 0));
        let last = manager.table_page("p", 1000, 2000, &[], "", &[json!(7)]).unwrap();
        assert_eq!(last.rows.len(), 500, "the last page is incomplete");
        assert_eq!((ids(&last.rows)[0], ids(&last.rows)[499]), (2000, 2499));
        assert_eq!(last.marked_ids, [json!(7)]);
        // "even": 1250 linhas encontradas; a 2a pagina de 1000 tem as 250 ultimas, todas pares
        let found = manager.table_page("p", 1000, 1000, &[], "even", &[]).unwrap();
        assert_eq!(found.rows.len(), 250);
        assert!(ids(&found.rows).iter().all(|id| id % 2 == 0) && ids(&found.rows)[0] == 2000);
        assert_eq!(manager.get_row_count("p", &[], "even").unwrap(), 1250);
        assert!(manager.table_page("p", 100, 2500, &[], "", &[]).unwrap().rows.is_empty());
    }

    // Exportar > Esquema da tabela atual / do banco: Coluna, Tipo, Aceita nulo traduzidos (e Tabela na frente no do banco);
    // Todas as tabelas em CSV: um arquivo por tabela na pasta
    #[test]
    fn schema_and_all_tables_exports() {
        use crate::backend::db_manager::schema_select;
        let dir = tempdir().unwrap();
        let manager = DBManager::new();
        manager.connect(sample_duckdb(dir.path()).to_str().unwrap(), &mut no_progress()).unwrap();
        let conn = manager.export_connection().unwrap();
        let labels: Vec<String> = ["Tabela", "Coluna", "Tipo", "Aceita nulo", "Sim", "Não"].map(String::from).to_vec();
        let out = dir.path().join("points_schema.csv");
        let select = schema_select(Some("points"), &labels).unwrap();
        export::export_source(&conn, &Source::Query("points_schema".into(), select), "csv", &out, &mut ok_progress()).unwrap();
        let text = std::fs::read_to_string(&out).unwrap();
        assert!(text.starts_with("\u{FEFF}Coluna,Tipo,Aceita nulo\r\nid,INTEGER,Sim\r\nname,VARCHAR,Sim\r\n"), "{text}");
        assert_eq!(text.lines().count(), 10);
        let out = dir.path().join("real_schema.csv");
        let select = schema_select(None, &labels).unwrap();
        export::export_source(&conn, &Source::Query("real_schema".into(), select), "csv", &out, &mut ok_progress()).unwrap();
        let text = std::fs::read_to_string(&out).unwrap();
        assert!(text.starts_with("\u{FEFF}Tabela,Coluna,Tipo,Aceita nulo\r\nOther table,k,BIGINT,Sim\r\npoints,id,INTEGER,Sim\r\n"), "{text}");
        assert!(schema_select(None, &labels[..5]).is_err());
        let folder = dir.path().join("all");
        std::fs::create_dir(&folder).unwrap();
        let tables = manager.list_tables().unwrap();
        assert_eq!(export::export_folder(&conn, &tables, &folder, &mut ok_progress()).unwrap().count, 2);
        assert_eq!(std::fs::read_to_string(folder.join("Other table.csv")).unwrap(), "\u{FEFF}k\r\n0\r\n1\r\n2\r\n3\r\n4\r\n");
        assert!(folder.join("points.csv").is_file());
    }

    // Aceitacao do BRIEF (secao 7) e tempos com o DB3 do dono (copias fora do git): MDB2SQL_TEST_DB3_DIR = pasta com
    // DB3.sqlite, DB3.duckdb (e DB3.accdb, opcional: conversao demora) e termos_dono.txt. Imprime os tempos da busca em
    // todas as tabelas (so colunas de texto, como o dev 2f17599, x todas as colunas) e da pesquisa de termos
    #[test]
    fn db3_acceptance_and_times() {
        use crate::backend::db_manager::{ident, search_condition};
        use crate::backend::terms;
        let Ok(folder) = std::env::var("MDB2SQL_TEST_DB3_DIR") else {
            eprintln!("MDB2SQL_TEST_DB3_DIR not set, skipping");
            return;
        };
        let folder = PathBuf::from(folder);
        let pasted = std::fs::read_to_string(folder.join("termos_dono.txt")).unwrap();
        // como a interface (parseTerms): linhas nao vazias, sem espacos nas pontas, sem repetidos
        let mut terms: Vec<String> = Vec::new();
        for line in pasted.lines().map(str::trim).filter(|l| !l.is_empty()) {
            if !terms.iter().any(|t| t.eq_ignore_ascii_case(line)) {
                terms.push(line.to_string());
            }
        }
        let files: Vec<PathBuf> = ["DB3.sqlite", "DB3.duckdb", "DB3.accdb"].iter().map(|f| folder.join(f)).filter(|f| f.is_file()).collect();
        for file in files {
            let manager = DBManager::new();
            let started = std::time::Instant::now();
            manager.connect(file.to_str().unwrap(), &mut no_progress()).unwrap();
            let tables = manager.list_tables().unwrap();
            eprintln!("DB3 {}: opened in {:?}, {} tables", file.display(), started.elapsed(), tables.len());
            let conn = manager.export_connection().unwrap();
            // busca em todas as tabelas: antes (dev 2f17599: so colunas VARCHAR), todas as colunas dobrando toda celula
            // (o commit wip) e agora (todas as colunas, numeros e datas sem dobrar): as duas ultimas acham o mesmo
            let columns = crate::backend::db_manager::all_columns(&conn).unwrap();
            let pick = |only_text: bool| -> Vec<(String, Vec<(String, String)>)> {
                let as_text = |cols: &Vec<(String, String)>| cols.iter().filter(|c| !only_text || c.1 == "VARCHAR").map(|c| (c.0.clone(), "VARCHAR".to_string())).collect();
                tables.iter().map(|t| (t.clone(), columns.get(t).map(as_text).unwrap_or_default())).collect()
            };
            let count_all = |list: &[(String, Vec<(String, String)>)], search: &str| -> Vec<(String, i64)> {
                let mut found = Vec::new();
                for (table, cols) in list {
                    if let Some((cond, params)) = search_condition(cols, search) {
                        let n: i64 = conn.query_row(&format!("SELECT count(*) FROM {} WHERE {cond}", ident(table)), duckdb::params_from_iter(params), |r| r.get(0)).unwrap();
                        if n > 0 {
                            found.push((table.clone(), n));
                        }
                    }
                }
                found
            };
            let (text_only, all_folded) = (pick(true), pick(false));
            // a maquina e dividida com outros builds: o menor de 3 tempos de cada jeito
            let best = |run: &dyn Fn() -> Vec<(String, i64)>| {
                let mut times = Vec::new();
                let mut found = Vec::new();
                for _ in 0..3 {
                    let t = std::time::Instant::now();
                    found = run();
                    times.push(t.elapsed());
                }
                (found, times.into_iter().min().unwrap())
            };
            for search in ["tension", "tension de campo", "238", "U9A", "2190"] {
                let (before, before_time) = best(&|| count_all(&text_only, search));
                let (folded, folded_time) = best(&|| count_all(&all_folded, search));
                let (now, now_time) = best(&|| manager.search_tables(search, &|| false).unwrap().into_iter().map(|f| (f.table, f.count)).collect());
                eprintln!(
                    "DB3 search all tables \"{search}\": text columns {} tables in {before_time:?}; all columns folded {} tables in {folded_time:?}; all columns now {} tables in {now_time:?}",
                    before.len(),
                    folded.len(),
                    now.len()
                );
                assert_eq!(now, folded, "{search}");
            }
            for whole in [true, false] {
                let conn = manager.export_connection().unwrap();
                let t = std::time::Instant::now();
                let hits = terms::search(&conn, &terms, whole, &tables, &mut ok_progress()).unwrap();
                let time = t.elapsed();
                let mut with_hits: Vec<String> = hits.iter().map(|h| h.table.clone()).collect();
                with_hits.dedup();
                let missing: Vec<&String> = terms.iter().enumerate().filter(|(i, _)| !hits.iter().any(|h| h.ord == *i)).map(|(_, t)| t).collect();
                eprintln!("DB3 terms whole={whole}: {} terms, all tables in {time:?}; tables {with_hits:?}; not found {missing:?}", terms.len());
                let sostat = terms::rows(&conn, "RANGER_SOSTAT", "Termo", usize::MAX).unwrap();
                // RTUNO e PNTNO sao texto num banco e numero em outro: compara o texto da grade
                let text = |v: &serde_json::Value| crate::backend::db_manager::json_text(v);
                let points: Vec<(String, String, String)> = sostat.rows.iter().map(|r| (text(&r["RTUNO"]), text(&r["PNTNO"]), text(&r["SUBNAM"]))).collect();
                eprintln!("DB3 RANGER_SOSTAT: {points:?}");
                assert_eq!(points.iter().map(|p| p.1.as_str()).collect::<Vec<_>>(), ["238", "242", "254", "256", "260", "304", "308", "2190"]);
                assert!(points.iter().all(|p| p.0 == "50"));
                assert_eq!(points[7].2, "U9A");
                // Contem acha PNTNAM tambem nas mensagens de RANGER_SOTEXT ("SOSTAT.SUBNAM+PNTNAM"); por inteiro, nao
                if whole {
                    assert_eq!(missing, [&"PNTNAM".to_string()]);
                } else {
                    assert!(missing.is_empty() && with_hits.contains(&"RANGER_SOTEXT".to_string()), "{missing:?}");
                }
            }
            // secao 13 a: com termos numericos o valor inteiro le tambem os numeros das celulas de texto (o custo novo)
            let numbers: Vec<String> = ["238", "2190", "50", "0,1", "216,0", "U9A"].map(String::from).to_vec();
            let conn = manager.export_connection().unwrap();
            let t = std::time::Instant::now();
            let hits = terms::search(&conn, &numbers, true, &tables, &mut ok_progress()).unwrap();
            eprintln!("DB3 numeric terms whole=true: {} terms, all tables in {:?}; {} term x table hits", numbers.len(), t.elapsed(), hits.len());
        }
    }
}
