// Pesquisa de termos (aba Termos): uma lista colada, um termo por linha, procurada em todas as colunas das tabelas
// do escopo. Generica: vale para qualquer banco e qualquer tabela.
// !T: Term search. The pasted list goes into a temporary table of the engine (temp.main.mdb2sql_terms) and each
// table of the scope is matched against it by a join, never row by row in the UI: every column as text (CAST AS
// VARCHAR), equal to the term without the spaces at the ends (whole value) or holding it (contains), ignoring case.
// A row found by two terms counts and shows twice, once per term, in the order of the pasted list.

const std = @import("std");
const dbm = @import("db.zig");
const query = dbm.query;
const exporter = @import("exporter.zig");
const gridtools = @import("gridtools.zig");
const Progress = exporter.Progress;
const Allocator = std.mem.Allocator;
const Db = dbm.Db;

pub const Match = @import("settings.zig").TermMatch; // whole | contains

const terms_table = "temp.main.mdb2sql_terms"; // ord, term, k (o termo em minusculas)
const pairs_table = "temp.main.mdb2sql_pairs"; // ord, tbl_index, tbl, n: linhas de cada termo em cada tabela
const row = query.row_alias;

// Termos da caixa: cada linha nao vazia, sem espacos nas pontas; o repetido vale uma vez (a primeira)
pub const List = struct {
    terms: []const []const u8, // fatias do texto, na ordem colada
    repeated: usize, // linhas que repetem um termo anterior
};

pub fn parse(a: Allocator, text: []const u8) Allocator.Error!List {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    var terms: std.ArrayList([]const u8) = .empty;
    errdefer terms.deinit(a);
    var repeated: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const term = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (term.len == 0) continue;
        const slot = try seen.getOrPut(a, term);
        if (slot.found_existing) repeated += 1 else try terms.append(a, term);
    }
    return .{ .terms = try terms.toOwnedSlice(a), .repeated = repeated };
}

pub const Pair = struct { term: usize, table: usize, rows: u64 };

// Tabela com acerto: indice em db.table_names, linhas achadas (uma por termo x linha), identidade de linha usada e
// as colunas (do arena do resultado)
pub const Table = struct { table: usize, rows: u64, key: query.RowKey, columns: []const []const u8 };

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    match: Match = .whole,
    terms: []const []const u8 = &.{}, // sem os repetidos, na ordem colada
    repeated: usize = 0,
    pairs: []const Pair = &.{}, // na ordem das tabelas; dentro da tabela, na ordem dos termos
    tables: []const Table = &.{}, // na ordem da lista de tabelas
    found: usize = 0, // termos com pelo menos uma linha
    rows: u64 = 0,
    not_found: [:0]const u8 = "", // os termos sem acerto, um por linha, na ordem colada (a caixa copiavel da tela)

    pub fn deinit(r: *Result) void {
        r.arena.deinit();
    }
};

// Pesquisa os termos de `text` em todas as tabelas (only = null) ou so na tabela `only`. Cancelar: error.Canceled
// (ou o erro do DuckDB interrompido); nada pela metade e devolvido.
pub fn search(db: *Db, gpa: Allocator, text: []const u8, match: Match, only: ?usize, progress: *Progress) !Result {
    var res: Result = .{ .arena = .init(gpa), .match = match };
    errdefer res.deinit();
    const a = res.arena.allocator();
    const list = try parse(a, try a.dupe(u8, text));
    res.terms = list.terms;
    res.repeated = list.repeated;
    const names = db.table_names;
    const first: usize = @min(only orelse 0, names.len);
    const last: usize = if (only != null) @min(first + 1, names.len) else names.len;
    progress.begin(last - first);

    try storeTerms(db, gpa, res.terms);
    var cols = try db.runMax(columns_sql, &.{}, std.math.maxInt(usize));
    defer cols.deinit();
    var pairs: std.ArrayList(Pair) = .empty;
    var tables: std.ArrayList(Table) = .empty;
    var parts: std.ArrayList(Part) = .empty;
    defer parts.deinit(gpa);
    const found = try a.alloc(bool, res.terms.len);
    @memset(found, false);
    var i = first;
    while (i < last) {
        try progress.check();
        const end = @min(i + batch, last);
        parts.clearRetainingCapacity();
        for (i..end) |ti| {
            const columns = try tableColumns(db, a, &cols, names[ti]);
            if (columns.len == 0 or res.terms.len == 0) continue;
            try parts.append(gpa, .{ .table = ti, .columns = columns, .key = if (query.hasRowidColumn(columns)) .hash else .rowid });
        }
        if (parts.items.len > 0) {
            // as tabelas do lote numa consulta so; se ela falhar (view sem rowid), uma por uma
            if (batchCounts(db, gpa, names, parts.items, match)) |grid| {
                var g = grid;
                defer g.deinit();
                for (g.rows) |r| {
                    const p = std.fmt.parseInt(usize, r[0] orelse continue, 10) catch continue;
                    if (p < parts.items.len) try addCount(a, &pairs, found, &parts.items[p], r[1], r[2]);
                }
            } else |e| {
                if (e != error.DuckDb or progress.cancel.load(.monotonic)) return e;
                for (parts.items) |*part| {
                    var g = try tableCounts(db, gpa, names[part.table], part.columns, match, &part.key, progress);
                    defer g.deinit();
                    for (g.rows) |r| try addCount(a, &pairs, found, part, r[0], r[1]);
                }
            }
            for (parts.items) |part| if (part.rows > 0) {
                try tables.append(a, .{ .table = part.table, .rows = part.rows, .key = part.key, .columns = part.columns });
                res.rows += part.rows;
            };
        }
        progress.add(end - i);
        i = end;
    }
    try storePairs(db, gpa, pairs.items, names);
    res.pairs = pairs.items;
    res.tables = tables.items;

    var missing: std.ArrayList(u8) = .empty;
    for (res.terms, found) |term, hit| {
        if (hit) {
            res.found += 1;
            continue;
        }
        if (missing.items.len > 0) try missing.append(a, '\n');
        try missing.appendSlice(a, term);
    }
    res.not_found = try missing.toOwnedSliceSentinel(a, 0);
    return res;
}

