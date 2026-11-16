// Planilha Excel .xlsx escrita direto (OOXML = zip + XML), em fluxo: uma linha por vez, memoria constante.
// !T: Minimal streaming .xlsx writer: deflated zip entries, inline strings, bold header, frozen first row

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

pub const max_data_rows = 1_048_575; // 1.048.576 linhas do Excel menos o cabecalho
pub const max_cols = 16_384;
pub const max_name = 31; // limite do nome de aba do Excel
const max_cell_chars = 32_767; // texto maior que isso o Excel recusa

// ------------------------------------------------------------- nomes de aba

// Nome de aba valido e unico (sem diferenciar maiusculas, como o Excel) para a parte `part` (1 = primeira)
// de uma tabela. Sem os caracteres proibidos \ / ? * [ ] :, sem apostrofo nas pontas, ate 31 caracteres;
// as partes seguintes viram "<nome> (2)", "(3)"... e um nome repetido ganha "~2", "~3"...
pub const Names = struct {
    gpa: Allocator,
    used: std.ArrayList([]u8) = .empty,

    pub fn deinit(n: *Names) void {
        for (n.used.items) |s| n.gpa.free(s);
        n.used.deinit(n.gpa);
    }

    fn taken(n: *const Names, name: []const u8) bool {
        for (n.used.items) |s| if (std.ascii.eqlIgnoreCase(s, name)) return true;
        return std.ascii.eqlIgnoreCase(name, "History"); // reservado pelo Excel
    }

    // O nome devolvido vive ate deinit
    pub fn make(n: *Names, table: []const u8, part: usize) Allocator.Error![]const u8 {
        var clean_buf: [256]u8 = undefined;
        var clean: std.ArrayList(u8) = .initBuffer(&clean_buf);
        for (table) |ch| {
            if (clean.items.len == clean_buf.len) break;
            clean.appendAssumeCapacity(if (std.mem.indexOfScalar(u8, "\\/?*[]:", ch) != null or ch < 0x20) '_' else ch);
        }
        const base = std.mem.trim(u8, clean.items, "' ");
        var buf: [64]u8 = undefined;
        var k: usize = 1;
        while (true) : (k += 1) {
            var suffix_buf: [24]u8 = undefined;
            const part_s = if (part > 1) std.fmt.bufPrint(&suffix_buf, " ({d})", .{part}) catch unreachable else "";
            var dup_buf: [24]u8 = undefined;
            const dup_s = if (k > 1) std.fmt.bufPrint(&dup_buf, "~{d}", .{k}) catch unreachable else "";
            const room = max_name - part_s.len - dup_s.len;
            const head = cutUtf8(if (base.len == 0) "Sheet" else base, room);
            const name = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ std.mem.trimEnd(u8, head, "' "), dup_s, part_s }) catch unreachable;
            if (!n.taken(name)) {
                const owned = try n.gpa.dupe(u8, name);
                errdefer n.gpa.free(owned);
                try n.used.append(n.gpa, owned);
                return owned;
            }
        }
    }
};

// Corta em ate `max` caracteres (pontos de codigo), sem partir um caractere UTF-8
pub fn cutUtf8(s: []const u8, max: usize) []const u8 {
    var chars: usize = 0;
    for (s, 0..) |ch, i| {
        if (ch & 0xC0 != 0x80) {
            if (chars == max) return s[0..i];
            chars += 1;
        }
    }
    return s;
}

// Letras da coluna: 0 -> A, 25 -> Z, 26 -> AA ...
pub fn colName(buf: *[3]u8, index: usize) []const u8 {
    var n = index + 1;
    var i: usize = buf.len;
    while (n > 0) {
        i -= 1;
        buf[i] = 'A' + @as(u8, @intCast((n - 1) % 26));
        n = (n - 1) / 26;
    }
    return buf[i..];
}

// ------------------------------------------------------------- XML

