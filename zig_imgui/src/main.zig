// GUI Dear ImGui (cimgui + GLFW + OpenGL3): abre .accdb/.mdb/.sqlite/.duckdb, lista tabelas, pagina dados,
// roda SQL e exporta (banco inteiro, tabela ou resultado) para SQLite, DuckDB, Excel e CSV.
// Todo texto da tela vem dos catalogos de idioma (src/lang/*.zig, via i18n.tr/fmt).
// !T: Same core flows as python_pyqt6 (load database -> pick table -> grid), plus paging, free SQL and exports

const std = @import("std");
const ig = @import("cimgui");
const glfw = @import("zglfw");
const dbm = @import("db");
const dialog = @import("dialog.zig");
const platform = @import("platform.zig");
const build_options = @import("build_options");
const query = dbm.query;
const worker = dbm.worker;
const settings = dbm.settings;
const access = dbm.access;
const i18n = dbm.i18n;
const tr = i18n.tr;
const ExportKind = worker.ExportKind;
const glcc = platform.glcc;

extern fn glfwGetVersion(major: *c_int, minor: *c_int, rev: *c_int) void;

// Backends do ImGui (imgui_impl_glfw/opengl3, compilados com IMGUI_IMPL_API=extern "C")
extern fn ImGui_ImplGlfw_InitForOpenGL(window: *anyopaque, install_callbacks: bool) bool;
extern fn ImGui_ImplGlfw_NewFrame() void;
extern fn ImGui_ImplGlfw_Shutdown() void;
extern fn ImGui_ImplOpenGL3_Init(glsl_version: [*:0]const u8) bool;
extern fn ImGui_ImplOpenGL3_NewFrame() void;
extern fn ImGui_ImplOpenGL3_RenderDrawData(draw_data: ?*anyopaque) void;
extern fn ImGui_ImplOpenGL3_Shutdown() void;

// src/shim.c: campos de structs que o translate-c deixa opacos
extern fn shim_io_setup() void;
extern fn shim_add_font(path: [*:0]const u8, size_pixels: f32) ?*ig.ImFont;
extern fn shim_merge_glyphs(path: [*:0]const u8, size_pixels: f32, ranges: [*]const ig.ImWchar) ?*ig.ImFont;
// juntados da fonte de simbolos: setas das paginas da aba Dados e a estrela das favoritas (pares inicio-fim, 0 no fim)
const symbol_glyphs = [_]ig.ImWchar{ 0x25B6, 0x25B6, 0x25C0, 0x25C0, 0x2605, 0x2605, 0 };
extern fn shim_clipper_range(clipper: *const ig.ImGuiListClipper, start: *c_int, end: *c_int) void;
extern fn shim_capture_setup() void;
extern fn shim_capture_frame(w: f32, h: f32) void;
extern fn shim_key(key: c_int, down: bool) void;

fn glProc(comptime T: type, name: [*:0]const u8) !T {
    return @ptrCast(glfw.getProcAddress(name) orelse return error.APIUnavailable);
}

// As poucas funcoes do OpenGL que o programa chama (o backend do ImGui carrega as dele); pelo GLFW, igual no
// Windows e no Linux
const Gl = struct {
    viewport: *const fn (c_int, c_int, c_int, c_int) callconv(glcc) void,
    clearColor: *const fn (f32, f32, f32, f32) callconv(glcc) void,
    clear: *const fn (c_uint) callconv(glcc) void,
    readPixels: *const fn (c_int, c_int, c_int, c_int, c_uint, c_uint, [*]u8) callconv(glcc) void,

    fn load() !Gl {
        return .{
            .viewport = try glProc(@FieldType(Gl, "viewport"), "glViewport"),
            .clearColor = try glProc(@FieldType(Gl, "clearColor"), "glClearColor"),
            .clear = try glProc(@FieldType(Gl, "clear"), "glClear"),
            .readPixels = try glProc(@FieldType(Gl, "readPixels"), "glReadPixels"),
        };
    }
};
var gl: Gl = undefined;

// --capture (auxiliar de teste, fora da UI): a interface e desenhada num framebuffer proprio do tamanho de cada
// passo e lida com glReadPixels; a janela fica invisivel e o mouse desligado
const Fbo = struct {
    genFramebuffers: *const fn (c_int, *c_uint) callconv(glcc) void,
    bindFramebuffer: *const fn (c_uint, c_uint) callconv(glcc) void,
    genRenderbuffers: *const fn (c_int, *c_uint) callconv(glcc) void,
    bindRenderbuffer: *const fn (c_uint, c_uint) callconv(glcc) void,
    renderbufferStorage: *const fn (c_uint, c_uint, c_int, c_int) callconv(glcc) void,
    framebufferRenderbuffer: *const fn (c_uint, c_uint, c_uint, c_uint) callconv(glcc) void,
    checkFramebufferStatus: *const fn (c_uint) callconv(glcc) c_uint,
    fb: c_uint = 0,
    rb: c_uint = 0,
    w: u32 = 0,
    h: u32 = 0,

    fn load() !Fbo {
        return .{
            .genFramebuffers = try glProc(@FieldType(Fbo, "genFramebuffers"), "glGenFramebuffers"),
            .bindFramebuffer = try glProc(@FieldType(Fbo, "bindFramebuffer"), "glBindFramebuffer"),
            .genRenderbuffers = try glProc(@FieldType(Fbo, "genRenderbuffers"), "glGenRenderbuffers"),
            .bindRenderbuffer = try glProc(@FieldType(Fbo, "bindRenderbuffer"), "glBindRenderbuffer"),
            .renderbufferStorage = try glProc(@FieldType(Fbo, "renderbufferStorage"), "glRenderbufferStorage"),
            .framebufferRenderbuffer = try glProc(@FieldType(Fbo, "framebufferRenderbuffer"), "glFramebufferRenderbuffer"),
            .checkFramebufferStatus = try glProc(@FieldType(Fbo, "checkFramebufferStatus"), "glCheckFramebufferStatus"),
        };
    }

    // Deixa ligado um framebuffer RGBA8 de w x h (refeito quando o tamanho muda)
    fn use(f: *Fbo, w: u32, h: u32) !void {
        const framebuffer = 0x8D40;
        const renderbuffer = 0x8D41;
        if (f.fb == 0) {
            f.genFramebuffers(1, &f.fb);
            f.genRenderbuffers(1, &f.rb);
        }
        f.bindFramebuffer(framebuffer, f.fb);
        if (f.w == w and f.h == h) return;
        f.bindRenderbuffer(renderbuffer, f.rb);
        f.renderbufferStorage(renderbuffer, 0x8058, @intCast(w), @intCast(h)); // GL_RGBA8
        f.framebufferRenderbuffer(framebuffer, 0x8CE0, renderbuffer, f.rb); // GL_COLOR_ATTACHMENT0
        if (f.checkFramebufferStatus(framebuffer) != 0x8CD5) return error.APIUnavailable; // GL_FRAMEBUFFER_COMPLETE
        f.w = w;
        f.h = h;
    }
};

// Roteiro de --capture (dbm.capture.plan): cada passo pede um estado, espera o trabalho acabar e alguns quadros
// para o layout assentar, e grava o PNG. Passo sem o que precisa (coluna, tabela ou Access convertido que o
// banco nao tem) e pulado e listado em <pasta>/capture_skipped.txt.
const Capture = struct {
    out_dir: []const u8,
    fbo: Fbo,
    step: usize = 0,
    applied: bool = false,
    settle: u32 = 0,
    since: f64 = 0, // igGetTime() do 1o quadro ocioso do passo
    failed: ?[]const u8 = null,
    skipped: std.ArrayList(u8) = .empty,
    deleted_tmp: ?access.TempPath = null, // passo final: o temporario que tem de sumir
    // MDB2SQL_CAPTURE_SAVE=sqlite|duckdb|xlsx: o passo final salva (sem a caixa, na pasta das capturas) antes de fechar
    save_type: ?dialog.SaveType = null,
    saved_path: ?[]const u8 = null, // Salvar: o arquivo que tem de existir (do gpa)
    esc_frames: u32 = 0, // passo exit_esc: quadros desde o pedido de saida; Esc solto aos 12
    wrong: std.ArrayList(u8) = .empty, // conferencias que falharam (a captura segue; saida 2 no fim)
    hidden_before: usize = 0, // click_cell: colunas ocultas antes do clique
    cleared: bool = false, // global_clear: o termo foi apagado com a busca rodando
    hit_rows: u64 = 0, // open_hit: linhas que a busca global listou para a tabela
    release_key: ?c_int = null, // passos key_*: tecla apertada, solta no quadro seguinte
    source_path: [1024:0]u8 = @splat(0), // prompt_delete: o Access de origem (reopen_saved abre de novo)
    pending_mark: bool = false, // search_mark: a busca rodou, falta marcar a 1a linha nao marcada
    terms_phase: u8 = 0, // terms: 1 = pesquisando; 2 = RANGER_SOSTAT escolhida na lista
    terms_file: []const u8 = "", // MDB2SQL_CAPTURE_TERMS: a lista colada na aba Termos
    terms_report: std.ArrayList(u8) = .empty, // capture_terms.txt
    dialog: bool = false, // MDB2SQL_CAPTURE_DIALOG=1: o passo save_dialog abre a caixa nativa
    log_mark: usize = 0, // prompt_delete: tamanho do Log antes de Fechar
    only: []const u8 = "", // MDB2SQL_CAPTURE_ONLY: comecos de nome dos passos que rodam (vazio = todos)

    fn wanted(only: []const u8, name: []const u8) bool {
        var it = std.mem.tokenizeScalar(u8, only, ',');
        while (it.next()) |prefix| if (std.mem.startsWith(u8, name, prefix)) return true;
        return false;
    }

    fn size(c: *const Capture) [2]u32 {
        const s = dbm.capture.plan[@min(c.step, dbm.capture.plan.len - 1)];
        return .{ s.w, s.h };
    }

    // Nada rodando nem pedido, banco aberto com uma tabela: pronto para o proximo estado
    fn ready(app: *const App) bool {
        if (app.slot.busy() or app.want_open or app.want_reload or app.want_run or app.want_select != null or app.want_global or
            app.search_wait.due != null or app.want_filter != null or app.want_unfilter != null or app.want_clear_filters or
            app.want_close or app.want_save != null or app.want_mark != null or app.want_unmark_all or
            app.want_terms or app.want_terms_page != null or app.want_terms_copy) return false;
        return app.db.isOpen() and app.selected != null;
    }

    // O estado pedido pelo passo ja esta na tela (o passo Fechar termina sem banco aberto)
    fn settled(c: *const Capture, app: *const App) bool {
        switch (dbm.capture.plan[c.step].action) {
            // saida pedida, pergunta aberta, Esc: a pergunta fecha e o programa continua aberto
            .exit_esc => return c.esc_frames > 14 and app.exit_ask == null and !app.quit and ready(app),
            .prompt => return app.exit_ask == .unsaved and !app.slot.busy(),
            .prompt_delete => return !app.slot.busy() and !app.want_close and !app.db.isOpen() and app.converted == null,
            .search_mark => return !c.pending_mark and ready(app),
            .terms => return c.terms_phase == 2 and ready(app),
            else => return ready(app),
        }
    }

    // Passos de duas fases: depois da busca, marca a 1a linha nao marcada; depois da pesquisa de termos, escolhe a
    // tabela RANGER_SOSTAT na lista
    fn secondPhase(c: *Capture, app: *App) void {
        if (!c.applied or !ready(app)) return;
        if (c.pending_mark) {
            c.pending_mark = false;
            const rows = if (app.data) |g| g.rows.len else 0;
            if (app.marked_top < rows) app.want_mark = app.marked_top else c.note(app.gpa, "the search found no row to mark");
        }
        if (c.terms_phase == 1) {
            c.terms_phase = 2;
            const res = app.terms_res orelse return c.note(app.gpa, "the term search gave no result");
            for (res.tables, 0..) |hit, i| if (std.mem.eql(u8, app.db.table_names[hit.table], dbm.capture.first_table)) {
                if (i != app.terms_hit) app.want_terms_page = i;
            };
        }
    }

    // capture_terms.txt: o resumo, o tempo, as tabelas com acerto, os nao encontrados e as linhas de RANGER_SOSTAT
    fn recordTerms(c: *Capture, app: *const App, how: []const u8) void {
        const res = app.terms_res orelse return;
        const rep = &c.terms_report; // texto do --capture (auxiliar de teste)
        const a = app.gpa;
        var sb: [3][96]u8 = undefined;
        var summary: [400]u8 = undefined;
        rep.print(a, "[{s}] {s}\r\ntempo: {d:.2} s\r\ntabelas:", .{ how, i18n.fmt(&summary, "terms_summary", .{
            i18n.fmtCount(&sb[0], "terms_found", res.terms.len, .{ res.found, res.terms.len }),
            i18n.fmtCount(&sb[1], "terms_rows", res.rows, .{res.rows}),
            i18n.fmtCount(&sb[2], "terms_tables", res.tables.len, .{res.tables.len}),
        }), app.terms_seconds }) catch return;
        for (res.tables) |hit| rep.print(a, " {s} ({d});", .{ app.db.table_names[hit.table], hit.rows }) catch return;
        rep.print(a, "\r\nnao encontrados: {s}\r\n", .{res.not_found}) catch return;
        const g = app.terms_grid orelse return;
        if (app.terms_hit >= res.tables.len) return;
        rep.print(a, "{s}:\r\n", .{app.db.table_names[res.tables[app.terms_hit].table]}) catch return;
        // Termo e as colunas que identificam o ponto
        var picks: [4]?usize = .{ 0, null, null, null };
        for (g.columns, 0..) |col, i| for ([_][]const u8{ "RTUNO", "PNTNO", "SUBNAM" }, 1..) |want, k| {
            if (std.ascii.eqlIgnoreCase(col, want)) picks[k] = i;
        };
        for (g.rows) |row| {
            for (picks, 0..) |p, k| if (p) |i| rep.print(a, "{s}{s}", .{ if (k > 0) " | " else "  ", row[i] orelse "" }) catch return;
            rep.appendSlice(a, "\r\n") catch return;
        }
        rep.appendSlice(a, "\r\n") catch {};
    }

    fn skip(c: *Capture, gpa: std.mem.Allocator, why: []const u8) void {
        c.skipped.print(gpa, "{s}: {s}\n", .{ dbm.capture.plan[c.step].name, why }) catch {};
        c.step += 1;
        c.applied = false;
    }

    // Antes de app.update(): pede o estado do passo atual quando nada esta rodando
    fn before(c: *Capture, app: *App) void {
        // tecla do passo anterior: solta (o atalho ja foi visto no quadro em que foi apertado)
        if (c.release_key) |k| {
            shim_key(k, false);
            shim_key(ig.ImGuiMod_Ctrl, false);
            c.release_key = null;
        }
        c.secondPhase(app);
        // global_clear: o termo e apagado com a busca rodando, como o usuario apagando a caixa
        if (c.applied and c.step < dbm.capture.plan.len and dbm.capture.plan[c.step].action == .global_clear and
            !c.cleared and app.slot.busyWith(.search_all))
        {
            c.cleared = true;
            app.search[0] = 0;
            app.search_wait.edited(ig.igGetTime());
        }
        while (true) {
            if (c.step == dbm.capture.plan.len or c.applied) return;
            // MDB2SQL_CAPTURE_ONLY=u_,v_: so os passos que comecam assim (medicao rapida); os outros nem rodam
            if (c.only.len > 0 and !wanted(c.only, dbm.capture.plan[c.step].name)) {
                c.step += 1;
                continue;
            }
            // reopen_saved comeca com o arquivo fechado (depois do Salvar)
            if (dbm.capture.plan[c.step].action == .reopen_saved) {
                if (app.slot.busy() or app.exit_ask != null) return;
                if (c.apply(app)) return;
                continue;
            }
            if (!app.slot.busy() and !app.want_open and !app.db.isOpen()) {
                c.failed = "the database did not open";
                return;
            }
            if (!ready(app)) return;
            if (c.apply(app)) return;
        }
    }

    // Atalho de teclado de verdade: o ImGui ve a tecla no proximo quadro; before() solta no seguinte
    fn press(c: *Capture, ctrl: bool, key: c_int) void {
        if (ctrl) shim_key(ig.ImGuiMod_Ctrl, true);
        shim_key(key, true);
        c.release_key = key;
    }

    // true = estado pedido; false = passo pulado (o laco tenta o proximo)
    fn apply(c: *Capture, app: *App) bool {
        const cap = dbm.capture;
        const action = cap.plan[c.step].action;
        // cada passo comeca sem os dialogos e menus do passo anterior, na aba Dados (os de SQL na aba SQL; os de
        // atalho na aba em que estao)
        if (action != .about) app.about_open = false;
        if (action != .export_ask) app.ask_export = null;
        app.close_popups = true;
        switch (action) {
            .sql_tab, .sql_error, .sql_write, .key_ctrl_enter => app.want_tab = .sql,
            .terms, .terms_show, .terms_empty => app.want_tab = .terms,
            .key_ctrl_1, .key_ctrl_2, .key_ctrl_f => {},
            else => app.want_tab = .data,
        }
        // so os passos de Log abrem o painel (a captura nao le nem grava as configuracoes)
        app.prefs.log_open = action == .log or action == .log_error_open;
        if (app.prefs.log_open) markLogRead();
        if (action != .prompt) app.exit_ask = null;
        if (action != .display_warning) app.display_dismiss = true;
        switch (action) {
            .exit_esc => {
                if (app.converted == null) {
                    c.skip(app.gpa, "not an Access file (no exit prompt)");
                    return false;
                }
                c.esc_frames = 0;
                c.press(true, ig.ImGuiKey_Q); // Sair pelo atalho Ctrl+Q
            },
            .export_ask => {
                if (app.applied_search[0] == 0 and app.filters.items.len == 0) {
                    c.skip(app.gpa, "no search or filter on the open table");
                    return false;
                }
                app.want_export = .table_csv;
            },
            .header_menu, .cell_menu => {
                if (app.col_names.len == 0 or app.data == null or app.data.?.rows.len == 0) {
                    c.skip(app.gpa, "the open table has no rows");
                    return false;
                }
                // a primeira coluna visivel (os passos de Colunas ocultam algumas)
                var col: usize = 0;
                while (col + 1 < app.col_names.len and app.data_sel.hidden.isSet(col)) col += 1;
                if (action == .header_menu) {
                    app.data_sel.header_col = col;
                    app.data_sel.popup_header = true;
                } else app.data_sel = .{ .row = 0, .col = col, .popup = true, .hidden = app.data_sel.hidden };
            },
            .file_menu => app.start_menu = .File,
            .export_menu => app.start_menu = .Export,
            .edit_menu => app.start_menu = .Edit,
            .view_menu => app.start_menu = .View,
            .table => {
                const i = indexOf(app.db.table_names, cap.plan[c.step].arg) orelse {
                    c.skip(app.gpa, "table not found");
                    return false;
                };
                if (app.selected != i) app.want_select = i;
            },
            .search_mark, .search_only => {
                // busca digitada na aba Dados (Esta tabela); search_mark marca depois a 1a linha nao marcada
                app.scope = .table;
                copyZ(&app.search, cap.plan[c.step].arg);
                app.runSearch();
                c.pending_mark = action == .search_mark;
            },
            .only_marked => {
                app.only_marked = true;
                app.reloadFirstPage();
            },
            .unmark_all => app.want_unmark_all = true,
            .page_next => {
                app.page += 1;
                app.want_reload = true;
            },
            .favorites => {
                // as 3 favoritas (as que o arquivo tiver) e o menu do clique direito na tabela aberta
                for (cap.fav_tables) |name| if (indexOf(app.db.table_names, name)) |i| {
                    if (!dbm.gridtools.isFavorite(app.favorites.items, name)) app.toggleFavorite(i);
                };
                app.fav_menu = app.selected;
            },
            .terms => {
                if (c.terms_file.len == 0) {
                    c.skip(app.gpa, "no term list (MDB2SQL_CAPTURE_TERMS=<file>)");
                    return false;
                }
                // a lista colada e a comparacao do passo; o escopo fica o de abertura da aba (Todas as tabelas, item 17)
                const text = std.Io.Dir.cwd().readFile(app.io, c.terms_file, app.terms_text[0 .. app.terms_text.len - 1]) catch {
                    c.skip(app.gpa, "the term list could not be read");
                    return false;
                };
                app.terms_text[text.len] = 0;
                app.countTerms();
                app.terms_match = if (std.mem.eql(u8, cap.plan[c.step].arg, "contains")) .contains else .whole;
                app.want_terms = true;
                c.terms_phase = 1;
            },
            .terms_show => if (app.terms_res == null) {
                c.skip(app.gpa, "no term search result");
                return false;
            },
            .save_dialog => {
                if (!c.dialog) {
                    c.skip(app.gpa, "the native save box blocks (MDB2SQL_CAPTURE_DIALOG=1 and a script that closes it)");
                    return false;
                }
                app.want_save = .save;
            },
            .sql_tab => {
                app.sql[0] = 0;
                app.clearResult();
                app.sql_msg.len = 0;
            },
            .sql_error => {
                copyZ(&app.sql, "SELEC 1");
                app.want_run = true;
            },
            .sql_write => {
                copyZ(&app.sql, cap.plan[c.step].arg);
                app.want_run = true;
            },
            .key_ctrl_enter => {
                copyZ(&app.sql, "SELECT 42 AS n");
                c.press(true, ig.ImGuiKey_Enter);
            },
            .key_ctrl_1 => c.press(true, ig.ImGuiKey_1),
            .key_ctrl_2 => c.press(true, ig.ImGuiKey_2),
            .key_ctrl_f => c.press(true, ig.ImGuiKey_F),
            .key_f5 => c.press(false, ig.ImGuiKey_F5),
            .reopen_saved => {
                if (c.save_type == null or c.save_type == .xlsx or c.source_path[0] == 0) {
                    c.skip(app.gpa, "the converted SQLite was not saved as SQLite or DuckDB (MDB2SQL_CAPTURE_SAVE=sqlite|duckdb)");
                    return false;
                }
                app.setPath(zstr(&c.source_path));
                app.want_open = true;
            },
            .display_warning => if (app.display_warning == null) {
                c.skip(app.gpa, "no display warning (X11 in use)");
                return false;
            },
            .show => {},
            .filter => {
                const col = indexOf(app.col_names, cap.filter_column) orelse {
                    c.skip(app.gpa, "column " ++ cap.filter_column ++ " not found");
                    return false;
                };
                const value = app.gpa.dupe(u8, cap.filter_value) catch {
                    c.failed = "out of memory";
                    return true;
                };
                app.want_filter = .{ .col = col, .value = value };
            },
            .columns => {
                // varias ocultas, como na captura (c)
                for ([_]usize{ 1, 4, 5, 6, 7 }) |i| if (i < app.col_names.len) app.data_sel.hidden.set(i);
                app.data_sel.open_columns = true;
            },
            .close_columns => app.data_sel.close_columns = true,
            .other_table => {
                const i = indexOf(app.db.table_names, cap.second_table) orelse {
                    c.skip(app.gpa, "table " ++ cap.second_table ++ " not found");
                    return false;
                };
                if (app.selected != i) app.want_select = i;
            },
            .about => app.want_about = true,
            .log, .log_error_open, .terms_empty => {},
            .log_error => {
                // erro de verdade (SQL errado) com o Log recolhido: a barra de status mostra o erro em destaque
                copyZ(&app.sql, "SELEC 1");
                app.want_run = true;
            },
            .settings_menu => app.start_menu = .Settings,
            .lang_en, .lang_pt_br, .lang_es => app.want_lang = switch (action) {
                .lang_pt_br => .pt_br,
                .lang_es => .es,
                else => .en,
            },
            .click_cell => {
                // o que o clique numa celula faz (a captura nao tem mouse)
                c.hidden_before = app.data_sel.hiddenCount(app.col_names.len);
                app.data_sel.pick(0, 0);
            },
            .global_late, .global_clear, .global => {
                if (action == .global_late and indexOf(app.db.table_names, cap.late_table) == null) {
                    c.skip(app.gpa, "table " ++ cap.late_table ++ " not found");
                    return false;
                }
                // termo digitado com o escopo Todas as tabelas
                app.scope = .all;
                copyZ(&app.search, if (action == .global_late) cap.late_term else cap.filter_value);
                app.runSearch();
                c.cleared = false;
            },
            .open_hit => {
                // o acerto da tabela aberta (que tem o filtro por valor do passo d_filter)
                const g = app.global orelse {
                    c.skip(app.gpa, "no global search result");
                    return false;
                };
                const hit = for (g.hits) |h| {
                    if (h.table == app.selected) break h;
                } else {
                    c.skip(app.gpa, "the open table is not in the global search result");
                    return false;
                };
                c.hit_rows = hit.rows;
                app.pickGlobal(hit.table, &g.term);
            },
            .reopen => {
                // (abrir de novo nao pergunta mais, nem com o Access convertido) filtro da lista de tabelas, busca e escopo diferentes do padrao; depois abre de novo o mesmo arquivo
                copyZ(&app.table_filter, "SOX");
                app.table_filter_applied = app.table_filter;
                copyZ(&app.search, cap.filter_value);
                app.scope = .all;
                app.setPath(zstr(&app.loaded_path));
                app.want_open = true;
            },
            .prompt, .prompt_delete => {
                const cv = app.converted orelse {
                    c.skip(app.gpa, "not an Access file (nothing was converted)");
                    return false;
                };
                c.source_path = cv.source;
                if (action == .prompt) {
                    // a pergunta ao sair (Ctrl+Q, X): Access convertido e nao salvo
                    app.requestExit();
                } else {
                    // Fechar: sem pergunta; o temporario some (descartado, ou salvo antes como na caixa de Salvar)
                    c.deleted_tmp = cv.tmp;
                    c.log_mark = session_log.slice().len; // a linha do descarte tem de vir depois daqui
                    if (c.save_type) |ty| {
                        var nb: [600]u8 = undefined;
                        const file = settings.fileName(&nb, std.fs.path.stem(zstr(&cv.source)), ty.ext());
                        c.saved_path = std.fs.path.join(app.gpa, &.{ c.out_dir, file }) catch null;
                        if (c.saved_path) |p| app.saveTo(p, ty);
                    }
                    app.want_close = true;
                }
            },
        }
        c.applied = true;
        return true;
    }

    // Depois de desenhar no framebuffer: grava o quadro quando o estado assentou; true = terminou
    fn after(c: *Capture, app: *App, io: std.Io) bool {
        if (c.failed == null and ig.igGetTime() > 900) c.failed = "timeout: the state did not settle in 15 minutes";
        if (c.failed != null or c.step == dbm.capture.plan.len) return true;
        if (c.applied and dbm.capture.plan[c.step].action == .exit_esc) {
            c.esc_frames += 1;
            if (c.esc_frames == 12) {
                if (app.exit_ask == null) c.failed = "the exit prompt did not open";
                shim_key(ig.ImGuiKey_Escape, true);
            }
            if (c.esc_frames == 13) shim_key(ig.ImGuiKey_Escape, false);
            if (c.esc_frames == 200 and app.exit_ask != null) c.failed = "Esc did not close the exit prompt";
            if (app.quit) c.failed = "Esc on the exit prompt closed the program";
        }
        if (!c.applied or !c.settled(app)) {
            c.settle = 0;
            return false;
        }
        c.settle += 1;
        if (c.settle == 1) c.since = ig.igGetTime();
        // popups, auto-ajuste das colunas e o escurecimento do fundo do modal levam alguns quadros e ~0,3 s
        if (c.settle < 8 or ig.igGetTime() - c.since < 0.5) return false;
        // Fechar: o temporario tem de ter sumido do disco; Salvar: o arquivo salvo e do tipo pedido
        if (c.deleted_tmp) |tmp| {
            if (std.Io.Dir.cwd().access(io, tmp.slice(), .{})) |_| {
                c.failed = "the temporary SQLite still exists after closing";
                return true;
            } else |_| {}
            c.deleted_tmp = null;
        }
        if (c.saved_path) |p| if (c.save_type) |ty| {
            var hb: [16]u8 = undefined;
            const head = std.Io.Dir.cwd().readFile(io, p, &hb) catch "";
            const ok = switch (ty) {
                .sqlite => std.mem.eql(u8, head, "SQLite format 3\x00"),
                .duckdb => head.len >= 12 and std.mem.eql(u8, head[8..12], "DUCK"),
                .xlsx => std.mem.startsWith(u8, head, &.{ 'P', 'K', 3, 4 }), // zip
            };
            if (!ok) {
                c.failed = "the saved file is missing or is not of the type saved";
                return true;
            }
        };
        c.check(app);
        c.save(app.gpa, io) catch |e| {
            c.failed = @errorName(e);
            return true;
        };
        c.step += 1;
        c.applied = false;
        c.settle = 0;
        return c.step == dbm.capture.plan.len;
    }

    // O que o estado assentado tem de mostrar; null = certo
    fn check(c: *Capture, app: *const App) void {
        const cap = dbm.capture;
        switch (cap.plan[c.step].action) {
            .click_cell => if (app.data_sel.hiddenCount(app.col_names.len) != c.hidden_before) c.note(app.gpa, "clicking a cell showed the hidden columns again"),
            .global_late => {
                const g = app.global orelse return c.note(app.gpa, "no global search result");
                for (g.hits) |h| if (std.mem.eql(u8, app.db.table_names[h.table], cap.late_table)) return;
                c.note(app.gpa, "the table after the 10,000th catalog column is missing from the result");
            },
            .global_clear => if (!c.cleared) c.note(app.gpa, "the search ended before the term could be cleared") else if (app.global != null) c.note(app.gpa, "the old result came back after the term was cleared"),
            .open_hit => if (app.filters.items.len > 0 or app.total != c.hit_rows) c.note(app.gpa, "the opened table does not show the row count listed"),
            .reopen => if (app.table_filter[0] != 0 or app.table_filter_applied[0] != 0 or app.search[0] != 0 or app.scope != app.prefs.search_scope)
                c.note(app.gpa, "the reopened file kept the table filter, the search or the scope"),
            .export_ask => if (app.ask_export == null) c.note(app.gpa, "the whole table / rows found question did not open"),
            .key_ctrl_1 => if (app.tab != .data) c.note(app.gpa, "Ctrl+1 did not show the Data tab"),
            .key_ctrl_2 => if (app.tab != .schema) c.note(app.gpa, "Ctrl+2 did not show the Schema tab"),
            .key_ctrl_f => if (app.tab != .data or app.focus_search) c.note(app.gpa, "Ctrl+F did not focus the Data search"),
            .sql_error => if (alert.len == 0 or !app.sql_msg.is_err) c.note(app.gpa, "the SQL error is not on the status bar"),
            .sql_write => if (!std.mem.eql(u8, app.sql_msg.text(), tr("sql_read_only")) or indexOf(app.db.table_names, cap.first_table) == null)
                c.note(app.gpa, "the SQL tab ran a statement that writes"),
            .key_ctrl_enter => if (app.result == null or alert.len > 0 or app.sql_msg.is_err) c.note(app.gpa, "Ctrl+Enter with a SQL that works did not clear the previous error"),
            .key_f5 => if (!app.db.isOpen() or !app.status.loaded) c.note(app.gpa, "F5 did not open the file again"),
            .reopen_saved => {
                if (app.converted != null or (app.source != .sqlite and app.source != .duckdb)) c.note(app.gpa, "the saved file was not reused (the Access file was converted again)");
                // a linha do Log diz o formato real do salvo
                const saved_as: dbm.Source = if (c.save_type == .duckdb) .duckdb else .sqlite;
                var lb: [2200]u8 = undefined;
                const line = i18n.fmt(&lb, "converted_reused", .{ std.fs.path.basename(zstr(&c.source_path)), saved_as.label(), c.saved_path orelse "" });
                if (std.mem.indexOf(u8, session_log.slice(), line) == null) c.note(app.gpa, "the Log line of the reused file does not say its format");
            },
            .search_only => if (app.marked_top != 3) c.note(app.gpa, "the 3 marked rows are not on top during another search"),
            .only_marked => if (app.data == null or app.data.?.rows.len != app.marksOf(app.selected).len) c.note(app.gpa, "Only marked does not show just the marked rows"),
            .unmark_all => if (app.marksOf(app.selected).len != 0 or app.only_marked) c.note(app.gpa, "Unmark all rows left marks"),
            // pagina 2 da tabela: as linhas depois das primeiras `limit`
            .page_next => if (app.page != 1 or app.data == null or app.data.?.rows.len == 0) c.note(app.gpa, "the next page of the Data tab did not load"),
            // as favoritas no topo da lista, em ordem alfabetica
            .favorites => {
                const order = app.table_order.items;
                const want = [_][]const u8{ "RANGER_SOEQID", "RANGER_SOSTAT", "RANGER_SOTEXT" };
                for (want, 0..) |name, k| if (k >= order.len or !std.mem.eql(u8, app.db.table_names[order[k]], name))
                    return c.note(app.gpa, "the favorite tables are not at the top in alphabetical order");
            },
            .terms => {
                c.recordTerms(app, cap.plan[c.step].arg);
                const res = app.terms_res orelse return;
                for (res.tables) |hit| {
                    if (std.mem.eql(u8, app.db.table_names[hit.table], cap.first_table)) break;
                } else c.note(app.gpa, "the term search did not find " ++ cap.first_table);
                // a grade da tabela escolhida mostra as linhas contadas (ate o limite de Linhas)
                const shown = if (app.terms_grid) |g| g.rows.len else 0;
                if (app.terms_hit < res.tables.len and shown != @min(res.tables[app.terms_hit].rows, app.limit))
                    c.note(app.gpa, "the grid of the chosen table does not show the rows counted");
                if (res.only != null) c.note(app.gpa, "the Advanced Search did not start in All tables");
            },
            // Fechar nao pergunta: o convertido nao salvo e descartado com a linha do Log
            .prompt_delete => {
                var lb: [1200]u8 = undefined;
                const line = i18n.fmt(&lb, "log_discarded", .{std.fs.path.basename(zstr(&c.source_path))});
                const log_now = session_log.slice();
                const logged = std.mem.indexOf(u8, log_now[@min(c.log_mark, log_now.len)..], line) != null;
                if (logged == (c.save_type != null)) c.note(app.gpa, "closing logged the discard wrongly (missing, or after saving)");
            },
            else => {},
        }
    }

    // Conferencia que falhou: listada em capture_error.txt, a captura continua
    fn note(c: *Capture, gpa: std.mem.Allocator, why: []const u8) void {
        c.wrong.print(gpa, "{s}: {s}\n", .{ dbm.capture.plan[c.step].name, why }) catch {};
    }

    fn save(c: *Capture, gpa: std.mem.Allocator, io: std.Io) !void {
        const w = c.fbo.w;
        const h = c.fbo.h;
        const pixels = try gpa.alloc(u8, @as(usize, w) * h * 4);
        defer gpa.free(pixels);
        gl.readPixels(0, 0, @intCast(w), @intCast(h), 0x1908, 0x1401, pixels.ptr); // GL_RGBA, GL_UNSIGNED_BYTE
        const png = try dbm.capture.encodePng(gpa, w, h, pixels);
        defer gpa.free(png);
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}.png", .{dbm.capture.plan[c.step].name});
        const path = try std.fs.path.join(gpa, &.{ c.out_dir, name });
        defer gpa.free(path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = png });
    }

    // Erro (ou as conferencias que falharam) vai para <pasta>/capture_error.txt (o exe de release do Windows nao tem
    // console); pulados em capture_skipped.txt
    fn report(c: *Capture, gpa: std.mem.Allocator, io: std.Io) void {
        defer c.skipped.deinit(gpa);
        defer c.wrong.deinit(gpa);
        defer c.terms_report.deinit(gpa);
        defer if (c.saved_path) |p| gpa.free(p);
        if (c.terms_report.items.len > 0) {
            const path = std.fs.path.join(gpa, &.{ c.out_dir, "capture_terms.txt" }) catch return;
            defer gpa.free(path);
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = c.terms_report.items }) catch {};
        }
        if (c.skipped.items.len > 0) {
            const path = std.fs.path.join(gpa, &.{ c.out_dir, "capture_skipped.txt" }) catch return;
            defer gpa.free(path);
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = c.skipped.items }) catch {};
        }
        const why = c.failed orelse if (c.wrong.items.len > 0) c.wrong.items else return;
        const path = std.fs.path.join(gpa, &.{ c.out_dir, "capture_error.txt" }) catch return;
        defer gpa.free(path);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = why }) catch {};
    }

    fn indexOf(names: anytype, want: []const u8) ?usize {
        for (names, 0..) |n, i| if (std.mem.eql(u8, n, want)) return i;
        return null;
    }
};

