// Leitura de .mdb/.accdb: converte o banco Access inteiro para um banco DuckDB em memoria ("src").
// !T: Access reader, in this order: (a) the 64-bit "Microsoft Access Driver (*.mdb, *.accdb)" ODBC driver,
// (b) the embedded static mdbtools (mdb-tables / mdb-schema / mdb-export), (c) a clear message.
// MDB2SQL_ACCESS_READER=odbc|mdbtools forces one of them.

const std = @import("std");
const c = @import("duckdb_c");
const dbm = @import("db.zig");
const query = dbm.query;
const Progress = @import("exporter.zig").Progress;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Db = dbm.Db;

pub const driver_name = "Microsoft Access Driver (*.mdb, *.accdb)";
pub const mdbtools_tools = [_][]const u8{ "mdb-tables.exe", "mdb-schema.exe", "mdb-export.exe" };

pub const Reader = enum { odbc, mdbtools };

pub const missing_message = "Cannot open Access files on this computer: install the 64-bit \"Microsoft Access Database Engine " ++
    "2016 Redistributable\" (ODBC driver \"" ++ driver_name ++ "\") or keep the mdbtools folder next to the program.";

// !T: Reader choice. forced = value of MDB2SQL_ACCESS_READER ("" = automatic: ODBC first, then mdbtools)
pub fn choose(forced: []const u8, odbc_ok: bool, mdbtools_ok: bool) error{ NoAccessReader, BadReaderName }!Reader {
    if (std.ascii.eqlIgnoreCase(forced, "odbc")) return if (odbc_ok) .odbc else error.NoAccessReader;
    if (std.ascii.eqlIgnoreCase(forced, "mdbtools")) return if (mdbtools_ok) .mdbtools else error.NoAccessReader;
    if (forced.len > 0 and !std.ascii.eqlIgnoreCase(forced, "auto")) return error.BadReaderName;
    if (odbc_ok) return .odbc;
    if (mdbtools_ok) return .mdbtools;
    return error.NoAccessReader;
}

pub const Options = struct {
    forced: []const u8 = "", // MDB2SQL_ACCESS_READER
    tools_dir: []const u8 = "", // pasta com mdb-*.exe; vazio = sem mdbtools
    temp_dir: []const u8 = ".", // onde ficam os CSV temporarios do mdbtools
};

// Abre o arquivo Access e devolve o caminho usado. Erro error.Failed: texto em db.lastError().
pub fn open(db: *Db, io: Io, path: []const u8, opts: Options, progress: *Progress) !dbm.Source {
    // o arquivo tem de existir (o driver ODBC daria uma mensagem confusa)
    Io.Dir.cwd().access(io, path, .{}) catch {
        db.setErrorText("File not found");
        return error.Failed;
    };
    const tools_ok = opts.tools_dir.len > 0 and mdbtoolsPresent(io, opts.tools_dir);
    const reader = choose(opts.forced, odbcDriverInstalled(), tools_ok) catch |e| {
        db.setErrorText(switch (e) {
            error.BadReaderName => "MDB2SQL_ACCESS_READER must be odbc, mdbtools or auto",
            error.NoAccessReader => if (opts.forced.len > 0 and !std.ascii.eqlIgnoreCase(opts.forced, "auto"))
                "The Access reader forced by MDB2SQL_ACCESS_READER is not available on this computer"
            else
                missing_message,
        });
        return error.Failed;
    };
    try db.beginMemory();
    errdefer db.closeSource();
    var used = reader;
    switch (reader) {
        .odbc => odbcImport(db, path, progress) catch |e| {
            // driver presente mas com falha (instalacao quebrada, arquivo que ele recusa): tenta o mdbtools,
            // a nao ser que o ODBC tenha sido forcado ou o usuario tenha cancelado
            if (e == error.Canceled or progress.cancel.load(.monotonic) or opts.forced.len > 0 and
                !std.ascii.eqlIgnoreCase(opts.forced, "auto") or !tools_ok) return e;
            try db.beginMemory();
            used = .mdbtools;
            try mdbtoolsImport(db, io, path, opts, progress);
        },
        .mdbtools => try mdbtoolsImport(db, io, path, opts, progress),
    }
    const source: dbm.Source = if (used == .odbc) .access_odbc else .access_mdbtools;
    try db.finishMemory(source);
    return source;
}

pub fn mdbtoolsPresent(io: Io, dir: []const u8) bool {
    for (mdbtools_tools) |exe| {
        var buf: [4096]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}\\{s}", .{ dir, exe }) catch return false;
        Io.Dir.cwd().access(io, p, .{}) catch return false;
    }
    return true;
}

// ------------------------------------------------------------------ tipos

