// NIVEL BASICO: Exportacao: banco inteiro para .duckdb, .sqlite ou .xlsx (uma aba por tabela);
// tabela atual ou resultado do SQL para .csv (UTF-8 com BOM) ou .xlsx.
// .mdb/.accdb nao: nao ha biblioteca confiavel para gravar Access.
//
// NIVEL TECNICO: every writer goes to a unique "<file>.<pid>-<n>.partial" renamed at the end, so a cancel or
// an error never leaves a half-written file under the chosen name. progress() returns Err to cancel.

use super::db_manager::{ident, json_text, list_tables, literal, value_to_json};
use super::sqlite_io;
use duckdb::Connection;
use duckdb::types::ValueRef;
use rust_xlsxwriter::{ExcelDateTime, Format, Workbook, Worksheet, XlsxError};
use std::collections::HashSet;
use std::io::Write;
use std::path::{Path, PathBuf};

// limite do Excel: 1.048.576 linhas, uma e o cabecalho
pub const EXCEL_MAX_DATA_ROWS: usize = 1_048_575;
const EXCEL_MAX_TEXT: usize = 32_767;
const EXCEL_MAX_SHEET_NAME: usize = 31;
// a cada tantas linhas a exportacao avisa o progresso (e confere o Cancelar)
const ROWS_PER_TICK: usize = 10_000;

pub type Progress<'a> = &'a mut dyn FnMut(usize, usize, &str) -> Result<(), String>;

// NIVEL BASICO: O que foi gravado: tabelas (banco inteiro) ou linhas (tabela/SQL), e abas se foi Excel
// a interface monta a frase no idioma escolhido
#[derive(Debug, PartialEq, serde::Serialize)]
pub struct Summary {
    pub count: usize,
    pub sheets: Option<usize>,
}

// NIVEL BASICO: O que exportar na exportacao de uma fonte so: tabela atual, so as linhas dela que a pesquisa e os
// filtros da aba Data acharam, ou resultado do SQL
pub enum Source {
    Table(String),
    // tabela, " WHERE ..." (de DBManager::rows_where) e os parametros dele: valores e palavras nunca vao no texto do SQL
    Rows(String, String, Vec<duckdb::types::Value>),
    Sql(String),
}

impl Source {
    fn select(&self) -> String {
        match self {
            Source::Table(t) => format!("SELECT * FROM {}", ident(t)),
            Source::Rows(t, filter, _) => format!("SELECT * FROM {}{filter}", ident(t)),
            Source::Sql(s) => s.trim().trim_end_matches(';').to_string(),
        }
    }

    fn params(&self) -> &[duckdb::types::Value] {
        match self {
            Source::Rows(_, _, params) => params,
            _ => &[],
        }
    }

    fn sheet_base(&self) -> &str {
        match self {
            Source::Table(t) | Source::Rows(t, _, _) => t,
            Source::Sql(_) => "Result",
        }
    }
}

fn utf16_len(text: &str) -> usize {
    text.encode_utf16().count()
}

// corta o texto para caber em `max` unidades UTF-16 (a conta do Excel), sem partir caractere
fn truncate_utf16(text: &str, max: usize) -> &str {
    let mut used = 0;
    for (i, c) in text.char_indices() {
        used += c.len_utf16();
        if used > max {
            return &text[..i];
        }
    }
    text
}

// NIVEL BASICO: Nomes de aba validos e sem repeticao
// Excel: ate 31 caracteres, sem [ ] : * ? / \, sem apostrofo no inicio/fim, "History" reservado,
// e duas abas nao podem ter o mesmo nome sem diferenciar maiusculas.
// part > 1 vira o sufixo " (part)" das tabelas que passam do limite de linhas; nome cortado que colide
// com outro ganha "~2", "~3"...
#[derive(Default)]
pub struct SheetNamer {
    used: HashSet<String>,
}