const app_title = dbm.about.window_title; // "mdb2sql <versao> - Zig": janela e caixas de mensagem

var main_io: ?std.Io = null; // para a caixa de mensagem do Linux (zenity) e para abrir links

// Abre no navegador padrao so os links fixos do Sobre (about.allowedLink); qualquer outro texto e ignorado
fn openLink(url: []const u8) void {
    const safe = dbm.about.allowedLink(url) orelse return;
    platform.openUrl(main_io orelse return, safe);
}

fn messageBox(text_utf8: []const u8, icon: platform.Icon) void {
    platform.messageBox(main_io, app_title, text_utf8, icon);
}

// Panico (checagem de seguranca do ReleaseSafe): mostra a mensagem antes de encerrar, em vez de sumir calado
pub const panic = std.debug.FullPanic(panicBox);

fn panicBox(msg: []const u8, ret_addr: ?usize) noreturn {
    var buf: [1200]u8 = undefined;
    messageBox(i18n.fmt(&buf, "err_internal", .{msg}), .err);
    std.debug.defaultPanic(msg, ret_addr);
}

// ------------------------------------------------------------------- tema

var light_theme = false;

const Color = struct { c_int, u24, f32 }; // ImGuiCol, 0xRRGGBB, alfa

const dark_colors = [_]Color{
    .{ ig.ImGuiCol_Text, 0xE6E8EB, 1 },                 .{ ig.ImGuiCol_TextDisabled, 0x8B929C, 1 },
    .{ ig.ImGuiCol_WindowBg, 0x1B1D21, 1 },             .{ ig.ImGuiCol_ChildBg, 0x000000, 0 },
    .{ ig.ImGuiCol_PopupBg, 0x23262B, 1 },              .{ ig.ImGuiCol_Border, 0x3A3F47, 1 },
    .{ ig.ImGuiCol_FrameBg, 0x262A30, 1 },              .{ ig.ImGuiCol_FrameBgHovered, 0x30353D, 1 },
    .{ ig.ImGuiCol_FrameBgActive, 0x3A404A, 1 },        .{ ig.ImGuiCol_TitleBg, 0x23262B, 1 },
    .{ ig.ImGuiCol_TitleBgActive, 0x2B3038, 1 },        .{ ig.ImGuiCol_MenuBarBg, 0x23262B, 1 },
    .{ ig.ImGuiCol_ScrollbarBg, 0x1B1D21, 0.6 },        .{ ig.ImGuiCol_ScrollbarGrab, 0x4A505A, 1 },
    .{ ig.ImGuiCol_ScrollbarGrabHovered, 0x5A616C, 1 }, .{ ig.ImGuiCol_ScrollbarGrabActive, 0x6B7380, 1 },
    .{ ig.ImGuiCol_CheckMark, 0x4C9BE8, 1 },            .{ ig.ImGuiCol_Button, 0x2F5F96, 1 },
    .{ ig.ImGuiCol_ButtonHovered, 0x3A74B5, 1 },        .{ ig.ImGuiCol_ButtonActive, 0x4587D1, 1 },
    .{ ig.ImGuiCol_Header, 0x2F5F96, 0.8 },             .{ ig.ImGuiCol_HeaderHovered, 0x3A74B5, 0.7 },
    .{ ig.ImGuiCol_HeaderActive, 0x4587D1, 1 },         .{ ig.ImGuiCol_Separator, 0x3A3F47, 1 },
    .{ ig.ImGuiCol_Tab, 0x23262B, 1 },                  .{ ig.ImGuiCol_TabHovered, 0x3A74B5, 1 },
    .{ ig.ImGuiCol_TabSelected, 0x2F5F96, 1 },          .{ ig.ImGuiCol_TabSelectedOverline, 0x4C9BE8, 1 },
    .{ ig.ImGuiCol_TableHeaderBg, 0x2A2E35, 1 },        .{ ig.ImGuiCol_TableBorderStrong, 0x3A3F47, 1 },
    .{ ig.ImGuiCol_TableBorderLight, 0x30343B, 1 },     .{ ig.ImGuiCol_TableRowBg, 0x000000, 0 },
    .{ ig.ImGuiCol_TableRowBgAlt, 0xFFFFFF, 0.04 },     .{ ig.ImGuiCol_TextSelectedBg, 0x4C9BE8, 0.4 },
    .{ ig.ImGuiCol_NavCursor, 0x4C9BE8, 1 },            .{ ig.ImGuiCol_ModalWindowDimBg, 0x000000, 0.55 },
    .{ ig.ImGuiCol_PlotHistogram, 0x4C9BE8, 1 },
};

const light_colors = [_]Color{
    .{ ig.ImGuiCol_Text, 0x1C1F23, 1 },                 .{ ig.ImGuiCol_TextDisabled, 0x646B75, 1 },
    .{ ig.ImGuiCol_WindowBg, 0xF4F5F7, 1 },             .{ ig.ImGuiCol_ChildBg, 0x000000, 0 },
    .{ ig.ImGuiCol_PopupBg, 0xFFFFFF, 1 },              .{ ig.ImGuiCol_Border, 0xBFC5CD, 1 },
    .{ ig.ImGuiCol_FrameBg, 0xFFFFFF, 1 },              .{ ig.ImGuiCol_FrameBgHovered, 0xEDF3FA, 1 },
    .{ ig.ImGuiCol_FrameBgActive, 0xDDE9F7, 1 },        .{ ig.ImGuiCol_TitleBg, 0xE4E7EB, 1 },
    .{ ig.ImGuiCol_TitleBgActive, 0xD5DAE0, 1 },        .{ ig.ImGuiCol_MenuBarBg, 0xE9ECF0, 1 },
    .{ ig.ImGuiCol_ScrollbarBg, 0xE9ECF0, 0.6 },        .{ ig.ImGuiCol_ScrollbarGrab, 0xB4BAC3, 1 },
    .{ ig.ImGuiCol_ScrollbarGrabHovered, 0x9AA1AB, 1 }, .{ ig.ImGuiCol_ScrollbarGrabActive, 0x808893, 1 },
    .{ ig.ImGuiCol_CheckMark, 0x1F6FC4, 1 },            .{ ig.ImGuiCol_Button, 0xD3E2F4, 1 },
    .{ ig.ImGuiCol_ButtonHovered, 0xBCD4EF, 1 },        .{ ig.ImGuiCol_ButtonActive, 0xA3C4EA, 1 },
    .{ ig.ImGuiCol_Header, 0xBCD4EF, 1 },               .{ ig.ImGuiCol_HeaderHovered, 0xD3E2F4, 1 },
    .{ ig.ImGuiCol_HeaderActive, 0xA3C4EA, 1 },         .{ ig.ImGuiCol_Separator, 0xBFC5CD, 1 },
    .{ ig.ImGuiCol_Tab, 0xE4E7EB, 1 },                  .{ ig.ImGuiCol_TabHovered, 0xBCD4EF, 1 },
    .{ ig.ImGuiCol_TabSelected, 0xFFFFFF, 1 },          .{ ig.ImGuiCol_TabSelectedOverline, 0x1F6FC4, 1 },
    .{ ig.ImGuiCol_TableHeaderBg, 0xE1E5EA, 1 },        .{ ig.ImGuiCol_TableBorderStrong, 0xBFC5CD, 1 },
    .{ ig.ImGuiCol_TableBorderLight, 0xD8DCE2, 1 },     .{ ig.ImGuiCol_TableRowBg, 0x000000, 0 },
    .{ ig.ImGuiCol_TableRowBgAlt, 0x000000, 0.035 },    .{ ig.ImGuiCol_TextSelectedBg, 0x1F6FC4, 0.3 },
    .{ ig.ImGuiCol_NavCursor, 0x1F6FC4, 1 },            .{ ig.ImGuiCol_ModalWindowDimBg, 0x000000, 0.35 },
    .{ ig.ImGuiCol_PlotHistogram, 0x1F6FC4, 1 },
};

fn channel(hex: u24, shift: u5) f32 {
    return @as(f32, @floatFromInt((hex >> shift) & 0xFF)) / 255.0;
}

// Cores do tema (os tamanhos sao definidos uma vez em setupSizes) + barra de titulo do Windows
fn applyTheme(light: bool, hwnd: ?*anyopaque) void {
    light_theme = light;
    const st = ig.igGetStyle();
    if (light) ig.igStyleColorsLight(st) else ig.igStyleColorsDark(st);
    for (if (light) &light_colors else &dark_colors) |c|
        st.*.Colors[@intCast(c[0])] = .{ .x = channel(c[1], 16), .y = channel(c[1], 8), .z = channel(c[1], 0), .w = c[2] };
    platform.darkTitleBar(hwnd, !light);
}

fn setupSizes(scale: f32) void {
    const st = ig.igGetStyle();
    st.*.WindowPadding = .{ .x = 10, .y = 10 };
    st.*.FramePadding = .{ .x = 8, .y = 5 };
    st.*.ItemSpacing = .{ .x = 8, .y = 6 };
    st.*.CellPadding = .{ .x = 6, .y = 4 };
    st.*.WindowRounding = 0;
    st.*.FrameRounding = 4;
    st.*.GrabRounding = 4;
    st.*.TabRounding = 4;
    st.*.PopupRounding = 6;
    st.*.ScrollbarSize = 14;
    st.*.FrameBorderSize = 1; // caixas de texto com contorno: no tema claro o fundo delas e branco
    ig.ImGuiStyle_ScaleAllSizes(st, scale);
}

// ------------------------------------------------------------------- texto e log

var session_log: dbm.log.Log = .{};
const log_pad_y: f32 = 4; // margem vertical do painel de Log
var mono_font: ?*ig.ImFont = null; // fonte monoespacada do painel de Log (null = a fonte da interface)
var log_gpa: std.mem.Allocator = std.heap.page_allocator; // trocado pelo gpa do programa em run()

fn logLine(s: []const u8) void {
    logEvent(.info, s);
}

// Com o Log recolhido a barra de status mostra a linha mais importante ainda nao vista no Log: ultimo erro >
// ultimo aviso > o status normal (ultima acao). Abrir o Log zera os contadores; um SQL certo tira os erros do SQL.
const Level = dbm.log.Level;
var alert: dbm.log.Alert = .{};

fn logEvent(level: Level, s: []const u8) void {
    logEventShort(level, s, s, false);
}

// `full` vai para o log (texto inteiro do motor, sem cortar); `short` e a linha da barra de status; `from_sql`: erro
// da aba SQL (sai da barra quando um SQL roda certo)
fn logEventShort(level: Level, full: []const u8, short: []const u8, from_sql: bool) void {
    var hb: [8]u8 = undefined;
    session_log.add(log_gpa, dbm.log.localTime(&hb), full);
    alert.add(level, short, from_sql);
}

fn markLogRead() void {
    alert.markRead();
}

// Linha do Log (a do Go): temporarios de uma sessao anterior (programa que caiu) apagados ao iniciar
fn logStale(n: usize) void {
    if (n == 0) return;
    var b: [200]u8 = undefined;
    logLine(i18n.fmtCount(&b, "log_stale_removed", n, .{n}));
}

const Msg = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    is_err: bool = false,
    loaded: bool = false, // e a mensagem "Aberto: ..." (refeita ao trocar o idioma)
    sql: bool = false, // a linha do botao Executar: os erros dela saem da barra de baixo quando um SQL roda certo

    // Texto do catalogo com argumentos; vai tambem para o log da sessao
    fn set(m: *Msg, is_err: bool, comptime key: []const u8, args: anytype) void {
        m.setText(is_err, i18n.fmt(&m.buf, key, args));
    }

    // Texto pronto (mensagem do banco ou de outro texto ja traduzido)
    fn setText(m: *Msg, is_err: bool, s: []const u8) void {
        m.replace(is_err, s);
        logEventShort(if (is_err) .err else .info, m.buf[0..m.len], m.buf[0..m.len], m.sql);
    }

    // Erro do motor: uma linha na tela com o prefixo traduzido (key = "err_sql" ou "err_db"); o texto inteiro no log
    fn setEngineError(m: *Msg, comptime key: []const u8, full: []const u8) void {
        var b: [1024]u8 = undefined;
        m.replace(true, i18n.fmt(&b, key, .{dbm.errorSummary(full)}));
        var fb: [1100]u8 = undefined;
        logEventShort(.err, i18n.fmt(&fb, key, .{full}), m.buf[0..m.len], m.sql);
    }

    // So troca o texto (sem nova linha no log): a mesma mensagem refeita em outro idioma
    fn replace(m: *Msg, is_err: bool, s: []const u8) void {
        m.is_err = is_err;
        m.loaded = false;
        const n = @min(s.len, m.buf.len);
        if (@intFromPtr(s.ptr) != @intFromPtr(&m.buf)) std.mem.copyForwards(u8, m.buf[0..n], s[0..n]);
        m.len = n;
    }

    fn text(m: *const Msg) []const u8 {
        return m.buf[0..m.len];
    }

    fn draw(m: *const Msg) void {
        if (m.is_err) pushTextColor(errorColor());
        ig.igPushTextWrapPos(0);
        textSlice(m.text());
        ig.igPopTextWrapPos();
        if (m.is_err) ig.igPopStyleColor(1);
    }
};

// Erro em vermelho, aviso em ambar (mensagens e barra de baixo)
fn errorColor() [3]f32 {
    return if (light_theme) .{ 0.70, 0.15, 0.12 } else .{ 1, 0.48, 0.45 };
}

fn warnColor() [3]f32 {
    return if (light_theme) .{ 0.62, 0.40, 0.0 } else .{ 0.95, 0.75, 0.30 };
}

fn pushTextColor(c: [3]f32) void {
    ig.igPushStyleColor_Vec4(ig.ImGuiCol_Text, .{ .x = c[0], .y = c[1], .z = c[2], .w = 1 });
}

// Largura do texto como ele e (sem tratar "##" como fim do rotulo)
fn rawWidth(s: []const u8) f32 {
    return ig.igCalcTextSize(s.ptr, s.ptr + s.len, false, -1).x;
}

// Uma linha em `w` px: o que nao cabe vira "..." no fim (cortado num caractere UTF-8 inteiro)
fn fitLine(buf: []u8, s: []const u8, w: f32) []const u8 {
    if (rawWidth(s) <= w) return s;
    const cut = dbm.gridtools.fitPrefix(s, w - rawWidth("..."), rawWidth);
    return std.fmt.bufPrint(buf, "{s}...", .{cut}) catch s;
}

fn textSlice(s: []const u8) void {
    ig.igTextUnformatted(s.ptr, s.ptr + s.len);
}

fn textT(comptime key: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    textSlice(i18n.fmt(&buf, key, args));
}

fn button(label: [*:0]const u8) bool {
    return ig.igButton(label, .{ .x = 0, .y = 0 });
}

fn textWidth(s: []const u8) f32 {
    return ig.igCalcTextSize(s.ptr, s.ptr + s.len, true, -1).x; // true: sem o "##id" do rotulo
}

fn tooltip(s: []const u8) void {
    ig.igSetTooltip("%.*s", @as(c_int, @intCast(@min(s.len, 4096))), s.ptr);
}

fn itemTooltip(s: [:0]const u8) void {
    ig.igSetItemTooltip("%s", s.ptr);
}

fn buttonWidth(label: [:0]const u8) f32 {
    return textWidth(label) + 2 * ig.igGetStyle().*.FramePadding.x;
}

// Rotulo traduzido com ID fixo ("Texto###id"): popups, menus e abas nao mudam de ID ao trocar o idioma
fn idLabel(buf: []u8, comptime key: []const u8, comptime id: []const u8) [:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}###" ++ id, .{tr(key)}, 0) catch "###" ++ id;
}

// Proximo item na mesma linha se `width` ainda cabe ate a borda da janela; senao ele desce (nunca e cortado)
fn sameLineIfFits(width: f32, spacing: f32) void {
    const st = ig.igGetStyle();
    const gap = if (spacing < 0) st.*.ItemSpacing.x else spacing;
    const right = ig.igGetWindowPos().x + ig.igGetWindowWidth() - st.*.WindowPadding.x;
    if (ig.igGetItemRectMax().x + gap + width <= right) ig.igSameLine(0, spacing);
}

// Proximo item encostado a direita do espaco que sobra (numero numa celula de tabela), menos `reserve` px
fn rightAlign(width: f32, reserve: f32) void {
    const avail = ig.igGetContentRegionAvail().x - reserve;
    if (avail > width) ig.igSetCursorPosX(ig.igGetCursorPosX() + avail - width);
}

// Cabecalho de coluna numerica: o nome encostado a direita, deixando `reserve` px (seta de ordenacao). O rotulo do
// TableHeader fica invisivel e so conta para a largura automatica da coluna. Devolve se o cabecalho esta sob o mouse.
fn rightHeader(label: [:0]const u8, reserve: f32) bool {
    const y0 = ig.igGetCursorScreenPos().y;
    ig.igPushStyleColor_U32(ig.ImGuiCol_Text, 0);
    ig.igTableHeader(label.ptr);
    ig.igPopStyleColor(1);
    const hovered = ig.igIsItemHovered(0);
    const min_x = ig.igGetItemRectMin().x;
    const max_x = ig.igGetItemRectMax().x - reserve;
    ig.igSameLine(0, 0);
    ig.igSetCursorScreenPos(.{ .x = @max(min_x, max_x - textWidth(label)), .y = y0 });
    textSlice(label);
    return hovered;
}

// Janela/dialogo sempre no centro da janela principal (mesmo redimensionada)
fn centerNext() void {
    const vp = ig.igGetMainViewport();
    ig.igSetNextWindowPos(.{ .x = vp.*.Pos.x + vp.*.Size.x / 2, .y = vp.*.Pos.y + vp.*.Size.y / 2 }, ig.ImGuiCond_Always, .{ .x = 0.5, .y = 0.5 });
}

// Dialogo com um botao so (Fechar/OK): Esc fecha sempre; Enter fecha so sem item em foco (na caixa de busca o Enter
// so filtra; um botao com foco e acionado pela navegacao do Dear ImGui)
fn dialogKeyClose() bool {
    const enter = ig.igIsKeyPressed_Bool(ig.ImGuiKey_Enter, false) or ig.igIsKeyPressed_Bool(ig.ImGuiKey_KeypadEnter, false);
    return dbm.gridtools.dialogCloses(ig.igIsKeyPressed_Bool(ig.ImGuiKey_Escape, false), enter, ig.igIsAnyItemFocused() or ig.igIsAnyItemActive());
}

// Foco de teclado visivel no item anterior (o botao padrao) quando o dialogo aparece; Enter o aciona
fn focusOnAppear() void {
    if (!ig.igIsWindowAppearing()) return;
    ig.igSetItemDefaultFocus();
    ig.igSetKeyboardFocusHere(-1);
    ig.igSetNavCursorVisible(true);
}

// Botoes de um dialogo todos do mesmo tamanho (a altura e a de sempre): a largura do maior texto entre eles nos 3
// idiomas, assim nenhum botao muda de tamanho com o idioma nem com o vizinho (pedido do dono, 26/11)
fn dialogButtonWidth(comptime keys: []const []const u8) f32 {
    var w: f32 = 88;
    inline for (i18n.catalogs) |C| inline for (keys) |k| {
        w = @max(w, buttonWidth(@field(C, k)));
    };
    return w;
}

fn zstr(buf: anytype) [:0]const u8 {
    return std.mem.sliceTo(buf, 0);
}

