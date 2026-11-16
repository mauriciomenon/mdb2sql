// Trabalhos do banco fora da thread da UI: um por vez, com o resultado num slot
// !T: Database jobs off the UI thread. One job at a time owns the Db; the UI thread polls the slot

const std = @import("std");
const dbm = @import("db.zig");
const query = dbm.query;
const exporter = @import("exporter.zig");
const access = @import("access.zig");
const Allocator = std.mem.Allocator;

pub const Kind = enum { open, select, reload, sql, export_ };

pub const ExportKind = enum {
    db_duckdb,
    db_sqlite,
    db_xlsx,
    table_csv,
    table_xlsx,
    result_csv,
    result_xlsx,

    pub fn ext(k: ExportKind) []const u8 {
        return switch (k) {
            .db_duckdb => ".duckdb",
            .db_sqlite => ".sqlite",
            .db_xlsx, .table_xlsx, .result_xlsx => ".xlsx",
            .table_csv, .result_csv => ".csv",
        };
    }

    // O trabalho conta tabelas (banco para banco) ou linhas (o resto)
    pub fn countsTables(k: ExportKind) bool {
        return k == .db_duckdb or k == .db_sqlite;
    }
};

// Pedido: copia do estado da UI, para a UI poder continuar editando os campos durante o trabalho
pub const Req = struct {
    kind: Kind = .open,
    path: [1024:0]u8 = @splat(0), // open
    table_name: []const u8 = "", // open: tabela inicial (sem diferenciar caixa); vazio = a primeira
    table: usize = 0, // select, reload, export de tabela
    columns: []const []const u8 = &.{}, // reload/export: colunas da tabela (do schema ja carregado)
    search: [256:0]u8 = @splat(0),
    sort_col: ?usize = null,
    sort_desc: bool = false,
    page: u64 = 0,
    sql: [8192:0]u8 = @splat(0), // sql, export do resultado
    export_kind: ExportKind = .db_duckdb,
    dest: [4096]u8 = undefined, // export: arquivo de destino (UTF-8)
    dest_len: usize = 0,
    total_hint: u64 = 0, // export de tabela/resultado: linhas esperadas (progresso)

    pub fn destPath(r: *const Req) []const u8 {
        return r.dest[0..r.dest_len];
    }

    pub fn setDest(r: *Req, p: []const u8) void {
        r.dest_len = @min(p.len, r.dest.len);
        @memcpy(r.dest[0..r.dest_len], p[0..r.dest_len]);
    }
};

// Resultado: o que nao for aproveitado pela UI e liberado por deinit
pub const Out = struct {
    kind: Kind,
    err: ?anyerror = null, // error.DuckDb/Failed: texto em db.lastError()
    counts: []u64 = &.{}, // open: linhas por tabela, na ordem de db.table_names
    source: ?dbm.Source = null, // open: por onde o arquivo foi lido
    table: ?usize = null,
    schema: ?dbm.Grid = null, // open, select
    columns: []const []const u8 = &.{}, // vive na arena de schema
    data: ?dbm.Grid = null, // open, select, reload
    total: u64 = 0,
    page: u64 = 0,
    result: ?dbm.Grid = null, // sql
    exported: u64 = 0, // export: tabelas ou linhas gravadas

    pub fn deinit(out: *Out, gpa: Allocator) void {
        gpa.free(out.counts);
        if (out.schema) |*g| g.deinit();
        if (out.data) |*g| g.deinit();
        if (out.result) |*g| g.deinit();
        out.* = .{ .kind = out.kind };
    }
};

// Contexto fixo dos trabalhos (o mesmo a cada pedido)
pub const Env = struct {
    io: std.Io,
    access: access.Options = .{},
};

// Executa o pedido (bloqueia). Erro fica em out.err; o texto de error.DuckDb em db.lastError()
pub fn run(db: *dbm.Db, gpa: Allocator, env: Env, req: *const Req, progress: *exporter.Progress) Out {
    var out: Out = .{ .kind = req.kind };
    exec(db, gpa, env, req, progress, &out) catch |e| {
        // consulta interrompida pelo Cancelar: mostra "Canceled", nao o erro cru do DuckDB
        out.err = if (progress.cancel.load(.monotonic) and (e == error.DuckDb or e == error.Failed)) error.Canceled else e;
    };
    return out;
}

