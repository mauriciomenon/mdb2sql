// Logica pura (sem UI, sem DuckDB): validacao de caminho, montagem de SQL, limite de linhas
// !T: Pure logic: path validation, SQL building with bound parameters, row limits

const std = @import("std");
const Allocator = std.mem.Allocator;

// Linhas da aba Dados: lista 100 / 500 / 1000 (as 4 versoes); mais desenharia celulas demais (tabelas de 130 colunas)
pub const row_limits = [_]u32{ 100, 500, 1000 };
pub const default_limit: u32 = row_limits[0];

pub const PathError = error{UnsupportedExtension};

pub const SourceKind = enum { duckdb, sqlite, access };

// !T: Only database file extensions are opened: .duckdb/.db, .sqlite/.sqlite3, .mdb/.accdb
pub fn sourceKind(path: []const u8) PathError!SourceKind {
    const ext = std.fs.path.extension(path);
    const table = [_]struct { []const u8, SourceKind }{
        .{ ".duckdb", .duckdb },  .{ ".db", .duckdb },  .{ ".sqlite", .sqlite },
        .{ ".sqlite3", .sqlite }, .{ ".mdb", .access }, .{ ".accdb", .access },
    };
    for (table) |e| if (std.ascii.eqlIgnoreCase(ext, e[0])) return e[1];
    return error.UnsupportedExtension;
}

// !T: Whitelist check, the SQL injection guard every implementation uses
pub fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

// Escreve "nome" com aspas duplicadas
pub fn writeIdent(out: *std.ArrayList(u8), a: Allocator, name: []const u8) Allocator.Error!void {
    return writeQuoted(out, a, name, '"');
}

// Escreve 'texto' com apostrofos duplicados (caminhos em ATTACH, que nao aceita parametros)
pub fn writeLiteral(out: *std.ArrayList(u8), a: Allocator, text: []const u8) Allocator.Error!void {
    return writeQuoted(out, a, text, '\'');
}

fn writeQuoted(out: *std.ArrayList(u8), a: Allocator, s: []const u8, q: u8) Allocator.Error!void {
    try out.append(a, q);
    for (s) |ch| {
        if (ch == q) try out.append(a, q);
        try out.append(a, ch);
    }
    try out.append(a, q);
}

pub const Op = enum {
    contains,
    equals,
    not_equals,
    starts_with,
    greater,
    less,
    is_null,
    not_null,
    exact, // texto exibido igual ao valor, com caixa e acentos (filtro do clique direito); valor vazio vale

    pub const labels = [_][:0]const u8{ "contains", "equals", "not equals", "starts with", ">", "<", "is null", "is not null", "is exactly" };

    pub fn needsValue(op: Op) bool {
        return op != .is_null and op != .not_null;
    }
};

pub const Criterion = struct {
    column: []const u8,
    op: Op,
    value: []const u8 = "",
};

// !T: Row identity of the marked rows and of the term search: the engine's rowid when the table has one; a view, or
// a table with a column of its own called rowid, has none and uses the text of the whole row (identical rows are
// then one row: they are marked together).
pub const RowKey = enum { rowid, hash };

pub const row_alias = "mdb2sql_row"; // alias da tabela nas consultas que usam a identidade da linha

pub fn keyExpr(k: RowKey) []const u8 {
    return switch (k) {
        .rowid => row_alias ++ ".rowid",
        .hash => "md5(CAST(" ++ row_alias ++ " AS VARCHAR))",
    };
}

pub fn hasRowidColumn(columns: []const []const u8) bool {
    for (columns) |c| if (std.ascii.eqlIgnoreCase(c, "rowid")) return true;
    return false;
}

// Linhas marcadas na consulta: todas as linhas; so as nao marcadas (o resto da busca, embaixo das marcadas); so as
// marcadas (na ordem da tabela, qualquer que seja a busca, os filtros e a ordenacao)
pub const Marked = enum { any, without, only };