// Tipo DuckDB de uma coluna do Access pelo nome que o mdb-schema (backend "access") imprime
pub fn duckTypeFromAccess(buf: []u8, access_type: []const u8) []const u8 {
    const ty = std.mem.trim(u8, access_type, " \t,");
    const paren = std.mem.indexOfScalar(u8, ty, '(');
    const name = std.mem.trim(u8, if (paren) |p| ty[0..p] else ty, " ");
    const simple = [_]struct { []const u8, []const u8 }{
        .{ "Boolean", "BOOLEAN" },   .{ "Byte", "UTINYINT" },        .{ "Integer", "SMALLINT" },
        .{ "Long Integer", "INTEGER" }, .{ "Currency", "DECIMAL(19,4)" }, .{ "Single", "FLOAT" },
        .{ "Double", "DOUBLE" },     .{ "DateTime", "TIMESTAMP" },   .{ "OLE", "BLOB" },
        .{ "Binary", "BLOB" },
    };
    for (simple) |s| if (std.mem.eql(u8, name, s[0])) return s[1];
    if (std.mem.eql(u8, name, "Numeric")) {
        // Numeric (p, s) -> DECIMAL(p,s); precisao acima do limite do DuckDB vira DOUBLE
        const args = if (paren) |p| std.mem.trim(u8, ty[p + 1 ..], " )") else "";
        var it = std.mem.splitScalar(u8, args, ',');
        const prec = std.fmt.parseInt(u8, std.mem.trim(u8, it.next() orelse "", " "), 10) catch return "DOUBLE";
        const scale = std.fmt.parseInt(u8, std.mem.trim(u8, it.next() orelse "0", " "), 10) catch return "DOUBLE";
        if (prec == 0 or prec > 38 or scale > prec) return "DOUBLE";
        return std.fmt.bufPrint(buf, "DECIMAL({d},{d})", .{ prec, scale }) catch "DOUBLE";
    }
    return "VARCHAR"; // Text, Memo/Hyperlink, Replication ID e o que vier de desconhecido
}

pub const Column = struct { name: []const u8, ty: []const u8 };
pub const Table = struct { name: []const u8, columns: []Column };

// !T: Parse "mdb-schema <file> access" output: CREATE TABLE [name] ( [col] Type (args), ... );
pub fn parseSchema(a: Allocator, text: []const u8) Allocator.Error![]Table {
    var tables: std.ArrayList(Table) = .empty;
    var cols: std.ArrayList(Column) = .empty;
    var current: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "CREATE TABLE [")) {
            const end = std.mem.lastIndexOfScalar(u8, line, ']') orelse continue;
            current = line["CREATE TABLE [".len..end];
            cols.clearRetainingCapacity();
        } else if (current != null and std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "[")) {
            const l = std.mem.trimStart(u8, line, " \t");
            const end = std.mem.indexOfScalar(u8, l, ']') orelse continue;
            var tbuf: [32]u8 = undefined;
            const ty = duckTypeFromAccess(&tbuf, l[end + 1 ..]);
            try cols.append(a, .{ .name = l[1..end], .ty = try a.dupe(u8, ty) });
        } else if (current != null and std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), ");")) {
            try tables.append(a, .{ .name = current.?, .columns = try cols.toOwnedSlice(a) });
            current = null;
        }
    }
    return tables.toOwnedSlice(a);
}

// ------------------------------------------------------------------ mdbtools

fn toolPath(buf: []u8, dir: []const u8, exe: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}\\{s}", .{ dir, exe }) catch unreachable;
}

fn mdbtoolsImport(db: *Db, io: Io, path: []const u8, opts: Options, progress: *Progress) !void {
    const gpa = db.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var pb: [4096]u8 = undefined;
    // um processo para o esquema de todas as tabelas (sem indices nem relacoes)
    const schema = std.process.run(arena, io, .{
        .argv = &.{ toolPath(&pb, opts.tools_dir, "mdb-schema.exe"), "--no-relations", "--no-indexes", "--no-not-null", "--no-default-values", path, "access" },
    }) catch |e| return failFmt(db, "mdb-schema could not run: {t}", .{e});
    if (!schema.term.success()) return failFmt(db, "mdb-schema failed: {s}", .{std.mem.trim(u8, schema.stderr, " \r\n")});
    const tables = try parseSchema(arena, schema.stdout);
    progress.begin(tables.len);

    // Cada mdb-export le o catalogo do arquivo de novo (~0,5 s no DB4): roda varios ao mesmo tempo, um CSV
    // temporario por processo, e carrega os CSVs no DuckDB um por um
    const parallel = 8;
    const tag = randomU64(io);
    var csv_bufs: [parallel][4096]u8 = undefined;
    var csv_paths: [parallel][]const u8 = undefined;
    for (&csv_paths, &csv_bufs, 0..) |*p, *b, i|
        p.* = std.fmt.bufPrint(b, "{s}\\mdb2sql-{x}-{d}.csv", .{ opts.temp_dir, tag, i }) catch return error.NameTooLong;
    defer for (csv_paths) |p| Io.Dir.cwd().deleteFile(io, p) catch {};

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(gpa);
    var start: usize = 0;
    while (start < tables.len) : (start += parallel) {
        try progress.check();
        const batch = tables[start..@min(start + parallel, tables.len)];
        var children: [parallel]?std.process.Child = @splat(null);
        // nenhum processo fica para tras: em erro, os que ainda rodam sao encerrados
        defer for (&children) |*ch| if (ch.*) |*child| child.kill(io);
        for (batch, 0..) |table, i| {
            const out = try Io.Dir.cwd().createFile(io, csv_paths[i], .{});
            defer out.close(io); // o filho herdou o seu proprio handle
            children[i] = std.process.spawn(io, .{
                .argv = &.{ toolPath(&pb, opts.tools_dir, "mdb-export.exe"), "-D", "%Y-%m-%d %H:%M:%S", "-T", "%Y-%m-%d %H:%M:%S", "-b", "hex", path, table.name },
                .stdin = .ignore,
                .stdout = .{ .file = out },
                .stderr = .ignore,
                .create_no_window = true,
            }) catch |e| return failFmt(db, "mdb-export could not run: {t}", .{e});
        }
        for (batch, 0..) |table, i| {
            const term = children[i].?.wait(io) catch |e| return failFmt(db, "mdb-export failed: {t}", .{e});
            children[i] = null;
            if (!term.success()) return failFmt(db, "mdb-export failed on table {s}", .{table.name});
        }
        for (batch, 0..) |table, i| {
            try loadCsv(db, table, csv_paths[i], &sql);
            progress.add(1);
        }
    }
}

