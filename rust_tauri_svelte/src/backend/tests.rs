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

    #[test]
    fn load_sample_duckdb_lists_tables_and_rows() {
        let manager = DBManager::new();
        let path = PathBuf::from("../data/sample.duckdb");
        if !path.exists() {
            eprintln!("sample.duckdb not found, skipping");
            return;
        }
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
        assert_eq!(manager.table_rows(&manager.list_tables().unwrap()).unwrap(), [5, 2]);

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

        // somente leitura: o SQL livre nao consegue gravar no arquivo aberto
        assert!(manager.run_sql("INSERT INTO points VALUES (3, 'x', NULL, NULL, NULL, NULL, NULL, NULL, NULL)", 10).is_err());
        let result = manager.run_sql("SELECT id, name FROM points ORDER BY id", 1).unwrap();
        assert_eq!(result.columns.len(), 2);
        assert_eq!(result.rows.len(), 1);
        assert!(result.truncated);
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
            assert_eq!(manager.table_rows(&["t".to_string()]).unwrap(), [5], "{path:?}");
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
        let sheets = export::write_sheets(&mut wb, &mut namer, &conn, "big", "SELECT * FROM big", 2, &mut tick).unwrap();
        assert_eq!(sheets, [("big".to_string(), 2), ("big (2)".to_string(), 2), ("big (3)".to_string(), 1)]);
        let sheets = export::write_sheets(&mut wb, &mut namer, &conn, "empty", "SELECT * FROM empty", 2, &mut tick).unwrap();
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
        let opened = manager.connect_with("tests/data/sample.mdb", Some("mdbtools"), &mut no_progress()).unwrap();
        assert_eq!(opened.source, "mdbtools → SQLite");
        assert_eq!(manager.list_tables().unwrap(), ["Empty", "Sample Types"]);
        assert_eq!(manager.get_row_count("Empty", &[], "").unwrap(), 0);

        let lite_path = opened.converted.as_ref().unwrap().path().to_path_buf();
        assert!(lite_path.starts_with(converted::temp_dir()));
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

    // salvar move o SQLite para onde o usuario escolheu; erro mantem o temporario; restos de processos mortos somem
    #[test]
    fn converted_sqlite_is_saved_discarded_and_cleaned() {
        let dir = tempdir().unwrap();
        let make = || {
            let path = converted::new_temp_path("t.sqlite").unwrap();
            rusqlite::Connection::open(&path).unwrap().execute_batch("CREATE TABLE t (x)").unwrap();
            converted::Converted::new(path)
        };
        let lite = make();
        let temp = lite.path().to_path_buf();
        let target = dir.path().join("saved.sqlite");
        assert!(lite.save(&target).is_ok());
        assert!(target.is_file() && !temp.exists());

        let lite = make();
        let temp = lite.path().to_path_buf();
        let (lite, _) = lite.save(&dir.path().join("missing folder").join("x.sqlite")).err().unwrap();
        assert!(temp.is_file(), "a failed save keeps the temporary");
        drop(lite);
        assert!(!temp.exists());

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

    // nomes de temporario reservados de forma exclusiva: chamadas seguidas nunca repetem nem reaproveitam arquivo
    #[test]
    fn temporary_names_are_reserved_exclusively() {
        let a = converted::new_temp_path("x.csv").unwrap();
        let b = converted::new_temp_path("x.csv").unwrap();
        assert_ne!(a, b);
        assert!(a.is_file() && b.is_file());
        let _ = std::fs::remove_file(a);
        let _ = std::fs::remove_file(b);
    }

    #[test]
    fn search_matches_all_words_in_one_cell_ignoring_case_and_accents() {
        assert!(search_condition(&["a".into()], "   ").is_none());
        let (sql, params) = search_condition(&["co\"l".into(), "b".into()], "x y").unwrap();
        assert_eq!(params.len(), 4);
        assert!(sql.contains("CAST(\"co\"\"l\" AS VARCHAR)") && sql.contains(" OR ") && sql.contains(" AND "), "{sql}");
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
    // acentos), so nas colunas de texto, na ordem da lista; DuckDB anexado e SQLite copiado para a memoria
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
                 INSERT INTO c_numbers VALUES (1, 7);",
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
        assert_eq!(found("7"), [], "numbers are not text columns");
        // abrir a tabela achada com a mesma pesquisa da a mesma contagem
        assert_eq!(manager.get_row_count("b_points", &[], "TENSAO").unwrap(), 2);

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
}