pub const Spec = struct {
    table: []const u8,
    tables: []const []const u8, // tabelas conhecidas (whitelist)
    columns: []const []const u8, // colunas conhecidas (whitelist + busca global)
    search: []const u8 = "", // busca global, sem diferenciar caixa/acentos
    criteria: []const Criterion = &.{},
    match_any: bool = false, // false = AND, true = OR
    sort_column: ?[]const u8 = null,
    sort_desc: bool = false,
    limit: u32 = default_limit,
    offset: u64 = 0,
    key: ?RowKey = null, // identidade de linha da tabela (precisa dela quem usa `marks` ou `with_key`)
    with_key: bool = false, // a identidade vem como 1a coluna do SELECT (a grade guarda uma por linha)
    marks: []const []const u8 = &.{}, // identidades das linhas marcadas
    marked: Marked = .any,
};

pub const BuildError = error{ TableNotFound, ColumnNotFound } || Allocator.Error;

pub const Built = struct {
    sql: [:0]u8,
    params: []const []const u8, // valores para os '?' na ordem

    pub fn deinit(self: Built, a: Allocator) void {
        a.free(self.sql);
        a.free(self.params);
    }
};

// !T: Case- and accent-insensitive text form of a column / of a parameter
fn writeNorm(out: *std.ArrayList(u8), a: Allocator, column: ?[]const u8) !void {
    try out.appendSlice(a, "strip_accents(lower(");
    if (column) |c| {
        try out.appendSlice(a, "CAST(");
        try writeIdent(out, a, c);
        try out.appendSlice(a, " AS VARCHAR)");
    } else try out.appendSlice(a, "CAST(? AS VARCHAR)");
    try out.appendSlice(a, "))");
}

fn writeCriterion(out: *std.ArrayList(u8), params: *std.ArrayList([]const u8), a: Allocator, c: Criterion) !void {
    switch (c.op) {
        .is_null, .not_null => {
            try writeIdent(out, a, c.column);
            try out.appendSlice(a, if (c.op == .is_null) " IS NULL" else " IS NOT NULL");
            return;
        },
        .greater, .less => {
            // Compara como numero quando os dois lados sao numericos, senao como texto
            const sym = if (c.op == .greater) ">" else "<";
            try out.appendSlice(a, "CASE WHEN TRY_CAST(? AS DOUBLE) IS NOT NULL THEN TRY_CAST(");
            try writeIdent(out, a, c.column);
            try out.print(a, " AS DOUBLE) {s} TRY_CAST(? AS DOUBLE) ELSE ", .{sym});
            try writeNorm(out, a, c.column);
            try out.print(a, " {s} ", .{sym});
            try writeNorm(out, a, null);
            try out.appendSlice(a, " END");
            try params.appendNTimes(a, c.value, 3);
            return;
        },
        .contains, .starts_with => {
            try out.appendSlice(a, if (c.op == .contains) "contains(" else "starts_with(");
            try writeNorm(out, a, c.column);
            try out.appendSlice(a, ", ");
            try writeNorm(out, a, null);
            try out.append(a, ')');
        },
        .equals, .not_equals => {
            try writeNorm(out, a, c.column);
            try out.appendSlice(a, if (c.op == .equals) " = " else " IS DISTINCT FROM ");
            try writeNorm(out, a, null);
        },
        .exact => {
            // o mesmo texto que a grade mostra (todo tipo chega como VARCHAR): vale para numero, data e texto
            try out.appendSlice(a, "CAST(");
            try writeIdent(out, a, c.column);
            try out.appendSlice(a, " AS VARCHAR) = ?");
        },
    }
    try params.append(a, c.value);
}

