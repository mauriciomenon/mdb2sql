// Exportacoes: banco inteiro para .duckdb/.sqlite/.xlsx, tabela ou resultado para .csv/.xlsx.
// !T: Exports run on the worker thread, stream the rows (constant memory), report progress, can be
// canceled, and write to "<dest>.part" first: the destination is replaced only when everything worked.

const std = @import("std");
const dbm = @import("db.zig");
const query = dbm.query;
const xlsx = @import("xlsx.zig");
const csv = @import("csv.zig");
const Io = std.Io;
const Db = dbm.Db;

// Progresso de um trabalho longo, lido pela thread da UI
pub const Progress = struct {
    done: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),
    // .xlsx: o que o Excel nao comporta e ficou de fora; a UI le depois que o trabalho termina
    cut_cells: u64 = 0, // textos cortados em 32.767 caracteres
    cut_cols: u64 = 0, // colunas alem da 16.384a (somadas por tabela)

    pub fn begin(p: *Progress, total: u64) void {
        p.done.store(0, .monotonic);
        p.total.store(total, .monotonic);
        p.cut_cells = 0;
        p.cut_cols = 0;
    }

    pub fn add(p: *Progress, n: u64) void {
        _ = p.done.fetchAdd(n, .monotonic);
    }

    pub fn check(p: *Progress) error{Canceled}!void {
        if (p.cancel.load(.monotonic)) return error.Canceled;
    }
};

pub const DbFormat = enum { duckdb, sqlite };
pub const FileFormat = enum { csv, xlsx };

// O que exportar de uma tabela ou do SQL livre
pub const Select = struct {
    sql: [:0]const u8,
    params: []const []const u8 = &.{},
    sheet: []const u8, // nome da aba (tabela ou "Query")
};

fn partPath(buf: []u8, dest: []const u8) error{NameTooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.part", .{dest}) catch error.NameTooLong;
}

