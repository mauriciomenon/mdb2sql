#[cfg(test)]
mod tests {
    use crate::backend::db_manager::DBManager;
    use std::fs::File;
    use tempfile::tempdir;
    use std::path::PathBuf;

    #[test]
    fn validate_database_path_rejects_bad_ext() {
        let manager = DBManager::new();
        let dir = tempdir().unwrap();
        let path = dir.path().join("file.txt");
        File::create(&path).unwrap();

        let err = manager.validate_database_path(path.to_str().unwrap());
        assert!(err.is_err());
        assert!(err.unwrap_err().contains("Only .duckdb and .db files are supported"));
    }

    #[test]
    fn load_sample_duckdb_lists_tables_and_rows() {
        let manager = DBManager::new();
        let path = PathBuf::from("../data/sample.duckdb");
        if !path.exists() {
            eprintln!("sample.duckdb not found, skipping");
            return;
        }

        manager.connect(path.to_str().unwrap()).expect("connect sample");
        let tables = manager.list_tables().expect("list tables");
        assert!(
            !tables.is_empty(),
            "expected tables in sample.duckdb, got none"
        );
        // use first table to verify queries
        let table = tables[0].clone();
        let rows = manager.query_table(&table, 2).expect("query rows");
        assert!(
            !rows.is_empty(),
            "expected rows from sample table {}, got none",
            table
        );
        let count = manager.get_row_count(&table).expect("row count");
        assert!(count >= rows.len() as i64);
    }

    // Nao depende de data/sample.duckdb (ignorado pelo git): cria o banco no teste
    #[test]
    fn connect_opens_real_file_read_only() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("real.duckdb");
        {
            let conn = duckdb::Connection::open(&path).unwrap();
            conn.execute_batch(
                "CREATE TABLE points (id INTEGER, name VARCHAR, ts TIMESTAMP, d DATE, t TIME, n DECIMAL(10,2), u UINTEGER);
                 INSERT INTO points VALUES
                   (1, 'a', TIMESTAMP '2026-07-14 10:00:00', DATE '2024-02-29', TIME '23:59:58.5', 12.30, 7),
                   (2, NULL, NULL, NULL, NULL, NULL, NULL);",
            )
            .unwrap();
        }

        let manager = DBManager::new();
        manager.connect(path.to_str().unwrap()).expect("connect");
        assert_eq!(manager.list_tables().unwrap(), vec!["points"]);
        assert_eq!(manager.get_row_count("points").unwrap(), 2);

        let schema = manager.get_table_schema("points").unwrap();
        let names: Vec<&str> = schema.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["id", "name", "ts", "d", "t", "n", "u"]);

        let rows = manager.query_table("points", 10).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["id"], 1);
        assert_eq!(rows[0]["name"], "a");
        assert!(rows[1]["name"].is_null());
        // datas e horas saem como texto ISO, nao na forma de debug do Rust
        assert_eq!(rows[0]["ts"], "2026-07-14 10:00:00");
        assert_eq!(rows[0]["d"], "2024-02-29");
        assert_eq!(rows[0]["t"], "23:59:58.5");
        assert_eq!(rows[0]["n"], "12.30");
        assert_eq!(rows[0]["u"], 7);
        assert!(rows[1]["ts"].is_null());
        assert!(manager.query_table("missing", 10).is_err());
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
}