// CSV do mdb-export -> tabela com os tipos do Access; NULL = campo vazio sem aspas, "" = texto vazio
fn loadCsv(db: *Db, table: Table, csv_path: []const u8, sql: *std.ArrayList(u8)) !void {
    const gpa = db.gpa;
    sql.clearRetainingCapacity();
    try sql.appendSlice(gpa, "CREATE TABLE ");
    try query.writeIdent(sql, gpa, table.name);
    if (table.columns.len == 0) {
        try sql.appendSlice(gpa, " (empty_table_without_columns VARCHAR)");
    } else {
        try sql.appendSlice(gpa, " AS SELECT * ");
        var any_blob = false;
        for (table.columns) |col| any_blob = any_blob or std.mem.eql(u8, col.ty, "BLOB");
        if (any_blob) {
            try sql.appendSlice(gpa, "REPLACE (");
            var first = true;
            for (table.columns) |col| if (std.mem.eql(u8, col.ty, "BLOB")) {
                if (!first) try sql.appendSlice(gpa, ", ");
                first = false;
                try sql.appendSlice(gpa, "from_hex(");
                try query.writeIdent(sql, gpa, col.name);
                try sql.appendSlice(gpa, ") AS ");
                try query.writeIdent(sql, gpa, col.name);
            };
            try sql.appendSlice(gpa, ") ");
        }
        try sql.appendSlice(gpa, "FROM read_csv(");
        try query.writeLiteral(sql, gpa, csv_path);
        try sql.appendSlice(gpa, ", header = true, auto_detect = false, delim = ',', quote = '\"', escape = '\"', " ++
            "allow_quoted_nulls = false, strict_mode = false, columns = {");
        for (table.columns, 0..) |col, i| {
            if (i > 0) try sql.appendSlice(gpa, ", ");
            try query.writeLiteral(sql, gpa, col.name);
            try sql.appendSlice(gpa, ": ");
            // o hex do binario chega como texto e vira BLOB no REPLACE acima
            try query.writeLiteral(sql, gpa, if (std.mem.eql(u8, col.ty, "BLOB")) "VARCHAR" else col.ty);
        }
        try sql.appendSlice(gpa, "})");
    }
    try sql.append(gpa, 0);
    try db.exec(sql.items[0 .. sql.items.len - 1 :0]);
}


fn randomU64(io: Io) u64 {
    var b: [8]u8 = undefined;
    io.random(&b);
    return std.mem.readInt(u64, &b, .little);
}

fn failFmt(db: *Db, comptime fmt: []const u8, args: anytype) error{Failed} {
    var buf: [1024]u8 = undefined;
    db.setErrorText(std.fmt.bufPrint(&buf, fmt, args) catch fmt);
    return error.Failed;
}

// ------------------------------------------------------------------ ODBC (odbc32.dll)

const SQLHANDLE = ?*anyopaque;
const SQLRETURN = i16;
const SQL_SUCCESS = 0;
const SQL_SUCCESS_WITH_INFO = 1;
const SQL_NO_DATA = 100;
const SQL_NTS = -3;
const SQL_NULL_DATA = -1;
const SQL_NO_TOTAL = -4;
const H_ENV = 1;
const H_DBC = 2;
const H_STMT = 3;
const SQL_C_WCHAR = -8;
const SQL_C_SBIGINT = -25;
const SQL_C_DOUBLE = 8;
const SQL_C_BIT = -7;
const SQL_C_BINARY = -2;

