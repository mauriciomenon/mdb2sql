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
// Titulo com o arquivo aberto (o do Python): "<arquivo> - mdb2sql 1.3.0 - Zig"; sem arquivo, window_title
pub fn windowTitleFor(buf: []u8, file_name: []const u8) [:0]const u8 {
    if (file_name.len == 0) return window_title;
    return std.fmt.bufPrintSentinel(buf, "{s} - " ++ window_title, .{file_name}, 0) catch window_title;
}

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
    // com arquivo aberto o nome vem antes; sem arquivo, so o titulo
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings("mdb2sql_test.mdb - mdb2sql 1.3.0 - Zig", windowTitleFor(&b, "mdb2sql_test.mdb"));
    try std.testing.expectEqualStrings("mdb2sql 1.3.0 - Zig", windowTitleFor(&b, ""));
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqualStrings("mdb2sql 1.3.0 - Zig", windowTitleFor(&tiny, "um nome longo demais.accdb"));
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
    // o botao e o menu Arquivo > Exportar usam a mesma lista exportItems; o banco inteiro saiu dela (Arquivo > Salvar)
    try std.testing.expectEqual(2, std.mem.count(u8, ui, "app.exportItems()"));
    try std.testing.expect(std.mem.indexOf(u8, ui, "export_db_") == null);
    for ([_][]const u8{ "Copyright", "(C) 20", "read-only\")", "not available\")", "any order, ignores", "Remember", "Please ", "Make sure" }) |bad| {
        try std.testing.expect(std.mem.indexOf(u8, ui, bad) == null);
    }
}

// Itens de menu (chaves do catalogo) na ordem em que aparecem em main.zig a partir de `start`
fn expectOrder(comptime start: []const u8, keys: []const []const u8) !void {
    const ui = @embedFile("main.zig");
    const from = std.mem.indexOf(u8, ui, start) orelse return error.MenuNotFound;
    var last: usize = from;
    for (keys) |k| {
        const at = std.mem.indexOfPos(u8, ui, last, k) orelse {
            std.debug.print("{s} not after {s}\n", .{ k, start });
            return error.WrongOrder;
        };
        last = at;
    }
}

test "cell menu as in Go: value filters, then copy value, row and row with header; no copy option" {
    try expectOrder("igBeginPopup(\"##copy\"", &.{ "tr(\"filter_by_value\")", "tr(\"clear_filters\")", "tr(\"copy_value\")", "tr(\"copy_row\")", "tr(\"copy_row_header\")" });
    // a caixa "Copiar linha com o cabecalho" e a opcao dela em Configuracoes sairam
    try std.testing.expect(std.mem.indexOf(u8, @embedFile("main.zig"), "copy_header") == null);
}

test "header menu as in Rust: fit, fit all, hide, Columns..., show all, then the column list" {
    try expectOrder("igBeginPopup(\"##header\"", &.{ "tr(\"fit_column\")", "tr(\"fit_all_columns\")", "tr(\"hide_column\")", "tr(\"columns_button\")", "tr(\"show_all_columns\")", "for (g.columns[0..n_cols]" });
}

test "All tables result: the count line and the list \"table (n)\" (Python and Rust), not a 2-column table" {
    try std.testing.expect(std.mem.indexOf(u8, @embedFile("main.zig"), "igBeginTable(\"##global\"") == null);
    try expectOrder("fn drawGlobal(", &.{ "\"global_found\"", "\"{s} ({d})\"" });
}

test "Data tab below the search (standard 24): filters line, grid, then the count line with the pages (item 13 h)" {
    try expectOrder("fn drawData(", &.{ "tr(\"rows_label\")", "tr(\"columns_button\")", "tr(\"filters_label\")", "drawGrid(\"##data\"", "\"rows_page_found\"", "\"rows_page\"", "tr(\"page_prev\")", "tr(\"page_next\")" });
    const ui = @embedFile("main.zig");
    for ([_][]const u8{ "tr(\"prev\")", "tr(\"next\")", "page_line" }) |gone| try std.testing.expect(std.mem.indexOf(u8, ui, gone) == null);
}

