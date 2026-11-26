// Trabalhos do banco fora da thread da UI: um por vez, com o resultado num slot
// !T: Database jobs off the UI thread. One job at a time owns the Db; the UI thread polls the slot

const std = @import("std");
const dbm = @import("db.zig");
const query = dbm.query;
const exporter = @import("exporter.zig");
const access = @import("access.zig");
const Allocator = std.mem.Allocator;

pub const Kind = enum { open, select, reload, sql, export_, search_all, terms, terms_page, terms_copy };
const terms = dbm.terms;

// Busca em todas as tabelas: tabela (indice em db.table_names) e linhas encontradas
pub const Hit = struct { table: usize, rows: u64 };

pub const ExportKind = enum {
    db_duckdb,
    db_sqlite,
    db_xlsx,
    table_csv,
    table_xlsx,
    result_csv,
    result_xlsx,
    marked_csv, // linhas marcadas da tabela atual (item 31)
    marked_xlsx,
    terms_xlsx, // relatorio da pesquisa de termos (item 32); CSV: uma pasta, um arquivo por aba
    terms_csv,
    terms_sqlite,
    terms_duckdb,

    pub fn ext(k: ExportKind) []const u8 {
        return switch (k) {
            .db_duckdb, .terms_duckdb => ".duckdb",
            .db_sqlite, .terms_sqlite => ".sqlite",
            .db_xlsx, .table_xlsx, .result_xlsx, .marked_xlsx, .terms_xlsx => ".xlsx",
            .table_csv, .result_csv, .marked_csv, .terms_csv => ".csv",
        };
    }

    // O trabalho conta tabelas (banco para banco) ou linhas (o resto)
    pub fn countsTables(k: ExportKind) bool {
        return k == .db_duckdb or k == .db_sqlite or k == .terms_sqlite or k == .terms_duckdb;
    }

    // Destino e uma pasta (um CSV por tabela ou por aba)
    pub fn toFolder(k: ExportKind) bool {
        return k == .terms_csv;
    }
};

// !T: Exporting the table of the Data tab while a search or a value filter narrows it asks first: the whole table or
// only the rows found (the 4 stacks). The schema, the SQL result and the database are exported as they are.
pub fn asksExportScope(kind: ExportKind, on_data_tab: bool, narrowed: bool) bool {
    return (kind == .table_csv or kind == .table_xlsx) and on_data_tab and narrowed;
}

test "export question only for the Data tab table with a search or filter" {
    try std.testing.expect(asksExportScope(.table_csv, true, true));
    try std.testing.expect(asksExportScope(.table_xlsx, true, true));
    try std.testing.expect(!asksExportScope(.table_csv, true, false)); // sem busca: a tabela inteira, sem pergunta
    try std.testing.expect(!asksExportScope(.table_csv, false, true)); // aba Esquema
    try std.testing.expect(!asksExportScope(.result_csv, true, true));
    try std.testing.expect(!asksExportScope(.db_sqlite, true, true));
}