fn writeFromWhere(out: *std.ArrayList(u8), params: *std.ArrayList([]const u8), a: Allocator, spec: Spec) BuildError!void {
    if (!contains(spec.tables, spec.table)) return error.TableNotFound;
    try out.appendSlice(a, " FROM ");
    try writeIdent(out, a, spec.table);
    if (spec.key != null) try out.appendSlice(a, " AS " ++ row_alias);
    if (spec.marked == .only) return writeMarks(out, params, a, spec, " WHERE ", " IN ");

    var n_groups: usize = 0;

    // Busca global: uma coluna que contem todas as palavras, em qualquer ordem (mesma regra de gridtools.rowMatches)
    const ws = &std.ascii.whitespace;
    if (std.mem.indexOfNone(u8, spec.search, ws) != null and spec.columns.len > 0) {
        try out.appendSlice(a, " WHERE (");
        for (spec.columns, 0..) |col, i| {
            if (i > 0) try out.appendSlice(a, " OR ");
            try out.append(a, '(');
            var words = std.mem.tokenizeAny(u8, spec.search, ws);
            var first_word = true;
            while (words.next()) |w| {
                if (!first_word) try out.appendSlice(a, " AND ");
                first_word = false;
                try writeCriterion(out, params, a, .{ .column = col, .op = .contains, .value = w });
            }
            try out.append(a, ')');
        }
        try out.append(a, ')');
        n_groups += 1;
    }

    var first = true;
    for (spec.criteria) |c| {
        if (c.op.needsValue() and c.op != .exact and c.value.len == 0) continue; // criterio incompleto nao filtra
        if (!contains(spec.columns, c.column)) return error.ColumnNotFound;
        if (first) {
            try out.appendSlice(a, if (n_groups == 0) " WHERE (" else " AND (");
            first = false;
        } else try out.appendSlice(a, if (spec.match_any) " OR " else " AND ");
        try writeCriterion(out, params, a, c);
    }
    if (!first) try out.append(a, ')');
    if (spec.marked == .without and spec.marks.len > 0)
        try writeMarks(out, params, a, spec, if (n_groups == 0 and first) " WHERE " else " AND ", " NOT IN ");
}

// "<identidade> IN (?, ...)" com as linhas marcadas (ou NOT IN); sem marcas, nenhuma linha
fn writeMarks(out: *std.ArrayList(u8), params: *std.ArrayList([]const u8), a: Allocator, spec: Spec, lead: []const u8, op: []const u8) Allocator.Error!void {
    try out.appendSlice(a, lead);
    const key = spec.key orelse .rowid;
    if (spec.marks.len == 0 or spec.key == null) return out.appendSlice(a, "1 = 0");
    try out.appendSlice(a, keyExpr(key));
    try out.appendSlice(a, op);
    for (spec.marks, 0..) |m, i| {
        try out.appendSlice(a, if (i == 0) "(" else ", ");
        try out.appendSlice(a, if (key == .rowid) "CAST(? AS BIGINT)" else "?");
        try params.append(a, m);
    }
    try out.append(a, ')');
}

fn finish(out: *std.ArrayList(u8), params: *std.ArrayList([]const u8), a: Allocator) Allocator.Error!Built {
    const sql = try out.toOwnedSliceSentinel(a, 0);
    errdefer a.free(sql);
    return .{ .sql = sql, .params = try params.toOwnedSlice(a) };
}

// SELECT * com filtro, ordenacao e pagina
pub fn buildSelect(a: Allocator, spec: Spec) BuildError!Built {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var params: std.ArrayList([]const u8) = .empty;
    errdefer params.deinit(a);

    try out.appendSlice(a, "SELECT ");
    if (spec.with_key) try out.print(a, "{s} AS mdb2sql_key, ", .{keyExpr(spec.key orelse .rowid)});
    try out.append(a, '*');
    try writeFromWhere(&out, &params, a, spec);
    if (spec.marked == .only) {
        if (spec.key == .rowid) try out.appendSlice(a, " ORDER BY " ++ row_alias ++ ".rowid");
    } else if (spec.sort_column) |col| {
        if (!contains(spec.columns, col)) return error.ColumnNotFound;
        try out.appendSlice(a, " ORDER BY ");
        try writeIdent(&out, a, col);
        try out.appendSlice(a, if (spec.sort_desc) " DESC NULLS LAST" else " ASC NULLS LAST");
        // empates na ordem da tabela: as paginas nao repetem nem pulam linhas (a ordenacao do motor nao e estavel)
        if (spec.key == .rowid) try out.appendSlice(a, ", " ++ row_alias ++ ".rowid");
    }
    // limit 0 = todas as linhas (exportacao da tabela inteira)
    if (spec.limit > 0) try out.print(a, " LIMIT {d} OFFSET {d}", .{ spec.limit, spec.offset });
    return finish(&out, &params, a);
}