fn exec(db: *dbm.Db, gpa: Allocator, env: Env, req: *const Req, progress: *exporter.Progress, out: *Out) !void {
    switch (req.kind) {
        .open => {
            const path = std.mem.sliceTo(&req.path, 0);
            if (try query.sourceKind(path) == .access) {
                out.source = try access.open(db, env.io, path, env.access, progress);
            } else {
                try db.openReadOnly(path);
                out.source = db.source;
            }
            const names = db.table_names;
            out.counts = try gpa.alloc(u64, names.len);
            progress.begin(names.len);
            var first: usize = 0;
            while (first < names.len) : (first += 32) {
                try progress.check();
                const end = @min(first + 32, names.len);
                try db.countMany(names[first..end], out.counts[first..end]);
                progress.add(end - first);
            }
            if (names.len == 0) return;
            var index: usize = 0;
            for (names, 0..) |n, i| {
                if (std.ascii.eqlIgnoreCase(n, req.table_name)) index = i;
            }
            try loadTable(db, index, out);
        },
        .select => try loadTable(db, req.table, out),
        .reload => {
            out.table = req.table;
            try loadPage(db, try tableSpec(db, req), req.page, out);
        },
        .sql => out.result = try db.run(std.mem.sliceTo(&req.sql, 0), &.{}),
        .export_ => out.exported = try exportJob(db, gpa, env, req, progress),
    }
}

// Tabela atual com a busca e a ordenacao da tela (sem pagina)
fn tableSpec(db: *dbm.Db, req: *const Req) !query.Spec {
    if (req.table >= db.table_names.len) return error.TableNotFound;
    return .{
        .table = db.table_names[req.table],
        .tables = db.table_names,
        .columns = req.columns,
        .search = std.mem.sliceTo(&req.search, 0),
        .sort_column = if (req.sort_col) |c| req.columns[c] else null,
        .sort_desc = req.sort_desc,
    };
}