fn copyZ(dst: anytype, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

fn setClipboard(s: []const u8) void {
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();
    out.writer.writeAll(s) catch return;
    out.writer.writeByte(0) catch return;
    ig.igSetClipboardText(out.written().ptr);
}

// ------------------------------------------------------------------- app

const Tab = enum { data, schema, sql, terms };

// Caixa da aba Termos: 1 MiB (uma coluna do Excel com dezenas de milhares de termos)
// shortcut: a fixed box, text beyond 1 MiB is not accepted; grow it with ImGuiInputTextFlags_CallbackResize if needed
const terms_box_size = 1 << 20;

// Busca em todas as tabelas: o termo buscado e as tabelas com linhas (hits do gpa)
const Global = struct { term: [256:0]u8, hits: []worker.Hit };

// Pergunta aberta ao sair do programa: exportacao em andamento (Voltar / Sair) ou Access convertido e nao salvo
// (Salvar / Voltar / Sair)
const ExitAsk = enum { export_running, unsaved };
// Arquivo > Salvar (pasta do original) e Salvar como... (ultima pasta em que o usuario salvou ou exportou)
const SaveMode = enum { save, save_as };
// Exportar a tabela com busca ou filtro: a tabela inteira ou so as linhas encontradas
const ExportScope = enum { whole, found };

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    db: dbm.Db,
    slot: worker.Slot, // consultas rodam fora da thread da UI; slot.db aponta para `db`
    busy_since: f64 = 0,
    hwnd: ?*anyopaque = null,
    window: ?*glfw.Window = null, // titulo com o arquivo aberto
    status: Msg = .{},
    prefs: settings.Settings = .{},
    prefs_path: []const u8 = "",
    gtk_theme: []const u8 = "",

    path: [1024:0]u8 = @splat(0),
    loaded_path: [1024:0]u8 = @splat(0), // arquivo aberto agora (pasta padrao dos dialogos de salvar)
    source: ?dbm.Source = null,
    counts: []u64 = &.{}, // linhas por tabela, mesma ordem de db.table_names
    table_filter: [128:0]u8 = @splat(0),
    table_filter_applied: [128:0]u8 = @splat(0), // o que filtra a lista: o texto da caixa 300 ms depois da ultima tecla
    table_filter_wait: dbm.gridtools.Debounce = .{},
    filter_scratch: std.ArrayList(u8) = .empty, // nome de tabela em forma de busca (reaproveitado a cada quadro)
    tables_w: f32 = 0, // largura inicial do painel das tabelas (0 = calcular)
    opened: u32 = 0, // arquivos abertos na sessao (ID do painel das tabelas)

    // Access aberto = SQLite temporario. Fechar, abrir outro e Reabrir o apagam sem perguntar; so ao sair do programa,
    // e so se ele nao foi salvo (Arquivo > Salvar), a UI pergunta
    converted: ?struct { tmp: access.TempPath, source: [1024:0]u8, saved: bool = false } = null,
    exit_ask: ?ExitAsk = null, // pergunta de saida aberta
    exit_save: bool = false, // "Salvar" na pergunta de saida: o programa fecha quando o arquivo estiver salvo
    saving: bool = false, // a exportacao em andamento e um Salvar (no fim o Access conta como salvo)
    want_save: ?SaveMode = null, // abre a caixa de salvar quando nenhum trabalho roda
    want_close: bool = false, // Arquivo > Fechar
    open_request: [1024:0]u8 = @splat(0), // arquivo pedido no open em andamento (o Access, mesmo abrindo o SQLite salvo)
    opened_file: [1024:0]u8 = @splat(0), // arquivo que o banco tem aberto (o SQLite salvo, quando reaproveitado)
    save_dir: [1024:0]u8 = @splat(0), // ultima pasta em que o usuario salvou ou exportou nesta sessao
    quit: bool = false,
    capture_mode: bool = false, // --capture (auxiliar de teste)
    // Linux sem X11: aviso da abertura (texto copiavel, terminado em 0); null = sem aviso
    display_warning: ?dbm.display.Warning = null,
    display_cmd: [320:0]u8 = @splat(0), // o comando de instalacao, na caixa selecionavel
    display_shown: bool = false,
    display_dismiss: bool = false, // --capture: fecha o aviso no passo seguinte

    selected: ?usize = null,
    schema: ?dbm.Grid = null,
    col_names: []const []const u8 = &.{}, // vive na arena de schema
    data: ?dbm.Grid = null,
    search: [256:0]u8 = @splat(0),
    search_wait: dbm.gridtools.Debounce = .{}, // a busca roda 300 ms depois da ultima tecla (Enter: na hora)
    scope: settings.SearchScope = .table, // escopo atual da busca (o padrao vem das configuracoes)
    global: ?Global = null, // resultado da busca em todas as tabelas
    select_search: bool = false, // o proximo select abre a tabela com a busca da caixa (escolha na busca global)
    sort_col: ?usize = null,
    sort_desc: bool = false,
    limit: u32 = query.default_limit, // linhas por pagina na aba Dados (lista 100 / 500 / 1000)
    page: u64 = 0, // pagina da aba Dados (0 = a primeira); as marcadas ficam fora dela, no topo
    total: u64 = 0,
    // busca que vale para as linhas na tela (a caixa de busca pode ter texto ainda nao aplicado)
    applied_search: [256:0]u8 = @splat(0),
    // Filtros coluna = valor exato (clique direito na celula), somados com AND na consulta ao banco.
    // `column` aponta para col_names e `value` e do gpa; a lista so muda sem trabalho rodando (o pedido a le).
    filters: std.ArrayList(query.Criterion) = .empty,
    want_filter: ?struct { col: usize, value: ?[]u8 } = null, // novo filtro pedido (valor do gpa; null = NULL)
    want_unfilter: ?usize = null, // remover o filtro de indice N
    want_clear_filters: bool = false,
    // Linhas marcadas (item 31), por tabela (indice em db.table_names), enquanto o arquivo estiver aberto: a identidade
    // de cada linha (rowid ou md5 da linha, do gpa). Mudam so sem trabalho rodando (o pedido le a lista).
    marks: []std.ArrayList([]const u8) = &.{},
    data_key: ?query.RowKey = null, // identidade de linha da tabela aberta
    marked_top: usize = 0, // as primeiras linhas de `data` sao as marcadas
    only_marked: bool = false, // Exibir > So as linhas marcadas (a caixa "So as marcadas")
    want_mark: ?usize = null, // marcar ou desmarcar esta linha da grade de Dados
    want_unmark_all: bool = false,

    // Aba Termos (item 32)
    terms_text: []u8 = &.{}, // a caixa (terms_box_size + 1 bytes do gpa, terminada em 0)
    terms_counted: [2]usize = .{ 0, 0 }, // termos sem os repetidos e os repetidos da caixa (refeito ao editar)
    terms_match: settings.TermMatch = .whole, // Valor inteiro | Contem (padrao em Configuracoes)
    // Esta tabela | Todas as tabelas: comeca SEMPRE em Todas as tabelas (item 17), nunca o escopo padrao da aba Dados
    terms_scope: settings.SearchScope = .all,
    terms_res: ?dbm.terms.Result = null, // resultado mostrado
    terms_hit: usize = 0, // tabela escolhida na lista (indice em terms_res.tables)
    terms_grid: ?dbm.Grid = null, // as linhas achadas da tabela escolhida (coluna Termo + as da tabela)
    terms_sel: GridSel = .{},
    terms_seconds: f64 = 0, // tempo da ultima pesquisa
    want_terms: bool = false, // Pesquisar termos (botao, Ctrl+Enter)
    want_terms_page: ?usize = null, // outra tabela escolhida na lista
    want_terms_copy: bool = false, // Copiar as linhas encontradas desta tabela

    sql: [8192:0]u8 = @splat(0),
    result: ?dbm.Grid = null,
    result_sql: [8192:0]u8 = @splat(0), // SQL que gerou `result` (a exportacao roda de novo, sem limite)
    sql_msg: Msg = .{ .sql = true },
    result_filter: [128:0]u8 = @splat(0), // filtro sobre as linhas carregadas do resultado
    result_rows: ?[]usize = null, // indices das linhas que casam; null = sem filtro
    tab: Tab = .data,
    data_sel: GridSel = .{},
    schema_sel: GridSel = .{},
    result_sel: GridSel = .{},

    // Acoes pedidas pela UI, executadas no inicio de um proximo quadro (nunca no meio do desenho).
    // As que usam o banco esperam o trabalho em andamento terminar.
    want_open: bool = false,
    want_select: ?usize = null,
    want_reload: bool = false,
    want_run: bool = false,
    want_global: bool = false,
    want_browse: bool = false,
    want_export: ?ExportKind = null, // abre o dialogo de salvar e dispara a exportacao
    ask_export: ?ExportKind = null, // pergunta aberta: tabela inteira ou so as linhas encontradas
    export_scope: ?ExportScope = null, // resposta, usada pelo proximo startExport
    want_theme: ?settings.Theme = null,
    want_lang: ?i18n.Lang = null,
    want_about: bool = false,
    about_open: bool = false,
    log_seen: usize = 0, // tamanho do log no ultimo quadro (linha nova: rola para o fim)
    want_tab: ?Tab = null, // aba a selecionar no proximo quadro (atalhos, --sql)
    focus_search: bool = false, // Ctrl+F: foco na busca da aba Dados
    focus_tables: bool = false, // Ctrl+T: foco no filtro da lista de tabelas
    want_refresh: bool = false, // F5: abre de novo o arquivo aberto
    close_popups: bool = false, // --capture: cada passo comeca sem os menus do passo anterior
    reveal_selected: bool = false, // rola a lista de tabelas ate a selecionada (ex.: --table)
    start_table: []const u8 = "", // --table: tabela inicial do proximo open
    start_sql: bool = false, // --sql: roda depois do primeiro open
    start_search: []const u8 = "", // --search: busca na aba Data depois do primeiro open
    start_cell: ?[2]usize = null, // --cell: linha e coluna (base 0) que abrem com o menu de copia
    start_menu: ?enum { File, Edit, View, Settings, Help, Export } = null, // --menu: menu aberto quando o banco abrir (capturas)
    start_export: ?ExportKind = null, // --export: abre o dialogo de salvar dessa exportacao quando o banco abrir
    // Tabelas favoritas (item 34): pelo nome (do gpa), so na memoria; valem em qualquer arquivo aberto na sessao
    favorites: std.ArrayList([]const u8) = .empty,
    table_order: std.ArrayList(usize) = .empty, // ordem da lista de tabelas no quadro (favoritas primeiro)
    want_fav: ?usize = null, // favoritar ou desfavoritar esta tabela (indice em db.table_names)
    fav_menu: ?usize = null, // --capture: abre o menu do clique direito desta tabela da lista

    // Favorita sai da lista ou entra nela (pelo nome); a lista rola ate a tabela aberta (que pode ter ido ao topo)
    fn toggleFavorite(app: *App, table: usize) void {
        if (table >= app.db.table_names.len) return;
        const name = app.db.table_names[table];
        for (app.favorites.items, 0..) |f, i| if (std.mem.eql(u8, f, name)) {
            app.gpa.free(app.favorites.orderedRemove(i));
            app.reveal_selected = true;
            return;
        };
        const copy = app.gpa.dupe(u8, name) catch return;
        app.favorites.append(app.gpa, copy) catch return app.gpa.free(copy);
        app.reveal_selected = true;
    }

    fn deinit(app: *App) void {
        // fechar com trabalho em andamento: pede para parar e espera a thread antes de soltar o banco
        // (uma exportacao interrompida apaga o arquivo .part)
        app.slot.cancel();
        var late: access.TempPath = .{};
        if (app.slot.wait()) |o| {
            var out = o;
            late = out.converted;
            out.deinit(app.gpa);
        }
        app.clearTable();
        app.clearResult();
        app.clearGlobal();
        app.clearTerms();
        app.gpa.free(app.terms_text);
        app.gpa.free(app.slot.req.terms_text); // pesquisa cortada pela saida
        app.gpa.free(app.slot.req.hits); // exportacao da busca global cortada pela saida
        app.gpa.free(app.counts);
        app.freeMarks();
        for (app.favorites.items) |f| app.gpa.free(f);
        app.favorites.deinit(app.gpa);
        app.table_order.deinit(app.gpa);
        app.filter_scratch.deinit(app.gpa);
        app.filters.deinit(app.gpa);
        app.db.close();
        // saida sem resposta (conversao terminada no Cancelar, erro ao iniciar): nada de temporario orfao
        if (late.len > 0) access.deleteTemp(app.io, late.slice(), zstr(&app.slot.req.path));
        if (app.converted) |cv| access.deleteTemp(app.io, cv.tmp.slice(), zstr(&cv.source));
    }

    fn clearFilters(app: *App) void {
        for (app.filters.items) |f| app.gpa.free(f.value);
        app.filters.clearRetainingCapacity();
        if (app.want_filter) |f| if (f.value) |v| app.gpa.free(v);
        app.want_filter = null;
        app.want_unfilter = null;
        app.want_clear_filters = false;
    }

    // Aplica os pedidos de filtro da UI (so chamado sem trabalho rodando)
    fn editFilters(app: *App) void {
        const add = app.want_filter;
        app.want_filter = null; // clearFilters nao pode soltar o valor que vai entrar na lista
        if (app.want_clear_filters) app.clearFilters();
        if (app.want_unfilter) |i| if (i < app.filters.items.len) app.gpa.free(app.filters.orderedRemove(i).value);
        app.want_unfilter = null;
        const f = add orelse return;
        if (f.col < app.col_names.len) return dbm.gridtools.addFilter(app.gpa, &app.filters, app.col_names[f.col], f.value);
        if (f.value) |v| app.gpa.free(v);
    }

    fn freeMarks(app: *App) void {
        for (app.marks) |*list| {
            for (list.items) |k| app.gpa.free(k);
            list.deinit(app.gpa);
        }
        app.gpa.free(app.marks);
        app.marks = &.{};
        app.only_marked = false;
    }

    // Arquivo novo: nenhuma linha marcada, uma lista por tabela
    fn resetMarks(app: *App, n: usize) void {
        app.freeMarks();
        app.marks = app.gpa.alloc(std.ArrayList([]const u8), n) catch &.{};
        for (app.marks) |*list| list.* = .empty;
    }

    fn marksOf(app: *const App, table: ?usize) []const []const u8 {
        const i = table orelse return &.{};
        return if (i < app.marks.len) app.marks[i].items else &.{};
    }

    // Marca ou desmarca a linha pedida da grade de Dados, ou desmarca todas (so sem trabalho rodando)
    fn editMarks(app: *App) void {
        const row = app.want_mark;
        const all = app.want_unmark_all;
        app.want_mark = null;
        app.want_unmark_all = false;
        const index = app.selected orelse return;
        if (index >= app.marks.len) return;
        const list = &app.marks[index];
        if (all) {
            for (list.items) |k| app.gpa.free(k);
            list.clearRetainingCapacity();
        }
        if (row) |r| if (app.data) |g| if (r < g.keys.len) {
            const at = for (list.items, 0..) |k, i| {
                if (std.mem.eql(u8, k, g.keys[r])) break i;
            } else null;
            if (at) |i| {
                app.gpa.free(list.orderedRemove(i));
            } else if (app.gpa.dupe(u8, g.keys[r])) |k| {
                list.append(app.gpa, k) catch app.gpa.free(k);
            } else |_| {}
        };
        if (list.items.len == 0) app.only_marked = false;
    }

    // Sem resultado de termos (pesquisa nova, outro arquivo): o velho nunca aparece
    fn clearTerms(app: *App) void {
        if (app.terms_res) |*r| r.deinit();
        if (app.terms_grid) |*g| g.deinit();
        app.terms_res = null;
        app.terms_grid = null;
        app.terms_hit = 0;
        app.terms_sel = .{};
    }

    // Contagem da caixa de termos ("8 termos, 1 repetido"): refeita quando o texto muda
    fn countTerms(app: *App) void {
        const list = dbm.terms.parse(app.gpa, std.mem.sliceTo(app.terms_text, 0)) catch return;
        defer app.gpa.free(list.terms);
        app.terms_counted = .{ list.terms.len, list.repeated };
    }

    fn clearTable(app: *App) void {
        app.clearFilters();
        if (app.data) |*g| g.deinit();
        if (app.schema) |*g| g.deinit();
        app.data = null;
        app.schema = null;
        app.col_names = &.{};
        app.selected = null;
        app.data_sel = .{};
        app.schema_sel = .{};
    }

    fn clearGlobal(app: *App) void {
        if (app.global) |g| app.gpa.free(g.hits);
        app.global = null;
    }

    // A grade da aba Dados de novo, da pagina 1: a busca, os filtros, a ordenacao, Linhas ou So as marcadas mudou
    fn reloadFirstPage(app: *App) void {
        app.page = 0;
        app.want_reload = true;
    }

    // Busca da caixa da aba Data no escopo atual (Enter ou 300 ms depois da ultima tecla). Todas as tabelas: a lista
    // anterior some ate o resultado do termo novo chegar
    fn runSearch(app: *App) void {
        app.search_wait.due = null;
        if (app.scope == .table) return app.reloadFirstPage();
        app.clearGlobal();
        app.want_global = std.mem.indexOfNone(u8, zstr(&app.search), &std.ascii.whitespace) != null;
    }

    // A busca global com este termo ainda e a que a tela pede: escopo Todas as tabelas, o mesmo texto na caixa e
    // nenhum arquivo para abrir. Senao o resultado e descartado e a busca em andamento para.
    fn wantsGlobal(app: *const App, term: *const [256:0]u8) bool {
        return app.scope == .all and !app.want_open and std.mem.eql(u8, zstr(term), zstr(&app.search));
    }

    // Seletor da aba Data ou Configuracoes: o texto da caixa ainda nao aplicado neste escopo e buscado agora
    fn setScope(app: *App, s: settings.SearchScope) void {
        if (app.scope == s) return;
        app.scope = s;
        const done = if (s == .all)
            (if (app.global) |g| std.mem.eql(u8, zstr(&g.term), zstr(&app.search)) else false)
        else
            std.mem.eql(u8, zstr(&app.applied_search), zstr(&app.search));
        if (!done) app.runSearch();
    }

    // Tabela escolhida no resultado da busca global: abre na aba Data com a mesma busca e sem filtros por valor, para
    // mostrar o numero listado (outra tabela ja abre sem eles)
    fn pickGlobal(app: *App, table: usize, term: *const [256:0]u8) void {
        app.scope = .table;
        app.search = term.*;
        app.search_wait.due = null;
        if (app.selected == table) {
            app.want_clear_filters = true; // update() limpa e recarrega da pagina 1
        } else {
            app.want_select = table;
            app.select_search = true;
        }
    }

    fn clearResult(app: *App) void {
        if (app.result) |*g| g.deinit();
        app.result = null;
        app.result_sel = .{};
        app.refilter();
    }

    // Refaz a lista de linhas do resultado que casam com o filtro (todas as colunas)
    fn refilter(app: *App) void {
        if (app.result_rows) |r| app.gpa.free(r);
        app.result_rows = null;
        const needle = zstr(&app.result_filter);
        const g = app.result orelse return;
        if (needle.len > 0) app.result_rows = dbm.gridtools.filterRows(app.gpa, g.rows, needle) catch null;
    }

    fn fail(app: *App, msg: *Msg, err: anyerror) void {
        switch (err) {
            // motor: uma linha com prefixo na tela, o texto inteiro no log; as mensagens do programa ja vem traduzidas
            error.DuckDb => if (msg == &app.sql_msg) msg.setEngineError("err_sql", app.db.lastError()) else msg.setEngineError("err_db", app.db.lastError()),
            error.Failed => msg.setEngineError("err_plain", app.db.lastError()),
            error.Canceled => msg.set(true, "canceled", .{}),
            error.SqlReadOnly => msg.set(true, "sql_read_only", .{}),
            error.UnsupportedExtension => msg.set(true, "err_not_db", .{}),
            // abrir um arquivo que nao existe: so "Arquivo nao encontrado: <caminho>", nunca o texto do sistema
            error.FileNotFound => if (app.slot.req.kind == .open) msg.set(true, "err_file_not_found", .{zstr(&app.slot.req.path)}) else msg.set(true, "err_generic", .{err}),
            error.AccessDenied, error.FileBusy, error.PermissionDenied => msg.set(true, "err_cannot_write", .{err}),
            else => msg.set(true, "err_generic", .{err}),
        }
    }

    fn setPath(app: *App, p: []const u8) void {
        copyZ(&app.path, p);
    }

    // Enter na caixa do caminho e Arquivo > Abrir o caminho digitado (item 14): vazio = a caixa de escolher arquivo;
    // caminho relativo = "Arquivo nao encontrado" (nunca resolvido contra a pasta do exe)
    fn openTyped(app: *App) void {
        switch (query.typedPath(zstr(&app.path))) {
            .pick => app.want_browse = true,
            .not_found => app.status.set(true, "err_file_not_found", .{std.mem.trim(u8, zstr(&app.path), &std.ascii.whitespace)}),
            .open => app.want_open = true,
        }
    }

    // Enquanto o banco esta sendo aberto a outra thread troca db.table_names: nao desenhar o banco
    fn opening(app: *const App) bool {
        return app.slot.busyWith(.open);
    }

    // Copia o estado da UI para o pedido e dispara a thread
    fn start(app: *App, kind: worker.Kind) void {
        const r = &app.slot.req;
        r.kind = kind;
        r.limit = app.limit;
        switch (kind) {
            .open => {
                r.path = app.path;
                app.page = 0;
                app.open_request = app.path;
                // Access ja convertido e salvo (chave caminho + tamanho + data, gravada nas configuracoes) e sem mudanca
                // desde entao: abre o SQLite salvo, sem converter de novo nem perguntar ao fechar
                const access_file = if (query.sourceKind(zstr(&app.path))) |k| k == .access else |_| false;
                if (access_file) {
                    // a ultima pasta possivel do convertido e a subpasta ao lado do original: as sobras dela saem aqui
                    var bb: [1100]u8 = undefined;
                    const beside = std.fmt.bufPrint(&bb, "{s}{s}" ++ access.temp_subdir, .{ std.fs.path.dirname(zstr(&app.path)) orelse ".", std.fs.path.sep_str }) catch "";
                    logStale(access.cleanupStale(app.io, beside));
                    std.Io.Dir.cwd().deleteDir(app.io, beside) catch {}; // vazia, some
                }
                if (access_file) if (app.prefs.savedFor(app.io, zstr(&app.path))) |dest| {
                    copyZ(&r.path, dest);
                    var lb: [2200]u8 = undefined;
                    // o formato real do salvo, lido do proprio arquivo: SQLite ou DuckDB
                    const saved_as = dbm.fileFormat(app.io, dest) orelse .sqlite;
                    logLine(i18n.fmt(&lb, "converted_reused", .{ std.fs.path.basename(zstr(&app.path)), saved_as.label(), dest }));
                };
                r.table_name = app.start_table;
                app.start_table = "";
            },
            .select => {
                r.table = app.want_select orelse return;
                app.page = 0; // outra tabela: pagina 1
                r.search = if (app.select_search) app.search else @splat(0);
                r.marks = app.marksOf(r.table); // as marcadas desta tabela vem no topo
                app.select_search = false;
            },
            .search_all => r.search = app.search,
            .reload => {
                r.table = app.selected orelse return;
                r.columns = app.col_names;
                r.search = app.search;
                r.filters = app.filters.items;
                r.sort_col = app.sort_col;
                r.sort_desc = app.sort_desc;
                r.key = app.data_key;
                r.marks = app.marksOf(r.table);
                r.only_marked = app.only_marked and r.marks.len > 0;
                r.offset = app.page * app.limit;
            },
            .sql => r.sql = app.sql,
            .export_ => {}, // preenchido em startExport
            .terms => {
                app.clearTerms();
                // copia: a caixa continua editavel durante a pesquisa (solta em apply)
                r.terms_text = app.gpa.dupe(u8, std.mem.sliceTo(app.terms_text, 0)) catch return app.status.set(true, "err_generic", .{error.OutOfMemory});
                r.term_match = app.terms_match;
                r.terms_only = if (app.terms_scope == .table) app.selected else null;
                r.terms_titles = termsTitles();
            },
            .terms_page, .terms_copy => {
                r.terms_res = if (app.terms_res) |*res| res else return;
                r.terms_hit = if (kind == .terms_page) (app.want_terms_page orelse return) else app.terms_hit;
                r.terms_titles = termsTitles();
            },
        }
        app.busy_since = ig.igGetTime();
        app.slot.start() catch |e| app.status.set(true, "err_worker", .{e});
    }

    // Resultado de um trabalho, ja na thread da UI
    fn apply(app: *App, result: worker.Out) void {
        var out = result;
        defer out.deinit(app.gpa); // libera o que nao foi aproveitado abaixo
        switch (out.kind) {
            .open => {
                app.clearTable();
                app.clearResult();
                app.clearGlobal();
                app.clearTerms();
                // arquivo novo comeca sem o filtro da lista de tabelas e sem a busca da aba Data, no escopo de Settings
                app.table_filter = @splat(0);
                app.table_filter_applied = @splat(0);
                app.table_filter_wait.due = null;
                app.search = @splat(0);
                app.search_wait.due = null;
                app.scope = app.prefs.search_scope;
                app.sql_msg.len = 0;
                app.tables_w = 0;
                app.opened +%= 1;
                app.want_select = null;
                app.want_reload = false;
                app.gpa.free(app.counts);
                app.counts = out.counts;
                out.counts = &.{};
                app.resetMarks(if (app.db.isOpen()) app.db.table_names.len else 0);
                app.source = if (app.db.isOpen()) out.source else null;
                app.loaded_path = if (app.db.isOpen()) app.open_request else @splat(0);
                app.opened_file = if (app.db.isOpen()) app.slot.req.path else @splat(0);
                app.updateTitle();
                // o SQLite convertido existe mesmo se a contagem foi cancelada: a UI fica com ele
                if (out.converted.len > 0) app.converted = .{ .tmp = out.converted, .source = app.slot.req.path };
                if (app.db.isOpen() and out.err == null) {
                    app.setLoadedStatus(true);
                    app.rememberDir(zstr(&app.slot.req.path));
                    // capturas de tela: so o nome do arquivo na caixa (a pasta tem o nome do usuario)
                    if (app.capture_mode) copyZ(&app.path, std.fs.path.basename(zstr(&app.open_request)));
                    if (app.start_sql) {
                        app.want_run = true;
                        app.want_tab = .sql;
                    }
                }
                app.start_sql = false;
                if (out.err == null) app.takeTable(&out, "");
            },
            .select => if (out.err == null) {
                app.clearTable();
                app.takeTable(&out, zstr(&app.slot.req.search));
            },
            .search_all => {
                // termo apagado ou trocado, outro escopo, tabela ou arquivo: resultado velho (ou o Cancelar dele) some
                if (!app.wantsGlobal(&app.slot.req.search)) return;
                app.clearGlobal(); // falha: lista vazia e o erro na barra de status
                if (out.err == null) {
                    app.global = .{ .term = app.slot.req.search, .hits = out.hits };
                    out.hits = &.{};
                }
            },
            .reload => if (out.err == null) {
                if (app.data) |*old| old.deinit();
                app.data = out.data;
                out.data = null;
                app.data_sel.row = null; // as colunas ocultas continuam valendo na mesma tabela
                app.marked_top = out.marked;
                app.total = out.total;
                app.applied_search = app.slot.req.search;
                // a pagina passou do fim (linhas que sairam dela foram marcadas): a ultima que existe
                const listed = app.total -| app.marked_top;
                if (app.page > 0 and !app.only_marked and app.page * app.limit >= listed) {
                    app.page = if (listed == 0) 0 else (listed - 1) / app.limit;
                    app.want_reload = true;
                }
            },
            .sql => {
                // erro: a grade velha some; certo: o erro anterior sai da linha do botao e da barra de baixo
                app.clearResult();
                if (out.err == null) alert.clearSql();
                if (out.result) |g| {
                    app.result = g;
                    out.result = null;
                    app.result_sql = app.slot.req.sql;
                    app.refilter();
                    if (g.truncated)
                        app.sql_msg.set(false, "sql_more_rows", .{ g.rows.len, g.rows.len })
                    else
                        app.sql_msg.setText(false, sqlRowsCols(&app.sql_msg.buf, g.rows.len, g.columns.len));
                }
            },
            .terms => {
                app.gpa.free(app.slot.req.terms_text);
                app.slot.req.terms_text = "";
                app.terms_seconds = ig.igGetTime() - app.busy_since;
                if (out.err == null) {
                    app.terms_res = out.terms;
                    app.terms_grid = out.data;
                    out.terms = null;
                    out.data = null;
                }
            },
            .terms_page => if (out.err == null) {
                if (app.terms_grid) |*g| g.deinit();
                app.terms_grid = out.data;
                out.data = null;
                app.terms_hit = app.slot.req.terms_hit;
                app.terms_sel = .{};
            },
            .terms_copy => if (out.copied) |text| setClipboard(text),
            .export_ => if (out.err == null) {
                const r = &app.slot.req;
                // Salvar em DuckDB, Excel (ou SQLite de um banco que nao e Access): o arquivo aberto conta como salvo
                if (app.saving) app.saved(r.destPath(), switch (r.export_kind) {
                    .db_sqlite => .sqlite,
                    .db_duckdb => .duckdb,
                    else => .xlsx,
                });
                // .xlsx: o que o Excel nao comporta aparece na mesma linha, em destaque (nada some calado)
                const p = &app.slot.progress;
                var cells_buf: [96]u8 = undefined;
                var cols_buf: [96]u8 = undefined;
                const cells_s = if (p.cut_cells > 0) i18n.fmt(&cells_buf, "export_cut_cells", .{p.cut_cells}) else "";
                const cols_s = if (p.cut_cols > 0) i18n.fmt(&cols_buf, "export_cut_cols", .{p.cut_cols}) else "";
                const unit = if (r.export_kind.countsTables()) i18n.trCount("unit_tables", out.exported) else i18n.trCount("unit_rows", out.exported);
                app.status.setText(cells_s.len + cols_s.len > 0, i18n.fmtCount(&app.status.buf, "status_exported", out.exported, .{ out.exported, unit, std.fs.path.basename(r.destPath()), cells_s, cols_s }));
            },
        }
        if (out.kind == .export_) {
            app.gpa.free(app.slot.req.hits);
            app.slot.req.hits = &.{};
            app.saving = false;
            if (out.err != null) app.exit_save = false; // nao salvou: o programa fica aberto
        }
        if (out.err) |e| return app.fail(if (out.kind == .sql) &app.sql_msg else &app.status, e);

        // Estado inicial pedido na linha de comando (--search, --cell), quando os dados dele chegam
        if (out.kind == .open) {
            if (app.start_search.len > 0 and app.selected != null) {
                copyZ(&app.search, app.start_search);
                app.runSearch(); // no escopo de Settings: esta tabela ou todas
            }
            app.start_search = "";
        }
        if (app.start_cell) |cell| if (!app.want_run and !app.want_reload) {
            const sel = if (out.kind == .sql) &app.result_sel else &app.data_sel;
            sel.* = .{ .row = cell[0], .col = cell[1], .popup = true };
            app.start_cell = null;
        };
    }

    // "Aberto: <arquivo> (<n> tabelas)" no idioma atual; log = false ao so traduzir a mesma mensagem. O leitor fica
    // fixo a direita da barra de baixo (e vai para o log junto)
    fn setLoadedStatus(app: *App, log: bool) void {
        if (app.source == null) return;
        var buf: [1024]u8 = undefined;
        const name = std.fs.path.basename(zstr(&app.loaded_path));
        const n = app.db.table_names.len;
        const s = i18n.fmtCount(&buf, "status_loaded", n, .{ name, n });
        if (log) {
            app.status.setText(false, s);
            var sb: [160]u8 = undefined;
            logLine(app.sourceText(&sb));
        } else app.status.replace(false, s);
        app.status.loaded = true;
    }

    // Titulo da janela: "<arquivo> - mdb2sql 1.3.0 - Zig" com arquivo aberto, senao "mdb2sql 1.3.0 - Zig"
    fn updateTitle(app: *App) void {
        const w = app.window orelse return;
        var tb: [1100]u8 = undefined;
        w.setTitle(dbm.about.windowTitleFor(&tb, std.fs.path.basename(zstr(&app.loaded_path))));
    }

    // Modo de leitura do arquivo aberto (direita da barra de baixo): "Aberto via Access ODBC, convertido para
    // SQLite", "Aberto via mdbtools, ...", "Aberto via SQLite" ou "Aberto via DuckDB"; vazio sem arquivo
    fn sourceText(app: *const App, buf: []u8) []const u8 {
        const src = app.source orelse return "";
        if (app.opening() or !app.db.isOpen()) return "";
        return if (src.isAccess()) i18n.fmt(buf, "source_via_converted", .{src.label()}) else i18n.fmt(buf, "source_via", .{src.label()});
    }

    // Colunas ocultas da grade da aba atual (direita da barra de baixo): "1 coluna oculta", "3 colunas ocultas" ou vazio
    fn hiddenNow(app: *const App, buf: []u8) []const u8 {
        if (app.opening() or !app.db.isOpen()) return "";
        return switch (app.tab) {
            .data => hiddenText(buf, &app.data_sel, if (app.data) |g| g.columns.len else 0),
            .sql => hiddenText(buf, &app.result_sel, if (app.result) |g| g.columns.len else 0),
            .terms => hiddenText(buf, &app.terms_sel, if (app.terms_grid) |g| g.columns.len else 0),
            .schema => "",
        };
    }

    // Tabela recem-carregada (schema + primeira pagina): comeca sem ordenacao, com a busca do pedido (vazia ou a
    // da busca global)
    fn takeTable(app: *App, out: *worker.Out, search: []const u8) void {
        app.selected = out.table orelse return;
        app.reveal_selected = true;
        app.schema = out.schema;
        if (app.schema) |*g| localizeSchema(g);
        app.col_names = out.columns;
        app.data = out.data;
        out.schema = null;
        out.data = null;
        app.data_key = out.key;
        app.marked_top = out.marked;
        app.total = out.total;
        copyZ(&app.search, search);
        copyZ(&app.applied_search, search);
        app.search_wait.due = null; // tecla pendente da tabela anterior nao busca nesta
        app.sort_col = null;
        app.sort_desc = false;
    }

    // Pasta usada por ultimo (abrir ou salvar), gravada para a proxima execucao
    fn rememberDir(app: *App, file_path: []const u8) void {
        const dir = std.fs.path.dirname(file_path) orelse return;
        if (std.mem.eql(u8, dir, app.prefs.lastDir())) return;
        app.prefs.setLastDir(dir);
        app.savePrefs();
    }

    fn savePrefs(app: *App) void {
        if (app.prefs_path.len == 0) return;
        app.prefs.save(app.io, app.prefs_path) catch |e| app.status.set(true, "err_settings", .{e});
    }

    // Sair do programa (X da janela, Arquivo > Sair, Ctrl+Q, Alt+F4). Antes de tudo, com uma exportacao em andamento,
    // pergunta (Voltar / Sair); busca ou outro trabalho e cancelado sem perguntar. So com Access convertido e nao salvo
    // vem a pergunta Salvar / Voltar / Sair.
    fn requestExit(app: *App) void {
        if (app.exit_ask != null) return;
        if (app.slot.busyWith(.export_)) {
            app.exit_ask = .export_running;
            return;
        }
        app.slot.cancel();
        app.exitUnlessUnsaved();
    }

    fn exitUnlessUnsaved(app: *App) void {
        const unsaved = if (app.converted) |cv| !cv.saved else false;
        if (unsaved) app.exit_ask = .unsaved else app.quit = true;
    }

    // O arquivo aberto e `path`: o original, o SQLite salvo que o substitui ou o SQLite temporario do Access
    fn isOpenFile(app: *const App, path: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(path, zstr(&app.loaded_path)) or std.ascii.eqlIgnoreCase(path, zstr(&app.opened_file))) return true;
        return if (app.converted) |cv| std.ascii.eqlIgnoreCase(path, cv.tmp.slice()) else false;
    }

    // Caixa de salvar de Arquivo > Salvar e Salvar como...: nome do original, tipos SQLite, DuckDB e Excel, ja marcado
    // o tipo do arquivo aberto (Access e SQLite: SQLite; DuckDB: DuckDB). Salvar abre na pasta do original; Salvar
    // como, na ultima pasta em que o usuario salvou ou exportou (sem ela, a do original).
    fn startSave(app: *App, mode: SaveMode) void {
        if (!app.db.isOpen()) return;
        const loaded = zstr(&app.loaded_path);
        const first: dialog.SaveType = if (app.source == .duckdb) .duckdb else .sqlite;
        var dir = std.fs.path.dirname(loaded) orelse "";
        if (mode == .save_as and app.save_dir[0] != 0) dir = zstr(&app.save_dir);
        if (dir.len > 0) std.Io.Dir.cwd().access(app.io, dir, .{}) catch {
            dir = "";
        };
        const stem = std.fs.path.stem(loaded);
        var name_buf: [600]u8 = undefined;
        var sugg_buf: [4096]u8 = undefined;
        var initial = settings.suggest(&sugg_buf, dir, settings.fileName(&name_buf, stem, first.ext()));
        // o nome sugerido e o do proprio arquivo aberto: "<nome> (copia)"
        if (app.isOpenFile(initial)) {
            var cb: [400]u8 = undefined;
            initial = settings.suggest(&sugg_buf, dir, settings.fileName(&name_buf, i18n.fmt(&cb, "copy_name", .{stem}), first.ext()));
        }
        var path_buf: dialog.PathBuf = undefined;
        const picked = dialog.pickSave(app.io, app.hwnd, tr("save_title"), initial, first, &path_buf) orelse {
            if (dialog.unavailable) app.status.set(true, "err_no_dialog", .{});
            // caixa cancelada: veio da pergunta de saida, ela volta
            if (app.exit_save) app.exit_ask = .unsaved;
            app.exit_save = false;
            return;
        };
        app.saveTo(picked.path, picked.type);
    }

    // Grava o banco aberto em `dest`. Access convertido para SQLite: o temporario e copiado. O resto usa a exportacao
    // do banco inteiro (gravacao segura em .part, progresso, Cancelar).
    fn saveTo(app: *App, dest: []const u8, ty: dialog.SaveType) void {
        if (app.isOpenFile(dest)) {
            app.exit_save = false;
            return app.status.set(true, "err_choose_other", .{});
        }
        copyZ(&app.save_dir, std.fs.path.dirname(dest) orelse "");
        if (app.converted) |cv| if (ty == .sqlite) {
            std.Io.Dir.cwd().copyFile(cv.tmp.slice(), std.Io.Dir.cwd(), dest, app.io, .{}) catch |e| {
                app.exit_save = false;
                return app.status.set(true, "err_save_sqlite", .{e});
            };
            // so o nome do arquivo na linha de status (o caminho inteiro quebraria a linha); a pasta vai para o log
            logLine(dest);
            app.status.set(false, "converted_saved", .{std.fs.path.basename(dest)});
            return app.saved(dest, ty);
        };
        const r = &app.slot.req;
        r.setDest(dest);
        r.total_hint = 0;
        if (ty == .xlsx) for (app.counts) |n| {
            r.total_hint += n;
        };
        r.export_kind = switch (ty) {
            .sqlite => .db_sqlite,
            .duckdb => .db_duckdb,
            .xlsx => .db_xlsx,
        };
        app.saving = true;
        app.start(.export_);
    }

    // O banco aberto foi salvo em `dest`. Access: a pergunta ao sair some e, salvo em SQLite ou DuckDB, a conversao
    // fica lembrada (o mesmo Access, sem mudanca, abre o arquivo salvo, tambem em outra execucao). Veio da pergunta
    // de saida: o programa fecha.
    fn saved(app: *App, dest: []const u8, ty: dialog.SaveType) void {
        if (app.converted) |*cv| {
            cv.saved = true;
            if (ty != .xlsx) {
                app.prefs.rememberSaved(app.io, zstr(&cv.source), dest);
                app.savePrefs();
            }
        }
        if (app.exit_save) app.quit = true;
        app.exit_save = false;
    }

    // Solta o arquivo aberto (so sem trabalho rodando) e apaga o SQLite temporario, se houver. Fechar, abrir outro e
    // Reabrir passam por aqui sem perguntar: o convertido que nao foi salvo e descartado e o Log diz
    fn closeFile(app: *App) void {
        if (!app.db.isOpen() and app.converted == null) return;
        const name = std.fs.path.basename(zstr(&app.loaded_path));
        var nb: [256]u8 = undefined;
        const shown = nb[0..@min(name.len, nb.len)];
        @memcpy(shown, name[0..shown.len]);
        app.clearTable();
        app.clearResult();
        app.clearGlobal();
        app.clearTerms();
        app.sql_msg.len = 0;
        app.db.closeSource();
        app.gpa.free(app.counts);
        app.counts = &.{};
        app.freeMarks();
        app.source = null;
        app.loaded_path = @splat(0);
        app.opened_file = @splat(0);
        if (app.converted) |cv| {
            access.deleteTemp(app.io, cv.tmp.slice(), zstr(&cv.source));
            if (!cv.saved) {
                var lb: [1200]u8 = undefined;
                logLine(i18n.fmt(&lb, "log_discarded", .{std.fs.path.basename(zstr(&cv.source))}));
            }
            app.converted = null;
        }
        app.updateTitle();
        if (shown.len > 0) app.status.set(false, "status_closed", .{shown});
    }

    fn update(app: *App) void {
        if (app.slot.poll()) |out| app.apply(out);
        const now = ig.igGetTime();
        if (app.search_wait.fire(now)) app.runSearch();
        if (app.table_filter_wait.fire(now)) app.table_filter_applied = app.table_filter;

        if (app.want_theme) |theme| {
            app.prefs.theme = theme;
            applyTheme(settings.isLight(theme, app.gtk_theme), app.hwnd);
            app.savePrefs();
        }
        app.want_theme = null;
        if (app.want_lang) |l| {
            i18n.lang = l;
            localizeImGui();
            app.prefs.lang = l;
            app.savePrefs();
            if (app.status.loaded) app.setLoadedStatus(false);
            if (app.schema) |*g| localizeSchema(g);
        }
        app.want_lang = null;
        if (app.want_browse) {
            var buf: dialog.PathBuf = undefined;
            if (dialog.pick(app.io, .open_db, app.hwnd, app.prefs.lastDir(), &buf)) |p| {
                app.setPath(p);
                app.want_open = true;
            } else if (dialog.unavailable) app.status.set(true, "err_no_dialog", .{});
        }
        app.want_browse = false;

        // busca global que a tela nao quer mais: para entre uma tabela e outra (o DuckDB interrompe a consulta), para a
        // busca nova ou a outra acao nao esperarem por ela
        if (app.slot.busyWith(.search_all) and !app.slot.progress.cancel.load(.monotonic) and !app.wantsGlobal(&app.slot.req.search))
            app.slot.cancel();
        // a exportacao acabou com a pergunta "Sair cancela a exportacao" aberta: a saida continua
        if (app.exit_ask == .export_running and !app.slot.busyWith(.export_)) {
            app.exit_ask = null;
            app.exitUnlessUnsaved();
        }
        if (app.slot.busy()) return; // um trabalho por vez; os pedidos abaixo ficam para depois
        if (app.exit_ask != null or app.quit) return; // esperando a resposta da pergunta de saida
        if (app.want_close) {
            app.want_close = false;
            app.closeFile();
        }
        // F5 (o do Python): abre de novo o arquivo aberto; o SQLite convertido dele e trocado pelo novo, sem pergunta.
        // Sem arquivo aberto (item 14): a caixa de escolher arquivo, nunca um banco padrao relativo
        if (app.want_refresh) {
            app.want_refresh = false;
            if (app.loaded_path[0] != 0) {
                var again: [1024:0]u8 = app.loaded_path;
                app.closeFile();
                app.setPath(zstr(&again));
                app.want_open = true;
            } else app.want_browse = true;
        }
        if (app.want_filter != null or app.want_unfilter != null or app.want_clear_filters) {
            app.editFilters();
            app.reloadFirstPage();
        }
        if (app.want_mark != null or app.want_unmark_all) {
            app.editMarks();
            app.want_reload = true;
        }
        if (app.want_fav) |i| {
            app.want_fav = null;
            app.toggleFavorite(i);
        }
        if (app.start_export != null and app.db.isOpen() and !app.want_open and !app.want_reload and !app.want_run) {
            app.want_export = app.start_export;
            app.start_export = null;
        }
        if (app.want_save) |mode| {
            app.want_save = null;
            app.startSave(mode);
        } else if (app.want_export) |kind| {
            app.want_export = null;
            app.startExport(kind);
        } else if (app.want_open) {
            app.want_open = false;
            // abrir outro arquivo nao pergunta: o convertido do anterior, se nao foi salvo, e descartado
            if (app.converted != null) app.closeFile();
            app.start(.open);
        } else if (app.want_select != null) {
            app.start(.select);
            app.want_select = null;
        } else if (app.want_reload) {
            app.want_reload = false;
            app.start(.reload);
        } else if (app.want_run) {
            app.want_run = false;
            app.start(.sql);
        } else if (app.want_global) {
            app.want_global = false;
            app.start(.search_all);
        } else if (app.want_terms) {
            app.want_terms = false;
            if (app.terms_counted[0] > 0) app.start(.terms);
        } else if (app.want_terms_page != null) {
            app.start(.terms_page);
            app.want_terms_page = null;
        } else if (app.want_terms_copy) {
            app.want_terms_copy = false;
            app.start(.terms_copy);
        }
    }

    // Dialogo de salvar (pasta do arquivo aberto; sem arquivo, a ultima usada) e dispara o trabalho
    fn startExport(app: *App, kind_in: ExportKind) void {
        if (!app.db.isOpen()) return;
        // tabela da aba Dados com busca ou filtro: antes pergunta se vai a tabela inteira ou so as linhas encontradas
        const narrowed = app.applied_search[0] != 0 or app.filters.items.len > 0;
        var whole = false;
        // Tabela atual e sempre a tabela da aba Dados (com a busca e os filtros dela), de qualquer aba
        if (worker.asksExportScope(kind_in, true, narrowed)) {
            const answer = app.export_scope orelse {
                app.ask_export = kind_in;
                return;
            };
            app.export_scope = null;
            whole = answer == .whole;
        }
        const kind = kind_in;
        const r = &app.slot.req;
        const loaded = zstr(&app.loaded_path);
        var name_buf: [512]u8 = undefined;
        const base: []const u8 = switch (kind) {
            .db_duckdb, .db_sqlite, .db_xlsx, .all_csv => std.fs.path.stem(loaded),
            .table_csv, .table_xlsx => app.db.table_names[app.selected orelse return],
            .schema_csv, .schema_xlsx => std.fmt.bufPrint(&name_buf, "{s}_schema", .{app.db.table_names[app.selected orelse return]}) catch "schema",
            .dbschema_csv, .dbschema_xlsx => std.fmt.bufPrint(&name_buf, "{s}_schema", .{std.fs.path.stem(loaded)}) catch "schema",
            .result_csv, .result_xlsx => "query",
            .marked_csv, .marked_xlsx => std.fmt.bufPrint(&name_buf, "{s}_marcadas", .{app.db.table_names[app.selected orelse return]}) catch "marcadas",
            .terms_xlsx, .terms_csv, .terms_sqlite, .terms_duckdb => std.fmt.bufPrint(&name_buf, "{s}_termos", .{std.fs.path.stem(loaded)}) catch "termos",
            .global_xlsx => std.fmt.bufPrint(&name_buf, "{s}_busca", .{std.fs.path.stem(loaded)}) catch "busca",
        };
        var file_buf: [600]u8 = undefined;
        var file = settings.fileName(&file_buf, base, kind.ext());
        // DB4.duckdb exportado para .duckdb: o nome sugerido nao pode ser o do proprio arquivo aberto
        if (std.ascii.eqlIgnoreCase(file, std.fs.path.basename(loaded)) or std.ascii.eqlIgnoreCase(file, std.fs.path.basename(zstr(&app.opened_file)))) {
            var b2: [520]u8 = undefined;
            file = settings.fileName(&file_buf, std.fmt.bufPrint(&b2, "{s}_export", .{base}) catch base, kind.ext());
        }
        var sugg_buf: [4096]u8 = undefined;
        var dir = settings.defaultDir(loaded, app.prefs.lastDir());
        // pasta que nao existe mais (apagada, pendrive removido): o dialogo recusaria abrir
        if (dir.len > 0) std.Io.Dir.cwd().access(app.io, dir, .{}) catch {
            dir = "";
        };
        const initial = settings.suggest(&sugg_buf, dir, file);
        const dkind: dialog.Kind = switch (kind) {
            .db_duckdb, .terms_duckdb => .save_duckdb,
            .db_sqlite, .terms_sqlite => .save_sqlite,
            .db_xlsx, .table_xlsx, .result_xlsx, .marked_xlsx, .terms_xlsx, .schema_xlsx, .dbschema_xlsx, .global_xlsx => .save_xlsx,
            .table_csv, .result_csv, .marked_csv, .terms_csv, .schema_csv, .dbschema_csv, .all_csv => .save_csv,
        };
        var path_buf: dialog.PathBuf = undefined;
        // um CSV por tabela ou por aba: o seletor de pasta nativo
        const picked = if (kind.toFolder()) app.pickExportFolder(kind, dir, &path_buf) else dialog.pick(app.io, dkind, app.hwnd, initial, &path_buf);
        const dest = picked orelse {
            if (!kind.toFolder() and dialog.unavailable) app.status.set(true, "err_no_dialog", .{});
            return;
        };
        // nem o arquivo aberto nem o SQLite salvo que o substitui (Access reaproveitado)
        if (std.ascii.eqlIgnoreCase(dest, loaded) or std.ascii.eqlIgnoreCase(dest, zstr(&app.opened_file))) return app.status.set(true, "err_choose_other", .{});
        if (app.converted) |cv| if (std.ascii.eqlIgnoreCase(dest, cv.tmp.slice())) return app.status.set(true, "err_choose_other", .{});
        if (!kind.toFolder()) app.rememberDir(dest);
        copyZ(&app.save_dir, if (kind.toFolder()) dest else std.fs.path.dirname(dest) orelse ""); // onde "Salvar como..." comeca

        r.setDest(dest);
        r.total_hint = 0;
        if (kind == .table_csv or kind == .table_xlsx) {
            // todas as linhas na ordem da tela: so as encontradas (busca e filtros aplicados) ou a tabela inteira
            const index = app.selected orelse return;
            r.table = index;
            r.columns = app.col_names;
            r.search = if (whole) @splat(0) else app.applied_search;
            r.filters = if (whole) &.{} else app.filters.items;
            r.sort_col = app.sort_col;
            r.sort_desc = app.sort_desc;
            r.key = app.data_key;
            r.total_hint = if (whole and index < app.counts.len) app.counts[index] else app.total;
        } else if (kind == .schema_csv or kind == .schema_xlsx or kind == .dbschema_csv or kind == .dbschema_xlsx) {
            // o esquema da aba Esquema (coluna, tipo, aceita nulo) ou o do banco (com a tabela na frente): titulos e
            // Sim/Nao no idioma da tela; vai como o resultado de um SQL
            const one = kind == .schema_csv or kind == .schema_xlsx;
            const sql = (if (one)
                query.buildSchemaExport(app.gpa, app.db.table_names[app.selected orelse return], .{ tr("schema_column"), tr("schema_type"), tr("schema_null") }, tr("yes"), tr("no"))
            else
                query.buildDbSchemaExport(app.gpa, .{ tr("col_table"), tr("schema_column"), tr("schema_type"), tr("schema_null") }, tr("yes"), tr("no"))) catch "";
            defer app.gpa.free(sql);
            if (sql.len == 0 or sql.len >= r.sql.len) return app.status.set(true, "err_table_name_long", .{});
            @memcpy(r.sql[0..sql.len], sql);
            r.sql[sql.len] = 0;
        } else if (kind == .all_csv) {
            for (app.counts) |n| r.total_hint += n;
        } else if (kind == .global_xlsx) {
            // as tabelas da busca em todas as tabelas (copia: a UI troca a lista a cada busca; solta em apply)
            const g = app.global orelse return;
            r.hits = app.gpa.dupe(worker.Hit, g.hits) catch return;
            r.search = g.term;
            for (g.hits) |h| r.total_hint += h.rows;
        } else if (kind == .marked_csv or kind == .marked_xlsx) {
            // as linhas marcadas da tabela atual: todas as colunas, na ordem da tabela, nome <tabela>_marcadas
            const index = app.selected orelse return;
            r.table = index;
            r.columns = app.col_names;
            r.key = app.data_key;
            r.marks = app.marksOf(index);
            r.total_hint = r.marks.len;
        } else if (kind == .result_csv or kind == .result_xlsx) {
            r.sql = app.result_sql;
            if (app.result) |g| if (!g.truncated) {
                r.total_hint = g.rows.len;
            };
        } else if (kind == .db_xlsx) {
            for (app.counts) |n| r.total_hint += n;
        } else if (kind == .terms_xlsx or kind == .terms_csv or kind == .terms_sqlite or kind == .terms_duckdb) {
            // relatorio da pesquisa mostrada: resumo, uma aba por tabela com acerto, nao encontrados
            const res = if (app.terms_res) |*x| x else return;
            r.terms_res = res;
            r.terms_titles = termsTitles();
            r.total_hint = res.rows + res.pairs.len + res.terms.len;
        }
        r.export_kind = kind;
        app.start(.export_);
    }

    // Exportacao para uma pasta (um CSV por tabela ou por aba): o seletor de pasta nativo; se algum dos arquivos ja
    // existe nela, uma pergunta so (T.overwriteMany, Sim/Nao nativo)
    fn pickExportFolder(app: *App, kind: ExportKind, initial: []const u8, buf: *dialog.PathBuf) ?[]const u8 {
        const dir = dialog.pickFolder(app.io, app.hwnd, initial, buf) orelse {
            if (dialog.unavailable) app.status.set(true, "err_no_dialog", .{});
            return null;
        };
        var arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena.deinit();
        const names = app.folderFiles(arena.allocator(), kind) catch return null;
        var existing: usize = 0;
        for (names) |n| {
            var pb: [4096]u8 = undefined;
            const p = dbm.exporter.csvPath(&pb, dir, n) catch continue;
            if (std.Io.Dir.cwd().access(app.io, p, .{})) |_| existing += 1 else |_| {}
        }
        if (existing > 0) {
            var qb: [200]u8 = undefined;
            if (!platform.confirm(app.io, app.hwnd, app_title, i18n.fmtCount(&qb, "overwrite_many", existing, .{existing}))) return null;
        }
        return dir;
    }

    // Nomes (sem o .csv) dos arquivos de uma exportacao para pasta
    fn folderFiles(app: *App, a: std.mem.Allocator, kind: ExportKind) ![]const []const u8 {
        if (kind == .all_csv) return app.db.table_names;
        if (kind != .terms_csv) return &.{};
        const res = if (app.terms_res) |*x| x else return &.{};
        const items = try dbm.terms.reportItems(a, app.db.table_names, res, termsTitles());
        const names = try a.alloc([]const u8, items.len);
        for (names, items) |*n, item| n.* = item.sheet;
        return names;
    }

    fn draw(app: *App) void {
        if (app.close_popups) {
            app.close_popups = false;
            ig.igClosePopupsExceptModals();
        }
        app.drawMenu();
        const vp = ig.igGetMainViewport();
        ig.igSetNextWindowPos(vp.*.WorkPos, ig.ImGuiCond_Always, .{ .x = 0, .y = 0 });
        ig.igSetNextWindowSize(vp.*.WorkSize, ig.ImGuiCond_Always);
        _ = ig.igBegin("##main", null, ig.ImGuiWindowFlags_NoDecoration | ig.ImGuiWindowFlags_NoMove |
            ig.ImGuiWindowFlags_NoSavedSettings | ig.ImGuiWindowFlags_NoBringToFrontOnFocus);
        defer ig.igEnd();
        app.drawAbout();
        app.drawExit();
        app.drawExportScope();
        app.drawDisplayWarning();

        // Barra superior (item 14): caminho | Abrir... | Exportar... (tambem aceita arrastar o arquivo para a janela).
        // Abrir... escolhe o arquivo na caixa (= Arquivo > Abrir..., Ctrl+O); o caminho digitado abre com Enter. O
        // caminho ocupa a linha toda menos os 2 botoes: o status foi para a barra de baixo
        const buttons = buttonWidth(tr("open")) + buttonWidth(tr("export_button")) + 2 * ig.igGetStyle().*.ItemSpacing.x;
        ig.igSetNextItemWidth(ig.igGetContentRegionAvail().x - buttons);
        // ElideLeft: caminho maior que a linha perde o comeco (com ...), nunca o nome do arquivo
        if (ig.igInputTextWithHint("##path", tr("path_hint"), &app.path, app.path.len + 1, ig.ImGuiInputTextFlags_EnterReturnsTrue | ig.ImGuiInputTextFlags_ElideLeft, null, null)) app.openTyped();
        ig.igSameLine(0, -1);
        if (button(tr("open"))) app.want_browse = true;
        ig.igSameLine(0, -1);
        ig.igBeginDisabled(app.opening() or !app.db.isOpen());
        if (button(tr("export_button")) or app.takeStartMenu(.Export)) _ = ig.igOpenPopup_Str("##export_menu", 0);
        // o menu abre logo abaixo do botao (e nao onde o mouse estiver)
        const below_x = ig.igGetItemRectMin().x;
        const below_y = ig.igGetItemRectMax().y;
        ig.igEndDisabled();
        ig.igSetNextWindowPos(.{ .x = below_x, .y = below_y }, ig.ImGuiCond_Appearing, .{ .x = 0, .y = 0 });
        if (ig.igBeginPopup("##export_menu", 0)) {
            defer ig.igEndPopup();
            app.exportItems();
        }
        ig.igSeparator();

        // Embaixo: painel de Log (quando aberto, com a borda de cima arrastavel) e a barra de status
        const st = ig.igGetStyle();
        const status_h = ig.igGetFrameHeight() + st.*.ItemSpacing.y + 1;
        const avail_h = ig.igGetContentRegionAvail().y - status_h;
        const split_h: f32 = 6;
        const log_h: f32 = if (app.prefs.log_open) logPanelHeight(app.prefs.log_frac, vp.*.WorkSize.y) else 0;
        // aberto: a borda arrastavel e o painel, cada um com o seu espacamento
        const content_h = @max(ig.igGetFrameHeight() * 3, avail_h - log_h - (if (app.prefs.log_open) split_h + 2 * st.*.ItemSpacing.y else 0));

        if (!app.opening() and app.db.isOpen()) {
            // painel das tabelas na largura do nome mais longo (ate 40% da janela; alem disso rola na horizontal,
            // nada e cortado); um ID por arquivo aberto para a largura inicial valer de novo a cada arquivo
            if (app.tables_w == 0) {
                var longest: f32 = 0;
                for (app.db.table_names) |n| longest = @max(longest, textWidth(n));
                const w = longest + textWidth("0000000") + 4 * st.*.CellPadding.x + 2 * st.*.WindowPadding.x + st.*.ScrollbarSize + 8;
                app.tables_w = std.math.clamp(w, 260, @max(260, vp.*.WorkSize.x * 0.4));
            }
            ig.igPushID_Int(@intCast(app.opened % 1_000_000));
            if (ig.igBeginChild_Str("##tables", .{ .x = app.tables_w, .y = content_h }, ig.ImGuiChildFlags_ResizeX | ig.ImGuiChildFlags_Borders, 0)) app.drawTables();
            ig.igEndChild();
            ig.igPopID();
            ig.igSameLine(0, -1);
            if (ig.igBeginChild_Str("##content", .{ .x = 0, .y = content_h }, 0, 0)) app.drawContent();
            ig.igEndChild();
        } else ig.igDummy(.{ .x = 1, .y = content_h });
        if (app.prefs.log_open) {
            // borda arrastavel: muda a altura do Log (fracao da janela, gravada ao soltar)
            _ = ig.igInvisibleButton("##logsplit", .{ .x = @max(1, ig.igGetContentRegionAvail().x), .y = split_h }, 0);
            if (ig.igIsItemHovered(0) or ig.igIsItemActive()) ig.igSetMouseCursor(ig.ImGuiMouseCursor_ResizeNS);
            if (ig.igIsItemActive()) {
                const dy = ig.igGetMouseDragDelta(0, 0).y; // desde o quadro anterior (zerado logo abaixo)
                ig.igResetMouseDragDelta(0);
                app.prefs.log_frac = settings.clampLogFrac(app.prefs.log_frac - dy / @max(1, vp.*.WorkSize.y));
            }
            if (ig.igIsItemDeactivated()) app.savePrefs();
            app.drawLogPanel(log_h);
        }
        ig.igSeparator();
        app.drawStatus();
    }

    // Altura do painel de Log: fracao da janela (~10%), entre 3 linhas (+ cabecalho) e 25%
    fn logPanelHeight(frac: f32, win_h: f32) f32 {
        // cabecalho + 3 linhas da fonte do log (um passo menor) + as margens da caixa e do painel
        const min_h = ig.igGetFrameHeightWithSpacing() + 3 * @max(13, ig.igGetFontSize() - 2) + 2 * ig.igGetStyle().*.FramePadding.y + 2 * log_pad_y + 2;
        return std.math.clamp(frac * win_h, min_h, @max(min_h, settings.max_log_frac * win_h));
    }

    fn setLogOpen(app: *App, open: bool) void {
        if (open) markLogRead();
        if (app.prefs.log_open == open) return;
        app.prefs.log_open = open;
        app.savePrefs();
    }

    // Exportar (Arquivo > Exportar e o botao Exportar...): a lista fixa do item 28, igual nas 4 versoes; o que nao se
    // aplica fica desabilitado. O banco inteiro e Arquivo > Salvar.
    fn exportItems(app: *App) void {
        const has_db = !app.opening() and app.db.isOpen();
        const has_table = has_db and app.selected != null;
        if (formatMenu(tr("export_table"), has_table)) |csv| app.want_export = if (csv) .table_csv else .table_xlsx;
        if (formatMenu(tr("export_marked"), has_table and app.marksOf(app.selected).len > 0)) |csv| app.want_export = if (csv) .marked_csv else .marked_xlsx;
        if (formatMenu(tr("export_schema"), has_table)) |csv| app.want_export = if (csv) .schema_csv else .schema_xlsx;
        if (formatMenu(tr("export_dbschema"), has_db)) |csv| app.want_export = if (csv) .dbschema_csv else .dbschema_xlsx;
        if (ig.igMenuItem_Bool(tr("export_all_csv"), null, false, has_db)) app.want_export = .all_csv;
        if (formatMenu(tr("export_result"), has_db and app.result != null)) |csv| app.want_export = if (csv) .result_csv else .result_xlsx;
        const has_global = if (app.global) |g| g.hits.len > 0 else false;
        if (ig.igMenuItem_Bool(tr("export_global"), null, false, has_db and has_global)) app.want_export = .global_xlsx;
        if (termsReportMenu(has_db and app.terms_res != null)) |k| app.want_export = k;
    }

    // A grade da aba atual e a celula escolhida nela (Editar > Copiar, Ctrl+Shift+C); `skip`: a coluna Termo
    const Current = struct { g: *const dbm.Grid, sel: *GridSel, skip: usize };
    fn currentGrid(app: *App) ?Current {
        return switch (app.tab) {
            .data => if (app.data) |*g| .{ .g = g, .sel = &app.data_sel, .skip = 0 } else null,
            .schema => if (app.schema) |*g| .{ .g = g, .sel = &app.schema_sel, .skip = 0 } else null,
            .sql => if (app.result) |*g| .{ .g = g, .sel = &app.result_sel, .skip = 0 } else null,
            .terms => if (app.terms_grid) |*g| .{ .g = g, .sel = &app.terms_sel, .skip = 1 } else null,
        };
    }

    fn drawMenu(app: *App) void {
        if (!ig.igBeginMainMenuBar()) return;
        defer ig.igEndMainMenuBar();
        var lb: [7][96]u8 = undefined;
        const file_l = idLabel(&lb[0], "menu_file", "file");
        const view_l = idLabel(&lb[1], "menu_view", "view");
        const settings_l = idLabel(&lb[2], "menu_settings", "settings");
        const help_l = idLabel(&lb[3], "menu_help", "help");
        const export_l = idLabel(&lb[4], "menu_export", "export");
        const lang_l = idLabel(&lb[5], "menu_language", "language");
        const edit_l = idLabel(&lb[6], "menu_edit", "edit");
        // --menu: abre o menu (e o submenu Exportar / Idioma) no mesmo quadro, para as capturas de tela
        const open_file = app.takeStartMenu(.File);
        const open_settings = app.takeStartMenu(.Settings);
        if (app.takeStartMenu(.Edit)) _ = ig.igOpenPopup_Str(edit_l, 0);
        if (open_file) _ = ig.igOpenPopup_Str(file_l, 0);
        if (open_settings) _ = ig.igOpenPopup_Str(settings_l, 0);
        if (app.takeStartMenu(.View)) _ = ig.igOpenPopup_Str(view_l, 0);
        if (app.takeStartMenu(.Help)) _ = ig.igOpenPopup_Str(help_l, 0);
        const has_db = !app.opening() and app.db.isOpen();
        if (ig.igBeginMenu(file_l, true)) {
            defer ig.igEndMenu();
            if (ig.igMenuItem_Bool(tr("menu_open"), "Ctrl+O", false, true)) app.want_browse = true;
            if (ig.igMenuItem_Bool(tr("menu_open_typed"), null, false, true)) app.openTyped();
            if (ig.igMenuItem_Bool(tr("menu_reopen"), "F5", false, !app.opening())) app.want_refresh = true;
            ig.igSeparator();
            if (ig.igMenuItem_Bool(tr("menu_save"), "Ctrl+S", false, has_db)) app.want_save = .save;
            if (ig.igMenuItem_Bool(tr("menu_save_as"), "Ctrl+Shift+S", false, has_db)) app.want_save = .save_as;
            if (open_file) _ = ig.igOpenPopup_Str(export_l, 0);
            if (ig.igBeginMenu(export_l, has_db)) {
                defer ig.igEndMenu();
                app.exportItems();
            }
            ig.igSeparator();
            if (ig.igMenuItem_Bool(tr("menu_close"), "Ctrl+W", false, has_db)) app.want_close = true;
            ig.igSeparator();
            if (ig.igMenuItem_Bool(tr("menu_exit"), "Ctrl+Q", false, true)) app.requestExit();
        }
        // Editar: o que os menus das grades fazem, na grade da aba atual
        if (ig.igBeginMenu(edit_l, true)) {
            defer ig.igEndMenu();
            const cur = app.currentGrid();
            const cell = if (cur) |c| c.sel.row != null else false;
            if (ig.igMenuItem_Bool(tr("copy_value"), "Ctrl+C", false, cell)) copySelection(cur.?.g, cur.?.sel, false, false, 0);
            if (ig.igMenuItem_Bool(tr("copy_row"), "Ctrl+Shift+C", false, cell)) copySelection(cur.?.g, cur.?.sel, true, false, cur.?.skip);
            if (ig.igMenuItem_Bool(tr("copy_row_header"), null, false, cell)) copySelection(cur.?.g, cur.?.sel, true, true, cur.?.skip);
            if (ig.igMenuItem_Bool(tr("menu_copy_log"), null, false, session_log.text.items.len > 0)) setClipboard(session_log.slice());
            ig.igSeparator();
            if (ig.igMenuItem_Bool(tr("menu_search"), "Ctrl+F", false, has_db)) {
                app.want_tab = .data;
                app.focus_search = true;
            }
            const data_cell = has_db and app.tab == .data and app.data_sel.row != null;
            if (ig.igMenuItem_Bool(tr("filter_by_value"), null, false, data_cell)) app.data_sel.want_filter = true;
            if (ig.igMenuItem_Bool(tr("clear_filters"), null, false, has_db and app.filters.items.len > 0)) app.want_clear_filters = true;
            ig.igSeparator();
            const keyed = if (app.data) |g| g.keys.len == g.rows.len else false;
            if (ig.igMenuItem_Bool(tr("menu_mark"), tr("key_space"), false, data_cell and keyed)) app.want_mark = app.data_sel.row;
            if (ig.igMenuItem_Bool(tr("menu_unmark_all"), null, false, has_db and app.marksOf(app.selected).len > 0)) app.want_unmark_all = true;
        }
        if (ig.igBeginMenu(view_l, true)) {
            defer ig.igEndMenu();
            if (ig.igMenuItem_Bool(tr("tab_data"), "Ctrl+1", false, has_db)) app.want_tab = .data;
            if (ig.igMenuItem_Bool(tr("tab_schema"), "Ctrl+2", false, has_db)) app.want_tab = .schema;
            if (ig.igMenuItem_Bool(tr("tab_sql"), "Ctrl+3", false, has_db)) app.want_tab = .sql;
            if (ig.igMenuItem_Bool(tr("tab_terms"), "Ctrl+4", false, has_db)) app.want_tab = .terms;
            ig.igSeparator();
            // Linhas > 100 / 500 / 1000 (a lista da aba Dados)
            var rb: [96]u8 = undefined;
            if (ig.igBeginMenu(idLabel(&rb, "rows_label", "rows"), has_db)) {
                defer ig.igEndMenu();
                for (query.row_limits) |n| {
                    var nb: [16]u8 = undefined;
                    const item = std.fmt.bufPrintSentinel(&nb, "{d}", .{n}, 0) catch continue;
                    if (ig.igMenuItem_Bool(item, null, app.limit == n, true) and n != app.limit) {
                        app.limit = n;
                        app.reloadFirstPage();
                    }
                }
            }
            // Colunas... da grade da aba atual (o Esquema nao tem)
            const cols_sel: ?*GridSel = switch (app.tab) {
                .data => if (app.data != null) &app.data_sel else null,
                .sql => if (app.result != null) &app.result_sel else null,
                .terms => if (app.terms_grid != null) &app.terms_sel else null,
                .schema => null,
            };
            if (ig.igMenuItem_Bool(tr("columns_button"), null, false, has_db and cols_sel != null)) cols_sel.?.open_columns = true;
            var sb: [96]u8 = undefined;
            if (ig.igBeginMenu(idLabel(&sb, "menu_search_in", "search_in"), has_db)) {
                defer ig.igEndMenu();
                const pick: ?settings.SearchScope = if (ig.igMenuItem_Bool(tr("scope_table"), null, app.scope == .table, true))
                    .table
                else if (ig.igMenuItem_Bool(tr("scope_all"), null, app.scope == .all, true)) .all else null;
                if (pick) |s| {
                    app.want_tab = .data; // a busca e a da aba Dados
                    app.setScope(s);
                }
            }
            if (ig.igMenuItem_Bool(tr("menu_only_marked"), null, app.only_marked, has_db and app.marksOf(app.selected).len > 0)) {
                app.only_marked = !app.only_marked;
                app.reloadFirstPage();
            }
            if (ig.igMenuItem_Bool(tr("menu_goto_tables"), "Ctrl+T", false, has_db)) app.focus_tables = true;
            if (ig.igMenuItem_Bool(tr("fav_toggle"), "Ctrl+D", false, has_db and app.selected != null)) app.want_fav = app.selected;
            ig.igSeparator();
            if (ig.igMenuItem_Bool(tr("menu_run_sql"), "Ctrl+Enter", false, has_db and zstr(&app.sql).len > 0)) {
                app.want_tab = .sql;
                app.want_run = true;
            }
            if (ig.igMenuItem_Bool(tr("terms_run"), "Ctrl+Enter", false, has_db and app.terms_counted[0] > 0)) {
                app.want_tab = .terms;
                app.want_terms = true;
            }
            ig.igSeparator();
            if (ig.igMenuItem_Bool(tr("menu_log"), "Ctrl+L", app.prefs.log_open, true)) app.setLogOpen(!app.prefs.log_open);
        }
        if (ig.igBeginMenu(settings_l, true)) {
            defer ig.igEndMenu();
            var tb: [96]u8 = undefined;
            const theme_l = idLabel(&tb, "menu_theme", "theme");
            if (ig.igBeginMenu(theme_l, true)) {
                defer ig.igEndMenu();
                const cur = app.prefs.theme;
                if (ig.igMenuItem_Bool(tr("theme_system"), null, cur == .system, true)) app.want_theme = .system;
                if (ig.igMenuItem_Bool(tr("theme_light"), null, cur == .light, true)) app.want_theme = .light;
                if (ig.igMenuItem_Bool(tr("theme_dark"), null, cur == .dark, true)) app.want_theme = .dark;
            }
            if (open_settings) _ = ig.igOpenPopup_Str(lang_l, 0);
            if (ig.igBeginMenu(lang_l, true)) {
                defer ig.igEndMenu();
                for (i18n.names, 0..) |n, i| {
                    const l: i18n.Lang = @fromBackingInt(@intCast(i));
                    if (ig.igMenuItem_Bool(n, null, i18n.lang == l, true)) app.want_lang = l;
                }
            }
            // as opcoes da tela, com o padrao gravado: escopo da busca e NULL
            ig.igSeparator();
            var sb: [96]u8 = undefined;
            if (ig.igBeginMenu(idLabel(&sb, "menu_search_scope", "scope"), true)) {
                defer ig.igEndMenu();
                const cur = app.prefs.search_scope;
                const pick: ?settings.SearchScope = if (ig.igMenuItem_Bool(tr("scope_table"), null, cur == .table, true))
                    .table
                else if (ig.igMenuItem_Bool(tr("scope_all"), null, cur == .all, true)) .all else null;
                if (pick) |s| {
                    app.prefs.search_scope = s;
                    app.savePrefs();
                    app.setScope(s);
                }
            }
            // padrao da aba Termos: Valor inteiro ou Contem
            var mb: [96]u8 = undefined;
            if (ig.igBeginMenu(idLabel(&mb, "menu_term_match", "term_match"), true)) {
                defer ig.igEndMenu();
                const cur = app.prefs.term_match;
                const pick: ?settings.TermMatch = if (ig.igMenuItem_Bool(tr("match_whole"), null, cur == .whole, true))
                    .whole
                else if (ig.igMenuItem_Bool(tr("match_contains"), null, cur == .contains, true)) .contains else null;
                if (pick) |m| {
                    app.prefs.term_match = m;
                    app.savePrefs();
                    app.terms_match = m;
                }
            }
            if (ig.igMenuItem_Bool(tr("menu_show_null"), null, app.prefs.show_null, true)) {
                app.prefs.show_null = !app.prefs.show_null;
                app.savePrefs();
            }
        }
        if (ig.igBeginMenu(help_l, true)) {
            defer ig.igEndMenu();
            if (ig.igMenuItem_Bool(tr("menu_about"), null, false, true)) app.want_about = true;
        }
        // atalhos do Python (os mesmos nas 4): Ctrl+O, Ctrl+F (busca), F5 (abrir de novo), Ctrl+Q, Ctrl+1/2/3 (abas),
        // Ctrl+L (Log), Ctrl+Enter (rodar o SQL); Ctrl+C fica na grade
        const chord = ig.igIsKeyChordPressed_Nil;
        const ctrl = ig.ImGuiMod_Ctrl;
        if (chord(ctrl | ig.ImGuiKey_O)) app.want_browse = true;
        if (chord(ctrl | ig.ImGuiKey_L)) app.setLogOpen(!app.prefs.log_open);
        if (chord(ctrl | ig.ImGuiKey_Q)) app.requestExit();
        if (has_db) {
            if (chord(ctrl | ig.ImGuiKey_S)) app.want_save = .save;
            if (chord(ctrl | ig.ImGuiMod_Shift | ig.ImGuiKey_S)) app.want_save = .save_as;
            if (chord(ctrl | ig.ImGuiKey_W)) app.want_close = true;
            if (chord(ctrl | ig.ImGuiKey_T)) app.focus_tables = true;
            if (chord(ctrl | ig.ImGuiKey_D)) app.want_fav = app.selected; // favoritar a tabela aberta
            // Ctrl+Shift+C: copiar a linha da celula escolhida na grade da aba atual
            if (chord(ctrl | ig.ImGuiMod_Shift | ig.ImGuiKey_C)) if (app.currentGrid()) |c| copySelection(c.g, c.sel, true, false, c.skip);
            if (chord(ctrl | ig.ImGuiKey_F)) {
                app.want_tab = .data;
                app.focus_search = true;
            }
            if (ig.igIsKeyPressed_Bool(ig.ImGuiKey_F5, false)) app.want_refresh = true;
            // Espaco na aba Dados (fora de uma caixa de texto): marca ou desmarca a linha da celula selecionada
            if (app.tab == .data and !ig.igIsAnyItemActive() and ig.igIsKeyPressed_Bool(ig.ImGuiKey_Space, false)) if (app.data_sel.row) |r| {
                app.want_mark = r;
            };
            if (chord(ctrl | ig.ImGuiKey_1)) app.want_tab = .data;
            if (chord(ctrl | ig.ImGuiKey_2)) app.want_tab = .schema;
            if (chord(ctrl | ig.ImGuiKey_3)) app.want_tab = .sql;
            if (chord(ctrl | ig.ImGuiKey_4)) app.want_tab = .terms;
            // Ctrl+Enter: na aba Termos pesquisa os termos; nas outras roda o SQL
            if (chord(ctrl | ig.ImGuiKey_Enter) or chord(ctrl | ig.ImGuiKey_KeypadEnter)) {
                if (app.tab == .terms) {
                    app.want_terms = true;
                } else if (zstr(&app.sql).len > 0) {
                    app.want_tab = .sql;
                    app.want_run = true;
                }
            }
        }
    }

    // O menu de --menu, uma vez, so depois que o banco abriu e nada esta rodando
    fn takeStartMenu(app: *App, which: @typeInfo(@FieldType(App, "start_menu")).optional.child) bool {
        if (app.start_menu != which or app.slot.busy() or app.want_open or app.want_reload or app.want_run) return false;
        app.start_menu = null;
        return true;
    }

    fn drawAbout(app: *App) void {
        var tb: [96]u8 = undefined;
        const title = idLabel(&tb, "about_title", "about");
        if (app.want_about) {
            _ = ig.igOpenPopup_Str(title, 0);
            app.about_open = true;
        }
        app.want_about = false;
        centerNext();
        if (!ig.igBeginPopupModal(title, &app.about_open, ig.ImGuiWindowFlags_AlwaysAutoResize | ig.ImGuiWindowFlags_NoSavedSettings)) return;
        defer ig.igEndPopup();
        if (!app.about_open) ig.igCloseCurrentPopup(); // --capture fecha pelo estado
        const about = dbm.about;
        // nome e versao em destaque (mesma fonte, maior)
        ig.igPushFont(null, ig.igGetStyle().*.FontSizeBase * 1.4);
        textSlice(about.name ++ " " ++ about.version);
        ig.igPopFont();
        textSlice(tr("about_tagline"));
        ig.igSpacing();
        ig.igSeparator();
        ig.igSpacing();

        var glfw_ver: [3]c_int = undefined;
        glfwGetVersion(&glfw_ver[0], &glfw_ver[1], &glfw_ver[2]);
        var bufs: [5][160]u8 = undefined;
        const rows = [_]struct { [:0]const u8, []const u8 }{
            .{ tr("about_build"), about.build(&bufs[0]) },
            .{ tr("about_stack"), about.stackText(&bufs[1], std.mem.span(ig.igGetVersion())) },
            .{ tr("about_window"), std.fmt.bufPrint(&bufs[2], "GLFW {d}.{d}.{d} + OpenGL 3.3", .{ glfw_ver[0], glfw_ver[1], glfw_ver[2] }) catch "" },
            .{ tr("about_database"), std.fmt.bufPrint(&bufs[3], "DuckDB {s}", .{std.mem.trimStart(u8, dbm.libraryVersion(), "v")}) catch "" },
            .{ tr("about_access"), if (platform.is_windows) i18n.fmt(&bufs[4], "about_access_win", .{about.mdbtools_version}) else i18n.fmt(&bufs[4], "about_access_unix", .{about.mdbtools_version}) },
            .{ tr("about_write"), tr("about_write_value") },
            .{ tr("about_author"), about.author },
            .{ tr("about_license"), tr("about_license_text") },
        };
        if (ig.igBeginTable("##about_rows", 2, ig.ImGuiTableFlags_SizingFixedFit, .{ .x = 0, .y = 0 }, 0)) {
            defer ig.igEndTable();
            // a linha de Gravacao (mais longa) quebra na largura da de Leitura do Access: o dialogo fica do mesmo tamanho
            const wrap_w = rawWidth(rows[4][1]) + 1;
            for (rows) |row| {
                ig.igTableNextRow(0, 0);
                _ = ig.igTableNextColumn();
                ig.igTextDisabled("%s", row[0].ptr);
                _ = ig.igTableNextColumn();
                ig.igPushTextWrapPos(ig.igGetCursorPosX() + wrap_w);
                textSlice(row[1]);
                ig.igPopTextWrapPos();
            }
            for (about.links) |link| {
                ig.igTableNextRow(0, 0);
                _ = ig.igTableNextColumn();
                ig.igTextDisabled("%s", link.label.ptr);
                _ = ig.igTableNextColumn();
                if (ig.igTextLink(link.url)) openLink(link.url);
                itemTooltip(tr("about_open_browser"));
            }
        }
        ig.igSpacing();
        ig.igSeparator();
        ig.igSpacing();
        // Fechar a direita, do mesmo tamanho dos botoes dos outros dialogos
        const close_l = tr("close");
        const bw = dialogButtonWidth(&.{"close"});
        ig.igSetCursorPosX(ig.igGetCursorPosX() + ig.igGetContentRegionAvail().x - bw);
        if (ig.igButton(close_l, .{ .x = bw, .y = 0 }) or dialogKeyClose()) ig.igCloseCurrentPopup();
    }

    // Linux sem X11: aviso curto da abertura (Wayland por reserva): 2 linhas de texto, a distro com o comando
    // selecionavel e Copiar, o link Ajuda (abre o navegador) e OK
    fn drawDisplayWarning(app: *App) void {
        const w = if (app.display_warning) |*x| x else return;
        var tb: [96]u8 = undefined;
        const title = idLabel(&tb, "display_title", "display");
        if (!app.display_shown) {
            _ = ig.igOpenPopup_Str(title, 0);
            app.display_shown = true;
        }
        centerNext();
        if (!ig.igBeginPopupModal(title, null, ig.ImGuiWindowFlags_AlwaysAutoResize | ig.ImGuiWindowFlags_NoSavedSettings)) return;
        defer ig.igEndPopup();
        if (app.display_dismiss) {
            app.display_warning = null;
            return ig.igCloseCurrentPopup();
        }
        const text = w.text();
        const lines_end = if (w.command_len > 0) std.mem.lastIndexOfScalar(u8, text[0..w.command_start], '\n') orelse text.len else text.len;
        ig.igPushTextWrapPos(ig.igGetFontSize() * 34);
        textSlice(text[0..lines_end]);
        ig.igPopTextWrapPos();
        const copy_l = tr("copy");
        const ok_l = tr("ok");
        const bw = dialogButtonWidth(&.{ "copy", "ok" });
        if (w.command_len > 0) {
            // "<distro>:" e o comando numa caixa somente leitura (selecionavel) com Copiar ao lado
            ig.igAlignTextToFramePadding();
            textSlice(text[lines_end + 1 .. w.command_start]);
            ig.igSameLine(0, -1);
            const cmd = std.fmt.bufPrintSentinel(&app.display_cmd, "{s}", .{w.command()}, 0) catch "";
            ig.igSetNextItemWidth(@max(textWidth(cmd) + 2 * ig.igGetStyle().*.FramePadding.x + 4, ig.igGetFontSize() * 12));
            _ = ig.igInputText("##displaycmd", &app.display_cmd, app.display_cmd.len + 1, ig.ImGuiInputTextFlags_ReadOnly, null, null);
            ig.igSameLine(0, -1);
            if (ig.igButton(copy_l, .{ .x = bw, .y = 0 })) setClipboard(cmd);
        }
        ig.igSpacing();
        ig.igAlignTextToFramePadding();
        if (ig.igTextLink(tr("display_help"))) if (main_io) |io| platform.openUrl(io, dbm.display.help_url);
        ig.igSameLine(0, -1);
        ig.igSetCursorPosX(ig.igGetCursorPosX() + @max(0, ig.igGetContentRegionAvail().x - bw));
        if (ig.igButton(ok_l, .{ .x = bw, .y = 0 }) or dialogKeyClose()) {
            app.display_warning = null;
            ig.igCloseCurrentPopup();
        }
    }

    // Perguntas ao sair do programa. Access convertido e nao salvo: "Salvar" a esquerda; "Voltar" e "Sair" a direita,
    // lado a lado. Exportacao em andamento: "Voltar" e "Sair" (Sair cancela a exportacao; o arquivo pela metade e
    // apagado). Esc e o X da caixa = Voltar.
    fn drawExit(app: *App) void {
        var tb: [2][96]u8 = undefined;
        const titles = [_][:0]const u8{ idLabel(&tb[0], "export_run_title", "exit_export"), idLabel(&tb[1], "converted_title", "exit_unsaved") };
        for (titles, [_]ExitAsk{ .export_running, .unsaved }) |title, kind| {
            const want = app.exit_ask == kind;
            if (want and !ig.igIsPopupOpen_Str(title, 0)) _ = ig.igOpenPopup_Str(title, 0);
            centerNext();
            var open = true;
            if (!ig.igBeginPopupModal(title, &open, ig.ImGuiWindowFlags_AlwaysAutoResize | ig.ImGuiWindowFlags_NoSavedSettings)) {
                if (!open and want) app.exit_ask = null; // o X fecha o popup antes de chegar aqui
                continue;
            }
            defer ig.igEndPopup();
            if (!want or !open or ig.igIsKeyPressed_Bool(ig.ImGuiKey_Escape, false)) {
                if (want) app.exit_ask = null;
                ig.igCloseCurrentPopup();
                continue;
            }
            var mb: [1300]u8 = undefined;
            const source = if (app.converted) |*cv| zstr(&cv.source) else "";
            ig.igPushTextWrapPos(ig.igGetFontSize() * 30);
            textSlice(if (kind == .unsaved)
                i18n.fmt(&mb, "exit_text", .{std.fs.path.basename(source)})
            else
                i18n.fmt(&mb, "export_run_text", .{std.fs.path.basename(app.slot.req.destPath())}));
            ig.igPopTextWrapPos();
            ig.igSpacing();
            const save_l = tr("btn_save");
            const back_l = tr("btn_back");
            const exit_l = tr("btn_exit");
            const bw = dialogButtonWidth(&.{ "btn_save", "btn_back", "btn_exit" });
            if (kind == .unsaved) {
                // Salvar abre a caixa de Arquivo > Salvar; cancelada, esta pergunta volta
                if (ig.igButton(save_l, .{ .x = bw, .y = 0 })) {
                    app.exit_ask = null;
                    app.exit_save = true;
                    app.want_save = .save;
                    ig.igCloseCurrentPopup();
                }
                focusOnAppear(); // foco inicial visivel em Salvar
                ig.igSameLine(0, -1);
            }
            ig.igSetCursorPosX(ig.igGetCursorPosX() + @max(0, ig.igGetContentRegionAvail().x - 2 * bw - ig.igGetStyle().*.ItemSpacing.x));
            if (ig.igButton(back_l, .{ .x = bw, .y = 0 })) {
                app.exit_ask = null;
                ig.igCloseCurrentPopup();
            }
            if (kind == .export_running) focusOnAppear(); // exportacao em andamento: foco em Voltar
            ig.igSameLine(0, -1);
            if (ig.igButton(exit_l, .{ .x = bw, .y = 0 })) {
                app.exit_ask = null;
                ig.igCloseCurrentPopup();
                if (kind == .export_running) {
                    app.slot.cancel();
                    app.exitUnlessUnsaved();
                } else app.quit = true;
            }
        }
    }

    // Exportar a tabela com busca ou filtro ativo: "Tabela inteira" / "So as <n> linhas encontradas" / Cancelar
    // (Esc e o X cancelam); a resposta segue para o dialogo de salvar
    fn drawExportScope(app: *App) void {
        var tb: [96]u8 = undefined;
        const title = idLabel(&tb, "menu_export", "export_scope");
        const kind = app.ask_export;
        if (kind != null and !ig.igIsPopupOpen_Str(title, 0)) _ = ig.igOpenPopup_Str(title, 0);
        centerNext();
        var open = true;
        if (!ig.igBeginPopupModal(title, &open, ig.ImGuiWindowFlags_AlwaysAutoResize | ig.ImGuiWindowFlags_NoSavedSettings)) {
            if (!open) app.ask_export = null;
            return;
        }
        defer ig.igEndPopup();
        if (kind == null) return ig.igCloseCurrentPopup();
        if (!open or ig.igIsKeyPressed_Bool(ig.ImGuiKey_Escape, false)) {
            app.ask_export = null;
            return ig.igCloseCurrentPopup();
        }
        const index = app.selected orelse {
            app.ask_export = null;
            return ig.igCloseCurrentPopup();
        };
        var mb: [600]u8 = undefined;
        ig.igPushTextWrapPos(ig.igGetFontSize() * 30);
        textSlice(i18n.fmt(&mb, "export_scope_text", .{app.db.table_names[index]}));
        ig.igPopTextWrapPos();
        ig.igSpacing();
        var fb: [160]u8 = undefined;
        const whole_l = tr("export_whole");
        const found_l = i18n.fmtCountZ(&fb, "export_found", app.total, .{app.total});
        const cancel_l = tr("cancel");
        // "So as N linhas encontradas" tem o numero: a largura dele nos 3 idiomas entra na conta
        var bw = dialogButtonWidth(&.{ "export_whole", "cancel" });
        inline for (i18n.catalogs) |C| {
            var cb: [160]u8 = undefined;
            const s = (if (app.total == 1) std.fmt.bufPrint(&cb, C.export_found_one, .{app.total}) else std.fmt.bufPrint(&cb, C.export_found, .{app.total})) catch "";
            bw = @max(bw, textWidth(s) + 2 * ig.igGetStyle().*.FramePadding.x);
        }
        const answer: ?ExportScope = blk: {
            if (ig.igButton(whole_l, .{ .x = bw, .y = 0 })) break :blk .whole;
            if (ig.igIsWindowAppearing()) {
                ig.igSetItemDefaultFocus();
                ig.igSetKeyboardFocusHere(-1);
                ig.igSetNavCursorVisible(true);
            }
            ig.igSameLine(0, -1);
            if (ig.igButton(found_l, .{ .x = bw, .y = 0 })) break :blk .found;
            ig.igSameLine(0, -1);
            if (ig.igButton(cancel_l, .{ .x = bw, .y = 0 })) {
                app.ask_export = null;
                ig.igCloseCurrentPopup();
            }
            break :blk null;
        };
        if (answer) |a| {
            app.export_scope = a;
            app.want_export = kind;
            app.ask_export = null;
            ig.igCloseCurrentPopup();
        }
    }

    // Painel de Log embaixo: cabecalho (seta para recolher, titulo, Copiar tudo, Limpar) e as mensagens da sessao
    // com a hora, em fonte monoespacada um passo menor; texto selecionavel (Ctrl+C). Rola sozinho para a ultima linha.
    fn drawLogPanel(app: *App, h: f32) void {
        markLogRead(); // aberto: tudo esta a vista
        defer ig.igEndChild();
        ig.igPushStyleVar_Vec2(ig.ImGuiStyleVar_WindowPadding, .{ .x = 8, .y = log_pad_y }); // painel enxuto
        const visible = ig.igBeginChild_Str("##logpanel", .{ .x = 0, .y = h }, ig.ImGuiChildFlags_Borders, ig.ImGuiWindowFlags_NoScrollbar);
        ig.igPopStyleVar(1);
        if (!visible) return;
        if (ig.igArrowButton("##logclose", ig.ImGuiDir_Down)) app.setLogOpen(false);
        itemTooltip(tr("log_hide"));
        ig.igSameLine(0, -1);
        ig.igAlignTextToFramePadding();
        textSlice(tr("log_title"));
        const copy_l = tr("copy_all");
        const clear_l = tr("clear");
        const right = buttonWidth(copy_l) + buttonWidth(clear_l) + ig.igGetStyle().*.ItemSpacing.x;
        ig.igSameLine(0, -1);
        ig.igSetCursorPosX(ig.igGetCursorPosX() + @max(0, ig.igGetContentRegionAvail().x - right));
        if (button(copy_l)) setClipboard(session_log.slice());
        ig.igSameLine(0, -1);
        if (button(clear_l)) session_log.clear();
        // somente leitura: o ImGui seleciona e copia (Ctrl+C) sem mudar o texto
        const empty = struct {
            var z: [1:0]u8 = .{0};
        };
        const buf: [*]u8 = if (session_log.text.items.len > 0) session_log.text.items.ptr else &empty.z;
        const len = if (session_log.text.items.len > 0) session_log.text.items.len else 1;
        if (len != app.log_seen) ig.igSetNextWindowScroll(.{ .x = 0, .y = 1e9 }); // linha nova: vai para o fim
        app.log_seen = len;
        ig.igPushFont(mono_font, @max(13, ig.igGetFontSize() - 2));
        _ = ig.igInputTextMultiline("##logtext", @ptrCast(buf), len, .{ .x = -1, .y = -1 }, ig.ImGuiInputTextFlags_ReadOnly, null, null);
        ig.igPopFont();
    }

    // Barra de baixo (a do Go): a esquerda a seta que abre/recolhe o Log e a mensagem (ou o trabalho em andamento,
    // com progresso e Cancelar); a direita, fixos, os erros/avisos nao lidos do Log, as colunas ocultas da grade atual
    // e o modo de leitura do arquivo aberto. Com o Log recolhido a mensagem e o erro ou aviso ainda nao visto
    // (destacado), senao o status; clicar nela abre o Log. Mensagem longa termina em "..." (inteira no tooltip).
    fn drawStatus(app: *App) void {
        const open = app.prefs.log_open;
        if (ig.igArrowButton("##logtoggle", if (open) ig.ImGuiDir_Down else ig.ImGuiDir_Up)) app.setLogOpen(!open);
        itemTooltip(if (open) tr("log_hide") else tr("log_show"));
        ig.igSameLine(0, -1);

        // a direita, medida antes: a mensagem para onde ela comeca
        const gap = 2 * ig.igGetStyle().*.ItemSpacing.x;
        const unread = if (open) 0 else alert.unread();
        var ub: [24]u8 = undefined;
        var hb: [64]u8 = undefined;
        var sb: [160]u8 = undefined;
        const right = [_][]const u8{
            if (unread > 0) std.fmt.bufPrint(&ub, "{d}", .{unread}) catch "" else "",
            app.hiddenNow(&hb),
            app.sourceText(&sb),
        };
        var right_w: f32 = 0;
        for (right) |s| if (s.len > 0) {
            right_w += gap + rawWidth(s);
        };
        const right_x = ig.igGetCursorPosX() + ig.igGetContentRegionAvail().x - right_w; // x local do bloco
        defer drawStatusRight(&right, right_x, gap, unread);

        const elapsed = ig.igGetTime() - app.busy_since;
        if (app.slot.busy() and elapsed > 0.15) {
            const r = &app.slot.req;
            const done = app.slot.progress.done.load(.monotonic);
            const total = app.slot.progress.total.load(.monotonic);
            ig.igAlignTextToFramePadding();
            var wb: [600]u8 = undefined;
            const what = switch (r.kind) {
                .open => if (query.sourceKind(zstr(&r.path)) catch .duckdb == .access) tr("busy_converting") else tr("busy_opening"),
                .select, .reload, .terms_page => tr("busy_loading"),
                .sql, .terms_copy => tr("busy_running"),
                .export_ => tr("busy_exporting"),
                .search_all => tr("busy_searching"),
                // "Pesquisando termos: tabela 3 de 287 (RANGER_SOSTAT)"
                .terms => blk: {
                    const names = app.db.table_names;
                    const at = if (r.terms_only) |o| o else @min(done, names.len -| 1);
                    break :blk i18n.fmt(&wb, "terms_progress", .{ @min(done + 1, @max(total, 1)), @max(total, 1), if (at < names.len) names[at] else "" });
                },
            };
            textT("busy_elapsed", .{ what, elapsed });
            if (total > 0 and (r.kind == .open or r.kind == .export_ or r.kind == .search_all or r.kind == .terms)) {
                ig.igSameLine(0, -1);
                var buf: [64]u8 = undefined;
                const unit = if (r.kind != .export_ or r.export_kind.countsTables()) i18n.trCount("unit_tables", total) else i18n.trCount("unit_rows", total);
                const overlay = i18n.fmtZ(&buf, "progress_overlay", .{ done, total, unit });
                const frac: f32 = @floatCast(@as(f64, @floatFromInt(@min(done, total))) / @as(f64, @floatFromInt(total)));
                ig.igProgressBar(frac, .{ .x = 240, .y = 0 }, overlay);
            }
            ig.igSameLine(0, -1);
            if (button(tr("cancel"))) app.slot.cancel();
            return;
        }
        ig.igAlignTextToFramePadding();
        // erro em vermelho, aviso em ambar; sem arquivo, "Nenhum banco aberto" apagado
        var shown: []const u8 = app.status.text();
        var color: ?[3]f32 = if (app.status.is_err) errorColor() else null;
        if (unread > 0 and alert.len > 0) {
            shown = alert.text();
            color = if (alert.level == .err) errorColor() else warnColor();
        }
        const empty = shown.len == 0;
        if (empty) shown = tr("no_db");
        var fb: [1100]u8 = undefined;
        const line = fitLine(&fb, shown, right_x - ig.igGetCursorPosX() - gap);
        if (color) |c| pushTextColor(c) else if (empty) ig.igPushStyleColor_U32(ig.ImGuiCol_Text, ig.igGetColorU32_Col(ig.ImGuiCol_TextDisabled, 1));
        textSlice(line);
        if (color != null or empty) ig.igPopStyleColor(1);
        if (line.len != shown.len and ig.igIsItemHovered(0)) tooltip(shown);
        const line_clicked = ig.igIsItemClicked(0);
        // clique direito na linha de status: Copiar (o texto inteiro, como aparece) e Log
        if (ig.igBeginPopupContextItem("##status_menu", ig.ImGuiPopupFlags_MouseButtonRight)) {
            defer ig.igEndPopup();
            if (ig.igMenuItem_Bool(tr("copy"), null, false, !empty)) setClipboard(shown);
            if (ig.igMenuItem_Bool(tr("log_show"), null, false, !open)) app.setLogOpen(true);
        }
        if (!open and line_clicked) app.setLogOpen(true);
    }

    // Direita da barra de baixo: nao lidos (com a frase no tooltip), colunas ocultas e o modo de leitura. Durante um
    // trabalho o bloco so aparece se couber depois do progresso (nunca por cima dele).
    fn drawStatusRight(right: []const []const u8, right_x: f32, gap: f32, unread: u32) void {
        const win_x = ig.igGetWindowPos().x - ig.igGetScrollX();
        if (ig.igGetItemRectMax().x - win_x + gap > right_x + 1) return;
        var x = right_x;
        for (right, 0..) |s, i| {
            if (s.len == 0) continue;
            x += gap;
            ig.igSameLine(0, 0);
            ig.igSetCursorPosX(x);
            textSlice(s);
            if (ig.igIsItemHovered(0)) {
                var tb: [96]u8 = undefined;
                if (i == 0) tooltip(i18n.fmtCount(&tb, "log_unread", unread, .{unread}));
                if (i == 2) tooltip(tr("source_tip"));
            }
            x += rawWidth(s);
        }
    }

    fn drawTables(app: *App) void {
        if (app.focus_tables) { // Ctrl+T
            app.focus_tables = false;
            ig.igSetKeyboardFocusHere(0);
        }
        ig.igSetNextItemWidth(-1);
        // filtra 300 ms depois da ultima tecla; Enter filtra na hora
        var hb: [96]u8 = undefined;
        if (ig.igInputTextWithHint("##filter", i18n.fmtCountZ(&hb, "filter_tables", app.db.table_names.len, .{app.db.table_names.len}), &app.table_filter, app.table_filter.len + 1, ig.ImGuiInputTextFlags_EnterReturnsTrue, null, null)) {
            app.table_filter_wait.due = null;
            app.table_filter_applied = app.table_filter;
        } else if (ig.igIsItemEdited()) app.table_filter_wait.edited(ig.igGetTime());
        itemTooltip(tr("search_rule"));
        // colunas na largura do conteudo: o nome inteiro aparece (rolagem horizontal se o painel for estreito)
        const flags = ig.ImGuiTableFlags_RowBg | ig.ImGuiTableFlags_ScrollY | ig.ImGuiTableFlags_ScrollX | ig.ImGuiTableFlags_BordersInnerV;
        if (!ig.igBeginTable("##tbl", 2, flags, .{ .x = 0, .y = 0 }, 0)) return;
        defer ig.igEndTable();
        ig.igTableSetupScrollFreeze(0, 1);
        ig.igTableSetupColumn(tr("col_table"), ig.ImGuiTableColumnFlags_WidthFixed, 0, 0);
        ig.igTableSetupColumn(tr("col_rows"), ig.ImGuiTableColumnFlags_WidthFixed, 0, 0);
        // cabecalho com "Linhas" a direita, como os numeros
        ig.igTableNextRow(ig.ImGuiTableRowFlags_Headers, ig.igTableGetHeaderRowHeight());
        if (ig.igTableSetColumnIndex(0)) ig.igTableHeader(tr("col_table"));
        if (ig.igTableSetColumnIndex(1)) {
            _ = rightHeader(tr("col_rows"), 0);
        }
        var fbuf: [app.table_filter.len]u8 = undefined;
        const words = dbm.gridtools.fold(&fbuf, zstr(&app.table_filter_applied));
        // favoritas primeiro, em ordem alfabetica; depois as outras na ordem do arquivo (o filtro vale para todas)
        dbm.gridtools.tableOrder(app.gpa, &app.table_order, &app.filter_scratch, app.db.table_names, app.favorites.items, words) catch {};
        for (app.table_order.items) |i| {
            const name = app.db.table_names[i];
            const fav = dbm.gridtools.isFavorite(app.favorites.items, name);
            ig.igTableNextRow(0, 0);
            _ = ig.igTableNextColumn();
            ig.igPushID_Int(@intCast(i));
            // "##" + PushID: o rotulo fica vazio e o nome (que nao termina em 0) vai por textSlice
            if (ig.igSelectable_Bool("##t", app.selected == i, ig.ImGuiSelectableFlags_SpanAllColumns, .{ .x = 0, .y = 0 })) {
                app.want_select = i;
                app.scope = .table; // a aba Data mostra a tabela escolhida
            }
            const hovered = ig.igIsItemHovered(0);
            // clique direito: Favoritar / Desfavoritar (--capture abre o menu sem mouse, logo abaixo da linha)
            if (app.fav_menu == i) {
                app.fav_menu = null;
                _ = ig.igOpenPopup_Str("##tablemenu", 0);
                ig.igSetNextWindowPos(.{ .x = ig.igGetItemRectMin().x + 24, .y = ig.igGetItemRectMax().y }, ig.ImGuiCond_Always, .{ .x = 0, .y = 0 });
            }
            if (ig.igBeginPopupContextItem("##tablemenu", ig.ImGuiPopupFlags_MouseButtonRight)) {
                defer ig.igEndPopup();
                if (ig.igMenuItem_Bool(if (fav) tr("fav_remove") else tr("fav_add"), null, false, true)) app.want_fav = i;
            }
            ig.igPopID();
            if (app.selected == i and app.reveal_selected) {
                ig.igSetScrollHereY(0.5);
                app.reveal_selected = false;
            }
            ig.igSameLine(0, 0);
            // nome mais largo que a coluna (painel estreito): o nome inteiro aparece no tooltip
            if (hovered and textWidth(name) > ig.igGetContentRegionAvail().x) tooltip(name);
            // favorita: "★ " antes do nome, na cor do texto
            if (fav) {
                textSlice("\u{2605} ");
                ig.igSameLine(0, 0);
            }
            textSlice(name);
            _ = ig.igTableNextColumn();
            if (i < app.counts.len) {
                var nb: [24]u8 = undefined;
                const n = std.fmt.bufPrint(&nb, "{d}", .{app.counts[i]}) catch "";
                rightAlign(textWidth(n), 0);
                textSlice(n);
            }
        }
    }

    fn drawContent(app: *App) void {
        if (!ig.igBeginTabBar("##tabs", 0)) return;
        defer ig.igEndTabBar();
        var lb: [4][64]u8 = undefined;
        // aba pedida por atalho (Ctrl+1/2/3/4, Ctrl+F, Ctrl+Enter) ou pelo --sql
        const pick = app.want_tab;
        app.want_tab = null;
        const sel = ig.ImGuiTabItemFlags_SetSelected;

        if (ig.igBeginTabItem(idLabel(&lb[0], "tab_data", "data"), null, if (pick == .data) sel else 0)) {
            defer ig.igEndTabItem();
            app.tab = .data;
            app.drawData();
        }
        if (ig.igBeginTabItem(idLabel(&lb[1], "tab_schema", "schema"), null, if (pick == .schema) sel else 0)) {
            defer ig.igEndTabItem();
            app.tab = .schema;
            if (app.schema) |*g| {
                // cabecalhos no idioma da tela (o Grid guarda os nomes em ingles)
                const cols = [_][:0]const u8{ tr("schema_column"), tr("schema_type"), tr("schema_null") };
                var shown = g.*;
                shown.columns = &cols;
                // um pouco mais de espaco entre as colunas (so o horizontal das celulas, +6 px de cada lado)
                const pad = ig.igGetStyle().*.CellPadding;
                ig.igPushStyleVar_Vec2(ig.ImGuiStyleVar_CellPadding, .{ .x = pad.x * 2, .y = pad.y });
                _ = drawGrid("##schema", &shown, null, &app.schema_sel, null, .plain, &app.prefs, "", 0, null);
                ig.igPopStyleVar(1);
            }
        }
        if (ig.igBeginTabItem(idLabel(&lb[2], "tab_sql", "sql"), null, if (pick == .sql) sel else 0)) {
            defer ig.igEndTabItem();
            app.tab = .sql;
            app.drawSql();
        }
        if (ig.igBeginTabItem(idLabel(&lb[3], "tab_terms", "terms"), null, if (pick == .terms) sel else 0)) {
            defer ig.igEndTabItem();
            app.tab = .terms;
            app.drawTerms();
        }
    }

    // Aba Termos (item 32), de cima para baixo: a caixa dos termos; Valor inteiro | Contem, Esta tabela | Todas as
    // tabelas, Pesquisar termos e a contagem; o resumo; as tabelas com acerto e a grade da escolhida; os nao
    // encontrados numa caixa copiavel
    fn drawTerms(app: *App) void {
        const st = ig.igGetStyle();
        const box_h = ig.igGetTextLineHeight() * 8 + 2 * st.*.FramePadding.y;
        // Ctrl+Enter na caixa pesquisa (Enter quebra a linha)
        if (ig.igInputTextEx("##terms", tr("terms_hint"), app.terms_text.ptr, @intCast(app.terms_text.len), .{ .x = -1, .y = box_h }, ig.ImGuiInputTextFlags_Multiline | ig.ImGuiInputTextFlags_EnterReturnsTrue, null, null)) app.want_terms = true;
        if (ig.igIsItemEdited()) app.countTerms();
        const match_l = [_][:0]const u8{ tr("match_whole"), tr("match_contains") };
        var match_hover = false;
        if (segmented(1, &match_l, @intFromBool(app.terms_match == .contains), &match_hover)) |i| app.terms_match = if (i == 0) .whole else .contains;
        if (match_hover) tooltip(tr("match_tip"));
        const scope_l = [_][:0]const u8{ tr("scope_table"), tr("scope_all") };
        sameLineIfFits(segmentedWidth(&scope_l), -1);
        if (segmented(2, &scope_l, @intFromBool(app.terms_scope == .all), null)) |i| app.terms_scope = if (i == 0) .table else .all;
        const run_l = tr("terms_run");
        sameLineIfFits(buttonWidth(run_l), -1);
        ig.igBeginDisabled(app.slot.busyWith(.terms) or app.terms_counted[0] == 0);
        if (button(run_l)) app.want_terms = true;
        ig.igEndDisabled();
        // "8 termos, 1 repetido"
        var cb: [64]u8 = undefined;
        var rb: [64]u8 = undefined;
        var lb: [140]u8 = undefined;
        const n, const rep = app.terms_counted;
        const count_s = std.fmt.bufPrint(&lb, "{s}{s}", .{ i18n.fmtCount(&cb, "terms_count", n, .{n}), if (rep > 0) i18n.fmtCount(&rb, "terms_repeated", rep, .{rep}) else "" }) catch "";
        sameLineIfFits(rawWidth(count_s), -1);
        ig.igAlignTextToFramePadding();
        textSlice(count_s);

        const res = if (app.terms_res) |*x| x else return;
        // "6 de 9 termos encontrados: 14 linhas em 3 tabelas"
        var sb: [3][96]u8 = undefined;
        var summary: [400]u8 = undefined;
        const n_terms = res.terms.len;
        textSlice(i18n.fmt(&summary, "terms_summary", .{
            i18n.fmtCount(&sb[0], "terms_found", n_terms, .{ res.found, n_terms }),
            i18n.fmtCount(&sb[1], "terms_rows", res.rows, .{res.rows}),
            i18n.fmtCount(&sb[2], "terms_tables", res.tables.len, .{res.tables.len}),
        }));
        // "Esta tabela" (item 17): diz onde pesquisou, para nunca parecer que o termo nao existe no banco
        if (res.only) |ti| if (ti < app.db.table_names.len) {
            ig.igSameLine(0, 0);
            var ob: [600]u8 = undefined;
            textSlice(i18n.fmt(&ob, "terms_only_in", .{app.db.table_names[ti]}));
        };
        // embaixo: o titulo dos nao encontrados com Copiar e a caixa deles (4 linhas)
        const nf_box_h = ig.igGetTextLineHeight() * 4 + 2 * st.*.FramePadding.y;
        const nf_h = ig.igGetFrameHeightWithSpacing() + nf_box_h + st.*.ItemSpacing.y;
        const mid_h = @max(ig.igGetFrameHeight() * 3, ig.igGetContentRegionAvail().y - nf_h);
        if (res.tables.len > 0) {
            // lista "tabela (n)", na largura do nome mais longo (ate 35% da aba)
            var longest: f32 = 0;
            var nb: [600]u8 = undefined;
            for (res.tables) |hit| longest = @max(longest, rawWidth(std.fmt.bufPrint(&nb, "{s} ({d})", .{ app.db.table_names[hit.table], hit.rows }) catch ""));
            const list_w = std.math.clamp(longest + 2 * st.*.WindowPadding.x + st.*.ScrollbarSize, 160, @max(160, ig.igGetContentRegionAvail().x * 0.35));
            if (ig.igBeginChild_Str("##terms_tables", .{ .x = list_w, .y = mid_h }, ig.ImGuiChildFlags_Borders, 0)) {
                for (res.tables, 0..) |hit, i| {
                    ig.igPushID_Int(@intCast(i));
                    if (ig.igSelectable_Bool("##h", app.terms_hit == i, 0, .{ .x = 0, .y = 0 }) and i != app.terms_hit) app.want_terms_page = i;
                    ig.igPopID();
                    ig.igSameLine(0, 0);
                    textSlice(std.fmt.bufPrint(&nb, "{s} ({d})", .{ app.db.table_names[hit.table], hit.rows }) catch app.db.table_names[hit.table]);
                }
            }
            ig.igEndChild();
            ig.igSameLine(0, -1);
            if (ig.igBeginChild_Str("##terms_grid", .{ .x = 0, .y = mid_h }, 0, 0)) if (app.terms_hit < res.tables.len) {
                const hit = res.tables[app.terms_hit];
                const name = app.db.table_names[hit.table];
                const count_h = ig.igGetFrameHeight() + st.*.ItemSpacing.y;
                if (app.terms_grid) |*g| _ = drawGrid("##termsgrid", g, null, &app.terms_sel, null, .terms, &app.prefs, name, count_h, null);
                // "<tabela>: mostrando X de Y linhas" (as linhas achadas; copiar e exportar usam todas)
                const shown: u64 = if (app.terms_grid) |g| g.rows.len else 0;
                var rlb: [700]u8 = undefined;
                var fb: [760]u8 = undefined;
                const line = i18n.fmtCount(&rlb, "rows_showing", hit.rows, .{ name, shown, hit.rows });
                ig.igAlignTextToFramePadding();
                const fitted = fitLine(&fb, line, ig.igGetContentRegionAvail().x);
                textSlice(fitted);
                if (fitted.len != line.len and ig.igIsItemHovered(0)) tooltip(line);
            };
            ig.igEndChild();
            // pedidos do menu da grade
            if (app.terms_sel.want_copy_hits) app.want_terms_copy = true;
            if (app.terms_sel.want_export) |k| app.want_export = k;
            app.terms_sel.want_copy_hits = false;
            app.terms_sel.want_export = null;
        } else ig.igDummy(.{ .x = 1, .y = mid_h });
        // "Nao encontrados (2)" + Copiar; um termo por linha, na ordem colada
        ig.igAlignTextToFramePadding();
        textT("not_found_title", .{n_terms - res.found});
        ig.igSameLine(0, -1);
        if (button(tr("copy"))) setClipboard(res.not_found);
        _ = ig.igInputTextMultiline("##notfound", @constCast(res.not_found.ptr), res.not_found.len + 1, .{ .x = -1, .y = nf_box_h }, ig.ImGuiInputTextFlags_ReadOnly, null, null);
    }

    fn drawData(app: *App) void {
        const index = app.selected orelse return ig.igTextDisabled("%s", tr("select_table").ptr);
        const name = app.db.table_names[index];
        // ID por tabela: o ImGui guarda ordenacao e larguras por ID, e cada tabela tem as suas
        ig.igPushID_Int(@intCast(index));
        defer ig.igPopID();

        // a busca ocupa o que sobra da linha depois do seletor e (em "Esta tabela") de Linhas e Colunas...; minimo de
        // 8 letras. Janela estreita (720 px): Linhas e Colunas descem, depois o seletor (nada cortado)
        const st = ig.igGetStyle();
        const gap = st.*.ItemSpacing.x;
        const selector_w = buttonWidth(tr("scope_table")) + buttonWidth(tr("scope_all"));
        const rows_l = tr("rows_label");
        const combo_w = textWidth("0000") + ig.igGetFrameHeight() + 2 * st.*.FramePadding.x;
        const limit_w = textWidth(rows_l) + gap + combo_w;
        // +2 gaps de folga em cada parte: sameLineIfFits mede pela borda da janela, um pouco antes da borda do painel
        const tail_w = if (app.scope == .table) limit_w + buttonWidth(tr("columns_button")) + 4 * gap else 0;
        if (app.focus_search) { // Ctrl+F
            app.focus_search = false;
            ig.igSetKeyboardFocusHere(0);
        }
        ig.igSetNextItemWidth(dbm.gridtools.searchWidth(ig.igGetContentRegionAvail().x, ig.igGetFontSize() * 8, selector_w + 3 * gap, tail_w));
        // busca 300 ms depois da ultima tecla; Enter busca na hora
        if (ig.igInputTextWithHint("##search", tr("search"), &app.search, app.search.len + 1, ig.ImGuiInputTextFlags_EnterReturnsTrue, null, null)) {
            app.runSearch();
        } else if (ig.igIsItemEdited()) app.search_wait.edited(ig.igGetTime());
        itemTooltip(tr("search_rule"));
        sameLineIfFits(selector_w, -1);
        app.scopeSelector();
        if (app.scope == .all) return app.drawGlobal();
        // Linhas: 100 / 500 / 1000 primeiras linhas (da busca e dos filtros, na ordem da grade); o rotulo e a lista
        // descem juntos se nao couberem
        sameLineIfFits(limit_w, -1);
        ig.igAlignTextToFramePadding();
        textSlice(rows_l);
        ig.igSameLine(0, -1);
        ig.igSetNextItemWidth(combo_w);
        var lb: [16]u8 = undefined;
        if (ig.igBeginCombo("##limit", std.fmt.bufPrintSentinel(&lb, "{d}", .{app.limit}, 0) catch "", 0)) {
            defer ig.igEndCombo();
            for (query.row_limits) |n| {
                var nb: [16]u8 = undefined;
                const item = std.fmt.bufPrintSentinel(&nb, "{d}", .{n}, 0) catch continue;
                if (ig.igSelectable_Bool(item, n == app.limit, 0, .{ .x = 0, .y = 0 }) and n != app.limit) {
                    app.limit = n;
                    app.reloadFirstPage();
                }
            }
        }
        // exportar a tabela fica so no Exportar... da barra de cima (um botao por acao)
        sameLineIfFits(buttonWidth(tr("columns_button")), -1);
        columnsButton(&app.data_sel);

        // Abaixo da busca, igual nas 4 (padrao 24): so com filtros por valor, a linha deles; a grade; embaixo dela a
        // contagem com as paginas ◀ ▶ (item 13 h). Nada acima da grade.
        // Filtros ativos: um botao por filtro (clicar remove) e Limpar filtros; o que nao cabe desce de linha
        const filters_l = tr("filters_label");
        for (app.filters.items, 0..) |f, i| {
            var label: [200]u8 = undefined;
            const chip = dbm.gridtools.filterLabel(&label, f);
            if (i == 0) {
                ig.igAlignTextToFramePadding();
                ig.igTextDisabled("%s", filters_l.ptr);
            }
            sameLineIfFits(buttonWidth(chip), -1);
            ig.igPushID_Int(@intCast(i));
            if (button(chip)) app.want_unfilter = i;
            itemTooltip(tr("remove_filter"));
            ig.igPopID();
        }
        if (app.filters.items.len > 0) {
            const clear_l = tr("clear_filters");
            sameLineIfFits(buttonWidth(clear_l), -1);
            if (button(clear_l)) app.want_clear_filters = true;
        }

        app.data_sel.has_filters = app.filters.items.len > 0;
        // a grade deixa embaixo a linha da contagem
        const count_h = ig.igGetFrameHeight() + st.*.ItemSpacing.y;
        const n_marked = app.marksOf(index).len;
        // a coluna das caixas de marcar so com a identidade das linhas (a grade carregada com ela)
        const marking: ?Marking = if (app.data) |g| (if (g.keys.len == g.rows.len) Marking{ .top = app.marked_top, .count = n_marked } else null) else null;
        if (app.data) |*g| if (drawGrid("##data", g, .{ .col = app.sort_col, .desc = app.sort_desc }, &app.data_sel, null, .filter, &app.prefs, name, count_h, marking)) |s| {
            app.sort_col = s.col;
            app.sort_desc = s.desc;
            app.reloadFirstPage();
        };
        // "<tabela>: linhas 1 a 100 de 36804" (com busca ou filtro: "... encontradas") + ", N marcadas" e as paginas
        // ◀ ▶ (a pagina = a lista Linhas; as marcadas ficam fora dela, no topo de toda pagina); as colunas ocultas
        // ficam na barra de baixo. Uma linha: o que nao cabe termina em "..." (inteira no tooltip). Com marcadas, a
        // direita a caixa "So as marcadas" (= Exibir > So as linhas marcadas).
        const shown: u64 = if (app.data) |g| g.rows.len else 0;
        const top: u64 = if (app.only_marked) 0 else app.marked_top;
        const listed = app.total -| top;
        const on_page = shown -| top;
        const first_row = if (on_page == 0) 0 else app.page * app.limit + 1;
        const last_row = app.page * app.limit + on_page;
        var cb: [700]u8 = undefined;
        const rows_line = if (app.applied_search[0] != 0 or app.filters.items.len > 0)
            i18n.fmtCount(&cb, "rows_page_found", listed, .{ name, first_row, last_row, listed })
        else
            i18n.fmtCount(&cb, "rows_page", listed, .{ name, first_row, last_row, listed });
        var mb: [64]u8 = undefined;
        var clb: [780]u8 = undefined;
        const count_line = if (n_marked > 0) std.fmt.bufPrint(&clb,"{s}{s}", .{ rows_line, i18n.fmtCount(&mb, "marked_count", n_marked, .{n_marked}) }) catch rows_line else rows_line;
        const only_l = tr("only_marked");
        const box_w = if (n_marked > 0) ig.igGetFrameHeight() + st.*.ItemInnerSpacing.x + textWidth(only_l) + 2 * gap else 0;
        const prev_l = "\u{25C0}##page_prev";
        const next_l = "\u{25B6}##page_next";
        const pager_w = buttonWidth(prev_l) + buttonWidth(next_l) + 2 * gap;
        ig.igAlignTextToFramePadding();
        var fb: [800]u8 = undefined;
        const fitted = fitLine(&fb, count_line, ig.igGetContentRegionAvail().x - box_w - pager_w);
        textSlice(fitted);
        if (fitted.len != count_line.len and ig.igIsItemHovered(0)) tooltip(count_line);
        const last_page = if (listed == 0) 0 else (listed - 1) / app.limit;
        ig.igSameLine(0, -1);
        ig.igBeginDisabled(app.page == 0 or app.only_marked);
        if (button(prev_l)) {
            app.page -= 1;
            app.want_reload = true;
        }
        itemTooltip(tr("page_prev"));
        ig.igEndDisabled();
        ig.igSameLine(0, -1);
        ig.igBeginDisabled(app.page >= last_page or app.only_marked);
        if (button(next_l)) {
            app.page += 1;
            app.want_reload = true;
        }
        itemTooltip(tr("page_next"));
        ig.igEndDisabled();
        if (n_marked > 0) {
            ig.igSameLine(0, -1);
            ig.igSetCursorPosX(ig.igGetCursorPosX() + @max(0, ig.igGetContentRegionAvail().x - (box_w - 2 * gap)));
            var only = app.only_marked;
            if (ig.igCheckbox(only_l, &only)) {
                app.only_marked = only;
                app.reloadFirstPage();
            }
        }
        // pedidos da grade (caixas de marcar) e do menu da celula
        const sel = &app.data_sel;
        if (sel.want_mark) |r| app.want_mark = r;
        if (sel.want_unmark_all) app.want_unmark_all = true;
        if (sel.want_export) |k| app.want_export = k;
        sel.want_mark = null;
        sel.want_unmark_all = false;
        sel.want_export = null;
        if (sel.want_clear) app.want_clear_filters = true;
        if (sel.want_filter and app.want_filter == null) if (app.data) |g| if (sel.row) |r| if (r < g.rows.len and sel.col < g.columns.len) {
            // o valor e copiado agora: a pagina pode ser trocada antes de o filtro ser aplicado
            if (g.rows[r][sel.col]) |s| {
                if (app.gpa.dupe(u8, s)) |v| {
                    app.want_filter = .{ .col = sel.col, .value = v };
                } else |_| {}
            } else app.want_filter = .{ .col = sel.col, .value = null };
        };
        sel.want_filter = false;
        sel.want_clear = false;
    }

    fn drawSql(app: *App) void {
        // campo vazio com a dica "SELECT * FROM ..." (o do Python); InputTextMultiline nao aceita dica, InputTextEx sim
        const enter = ig.igInputTextEx("##sql", tr("sql_hint"), &app.sql, app.sql.len + 1, .{ .x = -1, .y = ig.igGetTextLineHeight() * 7 }, ig.ImGuiInputTextFlags_Multiline | ig.ImGuiInputTextFlags_EnterReturnsTrue, null, null);
        const running = app.slot.busyWith(.sql);
        ig.igBeginDisabled(running);
        if (button(tr("run")) or enter) app.want_run = true;
        ig.igEndDisabled();
        ig.igSameLine(0, -1);
        if (running) ig.igTextDisabled("%s", tr("busy_running").ptr) else app.sql_msg.draw();
        const g = if (app.result) |*x| x else return;
        // o filtro ocupa a linha ate o botao Colunas (com 400 px fixos sobrava linha vazia)
        ig.igSetNextItemWidth(ig.igGetContentRegionAvail().x - buttonWidth(tr("columns_button")) - ig.igGetStyle().*.ItemSpacing.x);
        if (ig.igInputTextWithHint("##rfilter", tr("search_rows"), &app.result_filter, app.result_filter.len + 1, 0, null, null)) app.refilter();
        itemTooltip(tr("search_rule"));
        ig.igSameLine(0, -1);
        columnsButton(&app.result_sel);
        // as colunas ocultas ficam na barra de baixo
        if (app.result_rows) |rows| {
            ig.igSameLine(0, -1);
            var mb: [96]u8 = undefined;
            textSlice(i18n.fmtCount(&mb, "rows_match", g.rows.len, .{ rows.len, g.rows.len }));
        }
        _ = drawGrid("##result", g, null, &app.result_sel, app.result_rows, .hide, &app.prefs, tr("sql_result"), 0, null);
    }

    // Escopo da busca ao lado da caixa: "Esta tabela" | "Todas as tabelas", dois segmentos colados; o escolhido com
    // a cor de botao do tema, o outro com a cor das caixas de texto
    fn scopeSelector(app: *App) void {
        const labels = [_][:0]const u8{ tr("scope_table"), tr("scope_all") };
        if (segmented(0, &labels, @intFromBool(app.scope == .all), null)) |i| app.setScope(if (i == 0) .table else .all);
    }

    // Busca em todas as tabelas: "<n> tabelas com linhas que contem ..." e a lista "tabela (linhas)" (Python e Rust);
    // clicar abre a tabela com a mesma busca
    fn drawGlobal(app: *App) void {
        const g = if (app.global) |*x| x else return;
        ig.igAlignTextToFramePadding();
        var hb: [400]u8 = undefined;
        textSlice(i18n.fmtCount(&hb, "global_found", g.hits.len, .{ g.hits.len, zstr(&g.term) }));
        if (g.hits.len == 0) return;
        defer ig.igEndChild();
        if (!ig.igBeginChild_Str("##global", .{ .x = 0, .y = 0 }, ig.ImGuiChildFlags_Borders, 0)) return;
        for (g.hits, 0..) |h, i| {
            if (h.table >= app.db.table_names.len) continue;
            ig.igPushID_Int(@intCast(i));
            // "##" + PushID: o rotulo fica vazio e o texto (que nao termina em 0 e pode ter "#") vai por textSlice
            if (ig.igSelectable_Bool("##g", false, 0, .{ .x = 0, .y = 0 })) app.pickGlobal(h.table, &g.term);
            ig.igPopID();
            ig.igSameLine(0, 0);
            var ib: [600]u8 = undefined;
            textSlice(std.fmt.bufPrint(&ib, "{s} ({d})", .{ app.db.table_names[h.table], h.rows }) catch app.db.table_names[h.table]);
        }
    }
};