// COUNT(*) com o mesmo filtro (total para a paginacao)
pub fn buildCount(a: Allocator, spec: Spec) BuildError!Built {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var params: std.ArrayList([]const u8) = .empty;
    errdefer params.deinit(a);

    try out.appendSlice(a, "SELECT COUNT(*)");
    try writeFromWhere(&out, &params, a, spec);
    return finish(&out, &params, a);
}

// !T: DESCRIBE gives name, type and YES/NO null as text (same 3 fields as python_pyqt6 get_table_schema)
pub fn buildSchema(a: Allocator, tables: []const []const u8, table: []const u8) BuildError![:0]u8 {
    if (!contains(tables, table)) return error.TableNotFound;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "DESCRIBE ");
    try writeIdent(&out, a, table);
    return out.toOwnedSliceSentinel(a, 0);
}

// !T: SQL of the Schema tab export: column, type and nullable with the titles of the screen and Yes/No in the screen
// language (DuckDB's DESCRIBE says YES/NO), the same table the tab shows
pub fn buildSchemaExport(a: Allocator, table: []const u8, titles: [3][]const u8, yes: []const u8, no: []const u8) Allocator.Error![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "SELECT column_name AS ");
    try writeIdent(&out, a, titles[0]);
    try out.appendSlice(a, ", column_type AS ");
    try writeIdent(&out, a, titles[1]);
    try out.appendSlice(a, ", CASE \"null\" WHEN 'YES' THEN ");
    try writeLiteral(&out, a, yes);
    try out.appendSlice(a, " ELSE ");
    try writeLiteral(&out, a, no);
    try out.appendSlice(a, " END AS ");
    try writeIdent(&out, a, titles[2]);
    try out.appendSlice(a, " FROM (DESCRIBE ");
    try writeIdent(&out, a, table);
    try out.append(a, ')');
    return out.toOwnedSliceSentinel(a, 0);
}

// !T: SQL of the database schema export: one row per column of every table of the open file (table, column, type,
// nullable), with the titles and the Yes/No of the screen language, in the order of the table list
pub fn buildDbSchemaExport(a: Allocator, titles: [4][]const u8, yes: []const u8, no: []const u8) Allocator.Error![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "SELECT table_name AS ");
    try writeIdent(&out, a, titles[0]);
    try out.appendSlice(a, ", column_name AS ");
    try writeIdent(&out, a, titles[1]);
    try out.appendSlice(a, ", data_type AS ");
    try writeIdent(&out, a, titles[2]);
    try out.appendSlice(a, ", CASE WHEN is_nullable THEN ");
    try writeLiteral(&out, a, yes);
    try out.appendSlice(a, " ELSE ");
    try writeLiteral(&out, a, no);
    try out.appendSlice(a, " END AS ");
    try writeIdent(&out, a, titles[3]);
    try out.appendSlice(a, " FROM duckdb_columns() WHERE database_name = current_database() AND schema_name = current_schema() " ++
        "ORDER BY table_name, column_index");
    return out.toOwnedSliceSentinel(a, 0);
}

// -------------------------------------------------------------------- tests

const t = std.testing;

