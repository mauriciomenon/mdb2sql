// Ferramentas das grades: copiar linha separada por TAB e filtrar as linhas carregadas
// !T: Grid tools: TAB-separated row copy (pastes into Excel) and a filter over the loaded rows

const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

// Mesmo formato que o Excel poe na area de transferencia: um valor com TAB, quebra de linha ou
// aspas vai entre aspas, com as aspas dobradas; assim ele volta inteiro para uma unica celula.
// NULL vira celula vazia.
pub fn writeTsvField(w: *Writer, cell: ?[]const u8) Writer.Error!void {
    const s = cell orelse return;
    if (std.mem.indexOfAny(u8, s, "\t\r\n\"") == null) return w.writeAll(s);
    try w.writeByte('"');
    for (s) |ch| {
        if (ch == '"') try w.writeByte('"');
        try w.writeByte(ch);
    }
    try w.writeByte('"');
}

// Uma linha da grade; com `header` a linha de nomes das colunas vem antes (separadas por CRLF)
pub fn writeRow(w: *Writer, columns: []const [:0]const u8, row: []const ?[]const u8, header: bool) Writer.Error!void {
    if (header) {
        for (columns, 0..) |name, i| {
            if (i > 0) try w.writeByte('\t');
            try writeTsvField(w, name);
        }
        try w.writeAll("\r\n");
    }
    for (row[0..columns.len], 0..) |cell, i| {
        if (i > 0) try w.writeByte('\t');
        try writeTsvField(w, cell);
    }
}

// Algum valor da linha contem o texto (sem diferenciar maiusculas ASCII); NULL nunca casa
pub fn rowMatches(row: []const ?[]const u8, needle: []const u8) bool {
    for (row) |cell| {
        if (std.ascii.findIgnoreCase(cell orelse continue, needle) != null) return true;
    }
    return false;
}

// Indices das linhas que casam, na ordem original. O chamador libera com gpa.free.
pub fn filterRows(gpa: Allocator, rows: []const []?[]const u8, needle: []const u8) Allocator.Error![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    for (rows, 0..) |row, i| {
        if (rowMatches(row, needle)) try out.append(gpa, i);
    }
    return out.toOwnedSlice(gpa);
}

// -------------------------------------------------------------------- tests

const t = std.testing;

fn field(buf: []u8, cell: ?[]const u8) ![]const u8 {
    var w: Writer = .fixed(buf);
    try writeTsvField(&w, cell);
    return w.buffered();
}

test "TSV field: TAB, line break and quote are escaped" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("plain, with comma", try field(&buf, "plain, with comma"));
    try t.expectEqualStrings("\"a\tb\"", try field(&buf, "a\tb"));
    try t.expectEqualStrings("\"line1\nline2\"", try field(&buf, "line1\nline2"));
    try t.expectEqualStrings("\"cr\r\nlf\"", try field(&buf, "cr\r\nlf"));
    try t.expectEqualStrings("\"say \"\"hi\"\"\"", try field(&buf, "say \"hi\""));
    try t.expectEqualStrings("", try field(&buf, ""));
    try t.expectEqualStrings("", try field(&buf, null));
}

test "row copy: TAB separated, optional header, NULL as empty cell" {
    const row = [_]?[]const u8{ "5.0", null, "REG\tVELOC", "Ação" };
    const cols = [_][:0]const u8{ "RTUNO", "CTLOPS", "odd\nname", "PNTNAM" };
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeRow(&w, &cols, &row, false);
    try t.expectEqualStrings("5.0\t\t\"REG\tVELOC\"\tAção", w.buffered());
    // uma linha sem valores especiais tem exatamente colunas-1 TABs
    try t.expectEqual(cols.len - 1, std.mem.count(u8, "5.0\t\t\tAção", "\t"));

    w = .fixed(&buf);
    try writeRow(&w, &cols, &row, true);
    try t.expectEqualStrings("RTUNO\tCTLOPS\t\"odd\nname\"\tPNTNAM\r\n5.0\t\t\"REG\tVELOC\"\tAção", w.buffered());
}

test "filter over the loaded rows looks at every column" {
    var r0 = [_]?[]const u8{ "1", "GENERADOR RELE 86E", null };
    var r1 = [_]?[]const u8{ "2", "AGUA_PURA BOMBA 1", "U05" };
    var r2 = [_]?[]const u8{ "3", null, "rele aux" };
    const rows = [_][]?[]const u8{ &r0, &r1, &r2 };
    const hit = try filterRows(t.allocator, &rows, "RELE");
    defer t.allocator.free(hit);
    try t.expectEqualSlices(usize, &.{ 0, 2 }, hit);
    const none = try filterRows(t.allocator, &rows, "nothing here");
    defer t.allocator.free(none);
    try t.expectEqual(0, none.len);
    try t.expect(rowMatches(&r1, "u05") and !rowMatches(&r0, "null"));
}
