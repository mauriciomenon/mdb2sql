// NIVEL BASICO: Leitura de .mdb/.accdb para o DuckDB em memoria
// Ordem: a) driver ODBC "Microsoft Access Driver (*.mdb, *.accdb)" (64 bits) se instalado;
//        b) reserva: mdbtools estatico embutido no exe, extraido para %LOCALAPPDATA%\mdb2sql\;
//        c) nenhum dos dois: mensagem dizendo o que instalar.
// MDB2SQL_ACCESS_READER=odbc|mdbtools forca um dos caminhos.

use super::db_manager::{ident, literal};
use duckdb::types::Value as DuckValue;
use odbc_api::{
    ConnectionOptions, Cursor, DataType, Nullable, ResultSetMetadata, environment, escape_attribute_value,
};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

pub const ACCESS_DRIVER: &str = "Microsoft Access Driver (*.mdb, *.accdb)";
pub const MDBTOOLS_VERSION: &str = "1.0.1";
const INSTALL_HINT: &str = "Install the Microsoft Access Database Engine 2016 Redistributable, 64-bit \
    (accessdatabaseengine_X64.exe, free from Microsoft), or convert the file to .duckdb or .sqlite.";

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Reader {
    Odbc,
    Mdbtools,
}

impl Reader {
    // texto da barra de status
    pub fn label(self) -> &'static str {
        match self {
            Reader::Odbc => "Access ODBC",
            Reader::Mdbtools => "mdbtools",
        }
    }
}

// NIVEL BASICO: Escolhe o leitor do Access
// forced = MDB2SQL_ACCESS_READER; odbc = driver instalado; mdbtools = Ok se o mdbtools embutido esta pronto
pub(crate) fn choose_reader(forced: Option<&str>, odbc: bool, mdbtools: &Result<PathBuf, String>) -> Result<Reader, String> {
    let tools_error = || format!("the embedded mdbtools could not be used ({})", mdbtools.as_ref().err().map_or("", |e| e));
    match forced.map(str::trim).unwrap_or("").to_ascii_lowercase().as_str() {
        "" if odbc => Ok(Reader::Odbc),
        "" if mdbtools.is_ok() => Ok(Reader::Mdbtools),
        "" => Err(format!(
            "Cannot read .mdb/.accdb: the Microsoft Access ODBC driver (64-bit) is not installed and {}. {INSTALL_HINT}",
            tools_error()
        )),
        "odbc" if odbc => Ok(Reader::Odbc),
        "odbc" => Err(format!(
            "MDB2SQL_ACCESS_READER=odbc, but the Microsoft Access ODBC driver (64-bit) is not installed. {INSTALL_HINT}"
        )),
        "mdbtools" if mdbtools.is_ok() => Ok(Reader::Mdbtools),
        "mdbtools" => Err(format!("MDB2SQL_ACCESS_READER=mdbtools, but {}.", tools_error())),
        other => Err(format!("MDB2SQL_ACCESS_READER must be odbc or mdbtools, got: {other}")),
    }
}

// NIVEL BASICO: O driver ODBC do Access (da mesma arquitetura do exe, 64 bits) esta instalado?
pub fn odbc_installed() -> bool {
    environment()
        .and_then(|env| env.drivers())
        .is_ok_and(|drivers| drivers.iter().any(|d| d.description == ACCESS_DRIVER))
}

// NIVEL BASICO: Copia todas as tabelas do Access para o DuckDB em memoria; devolve o leitor usado
pub fn import(
    duck: &duckdb::Connection,
    path: &str,
    progress: &mut dyn FnMut(usize, usize, &str),
) -> Result<String, String> {
    let forced = std::env::var("MDB2SQL_ACCESS_READER").ok();
    let tools = mdbtools_dir();
    let reader = choose_reader(forced.as_deref(), odbc_installed(), &tools)?;
    match reader {
        Reader::Odbc => import_odbc(duck, path, progress),
        Reader::Mdbtools => import_mdbtools(duck, &tools?, path, progress),
    }
    .map(|_| reader.label().to_string())
    .map_err(|e| format!("{}: {e}", reader.label()))
}

// ---------------------------------------------------------------------------------------------
// a) ODBC

enum Fetch {
    Float,
    Binary,
    Text,
}