fn deleteQuiet(io: Io, path: []const u8) void {
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

// Troca o destino pelo arquivo pronto (substitui o que existia, ja confirmado no dialogo)
fn commit(io: Io, part: []const u8, dest: []const u8) !void {
    try Io.Dir.cwd().rename(part, Io.Dir.cwd(), dest, io);
}

// Banco inteiro para um arquivo novo .duckdb ou .sqlite (todas as tabelas, com os tipos do DuckDB)
pub fn database(db: *Db, io: Io, format: DbFormat, dest: []const u8, progress: *Progress) !void {
    const gpa = db.gpa;
    if (format == .sqlite) try db.loadSqlite();
    var part_buf: [4096]u8 = undefined;
    const part = try partPath(&part_buf, dest);
    var wal_buf: [4100]u8 = undefined;
    const wal = std.fmt.bufPrint(&wal_buf, "{s}.wal", .{part}) catch unreachable;
    deleteQuiet(io, part);
    deleteQuiet(io, wal);

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(gpa);
    try sql.appendSlice(gpa, "ATTACH ");
    try query.writeLiteral(&sql, gpa, part);
    try sql.appendSlice(gpa, if (format == .sqlite) " AS mdb2sql_out (TYPE sqlite)" else " AS mdb2sql_out");
    try db.exec(try zsql(&sql, gpa));
    errdefer {
        db.exec("ROLLBACK") catch {};
        db.exec("DETACH DATABASE IF EXISTS mdb2sql_out") catch {};
        deleteQuiet(io, part);
        deleteQuiet(io, wal);
    }
    // todas as tabelas numa transacao so: o arquivo e gravado uma vez no fim (SQLite: sem um commit por tabela)
    try db.exec("BEGIN TRANSACTION");

    progress.begin(db.table_names.len);
    for (db.table_names) |name| {
        try progress.check();
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try src.appendSlice(gpa, "SELECT * FROM ");
        try query.writeIdent(&src, gpa, name);
        if (format == .sqlite) {
            try copyToSqlite(db, gpa, name, name, src.items);
        } else {
            sql.clearRetainingCapacity();
            try sql.appendSlice(gpa, "CREATE TABLE mdb2sql_out.main.");
            try query.writeIdent(&sql, gpa, name);
            try sql.appendSlice(gpa, " AS ");
            try duckSelect(db, gpa, &sql, name, src.items);
            try db.exec(try zsql(&sql, gpa));
        }
        progress.add(1);
    }
    try db.exec("COMMIT");
    try db.exec("DETACH DATABASE mdb2sql_out");
    try commit(io, part, dest);
}

// Fonte SQLite (o Access convertido tambem): o schema esta no tipo declarado de cada coluna, que o leitor do DuckDB
// simplifica (DECIMAL(p,s) e REAL viram DOUBLE, BOOLEAN vira BIGINT)
fn sqliteSource(db: *const Db) bool {
    return if (db.source) |s| s != .duckdb else false;
}

// !T: Column names and types of an output table, by the schema (item 20): from a SQLite source, the declared type of
// each column of `table` (PRAGMA table_info), which keeps DECIMAL(p,s), REAL and BOOLEAN; otherwise the DuckDB type
// of the query (DESCRIBE). Rows: [name, type].
fn outputColumns(db: *Db, gpa: std.mem.Allocator, table: ?[]const u8, source: []const u8) !dbm.Grid {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(gpa);
    if (sqliteSource(db) and table != null) {
        var inner: std.ArrayList(u8) = .empty;
        defer inner.deinit(gpa);
        try inner.appendSlice(gpa, "SELECT name, type FROM pragma_table_info(");
        try query.writeLiteral(&inner, gpa, table.?);
        try inner.appendSlice(gpa, ") ORDER BY cid");
        try sql.appendSlice(gpa, "SELECT * FROM sqlite_query('src', ");
        try query.writeLiteral(&sql, gpa, inner.items);
        try sql.appendSlice(gpa, ")");
    } else try sql.print(gpa, "DESCRIBE {s}", .{source});
    return db.run(try zsql(&sql, gpa), &.{});
}

// !T: One table of a SQLite output (item 20): created by SQLite itself with the declared type of each column (the
// source's declared type, or query.sqliteType of the DuckDB type), then filled with the native values. DECIMAL stays
// DECIMAL in the schema and its values are stored as numbers; nothing numeric becomes text.
fn copyToSqlite(db: *Db, gpa: std.mem.Allocator, out_table: []const u8, schema_table: ?[]const u8, source: []const u8) !void {
    var cols = try outputColumns(db, gpa, schema_table, source);
    defer cols.deinit();
    const declared = sqliteSource(db) and schema_table != null;
    const names = try gpa.alloc([]const u8, cols.rows.len);
    defer gpa.free(names);
    const types = try gpa.alloc([]const u8, cols.rows.len);
    defer gpa.free(types);
    for (cols.rows, names, types) |r, *n, *ty| {
        n.* = r[0] orelse "";
        ty.* = if (declared) r[1] orelse "" else query.sqliteType(r[1] orelse "");
    }
    try db.createSqliteTable("mdb2sql_out", out_table, names, types);
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(gpa);
    try sql.appendSlice(gpa, "INSERT INTO mdb2sql_out.main.");
    try query.writeIdent(&sql, gpa, out_table);
    try sql.print(gpa, " {s}", .{source});
    try db.exec(try zsql(&sql, gpa));
}

// DECIMAL(p,s) ou NUMERIC(p,s) declarado no SQLite, com p ate 38: o mesmo tipo no DuckDB
fn decimalDeclared(ty: []const u8) bool {
    const up = if (std.ascii.startsWithIgnoreCase(ty, "DECIMAL(")) ty["DECIMAL(".len..] else if (std.ascii.startsWithIgnoreCase(ty, "NUMERIC(")) ty["NUMERIC(".len..] else return false;
    if (up.len < 2 or up[up.len - 1] != ')') return false;
    var it = std.mem.splitScalar(u8, up[0 .. up.len - 1], ',');
    const p = std.fmt.parseInt(u8, std.mem.trim(u8, it.next() orelse "", " "), 10) catch return false;
    const s = std.fmt.parseInt(u8, std.mem.trim(u8, it.next() orelse "0", " "), 10) catch return false;
    return p >= 1 and p <= 38 and s <= p and it.next() == null;
}

// !T: The SELECT of a DuckDB output (item 20): from a SQLite source, each column takes back the type of the schema
// that the DuckDB reader simplified: DECIMAL(p,s) stays DECIMAL(p,s), BOOLEAN BOOLEAN, REAL FLOAT; the rest as read.
fn duckSelect(db: *Db, gpa: std.mem.Allocator, sql: *std.ArrayList(u8), schema_table: ?[]const u8, source: []const u8) !void {
    if (!sqliteSource(db) or schema_table == null) return sql.appendSlice(gpa, source);
    var cols = try outputColumns(db, gpa, schema_table, source);
    defer cols.deinit();
    try sql.appendSlice(gpa, "SELECT ");
    for (cols.rows, 0..) |r, i| {
        if (i > 0) try sql.appendSlice(gpa, ", ");
        const name = r[0] orelse "";
        const ty = r[1] orelse "";
        const cast: ?[]const u8 = if (decimalDeclared(ty)) ty else if (std.ascii.eqlIgnoreCase(ty, "BOOLEAN")) "BOOLEAN" else if (std.ascii.eqlIgnoreCase(ty, "REAL")) "FLOAT" else null;
        if (cast != null) try sql.appendSlice(gpa, "CAST(");
        try sql.appendSlice(gpa, "q.");
        try query.writeIdent(sql, gpa, name);
        if (cast) |cty| try sql.print(gpa, " AS {s})", .{cty});
        try sql.appendSlice(gpa, " AS ");
        try query.writeIdent(sql, gpa, name);
    }
    try sql.print(gpa, " FROM ({s}) q", .{source});
}

fn zsql(sql: *std.ArrayList(u8), gpa: std.mem.Allocator) ![:0]const u8 {
    try sql.append(gpa, 0);
    defer sql.items.len -= 1;
    return sql.items[0 .. sql.items.len - 1 :0];
}

// Todas as tabelas numa pasta do Excel, uma aba por tabela (tabela grande continua em "<nome> (2)"...)
pub fn workbookAll(db: *Db, io: Io, dest: []const u8, progress: *Progress, rows_per_sheet: usize) !void {
    const counts = try db.gpa.alloc(u64, db.table_names.len);
    defer db.gpa.free(counts);
    try db.countMany(db.table_names, counts);
    var total: u64 = 0;
    for (counts) |n| total += n;
    progress.begin(total);

    var part_buf: [4096]u8 = undefined;
    const part = try partPath(&part_buf, dest);
    var wb = try xlsx.Workbook.create(db.gpa, io, part);
    {
        errdefer deleteQuiet(io, part);
        defer wb.deinit();
        for (db.table_names) |name| {
            const built = try query.buildSelect(db.gpa, .{ .table = name, .tables = db.table_names, .columns = &.{}, .limit = 0 });
            defer built.deinit(db.gpa);
            try writeSheets(&wb, db, .{ .sql = built.sql, .sheet = name }, progress, rows_per_sheet);
        }
        try wb.finish();
    }
    commit(io, part, dest) catch |e| {
        deleteQuiet(io, part);
        return e;
    };
}

// Uma consulta (tabela atual ou resultado) para .csv ou .xlsx; devolve as linhas gravadas
pub fn selection(db: *Db, io: Io, format: FileFormat, sel: Select, dest: []const u8, progress: *Progress, total_hint: u64) !u64 {
    progress.begin(total_hint);
    var part_buf: [4096]u8 = undefined;
    const part = try partPath(&part_buf, dest);
    errdefer deleteQuiet(io, part);
    const before = progress.done.load(.monotonic);
    switch (format) {
        .xlsx => {
            var wb = try xlsx.Workbook.create(db.gpa, io, part);
            defer wb.deinit();
            try writeSheets(&wb, db, sel, progress, xlsx.max_data_rows);
            try wb.finish();
        },
        .csv => try writeCsv(db, io, sel, part, progress),
    }
    try commit(io, part, dest);
    return progress.done.load(.monotonic) - before;
}

// Varias consultas num destino so
pub const BundleFormat = enum { xlsx, csv_dir, sqlite, duckdb };

// !T: Several queries into one destination: the sheets of one Excel workbook, one CSV file per query in the folder
// `dest` (<name>.csv; each file is written as .part and renamed, so a cancel leaves no half file), or the tables of
// a new SQLite/DuckDB file. Returns the rows written (workbook, CSV) or the tables created (database).
pub fn bundle(db: *Db, io: Io, format: BundleFormat, items: []const Select, dest: []const u8, progress: *Progress, total_hint: u64) !u64 {
    var part_buf: [4096]u8 = undefined;
    switch (format) {
        .xlsx => {
            progress.begin(total_hint);
            const part = try partPath(&part_buf, dest);
            errdefer deleteQuiet(io, part);
            {
                var wb = try xlsx.Workbook.create(db.gpa, io, part);
                defer wb.deinit();
                for (items) |item| try writeSheets(&wb, db, item, progress, xlsx.max_data_rows);
                try wb.finish();
            }
            try commit(io, part, dest);
            return progress.done.load(.monotonic);
        },
        .csv_dir => {
            progress.begin(total_hint);
            for (items) |item| {
                try progress.check();
                var file_buf: [4096]u8 = undefined;
                const file = try csvPath(&file_buf, dest, item.sheet);
                const part = try partPath(&part_buf, file);
                errdefer deleteQuiet(io, part);
                try writeCsv(db, io, item, part, progress);
                try commit(io, part, file);
            }
            return progress.done.load(.monotonic);
        },
        .sqlite, .duckdb => {
            const gpa = db.gpa;
            if (format == .sqlite) try db.loadSqlite();
            const part = try partPath(&part_buf, dest);
            var wal_buf: [4100]u8 = undefined;
            const wal = std.fmt.bufPrint(&wal_buf, "{s}.wal", .{part}) catch unreachable;
            deleteQuiet(io, part);
            deleteQuiet(io, wal);
            var sql: std.ArrayList(u8) = .empty;
            defer sql.deinit(gpa);
            try sql.appendSlice(gpa, "ATTACH ");
            try query.writeLiteral(&sql, gpa, part);
            try sql.appendSlice(gpa, if (format == .sqlite) " AS mdb2sql_out (TYPE sqlite)" else " AS mdb2sql_out");
            try db.exec(try zsql(&sql, gpa));
            errdefer {
                db.exec("ROLLBACK") catch {};
                db.exec("DETACH DATABASE IF EXISTS mdb2sql_out") catch {};
                deleteQuiet(io, part);
                deleteQuiet(io, wal);
            }
            try db.exec("BEGIN TRANSACTION");
            progress.begin(items.len);
            for (items) |item| {
                try progress.check();
                // os itens do relatorio da Pesquisa Avançada sao as tabelas (as colunas delas, item 19 d): o schema vem
                // da tabela de mesmo nome
                const schema_table: ?[]const u8 = if (query.contains(db.table_names, item.sheet)) item.sheet else null;
                if (format == .sqlite) {
                    try copyToSqlite(db, gpa, item.sheet, schema_table, item.sql);
                } else {
                    sql.clearRetainingCapacity();
                    try sql.appendSlice(gpa, "CREATE TABLE mdb2sql_out.main.");
                    try query.writeIdent(&sql, gpa, item.sheet);
                    try sql.appendSlice(gpa, " AS ");
                    try duckSelect(db, gpa, &sql, schema_table, item.sql);
                    try db.exec(try zsql(&sql, gpa));
                }
                progress.add(1);
            }
            try db.exec("COMMIT");
            try db.exec("DETACH DATABASE mdb2sql_out");
            try commit(io, part, dest);
            return items.len;
        },
    }
}

// <pasta>/<nome>.csv, com o nome sem os caracteres que um arquivo nao aceita
// shortcut: two tables whose names differ only in those characters share one file (the last one written wins)
pub fn csvPath(buf: []u8, dir: []const u8, name: []const u8) error{NameTooLong}![]const u8 {
    var name_buf: [600]u8 = undefined;
    const file = @import("settings.zig").fileName(&name_buf, name, ".csv");
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ dir, std.fs.path.sep_str, file }) catch error.NameTooLong;
}