pub fn writeEscaped(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        switch (ch) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\t', '\n', '\r' => try w.writeByte(ch),
            // controles nao existem em XML: o Excel le _xHHHH_ como o caractere
            0...0x08, 0x0B, 0x0C, 0x0E...0x1F => try w.print("_x{X:0>4}_", .{ch}),
            // um "_x0041_" literal precisa do "_" escapado, senao o Excel o troca por "A"
            '_' => if (looksEscaped(s[i..])) try w.writeAll("_x005F_") else try w.writeByte(ch),
            else => try w.writeByte(ch),
        }
    }
}

fn looksEscaped(s: []const u8) bool {
    if (s.len < 7 or s[1] != 'x' or s[6] != '_') return false;
    for (s[2..6]) |h| if (!std.ascii.isHex(h)) return false;
    return true;
}

pub const Cell = union(enum) {
    empty,
    text: []const u8,
    number: []const u8, // texto ja no formato numerico (ex.: "-1.5", "3e+20")
    boolean: bool,
};

// Numero que o Excel aceita em <v> (sem inf/nan/hex)
pub fn isExcelNumber(s: []const u8) bool {
    if (s.len == 0 or s.len > 40) return false;
    for (s) |ch| if (!(std.ascii.isDigit(ch) or ch == '-' or ch == '+' or ch == '.' or ch == 'e' or ch == 'E')) return false;
    const v = std.fmt.parseFloat(f64, s) catch return false;
    return std.math.isFinite(v);
}

// ------------------------------------------------------------- zip

const Entry = struct { name: []const u8, offset: u64, crc: u32, csize: u64, usize: u64 };

pub const Error = error{ TooLarge, TooManySheets } || Allocator.Error || Io.File.OpenError ||
    Io.File.Writer.Error || Io.File.WritePositionalError || Io.Writer.Error || Io.File.Writer.SeekError;

// Uma entrada do zip sendo escrita: XML -> deflate -> arquivo. CRC e tamanhos vao no cabecalho no fim.
const Stream = struct {
    crc: std.hash.Crc32 = .init(),
    size: u64 = 0,
    comp: flate.Compress,

    fn put(s: *Stream, bytes: []const u8) Io.Writer.Error!void {
        s.crc.update(bytes);
        s.size += bytes.len;
        try s.comp.writer.writeAll(bytes);
    }
};