const columns_sql = "SELECT table_name, column_name FROM duckdb_columns() WHERE database_name = current_database() " ++
    "AND schema_name = current_schema() ORDER BY table_name, column_index";

// Tabelas por consulta (UNION ALL), como a busca em todas as tabelas: uma consulta por tabela custava mais que a
// leitura dela (DB3 pelo leitor do SQLite: 287 consultas so de COUNT(*) levaram 8 s)
const batch = 32;

// Tabela de um lote: colunas (da arena do resultado), identidade de linha e as linhas achadas
const Part = struct { table: usize, columns: []const []const u8, key: query.RowKey, rows: u64 = 0 };

// Colunas da tabela, copiadas para `a`: as do catalogo; view: o catalogo so as tem depois de usada, o DESCRIBE da aba
// Esquema sempre tem
fn tableColumns(db: *Db, a: Allocator, cols: *const dbm.Grid, table: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (cols.rows) |r| if (std.mem.eql(u8, r[0] orelse "", table)) try list.append(a, try a.dupe(u8, r[1] orelse ""));
    if (list.items.len == 0) {
        var g = try db.schema(table);
        defer g.deinit();
        for (g.rows) |r| try list.append(a, try a.dupe(u8, r[0] orelse ""));
    }
    return list.items;
}

// Uma linha (termo, n) da contagem: o par entra no resultado e o termo conta como achado
fn addCount(a: Allocator, pairs: *std.ArrayList(Pair), found: []bool, part: *Part, ord_text: ?[]const u8, n_text: ?[]const u8) Allocator.Error!void {
    const ord = std.fmt.parseInt(usize, ord_text orelse return, 10) catch return;
    const n = std.fmt.parseInt(u64, n_text orelse "0", 10) catch 0;
    if (ord >= found.len or n == 0) return;
    try pairs.append(a, .{ .term = ord, .table = part.table, .rows = n });
    found[ord] = true;
    part.rows += n;
}

// Linhas por termo de varias tabelas numa consulta: (parte, ord, n), na ordem das tabelas e dos termos
fn batchCounts(db: *Db, gpa: Allocator, names: []const []const u8, parts: []const Part, match: Match) !dbm.Grid {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(gpa);
    for (parts, 0..) |part, p| {
        if (p > 0) try sql.appendSlice(gpa, " UNION ALL ");
        try sql.print(gpa, "SELECT {d} AS p, m.ord, COUNT(*) AS n FROM ", .{p});
        try writeMatches(&sql, gpa, names[part.table], part.columns, match, query.keyExpr(part.key), false);
        try sql.appendSlice(gpa, " m GROUP BY m.ord");
    }
    try sql.appendSlice(gpa, " ORDER BY 1, 2");
    try sql.append(gpa, 0);
    return db.runMax(sql.items[0 .. sql.items.len - 1 :0], &.{}, std.math.maxInt(usize));
}