// Pedido: copia do estado da UI, para a UI poder continuar editando os campos durante o trabalho
pub const Req = struct {
    kind: Kind = .open,
    path: [1024:0]u8 = @splat(0), // open
    table_name: []const u8 = "", // open: tabela inicial (sem diferenciar caixa); vazio = a primeira
    table: usize = 0, // select, reload, export de tabela
    columns: []const []const u8 = &.{}, // reload/export: colunas da tabela (do schema ja carregado)
    search: [256:0]u8 = @splat(0), // select (vazio = sem busca), reload, export, search_all
    filters: []const query.Criterion = &.{}, // reload/export: filtros coluna = valor exato (a UI so muda a lista sem trabalho rodando)
    key: ?query.RowKey = null, // reload/export: identidade de linha da tabela (a do Out.key do select)
    marks: []const []const u8 = &.{}, // select/reload/export: linhas marcadas da tabela (a UI so muda sem trabalho rodando)
    only_marked: bool = false, // reload: so as linhas marcadas
    sort_col: ?usize = null,
    sort_desc: bool = false,
    limit: u32 = query.default_limit, // open, select, reload: linhas carregadas (lista 100 / 500 / 1000)
    sql: [8192:0]u8 = @splat(0), // sql, export do resultado
    export_kind: ExportKind = .db_duckdb,
    dest: [4096]u8 = undefined, // export: arquivo de destino (UTF-8)
    dest_len: usize = 0,
    total_hint: u64 = 0, // export de tabela/resultado: linhas esperadas (progresso)
    // Pesquisa de termos (item 32)
    terms_text: []const u8 = "", // terms: a caixa (copia do gpa feita pela UI, solta por ela depois)
    term_match: terms.Match = .whole,
    terms_only: ?usize = null, // terms: so esta tabela (Esta tabela); null = todas
    terms_res: ?*const terms.Result = null, // terms_page, terms_copy, relatorio: o resultado mostrado (da UI)
    terms_hit: usize = 0, // terms_page, terms_copy: indice em terms_res.tables
    terms_titles: terms.Titles = undefined, // titulos da coluna do termo e do relatorio, no idioma da tela

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
    key: ?query.RowKey = null, // open, select: identidade de linha da tabela
    marked: usize = 0, // open, select, reload: as primeiras linhas de `data` sao as marcadas
    total: u64 = 0, // linhas da tabela que casam com a busca e os filtros (mais as marcadas, no topo)
    result: ?dbm.Grid = null, // sql
    exported: u64 = 0, // export: tabelas ou linhas gravadas
    converted: access.TempPath = .{}, // open de Access: o SQLite temporario (len 0 = nenhum)
    hits: []Hit = &.{}, // search_all: tabelas com linhas encontradas
    terms: ?terms.Result = null, // terms: o resultado (a grade da 1a tabela vem em `data`)
    copied: ?[]u8 = null, // terms_copy: o texto para a area de transferencia (gpa)

    pub fn deinit(out: *Out, gpa: Allocator) void {
        gpa.free(out.counts);
        gpa.free(out.hits);
        if (out.schema) |*g| g.deinit();
        if (out.data) |*g| g.deinit();
        if (out.result) |*g| g.deinit();
        if (out.terms) |*r| r.deinit();
        if (out.copied) |c| gpa.free(c);
        out.* = .{ .kind = out.kind, .converted = out.converted };
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
                out.source = try access.open(db, env.io, path, env.access, progress, &out.converted);
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
            try loadTable(db, index, "", req.limit, &.{}, out);
        },
        .select => try loadTable(db, req.table, std.mem.sliceTo(&req.search, 0), req.limit, req.marks, out),
        .reload => {
            out.table = req.table;
            var spec = try tableSpec(db, req);
            spec.limit = req.limit;
            spec.with_key = spec.key != null;
            try loadRows(db, spec, req.only_marked, out);
        },
        .sql => out.result = try db.runReadOnly(std.mem.sliceTo(&req.sql, 0)), // a aba SQL so le
        .export_ => out.exported = try exportJob(db, gpa, env, req, progress),
        .search_all => out.hits = try searchAll(db, gpa, std.mem.sliceTo(&req.search, 0), progress),
        .terms => {
            var res = try terms.search(db, gpa, req.terms_text, req.term_match, req.terms_only, progress);
            errdefer res.deinit();
            // a grade da primeira tabela com acerto ja vem junto
            if (res.tables.len > 0) out.data = try terms.page(db, gpa, &res, res.tables[0], req.terms_titles.term, req.limit);
            out.terms = res;
        },
        .terms_page => {
            const res = req.terms_res orelse return error.TableNotFound;
            if (req.terms_hit >= res.tables.len) return error.TableNotFound;
            out.data = try terms.page(db, gpa, res, res.tables[req.terms_hit], req.terms_titles.term, req.limit);
        },
        .terms_copy => {
            const res = req.terms_res orelse return error.TableNotFound;
            if (req.terms_hit >= res.tables.len) return error.TableNotFound;
            out.copied = try terms.copyText(db, gpa, res, res.tables[req.terms_hit], progress);
        },
    }
}