test "extension decides the source kind" {
    try t.expectEqual(.duckdb, try sourceKind("C:\\data\\sample.duckdb"));
    try t.expectEqual(.duckdb, try sourceKind("/tmp/x.DB"));
    try t.expectEqual(.sqlite, try sourceKind("a.SQLite3"));
    try t.expectEqual(.sqlite, try sourceKind("a b.sqlite"));
    try t.expectEqual(.access, try sourceKind("2026-07-14 DB4.accdb"));
    try t.expectEqual(.access, try sourceKind("old.MDB"));
    try t.expectError(error.UnsupportedExtension, sourceKind("invalid.txt"));
    try t.expectError(error.UnsupportedExtension, sourceKind("noext"));
}

const t_tables = [_][]const u8{ "RANGER_SOACCU", "odd\"name" };
const t_cols = [_][]const u8{ "ID", "NAME" };

test "plain page select" {
    const b = try buildSelect(t.allocator, .{ .table = "RANGER_SOACCU", .tables = &t_tables, .columns = &t_cols });
    defer b.deinit(t.allocator);
    try t.expectEqualStrings("SELECT * FROM \"RANGER_SOACCU\" LIMIT 100 OFFSET 0", b.sql);
    try t.expectEqual(0, b.params.len);
    const all = try buildSelect(t.allocator, .{ .table = "RANGER_SOACCU", .tables = &t_tables, .columns = &t_cols, .limit = 0 });
    defer all.deinit(t.allocator);
    try t.expectEqualStrings("SELECT * FROM \"RANGER_SOACCU\"", all.sql);
    var lit: std.ArrayList(u8) = .empty;
    defer lit.deinit(t.allocator);
    try writeLiteral(&lit, t.allocator, "C:\\a'b.duckdb");
    try t.expectEqualStrings("'C:\\a''b.duckdb'", lit.items);
}

test "unknown table and column are rejected, identifiers are quoted" {
    try t.expectError(error.TableNotFound, buildSelect(t.allocator, .{ .table = "x\"; DROP TABLE y; --", .tables = &t_tables, .columns = &t_cols }));
    try t.expectError(error.TableNotFound, buildSchema(t.allocator, &t_tables, "nope"));
    try t.expectError(error.ColumnNotFound, buildSelect(t.allocator, .{ .table = "RANGER_SOACCU", .tables = &t_tables, .columns = &t_cols, .sort_column = "EVIL" }));
    try t.expectError(error.ColumnNotFound, buildCount(t.allocator, .{
        .table = "RANGER_SOACCU",
        .tables = &t_tables,
        .columns = &t_cols,
        .criteria = &.{.{ .column = "EVIL", .op = .equals, .value = "1" }},
    }));
    const s = try buildSchema(t.allocator, &t_tables, "odd\"name");
    defer t.allocator.free(s);
    try t.expectEqualStrings("DESCRIBE \"odd\"\"name\"", s);
}

test "search, criteria, sort and paging" {
    const b = try buildSelect(t.allocator, .{
        .table = "RANGER_SOACCU",
        .tables = &t_tables,
        .columns = &t_cols,
        .search = "acao",
        .criteria = &.{
            .{ .column = "ID", .op = .greater, .value = "10" },
            .{ .column = "NAME", .op = .is_null },
            .{ .column = "NAME", .op = .equals, .value = "" }, // incompleto: ignorado
        },
        .match_any = true,
        .sort_column = "NAME",
        .sort_desc = true,
        .limit = 50,
        .offset = 150,
    });
    defer b.deinit(t.allocator);
    const n = "strip_accents(lower(CAST(\"NAME\" AS VARCHAR)))";
    const i = "strip_accents(lower(CAST(\"ID\" AS VARCHAR)))";
    const p = "strip_accents(lower(CAST(? AS VARCHAR)))";
    try t.expectEqualStrings("SELECT * FROM \"RANGER_SOACCU\" WHERE ((contains(" ++ i ++ ", " ++ p ++ ")) OR (contains(" ++ n ++ ", " ++ p ++ ")))" ++
        " AND (CASE WHEN TRY_CAST(? AS DOUBLE) IS NOT NULL THEN TRY_CAST(\"ID\" AS DOUBLE) > TRY_CAST(? AS DOUBLE) ELSE " ++ i ++ " > " ++ p ++ " END" ++
        " OR \"NAME\" IS NULL) ORDER BY \"NAME\" DESC NULLS LAST LIMIT 50 OFFSET 150", b.sql);
    try t.expectEqual(5, b.params.len);
    try t.expectEqualStrings("acao", b.params[1]);
    try t.expectEqualStrings("10", b.params[4]);
    // o numero de '?' sempre bate com o numero de parametros
    try t.expectEqual(b.params.len, std.mem.count(u8, b.sql, "?"));
}

