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
        sql.clearRetainingCapacity();
        try sql.appendSlice(gpa, "CREATE TABLE mdb2sql_out.main.");
        try query.writeIdent(&sql, gpa, name);
        try sql.appendSlice(gpa, " AS SELECT * FROM ");
        try query.writeIdent(&sql, gpa, name);
        try db.exec(try zsql(&sql, gpa));
        progress.add(1);
    }
    try db.exec("COMMIT");
    try db.exec("DETACH DATABASE mdb2sql_out");
    try commit(io, part, dest);
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
                sql.clearRetainingCapacity();
                try sql.appendSlice(gpa, "CREATE TABLE mdb2sql_out.main.");
                try query.writeIdent(&sql, gpa, item.sheet);
                try sql.print(gpa, " AS {s}", .{item.sql});
                try db.exec(try zsql(&sql, gpa));
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

    var part: usize = 1;
    _ = try wb.beginSheet(sel.sheet, part);
    try wb.writeRow(header);
    var in_sheet: usize = 0;
    var cell_buf: [64]u8 = undefined;
    while (try rows.next()) {
        try progress.check();
        for (0..rows.size) |r| {
            if (in_sheet == rows_per_sheet) {
                try wb.endSheet();
                part += 1;
                _ = try wb.beginSheet(sel.sheet, part);
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

// Texto da celula -> celula da planilha, conforme o tipo original da coluna
fn toCell(text: ?[]const u8, ty: anytype) xlsx.Cell {
    const s = text orelse return .empty;
    if (dbm.isBoolType(ty)) return .{ .boolean = std.mem.eql(u8, s, "true") };
    if (dbm.isNumericType(ty) and xlsx.isExcelNumber(s)) return .{ .number = s };
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
