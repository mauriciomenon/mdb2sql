// GUI Dear ImGui (cimgui + GLFW + OpenGL3): abre .duckdb/.sqlite/.mdb/.accdb, lista tabelas, pagina dados,
// roda SQL e exporta (banco inteiro, tabela ou resultado) para DuckDB, SQLite, Excel e CSV
// !T: Same core flows as python_pyqt6 (load database -> pick table -> grid), plus paging, free SQL and exports

const std = @import("std");
const ig = @import("cimgui");
const glfw = @import("zglfw");
const dbm = @import("db");
const dialog = @import("dialog.zig");
const build_options = @import("build_options");
const query = dbm.query;
const worker = dbm.worker;
const settings = dbm.settings;
const ExportKind = worker.ExportKind;

const page_size = query.default_page_size;

// GL 1.1 basta para limpar a tela; o backend OpenGL3 do ImGui carrega o resto sozinho
extern "opengl32" fn glViewport(x: c_int, y: c_int, w: c_int, h: c_int) callconv(.winapi) void;
extern "opengl32" fn glClearColor(r: f32, g: f32, b: f32, a: f32) callconv(.winapi) void;
extern "opengl32" fn glClear(mask: c_uint) callconv(.winapi) void;

extern "user32" fn MessageBoxW(hwnd: ?*anyopaque, text: [*:0]const u16, caption: [*:0]const u16, kind: c_uint) callconv(.winapi) c_int;
extern "dwmapi" fn DwmSetWindowAttribute(hwnd: ?*anyopaque, attr: c_uint, value: *const c_int, size: c_uint) callconv(.winapi) c_long;
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
extern fn shim_add_font(path: [*:0]const u8, size_pixels: f32) void;
extern fn shim_clipper_range(clipper: *const ig.ImGuiListClipper, start: *c_int, end: *c_int) void;

extern "shell32" fn ShellExecuteW(hwnd: ?*anyopaque, op: [*:0]const u16, file: [*:0]const u16, params: ?[*:0]const u16, dir: ?[*:0]const u16, show: c_int) callconv(.winapi) ?*anyopaque;

const app_title = dbm.about.window_title; // "mdb2sql <versao> - Zig": janela e caixas de mensagem

// Abre no navegador padrao so os links fixos do Sobre (about.allowedLink); qualquer outro texto e ignorado
fn openLink(url: []const u8) void {
    const safe = dbm.about.allowedLink(url) orelse return;
    var wide: [128:0]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], safe) catch return;
    wide[n] = 0;
    _ = ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), &wide, null, null, 1); // SW_SHOWNORMAL
}

// Caixa de mensagem: o exe de release nao tem console, entao erro fatal e panico aparecem aqui
fn messageBox(text_utf8: []const u8, icon: c_uint) void {
    var wide: [2048:0]u16 = undefined;
    const n = std.unicode.wtf8ToWtf16Le(wide[0 .. wide.len - 1], text_utf8[0..@min(text_utf8.len, 1000)]) catch 0;
    wide[n] = 0;
    _ = MessageBoxW(null, &wide, std.unicode.utf8ToUtf16LeStringLiteral(app_title), icon);
}

// Panico (checagem de seguranca do ReleaseSafe): mostra a mensagem antes de encerrar, em vez de sumir calado
pub const panic = std.debug.FullPanic(panicBox);

fn panicBox(msg: []const u8, ret_addr: ?usize) noreturn {
    var buf: [1200]u8 = undefined;
    messageBox(std.fmt.bufPrint(&buf, "Internal error, the program will close:\n{s}", .{msg}) catch msg, 0x10);
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
    const dark_title: c_int = @intFromBool(!light);
    _ = DwmSetWindowAttribute(hwnd, 20, &dark_title, @sizeOf(c_int)); // DWMWA_USE_IMMERSIVE_DARK_MODE
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

// ------------------------------------------------------------------- texto

const Msg = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    is_err: bool = false,

    fn set(m: *Msg, is_err: bool, comptime fmt: []const u8, args: anytype) void {
        m.is_err = is_err;
        const s: []const u8 = std.fmt.bufPrint(&m.buf, fmt, args) catch &m.buf; // texto longo: trunca
        m.len = s.len;
    }

    fn draw(m: *const Msg) void {
        const red: [3]f32 = if (light_theme) .{ 0.70, 0.15, 0.12 } else .{ 1, 0.48, 0.45 };
        if (m.is_err) ig.igPushStyleColor_Vec4(ig.ImGuiCol_Text, .{ .x = red[0], .y = red[1], .z = red[2], .w = 1 });
        ig.igPushTextWrapPos(0);
        textSlice(m.buf[0..m.len]);
        ig.igPopTextWrapPos();
        if (m.is_err) ig.igPopStyleColor(1);
    }
};

fn textSlice(s: []const u8) void {
    ig.igTextUnformatted(s.ptr, s.ptr + s.len);
}

