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
                "CREATE TABLE points (id INTEGER, name VARCHAR, ts TIMESTAMP);
                 INSERT INTO points VALUES (1, 'a', TIMESTAMP '2026-07-14 10:00:00'), (2, NULL, NULL);",
            )
            .unwrap();
        }

        let manager = DBManager::new();
        manager.connect(path.to_str().unwrap()).expect("connect");
        assert_eq!(manager.list_tables().unwrap(), vec!["points"]);
        assert_eq!(manager.get_row_count("points").unwrap(), 2);

        let schema = manager.get_table_schema("points").unwrap();
        let names: Vec<&str> = schema.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["id", "name", "ts"]);

        let rows = manager.query_table("points", 10).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["id"], 1);
        assert_eq!(rows[0]["name"], "a");
        assert!(rows[1]["name"].is_null());
        assert!(manager.query_table("missing", 10).is_err());
    }
}