// !T: Search in every table with the rule and the query of the Data tab search (query.buildCount: every column as
// text, every word in one cell, ignoring case and accents), so the count listed is the row count the table shows
// when opened with the same search. The columns of all tables come from one query and the counts go in UNION ALL
// batches (a DESCRIBE + COUNT per table took ~0.2 s each on a SQLite file). Returns the tables with at least one
// row, in table order.
pub fn searchAll(db: *dbm.Db, gpa: Allocator, term: []const u8, progress: *exporter.Progress) ![]Hit {
    var hits: std.ArrayList(Hit) = .empty;
    errdefer hits.deinit(gpa);
    if (std.mem.indexOfNone(u8, term, &std.ascii.whitespace) == null) return hits.toOwnedSlice(gpa);
    const names = db.table_names;
    // o catalogo inteiro: com o teto do SQL livre (max_rows) as tabelas depois da coluna 10.000 ficavam de fora
    var cols = try db.runMax("SELECT table_name, column_name FROM duckdb_columns() WHERE database_name = current_database() " ++
        "AND schema_name = current_schema() ORDER BY table_name, column_index", &.{}, std.math.maxInt(usize));
    defer cols.deinit();
    var text: std.ArrayList([]const u8) = .empty; // colunas da tabela
    defer text.deinit(gpa);
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(gpa);
    var params: std.ArrayList([]const u8) = .empty; // fatias de `term`
    defer params.deinit(gpa);
    progress.begin(names.len);
    var first: usize = 0;
    while (first < names.len) : (first += 32) {
        try progress.check();
        const end = @min(first + 32, names.len);
        sql.clearRetainingCapacity();
        params.clearRetainingCapacity();
        for (first..end) |i| {
            text.clearRetainingCapacity();
            for (cols.rows) |row| if (std.mem.eql(u8, row[0] orelse "", names[i])) try text.append(gpa, row[1] orelse "");
            if (text.items.len == 0) continue;
            if (sql.items.len > 0) try sql.appendSlice(gpa, " UNION ALL ");
            const built = try query.buildCount(gpa, .{ .table = names[i], .tables = names, .columns = text.items, .search = term });
            defer built.deinit(gpa);
            try sql.print(gpa, "SELECT {d}, ({s})", .{ i, built.sql });
            try params.appendSlice(gpa, built.params);
        }
        if (sql.items.len > 0) {
            try sql.append(gpa, 0);
            var g = try db.run(sql.items[0 .. sql.items.len - 1 :0], params.items);
            defer g.deinit();
            for (g.rows) |row| {
                const i = std.fmt.parseInt(usize, row[0] orelse continue, 10) catch continue;
                const n = std.fmt.parseInt(u64, row[1] orelse "0", 10) catch 0;
                if (n > 0) try hits.append(gpa, .{ .table = i, .rows = n });
            }
        }
        progress.add(end - first);
    }
    std.mem.sort(Hit, hits.items, {}, struct {
        fn less(_: void, a: Hit, b: Hit) bool {
            return a.table < b.table;
        }
    }.less);
    return hits.toOwnedSlice(gpa);
}