test "search words: all of them in the same column, any order; blank search filters nothing" {
    const b = try buildCount(t.allocator, .{ .table = "RANGER_SOACCU", .tables = &t_tables, .columns = &t_cols, .search = " campo\ttensao " });
    defer b.deinit(t.allocator);
    const n = "strip_accents(lower(CAST(\"NAME\" AS VARCHAR)))";
    const i = "strip_accents(lower(CAST(\"ID\" AS VARCHAR)))";
    const p = "strip_accents(lower(CAST(? AS VARCHAR)))";
    try t.expectEqualStrings("SELECT COUNT(*) FROM \"RANGER_SOACCU\" WHERE ((contains(" ++ i ++ ", " ++ p ++ ") AND contains(" ++ i ++ ", " ++ p ++ "))" ++
        " OR (contains(" ++ n ++ ", " ++ p ++ ") AND contains(" ++ n ++ ", " ++ p ++ ")))", b.sql);
    try t.expectEqualSlices(u8, "campo", b.params[0]);
    try t.expectEqualSlices(u8, "tensao", b.params[3]);
    try t.expectEqual(4, b.params.len);
    const blank = try buildCount(t.allocator, .{ .table = "RANGER_SOACCU", .tables = &t_tables, .columns = &t_cols, .search = "  " });
    defer blank.deinit(t.allocator);
    try t.expectEqualStrings("SELECT COUNT(*) FROM \"RANGER_SOACCU\"", blank.sql);
}

test "marked rows: only them in table order, or the rest of the search without them; the identity as first column" {
    const marks = [_][]const u8{ "7", "42" };
    const rid = "mdb2sql_row.rowid";
    const in = "(CAST(? AS BIGINT), CAST(? AS BIGINT))";
    // so as marcadas: a busca, os filtros e a ordenacao da tela nao valem; ordem da tabela
    const top = try buildSelect(t.allocator, .{ .table = "RANGER_SOACCU", .tables = &t_tables, .columns = &t_cols, .search = "x", .sort_column = "NAME", .limit = 0, .key = .rowid, .with_key = true, .marks = &marks, .marked = .only });
    defer top.deinit(t.allocator);
    try t.expectEqualStrings("SELECT " ++ rid ++ " AS mdb2sql_key, * FROM \"RANGER_SOACCU\" AS mdb2sql_row WHERE " ++ rid ++ " IN " ++ in ++ " ORDER BY " ++ rid, top.sql);
    try t.expectEqualStrings("42", top.params[1]);
    // o resto da busca, sem repetir as marcadas (tabela sem rowid: o texto da linha inteira)
    const rest = try buildCount(t.allocator, .{ .table = "RANGER_SOACCU", .tables = &t_tables, .columns = &t_cols, .search = "x", .key = .hash, .marks = &marks, .marked = .without });
    defer rest.deinit(t.allocator);
    try t.expect(std.mem.endsWith(u8, rest.sql, ")) AND md5(CAST(mdb2sql_row AS VARCHAR)) NOT IN (?, ?)"));
    try t.expectEqual(4, rest.params.len);
    try t.expectEqual(rest.params.len, std.mem.count(u8, rest.sql, "?"));
    const plain = try buildCount(t.allocator, .{ .table = "RANGER_SOACCU", .tables = &t_tables, .columns = &t_cols, .key = .rowid, .marks = &marks, .marked = .without });
    defer plain.deinit(t.allocator);
    try t.expectEqualStrings("SELECT COUNT(*) FROM \"RANGER_SOACCU\" AS mdb2sql_row WHERE " ++ rid ++ " NOT IN " ++ in, plain.sql);
    // nenhuma marcada: "so as marcadas" nao traz linha nenhuma, e a busca fica como era
    const none = try buildCount(t.allocator, .{ .table = "RANGER_SOACCU", .tables = &t_tables, .columns = &t_cols, .key = .rowid, .marked = .only });
    defer none.deinit(t.allocator);
    try t.expectEqualStrings("SELECT COUNT(*) FROM \"RANGER_SOACCU\" AS mdb2sql_row WHERE 1 = 0", none.sql);
    const same = try buildSelect(t.allocator, .{ .table = "RANGER_SOACCU", .tables = &t_tables, .columns = &t_cols, .key = .rowid, .marked = .without });
    defer same.deinit(t.allocator);
    try t.expectEqualStrings("SELECT * FROM \"RANGER_SOACCU\" AS mdb2sql_row LIMIT 100 OFFSET 0", same.sql);
    try t.expect(hasRowidColumn(&.{ "ID", "RowId" }) and !hasRowidColumn(&t_cols));
}