extern "odbc32" fn SQLAllocHandle(kind: i16, input: SQLHANDLE, out: *SQLHANDLE) callconv(.winapi) SQLRETURN;
extern "odbc32" fn SQLFreeHandle(kind: i16, h: SQLHANDLE) callconv(.winapi) SQLRETURN;
extern "odbc32" fn SQLSetEnvAttr(env: SQLHANDLE, attr: i32, value: ?*anyopaque, len: i32) callconv(.winapi) SQLRETURN;
extern "odbc32" fn SQLDriversW(env: SQLHANDLE, dir: u16, desc: [*]u16, desc_max: i16, desc_len: *i16, attrs: [*]u16, attrs_max: i16, attrs_len: *i16) callconv(.winapi) SQLRETURN;
extern "odbc32" fn SQLDriverConnectW(dbc: SQLHANDLE, hwnd: ?*anyopaque, in: [*]const u16, in_len: i16, out: ?[*]u16, out_max: i16, out_len: ?*i16, completion: u16) callconv(.winapi) SQLRETURN;
extern "odbc32" fn SQLDisconnect(dbc: SQLHANDLE) callconv(.winapi) SQLRETURN;
extern "odbc32" fn SQLTablesW(stmt: SQLHANDLE, cat: ?[*]const u16, cat_len: i16, sch: ?[*]const u16, sch_len: i16, name: ?[*]const u16, name_len: i16, kind: ?[*]const u16, kind_len: i16) callconv(.winapi) SQLRETURN;
extern "odbc32" fn SQLExecDirectW(stmt: SQLHANDLE, sql: [*]const u16, len: i32) callconv(.winapi) SQLRETURN;
extern "odbc32" fn SQLNumResultCols(stmt: SQLHANDLE, n: *i16) callconv(.winapi) SQLRETURN;
extern "odbc32" fn SQLDescribeColW(stmt: SQLHANDLE, col: u16, name: [*]u16, name_max: i16, name_len: *i16, data_type: *i16, size: *usize, digits: *i16, nullable: *i16) callconv(.winapi) SQLRETURN;
extern "odbc32" fn SQLFetch(stmt: SQLHANDLE) callconv(.winapi) SQLRETURN;
extern "odbc32" fn SQLGetData(stmt: SQLHANDLE, col: u16, target: i16, value: ?*anyopaque, max: isize, ind: *isize) callconv(.winapi) SQLRETURN;
extern "odbc32" fn SQLFreeStmt(stmt: SQLHANDLE, option: u16) callconv(.winapi) SQLRETURN;
extern "odbc32" fn SQLGetDiagRecW(kind: i16, h: SQLHANDLE, rec: i16, state: *[6]u16, native: *i32, msg: [*]u16, msg_max: i16, msg_len: *i16) callconv(.winapi) SQLRETURN;

fn ok(r: SQLRETURN) bool {
    return r == SQL_SUCCESS or r == SQL_SUCCESS_WITH_INFO;
}

fn newEnv() ?SQLHANDLE {
    var env: SQLHANDLE = null;
    if (!ok(SQLAllocHandle(H_ENV, null, &env))) return null;
    if (!ok(SQLSetEnvAttr(env, 200, @ptrFromInt(3), 0))) { // SQL_ATTR_ODBC_VERSION = SQL_OV_ODBC3
        _ = SQLFreeHandle(H_ENV, env);
        return null;
    }
    return env;
}

// !T: The 64-bit Access ODBC driver is installed (SQLDrivers lists it)
pub fn odbcDriverInstalled() bool {
    const env = newEnv() orelse return false;
    defer _ = SQLFreeHandle(H_ENV, env);
    const want = std.unicode.utf8ToUtf16LeStringLiteral(driver_name);
    var desc: [256]u16 = undefined;
    var attrs: [1024]u16 = undefined;
    var dl: i16 = 0;
    var al: i16 = 0;
    var dir: u16 = 2; // SQL_FETCH_FIRST
    while (ok(SQLDriversW(env, dir, &desc, desc.len, &dl, &attrs, attrs.len, &al))) : (dir = 1) { // SQL_FETCH_NEXT
        const n: usize = @intCast(@min(@max(dl, 0), desc.len));
        if (std.mem.eql(u16, desc[0..n], want)) return true;
    }
    return false;
}

// Mensagem de diagnostico do ODBC em db.lastError()
fn odbcFail(db: *Db, kind: i16, h: SQLHANDLE, what: []const u8) error{Failed} {
    var state: [6]u16 = undefined;
    var native: i32 = 0;
    var msg: [512]u16 = undefined;
    var len: i16 = 0;
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    w.print("{s}: ", .{what}) catch {};
    if (ok(SQLGetDiagRecW(kind, h, 1, &state, &native, &msg, msg.len, &len))) {
        const n: usize = @intCast(@min(@max(len, 0), msg.len));
        w.print("{f}", .{std.unicode.fmtUtf16Le(msg[0..n])}) catch {};
    } else w.writeAll("ODBC error") catch {};
    db.setErrorText(w.buffered());
    return error.Failed;
}

// Como cada tipo SQL do driver chega e vira coluna DuckDB
const Fetch = enum { int, double, bit, text, binary };