// Linhas por termo de uma tabela: (ord, n). A identidade de linha e o rowid do motor; a tabela sem rowid (view, ou
// com uma coluna chamada rowid) usa o texto da linha inteira.
fn tableCounts(db: *Db, gpa: Allocator, table: []const u8, columns: []const []const u8, match: Match, key: *query.RowKey, progress: *Progress) !dbm.Grid {
    key.* = if (query.hasRowidColumn(columns)) .hash else .rowid;
    while (true) {
        var sql: std.ArrayList(u8) = .empty;
        defer sql.deinit(gpa);
        // os pares (linha, termo) sem repetir ja contam: a tabela e lida uma vez
        try sql.appendSlice(gpa, "SELECT m.ord, COUNT(*) FROM ");
        try writeMatches(&sql, gpa, table, columns, match, query.keyExpr(key.*), false);
        try sql.appendSlice(gpa, " m GROUP BY m.ord ORDER BY m.ord");
        try sql.append(gpa, 0);
        return db.runMax(sql.items[0 .. sql.items.len - 1 :0], &.{}, std.math.maxInt(usize)) catch |e| {
            if (key.* == .hash or e != error.DuckDb or progress.cancel.load(.monotonic)) return e;
            key.* = .hash;
            continue;
        };
    }
}

// !T: The (row, term) pairs of a table, each once: the cells of every row become a list (unnest) matched against the
// terms table in a join; DISTINCT ON: a term in two columns of the same row counts once. With `whole_row` the row
// itself goes along as the struct mdb2sql_r, so the grid, the copy and the report come from this one scan: joining
// the table again by rowid gave no rows at random on SQLite files (DB3/DB5 through the sqlite extension).
fn writeMatches(out: *std.ArrayList(u8), a: Allocator, table: []const u8, columns: []const []const u8, match: Match, key_sql: []const u8, whole_row: bool) Allocator.Error!void {
    try out.print(a, "(SELECT DISTINCT ON (c.k, t.ord) c.k, t.ord, t.term{s} FROM (SELECT {s} AS k, {s}unnest([", .{
        if (whole_row) ", c.mdb2sql_r" else "", key_sql, if (whole_row) row ++ " AS mdb2sql_r, " else "",
    });
    for (columns, 0..) |col, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, if (match == .whole) "lower(trim(CAST(" ++ row ++ "." else "lower(CAST(" ++ row ++ ".");
        try query.writeIdent(out, a, col);
        try out.appendSlice(a, if (match == .whole) " AS VARCHAR)))" else " AS VARCHAR))");
    }
    try out.appendSlice(a, "]) AS v FROM ");
    try query.writeIdent(out, a, table);
    try out.print(a, " AS " ++ row ++ ") c JOIN " ++ terms_table ++ " t ON {s})", .{if (match == .whole) "c.v = t.k" else "contains(c.v, t.k)"});
}

// Nome de coluna do banco: sem diferenciar maiusculas, como o DuckDB compara
fn hasColumn(columns: []const []const u8, name: []const u8) bool {
    for (columns) |c| if (std.ascii.eqlIgnoreCase(c, name)) return true;
    return false;
}

// As linhas achadas de uma tabela, na ordem dos termos e depois na da tabela. `title`: titulo da 1a coluna (o termo
// que achou a linha); null = so as colunas da tabela. limit 0 = todas.
pub fn buildRows(a: Allocator, table: []const u8, hit: Table, match: Match, title: ?[]const u8, limit: u32) Allocator.Error![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "SELECT ");
    if (title) |name| {
        // tabela com uma coluna de mesmo nome (Termo, Term, Termino): a do termo vira "Termo (2)"; duas colunas com
        // o mesmo nome quebravam o relatorio em SQLite e DuckDB (CREATE TABLE ... AS)
        var free = name;
        var n: usize = 2;
        var nb: [600]u8 = undefined;
        while (hasColumn(hit.columns, free)) : (n += 1) free = std.fmt.bufPrint(&nb, "{s} ({d})", .{ name, n }) catch break;
        try out.appendSlice(a, "m.term AS ");
        try query.writeIdent(&out, a, free);
        try out.appendSlice(a, ", ");
    }
    // as colunas da tabela, na ordem dela (o struct da linha aberto)
    try out.appendSlice(a, "mdb2sql_r.* FROM ");
    try writeMatches(&out, a, table, hit.columns, match, query.keyExpr(hit.key), true);
    try out.appendSlice(a, if (hit.key == .rowid) " m ORDER BY m.ord, m.k" else " m ORDER BY m.ord");
    if (limit > 0) try out.print(a, " LIMIT {d}", .{limit});
    return out.toOwnedSliceSentinel(a, 0);
}

// As primeiras `limit` linhas achadas da tabela, com a coluna do termo na frente
pub fn page(db: *Db, gpa: Allocator, res: *const Result, hit: Table, title: []const u8, limit: u32) !dbm.Grid {
    const sql = try buildRows(gpa, db.table_names[hit.table], hit, res.match, title, limit);
    defer gpa.free(sql);
    return db.runMax(sql, &.{}, std.math.maxInt(usize));
}

