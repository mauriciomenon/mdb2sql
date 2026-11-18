// Auxiliar de teste (escondido da UI): --capture <pasta> [--db <arquivo>] abre o banco, passa sozinho pelos estados
// das capturas de tela e grava cada quadro em PNG, sem janela visivel, sem mouse real e sem tocar nas
// configuracoes salvas. Aqui ficam as partes sem UI: argumentos, roteiro e o codificador PNG.
// !T: Test aid: --capture <dir> renders scripted UI states off-screen and saves PNGs (args, plan, PNG encoder)

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

pub const Options = struct {
    out_dir: []const u8,
    db: ?[]const u8 = null, // --db; sem ele vale o caminho posicional
};

// --capture <pasta> e --db <arquivo>; null = modo normal. Os outros argumentos sao do programa (pulados aqui:
// so as opcoes que levam valor precisam ser conhecidas para nao confundir o valor com um caminho).
pub fn parse(args: []const []const u8) error{Usage}!?Options {
    var out: ?[]const u8 = null;
    var db: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!std.mem.startsWith(u8, a, "-") or std.mem.eql(u8, a, "--about")) continue; // como o laco de main.zig
        if (i + 1 >= args.len) return error.Usage;
        i += 1;
        if (std.mem.eql(u8, a, "--capture")) out = args[i] else if (std.mem.eql(u8, a, "--db")) db = args[i];
    }
    const dir = out orelse return null;
    if (dir.len == 0) return error.Usage;
    return .{ .out_dir = dir, .db = db };
}

// Roteiro das capturas: cada passo leva a interface a um estado e grava <nome>.png no tamanho dado
pub const Action = enum { show, filter, columns, close_columns, other_table, about };
pub const Step = struct { name: []const u8, action: Action, w: u32, h: u32 };
pub const default_size = [2]u32{ 1280, 800 }; // tamanho em que o programa abre
pub const max_size = [2]u32{ 1920, 1129 }; // area de trabalho de 1920x1200 menos a barra de tarefas e o titulo
pub const narrow_size = [2]u32{ 720, 800 }; // a linha da tabela quebra em vez de ser cortada
pub const filter_column = "SUBNAM";
pub const filter_value = "U02";
pub const first_table = "RANGER_SOSTAT";
pub const second_table = "RANGER_SOANLG";

pub const plan = [_]Step{
    .{ .name = "a_table", .action = .show, .w = default_size[0], .h = default_size[1] },
    .{ .name = "d_filter", .action = .filter, .w = default_size[0], .h = default_size[1] },
    .{ .name = "c_columns_default", .action = .columns, .w = default_size[0], .h = default_size[1] },
    .{ .name = "c_hidden_default", .action = .close_columns, .w = default_size[0], .h = default_size[1] },
    .{ .name = "a_max", .action = .show, .w = max_size[0], .h = max_size[1] },
    .{ .name = "c_columns_max", .action = .columns, .w = max_size[0], .h = max_size[1] },
    .{ .name = "f_narrow", .action = .close_columns, .w = narrow_size[0], .h = narrow_size[1] },
    .{ .name = "e_soanlg", .action = .other_table, .w = default_size[0], .h = default_size[1] },
    .{ .name = "e_soanlg_max", .action = .other_table, .w = max_size[0], .h = max_size[1] },
    .{ .name = "b_about", .action = .about, .w = default_size[0], .h = default_size[1] },
};

