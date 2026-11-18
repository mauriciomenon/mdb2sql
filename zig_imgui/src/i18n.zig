// Idiomas da interface: ingles (padrao), portugues do Brasil e espanhol. Um catalogo por idioma em src/lang/,
// todos com as mesmas chaves (conferido em tempo de compilacao e no teste abaixo).
// !T: UI languages. tr("key") / fmt(buf, "key", args) read the catalog of the current language.

const std = @import("std");

pub const Lang = enum { en, pt_br, es };

// Nome de cada idioma no proprio idioma (o menu mostra os tres assim, em qualquer idioma)
pub const names = [_][:0]const u8{ "English", "Português (Brasil)", "Español" };

pub const catalogs = .{ @import("lang/en.zig"), @import("lang/pt_br.zig"), @import("lang/es.zig") };

// Idioma atual. So a thread da UI troca; os trabalhos leem para montar mensagens de erro.
pub var lang: Lang = .en;

fn Catalog(comptime l: Lang) type {
    return catalogs[@backingInt(l)];
}

pub fn tr(comptime key: []const u8) [:0]const u8 {
    return switch (lang) {
        inline else => |l| @field(Catalog(l), key),
    };
}

// Texto com argumentos; o formato e o do catalogo (os tres precisam aceitar os mesmos argumentos: o compilador confere)
pub fn fmt(buf: []u8, comptime key: []const u8, args: anytype) []const u8 {
    return switch (lang) {
        inline else => |l| std.fmt.bufPrint(buf, @field(Catalog(l), key), args) catch buf,
    };
}

pub fn fmtZ(buf: []u8, comptime key: []const u8, args: anytype) [:0]const u8 {
    return switch (lang) {
        inline else => |l| std.fmt.bufPrintSentinel(buf, @field(Catalog(l), key), args, 0) catch "",
    };
}

// -------------------------------------------------------------------- tests

const t = std.testing;

fn keys(comptime C: type) []const [:0]const u8 {
    return std.meta.declarations(C);
}

test "the three catalogs have the same keys and no empty text" {
    inline for (catalogs) |C| {
        try t.expectEqual(keys(catalogs[0]).len, keys(C).len);
        inline for (comptime keys(catalogs[0])) |d| {
            try t.expect(@hasDecl(C, d));
            const s: []const u8 = @field(C, d);
            try t.expect(s.len > 0);
            // mesmos marcadores {..} nos tres idiomas e na mesma ordem
            const base: []const u8 = @field(catalogs[0], d);
            try t.expectEqual(std.mem.count(u8, base, "{"), std.mem.count(u8, s, "{"));
        }
    }
}

test "translations differ from English where words are involved" {
    // pelo menos os menus principais estao traduzidos (pega catalogo copiado por engano)
    inline for (.{ "menu_file", "menu_settings", "menu_help", "export_button", "converted_title" }) |k| {
        try t.expect(!std.mem.eql(u8, @field(catalogs[0], k), @field(catalogs[1], k)));
        try t.expect(!std.mem.eql(u8, @field(catalogs[0], k), @field(catalogs[2], k)));
    }
}

