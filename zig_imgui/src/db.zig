// Gerenciador de conexao DuckDB (C API) - abre banco, lista tabelas, pagina, conta, schema
// !T: DuckDB connection manager over libduckdb's C API; mirrors python_pyqt6/src/backend/db_manager.py
//
// Uma instancia DuckDB em memoria vive o programa inteiro (a conexao nunca e trocada, entao
// duckdb_interrupt pode ser chamado de outra thread a qualquer momento). O arquivo aberto entra
// como o banco "src" (ATTACH ... READ_ONLY; o Access vira um banco em memoria com esse nome).

const std = @import("std");
const c = @import("duckdb_c");
pub const query = @import("query.zig");
pub const worker = @import("worker.zig");
pub const csv = @import("csv.zig");
pub const about = @import("about.zig");
pub const capture = @import("capture.zig");
pub const gridtools = @import("gridtools.zig");
pub const xlsx = @import("xlsx.zig");
pub const exporter = @import("exporter.zig");
pub const terms = @import("terms.zig");
pub const access = @import("access.zig");
pub const settings = @import("settings.zig");
pub const i18n = @import("i18n.zig");
pub const log = @import("log.zig");
pub const display = @import("display.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{ DuckDb, Canceled, SqlReadOnly } || query.BuildError || query.PathError;

// !T: The SQL tab only reads. The kind of a statement is the one DuckDB gives after preparing it (never its text):
// queries (SELECT, WITH, VALUES, SHOW, DESCRIBE, SUMMARIZE and the PRAGMAs that DuckDB rewrites into a query) and
// EXPLAIN are read; everything else (CREATE, INSERT, UPDATE, DELETE, DROP, ALTER, COPY, ATTACH, SET, a PRAGMA that
// sets something, CALL, LOAD, transactions...) is refused before it runs.
pub fn readsOnly(ty: c.duckdb_statement_type) bool {
    return ty == c.DUCKDB_STATEMENT_TYPE_SELECT or ty == c.DUCKDB_STATEMENT_TYPE_EXPLAIN;
}

// !T: The format written in the file itself (its first bytes), not in its name: SQLite or DuckDB; null = neither
pub fn fileFormat(io: std.Io, path: []const u8) ?Source {
    var hb: [16]u8 = undefined;
    const h = std.Io.Dir.cwd().readFile(io, path, &hb) catch return null;
    if (std.mem.eql(u8, h, "SQLite format 3\x00")) return .sqlite;
    if (h.len >= 12 and std.mem.eql(u8, h[8..12], "DUCK")) return .duckdb;
    return null;
}

test "the format of a saved file comes from its first bytes (a DuckDB is not called SQLite)" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    const duck = tmpPath(&b1, &tmp, "f.duckdb");
    const lite = tmpPath(&b2, &tmp, "f.sqlite");
    var db = testDb();
    defer db.close();
    try db.open(duck, false);
    try db.exec("CREATE TABLE x AS SELECT 1 AS a");
    try db.open(":memory:", false);
    try db.loadSqlite();
    var ab: [400]u8 = undefined;
    try db.exec(try std.fmt.bufPrintSentinel(&ab, "ATTACH '{s}' AS l (TYPE sqlite)", .{lite}, 0));
    try db.exec("CREATE TABLE l.x AS SELECT 1 AS a");
    try db.exec("DETACH l");
    try t.expectEqual(Source.duckdb, fileFormat(t.io, duck).?);
    try t.expectEqual(Source.sqlite, fileFormat(t.io, lite).?);
    try t.expect(fileFormat(t.io, "nao_existe.sqlite") == null);
}

// !T: A call of a table function that attaches another database (sqlite_attach, postgres_attach, ... : a name
// ending in _attach, plain or quoted, followed by "("), outside string literals and comments. The statement type of
// such a SELECT is SELECT, so the type alone would let it run.
pub fn callsAttach(sql: []const u8) bool {
    var i: usize = 0;
    while (i < sql.len) {
        const ch = sql[i];
        if (ch == '\'') { // texto: ate o apostrofo que fecha ('' e um apostrofo dentro)
            i += 1;
            while (i < sql.len) : (i += 1) if (sql[i] == '\'') {
                if (i + 1 < sql.len and sql[i + 1] == '\'') i += 1 else break;
            };
            i += 1;
        } else if (ch == '-' and i + 1 < sql.len and sql[i + 1] == '-') {
            i = std.mem.indexOfScalarPos(u8, sql, i, '\n') orelse sql.len;
        } else if (ch == '/' and i + 1 < sql.len and sql[i + 1] == '*') {
            i = if (std.mem.indexOfPos(u8, sql, i + 2, "*/")) |e| e + 2 else sql.len;
        } else if (ch == '"' or std.ascii.isAlphabetic(ch) or ch == '_') {
            // nome (entre aspas ou nao) e, depois dos espacos, "("
            const quoted = ch == '"';
            const start = if (quoted) i + 1 else i;
            var end = start;
            if (quoted) {
                end = std.mem.indexOfScalarPos(u8, sql, start, '"') orelse sql.len;
            } else while (end < sql.len and (std.ascii.isAlphanumeric(sql[end]) or sql[end] == '_')) end += 1;
            const name = sql[start..end];
            i = if (quoted) @min(end + 1, sql.len) else end;
            var j = i;
            while (j < sql.len and std.ascii.isWhitespace(sql[j])) j += 1;
            if (j < sql.len and sql[j] == '(' and name.len >= "_attach".len and
                std.ascii.eqlIgnoreCase(name[name.len - "_attach".len ..], "_attach")) return true;
        } else i += 1;
    }
    return false;
}

test "SQL tab: a SELECT that calls a table function attaching a database is caught; the same words in text are not" {
    try t.expect(callsAttach("SELECT * FROM sqlite_attach('outro.sqlite', overwrite=true)"));
    try t.expect(callsAttach("select * from SQLITE_ATTACH ('x.db')"));
    try t.expect(callsAttach("SELECT * FROM \"sqlite_attach\"('x.db')"));
    try t.expect(callsAttach("WITH a AS (SELECT * FROM postgres_attach('dbname=x')) SELECT * FROM a"));
    try t.expect(!callsAttach("SELECT 'sqlite_attach(' AS s, 1 AS sqlite_attach"));
    try t.expect(!callsAttach("SELECT * FROM t -- sqlite_attach('x')\n"));
    try t.expect(!callsAttach("SELECT * FROM t /* sqlite_attach('x') */"));
    try t.expect(!callsAttach("SELECT 'it''s sqlite_attach(' FROM t"));
    try t.expect(!callsAttach("SELECT * FROM sqlite_scan('x.sqlite', 't')"));
}

// Por onde o arquivo aberto foi lido (mostrado na barra de status)
pub const Source = enum {
    duckdb,
    sqlite,
    access_odbc,
    access_mdbtools,

    pub fn label(s: Source) []const u8 {
        return switch (s) {
            .duckdb => "DuckDB",
            .sqlite => "SQLite",
            .access_odbc => i18n.tr("source_access_odbc"),
            .access_mdbtools => i18n.tr("source_access_mdbtools"),
        };
    }

    pub fn isAccess(s: Source) bool {
        return s == .access_odbc or s == .access_mdbtools;
    }
};

