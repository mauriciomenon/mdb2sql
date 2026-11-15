// Texto da janela Sobre. A versao vem de build.zig.zon (unica fonte) pelas build options.
// !T: About text; the version comes from build.zig.zon through the build options

const std = @import("std");
const builtin = @import("builtin");

pub const version: []const u8 = @import("build_options").version;
pub const zig_version = builtin.zig_version_string;

// As versoes do Dear ImGui e do GLFW sao lidas pela UI em execucao; a do DuckDB vem de db.zig
pub fn text(buf: []u8, imgui: []const u8, glfw: []const u8, duckdb: []const u8) []const u8 {
    return std.fmt.bufPrint(buf,
        \\MDB2SQL (Zig + Dear ImGui)
        \\Versão {s}
        \\Visualizador de bancos DuckDB convertidos de Microsoft Access: tabelas, esquema, dados e consultas.
        \\Zig {s}, Dear ImGui {s}, GLFW {s}, DuckDB {s}
        \\Autor: Mauricio Menon
        \\Código: https://github.com/mauriciomenon/mdb2sql
    , .{ version, zig_version, imgui, glfw, std.mem.trimStart(u8, duckdb, "v") }) catch buf;
}

test "about text has the six lines, the zon version and the runtime versions" {
    var buf: [1024]u8 = undefined;
    const s = text(&buf, "1.93.0", "3.4.0 Win32", "v2.0.0");
    var lines = std.mem.splitScalar(u8, s, '\n');
    try std.testing.expectEqualStrings("MDB2SQL (Zig + Dear ImGui)", lines.next().?);
    var want: [64]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&want, "Versão {s}", .{version}), lines.next().?);
    _ = try std.SemanticVersion.parse(version);
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, "Visualizador de bancos DuckDB"));
    var rt: [128]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&rt, "Zig {s}, Dear ImGui 1.93.0, GLFW 3.4.0 Win32, DuckDB 2.0.0", .{zig_version}), lines.next().?);
    try std.testing.expectEqualStrings("Autor: Mauricio Menon", lines.next().?);
    try std.testing.expectEqualStrings("Código: https://github.com/mauriciomenon/mdb2sql", lines.next().?);
    try std.testing.expect(lines.next() == null);
}
