// Texto da janela Sobre. Versao de build.zig.zon (unica fonte); numero e data do build vem do
// scripts\build_w11.ps1 pelas build options (fora dele: "build dev").
// !T: About text; the version comes from build.zig.zon, build number and date from the build script

const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");

pub const version: []const u8 = options.version;
pub const zig_version = builtin.zig_version_string;

// "build 42 (2026-11-15)" ou "build dev"
pub fn buildText(buf: []u8, number: []const u8, date: []const u8) []const u8 {
    if (number.len == 0) return "build dev";
    return std.fmt.bufPrint(buf, "build {s} ({s})", .{ number, date }) catch "build dev";
}

// As versoes do Dear ImGui e do GLFW sao lidas pela UI em execucao; a do DuckDB vem de db.zig
pub fn text(buf: []u8, imgui: []const u8, glfw: []const u8, duckdb: []const u8) []const u8 {
    var bb: [64]u8 = undefined;
    return std.fmt.bufPrint(buf,
        \\MDB2SQL (Zig + Dear ImGui)
        \\Versao {s} - {s}
        \\Abre bancos DuckDB, SQLite e Access e exporta para DuckDB, SQLite, Excel e CSV.
        \\Zig {s}, Dear ImGui {s}, GLFW {s}, DuckDB {s}
        \\Autor: Mauricio Menon
        \\Codigo: https://github.com/mauriciomenon/mdb2sql
    , .{ version, buildText(&bb, options.build_number, options.build_date), zig_version, imgui, glfw, std.mem.trimStart(u8, duckdb, "v") }) catch buf;
}

test "about text has the six lines, the zon version, the build and the runtime versions" {
    var buf: [1024]u8 = undefined;
    const s = text(&buf, "1.93.0", "3.4.0 Win32", "v2.0.0");
    var lines = std.mem.splitScalar(u8, s, '\n');
    try std.testing.expectEqualStrings("MDB2SQL (Zig + Dear ImGui)", lines.next().?);
    var want: [64]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, try std.fmt.bufPrint(&want, "Versao {s} - build ", .{version})));
    _ = try std.SemanticVersion.parse(version);
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, "Abre bancos DuckDB, SQLite e Access"));
    var rt: [128]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&rt, "Zig {s}, Dear ImGui 1.93.0, GLFW 3.4.0 Win32, DuckDB 2.0.0", .{zig_version}), lines.next().?);
    try std.testing.expectEqualStrings("Autor: Mauricio Menon", lines.next().?);
    try std.testing.expectEqualStrings("Codigo: https://github.com/mauriciomenon/mdb2sql", lines.next().?);
    try std.testing.expect(lines.next() == null);
    var bb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("build dev", buildText(&bb, "", ""));
    try std.testing.expectEqualStrings("build 57 (2026-11-15)", buildText(&bb, "57", "2026-11-15"));
}