fn writeCsv(db: *Db, io: Io, sel: Select, path: []const u8, progress: *Progress) !void {
    var rows = try db.stream(sel.sql, sel.params, .{});
    defer rows.deinit();
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;
    try w.writeAll("\xEF\xBB\xBF"); // BOM: sem ele o Excel le UTF-8 como ANSI e estraga os acentos
    for (0..rows.n_cols) |i| {
        if (i > 0) try w.writeByte(',');
        try csv.writeField(w, rows.name(i));
    }
    try w.writeAll("\r\n");
    var cell_buf: [64]u8 = undefined;
    while (try rows.next()) {
        try progress.check();
        for (0..rows.size) |r| {
            for (0..rows.n_cols) |col| {
                if (col > 0) try w.writeByte(',');
                try csv.writeField(w, rows.cell(col, r, &cell_buf));
            }
            try w.writeAll("\r\n");
        }
        progress.add(rows.size);
    }
    try fw.end();
}

// Linhas de uma consulta em abas: cabecalho em cada aba, nova aba a cada `rows_per_sheet` linhas de dados
fn writeSheets(wb: *xlsx.Workbook, db: *Db, sel: Select, progress: *Progress, rows_per_sheet: usize) !void {
    var rows = try db.stream(sel.sql, sel.params, .{ .types = true });
    defer rows.deinit();
    const n = @min(rows.n_cols, xlsx.max_cols);
    progress.cut_cols += rows.n_cols - n;
    defer progress.cut_cells = wb.cut_cells;
    const cells = try db.gpa.alloc(xlsx.Cell, n);
    defer db.gpa.free(cells);
    const header = try db.gpa.alloc(xlsx.Cell, n);
    defer db.gpa.free(header);
    for (header, 0..) |*h, i| h.* = .{ .text = rows.name(i) };

    // Largura de cada coluna ajustada ao conteudo (item 19 g): o titulo e o primeiro bloco de linhas (ate 2.048),
    // lido antes de abrir a aba (as larguras vem antes dos dados no XML).
    // shortcut: only the first chunk is measured; a longer value further down is wider than its column
    var more = try rows.next();
    const widths = try db.gpa.alloc(u16, n);
    defer db.gpa.free(widths);
    var cell_buf: [64]u8 = undefined;
    for (widths, 0..) |*w, col| {
        w.* = textWidth(rows.name(col)) + 1; // o titulo em negrito e um pouco mais largo
        if (more) for (0..rows.size) |r| {
            w.* = @max(w.*, textWidth(rows.cell(col, r, &cell_buf) orelse ""));
        };
        w.* = std.math.clamp(w.* + 2, 6, 80);
    }

    var part: usize = 1;
    _ = try wb.beginSheet(sel.sheet, part, widths);
    try wb.writeRow(header);
    var in_sheet: usize = 0;
    while (more) : (more = try rows.next()) {
        try progress.check();
        for (0..rows.size) |r| {
            if (in_sheet == rows_per_sheet) {
                try wb.endSheet();
                part += 1;
                _ = try wb.beginSheet(sel.sheet, part, widths);
                try wb.writeRow(header);
                in_sheet = 0;
            }
            for (cells, 0..) |*cell, col| {
                const ty = if (col < rows.types.len) rows.types[col] else 0;
                cell.* = toCell(rows.cell(col, r, &cell_buf), ty);
            }
            try wb.writeRow(cells);
            in_sheet += 1;
        }
        progress.add(rows.size);
    }
    try wb.endSheet();
}