impl SheetNamer {
    pub fn name(&mut self, base: &str, part: usize) -> String {
        let clean: String = base
            .chars()
            .map(|c| if "[]:*?/\\".contains(c) || c.is_control() { '_' } else { c })
            .collect();
        let clean = match clean.trim_matches('\'') {
            "" => "Sheet",
            text => text,
        };
        let suffix = if part > 1 { format!(" ({part})") } else { String::new() };
        for n in 1.. {
            let tag = if n == 1 { String::new() } else { format!("~{n}") };
            let room = EXCEL_MAX_SHEET_NAME - utf16_len(&tag) - utf16_len(&suffix);
            let head = truncate_utf16(clean, room).trim_end_matches('\'');
            let name = format!("{head}{tag}{suffix}");
            if !name.eq_ignore_ascii_case("history") && self.used.insert(name.to_lowercase()) {
                return name;
            }
        }
        unreachable!("the loop above always returns")
    }
}

fn xlsx_err(e: XlsxError) -> String {
    format!("Excel: {e}")
}

// NIVEL BASICO: Escreve um valor do DuckDB numa celula com o tipo mais proximo
// Numeros com mais de 15 digitos significativos vao como texto (o Excel arredondaria);
// datas viram data do Excel (antes de 1900 o Excel nao tem data: vai texto); texto e cortado em 32.767.
fn write_cell(ws: &mut Worksheet, row: u32, col: u16, value: ValueRef, date: &Format, datetime: &Format) -> Result<(), XlsxError> {
    const EXACT: u128 = 1 << 53;
    let text = |v: ValueRef| json_text(&value_to_json(v));
    match value {
        ValueRef::Null => return Ok(()),
        ValueRef::Boolean(b) => ws.write_boolean(row, col, b),
        ValueRef::TinyInt(i) => ws.write_number(row, col, i),
        ValueRef::SmallInt(i) => ws.write_number(row, col, i),
        ValueRef::Int(i) => ws.write_number(row, col, i),
        ValueRef::UTinyInt(i) => ws.write_number(row, col, i),
        ValueRef::USmallInt(i) => ws.write_number(row, col, i),
        ValueRef::UInt(i) => ws.write_number(row, col, i),
        ValueRef::BigInt(i) if u128::from(i.unsigned_abs()) <= EXACT => ws.write_number(row, col, i as f64),
        ValueRef::UBigInt(i) if u128::from(i) <= EXACT => ws.write_number(row, col, i as f64),
        ValueRef::HugeInt(i) if i.unsigned_abs() <= EXACT => ws.write_number(row, col, i as f64),
        ValueRef::Float(f) if f.is_finite() => ws.write_number(row, col, f),
        ValueRef::Double(f) if f.is_finite() => ws.write_number(row, col, f),
        ValueRef::Decimal(d) => {
            let s = d.to_string();
            let digits = s.trim_start_matches(['-', '0', '.']).chars().filter(char::is_ascii_digit).count();
            match s.parse::<f64>() {
                Ok(f) if digits <= 15 => ws.write_number(row, col, f),
                _ => ws.write_string(row, col, s),
            }
        }
        ValueRef::Timestamp(..) | ValueRef::Date32(_) => {
            let s = text(value);
            let format = if matches!(value, ValueRef::Date32(_)) { date } else { datetime };
            match ExcelDateTime::parse_from_str(&s) {
                Ok(dt) => ws.write_datetime_with_format(row, col, &dt, format),
                Err(_) => ws.write_string(row, col, s),
            }
        }
        ValueRef::Text(t) => {
            let s = String::from_utf8_lossy(t);
            ws.write_string(row, col, truncate_utf16(&s, EXCEL_MAX_TEXT))
        }
        other => ws.write_string(row, col, truncate_utf16(&text(other), EXCEL_MAX_TEXT)),
    }
    .map(|_| ())
}