test "item 13 f: every button has the height of its line (none taller to show hierarchy) and the default padding" {
    const ui = @embedFile("main.zig");
    var it = std.mem.splitSequence(u8, ui, "ig.igButton(");
    _ = it.next();
    var n: usize = 0;
    while (it.next()) |rest| : (n += 1) {
        const line = rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len];
        try std.testing.expect(std.mem.indexOf(u8, line, ".y = 0 }") != null);
    }
    try std.testing.expect(n > 5);
    // os segmentos tem a altura do quadro; o preenchimento so muda na caixa de marcar da grade
    try std.testing.expect(std.mem.indexOf(u8, ui, ".y = ig.igGetFrameHeight() }, 0)) clicked = i;") != null);
    try std.testing.expectEqual(1, std.mem.count(u8, ui, "ImGuiStyleVar_FramePadding"));
}

test "item 17: Advanced Search starts in All tables, never the Data tab default scope; This table says where it searched" {
    const ui = @embedFile("main.zig");
    try std.testing.expect(std.mem.indexOf(u8, ui, "terms_scope: settings.SearchScope = .all,") != null);
    try std.testing.expect(std.mem.indexOf(u8, ui, "terms_scope = app.prefs.search_scope") == null);
    try std.testing.expect(std.mem.indexOf(u8, ui, "app.terms_scope = s;") == null);
    try expectOrder("fn drawTerms(", &.{ "\"terms_summary\"", "if (res.only) |ti|", "\"terms_only_in\"" });
}

test "item 14: top bar path | Open... | Export...: Open... opens the file dialog, Enter goes by the typed path rule; no Browse" {
    try expectOrder("// Barra superior (item 14)", &.{ "\"##path\"", "app.openTyped();", "if (button(tr(\"open\"))) app.want_browse = true;", "tr(\"export_button\")" });
    try expectOrder("fn openTyped(", &.{ ".pick => app.want_browse = true", ".not_found => app.status.set(true, \"err_file_not_found\"", ".open => app.want_open = true" });
    try std.testing.expect(std.mem.indexOf(u8, @embedFile("main.zig"), "tr(\"browse\")") == null);
    // F5 e Arquivo > Reabrir sem arquivo aberto: a caixa de escolher arquivo (o item do menu fica habilitado)
    try expectOrder("if (app.want_refresh) {", &.{ "app.want_open = true;", "} else app.want_browse = true;" });
    try expectOrder("tr(\"menu_reopen\"), \"F5\", false, !app.opening())", &.{"app.want_refresh = true;"});
}

test "File menu (item 28: Open..., Open the typed path, Reopen, Save, Save as..., Export, Close, Exit) and the shortcuts" {
    try expectOrder("if (ig.igBeginMenu(file_l", &.{ "tr(\"menu_open\"), \"Ctrl+O\"", "tr(\"menu_open_typed\")", "tr(\"menu_reopen\"), \"F5\"", "igSeparator", "tr(\"menu_save\"), \"Ctrl+S\"", "tr(\"menu_save_as\"), \"Ctrl+Shift+S\"", "igBeginMenu(export_l", "igSeparator", "tr(\"menu_close\"), \"Ctrl+W\"", "igSeparator", "tr(\"menu_exit\"), \"Ctrl+Q\"" });
    try expectOrder("const chord = ig.igIsKeyChordPressed_Nil;", &.{ "ImGuiKey_O)", "ImGuiKey_L)", "ImGuiKey_Q)", "ImGuiKey_S)", "ImGuiMod_Shift | ig.ImGuiKey_S)", "ImGuiKey_W)", "ImGuiKey_F)", "ImGuiKey_F5,", "ImGuiKey_1)", "ImGuiKey_2)", "ImGuiKey_3)", "ImGuiKey_Enter)" });
}

test "exit question (item 27): Save on the left, Back and Exit on the right; no Remember for this session" {
    try expectOrder("fn drawExit(", &.{ "\"exit_text\"", "tr(\"btn_save\")", "tr(\"btn_back\")", "tr(\"btn_exit\")", "igButton(save_l", "igButton(back_l", "igButton(exit_l" });
    const ui = @embedFile("main.zig");
    for ([_][]const u8{ "converted_remember", "session_choice", "requestLeave" }) |gone| try std.testing.expect(std.mem.indexOf(u8, ui, gone) == null);
}

