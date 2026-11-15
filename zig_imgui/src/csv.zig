// Exportacao CSV (RFC 4180) de um resultado ja materializado como texto
// !T: CSV writer for a Grid: comma separated, CRLF lines, quotes doubled

const std = @import("std");
const Writer = std.Io.Writer;

// Campo entre aspas quando tem , " CR ou LF. NULL vira campo vazio e texto vazio vira "",
// a mesma distincao que o read_csv do DuckDB faz na volta.
pub fn writeField(w: *Writer, cell: ?[]const u8) Writer.Error!void {
    const s = cell orelse return;
    if (s.len > 0 and std.mem.indexOfAny(u8, s, ",\"\r\n") == null) return w.writeAll(s);
    try w.writeByte('"');
    for (s) |ch| {
        if (ch == '"') try w.writeByte('"');
        try w.writeByte(ch);
    }
    try w.writeByte('"');
}

pub fn write(w: *Writer, columns: []const [:0]const u8, rows: []const []?[]const u8) Writer.Error!void {
    try w.writeAll("\xEF\xBB\xBF"); // BOM: sem ele o Excel le UTF-8 como ANSI e estraga os acentos
    for (columns, 0..) |name, i| {
        if (i > 0) try w.writeByte(',');
        try writeField(w, name);
    }
    try w.writeAll("\r\n");
    for (rows) |row| {
        for (row[0..columns.len], 0..) |cell, i| {
            if (i > 0) try w.writeByte(',');
            try writeField(w, cell);
        }
        try w.writeAll("\r\n");
    }
}

// Grava o CSV em `path`, substituindo o arquivo se ele ja existir
pub fn writeFile(io: std.Io, path: []const u8, columns: []const [:0]const u8, rows: []const []?[]const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var w = file.writer(io, &buf);
    try write(&w.interface, columns, rows);
    try w.interface.flush();
}

// -------------------------------------------------------------------- tests

const t = std.testing;

fn field(buf: []u8, cell: ?[]const u8) ![]const u8 {
    var w: Writer = .fixed(buf);
    try writeField(&w, cell);
    return w.buffered();
}

test "field quoting" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("plain text", try field(&buf, "plain text"));
    try t.expectEqualStrings("Ação;1", try field(&buf, "Ação;1"));
    try t.expectEqualStrings("\"a,b\"", try field(&buf, "a,b"));
    try t.expectEqualStrings("\"say \"\"hi\"\"\"", try field(&buf, "say \"hi\""));
    try t.expectEqualStrings("\"line1\r\nline2\"", try field(&buf, "line1\r\nline2"));
    try t.expectEqualStrings("\"\"", try field(&buf, ""));
    try t.expectEqualStrings("", try field(&buf, null));
}

test "whole grid: BOM, header, CRLF, NULL" {
    var r1 = [_]?[]const u8{ "1", "a,b" };
    var r2 = [_]?[]const u8{ null, "x" };
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try write(&w, &.{ "id", "odd \"name\"" }, &.{ &r1, &r2 });
    try t.expectEqualStrings("\xEF\xBB\xBFid,\"odd \"\"name\"\"\"\r\n1,\"a,b\"\r\n,x\r\n", w.buffered());
}

test "file round trip: DuckDB reads back what was exported" {
    const dbm = @import("db.zig");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [512]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(t.io, &dir_buf)]; // absoluto, como o do dialogo de salvar
    var path_buf: [600]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}\\out.csv", .{dir});

    var r1 = [_]?[]const u8{ "1", "Ação, \"quoted\"", "" };
    var r2 = [_]?[]const u8{ "2", "two\nlines", null };
    try writeFile(t.io, path, &.{ "id", "some text", "note" }, &.{ &r1, &r2 });

    var db = dbm.Db.init(t.allocator);
    defer db.close();
    try db.open(":memory:", false);
    var sql_buf: [800]u8 = undefined;
    const sql = try std.fmt.bufPrintSentinel(&sql_buf, "SELECT * FROM read_csv('{s}', all_varchar = true, allow_quoted_nulls = false)", .{path}, 0);
    var g = try db.run(sql, &.{});
    defer g.deinit();
    try t.expectEqualStrings("id", g.columns[0]); // o BOM nao entra no nome da primeira coluna
    try t.expectEqualStrings("some text", g.columns[1]);
    try t.expectEqual(2, g.rows.len);
    try t.expectEqualStrings("Ação, \"quoted\"", g.rows[0][1].?);
    try t.expectEqualStrings("", g.rows[0][2].?);
    try t.expectEqualStrings("two\nlines", g.rows[1][1].?);
    try t.expect(g.rows[1][2] == null);
}
