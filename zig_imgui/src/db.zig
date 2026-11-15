// Gerenciador de conexao DuckDB (C API) - abre banco, lista tabelas, pagina, conta, schema
// !T: DuckDB connection manager over libduckdb's C API; mirrors py_qt6/src/backend/db_manager.py

const std = @import("std");
const c = @import("duckdb_c");
pub const query = @import("query.zig");
pub const worker = @import("worker.zig");
pub const csv = @import("csv.zig");
pub const about = @import("about.zig");
pub const gridtools = @import("gridtools.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{DuckDb} || query.BuildError || query.PathError;

// Resultado materializado como texto; null = NULL do banco
pub const Grid = struct {
    arena: std.heap.ArenaAllocator,
    columns: []const [:0]const u8 = &.{},
    rows: []const []?[]const u8 = &.{},
    total_rows: usize = 0, // linhas do resultado; rows.len <= max_rows

    pub fn deinit(self: *Grid) void {
        self.arena.deinit();
    }
};

// Versao da libduckdb carregada (ex.: "v2.0.0")
pub fn libraryVersion() []const u8 {
    return std.mem.span(c.duckdb_library_version());
}

// Teto de linhas materializadas por consulta (o SQL livre pode devolver milhoes)
pub const max_rows = 10_000;

pub const Db = struct {
    gpa: Allocator,
    db: c.duckdb_database = null,
    conn: c.duckdb_connection = null,
    tables: Grid, // 1 coluna: nomes (cache, como o tableSet do Go)
    table_names: []const []const u8 = &.{},
    err_buf: [1024]u8 = undefined,
    err_len: usize = 0,

    pub fn init(gpa: Allocator) Db {
        return .{ .gpa = gpa, .tables = .{ .arena = .init(gpa) } };
    }

    pub fn isOpen(self: *const Db) bool {
        return self.conn != null;
    }

    // Mensagem do ultimo erro.DuckDb
    pub fn lastError(self: *const Db) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    fn setError(self: *Db, msg: ?[*:0]const u8) void {
        const text: []const u8 = if (msg) |m| std.mem.span(m) else "unknown DuckDB error";
        self.err_len = @min(text.len, self.err_buf.len);
        @memcpy(self.err_buf[0..self.err_len], text[0..self.err_len]);
    }

    // !T: Viewer path: extension whitelist + read-only, a missing file is a DuckDB error
    pub fn openReadOnly(self: *Db, path: [:0]const u8) Error!void {
        try query.validateDbExtension(path);
        try self.open(path, true);
        errdefer self.close();
        try self.refreshTables();
    }

    // Abre (fechando a conexao anterior, como DBManager.connect)
    pub fn open(self: *Db, path: [:0]const u8, read_only: bool) Error!void {
        self.close();
        var config: c.duckdb_config = null;
        if (c.duckdb_create_config(&config) != c.DuckDBSuccess) return error.OutOfMemory;
        defer c.duckdb_destroy_config(&config);
        if (read_only) _ = c.duckdb_set_config(config, "access_mode", "READ_ONLY");

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

    pub fn close(self: *Db) void {
        if (self.conn != null) c.duckdb_disconnect(&self.conn);
        if (self.db != null) c.duckdb_close(&self.db);
        _ = self.tables.arena.reset(.free_all);
        self.tables.rows = &.{};
        self.table_names = &.{};
    }

    // Interrompe a consulta em andamento; pode ser chamada de outra thread
    pub fn interrupt(self: *Db) void {
        if (self.conn != null) c.duckdb_interrupt(self.conn);
    }

    // Executa SQL com parametros '?' e devolve tudo como texto
    pub fn run(self: *Db, sql: [:0]const u8, params: []const []const u8) Error!Grid {
        if (self.conn == null) {
            self.setError("no database connected");
            return error.DuckDb;
        }
        // !T: DuckDB itself casts every column to VARCHAR (any type, same text as the CLI), so the
        // reader below only needs VARCHAR vectors. The row API (duckdb_value_varchar) is deprecated
        // and crashed in libduckdb 2.0.0 on the real NMR5 database.
        const wrapped = try self.gpa.printSentinel("SELECT CAST(COLUMNS(*) AS VARCHAR) FROM (\n{s}\n)", .{std.mem.trimEnd(u8, sql, " \t\r\n;")}, 0);
        defer self.gpa.free(wrapped);
        var stmt: c.duckdb_prepared_statement = null;
        defer c.duckdb_destroy_prepare(&stmt);
        if (c.duckdb_prepare(self.conn, wrapped, &stmt) != c.DuckDBSuccess) {
            // Nao e um SELECT (PRAGMA, SET, CREATE...) ou o SQL esta errado: roda como veio
            c.duckdb_destroy_prepare(&stmt);
            if (c.duckdb_prepare(self.conn, sql, &stmt) != c.DuckDBSuccess) {
                self.setError(c.duckdb_prepare_error(stmt));
                return error.DuckDb;
            }
        }
        for (params, 1..) |p, i| {
            if (c.duckdb_bind_varchar_length(stmt, i, p.ptr, p.len) != c.DuckDBSuccess) {
                self.setError("failed to bind parameter");
                return error.DuckDb;
            }
        }
        var res: c.duckdb_result = undefined;
        defer c.duckdb_destroy_result(&res);
        if (c.duckdb_execute_prepared(stmt, &res) != c.DuckDBSuccess) {
            self.setError(c.duckdb_result_error(&res));
            return error.DuckDb;
        }

        var grid: Grid = .{ .arena = .init(self.gpa) };
        errdefer grid.deinit();
        const a = grid.arena.allocator();
        const n_cols: usize = @intCast(c.duckdb_column_count(&res));
        const columns = try a.alloc([:0]const u8, n_cols);
        for (columns, 0..) |*col, i| col.* = try a.dupeSentinel(u8, std.mem.span(c.duckdb_column_name(&res, i)), 0);

        var rows: std.ArrayList([]?[]const u8) = .empty;
        while (true) {
            var chunk = c.duckdb_fetch_chunk(res);
            if (chunk == null) break;
            defer c.duckdb_destroy_data_chunk(&chunk);
            const size: usize = @intCast(c.duckdb_data_chunk_get_size(chunk));
            grid.total_rows += size;
            // shortcut: past max_rows the chunks are only counted, but DuckDB still computes them;
            // use a streaming/pending result if huge free-SQL results become a problem
            const take = @min(size, max_rows - rows.items.len);
            const base = rows.items.len;
            for (0..take) |_| try rows.append(a, try a.alloc(?[]const u8, n_cols));
            for (0..n_cols) |col| {
                const vec = c.duckdb_data_chunk_get_vector(chunk, col);
                const validity = c.duckdb_vector_get_validity(vec); // null = nenhum NULL no chunk
                const data = c.duckdb_vector_get_data(vec);
                const ty = c.duckdb_column_type(&res, col);
                for (0..take) |r| {
                    const is_null = validity != null and !c.duckdb_validity_row_is_valid(validity, r);
                    rows.items[base + r][col] = if (is_null) null else try cellText(a, ty, data, r);
                }
            }
        }
        grid.columns = columns;
        grid.rows = rows.items;
        return grid;
    }

    // Texto de uma celula. SELECTs chegam sempre como VARCHAR (ver run); os outros tipos so
    // aparecem em comandos que nao sao SELECT (PRAGMA, CREATE...).
    fn cellText(a: Allocator, ty: c.duckdb_type, data: ?*anyopaque, r: usize) Allocator.Error![]const u8 {
        return switch (ty) {
            c.DUCKDB_TYPE_VARCHAR => {
                const s = &at(c.duckdb_string_t, data)[r];
                return a.dupe(u8, c.duckdb_string_t_data(s)[0..c.duckdb_string_t_length(s.*)]);
            },
            c.DUCKDB_TYPE_BOOLEAN => if (at(bool, data)[r]) "true" else "false",
            c.DUCKDB_TYPE_TINYINT => a.print("{d}", .{at(i8, data)[r]}),
            c.DUCKDB_TYPE_SMALLINT => a.print("{d}", .{at(i16, data)[r]}),
            c.DUCKDB_TYPE_INTEGER => a.print("{d}", .{at(i32, data)[r]}),
            c.DUCKDB_TYPE_BIGINT => a.print("{d}", .{at(i64, data)[r]}),
            c.DUCKDB_TYPE_UTINYINT => a.print("{d}", .{at(u8, data)[r]}),
            c.DUCKDB_TYPE_USMALLINT => a.print("{d}", .{at(u16, data)[r]}),
            c.DUCKDB_TYPE_UINTEGER => a.print("{d}", .{at(u32, data)[r]}),
            c.DUCKDB_TYPE_UBIGINT => a.print("{d}", .{at(u64, data)[r]}),
            c.DUCKDB_TYPE_FLOAT => a.print("{d}", .{at(f32, data)[r]}),
            c.DUCKDB_TYPE_DOUBLE => a.print("{d}", .{at(f64, data)[r]}),
            // shortcut: other types of non-SELECT statements (and of a SELECT with text after its
            // final ";", which cannot be wrapped) are not decoded; wrap the statement
            // in a SELECT (e.g. FROM pragma_xxx()) to see the values
            else => "(not text)",
        };
    }

    fn at(comptime T: type, data: ?*anyopaque) [*]T {
        return @ptrCast(@alignCast(data.?));
    }

    pub fn exec(self: *Db, sql: [:0]const u8) Error!void {
        var g = try self.run(sql, &.{});
        g.deinit();
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
        return self.run(built.sql, built.params);
    }

    pub fn count(self: *Db, spec: query.Spec) Error!u64 {
        const built = try query.buildCount(self.gpa, spec);
        defer built.deinit(self.gpa);
        var g = try self.run(built.sql, built.params);
        defer g.deinit();
        return std.fmt.parseInt(u64, g.rows[0][0] orelse "0", 10) catch 0;
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
    _ = gridtools;
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

test "rejects bad extension and missing file" {
    var db = Db.init(t.allocator);
    defer db.close();
    try t.expectError(error.UnsupportedExtension, db.openReadOnly("invalid.sqlite"));
    try t.expectError(error.DuckDb, db.openReadOnly("definitely/not_exists.duckdb"));
    try t.expect(db.lastError().len > 0);
    try t.expect(!db.isOpen());
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
    try t.expectEqual(3, db.table_names.len);
    try t.expect(query.contains(db.table_names, "people"));

    // somente leitura, como read_only=True do py_qt6
    try t.expectError(error.DuckDb, db.exec("CREATE TABLE nope (x INTEGER)"));
    try t.expectError(error.TableNotFound, db.schema("nope"));

    var sch = try db.schema("strict");
    defer sch.deinit();
    try t.expectEqualStrings("id", sch.rows[0][0].?);
    try t.expectEqualStrings("INTEGER", sch.rows[0][1].?);
    try t.expectEqualStrings("NO", sch.rows[0][2].?);
    try t.expectEqualStrings("YES", sch.rows[1][2].?);

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

test "free SQL result is capped at max_rows" {
    var db = Db.init(t.allocator);
    defer db.close();
    try db.open(":memory:", false);
    var g = try db.run("SELECT * FROM range(10050)", &.{});
    defer g.deinit();
    try t.expectEqual(max_rows, g.rows.len);
    try t.expectEqual(10050, g.total_rows);

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
}

test "reopen closes the previous connection" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    const first = tmpPath(&b1, &tmp, "first.duckdb");
    const second = tmpPath(&b2, &tmp, "second.db");
    try makeSample(first);
    try makeSample(second);

    var db = Db.init(t.allocator);
    defer db.close();
    try db.openReadOnly(first);
    try db.openReadOnly(second);
    // o primeiro arquivo ficou livre: da para abrir gravavel
    var other = Db.init(t.allocator);
    defer other.close();
    try other.open(first, false);
}
