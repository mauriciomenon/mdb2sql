// Trabalhos do banco fora da thread da UI: um por vez, com o resultado num slot
// !T: Database jobs off the UI thread. One job at a time owns the Db; the UI thread polls the slot

const std = @import("std");
const dbm = @import("db.zig");
const query = dbm.query;
const Allocator = std.mem.Allocator;

pub const Kind = enum { open, select, reload, sql };

// Pedido: copia do estado da UI, para a UI poder continuar editando os campos durante o trabalho
pub const Req = struct {
    kind: Kind = .open,
    path: [1024:0]u8 = @splat(0), // open
    table_name: []const u8 = "", // open: tabela inicial (sem diferenciar caixa); vazio = a primeira
    table: usize = 0, // select, reload
    columns: []const []const u8 = &.{}, // reload: colunas da tabela (do schema ja carregado)
    search: [256:0]u8 = @splat(0),
    sort_col: ?usize = null,
    sort_desc: bool = false,
    page: u64 = 0,
    sql: [8192:0]u8 = @splat(0), // sql
};

// Resultado: o que nao for aproveitado pela UI e liberado por deinit
pub const Out = struct {
    kind: Kind,
    err: ?dbm.Error = null,
    counts: []u64 = &.{}, // open: linhas por tabela, na ordem de db.table_names
    table: ?usize = null,
    schema: ?dbm.Grid = null, // open, select
    columns: []const []const u8 = &.{}, // vive na arena de schema
    data: ?dbm.Grid = null, // open, select, reload
    total: u64 = 0,
    page: u64 = 0,
    result: ?dbm.Grid = null, // sql

    pub fn deinit(out: *Out, gpa: Allocator) void {
        gpa.free(out.counts);
        if (out.schema) |*g| g.deinit();
        if (out.data) |*g| g.deinit();
        if (out.result) |*g| g.deinit();
        out.* = .{ .kind = out.kind };
    }
};

// Executa o pedido (bloqueia). Erro fica em out.err; o texto de error.DuckDb em db.lastError()
pub fn run(db: *dbm.Db, gpa: Allocator, req: *const Req) Out {
    var out: Out = .{ .kind = req.kind };
    exec(db, gpa, req, &out) catch |e| {
        out.err = e;
    };
    return out;
}

fn exec(db: *dbm.Db, gpa: Allocator, req: *const Req, out: *Out) dbm.Error!void {
    switch (req.kind) {
        .open => {
            try db.openReadOnly(std.mem.sliceTo(&req.path, 0));
            const names = db.table_names;
            out.counts = try gpa.alloc(u64, names.len);
            for (out.counts, names) |*n, name|
                n.* = db.count(.{ .table = name, .tables = names, .columns = &.{} }) catch 0;
            if (names.len == 0) return;
            var index: usize = 0;
            for (names, 0..) |n, i| {
                if (std.ascii.eqlIgnoreCase(n, req.table_name)) index = i;
            }
            try loadTable(db, index, out);
        },
        .select => try loadTable(db, req.table, out),
        .reload => {
            if (req.table >= db.table_names.len) return error.TableNotFound;
            out.table = req.table;
            try loadPage(db, .{
                .table = db.table_names[req.table],
                .tables = db.table_names,
                .columns = req.columns,
                .search = std.mem.sliceTo(&req.search, 0),
                .sort_column = if (req.sort_col) |c| req.columns[c] else null,
                .sort_desc = req.sort_desc,
            }, req.page, out);
        },
        .sql => out.result = try db.run(std.mem.sliceTo(&req.sql, 0), &.{}),
    }
}

// Schema + primeira pagina, sem busca nem ordenacao
fn loadTable(db: *dbm.Db, index: usize, out: *Out) dbm.Error!void {
    if (index >= db.table_names.len) return error.TableNotFound;
    out.table = index;
    out.schema = try db.schema(db.table_names[index]);
    const sch = &out.schema.?;
    const cols = try sch.arena.allocator().alloc([]const u8, sch.rows.len);
    for (cols, sch.rows) |*n, row| n.* = row[0] orelse "";
    out.columns = cols;
    try loadPage(db, .{ .table = db.table_names[index], .tables = db.table_names, .columns = cols }, 0, out);
}

fn loadPage(db: *dbm.Db, spec_in: query.Spec, page: u64, out: *Out) dbm.Error!void {
    var spec = spec_in;
    out.total = try db.count(spec);
    out.page = query.clampPage(page, out.total, spec.limit);
    spec.offset = out.page * spec.limit;
    out.data = try db.page(spec);
}