test "About as in Rust (Build, Stack, Window, Databases, Access reading, Author, License, links), titled About mdb2sql" {
    const pt = i18n.catalogs[1];
    try std.testing.expectEqualStrings("Sobre o mdb2sql", pt.about_title);
    inline for (.{ .{ "about_build", "Build" }, .{ "about_stack", "Stack" }, .{ "about_window", "Janela" }, .{ "about_database", "Bancos" }, .{ "about_access", "Leitura do Access" }, .{ "about_author", "Autor" }, .{ "about_license", "Licença" } }) |p|
        try std.testing.expectEqualStrings(p[1], @field(pt, p[0]));
    // item 28: a linha Gravacao logo depois de Leitura do Access
    try expectOrder("fn drawAbout(", &.{ "tr(\"about_build\")", "tr(\"about_stack\")", "tr(\"about_window\")", "tr(\"about_database\")", "tr(\"about_access\")", "tr(\"about_write\")", "tr(\"about_author\")", "tr(\"about_license\")", "about.links" });
    try std.testing.expectEqualStrings("Gravação", pt.about_write);
}

test "Terms tab (item 32), top to bottom: box, matching, scope, button and count, summary, tables and grid, not found" {
    try expectOrder("fn drawTerms(", &.{ "\"##terms\"", "tr(\"terms_hint\")", "tr(\"match_whole\")", "tr(\"match_contains\")", "tr(\"match_tip\")", "tr(\"scope_table\")", "tr(\"scope_all\")", "tr(\"terms_run\")", "\"terms_count\"", "\"terms_summary\"", "\"##terms_tables\"", "drawGrid(\"##termsgrid\"", "\"rows_showing\"", "\"not_found_title\"", "tr(\"copy\")", "\"##notfound\"" });
    // a aba nova vem depois da SQL; Ctrl+4 a abre
    try expectOrder("fn drawContent(", &.{ "\"tab_data\"", "\"tab_schema\"", "\"tab_sql\"", "\"tab_terms\"" });
    try expectOrder("const chord = ig.igIsKeyChordPressed_Nil;", &.{ "ImGuiKey_3)", "ImGuiKey_4)" });
}

test "menus of item 28: the fixed Export list, Edit, View and Settings in the brief's order; menu bar File, Edit, View, Settings, Help" {
    try expectOrder("fn exportItems(", &.{ "tr(\"export_table\")", "tr(\"export_marked\")", "tr(\"export_schema\")", "tr(\"export_dbschema\")", "tr(\"export_all_csv\")", "tr(\"export_result\")", "tr(\"export_global\")", "termsReportMenu(" });
    try expectOrder("fn formatMenu(", &.{ "tr(\"fmt_csv\")", "tr(\"fmt_xlsx\")" });
    try expectOrder("fn termsReportMenu(", &.{ "tr(\"fmt_xlsx\")", "tr(\"fmt_csv\")", "tr(\"fmt_sqlite\")", "tr(\"fmt_duckdb\")" });
    try expectOrder("if (ig.igBeginMenu(edit_l", &.{ "tr(\"copy_value\"), \"Ctrl+C\"", "tr(\"copy_row\"), \"Ctrl+Shift+C\"", "tr(\"copy_row_header\")", "tr(\"menu_copy_log\")", "igSeparator", "tr(\"menu_search\"), \"Ctrl+F\"", "tr(\"filter_by_value\")", "tr(\"clear_filters\")", "igSeparator", "tr(\"menu_mark\"), tr(\"key_space\")", "tr(\"menu_unmark_all\")" });
    try expectOrder("if (ig.igBeginMenu(view_l", &.{ "tr(\"tab_data\"), \"Ctrl+1\"", "tr(\"tab_schema\"), \"Ctrl+2\"", "tr(\"tab_sql\"), \"Ctrl+3\"", "tr(\"tab_terms\"), \"Ctrl+4\"", "igSeparator", "\"rows_label\"", "tr(\"columns_button\")", "\"menu_search_in\"", "tr(\"menu_only_marked\")", "tr(\"menu_goto_tables\"), \"Ctrl+T\"", "tr(\"fav_toggle\"), \"Ctrl+D\"", "igSeparator", "tr(\"menu_run_sql\"), \"Ctrl+Enter\"", "tr(\"terms_run\"), \"Ctrl+Enter\"", "igSeparator", "tr(\"menu_log\"), \"Ctrl+L\"" });
    try expectOrder("if (ig.igBeginMenu(settings_l", &.{ "\"menu_theme\"", "igBeginMenu(lang_l", "\"menu_search_scope\"", "\"menu_term_match\"", "tr(\"menu_show_null\")" });
    try expectOrder("fn drawMenu(", &.{ "igBeginMenu(file_l", "igBeginMenu(edit_l", "igBeginMenu(view_l", "igBeginMenu(settings_l", "igBeginMenu(help_l" });
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