// Texto de tela fora do catalogo: literal com espaco ou comecando por maiuscula (chaves e IDs sao minusculos,
// sem espaco). Excecoes: SQL, nomes de produto, atalhos, variaveis de ambiente e mensagens do --capture.
fn uiTextOutsideCatalog(src: []const u8) ?[]const u8 {
    const allowed_lines = [_][]const u8{ "c.failed", "c.skip(", "sql.appendSlice(", "@import(", "extern ", "\\x00*.", "--file-filter=", "segoeui", "SQLite format 3" };
    const allowed = [_][]const u8{ "GLFW {d}.{d}.{d} + OpenGL 3.3", "DuckDB {s}", "#version 330", "Ctrl+O", "Ctrl+L", "Ctrl+C" };
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |full| {
        // sem o comentario do fim da linha (// fora de string)
        var in_str = false;
        var cut = full.len;
        var p: usize = 0;
        while (p < full.len) : (p += 1) {
            const ch = full[p];
            if (in_str and ch == '\\') {
                p += 1;
            } else if (ch == '"' and !(p > 0 and full[p - 1] == '\'')) {
                in_str = !in_str;
            } else if (!in_str and ch == '/' and p + 1 < full.len and full[p + 1] == '/') {
                cut = p;
                break;
            }
        }
        const line = full[0..cut];
        const code = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, code, "//")) continue;
        const skip_line = for (allowed_lines) |a| {
            if (std.mem.indexOf(u8, line, a) != null) break true;
        } else false;
        if (!skip_line) {
            var i: usize = 0;
            while (std.mem.indexOfScalarPos(u8, line, i, '"')) |q| {
                if (q >= 2 and std.mem.eql(u8, line[q - 2 .. q], "//")) break;
                if (q > 0 and line[q - 1] == '\'') { // '"' de um caractere
                    i = q + 2;
                    continue;
                }
                var e = q + 1;
                while (e < line.len and line[e] != '"') : (e += 1) {
                    if (line[e] == '\\') e += 1;
                }
                if (e >= line.len) break;
                const lit = line[q + 1 .. e];
                i = e + 1;
                // so marcadores {..} e escapes (\n): nao e texto
                var words: usize = 0;
                var k: usize = 0;
                while (k < lit.len) : (k += 1) {
                    if (lit[k] == '{') k = std.mem.indexOfScalarPos(u8, lit, k, '}') orelse lit.len else if (lit[k] == '\\') {
                        k += 1;
                    } else if (std.ascii.isAlphabetic(lit[k])) words += 1;
                }
                if (words == 0) continue;
                const upper_id = for (lit) |ch| {
                    if (!std.ascii.isUpper(ch) and !std.ascii.isDigit(ch) and ch != '_') break false;
                } else true;
                const looks_ui = std.mem.indexOfScalar(u8, lit, ' ') != null or std.ascii.isUpper(lit[0]);
                if (!looks_ui or upper_id or std.mem.startsWith(u8, lit, "##")) continue;
                const ok = for (allowed) |a| {
                    if (std.mem.eql(u8, a, lit)) break true;
                } else false;
                if (!ok) return lit;
            }
        }
    }
    return null;
}

test "no screen text outside the catalogs (main.zig, dialog.zig, platform.zig)" {
    inline for (.{ "main.zig", "dialog.zig", "platform.zig" }) |f| {
        if (uiTextOutsideCatalog(@embedFile(f))) |lit| {
            std.debug.print("{s}: \"{s}\" is not in the catalogs\n", .{ f, lit });
            return error.TextOutsideCatalog;
        }
    }
    try t.expectEqualStrings("Open file", uiTextOutsideCatalog("    if (button(\"Open file\")) x();").?);
    try t.expect(uiTextOutsideCatalog("    if (button(tr(\"open\"))) x(); // \"Comment text\"") == null);
}

test "no lecturing hints and no copyright line in any catalog" {
    inline for (catalogs) |C| {
        inline for (comptime keys(C)) |d| {
            const s: []const u8 = @field(C, d);
            for ([_][]const u8{ "Copyright", "(C) 20", "Remember", "Please", "Make sure", "Lembre", "Por favor", "Verifique", "Recuerde", "Asegúrese" }) |bad|
                try t.expect(std.ascii.findIgnoreCase(s, bad) == null);
        }
    }
}

test "tr and fmt follow the current language" {
    defer lang = .en;
    var b: [128]u8 = undefined;
    lang = .en;
    try t.expectEqualStrings("File", tr("menu_file"));
    try t.expectEqualStrings("3 of 7 shown", fmt(&b, "columns_shown", .{ 3, 7 }));
    lang = .pt_br;
    try t.expectEqualStrings("Arquivo", tr("menu_file"));
    try t.expectEqualStrings("3 de 7 visíveis", fmt(&b, "columns_shown", .{ 3, 7 }));
    lang = .es;
    try t.expectEqualStrings("Archivo", tr("menu_file"));
    try t.expectEqualStrings("3 de 7 visibles", fmt(&b, "columns_shown", .{ 3, 7 }));
}