pub const Workbook = struct {
    gpa: Allocator,
    io: Io,
    file: Io.File,
    out_buf: []u8,
    out: Io.File.Writer,
    entries: std.ArrayList(Entry) = .empty,
    sheets: std.ArrayList([]u8) = .empty, // nomes (ja unicos), na ordem das abas
    names: Names,
    window: *[flate.max_window_len]u8,
    cur: ?struct { stream: Stream, header_at: u64, data_at: u64, name: []u8 } = null,
    row: usize = 0, // linhas escritas na aba atual (cabecalho incluso)
    // texto XML montado aqui antes de ir para o compressor
    xml_buf: []u8,
    xml: Io.Writer,

    pub fn create(gpa: Allocator, io: Io, path: []const u8) Error!Workbook {
        const file = try Io.Dir.cwd().createFile(io, path, .{});
        errdefer file.close(io);
        const out_buf = try gpa.alloc(u8, 256 * 1024);
        errdefer gpa.free(out_buf);
        const window = try gpa.create([flate.max_window_len]u8);
        errdefer gpa.destroy(window);
        const xml_buf = try gpa.alloc(u8, 64 * 1024);
        return .{
            .gpa = gpa,
            .io = io,
            .file = file,
            .out_buf = out_buf,
            .out = file.writer(io, out_buf),
            .names = .{ .gpa = gpa },
            .window = window,
            .xml_buf = xml_buf,
            .xml = .fixed(xml_buf),
        };
    }

    // Fecha o arquivo e libera tudo (depois de finish, ou para desistir no meio)
    pub fn deinit(wb: *Workbook) void {
        wb.file.close(wb.io);
        if (wb.cur) |cur| wb.gpa.free(cur.name);
        for (wb.entries.items) |e| wb.gpa.free(e.name);
        wb.entries.deinit(wb.gpa);
        wb.sheets.deinit(wb.gpa); // os nomes sao de `names`
        wb.names.deinit();
        wb.gpa.destroy(wb.window);
        wb.gpa.free(wb.out_buf);
        wb.gpa.free(wb.xml_buf);
    }

    fn beginEntry(wb: *Workbook, name: []const u8) Error!void {
        const owned = try wb.gpa.dupe(u8, name);
        errdefer wb.gpa.free(owned);
        const header_at = wb.out.logicalPos();
        try writeLocalHeader(&wb.out.interface, name, 0, 0, 0); // crc e tamanhos: endEntry
        try wb.out.interface.writeAll(name);
        wb.cur = .{
            .stream = .{ .comp = undefined },
            .header_at = header_at,
            .data_at = wb.out.logicalPos(),
            .name = owned,
        };
        const cur = &wb.cur.?;
        cur.stream.comp = try flate.Compress.init(&wb.out.interface, wb.window, .raw, .level_4);
    }

    fn flushXml(wb: *Workbook) Error!void {
        try wb.cur.?.stream.put(wb.xml.buffered());
        _ = wb.xml.consumeAll();
    }

    // Garante espaco no buffer XML (uma celula pode ter ate ~200 KB escapada: vai direto)
    fn room(wb: *Workbook, n: usize) Error!void {
        if (wb.xml.unusedCapacityLen() < n) try wb.flushXml();
    }

    fn put(wb: *Workbook, bytes: []const u8) Error!void {
        if (bytes.len > wb.xml_buf.len / 2) {
            try wb.flushXml();
            return wb.cur.?.stream.put(bytes);
        }
        try wb.room(bytes.len);
        try wb.xml.writeAll(bytes);
    }

    fn endEntry(wb: *Workbook) Error!void {
        try wb.flushXml();
        const cur = &wb.cur.?;
        try cur.stream.comp.finish();
        try wb.out.interface.flush();
        const end = wb.out.logicalPos();
        const csize = end - cur.data_at;
        // shortcut: no ZIP64, a sheet of more than 4 GB of XML is refused; split into more sheets if ever needed
        if (cur.stream.size > std.math.maxInt(u32) or csize > std.math.maxInt(u32) or end > std.math.maxInt(u32)) return error.TooLarge;
        const crc = cur.stream.crc.final();
        var hdr: [30]u8 = undefined;
        var hw: Io.Writer = .fixed(&hdr);
        writeLocalHeader(&hw, cur.name, crc, @intCast(csize), @intCast(cur.stream.size)) catch unreachable;
        try wb.file.writePositionalAll(wb.io, &hdr, cur.header_at);
        try wb.entries.append(wb.gpa, .{ .name = cur.name, .offset = cur.header_at, .crc = crc, .csize = csize, .usize = cur.stream.size });
        wb.cur = null;
    }

    fn whole(wb: *Workbook, name: []const u8, content: []const u8) Error!void {
        try wb.beginEntry(name);
        try wb.cur.?.stream.put(content);
        try wb.endEntry();
    }

    // Nova aba: `table` vira um nome valido e unico; `part` > 1 para as continuacoes de uma tabela grande
    pub fn beginSheet(wb: *Workbook, table: []const u8, part: usize) Error![]const u8 {
        if (wb.sheets.items.len >= 60_000) return error.TooManySheets;
        const name = try wb.names.make(table, part);
        try wb.sheets.append(wb.gpa, @constCast(name));
        var path_buf: [48]u8 = undefined;
        try wb.beginEntry(std.fmt.bufPrint(&path_buf, "xl/worksheets/sheet{d}.xml", .{wb.sheets.items.len}) catch unreachable);
        try wb.put("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" ++
            "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">" ++
            "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>" ++
            "<sheetData>");
        wb.row = 0;
        return name;
    }

    // Linha 1 = cabecalho em negrito; as celulas alem de 16.384 colunas ficam de fora
    pub fn writeRow(wb: *Workbook, cells: []const Cell) Error!void {
        wb.row += 1;
        const header = wb.row == 1;
        // folga larga: o print de inteiro do Writer pede ate ~70 bytes livres de uma vez, mesmo para numeros curtos
        try wb.room(256);
        try wb.xml.print("<row r=\"{d}\">", .{wb.row});
        for (cells[0..@min(cells.len, max_cols)], 0..) |cell, i| {
            if (cell == .empty) continue;
            var col_buf: [3]u8 = undefined;
            try wb.room(256); // "<c r=..." + o comeco de inlineStr (ver acima)
            try wb.xml.print("<c r=\"{s}{d}\"{s}", .{ colName(&col_buf, i), wb.row, if (header) " s=\"1\"" else "" });
            switch (cell) {
                .empty => unreachable,
                .number => |s| {
                    try wb.xml.writeAll("><v>");
                    try wb.put(s);
                    try wb.put("</v></c>");
                },
                .boolean => |b| try wb.xml.writeAll(if (b) " t=\"b\"><v>1</v></c>" else " t=\"b\"><v>0</v></c>"),
                .text => |s| {
                    try wb.xml.writeAll(" t=\"inlineStr\"><is><t xml:space=\"preserve\">");
                    const cut = cutUtf8(s, max_cell_chars);
                    // pior caso do escape: 7 bytes por byte de entrada
                    if (cut.len * 7 > wb.xml_buf.len / 2) {
                        var tmp: Io.Writer.Allocating = .init(wb.gpa);
                        defer tmp.deinit();
                        writeEscaped(&tmp.writer, cut) catch return error.OutOfMemory;
                        try wb.put(tmp.written());
                    } else {
                        try wb.room(cut.len * 7 + 256);
                        try writeEscaped(&wb.xml, cut);
                    }
                    try wb.put("</t></is></c>");
                },
            }
        }
        try wb.put("</row>");
    }

    pub fn endSheet(wb: *Workbook) Error!void {
        try wb.put("</sheetData></worksheet>");
        try wb.endEntry();
    }

    // Partes fixas do pacote + diretorio central. Uma pasta sem abas ganha uma aba vazia.
    pub fn finish(wb: *Workbook) Error!void {
        if (wb.sheets.items.len == 0) {
            _ = try wb.beginSheet("Sheet1", 1);
            try wb.endSheet();
        }
        var x: Io.Writer.Allocating = .init(wb.gpa);
        defer x.deinit();
        const w = &x.writer;
        const n = wb.sheets.items.len;

        try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" ++
            "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" ++
            "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" ++
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" ++
            "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>" ++
            "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>");
        for (1..n + 1) |i| try w.print("<Override PartName=\"/xl/worksheets/sheet{d}.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>", .{i});
        try w.writeAll("</Types>");
        try wb.whole("[Content_Types].xml", x.written());
        x.clearRetainingCapacity();

        try wb.whole("_rels/.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" ++
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" ++
            "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>" ++
            "</Relationships>");

        try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" ++
            "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>");
        for (wb.sheets.items, 1..) |name, i| {
            try w.writeAll("<sheet name=\"");
            try writeEscaped(w, name);
            try w.print("\" sheetId=\"{d}\" r:id=\"rId{d}\"/>", .{ i, i });
        }
        try w.writeAll("</sheets></workbook>");
        try wb.whole("xl/workbook.xml", x.written());
        x.clearRetainingCapacity();

        try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" ++
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">");
        for (1..n + 1) |i| try w.print("<Relationship Id=\"rId{d}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet{d}.xml\"/>", .{ i, i });
        try w.print("<Relationship Id=\"rId{d}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>", .{n + 1});
        try w.writeAll("</Relationships>");
        try wb.whole("xl/_rels/workbook.xml.rels", x.written());

        try wb.whole("xl/styles.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" ++
            "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">" ++
            "<fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>" ++
            "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>" ++
            "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>" ++
            "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>" ++
            "<cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>" ++
            "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/></cellXfs>" ++
            "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>" ++
            "</styleSheet>");

        // diretorio central
        const cd_at = wb.out.logicalPos();
        const o = &wb.out.interface;
        for (wb.entries.items) |e| {
            try o.writeInt(u32, 0x02014b50, .little);
            try o.writeInt(u16, 20, .little); // feito por: versao 2.0
            try o.writeInt(u16, 20, .little); // precisa da versao 2.0
            try o.writeInt(u16, 0x0800, .little); // nomes em UTF-8
            try o.writeInt(u16, 8, .little); // deflate
            try o.writeInt(u32, dos_time, .little);
            try o.writeInt(u32, e.crc, .little);
            try o.writeInt(u32, @intCast(e.csize), .little);
            try o.writeInt(u32, @intCast(e.usize), .little);
            try o.writeInt(u16, @intCast(e.name.len), .little);
            try o.writeInt(u16, 0, .little); // extra
            try o.writeInt(u16, 0, .little); // comentario
            try o.writeInt(u16, 0, .little); // disco
            try o.writeInt(u16, 0, .little); // atributos internos
            try o.writeInt(u32, 0, .little); // atributos externos
            try o.writeInt(u32, @intCast(e.offset), .little);
            try o.writeAll(e.name);
        }
        const cd_end = wb.out.logicalPos();
        if (cd_end > std.math.maxInt(u32) or wb.entries.items.len > std.math.maxInt(u16)) return error.TooLarge;
        try o.writeInt(u32, 0x06054b50, .little);
        try o.writeInt(u16, 0, .little);
        try o.writeInt(u16, 0, .little);
        try o.writeInt(u16, @intCast(wb.entries.items.len), .little);
        try o.writeInt(u16, @intCast(wb.entries.items.len), .little);
        try o.writeInt(u32, @intCast(cd_end - cd_at), .little);
        try o.writeInt(u32, @intCast(cd_at), .little);
        try o.writeInt(u16, 0, .little);
        try wb.out.interface.flush();
    }
};