// Resultado materializado como texto; null = NULL do banco
pub const Grid = struct {
    arena: std.heap.ArenaAllocator,
    columns: []const [:0]const u8 = &.{},
    rows: []const []?[]const u8 = &.{},
    truncated: bool = false, // o resultado tinha mais que max_rows linhas (as outras nao foram lidas)
    float_cols: []const bool = &.{}, // colunas DOUBLE/FLOAT: a grade mostra 2.0 como 2 (so na tela, como no Go)
    num_cols: []const bool = &.{}, // colunas numericas: a grade alinha a direita (valor e cabecalho)
    keys: []const []const u8 = &.{}, // identidade de cada linha (consulta com Spec.with_key; linhas marcadas)

    pub fn deinit(self: *Grid) void {
        self.arena.deinit();
    }

    // A 1a coluna (a identidade da linha, Spec.with_key) sai da grade e vira `keys`
    fn splitKeys(self: *Grid) Allocator.Error!void {
        if (self.columns.len == 0) return;
        const a = self.arena.allocator();
        const keys = try a.alloc([]const u8, self.rows.len);
        const rows = try a.alloc([]?[]const u8, self.rows.len);
        for (keys, rows, self.rows) |*k, *r, row| {
            k.* = row[0] orelse "";
            r.* = row[1..];
        }
        self.keys = keys;
        self.rows = rows;
        self.columns = self.columns[1..];
        self.float_cols = self.float_cols[1..];
        self.num_cols = self.num_cols[1..];
    }

    // As linhas de `other` (as mesmas colunas) depois das suas, copiadas para a arena desta grade
    pub fn append(self: *Grid, other: *const Grid) Allocator.Error!void {
        const a = self.arena.allocator();
        const rows = try a.alloc([]?[]const u8, self.rows.len + other.rows.len);
        @memcpy(rows[0..self.rows.len], self.rows);
        for (rows[self.rows.len..], other.rows) |*dst, src| {
            const row = try a.alloc(?[]const u8, src.len);
            for (row, src) |*cell, s| cell.* = if (s) |v| try a.dupe(u8, v) else null;
            dst.* = row;
        }
        const keys = try a.alloc([]const u8, self.keys.len + other.keys.len);
        @memcpy(keys[0..self.keys.len], self.keys);
        for (keys[self.keys.len..], other.keys) |*k, s| k.* = try a.dupe(u8, s);
        self.rows = rows;
        self.keys = keys;
        self.truncated = self.truncated or other.truncated;
    }
};

// !T: One-line summary of an engine error for the status bar: the first line, without DuckDB's "<Kind> Error: "
// prefix and without the "LINE 1: ..." pointer. The full text goes to the log.
pub fn errorSummary(msg: []const u8) []const u8 {
    var s = std.mem.trim(u8, msg, " \t\r\n");
    if (std.mem.indexOfScalar(u8, s, '\n')) |nl| s = s[0..nl];
    if (std.mem.indexOf(u8, s, "LINE ")) |l| s = s[0..l];
    if (std.mem.indexOf(u8, s, " Error: ")) |e| {
        const kind = s[0..e];
        if (kind.len > 0 and kind.len <= 24 and std.mem.indexOfScalar(u8, kind, ' ') == null) s = s[e + " Error: ".len ..];
    }
    return std.mem.trim(u8, s, " \t\r");
}

test "engine error summary: first line, no DuckDB kind prefix, no LINE pointer" {
    try t.expectEqualStrings("syntax error at or near \"SELEC\"", errorSummary("Parser Error: syntax error at or near \"SELEC\"\n\nLINE 1: SELEC 1\n        ^"));
    try t.expectEqualStrings("syntax error at or near \"SELEC\"", errorSummary("Parser Error: syntax error at or near \"SELEC\"  LINE 1: SELEC 1   ^^^^^"));
    try t.expectEqualStrings("Table with name nope does not exist!", errorSummary("Catalog Error: Table with name nope does not exist!\nDid you mean \"note\"?"));
    try t.expectEqualStrings("File not found", errorSummary("File not found"));
    try t.expectEqualStrings("mdb-export failed on table X", errorSummary("mdb-export failed on table X"));
}

// Versao da libduckdb carregada (ex.: "v2.0.0")
pub fn libraryVersion() []const u8 {
    return std.mem.span(c.duckdb_library_version());
}

// Teto de linhas materializadas por consulta (o SQL livre pode devolver milhoes)
pub const max_rows = 10_000;

pub const QueryOpts = struct {
    wrap: bool = true, // SELECT CAST(COLUMNS(*) AS VARCHAR) FROM (...): todo tipo chega como texto
    types: bool = false, // le tambem os tipos originais das colunas (Rows.types)
};

// Resultado em fluxo (streaming): um bloco de linhas por vez, memoria limitada mesmo com milhoes de linhas.
// Enquanto existe, nenhuma outra consulta pode rodar na conexao.
pub const Rows = struct {
    db: *Db,
    stmt: c.duckdb_prepared_statement,
    pending: c.duckdb_pending_result,
    res: c.duckdb_result,
    n_cols: usize,
    types: []const c.duckdb_type = &.{}, // so com QueryOpts.types (tipos antes do CAST para texto)
    chunk: c.duckdb_data_chunk = null,
    size: usize = 0, // linhas do bloco atual

    // Ordem importa: o resultado depende do pending, que depende do statement
    pub fn deinit(r: *Rows) void {
        if (r.chunk != null) c.duckdb_destroy_data_chunk(&r.chunk);
        c.duckdb_destroy_result(&r.res);
        c.duckdb_destroy_pending(&r.pending);
        c.duckdb_destroy_prepare(&r.stmt);
        r.db.gpa.free(r.types);
    }

    pub fn name(r: *Rows, col: usize) []const u8 {
        return std.mem.span(c.duckdb_column_name(&r.res, col));
    }

    // Proximo bloco; false no fim. Erro durante a execucao (ex.: interrupcao) vira error.DuckDb.
    pub fn next(r: *Rows) Error!bool {
        if (r.chunk != null) c.duckdb_destroy_data_chunk(&r.chunk);
        r.chunk = c.duckdb_fetch_chunk(r.res);
        r.size = if (r.chunk != null) @intCast(c.duckdb_data_chunk_get_size(r.chunk)) else 0;
        if (r.chunk != null) return true;
        if (c.duckdb_result_error(&r.res)) |msg| {
            r.db.setError(msg);
            return error.DuckDb;
        }
        return false;
    }

    // Texto da celula (linha `row` do bloco atual). Aponta para a memoria do bloco ou para `buf`:
    // vale ate o proximo next().
    pub fn cell(r: *Rows, col: usize, row: usize, buf: *[64]u8) ?[]const u8 {
        const vec = c.duckdb_data_chunk_get_vector(r.chunk, col);
        const validity = c.duckdb_vector_get_validity(vec); // null = nenhum NULL no bloco
        if (validity != null and !c.duckdb_validity_row_is_valid(validity, row)) return null;
        const data = c.duckdb_vector_get_data(vec);
        const ty = c.duckdb_column_type(&r.res, col);
        return cellText(ty, data, row, buf);
    }
};