// Tabela atual com a busca e a ordenacao da tela (sem o limite de linhas)
fn tableSpec(db: *dbm.Db, req: *const Req) !query.Spec {
    if (req.table >= db.table_names.len) return error.TableNotFound;
    return .{
        .table = db.table_names[req.table],
        .tables = db.table_names,
        .columns = req.columns,
        .search = std.mem.sliceTo(&req.search, 0),
        .criteria = req.filters,
        .sort_column = if (req.sort_col) |c| req.columns[c] else null,
        .sort_desc = req.sort_desc,
        .key = req.key,
        .marks = req.marks,
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
        .table_csv, .table_xlsx, .marked_csv, .marked_xlsx => {
            var spec = try tableSpec(db, req);
            spec.limit = 0; // todas as linhas
            // a tabela: a busca e os filtros da tela, sem olhar as marcas; as marcadas: todas, na ordem da tabela
            const marked = req.export_kind == .marked_csv or req.export_kind == .marked_xlsx;
            if (marked) spec.marked = .only else spec.marks = &.{};
            const built = try query.buildSelect(gpa, spec);
            defer built.deinit(gpa);
            const format: exporter.FileFormat = if (req.export_kind == .table_csv or req.export_kind == .marked_csv) .csv else .xlsx;
            return exporter.selection(db, env.io, format, .{ .sql = built.sql, .params = built.params, .sheet = spec.table }, dest, progress, req.total_hint);
        },
        .result_csv, .result_xlsx => {
            const format: exporter.FileFormat = if (req.export_kind == .result_csv) .csv else .xlsx;
            return exporter.selection(db, env.io, format, .{ .sql = std.mem.sliceTo(&req.sql, 0), .sheet = "Query" }, dest, progress, req.total_hint);
        },
        .terms_xlsx, .terms_csv, .terms_sqlite, .terms_duckdb => {
            // resumo, uma aba por tabela com acerto e os nao encontrados (a mesma lista nos 4 formatos)
            const res = req.terms_res orelse return error.TableNotFound;
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const items = try terms.reportItems(arena.allocator(), db.table_names, res, req.terms_titles);
            const format: exporter.BundleFormat = switch (req.export_kind) {
                .terms_xlsx => .xlsx,
                .terms_csv => .csv_dir,
                .terms_sqlite => .sqlite,
                else => .duckdb,
            };
            return exporter.bundle(db, env.io, format, items, dest, progress, req.total_hint);
        },
    }
}

// Schema + as primeiras `limit` linhas, sem ordenacao; com a busca pedida (vazia = nenhuma) e as linhas marcadas da
// tabela no topo
fn loadTable(db: *dbm.Db, index: usize, search: []const u8, limit: u32, marks: []const []const u8, out: *Out) dbm.Error!void {
    if (index >= db.table_names.len) return error.TableNotFound;
    out.table = index;
    out.schema = try db.schema(db.table_names[index]);
    const sch = &out.schema.?;
    const cols = try sch.arena.allocator().alloc([]const u8, sch.rows.len);
    for (cols, sch.rows) |*n, row| n.* = row[0] orelse "";
    out.columns = cols;
    out.key = try db.rowKey(db.table_names[index], cols);
    try loadRows(db, .{ .table = db.table_names[index], .tables = db.table_names, .columns = cols, .search = search, .limit = limit, .key = out.key, .with_key = true, .marks = marks }, false, out);
}