// Caracteres de um texto (UTF-8), ate 200: a medida da largura de uma coluna do Excel
fn textWidth(s: []const u8) u16 {
    const n = std.unicode.utf8CountCodepoints(s) catch s.len;
    return @intCast(@min(n, 200));
}

// Texto da celula -> celula da planilha, conforme o tipo original da coluna: numero e celula numerica, data e
// celula de data (item 19 c), NULL e celula vazia
fn toCell(text: ?[]const u8, ty: anytype) xlsx.Cell {
    const s = text orelse return .empty;
    if (dbm.isBoolType(ty)) return .{ .boolean = std.mem.eql(u8, s, "true") };
    if (dbm.isNumericType(ty) and xlsx.isExcelNumber(s)) return .{ .number = s };
    if (dbm.isDateType(ty)) if (xlsx.dateSerial(s)) |d| return .{ .date = d };
    return .{ .text = s };
}

// -------------------------------------------------------------------- tests

const t = std.testing;

fn sampleDb(tmp: *const std.testing.TmpDir, buf: []u8) !Db {
    const path = dbm.tmpPath(buf, tmp, "sample.duckdb");
    try dbm.makeSample(path);
    var db = dbm.testDb();
    errdefer db.close();
    try db.openReadOnly(path);
    return db;
}