// !T: "Copy the rows found in this table": every row found, with the header, TAB separated, without the term column
// and with no line in between (pasting into Excel gives exactly the rows found). The caller frees the text.
pub fn copyText(db: *Db, gpa: Allocator, res: *const Result, hit: Table, progress: *Progress) ![]u8 {
    const sql = try buildRows(gpa, db.table_names[hit.table], hit, res.match, null, 0);
    defer gpa.free(sql);
    var rows = try db.stream(sql, &.{}, .{});
    defer rows.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    for (0..rows.n_cols) |i| {
        if (i > 0) try w.writeByte('\t');
        try gridtools.writeTsvField(w, rows.name(i));
    }
    var buf: [64]u8 = undefined;
    while (try rows.next()) {
        try progress.check();
        for (0..rows.size) |r| {
            try w.writeAll("\r\n");
            for (0..rows.n_cols) |col| {
                if (col > 0) try w.writeByte('\t');
                try gridtools.writeTsvField(w, rows.cell(col, r, &buf));
            }
        }
    }
    return out.toOwnedSlice();
}

// Titulos do relatorio no idioma da tela
pub const Titles = struct {
    term: []const u8,
    status: []const u8,
    table: []const u8,
    rows: []const u8,
    found: []const u8,
    not_found: []const u8,
    sheet_summary: []const u8,
    sheet_not_found: []const u8,
};

// !T: Report of the term search, as a list of (name, query) for exporter.bundle: the summary (one row per term and
// table; a term not found has an empty table and 0 rows), one item per table with rows found (term + the table's
// columns) and the terms not found. Everything is allocated in `a` (an arena).
pub fn reportItems(a: Allocator, names: []const []const u8, res: *const Result, titles: Titles) Allocator.Error![]exporter.Select {
    const items = try a.alloc(exporter.Select, res.tables.len + 2);
    var sql: std.ArrayList(u8) = .empty;
    try sql.appendSlice(a, "SELECT t.term AS ");
    try query.writeIdent(&sql, a, titles.term);
    try sql.appendSlice(a, ", CASE WHEN p.ord IS NULL THEN ");
    try query.writeLiteral(&sql, a, titles.not_found);
    try sql.appendSlice(a, " ELSE ");
    try query.writeLiteral(&sql, a, titles.found);
    try sql.appendSlice(a, " END AS ");
    try query.writeIdent(&sql, a, titles.status);
    try sql.appendSlice(a, ", COALESCE(p.tbl, '') AS ");
    try query.writeIdent(&sql, a, titles.table);
    try sql.appendSlice(a, ", COALESCE(p.n, 0) AS ");
    try query.writeIdent(&sql, a, titles.rows);
    try sql.appendSlice(a, " FROM " ++ terms_table ++ " t LEFT JOIN " ++ pairs_table ++ " p ON p.ord = t.ord ORDER BY t.ord, p.tbl_index");
    items[0] = .{ .sql = try sql.toOwnedSliceSentinel(a, 0), .sheet = try freeName(a, titles.sheet_summary, names, res) };
    for (res.tables, items[1 .. items.len - 1]) |hit, *item|
        item.* = .{ .sql = try buildRows(a, names[hit.table], hit, res.match, titles.term, 0), .sheet = names[hit.table] };
    try sql.appendSlice(a, "SELECT t.term AS ");
    try query.writeIdent(&sql, a, titles.term);
    try sql.appendSlice(a, " FROM " ++ terms_table ++ " t WHERE t.ord NOT IN (SELECT ord FROM " ++ pairs_table ++ ") ORDER BY t.ord");
    items[items.len - 1] = .{ .sql = try sql.toOwnedSliceSentinel(a, 0), .sheet = try freeName(a, titles.sheet_not_found, names, res) };
    return items;
}

// "Resumo"; se uma tabela com acerto ja tem esse nome, "Resumo (2)"...
fn freeName(a: Allocator, want: []const u8, names: []const []const u8, res: *const Result) Allocator.Error![]const u8 {
    var name = want;
    var n: usize = 2;
    while (true) : (n += 1) {
        for (res.tables) |hit| {
            if (std.ascii.eqlIgnoreCase(names[hit.table], name)) break;
        } else return name;
        name = try std.fmt.allocPrint(a, "{s} ({d})", .{ want, n });
    }
}

// As tabelas temporarias da pesquisa saem com o arquivo: o SHOW TABLES do proximo arquivo as listaria
pub fn dropTables(db: *Db) void {
    db.exec("DROP TABLE IF EXISTS " ++ terms_table) catch {};
    db.exec("DROP TABLE IF EXISTS " ++ pairs_table) catch {};
}