// !T: Rows of the Data tab: the count of the rows that match and the first spec.limit of them. With marked rows
// (item 31) they all come first, in table order, whatever the search, the filters or the sort; below them the
// search without them; the total counts both. only_marked: just the marked rows.
fn loadRows(db: *dbm.Db, spec: query.Spec, only_marked: bool, out: *Out) dbm.Error!void {
    if (spec.marks.len == 0 and !only_marked) {
        out.total = try db.count(spec);
        out.data = try db.page(spec);
        return;
    }
    var top_spec = spec;
    top_spec.marked = .only;
    top_spec.limit = 0;
    out.data = try db.page(top_spec);
    const top = &out.data.?;
    out.marked = top.rows.len;
    out.total = top.rows.len;
    if (only_marked) return;
    var rest_spec = spec;
    rest_spec.marked = .without;
    out.total += try db.count(rest_spec);
    var rest = try db.page(rest_spec);
    defer rest.deinit();
    try top.append(&rest);
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

    // reload: busca sem acento, ordenacao desc
    slot.req = .{ .kind = .reload, .table = people, .columns = columns, .sort_col = 0, .sort_desc = true };
    setZ(&slot.req.search, "ACAO");
    try slot.start();
    out = slot.wait().?;
    try t.expect(out.err == null);
    try t.expectEqual(2, out.total);
    try t.expectEqual(2, out.data.?.rows.len);
    try t.expectEqualStrings("3", out.data.?.rows[0][0].?);
    out.deinit(t.allocator);

    // filtro de valor exato somado a busca: so o id 3 ("acao")
    slot.req.filters = &.{.{ .column = "name", .op = .exact, .value = "acao" }};
    try slot.start();
    out = slot.wait().?;
    try t.expect(out.err == null);
    try t.expectEqual(1, out.total);
    try t.expectEqualStrings("3", out.data.?.rows[0][0].?);
    out.deinit(t.allocator);
    slot.req.filters = &.{};

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
    // resposta "Tabela inteira": o mesmo pedido sem a busca e sem filtros grava as 4 linhas
    slot.req.search = @splat(0);
    slot.req.filters = &.{};
    try slot.start();
    out = slot.wait().?;
    try t.expect(out.err == null);
    try t.expectEqual(4, out.exported);
    out.deinit(t.allocator);

    // busca em todas as tabelas; a tabela escolhida abre com a mesma busca e mostra a mesma contagem
    slot.req = .{ .kind = .search_all };
    setZ(&slot.req.search, "ACAO");
    try slot.start();
    out = slot.wait().?;
    try t.expect(out.err == null);
    try t.expectEqual(1, out.hits.len);
    try t.expectEqual(people, out.hits[0].table);
    try t.expectEqual(2, out.hits[0].rows); // "Ação" e "acao"
    out.deinit(t.allocator);
    slot.req = .{ .kind = .select, .table = people };
    setZ(&slot.req.search, "acao");
    try slot.start();
    out = slot.wait().?;
    try t.expect(out.err == null);
    try t.expectEqual(2, out.total);
    out.deinit(t.allocator);
    // colunas de numero tambem, como texto (a mesma regra da aba Data): 149 so em big.n; termo em branco nao busca
    var p: exporter.Progress = .{};
    const n149 = try searchAll(&db, t.allocator, "149", &p);
    defer t.allocator.free(n149);
    try t.expect(n149.len == 1 and n149[0].rows == 1 and std.mem.eql(u8, db.table_names[n149[0].table], "big"));
    const blank = try searchAll(&db, t.allocator, "  ", &p);
    defer t.allocator.free(blank);
    try t.expectEqual(0, blank.len);

    // select de outra tabela: as primeiras 100 linhas (padrao); a lista Linhas pede 500 ou 1000 (aqui o total, 250)
    const big = out_table(&db, "big");
    slot.req = .{ .kind = .select, .table = big };
    try slot.start();
    out = pollUntilDone(&slot);
    try t.expect(out.err == null);
    try t.expectEqual(250, out.total);
    try t.expectEqual(100, out.data.?.rows.len);
    var big_schema = out.schema.?;
    out.schema = null;
    defer big_schema.deinit();
    const big_cols = out.columns;
    out.deinit(t.allocator);
    for (query.row_limits) |limit| {
        slot.req = .{ .kind = .reload, .table = big, .columns = big_cols, .limit = limit };
        try slot.start();
        out = slot.wait().?;
        try t.expect(out.err == null);
        try t.expectEqual(250, out.total);
        try t.expectEqual(@min(limit, 250), out.data.?.rows.len);
        out.deinit(t.allocator);
    }
    try t.expectEqualSlices(u32, &.{ 100, 500, 1000 }, &query.row_limits);

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

    // a aba SQL so le: o comando que escreve e recusado antes de rodar
    setZ(&slot.req.sql, "CREATE TABLE memory.main.x AS SELECT 1 AS a");
    try slot.start();
    out = slot.wait().?;
    try t.expectEqual(error.SqlReadOnly, out.err.?);
    try t.expect(out.result == null);
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

test "search in every table: a SQLite file finds what the DuckDB file finds" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b1: [256]u8 = undefined;
    const duck = dbm.tmpPath(&b1, &tmp, "g.duckdb");
    try dbm.makeSample(duck);
    var b2: [256]u8 = undefined;
    const lite = dbm.tmpPath(&b2, &tmp, "g.sqlite");
    var db = dbm.testDb();
    defer db.close();
    try db.start();
    try db.openReadOnly(duck);
    var p: exporter.Progress = .{};
    try exporter.database(&db, t.io, .sqlite, lite, &p);
    for ([_][:0]const u8{ duck, lite }) |path| {
        try db.openReadOnly(path);
        const people = out_table(&db, "people");
        // caixa e acentos dos dois lados, palavras em qualquer ordem na mesma celula; numero tambem ("10.5" so em
        // people.score)
        for ([_]struct { []const u8, u64 }{ .{ "ACAO", 2 }, .{ "ação", 2 }, .{ "zé", 1 }, .{ "uno br", 1 }, .{ "bru zz", 0 }, .{ "10.5", 1 } }) |c| {
            const hits = try searchAll(&db, t.allocator, c[0], &p);
            defer t.allocator.free(hits);
            try t.expect(hits.len <= 1);
            if (hits.len == 1) try t.expectEqual(people, hits[0].table);
            try t.expectEqual(c[1], if (hits.len == 1) hits[0].rows else 0);
        }
    }
}