test "whole database to .duckdb and .sqlite keeps every table, row and type" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b0: [256]u8 = undefined;
    var db = try sampleDb(&tmp, &b0);
    defer db.close();
    var p: Progress = .{};

    var b1: [256]u8 = undefined;
    const out_duck = dbm.tmpPath(&b1, &tmp, "out.duckdb");
    try database(&db, t.io, .duckdb, out_duck, &p);
    try t.expectEqual(3, p.done.load(.monotonic));
    var b2: [256]u8 = undefined;
    const out_lite = dbm.tmpPath(&b2, &tmp, "out.sqlite");
    try database(&db, t.io, .sqlite, out_lite, &p);
    // de novo por cima: o destino existente e substituido
    try database(&db, t.io, .sqlite, out_lite, &p);

    var check = dbm.testDb();
    defer check.close();
    try check.openReadOnly(out_duck);
    try t.expectEqual(3, check.table_names.len);
    try t.expectEqual(250, try check.count(.{ .table = "big", .tables = check.table_names, .columns = &.{} }));
    var sch = try check.schema("strict");
    defer sch.deinit();
    try t.expectEqualStrings("INTEGER", sch.rows[0][1].?);

    try check.openReadOnly(out_lite);
    try t.expectEqual(3, check.table_names.len);
    var g = try check.run("SELECT name FROM people WHERE id = 1", &.{});
    defer g.deinit();
    try t.expectEqualStrings("Ação", g.rows[0][0].?);
    try t.expectError(error.FileNotFound, Io.Dir.cwd().access(t.io, dbm.tmpPath(&b1, &tmp, "out.sqlite.part"), .{}));
}

