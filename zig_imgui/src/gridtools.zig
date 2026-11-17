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

// Letra base de U+00C0..U+00FF (UTF-8 C3 80..C3 BF); 0 = sem letra base (Æ Ð × Ø Þ ß æ ð ÷ ø þ)
const latin1_base = "aaaaaa\x00ceeeeiiii\x00nooooo\x00\x00uuuuy\x00\x00" ++ "aaaaaa\x00ceeeeiiii\x00nooooo\x00\x00uuuuy\x00y";
comptime {
    std.debug.assert(latin1_base.len == 64);
}

// !T: Search form: lower case without accents (ASCII + UTF-8 Latin-1 letters, no ICU); other bytes are kept.
// dst needs src.len bytes; the output is never longer than the input. Invalid UTF-8 is copied as is.
pub fn fold(dst: []u8, src: []const u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == 0xC3 and i + 1 < src.len and src[i + 1] >= 0x80 and src[i + 1] <= 0xBF) {
            i += 1;
            const lo = src[i];
            const base = latin1_base[lo - 0x80];
            if (base != 0) {
                dst[n] = base;
                n += 1;
                continue;
            }
            dst[n] = 0xC3;
            // Æ Ð Ø Þ (C3 86/90/98/9E) viram æ ð ø þ; × e ß ficam
            dst[n + 1] = if (lo <= 0x9E and lo != 0x97) lo + 0x20 else lo;
            n += 2;
            continue;
        }
        dst[n] = std.ascii.toLower(c);
        n += 1;
    }
    return dst[0..n];
}

// !T: One cell of the row holds every word of `words` (already folded), in any order; NULL never matches.
// No words = every row. `scratch` keeps the folded cell and is reused between calls.
pub fn rowMatches(gpa: Allocator, scratch: *std.ArrayList(u8), row: []const ?[]const u8, words: []const u8) Allocator.Error!bool {
    if (std.mem.indexOfNone(u8, words, &std.ascii.whitespace) == null) return true;
    for (row) |cell| {
        const s = cell orelse continue;
        scratch.clearRetainingCapacity();
        try scratch.ensureUnusedCapacity(gpa, s.len);
        scratch.items.len = fold(scratch.unusedCapacitySlice(), s).len;
        if (hasAll(scratch.items, words)) return true;
    }
    return false;
}

fn hasAll(text: []const u8, words: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, words, &std.ascii.whitespace);
    while (it.next()) |w| if (std.mem.indexOf(u8, text, w) == null) return false;
    return true;
}

// Indices das linhas que casam com a busca (todas as palavras, qualquer ordem, sem caixa nem acentos),
// na ordem original. O chamador libera com gpa.free.
pub fn filterRows(gpa: Allocator, rows: []const []?[]const u8, search: []const u8) Allocator.Error![]usize {
    const buf = try gpa.alloc(u8, search.len);
    defer gpa.free(buf);
    const words = fold(buf, search);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    for (rows, 0..) |row, i| {
        if (try rowMatches(gpa, &scratch, row, words)) try out.append(gpa, i);
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
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(t.allocator);
    try t.expect(try rowMatches(t.allocator, &scratch, &r1, "u05"));
    try t.expect(!try rowMatches(t.allocator, &scratch, &r0, "null"));
}

fn hits(rows: []const []?[]const u8, search: []const u8) ![]usize {
    return filterRows(t.allocator, rows, search);
}

test "search: every word in one cell, any order, no case or accents" {
    var r0 = [_]?[]const u8{ "1", "EXCITAÇÃO TENSÃO DE CAMPO", null };
    var r1 = [_]?[]const u8{ "2", "TENSÃO", "Campo U05" };
    var r2 = [_]?[]const u8{ "3", "Excitação", "TENSAO" };
    const rows = [_][]?[]const u8{ &r0, &r1, &r2 };
    const cases = [_]struct { []const u8, []const usize }{
        .{ "tensao de campo", &.{0} },
        .{ "campo tensao", &.{0} }, // r1 tem as duas palavras, mas em celulas diferentes: nao casa
        .{ "EXCITACAO", &.{ 0, 2 } },
        .{ "excitação tensão de campo", &.{0} }, // a frase exata continua casando
        .{ "tensao campo u06", &.{} }, // uma palavra que falta exclui a linha
        .{ "u05 CAMPO", &.{1} },
        .{ "  ", &.{ 0, 1, 2 } },
        .{ "", &.{ 0, 1, 2 } },
    };
    for (cases) |c| {
        const got = try hits(&rows, c[0]);
        defer t.allocator.free(got);
        try t.expectEqualSlices(usize, c[1], got);
    }
}

test "fold: Latin-1 letters lose case and accents, other bytes are kept" {
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("aaaaaa c eeee iiii n ooooo uuuu yy", fold(&buf, "ÀÁÂÃÄÅ Ç ÈÉÊË ÌÍÎÏ Ñ ÒÓÔÕÖ ÙÚÛÜ Ýÿ"));
    try t.expectEqualStrings("aaaaaa c eeee iiii n ooooo uuuu yy", fold(&buf, "àáâãäå ç èéêë ìíîï ñ òóôõö ùúûü ýÿ"));
    try t.expectEqualStrings("æðøþ ×ß €", fold(&buf, "ÆÐØÞ ×ß €"));
    // UTF-8 invalido ou cortado: copiado como esta, sem quebrar
    try t.expectEqualStrings("a\xC3", fold(&buf, "A\xC3"));
    try t.expectEqualStrings("\xC3a\xFF\x80", fold(&buf, "\xC3A\xFF\x80"));
    var r = [_]?[]const u8{ "TENS\xC3", "\xC3\xC3\xC3", "\xE2\x82" };
    const rows = [_][]?[]const u8{&r};
    for ([_][]const u8{ "s\xC3 TENS", "\xC3\xC3", "\xE2", "\xC3" }) |q| {
        const got = try hits(&rows, q);
        defer t.allocator.free(got);
        try t.expectEqualSlices(usize, &.{0}, got);
    }
}
