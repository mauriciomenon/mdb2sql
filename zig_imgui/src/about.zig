// Dados da janela Sobre e titulo da janela. Versao de build.zig.zon (unica fonte); numero e data do build
// vem do scripts\build_w11.ps1 pelas build options (fora dele: "dev").
// !T: About data and window title; the version comes from build.zig.zon, build number and date from the build script

const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const i18n = @import("i18n.zig");

pub const version: []const u8 = options.version;
pub const zig_version = builtin.zig_version_string;

pub const name = "mdb2sql";
// Titulo curto da janela e das caixas de mensagem; os detalhes ficam no Sobre
pub const window_title = name ++ " " ++ version ++ " - Zig";
pub const author = "Mauricio Menon";
pub const mdbtools_version = options.mdbtools_version;

pub const Link = struct { label: [:0]const u8, url: [:0]const u8 };
pub const links = [_]Link{
    .{ .label = "GitHub", .url = "https://github.com/mauriciomenon/mdb2sql" },
    .{ .label = "GitLab", .url = "https://gitlab.com/mauricio.menon/mdb2sql" },
};

// So os links do Sobre podem ser abertos no navegador: devolve a URL fixa (nunca o texto recebido) ou null
pub fn allowedLink(url: []const u8) ?[:0]const u8 {
    for (links) |l| if (std.mem.eql(u8, l.url, url)) return l.url;
    return null;
}

// "42 (2026-11-15)" ou "dev"
pub fn buildText(buf: []u8, number: []const u8, date: []const u8) []const u8 {
    if (number.len == 0) return "dev";
    return std.fmt.bufPrint(buf, "{s} ({s})", .{ number, date }) catch "dev";
}

pub fn build(buf: []u8) []const u8 {
    return buildText(buf, options.build_number, options.build_date);
}

// "Zig 0.17.1 + Dear ImGui 1.93.0": a versao do Dear ImGui e lida pela UI em execucao
pub fn stackText(buf: []u8, imgui: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "Zig {s} + Dear ImGui {s}", .{ zig_version, imgui }) catch "Zig + Dear ImGui";
}

test "window title is short and carries the zon version" {
    _ = try std.SemanticVersion.parse(version);
    try std.testing.expectEqualStrings("mdb2sql 1.3.0 - Zig", window_title); // muda junto com build.zig.zon
}

test "only the two About links may be opened" {
    try std.testing.expectEqualStrings("https://github.com/mauriciomenon/mdb2sql", allowedLink("https://github.com/mauriciomenon/mdb2sql").?);
    try std.testing.expectEqualStrings("https://gitlab.com/mauricio.menon/mdb2sql", allowedLink("https://gitlab.com/mauricio.menon/mdb2sql").?);
    try std.testing.expectEqual(2, links.len);
    for ([_][]const u8{
        "",                                               "https://github.com/mauriciomenon/mdb2sql/",
        "https://github.com/mauriciomenon/mdb2sql?x=1",   "http://github.com/mauriciomenon/mdb2sql",
        "HTTPS://GITHUB.COM/mauriciomenon/mdb2sql",       "https://github.com/mauriciomenon/mdb2sql\x00calc.exe",
        "https://gitlab.com/mauricio.menon/mdb2sql.evil", "file:///C:/Windows/System32/calc.exe",
        "C:\\Windows\\System32\\calc.exe",                "https://example.com",
    }) |bad| try std.testing.expect(allowedLink(bad) == null);
}

test "about texts: build, stack with versions" {
    var bb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("dev", buildText(&bb, "", ""));
    try std.testing.expectEqualStrings("57 (2026-11-15)", buildText(&bb, "57", "2026-11-15"));
    var sb: [96]u8 = undefined;
    var want: [96]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&want, "Zig {s} + Dear ImGui 1.93.0", .{zig_version}), stackText(&sb, "1.93.0"));
}

test "UI texts: one Export button, no copyright line, no lecturing hints" {
    const ui = @embedFile("main.zig");
    try std.testing.expectEqual(1, std.mem.count(u8, ui, "button(tr(\"export_button\"))")); // o Exportar... da barra de cima
    try std.testing.expectEqual(1, std.mem.count(u8, ui, "button(tr(\"columns_button\"))"));
    // cada exportacao aparece uma vez (o botao e o menu Arquivo > Exportar usam a mesma lista exportItems)
    inline for (.{ "export_db_sqlite", "export_db_xlsx", "export_db_duckdb" }) |k|
        try std.testing.expectEqual(1, std.mem.count(u8, ui, "tr(\"" ++ k ++ "\")"));
    for ([_][]const u8{ "Copyright", "(C) 20", "read-only\")", "not available\")", "any order, ignores", "Remember", "Please ", "Make sure" }) |bad| {
        try std.testing.expect(std.mem.indexOf(u8, ui, bad) == null);
    }
}

test "license: GPL v2 or later in About (three languages), LICENSE file is the GPL v2 text" {
    try std.testing.expectEqualStrings("GPL v2 or later (GPL-2.0-or-later)", i18n.catalogs[0].about_license_text);
    try std.testing.expectEqualStrings("GPL v2 ou posterior (GPL-2.0-or-later)", i18n.catalogs[1].about_license_text);
    try std.testing.expectEqualStrings("GPL v2 o posterior (GPL-2.0-or-later)", i18n.catalogs[2].about_license_text);
    const text = @embedFile("LICENSE"); // o mesmo arquivo que vai no zip e no instalador
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    try std.testing.expectEqualStrings("GNU GENERAL PUBLIC LICENSE", std.mem.trim(u8, lines.next().?, " "));
    try std.testing.expect(std.mem.startsWith(u8, std.mem.trim(u8, lines.next().?, " "), "Version 2,"));
}