// Texto de uma celula. SELECTs chegam sempre como VARCHAR (ver Db.query); os outros tipos so
// aparecem em comandos que nao sao SELECT (PRAGMA, CREATE...).
fn cellText(ty: c.duckdb_type, data: ?*anyopaque, r: usize, buf: *[64]u8) []const u8 {
    return switch (ty) {
        c.DUCKDB_TYPE_VARCHAR => {
            const s = &at(c.duckdb_string_t, data)[r];
            return c.duckdb_string_t_data(s)[0..c.duckdb_string_t_length(s.*)];
        },
        c.DUCKDB_TYPE_BOOLEAN => if (at(bool, data)[r]) "true" else "false",
        c.DUCKDB_TYPE_TINYINT => fmtNum(buf, at(i8, data)[r]),
        c.DUCKDB_TYPE_SMALLINT => fmtNum(buf, at(i16, data)[r]),
        c.DUCKDB_TYPE_INTEGER => fmtNum(buf, at(i32, data)[r]),
        c.DUCKDB_TYPE_BIGINT => fmtNum(buf, at(i64, data)[r]),
        c.DUCKDB_TYPE_UTINYINT => fmtNum(buf, at(u8, data)[r]),
        c.DUCKDB_TYPE_USMALLINT => fmtNum(buf, at(u16, data)[r]),
        c.DUCKDB_TYPE_UINTEGER => fmtNum(buf, at(u32, data)[r]),
        c.DUCKDB_TYPE_UBIGINT => fmtNum(buf, at(u64, data)[r]),
        c.DUCKDB_TYPE_FLOAT => fmtNum(buf, at(f32, data)[r]),
        c.DUCKDB_TYPE_DOUBLE => fmtNum(buf, at(f64, data)[r]),
        // shortcut: other types of non-SELECT statements (and of a SELECT with text after its
        // final ";", which cannot be wrapped) are not decoded; wrap the statement
        // in a SELECT (e.g. FROM pragma_xxx()) to see the values
        else => "(not text)",
    };
}

fn fmtNum(buf: *[64]u8, v: anytype) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "?";
}

fn at(comptime T: type, data: ?*anyopaque) [*]T {
    return @ptrCast(@alignCast(data.?));
}

// Tipos que viram numero numa planilha
pub fn isNumericType(ty: c.duckdb_type) bool {
    return switch (ty) {
        c.DUCKDB_TYPE_TINYINT, c.DUCKDB_TYPE_SMALLINT, c.DUCKDB_TYPE_INTEGER, c.DUCKDB_TYPE_BIGINT, c.DUCKDB_TYPE_UTINYINT, c.DUCKDB_TYPE_USMALLINT, c.DUCKDB_TYPE_UINTEGER, c.DUCKDB_TYPE_UBIGINT, c.DUCKDB_TYPE_FLOAT, c.DUCKDB_TYPE_DOUBLE, c.DUCKDB_TYPE_DECIMAL, c.DUCKDB_TYPE_HUGEINT, c.DUCKDB_TYPE_UHUGEINT => true,
        else => false,
    };
}

pub fn isBoolType(ty: c.duckdb_type) bool {
    return ty == c.DUCKDB_TYPE_BOOLEAN;
}