fn mapOdbcType(buf: []u8, sql_type: i16, size: usize, digits: i16) struct { []const u8, Fetch } {
    return switch (sql_type) {
        4 => .{ "INTEGER", .int }, // SQL_INTEGER
        5 => .{ "SMALLINT", .int }, // SQL_SMALLINT
        -6 => .{ "UTINYINT", .int }, // SQL_TINYINT (Byte do Access, 0-255)
        -5 => .{ "BIGINT", .int }, // SQL_BIGINT
        -7 => .{ "BOOLEAN", .bit }, // SQL_BIT
        7 => .{ "FLOAT", .double }, // SQL_REAL
        6, 8 => .{ "DOUBLE", .double }, // SQL_FLOAT, SQL_DOUBLE
        2, 3 => blk: { // SQL_NUMERIC, SQL_DECIMAL (texto exato -> DECIMAL)
            if (size == 0 or size > 38 or digits < 0 or digits > size) break :blk .{ "DOUBLE", .double };
            break :blk .{ std.fmt.bufPrint(buf, "DECIMAL({d},{d})", .{ size, digits }) catch "DOUBLE", .text };
        },
        9, 10, 11, 91, 92, 93 => .{ "TIMESTAMP", .text }, // datas: "aaaa-mm-dd hh:mm:ss"
        -2, -3, -4 => .{ "BLOB", .binary },
        else => .{ "VARCHAR", .text }, // texto, memo, GUID e o resto
    };
}

fn utf16z(a: Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(a, s) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidWtf8 => error.Failed,
    };
}

fn odbcImport(db: *Db, path: []const u8, progress: *Progress) !void {
    const gpa = db.gpa;
    const env = newEnv() orelse return failFmt(db, "ODBC is not available", .{});
    defer _ = SQLFreeHandle(H_ENV, env);
    var dbc: SQLHANDLE = null;
    if (!ok(SQLAllocHandle(H_DBC, env, &dbc))) return odbcFail(db, H_ENV, env, "ODBC");
    defer _ = SQLFreeHandle(H_DBC, dbc);

    const conn_str = try std.fmt.allocPrint(gpa, "Driver={{" ++ driver_name ++ "}};DBQ={s};ReadOnly=1;", .{path});
    defer gpa.free(conn_str);
    const conn_w = try utf16z(gpa, conn_str);
    defer gpa.free(conn_w);
    if (!ok(SQLDriverConnectW(dbc, null, conn_w.ptr, SQL_NTS, null, 0, null, 0))) return odbcFail(db, H_DBC, dbc, "Access ODBC");
    defer _ = SQLDisconnect(dbc);

    var stmt: SQLHANDLE = null;
    if (!ok(SQLAllocHandle(H_STMT, dbc, &stmt))) return odbcFail(db, H_DBC, dbc, "Access ODBC");
    defer _ = SQLFreeHandle(H_STMT, stmt);

    // nomes das tabelas de usuario (TABLE_NAME e a 3a coluna de SQLTables)
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    if (!ok(SQLTablesW(stmt, null, 0, null, 0, null, 0, std.unicode.utf8ToUtf16LeStringLiteral("TABLE"), SQL_NTS))) return odbcFail(db, H_STMT, stmt, "Access ODBC tables");
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var wide: std.ArrayList(u16) = .empty;
    defer wide.deinit(gpa);
    while (true) {
        const r = SQLFetch(stmt);
        if (r == SQL_NO_DATA) break;
        if (!ok(r)) return odbcFail(db, H_STMT, stmt, "Access ODBC tables");
        if (try getText(db, stmt, 3, &wide, &text)) try names.append(arena, try arena.dupe(u8, text.items));
    }
    _ = SQLFreeStmt(stmt, 0); // SQL_CLOSE
    progress.begin(names.items.len);

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(gpa);
    for (names.items) |name| {
        try progress.check();
        try copyTable(db, stmt, name, &sql, &wide, &text, progress);
        progress.add(1);
    }
}

// Le uma coluna texto (em partes, memo longo incluso) para `text` em UTF-8; false = NULL
fn getText(db: *Db, stmt: SQLHANDLE, col: u16, wide: *std.ArrayList(u16), text: *std.ArrayList(u8)) !bool {
    const gpa = db.gpa;
    wide.clearRetainingCapacity();
    var piece: [2048]u16 = undefined;
    while (true) {
        var ind: isize = 0;
        const r = SQLGetData(stmt, col, SQL_C_WCHAR, &piece, @sizeOf(@TypeOf(piece)), &ind);
        if (r == SQL_NO_DATA) break;
        if (!ok(r)) return odbcFail(db, H_STMT, stmt, "Access ODBC read");
        if (ind == SQL_NULL_DATA) return false;
        // cada parte vem terminada em 0; com SQL_NO_TOTAL ou dado maior que o buffer ela esta cheia
        const full = piece.len - 1;
        const n: usize = if (ind == SQL_NO_TOTAL or @as(usize, @intCast(ind)) / 2 > full) full else @as(usize, @intCast(ind)) / 2;
        try wide.appendSlice(gpa, piece[0..n]);
        if (r == SQL_SUCCESS) break;
    }
    text.clearRetainingCapacity();
    try text.resize(gpa, std.unicode.calcWtf8Len(wide.items));
    _ = std.unicode.wtf16LeToWtf8(text.items, wide.items);
    std.unicode.wtf8ToUtf8Lossy(text.items, text.items) catch {}; // surrogate solto vira U+FFFD (DuckDB quer UTF-8 valido)
    return true;
}

