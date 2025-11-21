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
}