pub const Db = struct {
    gpa: Allocator,
    db: c.duckdb_database = null,
    conn: c.duckdb_connection = null,
    tables: Grid, // 1 coluna: nomes (cache, como o tableSet do Go)
    table_names: []const []const u8 = &.{},
    source: ?Source = null, // arquivo aberto como "src"; null = nenhum
    sqlite_ext: []const u8 = "", // caminho do sqlite_scanner.duckdb_extension (pasta do programa)
    sqlite_loaded: bool = false,
    err_buf: [1024]u8 = undefined,
    err_len: usize = 0,

    pub fn init(gpa: Allocator) Db {
        return .{ .gpa = gpa, .tables = .{ .arena = .init(gpa) } };
    }

    pub fn isOpen(self: *const Db) bool {
        return self.source != null;
    }

    // Mensagem do ultimo erro.DuckDb
    pub fn lastError(self: *const Db) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    pub fn setError(self: *Db, msg: ?[*:0]const u8) void {
        const text: []const u8 = if (msg) |m| std.mem.span(m) else "unknown DuckDB error";
        self.setErrorText(text);
    }

    pub fn setErrorText(self: *Db, text: []const u8) void {
        self.err_len = @min(text.len, self.err_buf.len);
        @memcpy(self.err_buf[0..self.err_len], text[0..self.err_len]);
    }

    // Abre uma instancia DuckDB (fechando a anterior). O app usa so start(); os testes usam open
    // para criar bancos de exemplo.
    pub fn open(self: *Db, path: [:0]const u8, read_only: bool) Error!void {
        self.close();
        var config: c.duckdb_config = null;
        if (c.duckdb_create_config(&config) != c.DuckDBSuccess) return error.OutOfMemory;
        defer c.duckdb_destroy_config(&config);
        if (read_only) _ = c.duckdb_set_config(config, "access_mode", "READ_ONLY");
        // offline: nada de baixar nem carregar extensoes sozinho (a do SQLite e carregada do disco)
        _ = c.duckdb_set_config(config, "autoinstall_known_extensions", "false");
        _ = c.duckdb_set_config(config, "autoload_known_extensions", "false");

        var msg: [*c]u8 = null;
        if (c.duckdb_open_ext(path, &self.db, config, &msg) != c.DuckDBSuccess) {
            self.setError(msg);
            c.duckdb_free(msg);
            return error.DuckDb;
        }
        if (c.duckdb_connect(self.db, &self.conn) != c.DuckDBSuccess) {
            self.setError("failed to connect");
            c.duckdb_close(&self.db);
            return error.DuckDb;
        }
    }

    // A instancia em memoria do programa (uma vez, na thread da UI, antes de qualquer trabalho)
    pub fn start(self: *Db) Error!void {
        if (self.conn == null) try self.open(":memory:", false);
    }

    pub fn close(self: *Db) void {
        if (self.conn != null) c.duckdb_disconnect(&self.conn);
        if (self.db != null) c.duckdb_close(&self.db);
        self.forgetTables();
        self.source = null;
        self.sqlite_loaded = false;
    }

    fn forgetTables(self: *Db) void {
        _ = self.tables.arena.reset(.free_all);
        self.tables.rows = &.{};
        self.table_names = &.{};
    }

    // Solta o arquivo aberto (o lock do arquivo sai junto)
    pub fn closeSource(self: *Db) void {
        self.forgetTables();
        self.source = null;
        if (self.conn == null) return;
        terms.dropTables(self);
        self.exec("USE memory") catch {};
        self.exec("DETACH DATABASE IF EXISTS src") catch {};
    }

    // !T: Viewer path: extension whitelist + read-only ATTACH; a missing file is a DuckDB error.
    // Access files go through access.zig (converted into a SQLite file, then opened here).
    pub fn openReadOnly(self: *Db, path: []const u8) Error!void {
        const kind = try query.sourceKind(path);
        if (kind == .access) return error.UnsupportedExtension;
        try self.start();
        // .db e de SQLite ou de DuckDB: tenta DuckDB e, se ele recusar o arquivo, SQLite
        if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".db")) {
            self.attachAs(path, .duckdb) catch return self.attachAs(path, .sqlite);
            return;
        }
        return self.attachAs(path, kind);
    }

    fn attachAs(self: *Db, path: []const u8, kind: query.SourceKind) Error!void {
        self.closeSource();
        if (kind == .sqlite) try self.loadSqlite();
        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(self.gpa);
        try sql.appendSlice(self.gpa, "ATTACH ");
        try query.writeLiteral(&sql, self.gpa, path);
        try sql.appendSlice(self.gpa, if (kind == .sqlite) " AS src (TYPE sqlite, READ_ONLY)" else " AS src (READ_ONLY)");
        try sql.append(self.gpa, 0);
        try self.exec(sql.items[0 .. sql.items.len - 1 :0]);
        errdefer self.closeSource();
        try self.exec("USE src");
        try self.refreshTables();
        self.source = if (kind == .sqlite) .sqlite else .duckdb;
    }

    // Extensao sqlite do DuckDB, lida do arquivo ao lado do programa (sem internet)
    pub fn loadSqlite(self: *Db) Error!void {
        if (self.sqlite_loaded) return;
        if (self.sqlite_ext.len == 0) {
            self.setErrorText(i18n.tr("err_sqlite_missing"));
            return error.DuckDb;
        }
        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(self.gpa);
        try sql.appendSlice(self.gpa, "LOAD ");
        try query.writeLiteral(&sql, self.gpa, self.sqlite_ext);
        try sql.append(self.gpa, 0);
        try self.exec(sql.items[0 .. sql.items.len - 1 :0]);
        self.sqlite_loaded = true;
    }

    // Interrompe a consulta em andamento; pode ser chamada de outra thread
    pub fn interrupt(self: *Db) void {
        if (self.conn != null) c.duckdb_interrupt(self.conn);
    }

    // Executa SQL com parametros '?' em fluxo (ver Rows)
    pub fn stream(self: *Db, sql: [:0]const u8, params: []const []const u8, opts: QueryOpts) Error!Rows {
        if (self.conn == null) {
            self.setError("no database connected");
            return error.DuckDb;
        }
        var stmt: c.duckdb_prepared_statement = null;
        errdefer c.duckdb_destroy_prepare(&stmt);
        var wrapped_ok = false;
        if (opts.wrap) {
            // !T: DuckDB itself casts every column to VARCHAR (any type, same text as the CLI), so the
            // reader only needs VARCHAR vectors. The row API (duckdb_value_varchar) is deprecated
            // and crashed in libduckdb 2.0.0 on the real NMR5 database.
            const wrapped = try self.gpa.printSentinel("SELECT CAST(COLUMNS(*) AS VARCHAR) FROM (\n{s}\n)", .{std.mem.trimEnd(u8, sql, " \t\r\n;")}, 0);
            defer self.gpa.free(wrapped);
            wrapped_ok = c.duckdb_prepare(self.conn, wrapped, &stmt) == c.DuckDBSuccess;
            // Nao e um SELECT (PRAGMA, SET, CREATE...) ou o SQL esta errado: roda como veio
            if (!wrapped_ok) c.duckdb_destroy_prepare(&stmt);
        }
        if (!wrapped_ok and c.duckdb_prepare(self.conn, sql, &stmt) != c.DuckDBSuccess) {
            self.setError(c.duckdb_prepare_error(stmt));
            return error.DuckDb;
        }
        for (params, 1..) |p, i| {
            if (c.duckdb_bind_varchar_length(stmt, i, p.ptr, p.len) != c.DuckDBSuccess) {
                self.setError("failed to bind parameter");
                return error.DuckDb;
            }
        }
        const types = if (opts.types) try self.columnTypes(sql, stmt, wrapped_ok) else &.{};
        errdefer self.gpa.free(types);

        var pending: c.duckdb_pending_result = null;
        errdefer c.duckdb_destroy_pending(&pending);
        // streaming: so os blocos pedidos sao calculados (duckdb_pending_prepared materializa tudo)
        if (c.duckdb_pending_prepared_streaming(stmt, &pending) != c.DuckDBSuccess) {
            self.setError(c.duckdb_pending_error(pending));
            return error.DuckDb;
        }
        var res: c.duckdb_result = std.mem.zeroes(c.duckdb_result);
        if (c.duckdb_execute_pending(pending, &res) != c.DuckDBSuccess) {
            self.setError(c.duckdb_result_error(&res));
            c.duckdb_destroy_result(&res);
            return error.DuckDb;
        }
        return .{ .db = self, .stmt = stmt, .pending = pending, .res = res, .n_cols = @intCast(c.duckdb_column_count(&res)), .types = types };
    }

    // Tipos das colunas antes do CAST para texto (prepara o SQL original so para ler os tipos)
    fn columnTypes(self: *Db, sql: [:0]const u8, stmt: c.duckdb_prepared_statement, wrapped: bool) Error![]c.duckdb_type {
        var raw: c.duckdb_prepared_statement = null;
        defer if (wrapped) c.duckdb_destroy_prepare(&raw);
        if (wrapped and c.duckdb_prepare(self.conn, sql, &raw) != c.DuckDBSuccess) {
            self.setError(c.duckdb_prepare_error(raw));
            return error.DuckDb;
        }
        const src = if (wrapped) raw else stmt;
        const n: usize = @intCast(c.duckdb_prepared_statement_column_count(src));
        const types = try self.gpa.alloc(c.duckdb_type, n);
        for (types, 0..) |*ty, i| ty.* = c.duckdb_prepared_statement_column_type(src, i);
        return types;
    }

    // Tipo do comando, como o DuckDB o classifica ao preparar (SQL errado: error.DuckDb com a mensagem dele)
    pub fn statementType(self: *Db, sql: [:0]const u8) Error!c.duckdb_statement_type {
        if (self.conn == null) {
            self.setError("no database connected");
            return error.DuckDb;
        }
        var stmt: c.duckdb_prepared_statement = null;
        defer c.duckdb_destroy_prepare(&stmt);
        if (c.duckdb_prepare(self.conn, sql, &stmt) != c.DuckDBSuccess) {
            self.setError(c.duckdb_prepare_error(stmt));
            return error.DuckDb;
        }
        return c.duckdb_prepared_statement_type(stmt);
    }

    // !T: SQL of the SQL tab: refused with error.SqlReadOnly unless the statement only reads (readsOnly). EXPLAIN
    // ANALYZE runs the statement it explains, so an EXPLAIN goes inside a transaction that is rolled back: the
    // open file, the converted copy and the memory database never change.
    pub fn runReadOnly(self: *Db, sql: [:0]const u8) Error!Grid {
        // um SELECT pode chamar uma funcao de tabela que anexa outro banco (sqlite_attach cria views e abre o arquivo):
        // recusado antes de preparar
        if (callsAttach(sql)) return error.SqlReadOnly;
        const ty = try self.statementType(sql);
        if (!readsOnly(ty)) return error.SqlReadOnly;
        if (ty != c.DUCKDB_STATEMENT_TYPE_EXPLAIN) return self.run(sql, &.{});
        try self.exec("BEGIN TRANSACTION");
        defer self.exec("ROLLBACK") catch {};
        // como veio (o EXPLAIN ja devolve texto): uma tentativa que falha dentro da transacao a deixaria abortada
        return self.collect(sql, &.{}, max_rows, .{ .wrap = false, .types = true });
    }

    // Executa SQL com parametros '?' e devolve tudo como texto (no maximo max_rows linhas)
    pub fn run(self: *Db, sql: [:0]const u8, params: []const []const u8) Error!Grid {
        return self.runMax(sql, params, max_rows);
    }

    // run com outro teto: consultas do programa que precisam de todas as linhas (o catalogo de colunas da busca em
    // todas as tabelas; o DB4 passa de 10.000 colunas)
    pub fn runMax(self: *Db, sql: [:0]const u8, params: []const []const u8, limit: usize) Error!Grid {
        return self.collect(sql, params, limit, .{ .types = true });
    }

    fn collect(self: *Db, sql: [:0]const u8, params: []const []const u8, limit: usize, opts: QueryOpts) Error!Grid {
        var rows = try self.stream(sql, params, opts);
        defer rows.deinit();

        var grid: Grid = .{ .arena = .init(self.gpa) };
        errdefer grid.deinit();
        const a = grid.arena.allocator();
        const columns = try a.alloc([:0]const u8, rows.n_cols);
        for (columns, 0..) |*col, i| col.* = try a.dupeSentinel(u8, rows.name(i), 0);
        const floats = try a.alloc(bool, rows.n_cols);
        for (floats, 0..) |*f, i| f.* = i < rows.types.len and (rows.types[i] == c.DUCKDB_TYPE_DOUBLE or rows.types[i] == c.DUCKDB_TYPE_FLOAT);
        grid.float_cols = floats;
        const nums = try a.alloc(bool, rows.n_cols);
        for (nums, 0..) |*n, i| n.* = i < rows.types.len and isNumericType(rows.types[i]);
        grid.num_cols = nums;

        var list: std.ArrayList([]?[]const u8) = .empty;
        var buf: [64]u8 = undefined;
        while (try rows.next()) {
            const take = @min(rows.size, limit - list.items.len);
            for (0..take) |r| {
                const row = try a.alloc(?[]const u8, rows.n_cols);
                for (row, 0..) |*cell, col| cell.* = if (rows.cell(col, r, &buf)) |s| try a.dupe(u8, s) else null;
                try list.append(a, row);
            }
            // Para no teto: o resto nem e calculado (resultado em fluxo)
            if (list.items.len == limit) {
                grid.truncated = take < rows.size or try rows.next();
                break;
            }
        }
        grid.columns = columns;
        grid.rows = list.items;
        return grid;
    }

    pub fn exec(self: *Db, sql: [:0]const u8) Error!void {
        var rows = try self.stream(sql, &.{}, .{ .wrap = false });
        defer rows.deinit();
        while (try rows.next()) {}
    }

    // !T: SHOW TABLES, cached; the cache is the whitelist for every table name used in SQL
    pub fn refreshTables(self: *Db) Error!void {
        var g = try self.run("SHOW TABLES", &.{});
        self.tables.deinit();
        self.tables = g;
        const names = try g.arena.allocator().alloc([]const u8, g.rows.len);
        for (names, g.rows) |*n, row| n.* = row[0] orelse "";
        self.tables.arena = g.arena; // o alloc acima mudou o estado da arena
        self.table_names = names;
    }

    // Colunas: Column, Type, Null (YES/NO) - mesmo formato de get_table_schema
    pub fn schema(self: *Db, table: []const u8) Error!Grid {
        const sql = try query.buildSchema(self.gpa, self.table_names, table);
        defer self.gpa.free(sql);
        var grid = try self.run(sql, &.{}); // column_name, column_type, null, key, default, extra
        const rows = try grid.arena.allocator().dupe([]?[]const u8, grid.rows);
        for (rows) |*row| row.* = row.*[0..3];
        grid.columns = &.{ "Column", "Type", "Null" };
        grid.rows = rows;
        return grid;
    }

    pub fn page(self: *Db, spec: query.Spec) Error!Grid {
        const built = try query.buildSelect(self.gpa, spec);
        defer built.deinit(self.gpa);
        var g = try self.run(built.sql, built.params);
        errdefer g.deinit();
        if (spec.with_key) try g.splitKeys();
        return g;
    }

    // !T: Row identity of a table for the marked rows: the engine's rowid when the table has one (DuckDB tables, and
    // SQLite tables through the sqlite extension, so also the converted Access file); a view, or a table with a
    // column of its own called rowid, has none and uses the md5 of the whole row (identical rows are one row).
    pub fn rowKey(self: *Db, table: []const u8, columns: []const []const u8) Error!query.RowKey {
        if (query.hasRowidColumn(columns)) return .hash;
        if (!query.contains(self.table_names, table)) return error.TableNotFound;
        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(self.gpa);
        try sql.appendSlice(self.gpa, "SELECT " ++ query.row_alias ++ ".rowid FROM ");
        try query.writeIdent(&sql, self.gpa, table);
        try sql.appendSlice(self.gpa, " AS " ++ query.row_alias ++ " LIMIT 0");
        try sql.append(self.gpa, 0);
        // so prepara (nao roda): sem rowid o DuckDB recusa a coluna
        _ = self.statementType(sql.items[0 .. sql.items.len - 1 :0]) catch return .hash;
        return .rowid;
    }

    pub fn count(self: *Db, spec: query.Spec) Error!u64 {
        const built = try query.buildCount(self.gpa, spec);
        defer built.deinit(self.gpa);
        var g = try self.run(built.sql, built.params);
        defer g.deinit();
        return std.fmt.parseInt(u64, g.rows[0][0] orelse "0", 10) catch 0;
    }

    // Linhas de varias tabelas numa consulta so (UNION ALL): bem mais rapido que uma por tabela,
    // principalmente no SQLite. Se falhar, conta uma por uma (tabela com erro fica 0).
    pub fn countMany(self: *Db, names: []const []const u8, out: []u64) Error!void {
        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(self.gpa);
        // SQLite (e o Access convertido): o COUNT(*) roda no proprio SQLite (sqlite_query), que conta pela arvore
        // do indice sem ler as colunas; pelo leitor do DuckDB o DB4 levava ~8 s
        const native = if (self.source) |s| s != .duckdb else false;
        var inner: std.ArrayList(u8) = .empty;
        defer inner.deinit(self.gpa);
        for (names, 0..) |name, i| {
            if (!query.contains(self.table_names, name)) return error.TableNotFound;
            if (i > 0) try sql.appendSlice(self.gpa, " UNION ALL ");
            if (native) {
                inner.clearRetainingCapacity();
                try inner.appendSlice(self.gpa, "SELECT COUNT(*) FROM ");
                try query.writeIdent(&inner, self.gpa, name);
                try sql.print(self.gpa, "SELECT {d}, * FROM sqlite_query('src', ", .{i});
                try query.writeLiteral(&sql, self.gpa, inner.items);
                try sql.append(self.gpa, ')');
            } else {
                try sql.print(self.gpa, "SELECT {d}, COUNT(*) FROM ", .{i});
                try query.writeIdent(&sql, self.gpa, name);
            }
        }
        try sql.append(self.gpa, 0);
        @memset(out, 0);
        var g = self.run(sql.items[0 .. sql.items.len - 1 :0], &.{}) catch |e| {
            if (e == error.DuckDb and std.mem.indexOf(u8, self.lastError(), "nterrupt") != null) return e;
            for (names, out) |name, *n| n.* = self.count(.{ .table = name, .tables = self.table_names, .columns = &.{} }) catch 0;
            return;
        };
        defer g.deinit();
        for (g.rows) |row| {
            const i = std.fmt.parseInt(usize, row[0] orelse continue, 10) catch continue;
            if (i < out.len) out[i] = std.fmt.parseInt(u64, row[1] orelse "0", 10) catch 0;
        }
    }
};