// Uma thread por trabalho. Enquanto busy(), so a thread do trabalho usa o Db.
pub const Slot = struct {
    db: *dbm.Db,
    gpa: Allocator, // precisa ser thread-safe
    req: Req = .{},
    out: Out = .{ .kind = .open },
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),

    // Preencha `req` antes. So pode haver um trabalho por vez.
    pub fn start(s: *Slot) std.Thread.SpawnError!void {
        std.debug.assert(s.thread == null);
        s.done.store(false, .release);
        s.thread = try std.Thread.spawn(.{}, work, .{s});
    }

    fn work(s: *Slot) void {
        s.out = run(s.db, s.gpa, &s.req);
        s.done.store(true, .release);
    }

    pub fn busy(s: *const Slot) bool {
        return s.thread != null;
    }

    pub fn busyWith(s: *const Slot, kind: Kind) bool {
        return s.thread != null and s.req.kind == kind;
    }

    // Sem bloquear: devolve o resultado uma unica vez, quando o trabalho terminou
    pub fn poll(s: *Slot) ?Out {
        if (!s.done.load(.acquire)) return null;
        return s.wait();
    }

    // Bloqueia ate o trabalho terminar; null se nao ha trabalho
    pub fn wait(s: *Slot) ?Out {
        const th = s.thread orelse return null;
        th.join();
        s.thread = null;
        s.done.store(false, .release);
        return s.out;
    }

    // Pede ao DuckDB para interromper a consulta em andamento (ela termina com erro)
    pub fn cancel(s: *Slot) void {
        // durante o open a conexao esta sendo trocada pela outra thread: nao ha o que interromper
        if (s.busy() and s.req.kind != .open) s.db.interrupt();
    }
};

// -------------------------------------------------------------------- tests

const t = std.testing;

fn setZ(buf: anytype, s: []const u8) void {
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
}

fn pollUntilDone(slot: *Slot) Out {
    while (true) {
        if (slot.poll()) |out| return out;
        std.Thread.yield() catch {};
    }
}

test "jobs run on a worker thread: open, select, reload, sql, errors" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const path = dbm.tmpPath(&buf, &tmp, "sample.duckdb");
    try dbm.makeSample(path);

    var db = dbm.Db.init(t.allocator);
    defer db.close();
    var slot: Slot = .{ .db = &db, .gpa = t.allocator };
    try t.expect(slot.poll() == null and slot.wait() == null);

    // open: contagens de todas as tabelas + schema e primeira pagina da tabela pedida
    slot.req = .{ .kind = .open, .table_name = "PEOPLE" };
    setZ(&slot.req.path, path);
    try slot.start();
    try t.expect(slot.busy() and slot.busyWith(.open) and !slot.busyWith(.sql));
    var out = pollUntilDone(&slot);
    try t.expect(!slot.busy() and slot.poll() == null);
    try t.expect(out.err == null);
    try t.expectEqual(3, out.counts.len);
    const people = out.table.?;
    try t.expectEqualStrings("people", db.table_names[people]);
    try t.expectEqual(4, out.counts[people]);
    try t.expectEqual(3, out.columns.len);
    try t.expectEqual(4, out.total);
    try t.expectEqual(4, out.data.?.rows.len);
    var schema = out.schema.?; // a UI fica com o schema (dono de `columns`) e libera o resto
    out.schema = null;
    defer schema.deinit();
    const columns = out.columns;
    out.deinit(t.allocator);

    // reload: busca sem acento, ordenacao desc, pagina alem do fim e ajustada
    slot.req = .{ .kind = .reload, .table = people, .columns = columns, .sort_col = 0, .sort_desc = true, .page = 7 };
    setZ(&slot.req.search, "ACAO");
    try slot.start();
    out = slot.wait().?;
    try t.expect(out.err == null);
    try t.expectEqual(2, out.total);
    try t.expectEqual(0, out.page);
    try t.expectEqualStrings("3", out.data.?.rows[0][0].?);
    out.deinit(t.allocator);

    // select de outra tabela
    for (db.table_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, "big")) slot.req = .{ .kind = .select, .table = i };
    }
    try slot.start();
    out = pollUntilDone(&slot);
    try t.expect(out.err == null);
    try t.expectEqual(250, out.total);
    try t.expectEqual(100, out.data.?.rows.len);
    out.deinit(t.allocator);

    // sql livre e erro de sql (a mensagem fica no Db)
    slot.req = .{ .kind = .sql };
    setZ(&slot.req.sql, "SELECT COUNT(*) AS n FROM big");
    try slot.start();
    out = slot.wait().?;
    try t.expectEqualStrings("250", out.result.?.rows[0][0].?);
    out.deinit(t.allocator);

    setZ(&slot.req.sql, "SELEC nonsense");
    try slot.start();
    out = slot.wait().?;
    try t.expectEqual(error.DuckDb, out.err.?);
    try t.expect(out.result == null and db.lastError().len > 0);
    out.deinit(t.allocator);

    slot.req = .{ .kind = .select, .table = 99 };
    try slot.start();
    out = slot.wait().?;
    try t.expectEqual(error.TableNotFound, out.err.?);
    out.deinit(t.allocator);
}

test "cancel interrupts a long query" {
    var db = dbm.Db.init(t.allocator);
    defer db.close();
    try db.open(":memory:", false);
    var slot: Slot = .{ .db = &db, .gpa = t.allocator, .req = .{ .kind = .sql } };
    setZ(&slot.req.sql, "SELECT COUNT(*) FROM range(100000000000) a, range(100000) b");
    try slot.start();
    // o interrupt so pega depois que a consulta comecou: repete ate o trabalho terminar
    var out = while (true) {
        slot.cancel();
        if (slot.poll()) |o| break o;
        std.Thread.yield() catch {};
    };
    defer out.deinit(t.allocator);
    try t.expectEqual(error.DuckDb, out.err.?);
    try t.expect(std.ascii.findIgnoreCase(db.lastError(), "interrupt") != null);
}