fn exec(db: *Db, gpa: Allocator, sql: *std.ArrayList(u8)) !void {
    try sql.append(gpa, 0);
    defer sql.clearRetainingCapacity();
    try db.exec(sql.items[0 .. sql.items.len - 1 :0]);
}

// A lista de termos vira uma tabela temporaria do motor (em lotes: o SQL nao cresce sem limite)
fn storeTerms(db: *Db, gpa: Allocator, terms: []const []const u8) !void {
    try db.exec("CREATE OR REPLACE TEMP TABLE mdb2sql_terms (ord INTEGER, term VARCHAR, k VARCHAR)");
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(gpa);
    var first: usize = 0;
    while (first < terms.len) : (first += 500) {
        try sql.appendSlice(gpa, "INSERT INTO " ++ terms_table ++ " SELECT ord, term, lower(term) FROM (VALUES ");
        for (terms[first..@min(first + 500, terms.len)], first..) |term, ord| {
            try sql.print(gpa, "{s}({d}, ", .{ if (ord > first) ", " else "", ord });
            try query.writeLiteral(&sql, gpa, term);
            try sql.append(gpa, ')');
        }
        try sql.appendSlice(gpa, ") v(ord, term)");
        try exec(db, gpa, &sql);
    }
}

fn storePairs(db: *Db, gpa: Allocator, pairs: []const Pair, names: []const []const u8) !void {
    try db.exec("CREATE OR REPLACE TEMP TABLE mdb2sql_pairs (ord INTEGER, tbl_index INTEGER, tbl VARCHAR, n BIGINT)");
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(gpa);
    var first: usize = 0;
    while (first < pairs.len) : (first += 500) {
        try sql.appendSlice(gpa, "INSERT INTO " ++ pairs_table ++ " VALUES ");
        for (pairs[first..@min(first + 500, pairs.len)], first..) |p, i| {
            try sql.print(gpa, "{s}({d}, {d}, ", .{ if (i > first) ", " else "", p.term, p.table });
            try query.writeLiteral(&sql, gpa, names[p.table]);
            try sql.print(gpa, ", {d})", .{p.rows});
        }
        try exec(db, gpa, &sql);
    }
}

// -------------------------------------------------------------------- tests

const t = std.testing;

test "terms of the box: one per non-empty line, trimmed, a repeated one counts once, in the pasted order" {
    const list = try parse(t.allocator, "PNTNAM\r\n  Bomba 1 \r\n\r\n\tbomba 1\nBomba 1\n   \nZ\tY\nPNTNAM");
    defer t.allocator.free(list.terms);
    try t.expectEqual(4, list.terms.len);
    try t.expectEqualStrings("PNTNAM", list.terms[0]);
    try t.expectEqualStrings("Bomba 1", list.terms[1]);
    try t.expectEqualStrings("bomba 1", list.terms[2]); // so o texto igual e repetido
    try t.expectEqualStrings("Z\tY", list.terms[3]);
    try t.expectEqual(2, list.repeated);
    const none = try parse(t.allocator, " \r\n\n");
    defer t.allocator.free(none.terms);
    try t.expect(none.terms.len == 0 and none.repeated == 0);
}

const sample_ddl = [_][:0]const u8{
    // nome com espacos nas pontas e em outra caixa; numero e data como texto; NULL; texto que so contem o termo
    "CREATE TABLE points AS SELECT * FROM (VALUES (1, 'BOMBA 1', 'U9A', DATE '2026-07-14'), (2, '  bomba 1  ', 'U9A', NULL), " ++
        "(3, 'BOMBA 10', NULL, NULL), (4, 'Válvula', 'u02', NULL), (5, 'U9A', 'U9A', NULL), (6, NULL, '238', NULL)) v(id, name, sub, d)",
    "CREATE TABLE other AS SELECT * FROM (VALUES (238, 'x'), (7, 'bomba 1')) v(n, note)",
    "CREATE TABLE empty_one (a VARCHAR)",
    "CREATE VIEW seen AS SELECT name, name AS again FROM points WHERE id IN (1, 2, 2)",
};