// Segmentos colados ("Esta tabela | Todas as tabelas", "Valor inteiro | Contem"): o escolhido com a cor de botao do
// tema, os outros com a cor das caixas de texto. Devolve o segmento clicado; `hovered`: o mouse esta sobre ele.
fn segmented(id: c_int, labels: []const [:0]const u8, current: usize, hovered: ?*bool) ?usize {
    const st = ig.igGetStyle();
    const dl = ig.igGetWindowDrawList();
    var clicked: ?usize = null;
    ig.igPushID_Int(id);
    defer ig.igPopID();
    for (labels, 0..) |label, i| {
        if (i > 0) ig.igSameLine(0, 0);
        ig.igPushID_Int(@intCast(i));
        if (ig.igInvisibleButton("##seg", .{ .x = textWidth(label) + 2 * st.*.FramePadding.x, .y = ig.igGetFrameHeight() }, 0)) clicked = i;
        ig.igPopID();
        const over = ig.igIsItemHovered(0);
        if (hovered) |h| h.* = h.* or over;
        const col: c_int = if (current == i) ig.ImGuiCol_Button else if (over) ig.ImGuiCol_FrameBgHovered else ig.ImGuiCol_FrameBg;
        const corners: c_int = if (i == 0) ig.ImDrawFlags_RoundLeft else if (i + 1 == labels.len) ig.ImDrawFlags_RoundRight else ig.ImDrawFlags_RoundNone;
        const min = ig.igGetItemRectMin();
        const max = ig.igGetItemRectMax();
        ig.ImDrawList_AddRectFilled(dl, min, max, ig.igGetColorU32_Col(col, 1), st.*.FrameRounding, corners);
        ig.ImDrawList_AddRect(dl, min, max, ig.igGetColorU32_Col(ig.ImGuiCol_Border, 1), st.*.FrameRounding, st.*.FrameBorderSize, corners);
        ig.ImDrawList_AddText_Vec2(dl, .{ .x = min.x + st.*.FramePadding.x, .y = min.y + st.*.FramePadding.y }, ig.igGetColorU32_Col(ig.ImGuiCol_Text, 1), label.ptr, label.ptr + label.len);
    }
    return clicked;
}