// O DB4 real passa de 10.000 colunas: o catalogo inteiro entra na busca, nao so as max_rows primeiras linhas
test "search in every table reads the whole column catalog, beyond max_rows columns" {
    var db = dbm.testDb();
    defer db.close();
    try db.start();
    // 100 tabelas de 100 colunas = 10.000 linhas do catalogo antes de "z"
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(t.allocator);
    for (0..100) |i| {
        sql.clearRetainingCapacity();
        try sql.print(t.allocator, "CREATE TABLE t{d:0>3} (", .{i});
        for (0..100) |col| try sql.print(t.allocator, "{s}c{d} INTEGER", .{ if (col > 0) ", " else "", col });
        try sql.appendSlice(t.allocator, ")\x00");
        try db.exec(sql.items[0 .. sql.items.len - 1 :0]);
    }
    try db.exec("CREATE TABLE z AS SELECT 'needle' AS note");
    try db.refreshTables();
    var p: exporter.Progress = .{};
    const hits = try searchAll(&db, t.allocator, "needle", &p);
    defer t.allocator.free(hits);
    try t.expectEqual(1, hits.len);
    try t.expectEqualStrings("z", db.table_names[hits[0].table]);
    // tabela que falha na contagem: a busca devolve o erro (a UI mostra), nunca um resultado pela metade
    try db.exec("CREATE VIEW zz AS SELECT CAST(error('broken view') AS VARCHAR) AS s");
    try db.refreshTables();
    try t.expectError(error.DuckDb, searchAll(&db, t.allocator, "needle", &p));
    try t.expect(std.mem.indexOf(u8, db.lastError(), "broken view") != null);
}

// Ids (1a coluna) das linhas de uma grade, "3,4|2"; `top`: quantas sao as marcadas (antes da barra)
fn idsOf(buf: []u8, g: dbm.Grid, top: usize) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (g.rows, 0..) |r, i| {
        if (i == top and top > 0) w.writeByte('|') catch {} else if (i > 0) w.writeByte(',') catch {};
        w.writeAll(r[0] orelse "-") catch {};
    }
    return w.buffered();
}

// O exemplo do dono: busca kkk, marca 1 de 3; busca jjj, a de kkk continua no topo; marca 1 de jjj; busca hhh,
// marca 1: as 3 marcadas no topo, na ordem da tabela
fn expectMarks(db: *dbm.Db, table: []const u8) !void {
    const index = out_table(db, table);
    var out: Out = .{ .kind = .select };
    try loadTable(db, index, "acao", 100, &.{}, &out);
    defer out.deinit(t.allocator);
    const key = out.key.?;
    const cols = out.columns;
    var marks: std.ArrayList([]const u8) = .empty;
    defer marks.deinit(t.allocator);
    var keep: std.heap.ArenaAllocator = .init(t.allocator);
    defer keep.deinit();
    // a grade traz a identidade de cada linha fora das colunas
    try t.expectEqual(cols.len, out.data.?.columns.len);
    try t.expectEqual(out.data.?.rows.len, out.data.?.keys.len);
    try marks.append(t.allocator, out.data.?.keys[1]); // id 3, "acao"
    var buf: [64]u8 = undefined;
    const steps = [_]struct { []const u8, ?usize, []const u8, u64 }{
        .{ "zé", 0, "3|4", 2 }, // a marcada continua no topo; embaixo a busca sem ela; marca o Zé
        .{ "bruno", 0, "3,4|2", 3 }, // as 2 marcadas na ordem da tabela, depois a busca
        .{ "", null, "2,3,4|1", 4 }, // a 3a marcada; sem busca, o resto (ordenado por id desc)
    };
    for (steps) |s| {
        var r: Out = .{ .kind = .reload };
        defer r.deinit(t.allocator);
        try loadRows(db, .{ .table = table, .tables = db.table_names, .columns = cols, .search = s[0], .sort_column = "id", .sort_desc = true, .key = key, .with_key = true, .marks = marks.items }, false, &r);
        try t.expectEqualStrings(s[2], idsOf(&buf, r.data.?, r.marked));
        try t.expectEqual(s[3], r.total);
        // a UI guarda a identidade copiada (a grade troca a cada busca)
        if (s[1]) |i| try marks.append(t.allocator, try keep.allocator().dupe(u8, r.data.?.keys[r.marked + i])) else break;
    }
    try t.expectEqual(3, marks.items.len);
    // so as marcadas
    var only: Out = .{ .kind = .reload };
    defer only.deinit(t.allocator);
    try loadRows(db, .{ .table = table, .tables = db.table_names, .columns = cols, .search = "acao", .key = key, .with_key = true, .marks = marks.items }, true, &only);
    try t.expectEqualStrings("2,3,4", idsOf(&buf, only.data.?, 0));
    try t.expectEqual(3, only.total);
}