fn expectSample(db: *Db) !void {
    var p: Progress = .{};
    const text = "PNTNAM\nbomba 1\nU9A\n238\nVALVULA\nbomba 1\n2026-07-14\n";
    var res = try search(db, t.allocator, text, .whole, null, &p);
    defer res.deinit();
    // repetido uma vez; acento conta (VALVULA nao e Válvula); a 1a linha colada (cabecalho) cai em nao encontrados
    try t.expectEqual(6, res.terms.len);
    try t.expectEqual(1, res.repeated);
    try t.expectEqual(4, res.found);
    try t.expectEqualStrings("PNTNAM\nVALVULA", res.not_found);
    try t.expectEqual(db.table_names.len, p.done.load(.monotonic));
    // tabelas na ordem da lista: other, points, seen (a view; a tabela vazia nao aparece)
    try t.expectEqual(3, res.tables.len);
    const names = db.table_names;
    try t.expectEqualStrings("other", names[res.tables[0].table]);
    try t.expectEqualStrings("points", names[res.tables[1].table]);
    try t.expectEqualStrings("seen", names[res.tables[2].table]);
    try t.expectEqual(2, res.tables[0].rows); // 238 (numero como texto) e bomba 1
    // points: bomba 1 = 2 linhas (caixa e espacos nas pontas nao contam; "BOMBA 10" nao e o valor inteiro);
    // U9A = 3 linhas (a linha 5 tem o termo em duas colunas: conta uma vez); 238 = 1; a data = 1
    try t.expectEqual(7, res.tables[1].rows);
    try t.expectEqual(2, res.tables[2].rows); // a view: as duas linhas com bomba 1 (em duas colunas cada)
    try t.expectEqual(11, res.rows);
    try t.expectEqual(query.RowKey.rowid, res.tables[1].key);
    try t.expectEqual(query.RowKey.hash, res.tables[2].key); // view nao tem rowid

    // grade: a coluna do termo na frente, na ordem dos termos e depois na da tabela
    var g = try page(db, t.allocator, &res, res.tables[1], "Termo", 100);
    defer g.deinit();
    try t.expectEqualStrings("Termo", g.columns[0]);
    try t.expectEqualStrings("id", g.columns[1]);
    try t.expectEqual(7, g.rows.len);
    const want = [_]struct { []const u8, []const u8 }{ .{ "bomba 1", "1" }, .{ "bomba 1", "2" }, .{ "U9A", "1" }, .{ "U9A", "2" }, .{ "U9A", "5" }, .{ "238", "6" }, .{ "2026-07-14", "1" } };
    for (g.rows, want) |r, w| {
        try t.expectEqualStrings(w[0], r[0].?);
        try t.expectEqualStrings(w[1], r[1].?);
    }
    try t.expectEqualStrings("  bomba 1  ", g.rows[1][2].?); // a celula como esta no banco
    var cut = try page(db, t.allocator, &res, res.tables[1], "Termo", 3); // limite de linhas da grade
    defer cut.deinit();
    try t.expectEqual(3, cut.rows.len);

    // copiar as linhas achadas: cabecalho + linhas, TAB, sem a coluna do termo, sem linha no meio nem no fim
    const copied = try copyText(db, t.allocator, &res, res.tables[0], &p);
    defer t.allocator.free(copied);
    try t.expectEqualStrings("n\tnote\r\n7\tbomba 1\r\n238\tx", copied);

    // contem: BOMBA 10 entra; "a" acha muito; termo de outra caixa acha igual
    var c = try search(db, t.allocator, "BOMBA 1\nxyz", .contains, null, &p);
    defer c.deinit();
    try t.expectEqualStrings("xyz", c.not_found);
    try t.expectEqual(1 + 3 + 2, c.rows); // other 1, points 3 (linhas 1, 2, 3), seen 2
    // so uma tabela
    const points = res.tables[1].table;
    var one = try search(db, t.allocator, "bomba 1\n238", .whole, points, &p);
    defer one.deinit();
    try t.expect(one.tables.len == 1 and one.tables[0].table == points and one.rows == 3);
    try t.expectEqual(1, p.done.load(.monotonic));
    // nada colado: nada achado, sem erro
    var blank = try search(db, t.allocator, "\n \n", .whole, null, &p);
    defer blank.deinit();
    try t.expect(blank.terms.len == 0 and blank.tables.len == 0 and blank.not_found.len == 0);
}

test "term search on DuckDB and on SQLite: whole value, contains, case, spaces, repeated, order, not found" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    const duck = dbm.tmpPath(&b1, &tmp, "terms.duckdb");
    const lite = dbm.tmpPath(&b2, &tmp, "terms.sqlite");
    var db = dbm.testDb();
    defer db.close();
    try db.open(duck, false);
    for (sample_ddl) |sql| try db.exec(sql);
    try db.open(":memory:", false);
    try db.loadSqlite();
    var sb: [400]u8 = undefined;
    try db.exec(try std.fmt.bufPrintSentinel(&sb, "ATTACH '{s}' AS w (TYPE sqlite)", .{lite}, 0));
    try db.exec("USE w");
    for (sample_ddl) |sql| try db.exec(sql);
    try db.exec("USE memory");
    try db.exec("DETACH w");

    try db.openReadOnly(duck);
    try expectSample(&db);
    try db.openReadOnly(lite); // o Access convertido e lido assim
    // as tabelas temporarias da pesquisa anterior nao entram na lista do arquivo novo
    try t.expect(!query.contains(db.table_names, "mdb2sql_terms") and !query.contains(db.table_names, "mdb2sql_pairs"));
    try expectSample(&db);
}