// -------------------------------------------------------------------- tests

const t = std.testing;

test {
    // roda tambem os testes dos outros arquivos
    _ = query;
    _ = worker;
    _ = csv;
    _ = about;
    _ = capture;
    _ = gridtools;
    _ = xlsx;
    _ = exporter;
    _ = terms;
    _ = access;
    _ = settings;
    _ = i18n;
    _ = log;
    _ = display;
}

// Cria um banco de teste gravavel e fecha
pub fn makeSample(path: [:0]const u8) !void {
    var db = Db.init(t.allocator);
    defer db.close();
    try db.open(path, false);
    try db.exec("CREATE OR REPLACE TABLE people AS SELECT * FROM (VALUES " ++
        "(1, 'Ação', 10.5), (2, 'Bruno', NULL), (3, 'acao', 3.0), (4, 'Zé', 20.0)) v(id, name, score)");
    try db.exec("CREATE OR REPLACE TABLE big AS SELECT range AS n FROM range(250)");
    try db.exec("CREATE OR REPLACE TABLE strict (id INTEGER NOT NULL, note VARCHAR)");
}

pub fn tmpPath(buf: []u8, tmp: *const std.testing.TmpDir, name: []const u8) [:0]const u8 {
    return std.mem.printSentinel(buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name }, 0) catch unreachable;
}

