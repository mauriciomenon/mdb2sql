#[cfg(test)]
#[allow(clippy::module_inception)] // backend::tests::tests: the wrapper keeps the cfg(test) in this file
mod tests {
    use crate::backend::access::{Reader, choose_reader, parse_pg_schema, pg_to_duck};
    use crate::backend::db_manager::DBManager;
    use crate::backend::export::{self, EXCEL_MAX_DATA_ROWS, SheetNamer, Source};
    use crate::backend::sqlite_io::duck_type;
    use std::fs::File;
    use std::path::{Path, PathBuf};
    use tempfile::tempdir;

    fn no_progress() -> impl FnMut(usize, usize, &str) {
        |_, _, _| {}
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
        assert!(err.unwrap_err().contains("Only .duckdb, .db, .sqlite, .sqlite3, .mdb and .accdb"));
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
        let rows = manager.query_table(&tables[0], 2).expect("query rows");
        assert!(!rows.is_empty());
        assert!(manager.get_row_count(&tables[0]).unwrap() >= rows.len() as i64);
    }

    // Nao depende de data/sample.duckdb (ignorado pelo git): cria o banco no teste
    #[test]
    fn connect_opens_real_file_read_only() {
        let dir = tempdir().unwrap();
        let path = sample_duckdb(dir.path());

        let manager = DBManager::new();
        let source = manager.connect(path.to_str().unwrap(), &mut no_progress()).expect("connect");
        assert_eq!(source, "DuckDB");
        assert_eq!(manager.list_tables().unwrap(), vec!["Other table", "points"]);
        assert_eq!(manager.get_row_count("points").unwrap(), 2);

        let schema = manager.get_table_schema("points").unwrap();
        let names: Vec<&str> = schema.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["id", "name", "ts", "d", "t", "n", "u", "ok", "x"]);