// PNG RGBA 8 bits. `pixels` vem do glReadPixels: linhas de baixo para cima, 4 bytes por pixel.
pub fn encodePng(gpa: Allocator, w: u32, h: u32, pixels: []const u8) ![]u8 {
    std.debug.assert(pixels.len == @as(usize, w) * h * 4);
    var idat = try Io.Writer.Allocating.initCapacity(gpa, 64 * 1024); // o compressor pede buffer de saida
    defer idat.deinit();
    const window = try gpa.create([flate.max_window_len]u8);
    defer gpa.destroy(window);
    var comp = try flate.Compress.init(&idat.writer, window, .zlib, .level_4);
    const stride = @as(usize, w) * 4;
    var y = h;
    while (y > 0) {
        y -= 1;
        try comp.writer.writeByte(0); // filtro "None"
        try comp.writer.writeAll(pixels[y * stride ..][0..stride]);
    }
    try comp.finish();

    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const ow = &out.writer;
    try ow.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 }; // 8 bits, RGBA, deflate, filtro adaptativo, sem entrelacamento
    try chunk(ow, "IHDR", &ihdr);
    try chunk(ow, "IDAT", idat.written());
    try chunk(ow, "IEND", "");
    return out.toOwnedSlice();
}

fn chunk(w: *Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

// -------------------------------------------------------------------- tests

const t = std.testing;

test "capture arguments: --capture DIR and --db PATH among the normal ones" {
    try t.expect((try parse(&.{ "exe", "x.duckdb", "--table", "T", "--theme", "dark" })) == null);
    const o = (try parse(&.{ "exe", "x.duckdb", "--capture", "C:\\out", "--theme", "dark" })).?;
    try t.expectEqualStrings("C:\\out", o.out_dir);
    try t.expect(o.db == null);
    const o2 = (try parse(&.{ "exe", "--about", "--db", "--capture", "--capture", "out" })).?; // valor e valor, mesmo com "--"
    try t.expectEqualStrings("--capture", o2.db.?);
    try t.expectEqualStrings("out", o2.out_dir);
    try t.expectError(error.Usage, parse(&.{ "exe", "--capture" }));
    try t.expectError(error.Usage, parse(&.{ "exe", "--capture", "" }));
    try t.expectError(error.Usage, parse(&.{ "exe", "--db", "a.duckdb", "--capture" }));
}

test "capture plan: every step has a unique name and a sane size" {
    for (plan, 0..) |s, i| {
        try t.expect(s.w >= 640 and s.h >= 480 and s.w <= 3840);
        for (plan[0..i]) |p| try t.expect(!std.mem.eql(u8, p.name, s.name));
    }
}

test "PNG: signature, chunk CRCs and the zlib image rows (top row first)" {
    // 2x2, de baixo para cima como o glReadPixels: linha de baixo = azul, de cima = vermelho
    const px = [_]u8{ 0, 0, 255, 255, 0, 0, 255, 255, 255, 0, 0, 255, 255, 0, 0, 255 };
    const png = try encodePng(t.allocator, 2, 2, &px);
    defer t.allocator.free(png);
    try t.expectEqualStrings("\x89PNG\r\n\x1a\n", png[0..8]);
    var pos: usize = 8;
    var kinds: [3][4]u8 = undefined;
    var idat: []const u8 = "";
    for (&kinds) |*k| {
        const len = std.mem.readInt(u32, png[pos..][0..4], .big);
        k.* = png[pos + 4 ..][0..4].*;
        const data = png[pos + 8 ..][0..len];
        var crc: std.hash.Crc32 = .init();
        crc.update(k);
        crc.update(data);
        try t.expectEqual(crc.final(), std.mem.readInt(u32, png[pos + 8 + len ..][0..4], .big));
        if (std.mem.eql(u8, k, "IHDR")) {
            try t.expectEqual(2, std.mem.readInt(u32, data[0..4], .big));
            try t.expectEqualSlices(u8, &.{ 8, 6, 0, 0, 0 }, data[8..13]);
        }
        if (std.mem.eql(u8, k, "IDAT")) idat = data;
        pos += 12 + len;
    }
    try t.expectEqual(png.len, pos);
    try t.expectEqualStrings("IEND", &kinds[2]);
    var in: Io.Reader = .fixed(idat);
    var buf: [flate.max_window_len]u8 = undefined;
    var dec: flate.Decompress = .init(&in, .zlib, &buf);
    var raw: [18]u8 = undefined;
    try dec.reader.readSliceAll(&raw);
    try t.expectEqualSlices(u8, &.{ 0, 255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 0, 255, 255, 0, 0, 255, 255 }, &raw);
}