// 2026-01-01 00:00 em formato DOS (a data das entradas nao importa para o Excel)
const dos_time: u32 = (((2026 - 1980) << 9 | 1 << 5 | 1) << 16) | 0;

// Os 30 bytes fixos do cabecalho local (o nome vem logo depois)
fn writeLocalHeader(w: *Io.Writer, name: []const u8, crc: u32, csize: u32, usize_: u32) Io.Writer.Error!void {
    try w.writeInt(u32, 0x04034b50, .little);
    try w.writeInt(u16, 20, .little);
    try w.writeInt(u16, 0x0800, .little);
    try w.writeInt(u16, 8, .little);
    try w.writeInt(u32, dos_time, .little);
    try w.writeInt(u32, crc, .little);
    try w.writeInt(u32, csize, .little);
    try w.writeInt(u32, usize_, .little);
    try w.writeInt(u16, @intCast(name.len), .little);
    try w.writeInt(u16, 0, .little);
}

// -------------------------------------------------------------------- tests

const t = std.testing;

test "sheet names: Excel limits, forbidden characters, unique, continuation parts" {
    var n: Names = .{ .gpa = t.allocator };
    defer n.deinit();
    try t.expectEqualStrings("RANGER_SOSTAT", try n.make("RANGER_SOSTAT", 1));
    try t.expectEqualStrings("RANGER_SOSTAT (2)", try n.make("RANGER_SOSTAT", 2));
    try t.expectEqualStrings("ranger_sostat~2", try n.make("ranger_sostat", 1)); // igual sem caixa
    try t.expectEqualStrings("a_b_c_d_e_f_g_", try n.make("a/b\\c?d*e[f]g:", 1));
    const long = "ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789";
    try t.expectEqualStrings("ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123", try n.make(long, 1));
    try t.expectEqualStrings("ABCDEFGHIJKLMNOPQRSTUVWXYZ_01~2", try n.make(long ++ "x", 1));
    try t.expectEqualStrings("ABCDEFGHIJKLMNOPQRSTUVWXYZ_ (3)", try n.make(long, 3));
    try t.expectEqualStrings("Sheet", try n.make("''", 1));
    try t.expectEqualStrings("history~2", try n.make("history", 1));
    // acentos contam como um caractere e nao sao partidos
    const s = try n.make("Ação" ++ &@as([40]u8, @splat('x')), 1);
    try t.expectEqual(31, try std.unicode.utf8CountCodepoints(s));
    for (n.used.items) |name| try t.expect(try std.unicode.utf8CountCodepoints(name) <= max_name);
}