fn segmentedWidth(labels: []const [:0]const u8) f32 {
    var w: f32 = 0;
    for (labels) |l| w += buttonWidth(l);
    return w;
}

// Submenu "CSV... / Excel (.xlsx)..." da lista Exportar: true = CSV, false = Excel, null = nada escolhido
fn formatMenu(label: [:0]const u8, enabled: bool) ?bool {
    if (!ig.igBeginMenu(label, enabled)) return null;
    defer ig.igEndMenu();
    if (ig.igMenuItem_Bool(tr("fmt_csv"), null, false, true)) return true;
    if (ig.igMenuItem_Bool(tr("fmt_xlsx"), null, false, true)) return false;
    return null;
}

// Relatorio da pesquisa de termos > Excel / CSV / SQLite / DuckDB (menu Exportar e menu da grade de Termos)
fn termsReportMenu(enabled: bool) ?ExportKind {
    var pick: ?ExportKind = null;
    if (ig.igBeginMenu(tr("export_terms"), enabled)) {
        defer ig.igEndMenu();
        if (ig.igMenuItem_Bool(tr("fmt_xlsx"), null, false, true)) pick = .terms_xlsx;
        if (ig.igMenuItem_Bool(tr("fmt_csv"), null, false, true)) pick = .terms_csv;
        if (ig.igMenuItem_Bool(tr("fmt_sqlite"), null, false, true)) pick = .terms_sqlite;
        if (ig.igMenuItem_Bool(tr("fmt_duckdb"), null, false, true)) pick = .terms_duckdb;
    }
    return pick;
}