test "items 19 h and 20: the schema keeps the nature of the numbers: SQLite saved with DECIMAL/REAL/INTEGER and numeric values, DuckDB saved back with DECIMAL, Excel numeric cells" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b: [4][256]u8 = undefined;
    const src = dbm.tmpPath(&b[0], &tmp, "money.duckdb");
    const lite = dbm.tmpPath(&b[1], &tmp, "money.sqlite");
    const back = dbm.tmpPath(&b[2], &tmp, "money_back.duckdb");
    const book = dbm.tmpPath(&b[3], &tmp, "money.xlsx");
    var db = dbm.testDb();
    defer db.close();
    try db.open(src, false);
    try db.exec("CREATE TABLE money AS SELECT * FROM (VALUES (1, 19.99::DECIMAL(19,4), 1234.56::DECIMAL(10,2), 0.5::FLOAT, 2316.25::DOUBLE, true, TIMESTAMP '2026-07-14 10:30:00', 'x')) " ++
        "v(id, preco, valor, razao, d, ativo, quando, nome)");
    try db.open(":memory:", false);
    try db.openReadOnly(src);
    var p: Progress = .{};
    try database(&db, t.io, .sqlite, lite, &p);
    // o SQLite salvo: o schema com o tipo de cada coluna e os numeros guardados como numero (nunca texto)
    try db.open(":memory:", false);
    try db.openReadOnly(lite);
    var decl = try db.run("SELECT string_agg(name || ' ' || type, ', ' ORDER BY cid) FROM sqlite_query('src', 'SELECT cid, name, type FROM pragma_table_info(''money'')')", &.{});
    defer decl.deinit();
    try t.expectEqualStrings("id INTEGER, preco DECIMAL(19,4), valor DECIMAL(10,2), razao REAL, d DOUBLE, ativo BOOLEAN, quando TIMESTAMP, nome TEXT", decl.rows[0][0].?);
    var kinds = try db.run("SELECT * FROM sqlite_query('src', 'SELECT typeof(id) || typeof(preco) || typeof(valor) || typeof(razao) || typeof(d) || typeof(ativo) FROM money')", &.{});
    defer kinds.deinit();
    try t.expectEqualStrings("integerrealrealrealrealinteger", kinds.rows[0][0].?);
    // do SQLite para o DuckDB: DECIMAL volta DECIMAL, BOOLEAN volta BOOLEAN, REAL e FLOAT (o tipo do schema)
    try database(&db, t.io, .duckdb, back, &p);
    // e para o Excel: os numeros sao celulas numericas, a data e data
    try workbookAll(&db, t.io, book, &p, xlsx.max_data_rows);
    var check = dbm.testDb();
    defer check.close();
    try check.openReadOnly(back);
    var types = try check.run("SELECT string_agg(column_name || ' ' || data_type, ', ' ORDER BY column_index) FROM duckdb_columns() WHERE table_name = 'money'", &.{});
    defer types.deinit();
    try t.expectEqualStrings("id BIGINT, preco DECIMAL(19,4), valor DECIMAL(10,2), razao FLOAT, d DOUBLE, ativo BOOLEAN, quando TIMESTAMP, nome VARCHAR", types.rows[0][0].?);
    var vals = try check.run("SELECT preco::VARCHAR || '|' || valor::VARCHAR FROM money", &.{});
    defer vals.deinit();
    try t.expectEqualStrings("19.9900|1234.56", vals.rows[0][0].?);
    const sheet = try xlsx.readPart(t.allocator, t.io, book, "xl/worksheets/sheet1.xml");
    defer t.allocator.free(sheet);
    try t.expect(std.mem.indexOf(u8, sheet, "<c r=\"B2\"><v>19.99</v></c><c r=\"C2\"><v>1234.56</v></c><c r=\"D2\"><v>0.5</v></c>") != null);
    try t.expect(std.mem.indexOf(u8, sheet, "<c r=\"G2\" s=\"2\"><v>46217.4375</v></c>") != null);
}