// NIVEL BASICO: Tipo ODBC da coluna vira tipo do DuckDB e o jeito de buscar o valor
// NIVEL TECNICO: numbers that must stay exact (DECIMAL, integers, dates) travel as text and
// DuckDB casts them on append; floating point goes as f64 to keep every digit
fn odbc_column(data_type: DataType) -> (String, Fetch) {
    let text = |t: &str| (t.to_string(), Fetch::Text);
    match data_type {
        DataType::Bit => text("BOOLEAN"),
        // o Byte do Access vai de 0 a 255
        DataType::TinyInt | DataType::SmallInt => text("SMALLINT"),
        DataType::Integer => text("INTEGER"),
        DataType::BigInt => text("BIGINT"),
        DataType::Real => ("FLOAT".into(), Fetch::Float),
        DataType::Float { .. } | DataType::Double => ("DOUBLE".into(), Fetch::Float),
        DataType::Numeric { precision, scale } | DataType::Decimal { precision, scale }
            if (1..=38).contains(&precision) && (0..=precision as i16).contains(&scale) =>
        {
            text(&format!("DECIMAL({precision},{scale})"))
        }
        DataType::Timestamp { .. } => text("TIMESTAMP"),
        DataType::Date => text("DATE"),
        DataType::Time { .. } => text("TIME"),
        DataType::LongVarbinary { .. } | DataType::Varbinary { .. } | DataType::Binary { .. } => {
            ("BLOB".into(), Fetch::Binary)
        }
        _ => text("VARCHAR"),
    }
}