test "marked rows (item 31): always on top in table order during other searches, only the marked, export; DuckDB, SQLite and a view" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b1: [256]u8 = undefined;
    const duck = dbm.tmpPath(&b1, &tmp, "m.duckdb");
    try dbm.makeSample(duck);
    var b2: [256]u8 = undefined;
    const lite = dbm.tmpPath(&b2, &tmp, "m.sqlite");
    var db = dbm.testDb();
    defer db.close();
    // view (sem rowid): a identidade e o texto da linha inteira
    try db.open(duck, false);
    try db.exec("CREATE VIEW pv AS SELECT * FROM people");
    try db.open(":memory:", false);
    try db.openReadOnly(duck);
    var p: exporter.Progress = .{};
    try exporter.database(&db, t.io, .sqlite, lite, &p);

    try expectMarks(&db, "people");
    try t.expectEqual(query.RowKey.rowid, try db.rowKey("people", &.{ "id", "name", "score" }));
    try t.expectEqual(query.RowKey.hash, try db.rowKey("pv", &.{ "id", "name", "score" }));
    try t.expectEqual(query.RowKey.hash, try db.rowKey("people", &.{ "id", "RowID" })); // coluna propria chamada rowid
    try expectMarks(&db, "pv");

    // exportar as marcadas: todas as colunas, na ordem da tabela, sem a identidade
    var sel: Out = .{ .kind = .select };
    defer sel.deinit(t.allocator);
    try loadTable(&db, out_table(&db, "people"), "", 100, &.{}, &sel);
    const keys = [_][]const u8{ sel.data.?.keys[3], sel.data.?.keys[0] };
    var b3: [256]u8 = undefined;
    const out_csv = dbm.tmpPath(&b3, &tmp, "people_marcadas.csv");
    var req: Req = .{ .kind = .export_, .export_kind = .marked_csv, .table = out_table(&db, "people"), .columns = sel.columns, .key = sel.key, .marks = &keys };
    setZ(&req.search, "nada"); // a busca da tela nao vale para as marcadas
    req.setDest(out_csv);
    try t.expectEqual(2, try exportJob(&db, t.allocator, .{ .io = t.io }, &req, &p));
    var cbuf: [256]u8 = undefined;
    try t.expectEqualStrings("\xEF\xBB\xBFid,name,score\r\n1,Ação,10.5\r\n4,Zé,20.0\r\n", try std.Io.Dir.cwd().readFile(t.io, out_csv, &cbuf));

    // o Access convertido e lido como SQLite: rowid do SQLite
    try db.openReadOnly(lite);
    try expectMarks(&db, "people");
    try t.expectEqual(query.RowKey.rowid, try db.rowKey("people", &.{ "id", "name", "score" }));
}

