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

// Texto com contagem e plural certo: a chave `key ++ "_one"` quando n == 1 ("1 tabela"), senao `key` ("2 tabelas");
// as duas recebem os mesmos argumentos
pub fn fmtCount(buf: []u8, comptime key: []const u8, n: u64, args: anytype) []const u8 {
    return if (n == 1) fmt(buf, key ++ "_one", args) else fmt(buf, key, args);
}

// Palavra de uma contagem com o plural certo ("1 linha", "2 linhas"): `key ++ "_one"` quando n == 1
pub fn trCount(comptime key: []const u8, n: u64) [:0]const u8 {
    return if (n == 1) tr(key ++ "_one") else tr(key);
}

pub fn fmtCountZ(buf: []u8, comptime key: []const u8, n: u64, args: anytype) [:0]const u8 {
    return if (n == 1) fmtZ(buf, key ++ "_one", args) else fmtZ(buf, key, args);
}

// Coluna "Aceita nulo" do Esquema: o YES/NO do DuckDB (ou o Sim/Nao de outro idioma, ao trocar o idioma) no idioma
// atual; outro texto volta como veio
pub fn yesNo(v: []const u8) []const u8 {
    if (std.mem.eql(u8, v, "YES")) return tr("yes");
    if (std.mem.eql(u8, v, "NO")) return tr("no");
    inline for (catalogs) |C| {
        if (std.mem.eql(u8, v, C.yes)) return tr("yes");
        if (std.mem.eql(u8, v, C.no)) return tr("no");
    }
    return v;
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
    @setEvalBranchQuota(100_000);
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

test "plural: every _one key has its plural key with the same arguments, and fmtCount picks by the count" {
    @setEvalBranchQuota(100_000);
    inline for (catalogs) |C| {
        inline for (comptime keys(C)) |d| {
            if (comptime std.mem.endsWith(u8, d, "_one")) {
                const base = d[0 .. d.len - "_one".len];
                try t.expect(@hasDecl(C, base));
                try t.expectEqual(std.mem.count(u8, @field(C, base), "{"), std.mem.count(u8, @field(C, d), "{"));
            }
        }
    }
    defer lang = .en;
    var b: [128]u8 = undefined;
    lang = .pt_br;
    try t.expectEqualStrings("Aberto: a.mdb (1 tabela)", fmtCount(&b, "status_loaded", 1, .{ "a.mdb", 1 }));
    try t.expectEqualStrings("Aberto: a.mdb (3 tabelas)", fmtCount(&b, "status_loaded", 3, .{ "a.mdb", 3 }));
    try t.expectEqualStrings("Aberto: a.mdb (0 tabelas)", fmtCount(&b, "status_loaded", 0, .{ "a.mdb", 0 }));
    lang = .en;
    try t.expectEqualStrings("1 unread error or warning", fmtCount(&b, "log_unread", 1, .{1}));
    try t.expectEqualStrings("2 unread errors or warnings", fmtCount(&b, "log_unread", 2, .{2}));
    // SQL, exportacao e progresso
    lang = .pt_br;
    try t.expectEqualStrings("1 linha", fmtCount(&b, "sql_rows", 1, .{1}));
    try t.expectEqualStrings("1 coluna", fmtCount(&b, "sql_cols", 1, .{1}));
    try t.expectEqualStrings("1 de 1 linha encontrada", fmtCount(&b, "rows_match", 1, .{ 1, 1 }));
    try t.expectEqualStrings("Exportada 1 linha para T.csv", fmtCount(&b, "status_exported", 1, .{ 1, trCount("unit_rows", 1), "T.csv", "", "" }));
    try t.expectEqualStrings("Exportadas 3 tabelas para T.sqlite", fmtCount(&b, "status_exported", 3, .{ 3, trCount("unit_tables", 3), "T.sqlite", "", "" }));
}

test "Schema nullable column: YES/NO in the screen language, again after a language change" {
    defer lang = .en;
    lang = .pt_br;
    try t.expectEqualStrings("Sim", yesNo("YES"));
    try t.expectEqualStrings("Não", yesNo("NO"));
    lang = .es;
    try t.expectEqualStrings("Sí", yesNo("Sim")); // o texto ja traduzido, refeito no idioma novo
    try t.expectEqualStrings("No", yesNo("Não"));
    lang = .en;
    try t.expectEqualStrings("Yes", yesNo("Sí"));
    try t.expectEqualStrings("No", yesNo("No"));
    try t.expectEqualStrings("PRI", yesNo("PRI"));
}

test "texts as in the Go catalog (the reference wording), in the three languages" {
    const want = .{
        .{ "search_rule", "All words, any order, in one cell; ignores case and accents", "Todas as palavras, em qualquer ordem, na mesma célula; ignora maiúsculas e acentos", "Todas las palabras, en cualquier orden, en la misma celda; ignora mayúsculas y acentos" },
        .{ "columns_tip", "Search and export use every column", "Pesquisa e exportação usam todas as colunas", "La búsqueda y la exportación usan todas las columnas" },
        .{ "find_column", "Filter columns", "Filtrar colunas", "Filtrar columnas" },
        .{ "search", "Search the whole table", "Pesquisar na tabela inteira", "Buscar en toda la tabla" },
        .{ "clear_filters", "Clear filters", "Limpar filtros", "Quitar filtros" },
        .{ "menu_search_scope", "Default search scope", "Escopo padrão da busca", "Alcance predeterminado de la búsqueda" },
        .{ "menu_log", "Log", "Log", "Log" },
        // itens 27 e 28 (BRIEF de 25/11, secao 8)
        .{ "exit_text", "The database converted from {s} was not saved. Save before exiting?", "O banco convertido de {s} não foi salvo. Salvar antes de sair?", "La base de datos convertida de {s} no se guardó. ¿Guardar antes de salir?" },
        .{ "btn_back", "Back", "Voltar", "Volver" },
        .{ "log_discarded", "SQLite converted from {s} discarded", "SQLite convertido de {s} descartado", "SQLite convertido de {s} descartado" },
        .{ "export_run_text", "Exiting cancels the export of {s}.", "Sair cancela a exportação de {s}.", "Salir cancela la exportación de {s}." },
        .{ "copy_name", "{s} (copy)", "{s} (cópia)", "{s} (copia)" },
        .{ "about_write", "Writing", "Gravação", "Escritura" },
        .{ "menu_open_typed", "Open the typed path", "Abrir o caminho digitado", "Abrir la ruta escrita" },
        .{ "menu_save_as", "Save as...", "Salvar como...", "Guardar como..." },
    };
    inline for (want) |w| {
        inline for (0..3) |l| try t.expectEqualStrings(w[l + 1], @field(catalogs[l], w[0]));
    }
    // sem Title Case nas frases (so a primeira letra maiuscula)
    inline for (catalogs) |C| {
        inline for (.{ "search", "find_column", "menu_search_scope", "copy_row_header", "show_all_columns" }) |k| {
            const s: []const u8 = @field(C, k);
            var it = std.mem.tokenizeScalar(u8, s, ' ');
            _ = it.next();
            while (it.next()) |word| try t.expect(!std.ascii.isUpper(word[0]) or std.mem.eql(u8, word, "NULL"));
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
    const allowed_lines = [_][]const u8{ "c.failed", "c.skip(", "c.note(","sql.appendSlice(", "@import(", "extern ", "\\x00*.", "--file-filter=", "segoeui", "consola.ttf", "copyZ(&app.sql", "SQLite format 3", "env.get(" };
    const allowed = [_][]const u8{ "GLFW {d}.{d}.{d} + OpenGL 3.3", "DuckDB {s}", "#version 330", "X11 (DISPLAY={s}: {t})", "Ctrl+O", "Ctrl+L", "Ctrl+C", "Ctrl+Q", "Ctrl+S", "Ctrl+Shift+S", "Ctrl+W", "F5" };
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
            for ([_][]const u8{ "Copyright", "(C) 20", "Remember to", "Please", "Make sure", "Lembre", "Por favor", "Verifique", "Recuerde", "Asegúrese" }) |bad|
                try t.expect(std.ascii.findIgnoreCase(s, bad) == null);
            // setas sao Unicode (→ ←), nunca "->", "< " ou " >"
            try t.expect(std.mem.indexOf(u8, s, "->") == null and !std.mem.startsWith(u8, s, "< ") and !std.mem.endsWith(u8, s, " >"));
        }
        // mensagens do app sem "..." (o log e a barra de status mostram estas)
        inline for (.{ "busy_converting", "busy_opening", "busy_loading", "busy_running", "busy_exporting", "log_discarded", "status_loaded", "status_closed" }) |k|
            try t.expect(std.mem.indexOf(u8, @field(C, k), "...") == null);
    }
}

test "Data tab count line under the grid: shown of all rows, or of the rows found; plural by the count" {
    defer lang = .en;
    var b: [160]u8 = undefined;
    lang = .pt_br;
    try t.expectEqualStrings("Tipos: mostrando 3 de 3 linhas", fmtCount(&b, "rows_showing", 3, .{ "Tipos", 3, 3 }));
    try t.expectEqualStrings("Tipos: mostrando 1 de 1 linha", fmtCount(&b, "rows_showing", 1, .{ "Tipos", 1, 1 }));
    try t.expectEqualStrings("Medições: mostrando 1 de 1 linha encontrada", fmtCount(&b, "rows_found", 1, .{ "Medições", 1, 1 }));
    try t.expectEqualStrings("T: mostrando 100 de 604 linhas encontradas", fmtCount(&b, "rows_found", 604, .{ "T", 100, 604 }));
    lang = .es;
    try t.expectEqualStrings("T: mostrando 0 de 0 filas", fmtCount(&b, "rows_showing", 0, .{ "T", 0, 0 }));
    // Todas as tabelas
    lang = .pt_br;
    try t.expectEqualStrings("1 tabela com linhas que contêm \"campo\"", fmtCount(&b, "global_found", 1, .{ 1, "campo" }));
    try t.expectEqualStrings("3 tabelas com linhas que contêm \"ELSUL\"", fmtCount(&b, "global_found", 3, .{ 3, "ELSUL" }));
}

test "tr and fmt follow the current language" {
    defer lang = .en;
    var b: [128]u8 = undefined;
    lang = .en;
    try t.expectEqualStrings("File", tr("menu_file"));
    try t.expectEqualStrings("3 of 7 shown", fmt(&b, "columns_shown", .{ 3, 7 }));
    try t.expectEqualStrings("Columns of Tipos", fmt(&b, "columns_title", .{"Tipos"}));
    lang = .pt_br;
    try t.expectEqualStrings("Arquivo", tr("menu_file"));
    try t.expectEqualStrings("3 de 7 visíveis", fmt(&b, "columns_shown", .{ 3, 7 }));
    try t.expectEqualStrings("Colunas de Tipos", fmt(&b, "columns_title", .{"Tipos"}));
    lang = .es;
    try t.expectEqualStrings("Archivo", tr("menu_file"));
    try t.expectEqualStrings("3 de 7 visibles", fmt(&b, "columns_shown", .{ 3, 7 }));
    try t.expectEqualStrings("Columnas de Tipos", fmt(&b, "columns_title", .{"Tipos"}));
}