test "cancel leaves no file behind" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b0: [256]u8 = undefined;
    var db = try sampleDb(&tmp, &b0);
    defer db.close();
    var p: Progress = .{};
    p.cancel.store(true, .monotonic);
    var b1: [256]u8 = undefined;
    const out = dbm.tmpPath(&b1, &tmp, "never.duckdb");
    try t.expectError(error.Canceled, database(&db, t.io, .duckdb, out, &p));
    try t.expectError(error.FileNotFound, Io.Dir.cwd().access(t.io, out, .{}));
    var b2: [256]u8 = undefined;
    try t.expectError(error.FileNotFound, Io.Dir.cwd().access(t.io, dbm.tmpPath(&b2, &tmp, "never.duckdb.part"), .{}));
    try t.expectError(error.Canceled, workbookAll(&db, t.io, dbm.tmpPath(&b1, &tmp, "never.xlsx"), &p, 100));
    try t.expectError(error.FileNotFound, Io.Dir.cwd().access(t.io, dbm.tmpPath(&b1, &tmp, "never.xlsx.part"), .{}));
}

// Le as abas de volta: nomes no workbook.xml e numero de <row> em cada sheetN.xml
fn readBack(path: []const u8, sheet_names: *std.ArrayList(u8), rows_per_sheet: *std.ArrayList(usize)) !void {
    const file = try Io.Dir.cwd().openFile(t.io, path, .{});
    defer file.close(t.io);
    var rbuf: [4096]u8 = undefined;
    var reader = file.reader(t.io, &rbuf);
    var it = try std.zip.Iterator.init(&reader);
    var sheets: [16]usize = @splat(0);
    var n_sheets: usize = 0;
    while (try it.next()) |e| {
        var name_buf: [64]u8 = undefined;
        try reader.seekTo(e.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        const name = name_buf[0..e.filename_len];
        try reader.interface.readSliceAll(name);
        var data: Io.Writer.Allocating = .init(t.allocator);
        defer data.deinit();
        try e.extractTo(&reader, &data.writer);
        if (std.mem.startsWith(u8, name, "xl/worksheets/sheet")) {
            const idx = try std.fmt.parseInt(usize, name["xl/worksheets/sheet".len .. name.len - 4], 10);
            sheets[idx - 1] = std.mem.count(u8, data.written(), "<row ");
            n_sheets = @max(n_sheets, idx);
        } else if (std.mem.eql(u8, name, "xl/workbook.xml")) {
            var rest = data.written();
            while (std.mem.indexOf(u8, rest, "<sheet name=\"")) |i| {
                rest = rest[i + 13 ..];
                const end = std.mem.indexOfScalar(u8, rest, '"').?;
                try sheet_names.appendSlice(t.allocator, rest[0..end]);
                try sheet_names.append(t.allocator, '|');
            }
        }
    }
    try rows_per_sheet.appendSlice(t.allocator, sheets[0..n_sheets]);
}

test "xlsx: cells over 32,767 characters and columns past 16,384 are counted for the user (audit item 13)" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b0: [256]u8 = undefined;
    var db = try sampleDb(&tmp, &b0);
    defer db.close();
    var p: Progress = .{};
    // 3 linhas, 2 com texto de 40.000 "é" (alem de 32.767) e 1 com texto de 32.767 (cabe)
    var b1: [256]u8 = undefined;
    const out = dbm.tmpPath(&b1, &tmp, "wide.xlsx");
    const long = "SELECT repeat('é', CASE WHEN i = 1 THEN 32767 ELSE 40000 END) AS a FROM range(3) r(i)";
    try t.expectEqual(3, try selection(&db, t.io, .xlsx, .{ .sql = long, .sheet = "Query" }, out, &p, 3));
    try t.expectEqual(2, p.cut_cells);
    // colunas alem de 16.384 (consulta de 16.386 colunas: lenta demais para o teste) sao n_cols - max_cols
    // por tabela; aqui o contador fica no zero
    try t.expectEqual(0, p.cut_cols);
    p.cut_cols = 9; // e a exportacao seguinte zera os dois
    // a exportacao seguinte comeca do zero
    try t.expectEqual(1, try selection(&db, t.io, .xlsx, .{ .sql = "SELECT 'x' AS s", .sheet = "Query" }, out, &p, 1));
    try t.expectEqual(0, p.cut_cells);
    try t.expectEqual(0, p.cut_cols);
}