// Titulos da coluna do termo e do relatorio, no idioma da tela (textos estaticos do catalogo)
fn termsTitles() dbm.terms.Titles {
    return .{
        .term = tr("col_term"),
        .status = tr("col_status"),
        .table = tr("col_table"),
        .rows = tr("col_rows"),
        .found = tr("term_found"),
        .not_found = tr("term_not_found"),
        .sheet_result = tr("sheet_result"),
    };
}

// Botao "Colunas..." da barra da grade: o dialogo e desenhado por drawGrid
fn columnsButton(sel: *GridSel) void {
    if (button(tr("columns_button"))) sel.open_columns = true;
    itemTooltip(tr("columns_tip"));
}

// Resultado do SQL: "3 linhas, 1 coluna" (cada contagem com o seu plural)
fn sqlRowsCols(buf: []u8, rows: usize, cols: usize) []const u8 {
    var rb: [48]u8 = undefined;
    var cb: [48]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}, {s}", .{ i18n.fmtCount(&rb, "sql_rows", rows, .{rows}), i18n.fmtCount(&cb, "sql_cols", cols, .{cols}) }) catch "";
}

var schema_titles: [3][:0]const u8 = .{ "", "", "" }; // titulos da grade do Esquema no idioma da tela

// Coluna "Aceita nulo" do Esquema no idioma da tela (Sim/Nao, Si/No, Yes/No): o YES/NO do DuckDB troca pelo texto
// do catalogo (estatico); refeito ao trocar o idioma
fn localizeSchema(g: *dbm.Grid) void {
    // titulos tambem (Editar > Copiar linha com cabecalho)
    schema_titles = .{ tr("schema_column"), tr("schema_type"), tr("schema_null") };
    if (g.columns.len == schema_titles.len) g.columns = &schema_titles;
    for (g.rows) |row| if (row.len > 2) if (row[2]) |v| {
        row[2] = i18n.yesNo(v);
    };
}