// Db de teste com a extensao sqlite: o teste roda numa pasta com a duckdb.dll e a extensao (build.zig)
pub fn testDb() Db {
    var db = Db.init(t.allocator);
    db.sqlite_ext = "sqlite_scanner.duckdb_extension";
    return db;
}

test "Schema export: the tab titles and the nullable values in the screen language" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const path = tmpPath(&buf, &tmp, "schema.duckdb");
    try makeSample(path);
    var db = testDb();
    defer db.close();
    try db.openReadOnly(path);
    const sql = try query.buildSchemaExport(t.allocator, "strict", .{ "Coluna", "Tipo", "Aceita \"nulo\"" }, "Sim", "Não");
    defer t.allocator.free(sql);
    var g = try db.run(sql, &.{});
    defer g.deinit();
    try t.expectEqualStrings("Aceita \"nulo\"", g.columns[2]);
    try t.expectEqual(2, g.rows.len);
    try t.expectEqualStrings("id", g.rows[0][0].?);
    try t.expectEqualStrings("Não", g.rows[0][2].?); // id INTEGER NOT NULL
    try t.expectEqualStrings("Sim", g.rows[1][2].?);
}

test "SQL tab is read-only: reads run, every other statement is refused by its DuckDB statement type, nothing changes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const path = tmpPath(&buf, &tmp, "ro.duckdb");
    try makeSample(path);
    var db = Db.init(t.allocator);
    defer db.close();
    try db.openReadOnly(path);
    const reads = [_][:0]const u8{
        "SELECT * FROM people",                             "WITH x AS (SELECT 1 AS a) SELECT a FROM x",
        "FROM people",                                      "VALUES (1), (2)",
        "TABLE people",                                     "SHOW TABLES",
        "DESCRIBE people",                                  "SUMMARIZE people",
        "EXPLAIN SELECT * FROM people",                     "PRAGMA version",
        "PRAGMA table_info('people')",                      "PRAGMA database_list",
        "select count(*) from big ;",                       "/* c */ SELECT 1 -- fim",
    };
    for (reads) |sql| {
        var g = db.runReadOnly(sql) catch |e| {
            std.debug.print("refused or failed: {s} ({t}: {s})\n", .{ sql, e, db.lastError() });
            return e;
        };
        g.deinit();
    }
    // escrita na memoria (o arquivo esta anexado so para leitura), configuracao, arquivos, outros bancos: recusados
    const writes = [_][:0]const u8{
        "CREATE TABLE memory.main.x (a INTEGER)",           "CREATE TEMP TABLE x AS SELECT 1 AS a",
        "CREATE VIEW memory.main.v AS SELECT 1",            "CREATE MACRO memory.main.f(a) AS a + 1",
        "INSERT INTO people VALUES (9, 'x', 1.0)",          "UPDATE people SET name = 'x'",
        "DELETE FROM people",                               "DROP TABLE people",
        "ALTER TABLE people ADD COLUMN z INTEGER",          "WITH x AS (SELECT 1) INSERT INTO big SELECT * FROM x",
        "ATTACH ':memory:' AS other",                       "DETACH src",
        "USE memory",                                       "SET threads = 2",
        "RESET threads",                                    "PRAGMA threads = 2",
        "PRAGMA enable_profiling",                          "COPY people TO 'people_copy.csv'",
        "COPY (SELECT 1) TO 'one.csv'",                     "EXPORT DATABASE 'exported'",
        "CALL pragma_version()",                            "CHECKPOINT",
        "VACUUM",                                           "BEGIN TRANSACTION",
        "PREPARE p AS SELECT 1",                            "LOAD sqlite",
        "SELECT * FROM sqlite_attach('ro_other.sqlite', overwrite=true)",
    };
    for (writes) |sql| {
        if (db.runReadOnly(sql)) |g| {
            var grid = g;
            grid.deinit();
            std.debug.print("ran, should be refused: {s}\n", .{sql});
            return error.TestUnexpectedResult;
        } else |e| if (e != error.SqlReadOnly) {
            std.debug.print("{s}: {t} ({s})\n", .{ sql, e, db.lastError() });
            return error.TestUnexpectedResult;
        }
    }
    // EXPLAIN ANALYZE roda o comando explicado: a transacao desfeita nao deixa a tabela na memoria
    if (db.runReadOnly("EXPLAIN ANALYZE CREATE TABLE memory.main.sneaky AS SELECT 1 AS a")) |g| {
        var grid = g;
        grid.deinit();
    } else |_| {}
    try t.expectError(error.DuckDb, db.exec("SELECT * FROM memory.main.sneaky"));
    // varios comandos de uma vez nunca rodaram na aba SQL (o DuckDB recusa ao preparar)
    try t.expectError(error.DuckDb, db.runReadOnly("SELECT 1; DROP TABLE people"));
    // SQL errado: o erro do DuckDB, como antes
    try t.expectError(error.DuckDb, db.runReadOnly("SELEC 1"));
    try t.expect(std.mem.indexOf(u8, db.lastError(), "syntax error") != null);
    // nada mudou, e o que foi recusado nao criou arquivo
    try t.expectEqual(3, db.table_names.len);
    try t.expectEqual(4, try db.count(.{ .table = "people", .tables = db.table_names, .columns = &.{} }));
    try t.expectError(error.FileNotFound, std.Io.Dir.cwd().access(t.io, "one.csv", .{}));
    try t.expectError(error.FileNotFound, std.Io.Dir.cwd().access(t.io, "people_copy.csv", .{}));
    try t.expectError(error.FileNotFound, std.Io.Dir.cwd().access(t.io, "ro_other.sqlite", .{}));
    try t.expect(readsOnly(c.DUCKDB_STATEMENT_TYPE_SELECT) and readsOnly(c.DUCKDB_STATEMENT_TYPE_EXPLAIN));
    for ([_]c.duckdb_statement_type{ c.DUCKDB_STATEMENT_TYPE_INSERT, c.DUCKDB_STATEMENT_TYPE_UPDATE, c.DUCKDB_STATEMENT_TYPE_DELETE, c.DUCKDB_STATEMENT_TYPE_CREATE, c.DUCKDB_STATEMENT_TYPE_DROP, c.DUCKDB_STATEMENT_TYPE_ALTER, c.DUCKDB_STATEMENT_TYPE_COPY, c.DUCKDB_STATEMENT_TYPE_ATTACH, c.DUCKDB_STATEMENT_TYPE_DETACH, c.DUCKDB_STATEMENT_TYPE_SET, c.DUCKDB_STATEMENT_TYPE_PRAGMA, c.DUCKDB_STATEMENT_TYPE_CALL, c.DUCKDB_STATEMENT_TYPE_LOAD, c.DUCKDB_STATEMENT_TYPE_TRANSACTION, c.DUCKDB_STATEMENT_TYPE_EXPORT, c.DUCKDB_STATEMENT_TYPE_MULTI, c.DUCKDB_STATEMENT_TYPE_INVALID }) |ty|
        try t.expect(!readsOnly(ty));
}