// NIVEL BASICO: Resultado de um SELECT em abas: cabecalho na 1a linha, nova aba "<nome> (2)" a cada
// max_rows linhas de dados. Devolve (nome da aba, linhas de dados) de cada aba criada.
#[allow(clippy::too_many_arguments)] // os parametros do SELECT vao junto com ele
pub(crate) fn write_sheets(
    wb: &mut Workbook,
    namer: &mut SheetNamer,
    conn: &Connection,
    base: &str,
    select: &str,
    params: &[duckdb::types::Value],
    max_rows: usize,
    tick: &mut dyn FnMut() -> Result<(), String>,
) -> Result<Vec<(String, usize)>, String> {
    let bold = Format::new().set_bold();
    let date = Format::new().set_num_format("yyyy-mm-dd");
    let datetime = Format::new().set_num_format("yyyy-mm-dd hh:mm:ss");
    let mut stmt = conn.prepare(select).map_err(|e| format!("{base}: {e}"))?;
    let mut rows = stmt.query(duckdb::params_from_iter(params)).map_err(|e| format!("{base}: {e}"))?;
    let names = rows.as_ref().map(|s| s.column_names()).unwrap_or_default();

    let mut sheets: Vec<(String, usize)> = Vec::new();
    let mut start = |wb: &mut Workbook, sheets: &mut Vec<(String, usize)>| -> Result<(), String> {
        let name = namer.name(base, sheets.len() + 1);
        let ws = wb.add_worksheet_with_constant_memory().map_err(xlsx_err)?;
        ws.set_name(&name).map_err(xlsx_err)?;
        ws.write_row_with_format(0, 0, &names, &bold).map_err(xlsx_err)?;
        ws.set_freeze_panes(1, 0).map_err(xlsx_err)?;
        sheets.push((name, 0));
        Ok(())
    };
    start(wb, &mut sheets)?;
    let mut total = 0usize;
    while let Some(row) = rows.next().map_err(|e| format!("{base}: {e}"))? {
        if sheets.last().is_some_and(|s| s.1 == max_rows) {
            start(wb, &mut sheets)?;
        }
        let r = sheets.last().map_or(0, |s| s.1) as u32 + 1;
        // constant memory: a aba em uso e sempre a ultima criada
        let ws = wb.worksheets_mut().last_mut().expect("sheet just added");
        for c in 0..names.len() {
            let value = row.get_ref(c).map_err(|e| e.to_string())?;
            write_cell(ws, r, c as u16, value, &date, &datetime).map_err(xlsx_err)?;
        }
        sheets.last_mut().expect("sheet just added").1 += 1;
        total += 1;
        if total.is_multiple_of(ROWS_PER_TICK) {
            tick()?;
        }
    }
    Ok(sheets)
}

fn csv_field(text: &str) -> String {
    if text.contains([',', '"', '\r', '\n']) {
        format!("\"{}\"", text.replace('"', "\"\""))
    } else {
        text.to_string()
    }
}

// NIVEL BASICO: CSV em UTF-8 com BOM (o Excel reconhece acentos), separador virgula, linhas CRLF
fn write_csv(
    conn: &Connection,
    select: &str,
    params: &[duckdb::types::Value],
    path: &Path,
    tick: &mut dyn FnMut() -> Result<(), String>,
) -> Result<usize, String> {
    let file = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let mut out = std::io::BufWriter::new(file);
    let io = |e: std::io::Error| e.to_string();
    let mut stmt = conn.prepare(select).map_err(|e| e.to_string())?;
    let mut rows = stmt.query(duckdb::params_from_iter(params)).map_err(|e| e.to_string())?;
    let names = rows.as_ref().map(|s| s.column_names()).unwrap_or_default();
    let header: Vec<String> = names.iter().map(|n| csv_field(n)).collect();
    write!(out, "\u{FEFF}{}\r\n", header.join(",")).map_err(io)?;
    let mut count = 0usize;
    while let Some(row) = rows.next().map_err(|e| e.to_string())? {
        let fields: Vec<String> = (0..names.len())
            .map(|c| row.get_ref(c).map(|v| csv_field(&json_text(&value_to_json(v)))))
            .collect::<Result<_, _>>()
            .map_err(|e| e.to_string())?;
        write!(out, "{}\r\n", fields.join(",")).map_err(io)?;
        count += 1;
        if count.is_multiple_of(ROWS_PER_TICK) {
            tick()?;
        }
    }
    out.flush().map_err(io)?;
    Ok(count)
}