test "term search jobs (item 32): result with the first table's grid, another table's page, copy and report" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b1: [256]u8 = undefined;
    const path = dbm.tmpPath(&b1, &tmp, "tj.duckdb");
    try dbm.makeSample(path);
    var db = dbm.testDb();
    defer db.close();
    try db.openReadOnly(path);
    var slot: Slot = .{ .db = &db, .gpa = t.allocator, .env = .{ .io = t.io } };
    const titles: terms.Titles = .{ .term = "Termo", .status = "Situação", .table = "Tabela", .rows = "Linhas", .found = "Encontrado", .not_found = "Não encontrado", .sheet_summary = "Resumo", .sheet_not_found = "Não encontrados" };
    slot.req = .{ .kind = .terms, .terms_text = "nada\n149\nZé\nacao", .terms_titles = titles, .limit = 100 };
    try slot.start();
    var out = slot.wait().?;
    try t.expect(out.err == null);
    var res = out.terms.?; // a UI fica com o resultado
    out.terms = null;
    defer res.deinit();
    // 149 em big.n; Zé e acao em people (valor inteiro, sem diferenciar maiusculas; acento conta)
    try t.expectEqual(2, res.tables.len);
    try t.expectEqualStrings("nada", res.not_found);
    try t.expectEqualStrings("Termo", out.data.?.columns[0]);
    try t.expectEqualStrings("149", out.data.?.rows[0][0].?);
    out.deinit(t.allocator);

    slot.req = .{ .kind = .terms_page, .terms_res = &res, .terms_hit = 1, .terms_titles = titles, .limit = 1 };
    try slot.start();
    out = slot.wait().?;
    try t.expect(out.err == null and out.data.?.rows.len == 1);
    try t.expectEqualStrings("Zé", out.data.?.rows[0][0].?); // ordem dos termos colados
    out.deinit(t.allocator);

    slot.req.kind = .terms_copy;
    try slot.start();
    out = slot.wait().?;
    try t.expectEqualStrings("id\tname\tscore\r\n4\tZé\t20.0\r\n3\tacao\t3.0", out.copied.?);
    out.deinit(t.allocator);

    // relatorio em CSV: uma pasta, um arquivo por aba
    var b2: [256]u8 = undefined;
    slot.req = .{ .kind = .export_, .export_kind = .terms_csv, .terms_res = &res, .terms_titles = titles };
    slot.req.setDest(dbm.tmpPath(&b2, &tmp, ""));
    try slot.start();
    out = slot.wait().?;
    try t.expect(out.err == null);
    out.deinit(t.allocator);
    var b3: [300]u8 = undefined;
    var cbuf: [256]u8 = undefined;
    try t.expectEqualStrings("\xEF\xBB\xBFTermo\r\nnada\r\n", try std.Io.Dir.cwd().readFile(t.io, try exporter.csvPath(&b3, dbm.tmpPath(&b2, &tmp, ""), "Não encontrados"), &cbuf));
}

test "identical rows of a table without rowid are one row for the marks" {
    var db = dbm.testDb();
    defer db.close();
    try db.start();
    try db.exec("CREATE TABLE twins AS SELECT * FROM (VALUES (1, 'x'), (1, 'x'), (2, 'y')) v(id, s)");
    try db.exec("CREATE VIEW tv AS SELECT * FROM twins");
    try db.refreshTables();
    const cols = [_][]const u8{ "id", "s" };
    var g = try db.page(.{ .table = "tv", .tables = db.table_names, .columns = &cols, .key = .hash, .with_key = true });
    defer g.deinit();
    try t.expectEqualStrings(g.keys[0], g.keys[1]);
    const marks = [_][]const u8{g.keys[0]};
    try t.expectEqual(2, try db.count(.{ .table = "tv", .tables = db.table_names, .columns = &cols, .key = .hash, .marks = &marks, .marked = .only }));
    try t.expectEqual(1, try db.count(.{ .table = "tv", .tables = db.table_names, .columns = &cols, .key = .hash, .marks = &marks, .marked = .without }));
}

fn out_table(db: *dbm.Db, name: []const u8) usize {
    for (db.table_names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return 0;
}