test "rejects bad extension and missing file" {
    var db = Db.init(t.allocator);
    defer db.close();
    try t.expectError(error.UnsupportedExtension, db.openReadOnly("invalid.txt"));
    try t.expectError(error.DuckDb, db.openReadOnly("definitely/not_exists.duckdb"));
    try t.expect(db.lastError().len > 0);
    try t.expect(!db.isOpen());
    // sem a extensao ao lado do programa: mensagem clara, sem tentar baixar
    try t.expectError(error.DuckDb, db.openReadOnly("x.sqlite"));
    try t.expect(std.mem.indexOf(u8, db.lastError(), "sqlite_scanner") != null);
}

test "list tables, schema, paging, search, filter, sort, read-only" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const path = tmpPath(&buf, &tmp, "sample.duckdb");
    try makeSample(path);

    var db = Db.init(t.allocator);
    defer db.close();
    try db.openReadOnly(path);
    try t.expectEqual(.duckdb, db.source.?);
    try t.expectEqual(3, db.table_names.len);
    try t.expect(query.contains(db.table_names, "people"));

    // somente leitura, como read_only=True do python_pyqt6
    try t.expectError(error.DuckDb, db.exec("CREATE TABLE nope (x INTEGER)"));
    try t.expectError(error.TableNotFound, db.schema("nope"));

    var sch = try db.schema("strict");
    defer sch.deinit();
    try t.expectEqualStrings("id", sch.rows[0][0].?);
    try t.expectEqualStrings("INTEGER", sch.rows[0][1].?);
    try t.expectEqualStrings("NO", sch.rows[0][2].?);
    try t.expectEqualStrings("YES", sch.rows[1][2].?);
    // a mesma consulta que main.zig usa para exportar o esquema (aba Schema -> CSV/xlsx)
    var sch_export = try db.run("SELECT column_name AS \"Column\", column_type AS \"Type\", \"null\" AS \"Null\" FROM (DESCRIBE \"strict\")", &.{});
    defer sch_export.deinit();
    try t.expectEqualStrings("Column", sch_export.columns[0]);
    try t.expectEqualStrings("NO", sch_export.rows[0][2].?);

    // paginacao: 250 linhas, pagina 3 de 100 tem 50
    const big_cols = [_][]const u8{"n"};
    var spec: query.Spec = .{ .table = "big", .tables = db.table_names, .columns = &big_cols, .sort_column = "n", .offset = 200 };
    try t.expectEqual(250, try db.count(spec));
    var p3 = try db.page(spec);
    defer p3.deinit();
    try t.expectEqual(50, p3.rows.len);
    try t.expectEqualStrings("200", p3.rows[0][0].?);

    // busca sem diferenciar caixa/acentos
    const cols = [_][]const u8{ "id", "name", "score" };
    spec = .{ .table = "people", .tables = db.table_names, .columns = &cols, .search = "ACAO", .sort_column = "id" };
    try t.expectEqual(2, try db.count(spec));
    var found = try db.page(spec);
    defer found.deinit();
    try t.expectEqualStrings("Ação", found.rows[0][1].?);
    try t.expectEqualStrings("name", found.columns[1]);
    // varias palavras: todas na mesma coluna, qualquer ordem ("Ação" e "acao"); em colunas diferentes nao casa
    spec.search = "ÃO  ac";
    try t.expectEqual(2, try db.count(spec));
    spec.search = "acao 10";
    try t.expectEqual(0, try db.count(spec));

    // criterios AND / OR, numerico e NULL
    spec = .{ .table = "people", .tables = db.table_names, .columns = &cols, .criteria = &.{
        .{ .column = "score", .op = .greater, .value = "5" },
        .{ .column = "name", .op = .starts_with, .value = "z" },
    } };
    try t.expectEqual(1, try db.count(spec));
    spec.match_any = true;
    try t.expectEqual(2, try db.count(spec));
    spec.criteria = &.{.{ .column = "score", .op = .is_null }};
    var nulls = try db.page(spec);
    defer nulls.deinit();
    try t.expectEqual(1, nulls.rows.len);
    try t.expect(nulls.rows[0][2] == null);
}

// Filtro do clique direito (coluna = valor exato), o mesmo em DuckDB, SQLite e Access (banco em memoria)
const filter_table = "o'k \"t\"";
const filter_ddl = " AS SELECT * FROM (VALUES ('U9A', 1, DATE '2026-07-14'), ('it''s \"q\"', 2, NULL), (NULL, NULL, NULL), " ++
    "('u9a', 10, DATE '2026-07-15'), ('', 3, NULL), ('U9A', 11, DATE '2026-07-14')) v(\"si\"\"gla\", n, d)";

fn expectExactFilters(db: *Db) !void {
    const cols = [_][]const u8{ "si\"gla", "n", "d" };
    const cases = [_]struct { query.Criterion, u64 }{
        .{ .{ .column = "si\"gla", .op = .exact, .value = "U9A" }, 2 }, // caixa conta: nao pega 'u9a'
        .{ .{ .column = "si\"gla", .op = .exact, .value = "it's \"q\"" }, 1 }, // aspas no valor
        .{ .{ .column = "si\"gla", .op = .exact, .value = "' OR '1'='1" }, 0 }, // injecao e so um texto que nao existe
        .{ .{ .column = "si\"gla", .op = .exact, .value = "" }, 1 }, // texto vazio nao e NULL
        .{ .{ .column = "si\"gla", .op = .is_null }, 1 },
        .{ .{ .column = "n", .op = .exact, .value = "1" }, 1 }, // inteiro: 1 nao pega 10 nem 11
        .{ .{ .column = "n", .op = .is_null }, 1 },
        .{ .{ .column = "d", .op = .exact, .value = "2026-07-14" }, 2 }, // data, pelo texto exibido
    };
    var spec: query.Spec = .{ .table = filter_table, .tables = db.table_names, .columns = &cols };
    for (cases) |case| {
        spec.criteria = &.{case[0]};
        try t.expectEqual(case[1], try db.count(spec));
    }
    // varios filtros somam (AND), combinam com a busca e respeitam o limite de linhas
    spec.criteria = &.{ cases[0][0], .{ .column = "d", .op = .exact, .value = "2026-07-14" }, .{ .column = "n", .op = .exact, .value = "11" } };
    spec.search = "u9";
    try t.expectEqual(1, try db.count(spec));
    spec.criteria = spec.criteria[0..1];
    spec.limit = 1;
    var g = try db.page(spec);
    defer g.deinit();
    try t.expectEqual(1, g.rows.len);
    try t.expectEqualStrings("U9A", g.rows[0][0].?);
}