        let rows = manager.query_table("points", 10).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["id"], 1);
        assert!(rows[1]["name"].is_null());
        // datas e horas saem como texto ISO, nao na forma de debug do Rust
        assert_eq!(rows[0]["ts"], "2026-07-14 10:00:00");
        assert_eq!(rows[0]["d"], "2024-02-29");
        assert_eq!(rows[0]["t"], "23:59:58.5");
        assert_eq!(rows[0]["n"], "12.30");
        assert_eq!(rows[0]["u"], 7);
        assert!(manager.query_table("missing", 10).is_err());

        // somente leitura: o SQL livre nao consegue gravar no arquivo aberto
        assert!(manager.run_sql("INSERT INTO points VALUES (3, 'x', NULL, NULL, NULL, NULL, NULL, NULL, NULL)", 10).is_err());
        let result = manager.run_sql("SELECT id, name FROM points ORDER BY id", 1).unwrap();
        assert_eq!(result.columns.len(), 2);
        assert_eq!(result.rows.len(), 1);
        assert!(result.truncated);
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
            assert_eq!(summary, "2 tables");
            assert!(!dir.path().join(format!("out.{format}.partial")).exists());

            let reopened = DBManager::new();
            assert_eq!(reopened.connect(out.to_str().unwrap(), &mut no_progress()).unwrap(), label);
            assert_eq!(reopened.list_tables().unwrap(), vec!["Other table", "points"]);
            assert_eq!(reopened.get_row_count("Other table").unwrap(), 5);
            let types: Vec<String> = reopened.get_table_schema("points").unwrap().into_iter().map(|c| c.col_type).collect();
            assert_eq!(types, ["INTEGER", "VARCHAR", "TIMESTAMP", "DATE", "TIME", "DECIMAL(10,2)", "UINTEGER", "BOOLEAN", "DOUBLE"], "{format}");
            let rows = reopened.query_table("points", 10).unwrap();
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
        assert_eq!(manager.connect(path.to_str().unwrap(), &mut no_progress()).unwrap(), "SQLite");
        assert_eq!(manager.get_row_count("t").unwrap(), 2);
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
        let rows = manager.query_table("t", 10).unwrap();
        assert_eq!((rows[0]["a"].clone(), rows[1]["a"].clone()), ("1".into(), "abc".into()));
    }

    #[test]
    fn sqlite_declared_types_map_to_duckdb() {
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
        assert_eq!(export::export_source(&conn, &table, "csv", &csv, &mut ok_progress()).unwrap(), "2 rows");
        let text = std::fs::read_to_string(&csv).unwrap();
        let mut lines = text.split("\r\n");
        assert_eq!(lines.next().unwrap(), "\u{FEFF}id,name,ts,d,t,n,u,ok,x");
        assert_eq!(lines.next().unwrap(), "1,\"a, \"\"b\"\"\",2026-07-14 10:00:00,2024-02-29,23:59:58.5,12.30,7,true,0.1");
        assert_eq!(lines.next().unwrap(), "2,,,,,,,,");

        let sql = Source::Sql("SELECT k FROM \"Other table\" WHERE k > 2;".into());
        let xlsx = dir.path().join("result.xlsx");
        assert_eq!(export::export_source(&conn, &sql, "xlsx", &xlsx, &mut ok_progress()).unwrap(), "2 rows in 1 sheet(s)");
        let all = dir.path().join("all.xlsx");
        assert_eq!(export::export_database(&conn, "xlsx", &all, &mut ok_progress()).unwrap(), "2 tables in 2 sheets");
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
    }

    // Banco Access real (fora do git): MDB2SQL_TEST_ACCDB=<copia do .accdb> e MDB2SQL_TEST_DUCKDB=<conversao de
    // referencia>. Abre pelos dois leitores, confere tabelas e linhas contra a referencia e compara os dois
    // leitores celula a celula. Sem as variaveis o teste nao faz nada.
    #[test]
    fn real_access_file_reads_the_same_by_odbc_and_mdbtools() {
        let (Ok(accdb), Ok(reference)) = (std::env::var("MDB2SQL_TEST_ACCDB"), std::env::var("MDB2SQL_TEST_DUCKDB")) else {
            eprintln!("MDB2SQL_TEST_ACCDB/MDB2SQL_TEST_DUCKDB not set, skipping");
            return;
        };
        let dir = tempdir().unwrap();
        let mut outputs = Vec::new();
        for reader in ["odbc", "mdbtools"] {
            // unica escrita na variavel; os outros testes nao abrem Access
            unsafe { std::env::set_var("MDB2SQL_ACCESS_READER", reader) };
            let manager = DBManager::new();
            let started = std::time::Instant::now();
            let source = manager.connect(&accdb, &mut no_progress()).unwrap();
            eprintln!("{reader}: {source}, {} tables in {:?}", manager.list_tables().unwrap().len(), started.elapsed());
            let out = dir.path().join(format!("{reader}.duckdb"));
            export::export_database(&manager.export_connection().unwrap(), "duckdb", &out, &mut ok_progress()).unwrap();
            outputs.push(out);
        }
        unsafe { std::env::remove_var("MDB2SQL_ACCESS_READER") };

        let conn = duckdb::Connection::open_in_memory().unwrap();
        let attach = |path: &Path, name: &str| {
            conn.execute_batch(&format!("ATTACH '{}' AS {name} (READ_ONLY)", path.display())).unwrap();
        };
        attach(Path::new(&reference), "ref");
        attach(&outputs[0], "odbc");
        attach(&outputs[1], "mdbt");
        let tables: Vec<String> = conn
            .prepare("SELECT table_name FROM duckdb_tables() WHERE database_name = 'ref' ORDER BY 1")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        let count = |sql: String| -> i64 { conn.query_row(&sql, [], |r| r.get(0)).unwrap_or_else(|e| panic!("{sql}: {e}")) };
        let mut differences = Vec::new();
        for t in &tables {
            let q = format!("\"{}\"", t.replace('"', "\"\""));
            let expected = count(format!("SELECT count(*) FROM ref.{q}"));
            assert_eq!(count(format!("SELECT count(*) FROM odbc.{q}")), expected, "odbc {t}");
            assert_eq!(count(format!("SELECT count(*) FROM mdbt.{q}")), expected, "mdbtools {t}");
            let diff = count(format!(
                "SELECT count(*) FROM ((SELECT * FROM odbc.{q} EXCEPT ALL SELECT * FROM mdbt.{q}) \
                 UNION ALL (SELECT * FROM mdbt.{q} EXCEPT ALL SELECT * FROM odbc.{q}))"
            ));
            if diff != 0 {
                differences.push(format!("{t}: {diff}"));
            }
        }
        eprintln!("{} tables, readers differ in: {differences:?}", tables.len());
        assert!(differences.is_empty(), "{differences:?}");
    }
}