// Banco real (opcional): MDB2SQL_TEST_TERMS_DB aponta para uma COPIA (.sqlite, .duckdb) e MDB2SQL_TEST_TERMS para a
// lista; a grade de cada tabela com acerto traz as linhas que a contagem achou
test "term search on a real database: every table's grid has the rows counted (optional)" {
    const path = t.environ.getAlloc(t.allocator, "MDB2SQL_TEST_TERMS_DB") catch return error.SkipZigTest;
    defer t.allocator.free(path);
    const list = try t.environ.getAlloc(t.allocator, "MDB2SQL_TEST_TERMS");
    defer t.allocator.free(list);
    var buf: [64 * 1024]u8 = undefined;
    const text = try std.Io.Dir.cwd().readFile(t.io, list, &buf);
    var db = dbm.testDb();
    defer db.close();
    try db.openReadOnly(path);
    // tempo: a pesquisa inteira, a contagem uma consulta por tabela (rowid ou row_number()) e so ler cada tabela
    {
        var p: Progress = .{};
        const t0 = std.Io.Timestamp.now(t.io, .awake);
        var res = try search(&db, t.allocator, text, .whole, null, &p);
        res.deinit();
        std.debug.print("search: {d} ms\n", .{t0.durationTo(std.Io.Timestamp.now(t.io, .awake)).toMilliseconds()});
        var cols = try db.runMax(columns_sql, &.{}, std.math.maxInt(usize));
        defer cols.deinit();
        for ([_][]const u8{ "rowid", "number", "scan" }) |variant| {
            const t1 = std.Io.Timestamp.now(t.io, .awake);
            var of: std.ArrayList([]const u8) = .empty;
            defer of.deinit(t.allocator);
            for (db.table_names) |name| {
                of.clearRetainingCapacity();
                for (cols.rows) |r| if (std.mem.eql(u8, r[0] orelse "", name)) try of.append(t.allocator, r[1] orelse "");
                if (of.items.len == 0) continue;
                var sql: std.ArrayList(u8) = .empty;
                defer sql.deinit(t.allocator);
                if (std.mem.eql(u8, variant, "scan")) {
                    try sql.appendSlice(t.allocator, "SELECT COUNT(*) FROM ");
                    try query.writeIdent(&sql, t.allocator, name);
                } else {
                    try sql.appendSlice(t.allocator, "SELECT m.ord, COUNT(*) FROM ");
                    try writeMatches(&sql, t.allocator, name, of.items, .whole, if (std.mem.eql(u8, variant, "rowid")) query.keyExpr(.rowid) else "row_number() OVER ()", false);
                    try sql.appendSlice(t.allocator, " m GROUP BY m.ord");
                }
                try sql.append(t.allocator, 0);
                var g = db.runMax(sql.items[0 .. sql.items.len - 1 :0], &.{}, std.math.maxInt(usize)) catch |e| {
                    std.debug.print("{s} {s}: {t} {s}\n", .{ variant, name, e, db.lastError() });
                    break;
                };
                g.deinit();
            }
            std.debug.print("{s}: {d} ms\n", .{ variant, t1.durationTo(std.Io.Timestamp.now(t.io, .awake)).toMilliseconds() });
        }
    }
    // varias vezes: com o leitor do SQLite em paralelo, a grade ja veio vazia numa rodada e cheia na outra
    for (0..2) |_| for ([_]Match{ .whole, .contains }) |match| {
        var p: Progress = .{};
        var res = try search(&db, t.allocator, text, match, null, &p);
        defer res.deinit();
        for (res.tables) |hit| for ([_]u32{ 100, 0 }) |limit| {
            // a grade da tela (Linhas 100) e a de copiar e exportar (todas)
            var g = try page(&db, t.allocator, &res, hit, "Termo", limit);
            defer g.deinit();
            std.debug.print("{t} {s} limit {d}: {d} counted, {d} in the grid\n", .{ match, db.table_names[hit.table], limit, hit.rows, g.rows.len });
            try t.expectEqual(@min(hit.rows, if (limit == 0) hit.rows else limit), g.rows.len);
        };
    };
}