fn getBinary(db: *Db, stmt: SQLHANDLE, col: u16, out: *std.ArrayList(u8)) !bool {
    out.clearRetainingCapacity();
    var piece: [8192]u8 = undefined;
    while (true) {
        var ind: isize = 0;
        const r = SQLGetData(stmt, col, SQL_C_BINARY, &piece, piece.len, &ind);
        if (r == SQL_NO_DATA) break;
        if (!ok(r)) return odbcFail(db, H_STMT, stmt, "Access ODBC read");
        if (ind == SQL_NULL_DATA) return false;
        const n: usize = if (ind == SQL_NO_TOTAL or @as(usize, @intCast(ind)) > piece.len) piece.len else @intCast(ind);
        try out.appendSlice(db.gpa, piece[0..n]);
        if (r == SQL_SUCCESS) break;
    }
    return true;
}

fn appenderFail(db: *Db, app: c.duckdb_appender) error{Failed} {
    var err = c.duckdb_appender_error_data(app);
    defer c.duckdb_destroy_error_data(&err);
    db.setError(c.duckdb_error_data_message(err));
    return error.Failed;
}

fn copyTable(db: *Db, stmt: SQLHANDLE, name: []const u8, sql: *std.ArrayList(u8), wide: *std.ArrayList(u16), text: *std.ArrayList(u8), progress: *Progress) !void {
    const gpa = db.gpa;
    const select = try std.fmt.allocPrint(gpa, "SELECT * FROM [{s}]", .{name});
    defer gpa.free(select);
    const select_w = try utf16z(gpa, select);
    defer gpa.free(select_w);
    if (!ok(SQLExecDirectW(stmt, select_w.ptr, SQL_NTS))) return odbcFail(db, H_STMT, stmt, name);
    defer _ = SQLFreeStmt(stmt, 0);

    var n_cols: i16 = 0;
    _ = SQLNumResultCols(stmt, &n_cols);
    const fetch = try gpa.alloc(Fetch, @intCast(@max(n_cols, 0)));
    defer gpa.free(fetch);

    // CREATE TABLE com os tipos que o driver informa
    sql.clearRetainingCapacity();
    try sql.appendSlice(gpa, "CREATE TABLE ");
    try query.writeIdent(sql, gpa, name);
    try sql.appendSlice(gpa, " (");
    for (fetch, 1..) |*f, col| {
        var col_name: [256]u16 = undefined;
        var name_len: i16 = 0;
        var data_type: i16 = 0;
        var size: usize = 0;
        var digits: i16 = 0;
        var nullable: i16 = 0;
        if (!ok(SQLDescribeColW(stmt, @intCast(col), &col_name, col_name.len, &name_len, &data_type, &size, &digits, &nullable)))
            return odbcFail(db, H_STMT, stmt, name);
        var tbuf: [32]u8 = undefined;
        const duck, f.* = mapOdbcType(&tbuf, data_type, size, digits);
        if (col > 1) try sql.appendSlice(gpa, ", ");
        const nl: usize = @intCast(@min(@max(name_len, 0), col_name.len));
        var name_buf: [768]u8 = undefined;
        try query.writeIdent(sql, gpa, name_buf[0..std.unicode.wtf16LeToWtf8(&name_buf, col_name[0..nl])]);
        try sql.print(gpa, " {s}", .{duck});
    }
    try sql.appendSlice(gpa, ")");
    if (n_cols == 0) {
        sql.clearRetainingCapacity();
        try sql.appendSlice(gpa, "CREATE TABLE ");
        try query.writeIdent(sql, gpa, name);
        try sql.appendSlice(gpa, " (empty_table_without_columns VARCHAR)");
    }
    try sql.append(gpa, 0);
    try db.exec(sql.items[0 .. sql.items.len - 1 :0]);
    if (n_cols == 0) return;

    const name_z = try gpa.dupeSentinel(u8, name, 0);
    defer gpa.free(name_z);
    var app: c.duckdb_appender = null;
    if (c.duckdb_appender_create_ext(db.conn, "src", "main", name_z, &app) != c.DuckDBSuccess) return appenderFail(db, app);
    defer _ = c.duckdb_appender_destroy(&app);

    var rows: usize = 0;
    while (true) {
        const r = SQLFetch(stmt);
        if (r == SQL_NO_DATA) break;
        if (!ok(r)) return odbcFail(db, H_STMT, stmt, name);
        for (fetch, 1..) |f, col_i| {
            const col: u16 = @intCast(col_i);
            var ind: isize = 0;
            const state = switch (f) {
                .int => blk: {
                    var v: i64 = 0;
                    if (!ok(SQLGetData(stmt, col, SQL_C_SBIGINT, &v, 8, &ind))) return odbcFail(db, H_STMT, stmt, name);
                    break :blk if (ind == SQL_NULL_DATA) c.duckdb_append_null(app) else c.duckdb_append_int64(app, v);
                },
                .double => blk: {
                    var v: f64 = 0;
                    if (!ok(SQLGetData(stmt, col, SQL_C_DOUBLE, &v, 8, &ind))) return odbcFail(db, H_STMT, stmt, name);
                    break :blk if (ind == SQL_NULL_DATA) c.duckdb_append_null(app) else c.duckdb_append_double(app, v);
                },
                .bit => blk: {
                    var v: u8 = 0;
                    if (!ok(SQLGetData(stmt, col, SQL_C_BIT, &v, 1, &ind))) return odbcFail(db, H_STMT, stmt, name);
                    break :blk if (ind == SQL_NULL_DATA) c.duckdb_append_null(app) else c.duckdb_append_bool(app, v != 0);
                },
                .text => if (try getText(db, stmt, col, wide, text))
                    c.duckdb_append_varchar_length(app, text.items.ptr, text.items.len)
                else
                    c.duckdb_append_null(app),
                .binary => if (try getBinary(db, stmt, col, text))
                    c.duckdb_append_blob(app, text.items.ptr, text.items.len)
                else
                    c.duckdb_append_null(app),
            };
            if (state != c.DuckDBSuccess) return appenderFail(db, app);
        }
        if (c.duckdb_appender_end_row(app) != c.DuckDBSuccess) return appenderFail(db, app);
        rows += 1;
        if (rows % 4096 == 0) try progress.check();
    }
    if (c.duckdb_appender_close(app) != c.DuckDBSuccess) return appenderFail(db, app);
}