test "column letters and numbers" {
    var b: [3]u8 = undefined;
    try t.expectEqualStrings("A", colName(&b, 0));
    try t.expectEqualStrings("Z", colName(&b, 25));
    try t.expectEqualStrings("AA", colName(&b, 26));
    try t.expectEqualStrings("XFD", colName(&b, max_cols - 1));
    try t.expect(isExcelNumber("-1.5") and isExcelNumber("3e+20") and isExcelNumber("0"));
    try t.expect(!isExcelNumber("inf") and !isExcelNumber("nan") and !isExcelNumber("") and !isExcelNumber("0x1F"));
}

test "XML escaping" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeEscaped(&w, "a<b>&\"c\x01\x0b_x0041_ _y");
    try t.expectEqualStrings("a&lt;b&gt;&amp;&quot;c_x0001__x000B__x005F_x0041_ _y", w.buffered());
}

// Le de volta o .xlsx com o leitor de zip da std e confere as partes
// Regressao: o DB4 real derrubava a exportacao (buffer XML cheio no meio de uma linha). Linhas com celulas
// de tamanhos aleatorios passam por todos os limites do buffer; o zip tem de sair valido com todas as linhas.
test "random cell sizes never overflow the XML buffer" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/stress.xlsx", .{tmp.sub_path});
    var prng: std.Random.DefaultPrng = .init(42);
    const rnd = prng.random();
    var text_buf: [3000]u8 = undefined;
    const n_rows = 20_000;
    {
        var wb = try Workbook.create(t.allocator, t.io, path);
        defer wb.deinit();
        _ = try wb.beginSheet("stress", 1);
        var cells: [12]Cell = undefined;
        for (0..n_rows) |_| {
            for (&cells, 0..) |*cell, i| {
                const len = rnd.uintLessThan(usize, if (i == 0) text_buf.len else 40);
                for (text_buf[0..len]) |*ch| ch.* = switch (rnd.uintLessThan(u8, 8)) {
                    0 => '&',
                    1 => 0x01, // controle: vira _x0001_
                    2 => '_',
                    else => 'a' + rnd.uintLessThan(u8, 26),
                };
                cell.* = switch (rnd.uintLessThan(u8, 4)) {
                    0 => .empty,
                    1 => .{ .number = "-12345.678e+10" },
                    2 => .{ .boolean = true },
                    else => .{ .text = text_buf[0..len] },
                };
            }
            try wb.writeRow(&cells);
        }
        try wb.endSheet();
        try wb.finish();
    }
    const file = try Io.Dir.cwd().openFile(t.io, path, .{});
    defer file.close(t.io);
    var rbuf: [4096]u8 = undefined;
    var reader = file.reader(t.io, &rbuf);
    var it = try std.zip.Iterator.init(&reader);
    var rows: usize = 0;
    while (try it.next()) |e| {
        var data: Io.Writer.Allocating = .init(t.allocator);
        defer data.deinit();
        try e.extractTo(&reader, &data.writer);
        rows += std.mem.count(u8, data.written(), "<row ");
    }
    try t.expectEqual(n_rows, rows);
}