test "a table column named like the term column (Termo) breaks neither the grid, the copy nor the report" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    const duck = dbm.tmpPath(&b1, &tmp, "tc.duckdb");
    const out = dbm.tmpPath(&b2, &tmp, "tc_termos.duckdb");
    var db = dbm.testDb();
    defer db.close();
    try db.open(duck, false);
    try db.exec("CREATE TABLE tt AS SELECT * FROM (VALUES ('bomba 1', 'a'), ('x', 'bomba 1')) v(\"TERMO\", \"Termo (2)\")");
    try db.open(":memory:", false);
    try db.openReadOnly(duck);
    var p: Progress = .{};
    var res = try search(&db, t.allocator, "bomba 1", .whole, null, &p);
    defer res.deinit();
    try t.expectEqual(1, res.tables.len);
    // a coluna do termo ganha um nome livre; as da tabela ficam como sao
    var g = try page(&db, t.allocator, &res, res.tables[0], "Termo", 100);
    defer g.deinit();
    try t.expectEqualStrings("Termo (3)", g.columns[0]);
    try t.expectEqualStrings("TERMO", g.columns[1]);
    try t.expectEqual(2, g.rows.len);
    const copied = try copyText(&db, t.allocator, &res, res.tables[0], &p);
    defer t.allocator.free(copied);
    try t.expectEqualStrings("TERMO\tTermo (2)\r\nbomba 1\ta\r\nx\tbomba 1", copied);
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const items = try reportItems(arena.allocator(), db.table_names, &res, .{ .term = "Termo", .status = "Situação", .table = "Tabela", .rows = "Linhas", .found = "Encontrado", .not_found = "Não encontrado", .sheet_summary = "Resumo", .sheet_not_found = "Não encontrados" });
    try t.expectEqual(3, try exporter.bundle(&db, t.io, .duckdb, items, out, &p, 0));
}

test "term search report: summary, one table per table with rows, not found; into a new DuckDB file" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    const duck = dbm.tmpPath(&b1, &tmp, "r.duckdb");
    const out = dbm.tmpPath(&b2, &tmp, "r_termos.duckdb");
    var db = dbm.testDb();
    defer db.close();
    try db.open(duck, false);
    for (sample_ddl) |sql| try db.exec(sql);
    try db.exec("CREATE TABLE \"Resumo\" AS SELECT 'bomba 1' AS x"); // nome igual ao da aba do resumo
    try db.open(":memory:", false);
    try db.openReadOnly(duck);
    var p: Progress = .{};
    var res = try search(&db, t.allocator, "nada\nbomba 1\n238", .whole, null, &p);
    defer res.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const items = try reportItems(arena.allocator(), db.table_names, &res, .{ .term = "Termo", .status = "Situação", .table = "Tabela", .rows = "Linhas", .found = "Encontrado", .not_found = "Não encontrado", .sheet_summary = "Resumo", .sheet_not_found = "Não encontrados" });
    // resumo, as 4 tabelas com acerto (Resumo, other, points, seen) e os nao encontrados
    try t.expectEqual(6, items.len);
    try t.expectEqualStrings("Resumo (2)", items[0].sheet);
    try t.expectEqual(6, try exporter.bundle(&db, t.io, .duckdb, items, out, &p, 0));
    var check = dbm.testDb();
    defer check.close();
    try check.openReadOnly(out);
    var g = try check.run("SELECT \"Termo\", \"Situação\", \"Tabela\", \"Linhas\" FROM \"Resumo (2)\"", &.{});
    defer g.deinit();
    // um por termo x tabela, na ordem dos termos; o nao encontrado com a tabela vazia e 0
    try t.expectEqual(1 + 4 + 2, g.rows.len);
    try t.expectEqualStrings("nada", g.rows[0][0].?);
    try t.expectEqualStrings("Não encontrado", g.rows[0][1].?);
    try t.expectEqualStrings("", g.rows[0][2].?);
    try t.expectEqualStrings("0", g.rows[0][3].?);
    try t.expectEqualStrings("bomba 1", g.rows[1][0].?);
    try t.expectEqualStrings("Encontrado", g.rows[1][1].?);
    try t.expectEqualStrings("238", g.rows[6][0].?);
    var two = try check.run("SELECT \"Linhas\" FROM \"Resumo (2)\" WHERE \"Termo\" = 'bomba 1' AND \"Tabela\" = 'points'", &.{});
    defer two.deinit();
    try t.expectEqualStrings("2", two.rows[0][0].?);
    var nf = try check.run("SELECT * FROM \"Não encontrados\"", &.{});
    defer nf.deinit();
    try t.expect(nf.rows.len == 1 and std.mem.eql(u8, nf.rows[0][0].?, "nada"));
    var pts = try check.run("SELECT \"Termo\", id FROM points", &.{});
    defer pts.deinit();
    try t.expectEqual(3, pts.rows.len);
    try t.expectEqualStrings("238", pts.rows[2][0].?);
}