test "exact value filter on DuckDB and SQLite (the converted Access file)" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    const duck = tmpPath(&b1, &tmp, "f.duckdb");
    const lite = tmpPath(&b2, &tmp, "f.sqlite");
    var ident: std.ArrayList(u8) = .empty;
    defer ident.deinit(t.allocator);
    try query.writeIdent(&ident, t.allocator, filter_table);
    var sql_buf: [1024]u8 = undefined;

    var db = testDb();
    defer db.close();
    try db.open(duck, false);
    try db.exec(try std.fmt.bufPrintSentinel(&sql_buf, "CREATE TABLE {s}" ++ filter_ddl, .{ident.items}, 0));
    try db.open(":memory:", false);
    try db.loadSqlite();
    try db.exec(try std.fmt.bufPrintSentinel(&sql_buf, "ATTACH '{s}' AS w (TYPE sqlite)", .{lite}, 0));
    try db.exec(try std.fmt.bufPrintSentinel(&sql_buf, "CREATE TABLE w.{s}" ++ filter_ddl, .{ident.items}, 0));
    try db.exec("DETACH w");

    try db.openReadOnly(duck);
    try expectExactFilters(&db);
    // o Access convertido e lido deste mesmo jeito (access.zig grava um SQLite)
    try db.openReadOnly(lite);
    try t.expectEqual(.sqlite, db.source.?);
    try expectExactFilters(&db);
}

test "grid marks DOUBLE/FLOAT columns and keeps their original text" {
    var db = Db.init(t.allocator);
    defer db.close();
    try db.start();
    var g = try db.run("SELECT 2316.0::DOUBLE AS d, 2.5::DOUBLE AS e, '2.0' AS s, 2::FLOAT AS f, 2 AS i, 2.0::DECIMAL(4,1) AS m", &.{});
    defer g.deinit();
    try t.expectEqualSlices(bool, &.{ true, true, false, true, false, false }, g.float_cols);
    try t.expectEqualSlices(bool, &.{ true, true, false, true, true, true }, g.num_cols); // numeros a direita
    // a celula guarda o texto do banco: copia e "Filter by this value" (CAST AS VARCHAR = ?) continuam iguais
    try t.expectEqualStrings("2316.0", g.rows[0][0].?);
    try t.expectEqualStrings("2.0", g.rows[0][2].?);
    try t.expectEqualStrings("2.0", g.rows[0][3].?);
}

test "free SQL result is capped at max_rows and streamed" {
    var db = Db.init(t.allocator);
    defer db.close();
    try db.start();
    var g = try db.run("SELECT * FROM range(10050)", &.{});
    defer g.deinit();
    try t.expectEqual(max_rows, g.rows.len);
    try t.expect(g.truncated);
    var exact = try db.run("SELECT * FROM range(10000)", &.{});
    defer exact.deinit();
    try t.expect(!exact.truncated and exact.rows.len == max_rows);
    // um resultado enorme nao e materializado: so os primeiros blocos sao calculados
    var huge = try db.run("SELECT a.range * 1000000 + b.range AS n FROM range(1000000) a, range(1000000) b", &.{});
    defer huge.deinit();
    try t.expect(huge.truncated and huge.rows.len == max_rows);

    // qualquer tipo chega como texto; ponto e virgula no fim nao quebra
    var v = try db.run("SELECT DATE '2026-07-14' AS d, 1.50::DECIMAL(5,2) AS m, TIMESTAMP '2026-07-14 10:00:00' AS ts, NULL AS n, [1, 2] AS l ;\n", &.{});
    defer v.deinit();
    try t.expectEqualStrings("ts", v.columns[2]);
    try t.expectEqualStrings("2026-07-14", v.rows[0][0].?);
    try t.expectEqualStrings("1.50", v.rows[0][1].?);
    try t.expectEqualStrings("2026-07-14 10:00:00", v.rows[0][2].?);
    try t.expect(v.rows[0][3] == null);
    try t.expectEqualStrings("[1, 2]", v.rows[0][4].?);
    try t.expectError(error.DuckDb, db.exec("SELEC nonsense"));
    try t.expect(std.mem.indexOf(u8, db.lastError(), "syntax error") != null);

    // tipos originais, para a planilha saber o que e numero
    var typed = try db.stream("SELECT 1::INTEGER AS i, 'x' AS s, 2.5::DECIMAL(4,1) AS d, true AS b", &.{}, .{ .types = true });
    defer typed.deinit();
    try t.expect(isNumericType(typed.types[0]) and !isNumericType(typed.types[1]) and isNumericType(typed.types[2]));
    try t.expect(isBoolType(typed.types[3]));

    // um parametro a mais falha no bind sem derrubar o programa
    try t.expectError(error.DuckDb, db.run("SELECT 1", &.{"extra"}));
}

test "reopen closes the previous file" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    const first = tmpPath(&b1, &tmp, "first.duckdb");
    const second = tmpPath(&b2, &tmp, "second.db");
    try makeSample(first);
    try makeSample(second);
    // .db de SQLite tambem abre (a extensao serve aos dois formatos)
    {
        var b3: [256]u8 = undefined;
        const lite_db = tmpPath(&b3, &tmp, "lite.db");
        var w = testDb();
        defer w.close();
        try w.open(":memory:", false);
        try w.loadSqlite();
        var sb: [400]u8 = undefined;
        try w.exec(try std.fmt.bufPrintSentinel(&sb, "ATTACH '{s}' AS l (TYPE sqlite)", .{lite_db}, 0));
        try w.exec("CREATE TABLE l.t AS SELECT 1 AS x");
        try w.exec("DETACH l");
        var r = testDb();
        defer r.close();
        try r.openReadOnly(lite_db);
        try t.expectEqual(.sqlite, r.source.?);
        try r.openReadOnly(second);
        try t.expectEqual(.duckdb, r.source.?);
    }

    var db = Db.init(t.allocator);
    defer db.close();
    try db.openReadOnly(first);
    try db.openReadOnly(second);
    // o primeiro arquivo ficou livre: da para abrir gravavel
    var other = Db.init(t.allocator);
    defer other.close();
    try other.open(first, false);
}

test "sqlite file through the embedded DuckDB sqlite extension" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const path = tmpPath(&buf, &tmp, "sample.sqlite");
    var db = testDb();
    defer db.close();
    try db.start();
    try db.loadSqlite();
    var sql_buf: [400]u8 = undefined;
    try db.exec(try std.fmt.bufPrintSentinel(&sql_buf, "ATTACH '{s}' AS w (TYPE sqlite)", .{path}, 0));
    try db.exec("CREATE TABLE w.people AS SELECT * FROM (VALUES (1, 'Ação', 10.5), (2, NULL, NULL)) v(id, name, score)");
    try db.exec("DETACH w");

    try db.openReadOnly(path);
    try t.expectEqual(.sqlite, db.source.?);
    try t.expectEqual(1, db.table_names.len);
    var g = try db.run("SELECT * FROM people ORDER BY id", &.{});
    defer g.deinit();
    try t.expectEqualStrings("Ação", g.rows[0][1].?);
    try t.expect(g.rows[1][1] == null);
    try t.expectError(error.DuckDb, db.exec("CREATE TABLE nope (x INTEGER)")); // somente leitura
}
