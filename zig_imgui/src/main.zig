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
    save_end: bool = false, // MDB2SQL_CAPTURE_SAVE=1: o passo final responde Salvar em vez de Apagar
    saved_path: ?[]const u8 = null, // Salvar: o arquivo que tem de existir (do gpa)
    esc_frames: u32 = 0, // passo exit_esc: quadros desde o pedido de saida; Esc solto aos 12
    wrong: std.ArrayList(u8) = .empty, // conferencias que falharam (a captura segue; saida 2 no fim)
    hidden_before: usize = 0, // click_cell: colunas ocultas antes do clique
    cleared: bool = false, // global_clear: o termo foi apagado com a busca rodando
    hit_rows: u64 = 0, // open_hit: linhas que a busca global listou para a tabela

    fn size(c: *const Capture) [2]u32 {
        const s = dbm.capture.plan[@min(c.step, dbm.capture.plan.len - 1)];
        return .{ s.w, s.h };
    }

    // Nada rodando nem pedido, banco aberto com uma tabela: pronto para o proximo estado
    fn ready(app: *const App) bool {
        if (app.slot.busy() or app.want_open or app.want_reload or app.want_run or app.want_select != null or app.want_global or
            app.search_wait.due != null or app.want_filter != null or app.want_unfilter != null or app.want_clear_filters or
            app.choice != null) return false;
        return app.db.isOpen() and app.selected != null;
    }

    // O estado pedido pelo passo ja esta na tela (o passo Apagar termina sem banco aberto)
    fn settled(c: *const Capture, app: *const App) bool {
        // saida pedida, pergunta aberta, Esc: a pergunta fecha e o programa continua aberto
        if (dbm.capture.plan[c.step].action == .exit_esc)
            return c.esc_frames > 14 and app.leave == null and !app.quit and ready(app);
        if (dbm.capture.plan[c.step].action == .prompt_delete)
            return !app.slot.busy() and app.choice == null and app.leave == null and !app.db.isOpen() and app.converted == null;
        return ready(app);
    }

    fn skip(c: *Capture, gpa: std.mem.Allocator, why: []const u8) void {
        c.skipped.print(gpa, "{s}: {s}\n", .{ dbm.capture.plan[c.step].name, why }) catch {};
        c.step += 1;
        c.applied = false;
    }

    // Antes de app.update(): pede o estado do passo atual quando nada esta rodando
    fn before(c: *Capture, app: *App) void {
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
            if (!app.slot.busy() and !app.want_open and !app.db.isOpen()) {
                c.failed = "the database did not open";
                return;
            }
            if (!ready(app)) return;
            if (c.apply(app)) return;
        }
    }

    // true = estado pedido; false = passo pulado (o laco tenta o proximo)
    fn apply(c: *Capture, app: *App) bool {
        const cap = dbm.capture;
        const action = cap.plan[c.step].action;
        // cada passo comeca sem os dialogos do passo anterior
        if (action != .about) app.about_open = false;
        // so os passos de Log abrem o painel (a captura nao le nem grava as configuracoes)
        app.prefs.log_open = action == .log or action == .log_error_open;
        if (app.prefs.log_open) markLogRead();
        if (action != .prompt and action != .prompt_delete) app.leave = null;
        if (action != .display_warning) app.display_dismiss = true;
        switch (action) {
            .exit_esc => {
                if (app.converted == null) {
                    c.skip(app.gpa, "not an Access file (no exit prompt)");
                    return false;
                }
                c.esc_frames = 0;
                app.requestLeave(.exit);
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
            .log, .log_error_open => {},
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
                if (app.converted != null) {
                    c.skip(app.gpa, "an Access file asks before closing");
                    return false;
                }
                // filtro da lista de tabelas, busca e escopo diferentes do padrao; depois abre de novo o mesmo arquivo
                copyZ(&app.table_filter, "SOX");
                app.table_filter_applied = app.table_filter;
                copyZ(&app.search, cap.filter_value);
                app.scope = .all;
                app.setPath(zstr(&app.loaded_path));
                app.want_open = true;
            },
            .prompt, .prompt_delete => {
                if (app.converted == null) {
                    c.skip(app.gpa, "not an Access file (nothing was converted)");
                    return false;
                }
                const tmp = app.converted.?.tmp;
                if (action == .prompt) app.requestLeave(.close) else {
                    app.requestLeave(.close);
                    c.deleted_tmp = tmp;
                    if (c.save_end) {
                        // resposta "Salvar" lembrada, com a pasta das capturas: grava <origem>.sqlite sem dialogo
                        var nb: [600]u8 = undefined;
                        const file = settings.fileName(&nb, std.fs.path.stem(zstr(&app.converted.?.source)), ".sqlite");
                        c.saved_path = std.fs.path.join(app.gpa, &.{ c.out_dir, file }) catch null;
                        app.session_choice = .save;
                        copyZ(&app.save_dir, c.out_dir);
                        app.choice = .save;
                    } else app.choice = .delete;
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
                if (app.leave == null) c.failed = "the exit prompt did not open";
                shim_key(ig.ImGuiKey_Escape, true);
            }
            if (c.esc_frames == 13) shim_key(ig.ImGuiKey_Escape, false);
            if (c.esc_frames == 200 and app.leave != null) c.failed = "Esc did not close the exit prompt";
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
        // Apagar ou Salvar: o temporario tem de ter sumido do disco; Salvar: o arquivo salvo e um SQLite
        if (c.deleted_tmp) |tmp| {
            if (std.Io.Dir.cwd().access(io, tmp.slice(), .{})) |_| {
                c.failed = "the temporary SQLite still exists after the answer";
                return true;
            } else |_| {}
        }
        if (c.saved_path) |p| {
            var hb: [16]u8 = undefined;
            const head = std.Io.Dir.cwd().readFile(io, p, &hb) catch "";
            if (!std.mem.eql(u8, head, "SQLite format 3\x00")) {
                c.failed = "the saved SQLite file is missing or is not a SQLite file";
                return true;
            }
        }
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
        defer if (c.saved_path) |p| gpa.free(p);
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
// ultimo aviso > o status normal (ultima acao). Abrir o Log zera os contadores.
const Level = enum { info, warn, err };
var alert: struct { level: Level = .info, buf: [1024]u8 = undefined, len: usize = 0, unread_err: u32 = 0, unread_warn: u32 = 0 } = .{};

fn logEvent(level: Level, s: []const u8) void {
    logEventShort(level, s, s);
}

// `full` vai para o log (texto inteiro do motor, sem cortar); `short` e a linha da barra de status
fn logEventShort(level: Level, full: []const u8, short: []const u8) void {
    var hb: [8]u8 = undefined;
    session_log.add(log_gpa, dbm.log.localTime(&hb), full);
    const s = short;
    if (level == .info) return;
    if (level == .err) alert.unread_err += 1 else alert.unread_warn += 1;
    // um aviso nao esconde um erro ainda nao visto
    if (level == .warn and alert.unread_err > 0) return;
    alert.level = level;
    alert.len = @min(s.len, alert.buf.len);
    @memcpy(alert.buf[0..alert.len], s[0..alert.len]);
    for (alert.buf[0..alert.len]) |*ch| if (ch.* == '\n') {
        ch.* = ' '; // uma linha na barra de status
    };
}

fn markLogRead() void {
    alert.unread_err = 0;
    alert.unread_warn = 0;
}

const Msg = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    is_err: bool = false,
    loaded: bool = false, // e a mensagem "Aberto: ..." (refeita ao trocar o idioma)

    // Texto do catalogo com argumentos; vai tambem para o log da sessao
    fn set(m: *Msg, is_err: bool, comptime key: []const u8, args: anytype) void {
        m.setText(is_err, i18n.fmt(&m.buf, key, args));
    }

    // Texto pronto (mensagem do banco ou de outro texto ja traduzido)
    fn setText(m: *Msg, is_err: bool, s: []const u8) void {
        m.replace(is_err, s);
        logEvent(if (is_err) .err else .info, m.buf[0..m.len]);
    }

    // Erro do motor: uma linha na tela com o prefixo traduzido (key = "err_sql" ou "err_db"); o texto inteiro no log
    fn setEngineError(m: *Msg, comptime key: []const u8, full: []const u8) void {
        var b: [1024]u8 = undefined;
        m.replace(true, i18n.fmt(&b, key, .{dbm.errorSummary(full)}));
        var fb: [1100]u8 = undefined;
        logEventShort(.err, i18n.fmt(&fb, key, .{full}), m.buf[0..m.len]);
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

// Botoes de dialogo do mesmo tamanho, alinhados a direita
fn dialogButtonWidth(labels: []const [:0]const u8) f32 {
    var w: f32 = 88;
    for (labels) |l| w = @max(w, buttonWidth(l));
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

const Tab = enum { data, schema, sql };

// Busca em todas as tabelas: o termo buscado e as tabelas com linhas (hits do gpa)
const Global = struct { term: [256:0]u8, hits: []worker.Hit };

// O que fazer depois de responder sobre o SQLite convertido
const Leave = enum { open, close, exit };
const Choice = enum { save, delete };

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

    // Access aberto = SQLite temporario; ao fechar, abrir outro ou sair a UI pergunta se salva ou apaga
    converted: ?struct { tmp: access.TempPath, source: [1024:0]u8 } = null,
    leave: ?Leave = null, // acao esperando a resposta (o dialogo fica aberto enquanto isto existir)
    choice: ?Choice = null, // resposta, executada em update() quando nenhum trabalho roda
    session_choice: ?Choice = null, // a primeira resposta vale ate o programa fechar
    save_dir: [1024:0]u8 = @splat(0), // pasta escolhida no primeiro "Salvar" da sessao
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
    limit: u32 = query.default_limit, // linhas carregadas na aba Dados (lista 100 / 500 / 1000)
    total: u64 = 0,
    // busca que vale para as linhas na tela (a caixa de busca pode ter texto ainda nao aplicado)
    applied_search: [256:0]u8 = @splat(0),
    // Filtros coluna = valor exato (clique direito na celula), somados com AND na consulta ao banco.
    // `column` aponta para col_names e `value` e do gpa; a lista so muda sem trabalho rodando (o pedido a le).
    filters: std.ArrayList(query.Criterion) = .empty,
    want_filter: ?struct { col: usize, value: ?[]u8 } = null, // novo filtro pedido (valor do gpa; null = NULL)
    want_unfilter: ?usize = null, // remover o filtro de indice N
    want_clear_filters: bool = false,

    sql: [8192:0]u8 = @splat(0),
    result: ?dbm.Grid = null,
    result_sql: [8192:0]u8 = @splat(0), // SQL que gerou `result` (a exportacao roda de novo, sem limite)
    sql_msg: Msg = .{},
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
    want_theme: ?settings.Theme = null,
    want_lang: ?i18n.Lang = null,
    want_about: bool = false,
    about_open: bool = false,
    log_seen: usize = 0, // tamanho do log no ultimo quadro (linha nova: rola para o fim)
    focus_sql: bool = false,
    reveal_selected: bool = false, // rola a lista de tabelas ate a selecionada (ex.: --table)
    start_table: []const u8 = "", // --table: tabela inicial do proximo open
    start_sql: bool = false, // --sql: roda depois do primeiro open
    start_search: []const u8 = "", // --search: busca na aba Data depois do primeiro open
    start_cell: ?[2]usize = null, // --cell: linha e coluna (base 0) que abrem com o menu de copia
    start_menu: ?enum { File, View, Settings, Help, Export } = null, // --menu: menu aberto quando o banco abrir (capturas)
    start_export: ?ExportKind = null, // --export: abre o dialogo de salvar dessa exportacao quando o banco abrir

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
        app.gpa.free(app.counts);
        app.filter_scratch.deinit(app.gpa);
        app.filters.deinit(app.gpa);
        app.db.close();
        // saida sem resposta (conversao terminada no Cancelar, erro ao iniciar): nada de temporario orfao
        if (late.len > 0) access.deleteQuiet(app.io, late.slice());
        if (app.converted) |cv| access.deleteQuiet(app.io, cv.tmp.slice());
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

    // Busca da caixa da aba Data no escopo atual (Enter ou 300 ms depois da ultima tecla). Todas as tabelas: a lista
    // anterior some ate o resultado do termo novo chegar
    fn runSearch(app: *App) void {
        app.search_wait.due = null;
        if (app.scope == .table) {
            app.want_reload = true;
            return;
        }
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
            error.UnsupportedExtension => msg.set(true, "err_not_db", .{}),
            error.AccessDenied, error.FileBusy, error.PermissionDenied => msg.set(true, "err_cannot_write", .{err}),
            else => msg.set(true, "err_generic", .{err}),
        }
    }

    fn setPath(app: *App, p: []const u8) void {
        copyZ(&app.path, p);
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
                r.table_name = app.start_table;
                app.start_table = "";
            },
            .select => {
                r.table = app.want_select orelse return;
                r.search = if (app.select_search) app.search else @splat(0);
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
            },
            .sql => r.sql = app.sql,
            .export_ => {}, // preenchido em startExport
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
                app.source = if (app.db.isOpen()) out.source else null;
                app.loaded_path = if (app.db.isOpen()) app.slot.req.path else @splat(0);
                app.updateTitle();
                // o SQLite convertido existe mesmo se a contagem foi cancelada: a UI fica com ele
                if (out.converted.len > 0) app.converted = .{ .tmp = out.converted, .source = app.slot.req.path };
                if (app.db.isOpen() and out.err == null) {
                    app.setLoadedStatus(true);
                    app.rememberDir(zstr(&app.slot.req.path));
                    // capturas de tela: so o nome do arquivo na caixa (a pasta tem o nome do usuario)
                    if (app.capture_mode) copyZ(&app.path, std.fs.path.basename(zstr(&app.slot.req.path)));
                    if (app.start_sql) {
                        app.want_run = true;
                        app.focus_sql = true;
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
                app.total = out.total;
                app.applied_search = app.slot.req.search;
            },
            .sql => {
                app.clearResult();
                if (out.result) |g| {
                    app.result = g;
                    out.result = null;
                    app.result_sql = app.slot.req.sql;
                    app.refilter();
                    if (g.truncated)
                        app.sql_msg.set(false, "sql_more_rows", .{ g.rows.len, g.rows.len })
                    else
                        app.sql_msg.set(false, "sql_rows_cols", .{ g.rows.len, g.columns.len });
                }
            },
            .export_ => if (out.err == null) {
                const r = &app.slot.req;
                // .xlsx: o que o Excel nao comporta aparece na mesma linha, em destaque (nada some calado)
                const p = &app.slot.progress;
                var cells_buf: [96]u8 = undefined;
                var cols_buf: [96]u8 = undefined;
                const cells_s = if (p.cut_cells > 0) i18n.fmt(&cells_buf, "export_cut_cells", .{p.cut_cells}) else "";
                const cols_s = if (p.cut_cols > 0) i18n.fmt(&cols_buf, "export_cut_cols", .{p.cut_cols}) else "";
                const unit = if (r.export_kind.countsTables()) tr("unit_tables") else tr("unit_rows");
                app.status.set(cells_s.len + cols_s.len > 0, "status_exported", .{ out.exported, unit, std.fs.path.basename(r.destPath()), cells_s, cols_s });
            },
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

    // Fechar o arquivo, abrir outro ou sair. update() executa quando nenhum trabalho roda; com SQLite convertido,
    // antes pergunta (ou usa a resposta da sessao)
    fn requestLeave(app: *App, action: Leave) void {
        if (action == .exit) app.slot.cancel(); // um trabalho longo nao segura a saida
        if (app.leave == null or action == .exit) app.leave = action;
    }

    fn finishLeave(app: *App, action: Leave) void {
        switch (action) {
            .open => app.want_open = true,
            .close => app.closeFile(),
            .exit => app.quit = true,
        }
    }

    // Solta o arquivo aberto (so sem trabalho rodando) e apaga o SQLite temporario, se houver
    fn closeFile(app: *App) void {
        if (!app.db.isOpen() and app.converted == null) return;
        const name = std.fs.path.basename(zstr(&app.loaded_path));
        var nb: [256]u8 = undefined;
        const shown = nb[0..@min(name.len, nb.len)];
        @memcpy(shown, name[0..shown.len]);
        app.clearTable();
        app.clearResult();
        app.clearGlobal();
        app.sql_msg.len = 0;
        app.db.closeSource();
        app.gpa.free(app.counts);
        app.counts = &.{};
        app.source = null;
        app.loaded_path = @splat(0);
        if (app.converted) |cv| {
            access.deleteQuiet(app.io, cv.tmp.slice());
            app.converted = null;
        }
        app.updateTitle();
        if (shown.len > 0) app.status.set(false, "status_closed", .{shown});
    }

    // Executa a resposta do dialogo do SQLite convertido (na thread da UI, sem trabalho rodando)
    // from_prompt: respondida no dialogo (cancelar o dialogo de arquivo volta para a pergunta); senao e a resposta
    // lembrada da sessao (cancelar desiste da acao)
    fn resolve(app: *App, ch: Choice, from_prompt: bool) void {
        const cv = app.converted orelse {
            app.leave = null;
            return;
        };
        var saved: ?[]const u8 = null;
        var sugg_buf: [4096]u8 = undefined;
        var path_buf: dialog.PathBuf = undefined;
        if (ch == .save) {
            const stem = std.fs.path.stem(zstr(&cv.source));
            var name_buf: [600]u8 = undefined;
            const file = settings.fileName(&name_buf, stem, ".sqlite");
            var dest: ?[]const u8 = null;
            // resposta lembrada: grava direto na pasta escolhida da primeira vez, se o nome estiver livre
            if (app.session_choice == .save and app.save_dir[0] != 0) {
                const p = settings.suggest(&sugg_buf, zstr(&app.save_dir), file);
                if (std.Io.Dir.cwd().access(app.io, p, .{})) |_| {} else |_| dest = p;
            }
            if (dest == null) {
                // padrao: ao lado do arquivo de origem, <origem>.sqlite
                const initial = settings.suggest(&sugg_buf, std.fs.path.dirname(zstr(&cv.source)) orelse "", file);
                dest = dialog.pick(app.io, .save_sqlite, app.hwnd, initial, &path_buf);
                if (dest == null) {
                    if (dialog.unavailable) app.status.set(true, "err_no_dialog", .{});
                    // cancelou o dialogo de salvar: nada fecha; veio da pergunta, ela volta (Esc continua valendo)
                    if (!from_prompt) app.leave = null;
                    return;
                }
            }
            std.Io.Dir.cwd().copyFile(cv.tmp.slice(), std.Io.Dir.cwd(), dest.?, app.io, .{}) catch |e| {
                app.status.set(true, "err_save_sqlite", .{e});
                app.leave = null; // nada fecha: o usuario tenta de novo
                return;
            };
            copyZ(&app.save_dir, std.fs.path.dirname(dest.?) orelse "");
            saved = dest;
        }
        app.session_choice = ch;
        const action = app.leave orelse .close;
        app.leave = null;
        app.closeFile();
        // a ultima linha de status diz o que aconteceu com o SQLite (o "Fechado" fica no log)
        // so o nome do arquivo na linha de status (o caminho inteiro quebraria a linha); a pasta vai para o log
        if (saved) |d| {
            logLine(d);
            app.status.set(false, "converted_saved", .{std.fs.path.basename(d)});
        } else app.status.set(false, "converted_deleted", .{});
        app.finishLeave(action);
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
        if (app.slot.busy()) return; // um trabalho por vez; os pedidos abaixo ficam para depois
        if (app.choice) |ch| {
            app.choice = null;
            app.resolve(ch, true);
        } else if (app.leave) |action| {
            if (app.converted == null) {
                app.leave = null;
                app.finishLeave(action);
            } else if (app.session_choice) |ch| app.resolve(ch, false);
        }
        if (app.leave != null) return; // esperando a resposta sobre o SQLite convertido
        if (app.want_filter != null or app.want_unfilter != null or app.want_clear_filters) {
            app.editFilters();
            app.want_reload = true;
        }
        if (app.start_export != null and app.db.isOpen() and !app.want_open and !app.want_reload and !app.want_run) {
            app.want_export = app.start_export;
            app.start_export = null;
        }
        if (app.want_export) |kind| {
            app.want_export = null;
            app.startExport(kind);
        } else if (app.want_open) {
            app.want_open = false;
            if (app.converted != null) app.requestLeave(.open) else app.start(.open);
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
        }
    }

    // O que a aba atual exporta: tabela (Data), esquema (Schema, via DESCRIBE) ou resultado (SQL)
    fn canExportCurrent(app: *const App) bool {
        if (app.opening() or !app.db.isOpen()) return false;
        return switch (app.tab) {
            .data, .schema => app.selected != null,
            .sql => app.result != null,
        };
    }

    // Dialogo de salvar (pasta do arquivo aberto; sem arquivo, a ultima usada) e dispara o trabalho
    fn startExport(app: *App, kind_in: ExportKind) void {
        if (!app.db.isOpen()) return;
        var kind = kind_in;
        const r = &app.slot.req;
        const loaded = zstr(&app.loaded_path);
        var name_buf: [512]u8 = undefined;
        const base: []const u8 = switch (kind) {
            .db_duckdb, .db_sqlite, .db_xlsx => std.fs.path.stem(loaded),
            .table_csv, .table_xlsx => switch (app.tab) {
                .schema => std.fmt.bufPrint(&name_buf, "{s}_schema", .{app.db.table_names[app.selected orelse return]}) catch "schema",
                else => app.db.table_names[app.selected orelse return],
            },
            .result_csv, .result_xlsx => "query",
        };
        var file_buf: [600]u8 = undefined;
        var file = settings.fileName(&file_buf, base, kind.ext());
        // DB4.duckdb exportado para .duckdb: o nome sugerido nao pode ser o do proprio arquivo aberto
        if (std.ascii.eqlIgnoreCase(file, std.fs.path.basename(loaded))) {
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
            .db_duckdb => .save_duckdb,
            .db_sqlite => .save_sqlite,
            .db_xlsx, .table_xlsx, .result_xlsx => .save_xlsx,
            .table_csv, .result_csv => .save_csv,
        };
        var path_buf: dialog.PathBuf = undefined;
        const dest = dialog.pick(app.io, dkind, app.hwnd, initial, &path_buf) orelse {
            if (dialog.unavailable) app.status.set(true, "err_no_dialog", .{});
            return;
        };
        if (std.ascii.eqlIgnoreCase(dest, loaded)) return app.status.set(true, "err_choose_other", .{});
        if (app.converted) |cv| if (std.ascii.eqlIgnoreCase(dest, cv.tmp.slice())) return app.status.set(true, "err_choose_other", .{});
        app.rememberDir(dest);

        r.setDest(dest);
        r.total_hint = 0;
        if (kind == .table_csv or kind == .table_xlsx) {
            const index = app.selected orelse return;
            if (app.tab == .schema) {
                // o esquema exportado e o mesmo da aba: coluna, tipo, aceita nulo (titulos e Sim/Nao no idioma da tela)
                const sql = query.buildSchemaExport(app.gpa, app.db.table_names[index], .{ tr("schema_column"), tr("schema_type"), tr("schema_null") }, tr("yes"), tr("no")) catch "";
                defer app.gpa.free(sql);
                if (sql.len == 0 or sql.len >= r.sql.len) return app.status.set(true, "err_table_name_long", .{});
                @memcpy(r.sql[0..sql.len], sql);
                r.sql[sql.len] = 0;
                kind = if (kind == .table_csv) .result_csv else .result_xlsx;
            } else {
                // a tabela inteira com a busca e a ordenacao aplicadas na tela
                r.table = index;
                r.columns = app.col_names;
                r.search = app.applied_search;
                r.filters = app.filters.items;
                r.sort_col = app.sort_col;
                r.sort_desc = app.sort_desc;
                r.total_hint = app.total;
            }
        } else if (kind == .result_csv or kind == .result_xlsx) {
            r.sql = app.result_sql;
            if (app.result) |g| if (!g.truncated) {
                r.total_hint = g.rows.len;
            };
        } else if (kind == .db_xlsx) {
            for (app.counts) |n| r.total_hint += n;
        }
        r.export_kind = kind;
        app.start(.export_);
    }

    fn draw(app: *App) void {
        app.drawMenu();
        const vp = ig.igGetMainViewport();
        ig.igSetNextWindowPos(vp.*.WorkPos, ig.ImGuiCond_Always, .{ .x = 0, .y = 0 });
        ig.igSetNextWindowSize(vp.*.WorkSize, ig.ImGuiCond_Always);
        _ = ig.igBegin("##main", null, ig.ImGuiWindowFlags_NoDecoration | ig.ImGuiWindowFlags_NoMove |
            ig.ImGuiWindowFlags_NoSavedSettings | ig.ImGuiWindowFlags_NoBringToFrontOnFocus);
        defer ig.igEnd();
        app.drawAbout();
        app.drawConverted();
        app.drawDisplayWarning();

        // Barra superior: caminho + Procurar + Abrir + Exportar (tambem aceita arrastar o arquivo para a janela). O caminho
        // ocupa a linha toda menos os 3 botoes: o status foi para a barra de baixo, e com 40% cortava caminho longo
        const buttons = buttonWidth(tr("browse")) + buttonWidth(tr("open")) + buttonWidth(tr("export_button")) +
            3 * ig.igGetStyle().*.ItemSpacing.x;
        ig.igSetNextItemWidth(ig.igGetContentRegionAvail().x - buttons);
        // ElideLeft: caminho maior que a linha perde o comeco (com ...), nunca o nome do arquivo
        const enter = ig.igInputTextWithHint("##path", tr("path_hint"), &app.path, app.path.len + 1, ig.ImGuiInputTextFlags_EnterReturnsTrue | ig.ImGuiInputTextFlags_ElideLeft, null, null);
        ig.igSameLine(0, -1);
        if (button(tr("browse"))) app.want_browse = true;
        ig.igSameLine(0, -1);
        if (button(tr("open")) or enter) app.want_open = true;
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

    // Itens de exportacao (menu Arquivo > Exportar e botao Exportar...)
    fn exportItems(app: *App) void {
        const can_db = !app.opening() and app.db.isOpen();
        if (ig.igMenuItem_Bool(tr("export_db_sqlite"), null, false, can_db)) app.want_export = .db_sqlite;
        if (ig.igMenuItem_Bool(tr("export_db_xlsx"), null, false, can_db)) app.want_export = .db_xlsx;
        if (ig.igMenuItem_Bool(tr("export_db_duckdb"), null, false, can_db)) app.want_export = .db_duckdb; // DuckDB por ultimo
        ig.igSeparator();
        const cur = app.canExportCurrent();
        const csv_key, const xlsx_key = switch (app.tab) {
            .data => .{ tr("export_table_csv"), tr("export_table_xlsx") },
            .schema => .{ tr("export_schema_csv"), tr("export_schema_xlsx") },
            .sql => .{ tr("export_result_csv"), tr("export_result_xlsx") },
        };
        if (ig.igMenuItem_Bool(csv_key, null, false, cur)) app.want_export = if (app.tab == .sql) .result_csv else .table_csv;
        if (ig.igMenuItem_Bool(xlsx_key, null, false, cur)) app.want_export = if (app.tab == .sql) .result_xlsx else .table_xlsx;
    }

    fn drawMenu(app: *App) void {
        if (!ig.igBeginMainMenuBar()) return;
        defer ig.igEndMainMenuBar();
        var lb: [6][96]u8 = undefined;
        const file_l = idLabel(&lb[0], "menu_file", "file");
        const view_l = idLabel(&lb[1], "menu_view", "view");
        const settings_l = idLabel(&lb[2], "menu_settings", "settings");
        const help_l = idLabel(&lb[3], "menu_help", "help");
        const export_l = idLabel(&lb[4], "menu_export", "export");
        const lang_l = idLabel(&lb[5], "menu_language", "language");
        // --menu: abre o menu (e o submenu Exportar / Idioma) no mesmo quadro, para as capturas de tela
        const open_file = app.takeStartMenu(.File);
        const open_settings = app.takeStartMenu(.Settings);
        if (open_file) _ = ig.igOpenPopup_Str(file_l, 0);
        if (open_settings) _ = ig.igOpenPopup_Str(settings_l, 0);
        if (app.takeStartMenu(.View)) _ = ig.igOpenPopup_Str(view_l, 0);
        if (app.takeStartMenu(.Help)) _ = ig.igOpenPopup_Str(help_l, 0);
        const has_db = !app.opening() and app.db.isOpen();
        if (ig.igBeginMenu(file_l, true)) {
            defer ig.igEndMenu();
            if (ig.igMenuItem_Bool(tr("menu_open"), "Ctrl+O", false, true)) app.want_browse = true;
            if (open_file) _ = ig.igOpenPopup_Str(export_l, 0);
            if (ig.igBeginMenu(export_l, has_db)) {
                defer ig.igEndMenu();
                app.exportItems();
            }
            if (ig.igMenuItem_Bool(tr("menu_close"), null, false, has_db)) app.requestLeave(.close);
            ig.igSeparator();
            if (ig.igMenuItem_Bool(tr("menu_exit"), null, false, true)) app.requestLeave(.exit);
        }
        if (ig.igBeginMenu(view_l, true)) {
            defer ig.igEndMenu();
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
            if (ig.igMenuItem_Bool(tr("menu_show_null"), null, app.prefs.show_null, true)) {
                app.prefs.show_null = !app.prefs.show_null;
                app.savePrefs();
            }
        }
        if (ig.igBeginMenu(help_l, true)) {
            defer ig.igEndMenu();
            if (ig.igMenuItem_Bool(tr("menu_about"), null, false, true)) app.want_about = true;
        }
        if (ig.igIsKeyChordPressed_Nil(ig.ImGuiMod_Ctrl | ig.ImGuiKey_O)) app.want_browse = true;
        if (ig.igIsKeyChordPressed_Nil(ig.ImGuiMod_Ctrl | ig.ImGuiKey_L)) app.setLogOpen(!app.prefs.log_open);
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
            .{ tr("about_author"), about.author },
            .{ tr("about_license"), tr("about_license_text") },
        };
        if (ig.igBeginTable("##about_rows", 2, ig.ImGuiTableFlags_SizingFixedFit, .{ .x = 0, .y = 0 }, 0)) {
            defer ig.igEndTable();
            for (rows) |row| {
                ig.igTableNextRow(0, 0);
                _ = ig.igTableNextColumn();
                ig.igTextDisabled("%s", row[0].ptr);
                _ = ig.igTableNextColumn();
                textSlice(row[1]);
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
        const bw = dialogButtonWidth(&.{close_l});
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
        const bw = dialogButtonWidth(&.{ copy_l, ok_l });
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

    // Pergunta sobre o SQLite convertido do Access: Salvar... / Apagar / Cancelar
    fn drawConverted(app: *App) void {
        var tb: [96]u8 = undefined;
        const title = idLabel(&tb, "converted_title", "converted");
        const want = app.leave != null and app.choice == null and app.converted != null;
        if (want and !ig.igIsPopupOpen_Str(title, 0)) _ = ig.igOpenPopup_Str(title, 0);
        centerNext();
        // X do dialogo, Esc ou Cancelar fecham a pergunta (inclusive na saida do programa); Enter = Salvar...
        var open = true;
        if (!ig.igBeginPopupModal(title, &open, ig.ImGuiWindowFlags_AlwaysAutoResize | ig.ImGuiWindowFlags_NoSavedSettings)) {
            if (!open) app.leave = null; // o X fecha o popup antes de chegar aqui
            return;
        }
        defer ig.igEndPopup();
        if (!want) return ig.igCloseCurrentPopup();
        if (!open or ig.igIsKeyPressed_Bool(ig.ImGuiKey_Escape, false)) {
            app.leave = null;
            return ig.igCloseCurrentPopup();
        }
        const cv = app.converted.?;
        var mb: [600]u8 = undefined;
        // largura controlada: o nome longo quebra a linha em vez de alargar o dialogo
        ig.igPushTextWrapPos(ig.igGetFontSize() * 30);
        textSlice(i18n.fmt(&mb, "converted_text", .{std.fs.path.basename(zstr(&cv.source))}));
        ig.igPopTextWrapPos();
        ig.igSpacing();
        const save_l = tr("save");
        const delete_l = tr("delete");
        const cancel_l = tr("cancel");
        const bw = dialogButtonWidth(&.{ save_l, delete_l, cancel_l });
        const st = ig.igGetStyle();
        const row_w = 3 * bw + 2 * st.*.ItemSpacing.x;
        ig.igSetCursorPosX(ig.igGetCursorPosX() + @max(0, ig.igGetContentRegionAvail().x - row_w));
        if (ig.igButton(save_l, .{ .x = bw, .y = 0 })) app.choice = .save;
        // foco inicial visivel no botao padrao; Enter (com o foco nele) salva
        if (ig.igIsWindowAppearing()) {
            ig.igSetItemDefaultFocus();
            ig.igSetKeyboardFocusHere(-1);
            ig.igSetNavCursorVisible(true);
        }
        var sb: [600]u8 = undefined;
        itemTooltip(i18n.fmtZ(&sb, "converted_save_tip", .{std.fs.path.stem(zstr(&cv.source))}));
        ig.igSameLine(0, -1);
        if (ig.igButton(delete_l, .{ .x = bw, .y = 0 })) app.choice = .delete;
        ig.igSameLine(0, -1);
        if (ig.igButton(cancel_l, .{ .x = bw, .y = 0 })) {
            app.leave = null;
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
        const unread = if (open) 0 else alert.unread_err + alert.unread_warn;
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
            const what = switch (r.kind) {
                .open => if (query.sourceKind(zstr(&r.path)) catch .duckdb == .access) tr("busy_converting") else tr("busy_opening"),
                .select, .reload => tr("busy_loading"),
                .sql => tr("busy_running"),
                .export_ => tr("busy_exporting"),
                .search_all => tr("busy_searching"),
            };
            textT("busy_elapsed", .{ what, elapsed });
            if (total > 0 and (r.kind == .open or r.kind == .export_ or r.kind == .search_all)) {
                ig.igSameLine(0, -1);
                var buf: [64]u8 = undefined;
                const unit = if (r.kind != .export_ or r.export_kind.countsTables()) tr("unit_tables") else tr("unit_rows");
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
            shown = alert.buf[0..alert.len];
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
        ig.igSetNextItemWidth(-1);
        // filtra 300 ms depois da ultima tecla; Enter filtra na hora
        if (ig.igInputTextWithHint("##filter", tr("filter_tables"), &app.table_filter, app.table_filter.len + 1, ig.ImGuiInputTextFlags_EnterReturnsTrue, null, null)) {
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
        for (app.db.table_names, 0..) |name, i| {
            const row = [_]?[]const u8{name};
            if (!(dbm.gridtools.rowMatches(app.gpa, &app.filter_scratch, &row, words) catch true)) continue;
            ig.igTableNextRow(0, 0);
            _ = ig.igTableNextColumn();
            ig.igPushID_Int(@intCast(i));
            // "##" + PushID: o rotulo fica vazio e o nome (que nao termina em 0) vai por textSlice
            if (ig.igSelectable_Bool("##t", app.selected == i, ig.ImGuiSelectableFlags_SpanAllColumns, .{ .x = 0, .y = 0 })) {
                app.want_select = i;
                app.scope = .table; // a aba Data mostra a tabela escolhida
            }
            const hovered = ig.igIsItemHovered(0);
            ig.igPopID();
            if (app.selected == i and app.reveal_selected) {
                ig.igSetScrollHereY(0.5);
                app.reveal_selected = false;
            }
            ig.igSameLine(0, 0);
            // nome mais largo que a coluna (painel estreito): o nome inteiro aparece no tooltip
            if (hovered and textWidth(name) > ig.igGetContentRegionAvail().x) tooltip(name);
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
        var lb: [3][64]u8 = undefined;

        if (ig.igBeginTabItem(idLabel(&lb[0], "tab_data", "data"), null, 0)) {
            defer ig.igEndTabItem();
            app.tab = .data;
            app.drawData();
        }
        if (ig.igBeginTabItem(idLabel(&lb[1], "tab_schema", "schema"), null, 0)) {
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
                _ = drawGrid("##schema", &shown, null, &app.schema_sel, null, .plain, &app.prefs, "");
                ig.igPopStyleVar(1);
            }
        }
        if (ig.igBeginTabItem(idLabel(&lb[2], "tab_sql", "sql"), null, if (app.focus_sql) ig.ImGuiTabItemFlags_SetSelected else 0)) {
            defer ig.igEndTabItem();
            app.tab = .sql;
            app.drawSql();
        }
        app.focus_sql = false;
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
                    app.want_reload = true;
                }
            }
        }
        // exportar a tabela fica so no Exportar... da barra de cima (um botao por acao)
        sameLineIfFits(buttonWidth(tr("columns_button")), -1);
        columnsButton(&app.data_sel);
        // contagem na linha de baixo (as colunas ocultas ficam na barra de baixo): quebra na borda da janela em vez
        // de ser cortada
        const shown: u64 = if (app.data) |g| g.rows.len else 0;
        const in_table = if (index < app.counts.len) app.counts[index] else app.total;
        var cb: [700]u8 = undefined;
        const count_line = if (app.applied_search[0] != 0 or app.filters.items.len > 0)
            i18n.fmtCount(&cb, "rows_found", app.total, .{ name, shown, app.total, in_table })
        else
            i18n.fmtCount(&cb, "rows_showing", app.total, .{ name, shown, app.total });
        ig.igAlignTextToFramePadding();
        ig.igPushTextWrapPos(0);
        textSlice(count_line);
        ig.igPopTextWrapPos();

        // Filtros ativos: um botao por filtro (clicar remove) e Limpar filtros; o que nao cabe desce de linha
        const filters_l = tr("filters_label");
        for (app.filters.items, 0..) |f, i| {
            var label: [200]u8 = undefined;
            const chip = dbm.gridtools.filterLabel(&label, f);
            if (i == 0) {
                sameLineIfFits(textWidth(filters_l) + ig.igGetStyle().*.ItemSpacing.x + buttonWidth(chip), 24);
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
        if (app.data) |*g| if (drawGrid("##data", g, .{ .col = app.sort_col, .desc = app.sort_desc }, &app.data_sel, null, .filter, &app.prefs, app.db.table_names[index])) |s| {
            app.sort_col = s.col;
            app.sort_desc = s.desc;
            app.want_reload = true;
        };
        // pedidos do menu da celula
        const sel = &app.data_sel;
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
        const enter = ig.igInputTextMultiline("##sql", &app.sql, app.sql.len + 1, .{ .x = -1, .y = ig.igGetTextLineHeight() * 7 }, ig.ImGuiInputTextFlags_EnterReturnsTrue, null, null);
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
            textT("rows_match", .{ rows.len, g.rows.len });
        }
        _ = drawGrid("##result", g, null, &app.result_sel, app.result_rows, .hide, &app.prefs, tr("sql_result"));
    }

    // Escopo da busca ao lado da caixa: "Esta tabela" | "Todas as tabelas", dois segmentos colados; o escolhido com
    // a cor de botao do tema, o outro com a cor das caixas de texto
    fn scopeSelector(app: *App) void {
        const st = ig.igGetStyle();
        const dl = ig.igGetWindowDrawList();
        const labels = [_][:0]const u8{ tr("scope_table"), tr("scope_all") };
        for (labels, 0..) |label, i| {
            const s: settings.SearchScope = if (i == 0) .table else .all;
            if (i > 0) ig.igSameLine(0, 0);
            ig.igPushID_Int(@intCast(i));
            if (ig.igInvisibleButton("##scope", .{ .x = textWidth(label) + 2 * st.*.FramePadding.x, .y = ig.igGetFrameHeight() }, 0)) app.setScope(s);
            ig.igPopID();
            const col: c_int = if (app.scope == s) ig.ImGuiCol_Button else if (ig.igIsItemHovered(0)) ig.ImGuiCol_FrameBgHovered else ig.ImGuiCol_FrameBg;
            const corners: c_int = if (i == 0) ig.ImDrawFlags_RoundLeft else ig.ImDrawFlags_RoundRight;
            const min = ig.igGetItemRectMin();
            const max = ig.igGetItemRectMax();
            ig.ImDrawList_AddRectFilled(dl, min, max, ig.igGetColorU32_Col(col, 1), st.*.FrameRounding, corners);
            ig.ImDrawList_AddRect(dl, min, max, ig.igGetColorU32_Col(ig.ImGuiCol_Border, 1), st.*.FrameRounding, st.*.FrameBorderSize, corners);
            ig.ImDrawList_AddText_Vec2(dl, .{ .x = min.x + st.*.FramePadding.x, .y = min.y + st.*.FramePadding.y }, ig.igGetColorU32_Col(ig.ImGuiCol_Text, 1), label.ptr, label.ptr + label.len);
        }
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

// Coluna "Aceita nulo" do Esquema no idioma da tela (Sim/Nao, Si/No, Yes/No): o YES/NO do DuckDB troca pelo texto
// do catalogo (estatico); refeito ao trocar o idioma
fn localizeSchema(g: *dbm.Grid) void {
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

// plain: so copia; hide: tambem ocultar colunas; filter: tambem "Filtrar por este valor" (aba Dados)
const GridMode = enum { plain, hide, filter };

// Poe na area de transferencia o valor da celula selecionada ou a linha dela separada por TAB (NULL = vazio);
// `header`: a linha de nomes das colunas vem antes
fn copySelection(g: *const dbm.Grid, sel: *const GridSel, whole_row: bool, header: bool) void {
    const r = sel.row orelse return;
    if (r >= g.rows.len or sel.col >= g.columns.len) return;
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();
    const w = &out.writer;
    (if (whole_row) dbm.gridtools.writeRow(w, g.columns, g.rows[r], header) else w.writeAll(g.rows[r][sel.col] orelse "")) catch return;
    w.writeByte(0) catch return;
    ig.igSetClipboardText(out.written().ptr);
}

// Desenha um Grid; com `sort` os cabecalhos ordenam e a nova ordenacao pedida e devolvida.
// `rows` limita e ordena as linhas mostradas (filtro); null = todas.
// Clique seleciona a celula; Ctrl+C copia o valor; o clique direito abre o menu da celula (copiar, filtrar).
// Com `mode` != .plain o clique direito no cabecalho abre o menu do cabecalho: ajustar a largura, ocultar e mostrar
// colunas. NULL aparece como "NULL" ou como celula vazia (Configuracoes > Exibir NULL). `owner`: tabela ou resultado,
// no titulo do dialogo Colunas.
fn drawGrid(id: [*:0]const u8, g: *const dbm.Grid, sort: ?Sort, sel: *GridSel, rows: ?[]const usize, mode: GridMode, prefs: *settings.Settings, owner: []const u8) ?Sort {
    const n_cols: usize = @min(g.columns.len, max_grid_cols);
    if (n_cols == 0) return null;
    const can_hide = mode != .plain;
    var flags: c_int = ig.ImGuiTableFlags_Borders | ig.ImGuiTableFlags_RowBg | ig.ImGuiTableFlags_Resizable |
        ig.ImGuiTableFlags_ScrollX | ig.ImGuiTableFlags_ScrollY | ig.ImGuiTableFlags_SizingFixedFit;
    if (sort != null) flags |= ig.ImGuiTableFlags_Sortable | ig.ImGuiTableFlags_SortTristate;
    if (can_hide) flags |= ig.ImGuiTableFlags_Hideable;
    if (!ig.igBeginTable(id, @intCast(n_cols), flags, .{ .x = 0, .y = 0 }, 0)) return null;
    defer ig.igEndTable();
    const table = ig.igGetCurrentTable(); // "Ajustar coluna" do menu do cabecalho

    ig.igTableSetupScrollFreeze(0, 1);
    for (g.columns[0..n_cols]) |name| ig.igTableSetupColumn(name.ptr, 0, 0, 0);
    var open_header = false;
    if (can_hide) {
        // a lista de ocultas e nossa (GridSel.hidden); o ImGui so executa
        for (0..n_cols) |c| ig.igTableSetColumnEnabled(@intCast(c), !sel.hidden.isSet(c));
        // cabecalho como o TableHeadersRow, mais o clique direito com o nosso menu
        ig.igTableNextRow(ig.ImGuiTableRowFlags_Headers, ig.igTableGetHeaderRowHeight());
        for (g.columns[0..n_cols], 0..) |name, c| {
            if (!ig.igTableSetColumnIndex(@intCast(c))) continue;
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
        }
    } else ig.igTableHeadersRow();

    var changed: ?Sort = null;
    if (sort) |cur| if (ig.igTableGetSortSpecs()) |specs| if (specs.*.SpecsDirty) {
        specs.*.SpecsDirty = false;
        const new: Sort = if (specs.*.SpecsCount > 0)
            .{ .col = @intCast(specs.*.Specs[0].ColumnIndex), .desc = specs.*.Specs[0].SortDirection == ig.ImGuiSortDirection_Descending }
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

    if (ig.igIsWindowFocused(0) and ig.igIsKeyChordPressed_Nil(ig.ImGuiMod_Ctrl | ig.ImGuiKey_C)) copySelection(g, sel, false, false);
    if (open_menu) _ = ig.igOpenPopup_Str("##copy", 0);
    // menu da celula do Go: filtros por valor (aba Dados), depois copiar valor, linha e linha com o cabecalho
    if (ig.igBeginPopup("##copy", 0)) {
        defer ig.igEndPopup();
        if (mode == .filter) {
            if (ig.igMenuItem_Bool(tr("filter_by_value"), null, false, true)) sel.want_filter = true;
            if (ig.igMenuItem_Bool(tr("clear_filters"), null, false, sel.has_filters)) sel.want_clear = true;
            ig.igSeparator();
        }
        if (ig.igMenuItem_Bool(tr("copy_value"), "Ctrl+C", false, true)) copySelection(g, sel, false, false);
        if (ig.igMenuItem_Bool(tr("copy_row"), null, false, true)) copySelection(g, sel, true, false);
        if (ig.igMenuItem_Bool(tr("copy_row_header"), null, false, true)) copySelection(g, sel, true, true);
    }
    if (!can_hide) return changed;

    // Cabecalho: este menu abre depois do menu padrao do ImGui (TableHeader) no mesmo quadro e toma o lugar dele.
    // Ordem do Rust: Ajustar coluna, Ajustar todas, Ocultar esta coluna, Colunas..., Mostrar todas (sem coluna oculta,
    // desabilitado) e a lista das colunas; a ultima coluna visivel nao pode ser ocultada.
    if (open_header) _ = ig.igOpenPopup_Str("##header", 0);
    if (ig.igBeginPopup("##header", 0)) {
        defer ig.igEndPopup();
        const visible = n_cols - sel.hiddenCount(n_cols);
        if (ig.igMenuItem_Bool(tr("fit_column"), null, false, true)) ig.igTableSetColumnWidthAutoSingle(table, @intCast(sel.header_col));
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
        const bw = dialogButtonWidth(&.{ show_l, hide_l, close_l });
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
    // temporarios (SQLite convertido do Access, CSVs do mdbtools): <TEMP>/mdb2sql-zig; os de um programa que caiu
    // sao apagados aqui
    const sys_tmp = init.environ_map.get("TEMP") orelse init.environ_map.get("TMP") orelse init.environ_map.get("TMPDIR") orelse
        (if (platform.is_windows) "." else "/tmp");
    const temp_dir = try std.fs.path.join(arena, &.{ sys_tmp, "mdb2sql-zig" });
    _ = access.cleanupStale(init.io, temp_dir);
    app.slot = .{ .db = &app.db, .gpa = init.gpa, .env = .{ .io = init.io, .access = .{
        .forced = init.environ_map.get("MDB2SQL_ACCESS_READER") orelse "",
        .tools_dir = try std.fs.path.join(arena, &.{ exe_dir, "mdbtools" }),
        .temp_dir = temp_dir,
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
        const save_end = if (init.environ_map.get("MDB2SQL_CAPTURE_SAVE")) |v| std.mem.eql(u8, v, "1") else false;
        capture = .{ .out_dir = o.out_dir, .fbo = try Fbo.load(), .save_end = save_end };
    }
    defer if (capture) |*c| {
        if (c.failed != null or c.wrong.items.len > 0) capture_failed = true;
        c.report(init.gpa, init.io);
    };

    while (!app.quit) {
        glfw.pollEvents();
        // fechar a janela passa pela pergunta do SQLite convertido (Cancelar mantem o programa aberto)
        if (window.shouldClose()) {
            window.setShouldClose(false);
            app.requestLeave(.exit);
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