fn import_odbc(duck: &duckdb::Connection, path: &str, progress: &mut dyn FnMut(usize, usize, &str)) -> Result<(), String> {
    let err = |e: odbc_api::Error| e.to_string();
    let env = environment().map_err(err)?;
    let conn_str = format!(
        "Driver={{{ACCESS_DRIVER}}};Dbq={};ReadOnly=1;Exclusive=0;",
        escape_attribute_value(path)
    );
    let conn = env.connect_with_connection_string(&conn_str, ConnectionOptions::default()).map_err(err)?;

    let mut tables = Vec::new();
    for row in conn.tables("", "", "", "TABLE").map_err(err)? {
        let row = row.map_err(err)?;
        // shortcut: names come in the ANSI code page; a non-ASCII table name would not match
        if let Some(name) = row.table.as_bytes() {
            tables.push(String::from_utf8_lossy(name).into_owned());
        }
    }
    tables.sort();

    for (i, table) in tables.iter().enumerate() {
        progress(i, tables.len(), table);
        let mut cursor = conn
            .execute(&format!("SELECT * FROM [{table}]"), (), None)
            .map_err(|e| format!("{table}: {e}"))?
            .ok_or_else(|| format!("{table}: no result set"))?;
        let ncols = cursor.num_result_cols().map_err(err)? as u16;
        let mut defs = Vec::new();
        let mut fetch = Vec::new();
        for col in 1..=ncols {
            let name = cursor.col_name(col).map_err(err)?;
            let (duck_type, how) = odbc_column(cursor.col_data_type(col).map_err(err)?);
            defs.push(format!("{} {duck_type}", ident(&name)));
            fetch.push(how);
        }
        duck.execute_batch(&format!("CREATE TABLE {} ({})", ident(table), defs.join(", ")))
            .map_err(|e| format!("{table}: {e}"))?;

        let mut appender = duck.appender(table).map_err(|e| e.to_string())?;
        let (mut text, mut bytes) = (Vec::<u16>::new(), Vec::<u8>::new());
        while let Some(mut row) = cursor.next_row().map_err(err)? {
            let mut values = Vec::with_capacity(fetch.len());
            for (c, how) in fetch.iter().enumerate() {
                let col = c as u16 + 1;
                values.push(match how {
                    Fetch::Float => {
                        let mut v = Nullable::<f64>::null();
                        row.get_data(col, &mut v).map_err(err)?;
                        v.into_opt().map_or(DuckValue::Null, DuckValue::Double)
                    }
                    Fetch::Binary if row.get_binary(col, &mut bytes).map_err(err)? => DuckValue::Blob(bytes.clone()),
                    // UTF-16: o texto "estreito" do driver viria na pagina de codigo do Windows
                    Fetch::Text if row.get_wide_text(col, &mut text).map_err(err)? => {
                        DuckValue::Text(String::from_utf16_lossy(&text))
                    }
                    _ => DuckValue::Null,
                });
            }
            appender
                .append_row(duckdb::appender_params_from_iter(values))
                .map_err(|e| format!("{table}: {e}"))?;
        }
        appender.flush().map_err(|e| format!("{table}: {e}"))?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// b) mdbtools

// NIVEL BASICO: mdbtools estatico dentro do exe (baixado pelo scripts\setup_tools.ps1, sha256 conferido)
#[cfg(windows)]
// COPYING (GPL, os exes) e COPYING.LIB (LGPL, a libmdb ligada neles) vao junto, como a licenca pede
const MDBTOOLS_FILES: [(&str, &[u8]); 6] = [
    ("mdb-tables.exe", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/.tools/mdbtools-1.0.1-w11-amd64/mdb-tables.exe"))),
    ("mdb-schema.exe", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/.tools/mdbtools-1.0.1-w11-amd64/mdb-schema.exe"))),
    ("mdb-export.exe", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/.tools/mdbtools-1.0.1-w11-amd64/mdb-export.exe"))),
    ("COPYING", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/.tools/mdbtools-1.0.1-w11-amd64/COPYING"))),
    ("COPYING.LIB", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/.tools/mdbtools-1.0.1-w11-amd64/COPYING.LIB"))),
    ("VERSION.txt", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/.tools/mdbtools-1.0.1-w11-amd64/VERSION.txt"))),
];

// NIVEL BASICO: Extrai o mdbtools para %LOCALAPPDATA%\mdb2sql\rust-tauri-svelte-<versao>\mdbtools (uma pasta
// por versao do app) e apaga as pastas de versoes antigas deste stack; os outros stacks usam outro prefixo
#[cfg(windows)]
fn mdbtools_dir() -> Result<PathBuf, String> {
    let base = PathBuf::from(std::env::var_os("LOCALAPPDATA").ok_or("LOCALAPPDATA is not set")?).join("mdb2sql");
    let prefix = "rust-tauri-svelte-";
    let current = format!("{prefix}{}", env!("CARGO_PKG_VERSION"));
    let dir = base.join(&current).join("mdbtools");
    let io = |e: std::io::Error| format!("{}: {e}", dir.display());
    std::fs::create_dir_all(&dir).map_err(io)?;
    for (name, bytes) in MDBTOOLS_FILES {
        let file = dir.join(name);
        if std::fs::metadata(&file).map(|m| m.len()).ok() != Some(bytes.len() as u64) {
            // grava ao lado e renomeia: um exe pela metade nunca fica com o nome final
            let partial = dir.join(format!("{name}.partial"));
            std::fs::write(&partial, bytes).map_err(io)?;
            std::fs::rename(&partial, &file).map_err(io)?;
        }
    }
    for entry in std::fs::read_dir(&base).map_err(io)?.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with(prefix) && name != current {
            // shortcut: a folder still in use by another running version stays until the next start
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
    Ok(dir)
}

// fora do Windows usa o mdbtools do sistema (pacote mdbtools), pelo PATH
#[cfg(not(windows))]
fn mdbtools_dir() -> Result<PathBuf, String> {
    Ok(PathBuf::new())
}

fn mdb_tool(dir: &Path, name: &str) -> Command {
    let mut cmd = Command::new(dir.join(format!("{name}{}", std::env::consts::EXE_SUFFIX)));
    #[cfg(windows)]
    {
        // CREATE_NO_WINDOW: o app e grafico, sem isto cada chamada pisca uma janela de console
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    cmd
}

fn run(mut cmd: Command) -> Result<String, String> {
    let out = cmd.output().map_err(|e| format!("{:?}: {e}", cmd.get_program()))?;
    if !out.status.success() {
        return Err(format!("{:?} failed: {}", cmd.get_program(), String::from_utf8_lossy(&out.stderr).trim()));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

// NIVEL BASICO: Tipo do "mdb-schema ... postgres" vira tipo do DuckDB
pub(crate) fn pg_to_duck(pg: &str) -> String {
    let t = pg.trim().to_ascii_uppercase();
    if let Some(args) = t.strip_prefix("NUMERIC").map(|a| a.trim().trim_start_matches('(').trim_end_matches(')')) {
        let nums: Vec<u32> = args.split(',').filter_map(|a| a.trim().parse().ok()).collect();
        return match nums.as_slice() {
            [p, s] if (1..=38).contains(p) && s <= p => format!("DECIMAL({p},{s})"),
            _ => "DOUBLE".into(),
        };
    }
    match t.as_str() {
        "DOUBLE PRECISION" => "DOUBLE",
        "REAL" => "FLOAT",
        "INTEGER" | "SERIAL" => "INTEGER",
        "SMALLINT" => "SMALLINT",
        "BIGINT" => "BIGINT",
        "BOOLEAN" => "BOOLEAN",
        "DATE" => "DATE",
        "BYTEA" => "BLOB",
        "MONEY" => "DECIMAL(19,4)",
        _ if t.starts_with("TIMESTAMP") => "TIMESTAMP",
        _ => "VARCHAR",
    }
    .into()
}

// NIVEL BASICO: Le os tipos das colunas de cada tabela no SQL gerado pelo mdb-schema (backend postgres)
// Chave: nome da tabela em minusculas (o backend postgres poe tudo em minusculas); valor: tipos na ordem das colunas
pub(crate) fn parse_pg_schema(sql: &str) -> HashMap<String, Vec<String>> {
    let mut tables = HashMap::new();
    let mut current: Option<String> = None;
    for line in sql.lines() {
        if let Some(rest) = line.strip_prefix("CREATE TABLE") {
            let name = rest.trim().trim_start_matches("IF NOT EXISTS").trim().trim_matches('"').replace("\"\"", "\"");
            tables.insert(name.to_lowercase(), Vec::new());
            current = Some(name.to_lowercase());
        } else if line.starts_with(");") {
            current = None;
        } else if let (Some(table), Some(end)) = (&current, line.rfind('"')) {
            // coluna: <tab>"nome"<tabs>TIPO,  (o tipo nunca tem aspas)
            if line.trim_start().starts_with('"') {
                let pg = line[end + 1..].trim().trim_end_matches(',').trim();
                if let Some(cols) = tables.get_mut(table) {
                    cols.push(pg_to_duck(pg));
                }
            }
        }
    }
    tables
}

fn import_mdbtools(
    duck: &duckdb::Connection,
    dir: &Path,
    path: &str,
    progress: &mut dyn FnMut(usize, usize, &str),
) -> Result<(), String> {
    let mut tables_cmd = mdb_tool(dir, "mdb-tables");
    tables_cmd.args(["-1", path]);
    let mut tables: Vec<String> = run(tables_cmd)?.lines().filter(|l| !l.is_empty()).map(str::to_string).collect();
    tables.sort();

    let mut schema_cmd = mdb_tool(dir, "mdb-schema");
    // sem restricoes: a linha de cada coluna fica so "nome tipo," (o parser abaixo conta com isso)
    schema_cmd.args([
        path, "postgres", "--no-indexes", "--no-relations", "--no-comments", "--no-drop-table", "--no-not-null",
        "--no-default-values", "--no-not_empty",
    ]);
    let schema = parse_pg_schema(&run(schema_cmd)?);

    let csv = std::env::temp_dir().join(format!("mdb2sql-{}-mdbtools.csv", std::process::id()));
    let result = (|| {
        for (i, table) in tables.iter().enumerate() {
            progress(i, tables.len(), table);
            let file = std::fs::File::create(&csv).map_err(|e| e.to_string())?;
            let mut export = mdb_tool(dir, "mdb-export");
            let iso = "%Y-%m-%d %H:%M:%S";
            export.args(["-D", iso, "-T", iso, "-b", "hex", path, table]).stdout(file);
            let out = export.output().map_err(|e| e.to_string())?;
            if !out.status.success() {
                return Err(format!("mdb-export {table}: {}", String::from_utf8_lossy(&out.stderr).trim()));
            }

            // tipos por posicao; BLOB chega em hex e e convertido depois. Sem tipos no esquema: tudo texto
            let types = schema.get(&table.to_lowercase());
            let typing = match types {
                Some(t) => {
                    let list: Vec<String> = t.iter().map(|t| literal(if t == "BLOB" { "VARCHAR" } else { t })).collect();
                    format!("types = [{}]", list.join(", "))
                }
                None => "all_varchar = true".to_string(),
            };
            // allow_quoted_nulls = false: "" e texto vazio; so o campo sem nada e NULL
            duck.execute_batch(&format!(
                "CREATE TABLE {} AS SELECT * FROM read_csv({}, header = true, delim = ',', quote = '\"', escape = '\"', \
                 allow_quoted_nulls = false, {typing})",
                ident(table),
                literal(&csv.to_string_lossy())
            ))
            .map_err(|e| format!("{table}: {e}"))?;

            for (c, t) in types.into_iter().flatten().enumerate() {
                if t == "BLOB" {
                    let name: String = duck
                        .query_row(&format!("SELECT name FROM pragma_table_info({}) WHERE cid = {c}", literal(table)), [], |r| r.get(0))
                        .map_err(|e| e.to_string())?;
                    duck.execute_batch(&format!(
                        "ALTER TABLE {0} ALTER COLUMN {1} TYPE BLOB USING unhex({1})",
                        ident(table),
                        ident(&name)
                    ))
                    .map_err(|e| format!("{table}: {e}"))?;
                }
            }
        }
        Ok(())
    })();
    let _ = std::fs::remove_file(&csv); // temporario; se sobrar, o %TEMP% e limpo pelo Windows
    result
}
