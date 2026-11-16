// Ferramenta de build: comprime um arquivo em gzip para ir embutido no executavel unico (launcher.zig).
// Uso: pack <entrada> <saida.gz>
const std = @import("std");
const flate = std.compress.flate;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;
    const io = init.io;
    const in = try std.Io.Dir.cwd().openFile(io, args[1], .{});
    defer in.close(io);
    var rbuf: [64 * 1024]u8 = undefined;
    var reader = in.reader(io, &rbuf);
    const out = try std.Io.Dir.cwd().createFile(io, args[2], .{});
    defer out.close(io);
    var wbuf: [64 * 1024]u8 = undefined;
    var writer = out.writer(io, &wbuf);
    try pack(&reader.interface, &writer.interface);
    try writer.end();
}

pub fn pack(r: *std.Io.Reader, w: *std.Io.Writer) !void {
    var window: [flate.max_window_len]u8 = undefined;
    var comp = try flate.Compress.init(w, &window, .gzip, .level_6);
    _ = try r.streamRemaining(&comp.writer);
    try comp.finish();
}

test "gzip round trip (the launcher unpacks with std.compress.flate.Decompress)" {
    const data = comptime blk: {
        @setEvalBranchQuota(20000);
        var d: []const u8 = "";
        for (0..5000) |_| d = d ++ "MDB2SQL ";
        break :blk d ++ "fim";
    };
    var in: std.Io.Reader = .fixed(data);
    var packed_buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&packed_buf);
    try pack(&in, &w);
    try std.testing.expect(w.buffered().len < data.len / 10);
    var src: std.Io.Reader = .fixed(w.buffered());
    var dbuf: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&src, .gzip, &dbuf);
    const back = try d.reader.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings(data, back);
}