// -------------------------------------------------------------------- tests

const t = std.testing;

test "Access reader choice: ODBC first, mdbtools as fallback, forced by the variable" {
    try t.expectEqual(.odbc, try choose("", true, true));
    try t.expectEqual(.mdbtools, try choose("", false, true));
    try t.expectEqual(.odbc, try choose("auto", true, false));
    try t.expectError(error.NoAccessReader, choose("", false, false));
    try t.expectEqual(.mdbtools, try choose("mdbtools", true, true));
    try t.expectEqual(.mdbtools, try choose("MDBTOOLS", false, true));
    try t.expectError(error.NoAccessReader, choose("mdbtools", true, false));
    try t.expectEqual(.odbc, try choose("odbc", true, true));
    try t.expectError(error.NoAccessReader, choose("odbc", false, true));
    try t.expectError(error.BadReaderName, choose("jet", true, true));
    _ = odbcDriverInstalled(); // a deteccao real roda sem quebrar, com ou sem o driver
}

test "a file that is not Access fails with a message, through every reader available" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b: [256]u8 = undefined;
    const path = dbm.tmpPath(&b, &tmp, "fake.accdb");
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = path, .data = "not an access file" });
    var db = Db.init(t.allocator);
    defer db.close();
    var p: Progress = .{};
    const tools = t.environ.getAlloc(t.allocator, "MDB2SQL_TEST_MDBTOOLS") catch try t.allocator.dupe(u8, "");
    defer t.allocator.free(tools);
    try t.expectError(error.Failed, open(&db, t.io, path, .{ .tools_dir = tools, .temp_dir = ".zig-cache" }, &p));
    try t.expect(db.lastError().len > 0 and !db.isOpen());
    try t.expectError(error.Failed, open(&db, t.io, "nao/existe.accdb", .{ .tools_dir = tools }, &p));
    try t.expectEqualStrings("File not found", db.lastError());
}

test "Access types from mdb-schema" {
    var b: [32]u8 = undefined;
    try t.expectEqualStrings("DECIMAL(10,0)", duckTypeFromAccess(&b, "Numeric (10, 0), "));
    try t.expectEqualStrings("DOUBLE", duckTypeFromAccess(&b, "Numeric (60, 2)"));
    try t.expectEqualStrings("VARCHAR", duckTypeFromAccess(&b, "Text (48), "));
    try t.expectEqualStrings("VARCHAR", duckTypeFromAccess(&b, "Memo/Hyperlink (255)"));
    try t.expectEqualStrings("INTEGER", duckTypeFromAccess(&b, "Long Integer, "));
    try t.expectEqualStrings("SMALLINT", duckTypeFromAccess(&b, "Integer"));
    try t.expectEqualStrings("TIMESTAMP", duckTypeFromAccess(&b, "DateTime, "));
    try t.expectEqualStrings("DECIMAL(19,4)", duckTypeFromAccess(&b, "Currency"));
    try t.expectEqualStrings("BLOB", duckTypeFromAccess(&b, "OLE"));
    try t.expectEqualStrings("VARCHAR", duckTypeFromAccess(&b, "Replication ID"));
    var o: [32]u8 = undefined;
    try t.expectEqualStrings("DECIMAL(19,4)", mapOdbcType(&o, 2, 19, 4)[0]);
    try t.expectEqual(.int, mapOdbcType(&o, 4, 10, 0)[1]);
    try t.expectEqualStrings("TIMESTAMP", mapOdbcType(&o, 93, 19, 0)[0]);
}