fn text(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    textSlice(std.fmt.bufPrint(&buf, fmt, args) catch &buf);
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

fn buttonWidth(label: [:0]const u8) f32 {
    return textWidth(label) + 2 * ig.igGetStyle().*.FramePadding.x;
}

// Proximo item na mesma linha se `width` ainda cabe ate a borda da janela; senao ele desce (nunca e cortado)
fn sameLineIfFits(width: f32, spacing: f32) void {
    const st = ig.igGetStyle();
    const gap = if (spacing < 0) st.*.ItemSpacing.x else spacing;
    const right = ig.igGetWindowPos().x + ig.igGetWindowWidth() - st.*.WindowPadding.x;
    if (ig.igGetItemRectMax().x + gap + width <= right) ig.igSameLine(0, spacing);
}

fn zstr(buf: anytype) [:0]u8 {
    return std.mem.sliceTo(buf, 0);
}

fn copyZ(dst: anytype, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

// ------------------------------------------------------------------- app

const Tab = enum { data, schema, sql };

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    db: dbm.Db,
    slot: worker.Slot, // consultas rodam fora da thread da UI; slot.db aponta para `db`
    busy_since: f64 = 0,
    hwnd: ?*anyopaque = null,
    status: Msg = .{},
    prefs: settings.Settings = .{},
    prefs_path: []const u8 = "",

    path: [1024:0]u8 = @splat(0),
    loaded_path: [1024:0]u8 = @splat(0), // arquivo aberto agora (pasta padrao dos dialogos de salvar)
    source: ?dbm.Source = null,
    counts: []u64 = &.{}, // linhas por tabela, mesma ordem de db.table_names
    table_filter: [128:0]u8 = @splat(0),
    filter_scratch: std.ArrayList(u8) = .empty, // nome de tabela em forma de busca (reaproveitado a cada quadro)

    selected: ?usize = null,
    schema: ?dbm.Grid = null,
    col_names: []const []const u8 = &.{}, // vive na arena de schema
    data: ?dbm.Grid = null,
    search: [256:0]u8 = @splat(0),
    sort_col: ?usize = null,
    sort_desc: bool = false,
    page: u64 = 0,
    total: u64 = 0,
    // busca e ordenacao que valem para a pagina na tela (a caixa de busca pode ter texto ainda nao aplicado)
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
    want_browse: bool = false,
    want_export: ?ExportKind = null, // abre o dialogo de salvar e dispara a exportacao
    want_theme: ?settings.Theme = null,
    want_about: bool = false,
    want_exit: bool = false,
    about_open: bool = false,
    focus_sql: bool = false,
    reveal_selected: bool = false, // rola a lista de tabelas ate a selecionada (ex.: --table)
    start_table: []const u8 = "", // --table: tabela inicial do proximo open
    start_sql: bool = false, // --sql: roda depois do primeiro open
    start_search: []const u8 = "", // --search: busca na aba Data depois do primeiro open
    start_cell: ?[2]usize = null, // --cell: linha e coluna (base 0) que abrem com o menu de copia
    start_menu: ?enum { File, Settings, Help, Export } = null, // --menu: menu aberto quando o banco termina de abrir (capturas)
    start_export: ?ExportKind = null, // --export: abre o dialogo de salvar dessa exportacao quando o banco abrir

    fn deinit(app: *App) void {
        // fechar com trabalho em andamento: pede para parar e espera a thread antes de soltar o banco
        // (uma exportacao interrompida apaga o arquivo .part)
        app.slot.cancel();
        if (app.slot.wait()) |o| {
            var out = o;
            out.deinit(app.gpa);
        }
        app.clearTable();
        app.clearResult();
        app.gpa.free(app.counts);
        app.filter_scratch.deinit(app.gpa);
        app.filters.deinit(app.gpa);
        app.db.close();
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
            error.DuckDb, error.Failed => msg.set(true, "{s}", .{app.db.lastError()}),
            error.Canceled => msg.set(true, "Canceled", .{}),
            error.UnsupportedExtension => msg.set(true, "Not a database file: use .duckdb, .db, .sqlite, .sqlite3, .mdb or .accdb", .{}),
            error.AccessDenied, error.FileBusy, error.PermissionDenied => msg.set(true, "Cannot write the file: it is open in another program or the folder is read-only ({t})", .{err}),
            else => msg.set(true, "Error: {t}", .{err}),
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
        switch (kind) {
            .open => {
                r.path = app.path;
                r.table_name = app.start_table;
                app.start_table = "";
            },
            .select => r.table = app.want_select orelse return,
            .reload => {
                r.table = app.selected orelse return;
                r.columns = app.col_names;
                r.search = app.search;
                r.filters = app.filters.items;
                r.sort_col = app.sort_col;
                r.sort_desc = app.sort_desc;
                r.page = app.page;
            },
            .sql => r.sql = app.sql,
            .export_ => {}, // preenchido em startExport
        }
        app.busy_since = ig.igGetTime();
        app.slot.start() catch |e| app.status.set(true, "Could not start the worker thread: {t}", .{e});
    }

    // Resultado de um trabalho, ja na thread da UI
    fn apply(app: *App, result: worker.Out) void {
        var out = result;
        defer out.deinit(app.gpa); // libera o que nao foi aproveitado abaixo
        switch (out.kind) {
            .open => {
                app.clearTable();
                app.clearResult();
                app.sql_msg.len = 0;
                app.want_select = null;
                app.want_reload = false;
                app.gpa.free(app.counts);
                app.counts = out.counts;
                out.counts = &.{};
                app.source = if (app.db.isOpen()) out.source else null;
                app.loaded_path = if (app.db.isOpen()) app.slot.req.path else @splat(0);
                if (app.db.isOpen()) {
                    app.status.set(false, "Loaded: {s} ({d} tables) - opened with {s}", .{
                        std.fs.path.basename(zstr(&app.slot.req.path)), app.db.table_names.len, app.source.?.label(),
                    });
                    app.rememberDir(zstr(&app.slot.req.path));
                    if (app.start_sql) {
                        app.want_run = true;
                        app.focus_sql = true;
                    }
                }
                app.start_sql = false;
                if (out.err == null) app.takeTable(&out);
            },
            .select => if (out.err == null) {
                app.clearTable();
                app.takeTable(&out);
            },
            .reload => if (out.err == null) {
                if (app.data) |*old| old.deinit();
                app.data = out.data;
                out.data = null;
                app.data_sel.row = null; // as colunas ocultas continuam valendo na mesma tabela
                app.total = out.total;
                app.page = out.page;
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
                        app.sql_msg.set(false, "More than {d} rows: showing the first {d} (export writes all of them)", .{ g.rows.len, g.rows.len })
                    else
                        app.sql_msg.set(false, "{d} rows, {d} columns", .{ g.rows.len, g.columns.len });
                }
            },
            .export_ => if (out.err == null) {
                const r = &app.slot.req;
                app.status.set(false, "Exported {d} {s} to {s}", .{
                    out.exported, if (r.export_kind.countsTables()) "tables" else "rows", std.fs.path.basename(r.destPath()),
                });
            },
        }
        if (out.err) |e| return app.fail(if (out.kind == .sql) &app.sql_msg else &app.status, e);

        // Estado inicial pedido na linha de comando (--search, --cell), quando os dados dele chegam
        if (out.kind == .open) {
            if (app.start_search.len > 0 and app.selected != null) {
                copyZ(&app.search, app.start_search);
                app.want_reload = true;
            }
            app.start_search = "";
        }
        if (app.start_cell) |cell| if (!app.want_run and !app.want_reload) {
            const sel = if (out.kind == .sql) &app.result_sel else &app.data_sel;
            sel.* = .{ .row = cell[0], .col = cell[1], .popup = true };
            app.start_cell = null;
        };
    }

    // Tabela recem-carregada (schema + primeira pagina): comeca sem busca nem ordenacao
    fn takeTable(app: *App, out: *worker.Out) void {
        app.selected = out.table orelse return;
        app.reveal_selected = true;
        app.schema = out.schema;
        app.col_names = out.columns;
        app.data = out.data;
        out.schema = null;
        out.data = null;
        app.total = out.total;
        app.page = out.page;
        app.search[0] = 0;
        app.applied_search[0] = 0;
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
        app.prefs.save(app.io, app.prefs_path) catch |e| app.status.set(true, "Could not save the settings: {t}", .{e});
    }

    fn update(app: *App) void {
        if (app.slot.poll()) |out| app.apply(out);

        if (app.want_theme) |theme| {
            app.prefs.theme = theme;
            applyTheme(settings.isLight(theme), app.hwnd);
            app.savePrefs();
        }
        app.want_theme = null;
        if (app.want_browse) {
            var buf: dialog.PathBuf = undefined;
            if (dialog.pick(.open_db, app.hwnd, app.prefs.lastDir(), &buf)) |p| {
                app.setPath(p);
                app.want_open = true;
            }
        }
        app.want_browse = false;

        if (app.slot.busy()) return; // um trabalho por vez; os pedidos abaixo ficam para depois
        if (app.want_filter != null or app.want_unfilter != null or app.want_clear_filters) {
            app.editFilters();
            app.page = 0;
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
        const dest = dialog.pick(dkind, app.hwnd, initial, &path_buf) orelse return;
        if (std.ascii.eqlIgnoreCase(dest, loaded)) return app.status.set(true, "Choose another file: this one is the database that is open", .{});
        app.rememberDir(dest);

        r.setDest(dest);
        r.total_hint = 0;
        if (kind == .table_csv or kind == .table_xlsx) {
            const index = app.selected orelse return;
            if (app.tab == .schema) {
                // o esquema exportado e o mesmo da aba: Column, Type, Null
                var sql: std.ArrayList(u8) = .initBuffer(&r.sql);
                sql.appendSliceAssumeCapacity("SELECT column_name AS \"Column\", column_type AS \"Type\", \"null\" AS \"Null\" FROM (DESCRIBE ");
                var tmp: std.ArrayList(u8) = .empty;
                defer tmp.deinit(app.gpa);
                query.writeIdent(&tmp, app.gpa, app.db.table_names[index]) catch return;
                if (tmp.items.len + 2 > sql.unusedCapacitySlice().len) return app.status.set(true, "Table name too long", .{});
                sql.appendSliceAssumeCapacity(tmp.items);
                sql.appendSliceAssumeCapacity(")");
                r.sql[sql.items.len] = 0;
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
        _ = ig.igBegin("MDB2SQL", null, ig.ImGuiWindowFlags_NoDecoration | ig.ImGuiWindowFlags_NoMove |
            ig.ImGuiWindowFlags_NoSavedSettings | ig.ImGuiWindowFlags_NoBringToFrontOnFocus);
        defer ig.igEnd();
        app.drawAbout();

        // Barra superior: caminho + Browse + Open + Export + status (tambem aceita arrastar o arquivo para a janela)
        ig.igSetNextItemWidth(ig.igGetContentRegionAvail().x * 0.40);
        const enter = ig.igInputTextWithHint("##path", "path to .duckdb / .sqlite / .accdb / .mdb (or drop the file here)", &app.path, app.path.len + 1, ig.ImGuiInputTextFlags_EnterReturnsTrue, null, null);
        ig.igSameLine(0, -1);
        if (button("Browse...")) app.want_browse = true;
        ig.igSameLine(0, -1);
        if (button("Open") or enter) app.want_open = true;
        ig.igSameLine(0, -1);
        ig.igBeginDisabled(app.opening() or !app.db.isOpen());
        if (button("Export...") or app.takeStartMenu(.Export)) _ = ig.igOpenPopup_Str("export_menu", 0);
        // o menu abre logo abaixo do botao (e nao onde o mouse estiver)
        const below_x = ig.igGetItemRectMin().x;
        const below_y = ig.igGetItemRectMax().y;
        ig.igEndDisabled();
        ig.igSetNextWindowPos(.{ .x = below_x, .y = below_y }, ig.ImGuiCond_Appearing, .{ .x = 0, .y = 0 });
        if (ig.igBeginPopup("export_menu", 0)) {
            defer ig.igEndPopup();
            app.exportItems();
        }
        ig.igSameLine(0, -1);
        app.drawStatus();
        ig.igSeparator();

        if (app.opening() or !app.db.isOpen()) return;

        if (ig.igBeginChild_Str("tables", .{ .x = 320, .y = 0 }, ig.ImGuiChildFlags_ResizeX | ig.ImGuiChildFlags_Borders, 0)) app.drawTables();
        ig.igEndChild();
        ig.igSameLine(0, -1);
        if (ig.igBeginChild_Str("content", .{ .x = 0, .y = 0 }, 0, 0)) app.drawContent();
        ig.igEndChild();
    }

    // Itens de exportacao (menu Arquivo > Exportar e botao Export...)
    fn exportItems(app: *App) void {
        const can_db = !app.opening() and app.db.isOpen();
        if (ig.igMenuItem_Bool("Database to DuckDB (.duckdb)...", null, false, can_db)) app.want_export = .db_duckdb;
        if (ig.igMenuItem_Bool("Database to SQLite (.sqlite)...", null, false, can_db)) app.want_export = .db_sqlite;
        if (ig.igMenuItem_Bool("Database to Excel (.xlsx, one sheet per table)...", null, false, can_db)) app.want_export = .db_xlsx;
        ig.igSeparator();
        const cur = app.canExportCurrent();
        const what: [:0]const u8 = switch (app.tab) {
            .data => "Current table",
            .schema => "Current table schema",
            .sql => "Current SQL result",
        };
        var b1: [96]u8 = undefined;
        var b2: [96]u8 = undefined;
        const l1 = std.fmt.bufPrintSentinel(&b1, "{s} to CSV...", .{what}, 0) catch "CSV...";
        const l2 = std.fmt.bufPrintSentinel(&b2, "{s} to Excel (.xlsx)...", .{what}, 0) catch "Excel...";
        if (ig.igMenuItem_Bool(l1, null, false, cur)) app.want_export = if (app.tab == .sql) .result_csv else .table_csv;
        if (ig.igMenuItem_Bool(l2, null, false, cur)) app.want_export = if (app.tab == .sql) .result_xlsx else .table_xlsx;
        ig.igSeparator();
        ig.igTextDisabled("Export to .mdb/.accdb: not available");
    }

    fn drawMenu(app: *App) void {
        if (!ig.igBeginMainMenuBar()) return;
        defer ig.igEndMainMenuBar();
        // --menu: abre o menu (e o submenu Exportar / Tema) no mesmo quadro, para as capturas de tela
        const open_file = app.takeStartMenu(.File);
        const open_settings = app.takeStartMenu(.Settings);
        if (open_file) _ = ig.igOpenPopup_Str("File", 0);
        if (open_settings) _ = ig.igOpenPopup_Str("Settings", 0);
        if (app.takeStartMenu(.Help)) _ = ig.igOpenPopup_Str("Help", 0);
        if (ig.igBeginMenu("File", true)) {
            defer ig.igEndMenu();
            if (ig.igMenuItem_Bool("Open...", "Ctrl+O", false, true)) app.want_browse = true;
            if (open_file) _ = ig.igOpenPopup_Str("Export", 0);
            if (ig.igBeginMenu("Export", !app.opening() and app.db.isOpen())) {
                defer ig.igEndMenu();
                app.exportItems();
            }
            ig.igSeparator();
            if (ig.igMenuItem_Bool("Exit", null, false, true)) app.want_exit = true;
        }
        if (ig.igBeginMenu("Settings", true)) {
            defer ig.igEndMenu();
            if (open_settings) _ = ig.igOpenPopup_Str("Theme", 0);
            if (ig.igBeginMenu("Theme", true)) {
                defer ig.igEndMenu();
                const cur = app.prefs.theme;
                if (ig.igMenuItem_Bool("System", null, cur == .system, true)) app.want_theme = .system;
                if (ig.igMenuItem_Bool("Light", null, cur == .light, true)) app.want_theme = .light;
                if (ig.igMenuItem_Bool("Dark", null, cur == .dark, true)) app.want_theme = .dark;
            }
        }
        if (ig.igBeginMenu("Help", true)) {
            defer ig.igEndMenu();
            if (ig.igMenuItem_Bool("About mdb2sql", null, false, true)) app.want_about = true;
        }
        if (ig.igIsKeyChordPressed_Nil(ig.ImGuiMod_Ctrl | ig.ImGuiKey_O)) app.want_browse = true;
    }

    // O menu de --menu, uma vez, so depois que o banco abriu e nada esta rodando
    fn takeStartMenu(app: *App, which: @typeInfo(@FieldType(App, "start_menu")).optional.child) bool {
        if (app.start_menu != which or app.slot.busy() or app.want_open or app.want_reload or app.want_run) return false;
        app.start_menu = null;
        return true;
    }

    fn drawAbout(app: *App) void {
        const title = "About mdb2sql";
        if (app.want_about) {
            _ = ig.igOpenPopup_Str(title, 0);
            app.about_open = true;
        }
        app.want_about = false;
        const vp = ig.igGetMainViewport();
        ig.igSetNextWindowPos(.{ .x = vp.*.Pos.x + vp.*.Size.x / 2, .y = vp.*.Pos.y + vp.*.Size.y / 2 }, ig.ImGuiCond_Appearing, .{ .x = 0.5, .y = 0.5 });
        if (!ig.igBeginPopupModal(title, &app.about_open, ig.ImGuiWindowFlags_AlwaysAutoResize | ig.ImGuiWindowFlags_NoSavedSettings)) return;
        defer ig.igEndPopup();
        const about = dbm.about;
        // nome e versao em destaque (mesma fonte, maior)
        ig.igPushFont(null, ig.igGetStyle().*.FontSizeBase * 1.4);
        textSlice(about.name ++ " " ++ about.version);
        ig.igPopFont();
        textSlice(about.tagline);
        ig.igSpacing();
        ig.igSeparator();
        ig.igSpacing();

        var glfw_ver: [3]c_int = undefined;
        glfwGetVersion(&glfw_ver[0], &glfw_ver[1], &glfw_ver[2]);
        var bufs: [4][96]u8 = undefined;
        const rows = [_]struct { [:0]const u8, []const u8 }{
            .{ "Build", about.build(&bufs[0]) },
            .{ "Stack", about.stackText(&bufs[1], std.mem.span(ig.igGetVersion())) },
            .{ "Window", std.fmt.bufPrint(&bufs[2], "GLFW {d}.{d}.{d} + OpenGL 3.3", .{ glfw_ver[0], glfw_ver[1], glfw_ver[2] }) catch "" },
            .{ "Database", std.fmt.bufPrint(&bufs[3], "DuckDB {s}", .{std.mem.trimStart(u8, dbm.libraryVersion(), "v")}) catch "" },
            .{ "Access reader", about.access_engine },
            .{ "Author", about.author },
            .{ "License", about.license },
        };
        if (ig.igBeginTable("about", 2, ig.ImGuiTableFlags_SizingFixedFit, .{ .x = 0, .y = 0 }, 0)) {
            defer ig.igEndTable();
            for (rows) |row| {
                ig.igTableNextRow(0, 0);
                _ = ig.igTableNextColumn();
                ig.igTextDisabled(row[0]);
                _ = ig.igTableNextColumn();
                textSlice(row[1]);
            }
            for (about.links) |link| {
                ig.igTableNextRow(0, 0);
                _ = ig.igTableNextColumn();
                ig.igTextDisabled(link.label);
                _ = ig.igTableNextColumn();
                if (ig.igTextLink(link.url)) openLink(link.url);
                ig.igSetItemTooltip("%s", "Open in the browser");
            }
        }
        ig.igSpacing();
        ig.igSeparator();
        ig.igSpacing();
        // Close a direita, do mesmo tamanho do Close do dialogo Columns
        ig.igSetCursorPosX(ig.igGetCursorPosX() + ig.igGetContentRegionAvail().x - 88);
        if (ig.igButton("Close", .{ .x = 88, .y = 0 })) ig.igCloseCurrentPopup();
    }

    // Status, ou o trabalho em andamento (com progresso e Cancelar) quando ele ja demora o bastante para ser notado
    fn drawStatus(app: *App) void {
        const elapsed = ig.igGetTime() - app.busy_since;
        if (app.slot.busy() and elapsed > 0.15) {
            const r = &app.slot.req;
            const done = app.slot.progress.done.load(.monotonic);
            const total = app.slot.progress.total.load(.monotonic);
            ig.igAlignTextToFramePadding();
            text("{s} {d:.1} s", .{ switch (r.kind) {
                .open => if (query.sourceKind(zstr(&r.path)) catch .duckdb == .access) "Converting the Access database..." else "Opening database...",
                .select, .reload => "Loading table...",
                .sql => "Running query...",
                .export_ => "Exporting...",
            }, elapsed });
            if (total > 0 and (r.kind == .open or r.kind == .export_)) {
                ig.igSameLine(0, -1);
                var buf: [64]u8 = undefined;
                const unit = if (r.kind == .open or r.export_kind.countsTables()) "tables" else "rows";
                const overlay = std.fmt.bufPrintSentinel(&buf, "{d} / {d} {s}", .{ done, total, unit }, 0) catch "";
                const frac: f32 = @floatCast(@as(f64, @floatFromInt(@min(done, total))) / @as(f64, @floatFromInt(total)));
                ig.igProgressBar(frac, .{ .x = 240, .y = 0 }, overlay);
            }
            ig.igSameLine(0, -1);
            if (button("Cancel")) app.slot.cancel();
        } else if (app.status.len == 0) ig.igTextDisabled("No database loaded") else app.status.draw();
    }

    fn drawTables(app: *App) void {
        ig.igSetNextItemWidth(-1);
        _ = ig.igInputTextWithHint("##filter", "all words, any order, ignores case and accents", &app.table_filter, app.table_filter.len + 1, 0, null, null);
        const flags = ig.ImGuiTableFlags_RowBg | ig.ImGuiTableFlags_ScrollY | ig.ImGuiTableFlags_BordersInnerV;
        if (!ig.igBeginTable("tbl", 2, flags, .{ .x = 0, .y = 0 }, 0)) return;
        defer ig.igEndTable();
        ig.igTableSetupScrollFreeze(0, 1);
        ig.igTableSetupColumn("Table", ig.ImGuiTableColumnFlags_WidthStretch, 0, 0);
        ig.igTableSetupColumn("Rows", ig.ImGuiTableColumnFlags_WidthFixed, 0, 0);
        ig.igTableHeadersRow();
        var fbuf: [app.table_filter.len]u8 = undefined;
        const words = dbm.gridtools.fold(&fbuf, zstr(&app.table_filter));
        for (app.db.table_names, 0..) |name, i| {
            const row = [_]?[]const u8{name};
            if (!(dbm.gridtools.rowMatches(app.gpa, &app.filter_scratch, &row, words) catch true)) continue;
            ig.igTableNextRow(0, 0);
            _ = ig.igTableNextColumn();
            ig.igPushID_Int(@intCast(i));
            // "##" + PushID: o rotulo fica vazio e o nome (que nao termina em 0) vai por textSlice
            if (ig.igSelectable_Bool("##t", app.selected == i, ig.ImGuiSelectableFlags_SpanAllColumns, .{ .x = 0, .y = 0 }))
                app.want_select = i;
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
            if (i < app.counts.len) text("{d}", .{app.counts[i]});
        }
    }

    fn drawContent(app: *App) void {
        if (!ig.igBeginTabBar("tabs", 0)) return;
        defer ig.igEndTabBar();

        if (ig.igBeginTabItem("Data", null, 0)) {
            defer ig.igEndTabItem();
            app.tab = .data;
            app.drawData();
        }
        if (ig.igBeginTabItem("Schema", null, 0)) {
            defer ig.igEndTabItem();
            app.tab = .schema;
            if (app.schema) |*g| _ = drawGrid("schema", g, null, &app.schema_sel, null, .plain);
        }
        if (ig.igBeginTabItem("SQL", null, if (app.focus_sql) ig.ImGuiTabItemFlags_SetSelected else 0)) {
            defer ig.igEndTabItem();
            app.tab = .sql;
            app.drawSql();
        }
        app.focus_sql = false;
    }

    fn drawData(app: *App) void {
        const index = app.selected orelse return ig.igTextDisabled("Select a table");
        const pages = query.pageCount(app.total, page_size);
        // ID por tabela: o ImGui guarda ordenacao e larguras por ID, e cada tabela tem as suas
        ig.igPushID_Int(@intCast(index));
        defer ig.igPopID();

        ig.igSetNextItemWidth(264);
        if (ig.igInputTextWithHint("##search", "all words, any order, ignores case and accents", &app.search, app.search.len + 1, ig.ImGuiInputTextFlags_EnterReturnsTrue, null, null)) {
            app.page = 0;
            app.want_reload = true;
        }
        ig.igSameLine(0, -1);
        ig.igBeginDisabled(app.page == 0);
        if (button("< Prev")) {
            app.page -|= 1;
            app.want_reload = true;
        }
        ig.igEndDisabled();
        ig.igSameLine(0, -1);
        ig.igBeginDisabled(app.page + 1 >= pages);
        if (button("Next >")) {
            app.page += 1;
            app.want_reload = true;
        }
        ig.igEndDisabled();
        // exportar a tabela fica so no Export... da barra de cima (um botao por acao)
        ig.igSameLine(0, -1);
        columnsButton(&app.data_sel);
        // contagem na linha de baixo: ao lado dos botoes ela ficava cortada na janela de 1280
        const first = app.page * page_size;
        const shown = if (app.data) |g| g.rows.len else 0;
        var hidden_buf: [48]u8 = undefined;
        ig.igAlignTextToFramePadding();
        // nome da tabela e contagem: quebra na borda da janela em vez de ser cortado
        ig.igPushTextWrapPos(0);
        text("{s}: page {d} of {d} | rows {d}-{d} of {d}{s}{s}", .{
            app.db.table_names[index],                     app.page + 1,  pages,
            if (shown == 0) 0 else first + 1,              first + shown, app.total,
            if (app.applied_search[0] != 0 or app.filters.items.len > 0) " (filtered)" else "",
            hiddenText(&hidden_buf, &app.data_sel, if (app.data) |g| g.columns.len else 0),
        });
        ig.igPopTextWrapPos();

        // Filtros ativos: um botao por filtro (clicar remove) e Clear filters; o que nao cabe desce de linha
        for (app.filters.items, 0..) |f, i| {
            var label: [200]u8 = undefined;
            const chip = dbm.gridtools.filterLabel(&label, f);
            if (i == 0) {
                sameLineIfFits(textWidth("Filters:") + ig.igGetStyle().*.ItemSpacing.x + buttonWidth(chip), 24);
                ig.igTextDisabled("Filters:");
            }
            sameLineIfFits(buttonWidth(chip), -1);
            ig.igPushID_Int(@intCast(i));
            if (button(chip)) app.want_unfilter = i;
            ig.igSetItemTooltip("%s", "Remove this filter");
            ig.igPopID();
        }
        if (app.filters.items.len > 0) {
            sameLineIfFits(buttonWidth("Clear filters"), -1);
            if (button("Clear filters")) app.want_clear_filters = true;
        }

        app.data_sel.has_filters = app.filters.items.len > 0;
        if (app.data) |*g| if (drawGrid("data", g, .{ .col = app.sort_col, .desc = app.sort_desc }, &app.data_sel, null, .filter)) |s| {
            app.sort_col = s.col;
            app.sort_desc = s.desc;
            app.page = 0;
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
        if (button("Run (Ctrl+Enter)") or enter) app.want_run = true;
        ig.igEndDisabled();
        ig.igSameLine(0, -1);
        if (running) ig.igTextDisabled("Running...") else if (app.sql_msg.len == 0) ig.igTextDisabled("the open file is read-only") else app.sql_msg.draw();
        const g = if (app.result) |*x| x else return;
        ig.igSetNextItemWidth(400);
        if (ig.igInputTextWithHint("##rfilter", "search the rows shown: all words, any order, ignores case and accents", &app.result_filter, app.result_filter.len + 1, 0, null, null)) app.refilter();
        ig.igSameLine(0, -1);
        columnsButton(&app.result_sel);
        var hidden_buf: [48]u8 = undefined;
        const hidden = hiddenText(&hidden_buf, &app.result_sel, g.columns.len);
        if (app.result_rows) |rows| {
            ig.igSameLine(0, -1);
            text("{d} of {d} rows match{s}", .{ rows.len, g.rows.len, hidden });
        } else if (hidden.len > 0) {
            ig.igSameLine(0, -1);
            textSlice(hidden[3..]); // sem o " | " do comeco
        }
        _ = drawGrid("result", g, null, &app.result_sel, app.result_rows, .hide);
    }
};

// Botao "Columns..." da barra da grade: o dialogo e desenhado por drawGrid
fn columnsButton(sel: *GridSel) void {
    if (button("Columns...")) sel.open_columns = true;
    ig.igSetItemTooltip("%s", "Show or hide several columns at once.\nHidden columns are still searched, and exports still write every column.");
}

// " | 3 columns hidden" ou vazio
fn hiddenText(buf: []u8, sel: *const GridSel, n_cols: usize) []const u8 {
    const n = sel.hiddenCount(n_cols);
    if (n == 0) return "";
    return std.fmt.bufPrint(buf, " | {d} column{s} hidden", .{ n, if (n == 1) "" else "s" }) catch "";
}

const Sort = struct { col: ?usize, desc: bool };

// Celula selecionada de uma grade (indices da linha em Grid.rows e da coluna)
const GridSel = struct {
    row: ?usize = null,
    col: usize = 0,
    popup: bool = false, // abrir o menu da celula ao lado dela (estado inicial --cell)
    // Colunas ocultas desta grade (indice da coluna). Valem ate trocar de tabela/resultado ou "Show all";
    // so mudam o que e desenhado: busca e exportacao continuam com todas as colunas.
    hidden: std.StaticBitSet(max_grid_cols) = .empty,
    header_col: usize = 0, // coluna do menu do cabecalho
    open_columns: bool = false, // abrir o dialogo "Columns"
    col_filter: [64:0]u8 = @splat(0), // busca por nome dentro do dialogo
    has_filters: bool = false, // habilita "Clear filters" no menu da celula
    want_filter: bool = false, // menu da celula: filtrar pelo valor da celula selecionada
    want_clear: bool = false, // menu da celula: limpar filtros

    fn hiddenCount(sel: *const GridSel, n_cols: usize) usize {
        var n: usize = 0;
        for (0..@min(n_cols, max_grid_cols)) |c| n += @intFromBool(sel.hidden.isSet(c));
        return n;
    }
};

// shortcut: ImGui tables hold at most 512 columns, wider results are cut at 512
const max_grid_cols = 512;

// plain: so copia; hide: tambem ocultar colunas; filter: tambem "Filter by this value" (aba Data)
const GridMode = enum { plain, hide, filter };

var copy_header = false; // "Copy row" tambem copia a linha de nomes das colunas

// Poe na area de transferencia o valor da celula selecionada ou a linha dela separada por TAB
fn copySelection(g: *const dbm.Grid, sel: *const GridSel, whole_row: bool) void {
    const r = sel.row orelse return;
    if (r >= g.rows.len or sel.col >= g.columns.len) return;
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();
    const w = &out.writer;
    (if (whole_row) dbm.gridtools.writeRow(w, g.columns, g.rows[r], copy_header) else w.writeAll(g.rows[r][sel.col] orelse "")) catch return;
    w.writeByte(0) catch return;
    ig.igSetClipboardText(out.written().ptr);
}

// Desenha um Grid; com `sort` os cabecalhos ordenam e a nova ordenacao pedida e devolvida.
// `rows` limita e ordena as linhas mostradas (filtro); null = todas.
// Clique seleciona a celula; Ctrl+C copia o valor; o clique direito abre o menu da celula (copiar, filtrar).
// Com `mode` != .plain o clique direito no cabecalho oculta colunas e abre o popup "Columns...".
fn drawGrid(id: [*:0]const u8, g: *const dbm.Grid, sort: ?Sort, sel: *GridSel, rows: ?[]const usize, mode: GridMode) ?Sort {
    const n_cols: usize = @min(g.columns.len, max_grid_cols);
    if (n_cols == 0) return null;
    const can_hide = mode != .plain;
    var flags: c_int = ig.ImGuiTableFlags_Borders | ig.ImGuiTableFlags_RowBg | ig.ImGuiTableFlags_Resizable |
        ig.ImGuiTableFlags_ScrollX | ig.ImGuiTableFlags_ScrollY | ig.ImGuiTableFlags_SizingFixedFit;
    if (sort != null) flags |= ig.ImGuiTableFlags_Sortable | ig.ImGuiTableFlags_SortTristate;
    if (can_hide) flags |= ig.ImGuiTableFlags_Hideable;
    if (!ig.igBeginTable(id, @intCast(n_cols), flags, .{ .x = 0, .y = 0 }, 0)) return null;
    defer ig.igEndTable();

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
            ig.igTableHeader(name.ptr);
            ig.igPopID();
            // a largura inicial ja inclui o cabecalho (auto-fit do ImGui); estreitada a mao, o nome vai no tooltip
            if (ig.igIsItemHovered(0) and textWidth(name) > avail) tooltip(name);
            if (ig.igIsMouseReleased_Nil(1) and ig.igIsItemHovered(0)) {
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
                if (ig.igSelectable_Bool("##cell", selected, 0, .{ .x = 0, .y = 0 })) sel.* = .{ .row = r, .col = c };
                if (ig.igIsItemHovered(0) and ig.igIsMouseClicked_Bool(1, false)) {
                    sel.* = .{ .row = r, .col = c };
                    open_menu = true;
                }
                if (selected and sel.popup) {
                    sel.popup = false;
                    open_menu = true;
                    const max = ig.igGetItemRectMax();
                    ig.igSetNextWindowPos(.{ .x = ig.igGetItemRectMin().x + 24, .y = max.y }, ig.ImGuiCond_Always, .{ .x = 0, .y = 0 });
                }
                ig.igPopID();
                ig.igSameLine(0, 0);
                if (cell) |s| textSlice(s) else ig.igTextDisabled("NULL");
            }
        }
    }

    if (ig.igIsWindowFocused(0) and ig.igIsKeyChordPressed_Nil(ig.ImGuiMod_Ctrl | ig.ImGuiKey_C)) copySelection(g, sel, false);
    if (open_menu) _ = ig.igOpenPopup_Str("copy", 0);
    if (ig.igBeginPopup("copy", 0)) {
        defer ig.igEndPopup();
        if (mode == .filter) {
            if (ig.igMenuItem_Bool("Filter by this value", null, false, true)) sel.want_filter = true;
            if (ig.igMenuItem_Bool("Clear filters", null, false, sel.has_filters)) sel.want_clear = true;
            ig.igSeparator();
        }
        if (ig.igMenuItem_Bool("Copy value", "Ctrl+C", false, true)) copySelection(g, sel, false);
        if (ig.igMenuItem_Bool("Copy row (TAB separated)", null, false, true)) copySelection(g, sel, true);
        ig.igSeparator();
        _ = ig.igCheckbox("Copy row includes the header", &copy_header);
    }
    if (!can_hide) return changed;

    // Cabecalho: este menu abre depois do menu padrao do ImGui (TableHeader) no mesmo quadro e toma o lugar dele
    if (open_header) _ = ig.igOpenPopup_Str("header", 0);
    if (ig.igBeginPopup("header", 0)) {
        defer ig.igEndPopup();
        if (ig.igMenuItem_Bool("Hide this column", null, false, true)) sel.hidden.set(sel.header_col);
        if (ig.igMenuItem_Bool("Columns...", null, false, true)) sel.open_columns = true;
        if (ig.igMenuItem_Bool("Show all", null, false, sel.hiddenCount(n_cols) > 0)) sel.hidden = .empty;
    }

    // "Columns": dialogo no centro da janela, uma caixa por coluna; marcar e desmarcar varias e fechar
    const dialog_title = "Columns";
    if (sel.open_columns) {
        sel.open_columns = false;
        sel.col_filter[0] = 0;
        _ = ig.igOpenPopup_Str(dialog_title, 0);
    }
    const vp = ig.igGetMainViewport();
    ig.igSetNextWindowPos(.{ .x = vp.*.Pos.x + vp.*.Size.x / 2, .y = vp.*.Pos.y + vp.*.Size.y / 2 }, ig.ImGuiCond_Appearing, .{ .x = 0.5, .y = 0.5 });
    var dialog_open = true;
    if (ig.igBeginPopupModal(dialog_title, &dialog_open, ig.ImGuiWindowFlags_AlwaysAutoResize | ig.ImGuiWindowFlags_NoSavedSettings)) {
        defer ig.igEndPopup();
        const width = 360;
        ig.igSetNextItemWidth(width);
        _ = ig.igInputTextWithHint("##colfilter", "find a column", &sel.col_filter, sel.col_filter.len + 1, 0, null, null);
        const needle = zstr(&sel.col_filter);
        const line = ig.igGetFrameHeightWithSpacing();
        if (ig.igBeginChild_Str("list", .{ .x = width, .y = line * 12 }, ig.ImGuiChildFlags_Borders, 0)) {
            for (g.columns[0..n_cols], 0..) |name, c| {
                if (needle.len > 0 and std.ascii.findIgnoreCase(name, needle) == null) continue;
                var shown = !sel.hidden.isSet(c);
                ig.igPushID_Int(@intCast(c));
                if (ig.igCheckbox(name.ptr, &shown)) sel.hidden.setValue(c, !shown);
                ig.igPopID();
            }
        }
        ig.igEndChild();
        ig.igAlignTextToFramePadding();
        text("{d} of {d} shown", .{ n_cols - sel.hiddenCount(n_cols), n_cols });
        ig.igSameLine(width - 2 * 88 - ig.igGetStyle().*.ItemSpacing.x + ig.igGetStyle().*.WindowPadding.x, -1);
        if (ig.igButton("Show all", .{ .x = 88, .y = 0 })) sel.hidden = .empty;
        ig.igSameLine(0, -1);
        if (ig.igButton("Hide all", .{ .x = 88, .y = 0 })) sel.hidden.setRangeValue(.{ .start = 0, .end = n_cols }, true);
        ig.igPushTextWrapPos(ig.igGetCursorPosX() + width);
        ig.igTextDisabled("%s", "Hidden columns are still searched and exported.");
        ig.igPopTextWrapPos();
        ig.igSeparator();
        ig.igSetCursorPosX(ig.igGetCursorPosX() + width - 88);
        if (ig.igButton("Close", .{ .x = 88, .y = 0 })) ig.igCloseCurrentPopup();
    }
    return changed;
}

var dropped: [1024:0]u8 = @splat(0); // caminho solto na janela (callback do GLFW)

fn onDrop(_: *glfw.Window, count: i32, paths: [*][*:0]const u8) callconv(.c) void {
    if (count < 1) return;
    copyZ(&dropped, std.mem.span(paths[0]));
}

const usage =
    \\usage: mdb2sql-zig [file.duckdb|.db|.sqlite|.sqlite3|.mdb|.accdb] [--table NAME] [--sql "SELECT ..."]
    \\                   [--search TEXT] [--cell ROW,COL] [--theme system|dark|light] [--about] [--menu NAME] [--export KIND]
    \\  no file argument: uses the MDB2SQL_DB_PATH environment variable, if set
    \\  MDB2SQL_ACCESS_READER=odbc|mdbtools forces the reader of .mdb/.accdb files
    \\  the flags set the start state: selected table, SQL to run, search text of
    \\  the Data tab, grid cell selected with its copy menu open, colors (this run only),
    \\  About open, a menu open (File, Settings, Help, Export)
    \\  --export db_duckdb|db_sqlite|db_xlsx|table_csv|table_xlsx|result_csv|result_xlsx
    \\  opens the save dialog of that export when the file is loaded
    \\
;

fn showUsage() void {
    std.debug.print("{s}", .{usage});
    if (!build_options.console) messageBox(usage, 0x40); // MB_ICONINFORMATION
}

pub fn main(init: std.process.Init) void {
    run(init) catch |e| {
        // sem console no release: o motivo aparece numa caixa, nao some calado
        var buf: [512]u8 = undefined;
        const hint = if (e == error.APIUnavailable or e == error.VersionUnavailable or e == error.PlatformError)
            "\nThe graphics driver must support OpenGL 3.3 (on a remote desktop or a VM without 3D, use the computer itself)."
        else
            "";
        messageBox(std.fmt.bufPrint(&buf, "MDB2SQL could not start: {t}{s}", .{ e, hint }) catch "MDB2SQL could not start", 0x10);
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    var app: App = .{ .gpa = init.gpa, .io = init.io, .db = .init(init.gpa), .slot = undefined };
    const arena = init.arena.allocator();

    // Arquivos que vem junto do programa (pasta do exe): extensao sqlite e mdbtools\
    const exe_dir = std.process.executableDirPathAlloc(init.io, arena) catch "";
    const sqlite_ext = try std.fs.path.join(arena, &.{ exe_dir, "sqlite_scanner.duckdb_extension" });
    if (std.Io.Dir.cwd().access(init.io, sqlite_ext, .{})) |_| app.db.sqlite_ext = sqlite_ext else |_| {}
    app.slot = .{ .db = &app.db, .gpa = init.gpa, .env = .{ .io = init.io, .access = .{
        .forced = init.environ_map.get("MDB2SQL_ACCESS_READER") orelse "",
        .tools_dir = try std.fs.path.join(arena, &.{ exe_dir, "mdbtools" }),
        .temp_dir = init.environ_map.get("TEMP") orelse init.environ_map.get("TMP") orelse ".",
    } } };
    defer app.deinit();
    // a instancia DuckDB do programa nasce aqui, na thread da UI (ver db.zig)
    try app.db.start();

    if (init.environ_map.get("APPDATA")) |appdata| {
        app.prefs_path = try std.fs.path.join(arena, &.{ appdata, "mdb2sql", "zig-imgui.ini" });
        app.prefs = settings.Settings.load(init.io, app.prefs_path);
    }

    // Argumentos: caminho do banco e estado inicial opcional
    const args = try init.minimal.args.toSlice(arena);
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
            } else if (std.mem.eql(u8, arg, "--export")) {
                app.start_export = std.meta.stringToEnum(ExportKind, value) orelse return showUsage();
            } else if (std.mem.eql(u8, arg, "--menu")) {
                app.start_menu = std.meta.stringToEnum(@typeInfo(@FieldType(App, "start_menu")).optional.child, value) orelse return showUsage();
            } else return showUsage();
        }
    }
    if (app.path[0] == 0) if (init.environ_map.get("MDB2SQL_DB_PATH")) |p| app.setPath(p);
    app.want_open = app.path[0] != 0;
    app.start_sql = app.want_open and app.sql[0] != 0;

    try glfw.init();
    defer glfw.terminate();
    glfw.windowHint(.context_version_major, 3);
    glfw.windowHint(.context_version_minor, 3);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    const window = try glfw.Window.create(1280, 800, app_title, null, null);
    defer window.destroy();
    glfw.makeContextCurrent(window);
    glfw.swapInterval(1);
    _ = glfw.setDropCallback(window, onDrop);
    app.hwnd = @ptrCast(glfw.getWin32Window(window));

    _ = ig.igCreateContext(null);
    defer ig.igDestroyContext(null);
    shim_io_setup();
    const scale = window.getContentScale()[0];
    setupSizes(scale);
    applyTheme(settings.isLight(theme), app.hwnd);
    // Segoe UI quando existe (acentos legiveis); senao fica a fonte embutida do ImGui.
    // 16 px (1.1.1 usava 17): um pouco menor a pedido do dono; titulos seguem proporcionais (FontSizeBase)
    const font = "C:\\Windows\\Fonts\\segoeui.ttf";
    if (std.Io.Dir.cwd().access(init.io, font, .{})) |_| {
        shim_add_font(font, 16 * scale);
    } else |_| ig.igGetStyle().*.FontScaleDpi = scale;

    if (!ImGui_ImplGlfw_InitForOpenGL(window, true)) return error.PlatformError;
    defer ImGui_ImplGlfw_Shutdown();
    if (!ImGui_ImplOpenGL3_Init("#version 330")) return error.APIUnavailable;
    defer ImGui_ImplOpenGL3_Shutdown();

    while (!window.shouldClose() and !app.want_exit) {
        glfw.pollEvents();
        if (dropped[0] != 0) {
            app.setPath(zstr(&dropped));
            dropped[0] = 0;
            app.want_open = true;
        }
        app.update();

        ImGui_ImplOpenGL3_NewFrame();
        ImGui_ImplGlfw_NewFrame();
        ig.igNewFrame();
        app.draw();
        ig.igRender();

        const fb = window.getFramebufferSize();
        glViewport(0, 0, fb[0], fb[1]);
        glClearColor(0.1, 0.1, 0.1, 1);
        glClear(0x4000); // GL_COLOR_BUFFER_BIT
        ImGui_ImplOpenGL3_RenderDrawData(ig.igGetDrawData());
        window.swapBuffers();
    }
}