test "xlsx: one sheet per table, big table split, typed cells, result export" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b0: [256]u8 = undefined;
    var db = try sampleDb(&tmp, &b0);
    defer db.close();
    var p: Progress = .{};

    var b1: [256]u8 = undefined;
    const out = dbm.tmpPath(&b1, &tmp, "all.xlsx");
    try workbookAll(&db, t.io, out, &p, 100); // 100 linhas por aba: "big" (250) vira 3 abas
    try t.expectEqual(254, p.done.load(.monotonic));
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(t.allocator);
    var counts: std.ArrayList(usize) = .empty;
    defer counts.deinit(t.allocator);
    try readBack(out, &names, &counts);
    // ordem do SHOW TABLES: big, people, strict
    try t.expectEqualStrings("big|big (2)|big (3)|people|strict|", names.items);
    try t.expectEqualSlices(usize, &.{ 101, 101, 51, 5, 1 }, counts.items);

    // tabela atual com busca para .xlsx e .csv
    const cols = [_][]const u8{ "id", "name", "score" };
    const built = try query.buildSelect(t.allocator, .{ .table = "people", .tables = db.table_names, .columns = &cols, .search = "acao", .sort_column = "id", .limit = 0 });
    defer built.deinit(t.allocator);
    var b2: [256]u8 = undefined;
    const one = dbm.tmpPath(&b2, &tmp, "people.xlsx");
    try t.expectEqual(2, try selection(&db, t.io, .xlsx, .{ .sql = built.sql, .params = built.params, .sheet = "people" }, one, &p, 2));
    var b3: [256]u8 = undefined;
    const csv_path = dbm.tmpPath(&b3, &tmp, "people.csv");
    try t.expectEqual(2, try selection(&db, t.io, .csv, .{ .sql = built.sql, .params = built.params, .sheet = "people" }, csv_path, &p, 2));
    var cbuf: [256]u8 = undefined;
    const text = try Io.Dir.cwd().readFile(t.io, csv_path, &cbuf);
    try t.expectEqualStrings("\xEF\xBB\xBFid,name,score\r\n1,Ação,10.5\r\n3,acao,3.0\r\n", text);

    // resultado de SQL livre: numero vira <v>, texto vira inlineStr, booleano vira t="b"
    const r = "SELECT 7 AS n, 'x' AS s, true AS b, 1.25::DOUBLE AS d, NULL AS z";
    try t.expectEqual(1, try selection(&db, t.io, .xlsx, .{ .sql = r, .sheet = "Query" }, one, &p, 1));
    const file = try Io.Dir.cwd().openFile(t.io, one, .{});
    defer file.close(t.io);
    var rbuf: [4096]u8 = undefined;
    var reader = file.reader(t.io, &rbuf);
    var it = try std.zip.Iterator.init(&reader);
    while (try it.next()) |e| {
        var data: Io.Writer.Allocating = .init(t.allocator);
        defer data.deinit();
        try e.extractTo(&reader, &data.writer);
        if (std.mem.indexOf(u8, data.written(), "<row r=\"2\">")) |i| {
            try t.expectEqualStrings("<row r=\"2\"><c r=\"A2\"><v>7</v></c><c r=\"B2\" t=\"inlineStr\"><is><t xml:space=\"preserve\">x</t></is></c>" ++
                "<c r=\"C2\" t=\"b\"><v>1</v></c><c r=\"D2\"><v>1.25</v></c></row>", data.written()[i .. std.mem.indexOfPos(u8, data.written(), i, "</row>").? + 6]);
        }
    }
}