// NIVEL BASICO: Grava numa pasta temporaria propria ".<arquivo>.<pid>-<n>.partial\" ao lado do destino e so no fim
// move o arquivo para o nome escolhido; o destino anterior so e substituido se tudo deu certo
// NIVEL TECNICO: create_dir is atomic and fails if the folder exists, so the folder is ours alone (no
// check-then-create race) and cleaning it up never touches a file of the user; the DuckDB .wal lands inside it
// too. Same folder as the target, so the final rename stays on one disk and replaces the target in one step.
fn via_partial<T>(path: &Path, write: impl FnOnce(&Path) -> Result<T, String>) -> Result<T, String> {
    let file_name = path.file_name().ok_or("Invalid file name")?.to_string_lossy().into_owned();
    let mut n = 0u32;
    let dir: PathBuf = loop {
        let dir = path.with_file_name(format!(".{file_name}.{}-{n}.partial", std::process::id()));
        match std::fs::create_dir(&dir) {
            Ok(()) => break dir,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => n += 1,
            Err(e) => return Err(format!("{}: {e}", dir.display())),
        }
    };
    let partial = dir.join(&file_name);
    let result = write(&partial).and_then(|summary| {
        std::fs::rename(&partial, path).map_err(|e| format!("{}: {e}", path.display()))?;
        Ok(summary)
    });
    let _ = std::fs::remove_dir_all(&dir); // so tem o que este processo criou
    result
}

// NIVEL BASICO: Banco inteiro: format = "duckdb", "sqlite" ou "xlsx"
pub fn export_database(conn: &Connection, format: &str, path: &Path, progress: Progress) -> Result<Summary, String> {
    let tables = list_tables(conn)?;
    let n = tables.len();
    via_partial(path, |partial| match format {
        "duckdb" => {
            conn.execute_batch(&format!("ATTACH {} AS mdb2sql_out", literal(&partial.to_string_lossy())))
                .map_err(|e| e.to_string())?;
            let copied = tables.iter().enumerate().try_for_each(|(i, t)| {
                progress(i, n, t)?;
                conn.execute_batch(&format!("CREATE TABLE mdb2sql_out.main.{0} AS SELECT * FROM {0}", ident(t)))
                    .map_err(|e| format!("{t}: {e}"))
            });
            // DETACH sempre: sem ele o arquivo fica preso e nao da para renomear nem apagar
            let detached = conn.execute_batch("DETACH mdb2sql_out").map_err(|e| e.to_string());
            copied.and(detached).map(|_| Summary { count: n, sheets: None })
        }
        "sqlite" => sqlite_io::export(conn, &tables, partial, progress).map(|_| Summary { count: n, sheets: None }),
        "xlsx" => {
            let mut wb = Workbook::new();
            let mut namer = SheetNamer::default();
            let mut sheets = 0;
            for (i, t) in tables.iter().enumerate() {
                progress(i, n, t)?;
                let select = format!("SELECT * FROM {}", ident(t));
                sheets += write_sheets(&mut wb, &mut namer, conn, t, &select, &[], EXCEL_MAX_DATA_ROWS, &mut || progress(i, n, t))?.len();
            }
            progress(n, n, "[[progress.saving]]")?;
            wb.save(partial).map_err(xlsx_err)?;
            Ok(Summary { count: n, sheets: Some(sheets) })
        }
        other => Err(format!("Unknown export format: {other}")),
    })
}

// NIVEL BASICO: Tabela atual ou resultado do SQL: format = "csv" ou "xlsx"
pub fn export_source(conn: &Connection, source: &Source, format: &str, path: &Path, progress: Progress) -> Result<Summary, String> {
    let base = source.sheet_base().to_string();
    let select = source.select();
    progress(0, 1, &base)?;
    via_partial(path, |partial| match format {
        "csv" => write_csv(conn, &select, source.params(), partial, &mut || progress(0, 1, &base))
            .map(|rows| Summary { count: rows, sheets: None }),
        "xlsx" => {
            let mut wb = Workbook::new();
            let mut tick = || progress(0, 1, &base);
            let sheets =
                write_sheets(&mut wb, &mut SheetNamer::default(), conn, &base, &select, source.params(), EXCEL_MAX_DATA_ROWS, &mut tick)?;
            progress(1, 1, "[[progress.saving]]")?;
            wb.save(partial).map_err(xlsx_err)?;
            let rows: usize = sheets.iter().map(|s| s.1).sum();
            Ok(Summary { count: rows, sheets: Some(sheets.len()) })
        }
        other => Err(format!("Unknown export format: {other}")),
    })
}