test "workbook round trip through std.zip" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/out.xlsx", .{tmp.sub_path});

    var wb = try Workbook.create(t.allocator, t.io, path);
    {
        defer wb.deinit();
        _ = try wb.beginSheet("people", 1);
        try wb.writeRow(&.{ .{ .text = "id" }, .{ .text = "name" }, .{ .text = "ok" } });
        try wb.writeRow(&.{ .{ .number = "1" }, .{ .text = "Ação & <cia>" }, .{ .boolean = true } });
        try wb.writeRow(&.{ .{ .number = "2" }, .empty, .{ .boolean = false } });
        for (0..5000) |i| {
            var nb: [16]u8 = undefined;
            try wb.writeRow(&.{ .{ .number = std.fmt.bufPrint(&nb, "{d}", .{i}) catch unreachable }, .{ .text = &@as([50]u8, @splat('x')) } });
        }
        try wb.endSheet();
        _ = try wb.beginSheet("people", 2);
        try wb.writeRow(&.{.{ .text = "id" }});
        try wb.endSheet();
        try wb.finish();
    }

    const file = try Io.Dir.cwd().openFile(t.io, path, .{});
    defer file.close(t.io);
    var rbuf: [4096]u8 = undefined;
    var reader = file.reader(t.io, &rbuf);
    var it = try std.zip.Iterator.init(&reader);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |s| t.allocator.free(s);
        names.deinit(t.allocator);
    }
    var sheet1: []u8 = &.{};
    defer t.allocator.free(sheet1);
    var workbook_xml: []u8 = &.{};
    defer t.allocator.free(workbook_xml);
    var name_buf: [64]u8 = undefined;
    while (try it.next()) |e| {
        try reader.seekTo(e.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        const name = name_buf[0..e.filename_len];
        try reader.interface.readSliceAll(name);
        try names.append(t.allocator, try t.allocator.dupe(u8, name));
        try t.expectEqual(.deflate, e.compression_method);
        // extractTo confere o cabecalho local contra o diretorio central (crc, versao, flags, data)
        var data: Io.Writer.Allocating = .init(t.allocator);
        defer data.deinit();
        try e.extractTo(&reader, &data.writer);
        try t.expectEqual(e.uncompressed_size, data.written().len);
        try t.expectEqual(e.crc32, std.hash.Crc32.hash(data.written()));
        if (std.mem.eql(u8, name, "xl/worksheets/sheet1.xml")) sheet1 = try data.toOwnedSlice();
        if (std.mem.eql(u8, name, "xl/workbook.xml")) workbook_xml = try data.toOwnedSlice();
    }
    try t.expectEqual(7, names.items.len);
    try t.expect(std.mem.indexOf(u8, sheet1, "<c r=\"B2\" t=\"inlineStr\"><is><t xml:space=\"preserve\">Ação &amp; &lt;cia&gt;</t></is></c>") != null);
    try t.expect(std.mem.indexOf(u8, sheet1, "<c r=\"A1\" s=\"1\" t=\"inlineStr\">") != null);
    try t.expect(std.mem.indexOf(u8, sheet1, "<row r=\"3\"><c r=\"A3\"><v>2</v></c><c r=\"C3\" t=\"b\"><v>0</v></c></row>") != null);
    try t.expect(std.mem.indexOf(u8, sheet1, "<row r=\"5003\">") != null);
    try t.expect(std.mem.indexOf(u8, workbook_xml, "<sheet name=\"people (2)\" sheetId=\"2\" r:id=\"rId2\"/>") != null);
}