// "1 coluna oculta", "3 colunas ocultas" ou vazio
fn hiddenText(buf: []u8, sel: *const GridSel, n_cols: usize) []const u8 {
    const n = sel.hiddenCount(n_cols);
    if (n == 0) return "";
    return i18n.fmtCount(buf, "hidden_cols", n, .{n});
}

const Sort = struct { col: ?usize, desc: bool };

// Celula selecionada de uma grade (indices da linha em Grid.rows e da coluna)
const GridSel = struct {
    row: ?usize = null,
    col: usize = 0,
    popup: bool = false, // abrir o menu da celula ao lado dela (estado inicial --cell)
    popup_header: bool = false, // abrir o menu do cabecalho da coluna header_col (--capture)
    // Colunas ocultas desta grade (indice da coluna). Valem ate trocar de tabela/resultado ou "Mostrar todas";
    // so mudam o que e desenhado: busca e exportacao continuam com todas as colunas.
    hidden: std.StaticBitSet(max_grid_cols) = .empty,
    header_col: usize = 0, // coluna do menu do cabecalho
    open_columns: bool = false, // abrir o dialogo "Colunas"
    close_columns: bool = false, // fechar o dialogo (so o --capture usa)
    col_filter: [64:0]u8 = @splat(0), // busca por nome dentro do dialogo
    has_filters: bool = false, // habilita "Limpar filtros" no menu da celula
    want_filter: bool = false, // menu da celula: filtrar pelo valor da celula selecionada
    want_clear: bool = false, // menu da celula: limpar filtros
    want_mark: ?usize = null, // caixa da linha ou menu da celula: marcar ou desmarcar a linha
    want_unmark_all: bool = false, // menu da celula: desmarcar todas
    want_export: ?ExportKind = null, // menu da celula: exportar as linhas marcadas (Dados) ou o relatorio (Termos)
    want_copy_hits: bool = false, // menu da grade de Termos: copiar as linhas achadas da tabela

    // Clique (esquerdo ou direito) na celula: so a selecao muda (refazer o GridSel inteiro mostrava as ocultas de novo)
    fn pick(sel: *GridSel, row: usize, col: usize) void {
        sel.row = row;
        sel.col = col;
    }

    fn hiddenCount(sel: *const GridSel, n_cols: usize) usize {
        var n: usize = 0;
        for (0..@min(n_cols, max_grid_cols)) |c| n += @intFromBool(sel.hidden.isSet(c));
        return n;
    }
};

// shortcut: ImGui tables hold at most 512 columns, wider results are cut at 512
const max_grid_cols = 512;

// plain: so copia; hide: tambem ocultar colunas; filter: tambem "Filtrar por este valor" (aba Dados); terms: grade da
// aba Termos (copiar linha sem a coluna Termo, copiar as linhas achadas, relatorio)
const GridMode = enum { plain, hide, filter, terms };

// Coluna das caixas de marcar da aba Dados: as `top` primeiras linhas sao as marcadas; `count` marcadas na tabela
const Marking = struct { top: usize, count: usize };

// Poe na area de transferencia o valor da celula selecionada ou a linha dela separada por TAB (NULL = vazio);
// `header`: a linha de nomes das colunas vem antes; `skip`: colunas do comeco que a linha nao leva (Termo)
fn copySelection(g: *const dbm.Grid, sel: *const GridSel, whole_row: bool, header: bool, skip: usize) void {
    const r = sel.row orelse return;
    if (r >= g.rows.len or sel.col >= g.columns.len or skip >= g.columns.len) return;
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();
    const w = &out.writer;
    (if (whole_row) dbm.gridtools.writeRow(w, g.columns[skip..], g.rows[r][skip..], header) else w.writeAll(g.rows[r][sel.col] orelse "")) catch return;
    w.writeByte(0) catch return;
    ig.igSetClipboardText(out.written().ptr);
}