fn exportJob(db: *dbm.Db, gpa: Allocator, env: Env, req: *const Req, progress: *exporter.Progress) !u64 {
    const dest = req.destPath();
    switch (req.export_kind) {
        .db_duckdb, .db_sqlite => {
            try exporter.database(db, env.io, if (req.export_kind == .db_duckdb) .duckdb else .sqlite, dest, progress);
            return db.table_names.len;
        },
        .db_xlsx => {
            try exporter.workbookAll(db, env.io, dest, progress, @import("xlsx.zig").max_data_rows);
            return progress.done.load(.monotonic);
        },
        .table_csv, .table_xlsx => {
            var spec = try tableSpec(db, req);
            spec.limit = 0; // todas as linhas
            const built = try query.buildSelect(gpa, spec);
            defer built.deinit(gpa);
            const format: exporter.FileFormat = if (req.export_kind == .table_csv) .csv else .xlsx;
            return exporter.selection(db, env.io, format, .{ .sql = built.sql, .params = built.params, .sheet = spec.table }, dest, progress, req.total_hint);
        },
        .result_csv, .result_xlsx => {
            const format: exporter.FileFormat = if (req.export_kind == .result_csv) .csv else .xlsx;
            return exporter.selection(db, env.io, format, .{ .sql = std.mem.sliceTo(&req.sql, 0), .sheet = "Query" }, dest, progress, req.total_hint);
        },
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
    env: Env,
    req: Req = .{},
    out: Out = .{ .kind = .open },
    progress: exporter.Progress = .{},
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),

    // Preencha `req` antes. So pode haver um trabalho por vez.
    pub fn start(s: *Slot) std.Thread.SpawnError!void {
        std.debug.assert(s.thread == null);
        s.done.store(false, .release);
        s.progress.cancel.store(false, .monotonic);
        s.progress.begin(0);
        s.thread = try std.Thread.spawn(.{}, work, .{s});
    }

    fn work(s: *Slot) void {
        s.out = run(s.db, s.gpa, s.env, &s.req, &s.progress);
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

    // Pede para parar: o trabalho confere a marca entre tabelas/blocos e o DuckDB interrompe a
    // consulta em andamento. A conexao vive o programa inteiro, entao interromper e sempre seguro.
    pub fn cancel(s: *Slot) void {
        if (!s.busy()) return;
        s.progress.cancel.store(true, .monotonic);
        s.db.interrupt();
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

test "jobs run on a worker thread: open, select, reload, sql, export, errors" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const path = dbm.tmpPath(&buf, &tmp, "sample.duckdb");
    try dbm.makeSample(path);

    var db = dbm.testDb();
    defer db.close();
    try db.start();
    var slot: Slot = .{ .db = &db, .gpa = t.allocator, .env = .{ .io = t.io } };
    try t.expect(slot.poll() == null and slot.wait() == null);

    // open: contagens de todas as tabelas + schema e primeira pagina da tabela pedida
    slot.req = .{ .kind = .open, .table_name = "PEOPLE" };
    setZ(&slot.req.path, path);
    try slot.start();
    try t.expect(slot.busy() and slot.busyWith(.open) and !slot.busyWith(.sql));
    var out = pollUntilDone(&slot);
    try t.expect(!slot.busy() and slot.poll() == null);
    try t.expect(out.err == null);
    try t.expectEqual(.duckdb, out.source.?);
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

    // export da tabela atual com a mesma busca: so as 2 linhas que casam
    slot.req.kind = .export_;
    slot.req.export_kind = .table_csv;
    var b2: [256]u8 = undefined;
    slot.req.setDest(dbm.tmpPath(&b2, &tmp, "people.csv"));
    try slot.start();
    out = slot.wait().?;
    try t.expect(out.err == null);
    try t.expectEqual(2, out.exported);
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

    // arquivo que nao e banco: erro, sem quebrar
    slot.req = .{ .kind = .open };
    setZ(&slot.req.path, "nada.txt");
    try slot.start();
    out = slot.wait().?;
    try t.expectEqual(error.UnsupportedExtension, out.err.?);
    out.deinit(t.allocator);
}

test "cancel interrupts a long query and the next job still works" {
    var db = dbm.Db.init(t.allocator);
    defer db.close();
    try db.start();
    var slot: Slot = .{ .db = &db, .gpa = t.allocator, .env = .{ .io = t.io }, .req = .{ .kind = .sql } };
    setZ(&slot.req.sql, "SELECT COUNT(*) FROM range(100000000000) a, range(100000) b");
    try slot.start();
    // o interrupt so pega depois que a consulta comecou: repete ate o trabalho terminar
    var out = while (true) {
        slot.cancel();
        if (slot.poll()) |o| break o;
        std.Thread.yield() catch {};
    };
    try t.expectEqual(error.Canceled, out.err.?);
    try t.expect(std.ascii.findIgnoreCase(db.lastError(), "interrupt") != null); // o DuckDB parou mesmo
    out.deinit(t.allocator);

    // um interrupt que chega sem consulta rodando nao pode derrubar o proximo trabalho
    db.interrupt();
    setZ(&slot.req.sql, "SELECT 42");
    try slot.start();
    out = slot.wait().?;
    defer out.deinit(t.allocator);
    try t.expect(out.err == null);
    try t.expectEqualStrings("42", out.result.?.rows[0][0].?);
}

// Sessao longa: abre e reabre (DuckDB e SQLite), troca de tabela, erra SQL, pede resultado enorme,
// exporta e cancela, muitas vezes seguidas. O alocador de teste acusa qualquer vazamento no fim.
test "long session: reopen, errors, huge result, export and cancel in a loop" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b1: [256]u8 = undefined;
    const duck = dbm.tmpPath(&b1, &tmp, "s.duckdb");
    try dbm.makeSample(duck);
    var b2: [256]u8 = undefined;
    const lite = dbm.tmpPath(&b2, &tmp, "s.sqlite");
    var b3: [256]u8 = undefined;
    const out_path = dbm.tmpPath(&b3, &tmp, "out.xlsx");

    var db = dbm.testDb();
    defer db.close();
    try db.start();
    var slot: Slot = .{ .db = &db, .gpa = t.allocator, .env = .{ .io = t.io } };
    // o .sqlite de teste nasce de uma exportacao do .duckdb
    try db.openReadOnly(duck);
    var p: exporter.Progress = .{};
    try exporter.database(&db, t.io, .sqlite, lite, &p);

    for (0..25) |round| {
        slot.req = .{ .kind = .open };
        setZ(&slot.req.path, if (round % 2 == 0) duck else lite);
        try slot.start();
        var out = slot.wait().?;
        try t.expect(out.err == null);
        try t.expectEqual(3, db.table_names.len);
        var schema = out.schema.?;
        out.schema = null;
        const columns = out.columns;
        out.deinit(t.allocator);
        defer schema.deinit();

        const jobs = [_]struct { Kind, []const u8 }{
            .{ .sql, "SELECT nope FROM nowhere" }, // erro
            .{ .sql, "SELECT a.range FROM range(100000) a, range(100000) b" }, // 10^10 linhas: so 10.000 lidas
            .{ .sql, "PRAGMA version" }, // nao da para embrulhar: roda como veio
        };
        for (jobs) |job| {
            slot.req = .{ .kind = job[0] };
            setZ(&slot.req.sql, job[1]);
            try slot.start();
            out = slot.wait().?;
            if (out.result) |g| try t.expect(g.rows.len <= dbm.max_rows);
            out.deinit(t.allocator);
        }

        // exporta a tabela atual; a cada 3 rodadas, cancela no meio
        slot.req = .{ .kind = .export_, .export_kind = .table_xlsx, .table = out_table(&db, "big"), .columns = columns[0..0] };
        slot.req.setDest(out_path);
        try slot.start();
        if (round % 3 == 0) slot.cancel();
        out = slot.wait().?;
        if (out.err) |e| try t.expectEqual(error.Canceled, e);
        out.deinit(t.allocator);
    }
}

fn out_table(db: *dbm.Db, name: []const u8) usize {
    for (db.table_names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return 0;
}
