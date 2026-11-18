// Ferramentas das grades: copiar linha separada por TAB e filtrar as linhas carregadas
// !T: Grid tools: TAB-separated row copy (pastes into Excel) and a filter over the loaded rows

const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const query = @import("query.zig");

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

// Soma um filtro do clique direito (coluna = valor exato; valor null = IS NULL) a lista. O valor (do gpa)
// passa a ser da lista; se o filtro ja existe ou falta memoria, e liberado aqui.
pub fn addFilter(gpa: Allocator, list: *std.ArrayList(query.Criterion), column: []const u8, value: ?[]u8) void {
    const v: []const u8 = value orelse "";
    const op: query.Op = if (value == null) .is_null else .exact;
    for (list.items) |old| {
        if (old.op == op and std.mem.eql(u8, old.column, column) and std.mem.eql(u8, old.value, v)) break;
    } else if (list.append(gpa, .{ .column = column, .op = op, .value = v })) |_| return else |_| {}
    gpa.free(v);
}

// Corta em ate `max` bytes sem partir um caractere UTF-8
fn cutUtf8(s: []const u8, max: usize) []const u8 {
    var end = @min(s.len, max);
    while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

// Rotulo do botao de um filtro ativo: "SIGLA = 'U9A'  x" / "SIGLA IS NULL  x"; valor longo e cortado (so na
// tela). "###f" fixa o ID do botao do ImGui.
// shortcut: a value holding "##" shows cut at that point (ImGui label rule), escape it if that ever matters
pub fn filterLabel(buf: []u8, f: query.Criterion) [:0]const u8 {
    const column = cutUtf8(f.column, 64);
    const value = cutUtf8(f.value, 40);
    return (if (f.op == .is_null)
        std.fmt.bufPrintSentinel(buf, "{s} IS NULL  x###f", .{column}, 0)
    else
        std.fmt.bufPrintSentinel(buf, "{s} = '{s}{s}'  x###f", .{ column, value, if (value.len < f.value.len) "..." else "" }, 0)) catch "filter  x###f";
}

// Texto na tela de um DOUBLE/FLOAT inteiro sem a parte decimal ("2316.0" -> "2316"), igual a stack Go; o resto
// (2.5, 1e+20, inf, nan) fica como veio. So para desenhar: copia, filtro e exportacao usam o valor original.
pub fn wholeFloatText(s: []const u8) []const u8 {
    if (!std.mem.endsWith(u8, s, ".0")) return s;
    const int = s[0 .. s.len - 2];
    const digits = if (std.mem.startsWith(u8, int, "-")) int[1..] else int;
    if (digits.len == 0) return s;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return s;
    return int;
}

// Dialogo Colunas: a coluna aparece na lista se o nome contem o texto da busca (sem diferenciar caixa)
pub fn columnListed(name: []const u8, needle: []const u8) bool {
    return needle.len == 0 or std.ascii.findIgnoreCase(name, needle) != null;
}

// Mostrar todas / Ocultar todas: so as colunas listadas pela busca do dialogo mudam
pub fn setListed(hidden: anytype, names: []const [:0]const u8, needle: []const u8, hide: bool) void {
    for (names, 0..) |name, c| if (columnListed(name, needle)) hidden.setValue(c, hide);
}

// Dialogo Columns: ~65% da largura da janela principal, entre 420 e 900 px, e nunca maior que a propria janela
pub fn columnsDialogWidth(main_w: f32) f32 {
    return @max(0, @min(std.math.clamp(main_w * 0.65, 420, 900), main_w - 16));
}

// Colunas da grade de caixas do dialogo: quantas celulas de `cell` px cabem em `avail`, de 1 a 6
pub fn checkboxGridColumns(avail: f32, cell: f32) usize {
    if (!(cell > 0) or !(avail > 0)) return 1;
    return @intFromFloat(std.math.clamp(@floor(avail / cell), 1, 6));
}

// -------------------------------------------------------------------- tests

test "whole DOUBLE values are shown without .0, the rest as it came" {
    try t.expectEqualStrings("2", wholeFloatText("2.0"));
    try t.expectEqualStrings("2316", wholeFloatText("2316.0"));
    try t.expectEqualStrings("-7", wholeFloatText("-7.0"));
    try t.expectEqualStrings("0", wholeFloatText("0.0"));
    for ([_][]const u8{ "2.5", "2.05", "1e+20", "1.0e+20", "inf", "-inf", "nan", ".0", "-.0", "x.0", "", "10" }) |s|
        try t.expectEqualStrings(s, wholeFloatText(s));
}

test "Columns dialog: Show all / Hide all act only on the columns the search lists" {
    const names = [_][:0]const u8{ "RTUNO", "PNTNAM", "PNTNO", "SUBNAM", "rtu_alias" };
    var hidden: std.StaticBitSet(8) = .empty;
    setListed(&hidden, &names, "rtu", true); // RTUNO e rtu_alias
    try t.expect(hidden.isSet(0) and hidden.isSet(4) and hidden.count() == 2);
    setListed(&hidden, &names, "pnt", true);
    try t.expectEqual(4, hidden.count());
    setListed(&hidden, &names, "RTUNO", false); // so ela volta
    try t.expect(!hidden.isSet(0) and hidden.isSet(4) and hidden.count() == 3);
    setListed(&hidden, &names, "", false); // sem busca: todas
    try t.expectEqual(0, hidden.count());
    setListed(&hidden, &names, "", true);
    try t.expectEqual(5, hidden.count());
}

test "Columns dialog: width follows the main window within 420..900, grid of 1 to 6 columns" {
    try t.expectEqual(@as(f32, 832), columnsDialogWidth(1280)); // tamanho padrao do app
    try t.expectEqual(@as(f32, 900), columnsDialogWidth(1920)); // maximizada
    try t.expectEqual(@as(f32, 420), columnsDialogWidth(600));
    try t.expectEqual(@as(f32, 384), columnsDialogWidth(400)); // janela menor que o minimo: cabe nela
    // celula minima de 11 em (176 px com a fonte de 16 px): ~4 colunas no tamanho padrao
    try t.expectEqual(4, checkboxGridColumns(832 - 2 * 10 - 2 * 10 - 14, 176));
    try t.expectEqual(4, checkboxGridColumns(900 - 54, 176));
    try t.expectEqual(2, checkboxGridColumns(420 - 54, 176));
    try t.expectEqual(1, checkboxGridColumns(100, 176));
    try t.expectEqual(6, checkboxGridColumns(5000, 176));
    try t.expectEqual(1, checkboxGridColumns(0, 176));
    try t.expectEqual(1, checkboxGridColumns(500, 0));
}

test "right-click filters: exact value or NULL, no repeats, the list owns the values" {
    var list: std.ArrayList(query.Criterion) = .empty;
    defer {
        for (list.items) |f| t.allocator.free(f.value);
        list.deinit(t.allocator);
    }
    addFilter(t.allocator, &list, "SIGLA", try t.allocator.dupe(u8, "U9A"));
    addFilter(t.allocator, &list, "SIGLA", try t.allocator.dupe(u8, "U9A")); // repetido: liberado, nao somado
    addFilter(t.allocator, &list, "SIGLA", null);
    addFilter(t.allocator, &list, "SIGLA", null);
    addFilter(t.allocator, &list, "SIGLA", try t.allocator.dupe(u8, "")); // texto vazio nao e NULL
    addFilter(t.allocator, &list, "N", try t.allocator.dupe(u8, "U9A"));
    try t.expectEqual(4, list.items.len);
    try t.expectEqual(query.Op.exact, list.items[0].op);
    try t.expectEqual(query.Op.is_null, list.items[1].op);
    try t.expectEqual(query.Op.exact, list.items[2].op);
    try t.expectEqualStrings("N", list.items[3].column);
}

test "filter button label: value quoted, NULL, long value cut on a whole UTF-8 character" {
    var buf: [200]u8 = undefined;
    try t.expectEqualStrings("SIGLA = 'U9A'  x###f", filterLabel(&buf, .{ .column = "SIGLA", .op = .exact, .value = "U9A" }));
    try t.expectEqualStrings("SIGLA IS NULL  x###f", filterLabel(&buf, .{ .column = "SIGLA", .op = .is_null }));
    try t.expectEqualStrings("S = ''  x###f", filterLabel(&buf, .{ .column = "S", .op = .exact, .value = "" }));
    // 39 letras + "Ç" (2 bytes) passa de 40: corta antes do Ç, nunca no meio dele
    const a39 = "abcdefghijklmnopqrstuvwxyzabcdefghijklm";
    try t.expectEqual(39, a39.len);
    try t.expectEqualStrings("S = '" ++ a39 ++ "...'  x###f", filterLabel(&buf, .{ .column = "S", .op = .exact, .value = a39 ++ "Çb" }));
    const e30 = "éééééééééééééééééééééééééééééé"; // 30 x 2 bytes: o corte em 40 cai entre dois "é"
    try t.expectEqualStrings("S = '" ++ e30[0..40] ++ "...'  x###f", filterLabel(&buf, .{ .column = "S", .op = .exact, .value = e30 }));
    // corte impar: em 40 bytes ficaria "a" + 19 "é" + meio "é"; sai "a" + 19 "é"
    try t.expectEqualStrings("S = 'a" ++ e30[0..38] ++ "...'  x###f", filterLabel(&buf, .{ .column = "S", .op = .exact, .value = "a" ++ e30 }));
}

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