test "count shares the filter and has no paging" {
    const b = try buildCount(t.allocator, .{
        .table = "RANGER_SOACCU",
        .tables = &t_tables,
        .columns = &t_cols,
        .criteria = &.{ .{ .column = "NAME", .op = .starts_with, .value = "ab" }, .{ .column = "ID", .op = .not_equals, .value = "3" } },
    });
    defer b.deinit(t.allocator);
    try t.expect(std.mem.startsWith(u8, b.sql, "SELECT COUNT(*) FROM \"RANGER_SOACCU\" WHERE (starts_with("));
    try t.expect(std.mem.indexOf(u8, b.sql, ") AND strip_accents(") != null);
    try t.expect(std.mem.indexOf(u8, b.sql, "LIMIT") == null);
    try t.expectEqual(2, b.params.len);
}

test "exact value filter: quoted identifier, bound value, NULL, empty text, AND with the search" {
    const cols = [_][]const u8{ "si\"gla", "ID" };
    const evil = "U9A' OR '1'='1\" --";
    const b = try buildCount(t.allocator, .{
        .table = "odd\"name",
        .tables = &t_tables,
        .columns = &cols,
        .search = "x",
        .criteria = &.{
            .{ .column = "si\"gla", .op = .exact, .value = evil },
            .{ .column = "ID", .op = .is_null },
            .{ .column = "ID", .op = .exact, .value = "" }, // texto vazio e um valor, nao um criterio incompleto
        },
    });
    defer b.deinit(t.allocator);
    try t.expect(std.mem.endsWith(u8, b.sql, " AND (CAST(\"si\"\"gla\" AS VARCHAR) = ? AND \"ID\" IS NULL AND CAST(\"ID\" AS VARCHAR) = ?)"));
    try t.expect(std.mem.startsWith(u8, b.sql, "SELECT COUNT(*) FROM \"odd\"\"name\" WHERE (("));
    // o valor nunca entra no SQL: so como parametro, byte a byte
    try t.expect(std.mem.indexOf(u8, b.sql, "U9A") == null);
    try t.expectEqual(4, b.params.len); // 2 da busca + 2 dos filtros
    try t.expectEqualStrings(evil, b.params[2]);
    try t.expectEqualStrings("", b.params[3]);
    try t.expectEqual(b.params.len, std.mem.count(u8, b.sql, "?"));
    try t.expectError(error.ColumnNotFound, buildSelect(t.allocator, .{
        .table = "RANGER_SOACCU",
        .tables = &t_tables,
        .columns = &t_cols,
        .criteria = &.{.{ .column = "NAME\" = 1 OR \"x", .op = .exact, .value = "1" }},
    }));
}