// Desenha um Grid; com `sort` os cabecalhos ordenam e a nova ordenacao pedida e devolvida.
// `rows` limita e ordena as linhas mostradas (filtro); null = todas.
// Clique seleciona a celula; Ctrl+C copia o valor; o clique direito abre o menu da celula (copiar, filtrar).
// Com `mode` != .plain o clique direito no cabecalho abre o menu do cabecalho: ajustar a largura, ocultar e mostrar
// colunas. NULL aparece como "NULL" ou como celula vazia (Configuracoes > Exibir NULL). `bottom`: altura livre embaixo
// da grade (a linha da contagem na aba Dados). `owner`: tabela ou resultado,
// no titulo do dialogo Colunas. `mark` (aba Dados): a 1a coluna e a das caixas de marcar a linha.
fn drawGrid(id: [*:0]const u8, g: *const dbm.Grid, sort: ?Sort, sel: *GridSel, rows: ?[]const usize, mode: GridMode, prefs: *settings.Settings, owner: []const u8, bottom: f32, mark: ?Marking) ?Sort {
    const off: usize = @intFromBool(mark != null); // colunas do ImGui = a das caixas + as do banco
    const n_cols: usize = @min(g.columns.len, max_grid_cols - off);
    if (n_cols == 0) return null;
    const can_hide = mode != .plain;
    var flags: c_int = ig.ImGuiTableFlags_Borders | ig.ImGuiTableFlags_RowBg | ig.ImGuiTableFlags_Resizable |
        ig.ImGuiTableFlags_ScrollX | ig.ImGuiTableFlags_ScrollY | ig.ImGuiTableFlags_SizingFixedFit;
    if (sort != null) flags |= ig.ImGuiTableFlags_Sortable | ig.ImGuiTableFlags_SortTristate;
    if (can_hide) flags |= ig.ImGuiTableFlags_Hideable;
    if (!ig.igBeginTable(id, @intCast(n_cols + off), flags, .{ .x = 0, .y = -bottom }, 0)) return null;
    defer ig.igEndTable();
    const table = ig.igGetCurrentTable(); // "Ajustar coluna" do menu do cabecalho

    // a coluna das caixas, estreita e sem titulo, fica parada na rolagem horizontal
    ig.igTableSetupScrollFreeze(@intCast(off), 1);
    if (mark != null) ig.igTableSetupColumn("##mark", ig.ImGuiTableColumnFlags_WidthFixed | ig.ImGuiTableColumnFlags_NoResize | ig.ImGuiTableColumnFlags_NoHide |
        ig.ImGuiTableColumnFlags_NoSort | ig.ImGuiTableColumnFlags_NoReorder, ig.igGetFontSize(), 0);
    for (g.columns[0..n_cols]) |name| ig.igTableSetupColumn(name.ptr, 0, 0, 0);
    var open_header = false;
    var header_at: ?[2]f32 = null; // --capture: onde o menu do cabecalho abre
    if (can_hide) {
        // a lista de ocultas e nossa (GridSel.hidden); o ImGui so executa
        for (0..n_cols) |c| ig.igTableSetColumnEnabled(@intCast(c + off), !sel.hidden.isSet(c));
        // cabecalho como o TableHeadersRow, mais o clique direito com o nosso menu
        ig.igTableNextRow(ig.ImGuiTableRowFlags_Headers, ig.igTableGetHeaderRowHeight());
        if (mark != null and ig.igTableSetColumnIndex(0)) {
            ig.igTableHeader("##mark");
            if (ig.igIsItemHovered(0)) tooltip(tr("mark_tip"));
        }
        for (g.columns[0..n_cols], 0..) |name, c| {
            if (!ig.igTableSetColumnIndex(@intCast(c + off))) continue;
            const avail = ig.igGetContentRegionAvail().x;
            ig.igPushID_Int(@intCast(c));
            var hovered = false;
            if (c < g.num_cols.len and g.num_cols[c]) {
                // coluna numerica: o nome a direita, deixando lugar para a seta de ordenacao
                // o cabecalho com o nome invisivel mantem o ajuste automatico da largura pelo nome
                hovered = rightHeader(name, if (sort != null and sort.?.col == c) ig.igGetFontSize() * 0.8 else 0); // seta so na ordenada
            } else {
                ig.igTableHeader(name.ptr);
                hovered = ig.igIsItemHovered(0);
            }
            ig.igPopID();
            // a largura inicial ja inclui o cabecalho (auto-fit do ImGui); estreitada a mao, o nome vai no tooltip
            if (hovered and textWidth(name) > avail) tooltip(name);
            if (ig.igIsMouseReleased_Nil(1) and hovered) {
                sel.header_col = c;
                open_header = true;
            }
            // --capture: o menu desta coluna abre logo abaixo do cabecalho (sem mouse)
            if (sel.popup_header and c == sel.header_col) {
                sel.popup_header = false;
                open_header = true;
                header_at = .{ ig.igGetItemRectMin().x, ig.igGetItemRectMax().y };
            }
        }
    } else ig.igTableHeadersRow();

    var changed: ?Sort = null;
    if (sort) |cur| if (ig.igTableGetSortSpecs()) |specs| if (specs.*.SpecsDirty) {
        specs.*.SpecsDirty = false;
        const new: Sort = if (specs.*.SpecsCount > 0 and specs.*.Specs[0].ColumnIndex >= off)
            .{ .col = @as(usize, @intCast(specs.*.Specs[0].ColumnIndex)) - off, .desc = specs.*.Specs[0].SortDirection == ig.ImGuiSortDirection_Descending }
        else
            .{ .col = null, .desc = false };
        if (new.col != cur.col or new.desc != cur.desc) changed = new;
    };

    const clipper = ig.ImGuiListClipper_ImGuiListClipper();
    defer ig.ImGuiListClipper_destroy(clipper);
    ig.ImGuiListClipper_Begin(clipper, @intCast(if (rows) |r| r.len else g.rows.len), -1);
    var open_menu = false;
    while (ig.ImGuiListClipper_Step(clipper)) {
        var start: c_int = 0;
        var end: c_int = 0;
        shim_clipper_range(clipper, &start, &end);
        for (@intCast(start)..@intCast(end)) |shown| {
            const r = if (rows) |list| list[shown] else shown;
            ig.igTableNextRow(0, 0);
            if (mark) |m| if (ig.igTableNextColumn()) {
                // caixa da altura do texto: a linha nao cresce
                var on = r < m.top;
                ig.igPushID_Int(@intCast(r));
                ig.igPushStyleVar_Vec2(ig.ImGuiStyleVar_FramePadding, .{ .x = 0, .y = 0 });
                if (ig.igCheckbox("##m", &on)) sel.want_mark = r;
                ig.igPopStyleVar(1);
                ig.igPopID();
            };
            for (g.rows[r][0..n_cols], 0..) |cell, c| {
                if (!ig.igTableNextColumn()) continue; // coluna oculta ou fora da tela
                ig.igPushID_Int(@intCast(r * n_cols + c));
                const selected = sel.row == r and sel.col == c;
                // rotulo vazio: a area clicavel e a celula toda e o texto vem logo depois
                if (ig.igSelectable_Bool("##cell", selected, 0, .{ .x = 0, .y = 0 })) sel.pick(r, c);
                if (ig.igIsItemHovered(0) and ig.igIsMouseClicked_Bool(1, false)) {
                    sel.pick(r, c);
                    open_menu = true;
                }
                if (selected and sel.popup) {
                    sel.popup = false;
                    open_menu = true;
                    const max = ig.igGetItemRectMax();
                    ig.igSetNextWindowPos(.{ .x = ig.igGetItemRectMin().x + 24, .y = max.y }, ig.ImGuiCond_Always, .{ .x = 0, .y = 0 });
                }
                ig.igPopID();
                // DOUBLE inteiro sem ".0" so na tela; a celula (copia, filtro) segue com o texto original
                const float = c < g.float_cols.len and g.float_cols[c];
                const disp: ?[]const u8 = if (cell) |s|
                    (if (float) dbm.gridtools.wholeFloatText(s) else s)
                else if (prefs.show_null) tr("null_text") else null;
                if (disp) |txt| {
                    ig.igSameLine(0, 0);
                    // numero alinhado a direita (o cabecalho tambem); texto a esquerda
                    if (c < g.num_cols.len and g.num_cols[c]) rightAlign(textWidth(txt), 0);
                    textSlice(txt);
                }
            }
        }
    }

    // aba Termos: copiar linha e linha com cabecalho sem a coluna Termo
    const skip: usize = @intFromBool(mode == .terms);
    if (ig.igIsWindowFocused(0) and ig.igIsKeyChordPressed_Nil(ig.ImGuiMod_Ctrl | ig.ImGuiKey_C)) copySelection(g, sel, false, false, 0);
    if (open_menu) _ = ig.igOpenPopup_Str("##copy", 0);
    // menu da celula do Go: filtros por valor (aba Dados), depois copiar valor, linha e linha com o cabecalho
    if (ig.igBeginPopup("##copy", 0)) {
        defer ig.igEndPopup();
        if (mode == .filter) {
            if (ig.igMenuItem_Bool(tr("filter_by_value"), null, false, true)) sel.want_filter = true;
            if (ig.igMenuItem_Bool(tr("clear_filters"), null, false, sel.has_filters)) sel.want_clear = true;
            ig.igSeparator();
        }
        if (ig.igMenuItem_Bool(tr("copy_value"), "Ctrl+C", false, true)) copySelection(g, sel, false, false, 0);
        if (ig.igMenuItem_Bool(tr("copy_row"), null, false, true)) copySelection(g, sel, true, false, skip);
        if (ig.igMenuItem_Bool(tr("copy_row_header"), null, false, true)) copySelection(g, sel, true, true, skip);
        // aba Termos: todas as linhas achadas da tabela (sem a coluna Termo) e o relatorio
        if (mode == .terms) {
            ig.igSeparator();
            if (ig.igMenuItem_Bool(tr("copy_hits"), null, false, true)) sel.want_copy_hits = true;
            if (termsReportMenu(true)) |k| sel.want_export = k;
        }
        // aba Dados: marcar a linha, exportar as marcadas, desmarcar todas (item 31)
        if (mark) |m| {
            ig.igSeparator();
            if (ig.igMenuItem_Bool(tr("menu_mark"), tr("key_space"), false, sel.row != null)) sel.want_mark = sel.row;
            if (ig.igBeginMenu(tr("ctx_export_marked"), m.count > 0)) {
                defer ig.igEndMenu();
                if (ig.igMenuItem_Bool(tr("fmt_csv"), null, false, true)) sel.want_export = .marked_csv;
                if (ig.igMenuItem_Bool(tr("fmt_xlsx"), null, false, true)) sel.want_export = .marked_xlsx;
            }
            if (ig.igMenuItem_Bool(tr("menu_unmark_all"), null, false, m.count > 0)) sel.want_unmark_all = true;
        }
    }
    if (!can_hide) return changed;

    // Cabecalho: este menu abre depois do menu padrao do ImGui (TableHeader) no mesmo quadro e toma o lugar dele.
    // Ordem do Rust: Ajustar coluna, Ajustar todas, Ocultar esta coluna, Colunas..., Mostrar todas (sem coluna oculta,
    // desabilitado) e a lista das colunas; a ultima coluna visivel nao pode ser ocultada.
    if (open_header) _ = ig.igOpenPopup_Str("##header", 0);
    if (header_at) |p| ig.igSetNextWindowPos(.{ .x = p[0], .y = p[1] }, ig.ImGuiCond_Always, .{ .x = 0, .y = 0 });
    if (ig.igBeginPopup("##header", 0)) {
        defer ig.igEndPopup();
        const visible = n_cols - sel.hiddenCount(n_cols);
        if (ig.igMenuItem_Bool(tr("fit_column"), null, false, true)) ig.igTableSetColumnWidthAutoSingle(table, @intCast(sel.header_col + off));
        if (ig.igMenuItem_Bool(tr("fit_all_columns"), null, false, true)) ig.igTableSetColumnWidthAutoAll(table);
        ig.igSeparator();
        if (ig.igMenuItem_Bool(tr("hide_column"), null, false, visible > 1)) sel.hidden.set(sel.header_col);
        if (ig.igMenuItem_Bool(tr("columns_button"), null, false, true)) sel.open_columns = true;
        if (ig.igMenuItem_Bool(tr("show_all_columns"), null, false, visible < n_cols)) sel.hidden = .empty;
        ig.igSeparator();
        // uma linha por coluna, marcada se visivel: clicar alterna e o menu continua aberto (varias de uma vez)
        ig.igPushItemFlag(ig.ImGuiItemFlags_AutoClosePopups, false);
        defer ig.igPopItemFlag();
        for (g.columns[0..n_cols], 0..) |name, c| {
            const on = !sel.hidden.isSet(c);
            ig.igPushID_Int(@intCast(c));
            if (ig.igMenuItem_Bool(name.ptr, null, on, !on or visible > 1)) sel.hidden.setValue(c, on);
            ig.igPopID();
        }
    }

    // "Colunas de <tabela>": dialogo no centro da janela, uma caixa por coluna; marcar e desmarcar varias e fechar
    var nb: [400]u8 = undefined;
    var tb: [420]u8 = undefined;
    const dialog_title = std.fmt.bufPrintSentinel(&tb, "{s}###columns", .{i18n.fmt(&nb, "columns_title", .{owner})}, 0) catch "###columns";
    if (sel.open_columns) {
        sel.open_columns = false;
        sel.col_filter[0] = 0;
        _ = ig.igOpenPopup_Str(dialog_title, 0);
    }
    if (!ig.igIsPopupOpen_Str(dialog_title, 0)) {
        sel.close_columns = false;
        return changed;
    }
    // Tamanho proporcional a janela (REGRA_VISUAL): largura ~65% (420..900 px), altura ate 70%; redimensionavel,
    // a grade de caixas se refaz pela largura disponivel; a fonte e sempre a base do app
    const st = ig.igGetStyle();
    const vp = ig.igGetMainViewport();
    const row_h = ig.igGetFrameHeight() + 2 * st.*.CellPadding.y;
    const footer_h = ig.igGetFrameHeightWithSpacing() + st.*.ItemSpacing.y + 2; // separador + contagem e botoes
    // celula: nome mais longo + caixa + folga, nunca menos de 11 em (assim da ~4 colunas no tamanho padrao)
    var longest: f32 = 0;
    for (g.columns[0..n_cols]) |name| longest = @max(longest, textWidth(name));
    const cell_w = @max(longest + ig.igGetFrameHeight() + st.*.ItemInnerSpacing.x + 2 * st.*.CellPadding.x + 12, 11 * ig.igGetFontSize());
    const dlg_w = dbm.gridtools.columnsDialogWidth(vp.*.Size.x);
    const per_row0 = dbm.gridtools.checkboxGridColumns(dlg_w - 4 * st.*.WindowPadding.x - st.*.ScrollbarSize, cell_w);
    const n_rows: f32 = @floatFromInt((n_cols + per_row0 - 1) / per_row0);
    const overhead = ig.igGetFrameHeight() + 2 * st.*.WindowPadding.y + ig.igGetFrameHeightWithSpacing() + 2 * st.*.WindowPadding.y + footer_h;
    const dlg_h = @min(overhead + n_rows * row_h, vp.*.Size.y * 0.7);
    centerNext(); // sempre no centro e dentro da janela
    ig.igSetNextWindowSize(.{ .x = dlg_w, .y = dlg_h }, ig.ImGuiCond_Appearing);
    ig.igSetNextWindowSizeConstraints(.{ .x = @min(420, vp.*.Size.x - 16), .y = overhead + 3 * row_h }, .{ .x = vp.*.Size.x - 16, .y = vp.*.Size.y - 16 }, null, null);
    var dialog_open = true;
    if (ig.igBeginPopupModal(dialog_title, &dialog_open, ig.ImGuiWindowFlags_NoSavedSettings)) {
        defer ig.igEndPopup();
        if (sel.close_columns) {
            sel.close_columns = false;
            ig.igCloseCurrentPopup();
        }
        ig.igSetNextItemWidth(-1);
        _ = ig.igInputTextWithHint("##colfilter", tr("find_column"), &sel.col_filter, sel.col_filter.len + 1, 0, null, null);
        const needle = zstr(&sel.col_filter);
        // so rolagem vertical: a grade usa a largura da lista, sem barra horizontal
        if (ig.igBeginChild_Str("##list", .{ .x = 0, .y = -footer_h }, ig.ImGuiChildFlags_Borders, 0)) {
            const per_row = dbm.gridtools.checkboxGridColumns(ig.igGetContentRegionAvail().x, cell_w);
            if (ig.igBeginTable("##grid", @intCast(per_row), ig.ImGuiTableFlags_SizingStretchSame, .{ .x = 0, .y = 0 }, 0)) {
                defer ig.igEndTable();
                const last = n_cols - sel.hiddenCount(n_cols) == 1; // a ultima visivel nao pode ser desmarcada
                for (g.columns[0..n_cols], 0..) |name, c| {
                    if (!dbm.gridtools.columnListed(name, needle)) continue;
                    _ = ig.igTableNextColumn();
                    var shown = !sel.hidden.isSet(c);
                    ig.igPushID_Int(@intCast(c));
                    ig.igBeginDisabled(shown and last);
                    if (ig.igCheckbox(name.ptr, &shown)) sel.hidden.setValue(c, !shown);
                    ig.igEndDisabled();
                    ig.igPopID();
                }
            }
        }
        ig.igEndChild();
        ig.igSeparator();
        // contagem a esquerda; Mostrar todas, Ocultar todas e Fechar a direita, do mesmo tamanho
        const show_l = tr("show_all");
        const hide_l = tr("hide_all");
        const close_l = tr("close");
        const bw = dialogButtonWidth(&.{ "show_all", "hide_all", "close" });
        const full = ig.igGetContentRegionAvail().x;
        ig.igAlignTextToFramePadding();
        textT("columns_shown", .{ n_cols - sel.hiddenCount(n_cols), n_cols });
        ig.igSameLine(st.*.WindowPadding.x + full - 3 * bw - 2 * st.*.ItemSpacing.x, -1);
        // com o campo de busca preenchido, Mostrar/Ocultar todas agem so nas colunas listadas
        if (ig.igButton(show_l, .{ .x = bw, .y = 0 })) dbm.gridtools.setListed(&sel.hidden, g.columns[0..n_cols], needle, false);
        ig.igSameLine(0, -1);
        if (ig.igButton(hide_l, .{ .x = bw, .y = 0 })) dbm.gridtools.setListed(&sel.hidden, g.columns[0..n_cols], needle, true);
        ig.igSameLine(0, -1);
        if (ig.igButton(close_l, .{ .x = bw, .y = 0 }) or dialogKeyClose()) ig.igCloseCurrentPopup();
    }
    return changed;
}

// Menu padrao do cabecalho do Dear ImGui (grade do Esquema): os textos do nosso menu, no idioma da tela
fn localizeImGui() void {
    switch (i18n.lang) {
        inline else => |l| {
            const C = i18n.catalogs[@backingInt(l)];
            const entries = struct {
                const list = [_]ig.ImGuiLocEntry{
                    .{ .Key = ig.ImGuiLocKey_TableSizeOne, .Text = C.fit_column ++ "###SizeOne" },
                    .{ .Key = ig.ImGuiLocKey_TableSizeAllFit, .Text = C.fit_all_columns ++ "###SizeAll" },
                    .{ .Key = ig.ImGuiLocKey_TableSizeAllDefault, .Text = C.fit_all_columns ++ "###SizeAll" },
                };
            };
            ig.igLocalizeRegisterEntries(&entries.list, entries.list.len);
        },
    }
}

var dropped: [1024:0]u8 = @splat(0); // caminho solto na janela (callback do GLFW)

fn onDrop(_: *glfw.Window, count: i32, paths: [*][*:0]const u8) callconv(.c) void {
    if (count < 1) return;
    copyZ(&dropped, std.mem.span(paths[0]));
}

fn showUsage() void {
    std.debug.print("{s}", .{tr("usage")});
    if (!build_options.console) messageBox(tr("usage"), .info);
}

pub fn main(init: std.process.Init) void {
    main_io = init.io;
    run(init) catch |e| {
        // sem console no release: o motivo aparece numa caixa, nao some calado
        var buf: [512]u8 = undefined;
        const hint = if (e == error.APIUnavailable or e == error.VersionUnavailable or e == error.PlatformError) tr("err_opengl") else "";
        messageBox(i18n.fmt(&buf, "err_start", .{ e, hint }), .err);
        std.process.exit(1);
    };
    if (capture_failed) std.process.exit(2);
}

// Pasta das preferencias: %APPDATA%\mdb2sql (Windows) ou $XDG_CONFIG_HOME/mdb2sql, ~/.config/mdb2sql (Linux)
fn prefsPath(a: std.mem.Allocator, env: anytype) !?[]const u8 {
    if (platform.is_windows) {
        const appdata = env.get("APPDATA") orelse return null;
        return try std.fs.path.join(a, &.{ appdata, "mdb2sql", "zig-imgui.ini" });
    }
    if (env.get("XDG_CONFIG_HOME")) |x| if (x.len > 0) return try std.fs.path.join(a, &.{ x, "mdb2sql", "zig-imgui.ini" });
    const home = env.get("HOME") orelse return null;
    return try std.fs.path.join(a, &.{ home, ".config", "mdb2sql", "zig-imgui.ini" });
}

// Abre o GLFW no sistema de janelas decidido por display.decide. Devolve o texto do aviso quando ficou no Wayland
// por reserva; sem X11 e sem Wayland, mensagem no stderr e saida 3.
fn initLinuxDisplay(a: std.mem.Allocator, io: std.Io, env: anytype) !?dbm.display.Warning {
    const display = dbm.display;
    var missing: std.ArrayList([]const u8) = .empty;
    const x_display = env.get("DISPLAY");
    const has_display = if (x_display) |d| d.len > 0 else false;
    if (has_display) for (display.x11_libs) |lib| if (!platform.libLoads(lib)) try missing.append(a, lib);
    const d = display.decide(.{ .user = env.get("MDB2SQL_DISPLAY"), .display = x_display, .wayland_display = env.get("WAYLAND_DISPLAY") }, missing.items);
    var warn = d.warn;
    openBackend(d.backend) catch |e| {
        const fb = d.fallback orelse return noWindow(e);
        openBackend(fb) catch |e2| return noWindow(e2);
        // DISPLAY definido mas o X11 nao abriu (servidor fora do ar): Wayland por reserva, com aviso
        warn = true;
        try missing.append(a, try std.fmt.allocPrint(a, "X11 (DISPLAY={s}: {t})", .{ x_display.?, e }));
    };
    if (!warn) return null;
    var os_buf: [4096]u8 = undefined;
    const os_release = std.Io.Dir.cwd().readFile(io, "/etc/os-release", &os_buf) catch
        std.Io.Dir.cwd().readFile(io, "/usr/lib/os-release", &os_buf) catch "";
    return display.warning(os_release, !has_display, missing.items);
}

fn openBackend(b: dbm.display.Backend) !void {
    try glfw.initHint(.platform, if (b == .x11) glfw.Platform.x11 else glfw.Platform.wayland);
    try glfw.init();
}

fn noWindow(e: anyerror) noreturn {
    var buf: [600]u8 = undefined;
    std.debug.print("{s}", .{i18n.fmt(&buf, "display_none", .{ e, dbm.display.help_url })});
    std.process.exit(3);
}

fn run(init: std.process.Init) !void {
    var app: App = .{ .gpa = init.gpa, .io = init.io, .db = .init(init.gpa), .slot = undefined };
    const arena = init.arena.allocator();
    log_gpa = init.gpa;
    defer session_log.deinit(init.gpa);

    // Arquivos que vem junto do programa (pasta do exe): extensao sqlite e mdbtools/
    const exe_dir = std.process.executableDirPathAlloc(init.io, arena) catch "";
    const sqlite_ext = try std.fs.path.join(arena, &.{ exe_dir, "sqlite_scanner.duckdb_extension" });
    if (std.Io.Dir.cwd().access(init.io, sqlite_ext, .{})) |_| app.db.sqlite_ext = sqlite_ext else |_| {}
    // temporarios (SQLite convertido do Access, CSVs do mdbtools), na subpasta mdb2sql-zig: a pasta temporaria do
    // usuario, senao a do sistema; por ultimo (access.pickTempDir) a pasta do arquivo de origem. Os de um programa
    // que caiu sao apagados aqui (os da pasta do original, ao abrir o arquivo)
    const env = init.environ_map;
    const user_tmp = env.get("TEMP") orelse env.get("TMP") orelse env.get("TMPDIR") orelse "";
    const sys_tmp = if (platform.is_windows) try std.fs.path.join(arena, &.{ env.get("SystemRoot") orelse "C:\\Windows", "Temp" }) else "/tmp";
    var temp_dirs: std.ArrayList([]const u8) = .empty;
    var stale: usize = 0;
    for ([_][]const u8{ user_tmp, sys_tmp }) |dir| {
        if (dir.len == 0 or std.mem.eql(u8, dir, user_tmp) and temp_dirs.items.len > 0) continue;
        try temp_dirs.append(arena, try std.fs.path.join(arena, &.{ dir, access.temp_subdir }));
        stale += access.cleanupStale(init.io, temp_dirs.getLast());
    }
    app.slot = .{ .db = &app.db, .gpa = init.gpa, .env = .{ .io = init.io, .access = .{
        .forced = init.environ_map.get("MDB2SQL_ACCESS_READER") orelse "",
        .tools_dir = try std.fs.path.join(arena, &.{ exe_dir, "mdbtools" }),
        .temp_dirs = temp_dirs.items,
    } } };
    defer app.deinit();
    app.gtk_theme = init.environ_map.get("GTK_THEME") orelse "";
    // a instancia DuckDB do programa nasce aqui, na thread da UI (ver db.zig)
    try app.db.start();

    // Argumentos: caminho do banco e estado inicial opcional
    const args = try init.minimal.args.toSlice(arena);
    // --capture: auxiliar de teste (README-BUILD.txt); nao le nem grava as configuracoes salvas
    const capture_opts = dbm.capture.parse(args) catch return showUsage();
    if (capture_opts == null) if (try prefsPath(arena, init.environ_map)) |p| {
        app.prefs_path = p;
        app.prefs = settings.Settings.load(init.io, app.prefs_path);
    };
    i18n.lang = app.prefs.lang;
    app.scope = app.prefs.search_scope;
    // aba Pesquisa Avançada: a comparacao padrao das configuracoes; o escopo comeca em Todas as tabelas; a caixa vazia
    app.terms_match = app.prefs.term_match;
    app.terms_text = try init.gpa.alloc(u8, terms_box_size + 1);
    @memset(app.terms_text, 0);
    var theme = app.prefs.theme;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!std.mem.startsWith(u8, arg, "-")) {
            app.setPath(arg);
        } else if (std.mem.eql(u8, arg, "--about")) {
            app.want_about = true;
        } else {
            i += 1;
            if (i >= args.len) return showUsage();
            const value = args[i];
            if (std.mem.eql(u8, arg, "--table")) {
                app.start_table = value;
            } else if (std.mem.eql(u8, arg, "--sql")) {
                copyZ(&app.sql, value);
            } else if (std.mem.eql(u8, arg, "--search")) {
                app.start_search = value;
            } else if (std.mem.eql(u8, arg, "--cell")) {
                // ROW,COL a partir de 1, como aparecem na grade
                const comma = std.mem.indexOfScalar(u8, value, ',') orelse return showUsage();
                const row = std.fmt.parseInt(usize, value[0..comma], 10) catch return showUsage();
                const col = std.fmt.parseInt(usize, value[comma + 1 ..], 10) catch return showUsage();
                if (row == 0 or col == 0) return showUsage();
                app.start_cell = .{ row - 1, col - 1 };
            } else if (std.mem.eql(u8, arg, "--theme")) {
                theme = std.meta.stringToEnum(settings.Theme, value) orelse return showUsage();
            } else if (std.mem.eql(u8, arg, "--lang")) {
                i18n.lang = std.meta.stringToEnum(i18n.Lang, value) orelse return showUsage();
            } else if (std.mem.eql(u8, arg, "--export")) {
                app.start_export = std.meta.stringToEnum(ExportKind, value) orelse return showUsage();
            } else if (std.mem.eql(u8, arg, "--db")) {
                app.setPath(value);
            } else if (std.mem.eql(u8, arg, "--capture")) {
                // lido por dbm.capture.parse
            } else if (std.mem.eql(u8, arg, "--menu")) {
                app.start_menu = std.meta.stringToEnum(@typeInfo(@FieldType(App, "start_menu")).optional.child, value) orelse return showUsage();
            } else return showUsage();
        }
    }
    if (app.path[0] == 0) if (init.environ_map.get("MDB2SQL_DB_PATH")) |p| app.setPath(p);
    app.want_open = app.path[0] != 0;
    app.start_sql = app.want_open and app.sql[0] != 0;
    if (capture_opts != null and app.start_table.len == 0) app.start_table = dbm.capture.first_table;
    app.capture_mode = capture_opts != null;
    logStale(stale); // ja no idioma da tela

    // Linux: X11 (XWayland, se houver) antes do Wayland nativo (REGRA_X11, src/display.zig). No Wayland o GLFW decora a
    // janela pelo libdecor, que carrega o GTK; no WSLg recem-reiniciado o programa caiu 2 vezes dentro dele.
    if (platform.is_windows) try glfw.init() else if (try initLinuxDisplay(arena, init.io, init.environ_map)) |w| {
        app.display_warning = w;
        logEvent(.warn, w.text()); // no log as 3 linhas viram uma
    }
    defer glfw.terminate();
    glfw.windowHint(.context_version_major, 3);
    glfw.windowHint(.context_version_minor, 3);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    if (capture_opts != null) glfw.windowHint(.visible, false); // nada aparece na tela do usuario
    const window = try glfw.Window.create(1280, 800, app_title, null, null);
    defer window.destroy();
    glfw.makeContextCurrent(window);
    glfw.swapInterval(if (capture_opts != null) 0 else 1);
    _ = glfw.setDropCallback(window, onDrop);
    if (platform.is_windows) app.hwnd = @ptrCast(glfw.getWin32Window(window));
    app.window = window;
    gl = try Gl.load();

    _ = ig.igCreateContext(null);
    defer ig.igDestroyContext(null);
    shim_io_setup();
    localizeImGui();
    const scale = window.getContentScale()[0];
    setupSizes(scale);
    applyTheme(settings.isLight(theme, app.gtk_theme), app.hwnd);
    // Segoe UI (Windows) ou DejaVu/Noto Sans (Linux) quando existe (acentos legiveis); senao fica a fonte embutida
    // do ImGui. O ImGui mede a altura da linha (no Segoe UI, 1.33x a letra): 18.6 = letra de 14 px, a do Go/Wails
    // (com 16 ficava em 12 px, pequena); titulos seguem proporcionais (FontSizeBase)
    // Os glifos (acentos, setas U+2190-21FF) entram no atlas sob demanda (fontes dinamicas do Dear ImGui 1.92+)
    const ui_font = for (platform.fonts) |font| {
        if (std.Io.Dir.cwd().access(init.io, font, .{})) |_| {
            _ = shim_add_font(font, 18.6 * scale);
            // a estrela das favoritas (U+2605) e as setas das paginas (U+25B6, U+25C0) de outra fonte, juntada a esta
            for (platform.star_fonts) |star| if (std.Io.Dir.cwd().access(init.io, star, .{})) |_| {
                _ = shim_merge_glyphs(star, 18.6 * scale, &symbol_glyphs);
                break;
            } else |_| {};
            break true;
        } else |_| {}
    } else blk: {
        ig.igGetStyle().*.FontScaleDpi = scale;
        break :blk false;
    };
    // monoespacada para o painel de Log (Consolas, DejaVu Sans Mono), so depois da fonte da interface (a 1a e a padrao)
    if (ui_font) for (platform.mono_fonts) |font| {
        if (std.Io.Dir.cwd().access(init.io, font, .{})) |_| {
            mono_font = shim_add_font(font, 14 * scale);
            break;
        } else |_| {}
    };

    // no --capture o GLFW nao entrega mouse nem teclado reais ao ImGui
    if (!ImGui_ImplGlfw_InitForOpenGL(window, capture_opts == null)) return error.PlatformError;
    defer ImGui_ImplGlfw_Shutdown();
    if (!ImGui_ImplOpenGL3_Init("#version 330")) return error.APIUnavailable;
    defer ImGui_ImplOpenGL3_Shutdown();
    var capture: ?Capture = null;
    if (capture_opts) |o| {
        shim_capture_setup();
        try std.Io.Dir.cwd().createDirPath(init.io, o.out_dir);
        const save_type = if (init.environ_map.get("MDB2SQL_CAPTURE_SAVE")) |v| std.meta.stringToEnum(dialog.SaveType, v) else null;
        capture = .{ .out_dir = o.out_dir, .fbo = try Fbo.load(), .save_type = save_type };
        capture.?.terms_file = init.environ_map.get("MDB2SQL_CAPTURE_TERMS") orelse "";
        capture.?.dialog = if (init.environ_map.get("MDB2SQL_CAPTURE_DIALOG")) |v| std.mem.eql(u8, v, "1") else false;
        capture.?.only = init.environ_map.get("MDB2SQL_CAPTURE_ONLY") orelse "";
    }
    defer if (capture) |*c| {
        if (c.failed != null or c.wrong.items.len > 0) capture_failed = true;
        c.report(init.gpa, init.io);
    };

    while (!app.quit) {
        glfw.pollEvents();
        // X da janela e Alt+F4: a mesma saida de Arquivo > Sair (Voltar mantem o programa aberto)
        if (window.shouldClose()) {
            window.setShouldClose(false);
            app.requestExit();
        }
        if (dropped[0] != 0) {
            app.setPath(zstr(&dropped));
            dropped[0] = 0;
            app.want_open = true;
        }
        if (capture) |*c| c.before(&app);
        app.update();

        ImGui_ImplOpenGL3_NewFrame();
        ImGui_ImplGlfw_NewFrame();
        if (capture) |*c| {
            const sz = c.size();
            shim_capture_frame(@floatFromInt(sz[0]), @floatFromInt(sz[1]));
        }
        ig.igNewFrame();
        app.draw();
        ig.igRender();

        var fb = window.getFramebufferSize();
        if (capture) |*c| {
            const sz = c.size();
            try c.fbo.use(sz[0], sz[1]);
            fb = .{ @intCast(sz[0]), @intCast(sz[1]) };
        }
        gl.viewport(0, 0, fb[0], fb[1]);
        gl.clearColor(0.1, 0.1, 0.1, 1);
        gl.clear(0x4000); // GL_COLOR_BUFFER_BIT
        ImGui_ImplOpenGL3_RenderDrawData(ig.igGetDrawData());
        if (capture) |*c| {
            if (c.after(&app, init.io)) break;
            continue; // janela invisivel: nada para mostrar
        }
        window.swapBuffers();
    }
}

var capture_failed = false; // --capture terminou com erro (detalhe em <pasta>/capture_error.txt)