test "mdb-schema output parser" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const text =
        "-- That file uses encoding ISO-8859-1\n\nCREATE TABLE [RANGER_SOSTAT]\n (\n" ++
        "\t[RTUNO]\t\t\tNumeric (10, 0), \n\t[PNTNAM]\t\t\tText (48), \n\t[Data de criação]\t\t\tDateTime\n);\n\n" ++
        "CREATE TABLE [Outra tabela]\n (\n\t[ID]\t\t\tLong Integer\n);\n";
    const tables = try parseSchema(arena.allocator(), text);
    try t.expectEqual(2, tables.len);
    try t.expectEqualStrings("RANGER_SOSTAT", tables[0].name);
    try t.expectEqual(3, tables[0].columns.len);
    try t.expectEqualStrings("DECIMAL(10,0)", tables[0].columns[0].ty);
    try t.expectEqualStrings("Data de criação", tables[0].columns[2].name);
    try t.expectEqualStrings("TIMESTAMP", tables[0].columns[2].ty);
    try t.expectEqualStrings("Outra tabela", tables[1].name);
    try t.expectEqualStrings("INTEGER", tables[1].columns[0].ty);
}

// Com MDB2SQL_TEST_OUT (pasta): exporta o banco convertido para .duckdb, .sqlite e .xlsx e confere as
// contagens de todas as tabelas reabrindo o .duckdb e o .sqlite (o .xlsx e conferido fora, com openpyxl)
fn exportAndCompare(db: *Db, total: u64) !void {
    const exporter = @import("exporter.zig");
    const dir = t.environ.getAlloc(t.allocator, "MDB2SQL_TEST_OUT") catch return;
    defer t.allocator.free(dir);
    const ext_path = t.environ.getAlloc(t.allocator, "MDB2SQL_TEST_SQLITE_EXT") catch return;
    defer t.allocator.free(ext_path);
    db.sqlite_ext = ext_path;
    var p: Progress = .{};
    var b: [3][1024]u8 = undefined;
    const outs = [_][]const u8{
        try std.fmt.bufPrint(&b[0], "{s}\\DB4_export.duckdb", .{dir}),
        try std.fmt.bufPrint(&b[1], "{s}\\DB4_export.sqlite", .{dir}),
        try std.fmt.bufPrint(&b[2], "{s}\\DB4_export.xlsx", .{dir}),
    };
    try exporter.database(db, t.io, .duckdb, outs[0], &p);
    try exporter.database(db, t.io, .sqlite, outs[1], &p);
    try exporter.workbookAll(db, t.io, outs[2], &p, @import("xlsx.zig").max_data_rows);
    try t.expectEqual(total, p.done.load(.monotonic));
    const want = try t.allocator.alloc(u64, db.table_names.len);
    defer t.allocator.free(want);
    try db.countMany(db.table_names, want);
    for (outs[0..2]) |out| {
        var check = Db.init(t.allocator);
        defer check.close();
        check.sqlite_ext = ext_path;
        try check.openReadOnly(out);
        try t.expectEqual(db.table_names.len, check.table_names.len);
        for (db.table_names, want) |name, n| {
            try t.expectEqual(n, try check.count(.{ .table = name, .tables = check.table_names, .columns = &.{} }));
        }
        std.debug.print("{s}: {d} tables, every count equal\n", .{ std.fs.path.basename(out), check.table_names.len });
    }
}

// Conversao real quando MDB2SQL_TEST_ACCDB aponta para uma COPIA de um .accdb (opcional; o dono roda com o DB4)
test "real Access file through both readers (optional)" {
    const path = t.environ.getAlloc(t.allocator, "MDB2SQL_TEST_ACCDB") catch return error.SkipZigTest;
    defer t.allocator.free(path);
    const tools = t.environ.getAlloc(t.allocator, "MDB2SQL_TEST_MDBTOOLS") catch try t.allocator.dupe(u8, "");
    defer t.allocator.free(tools);
    var counts: [2]u64 = undefined;
    for ([_][]const u8{ "odbc", "mdbtools" }, 0..) |reader, i| {
        var db = Db.init(t.allocator);
        defer db.close();
        var p: Progress = .{};
        const t0 = std.Io.Timestamp.now(t.io, .awake);
        const src = open(&db, t.io, path, .{ .forced = reader, .tools_dir = tools, .temp_dir = ".zig-cache" }, &p) catch |e| {
            std.debug.print("{s}: {s}\n", .{ reader, db.lastError() });
            return e;
        };
        const ms = t0.durationTo(std.Io.Timestamp.now(t.io, .awake)).toMilliseconds();
        try t.expectEqual(if (i == 0) dbm.Source.access_odbc else dbm.Source.access_mdbtools, src);
        var total: u64 = 0;
        for (db.table_names) |name| total += try db.count(.{ .table = name, .tables = db.table_names, .columns = &.{} });
        counts[i] = total;
        std.debug.print("{s}: {d} tables, {d} rows, converted in {d} ms\n", .{ reader, db.table_names.len, total, ms });
        if (i == 0) try exportAndCompare(&db, total);
    }
    try t.expectEqual(counts[0], counts[1]);
}
