// GUI Dear ImGui (cimgui + GLFW + OpenGL3): abre .duckdb, lista tabelas, pagina dados, roda SQL
// !T: Same core flows as py_qt6 (load database -> pick table -> grid), plus paging and free SQL

const std = @import("std");
const ig = @import("cimgui");
const glfw = @import("zglfw");
const dbm = @import("db");
const query = dbm.query;

const page_size = query.default_page_size;

// GL 1.1 basta para limpar a tela; o backend OpenGL3 do ImGui carrega o resto sozinho
extern "opengl32" fn glViewport(x: c_int, y: c_int, w: c_int, h: c_int) callconv(.winapi) void;
extern "opengl32" fn glClearColor(r: f32, g: f32, b: f32, a: f32) callconv(.winapi) void;
extern "opengl32" fn glClear(mask: c_uint) callconv(.winapi) void;

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
        if (m.is_err) ig.igPushStyleColor_Vec4(ig.ImGuiCol_Text, .{ .x = 1, .y = 0.4, .z = 0.4, .w = 1 });
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

fn zstr(buf: anytype) [:0]u8 {
    return std.mem.sliceTo(buf, 0);
}

const App = struct {
    gpa: std.mem.Allocator,
    db: dbm.Db,
    status: Msg = .{},

    path: [1024:0]u8 = @splat(0),
    counts: []u64 = &.{}, // linhas por tabela, mesma ordem de db.table_names
    table_filter: [128:0]u8 = @splat(0),

    selected: ?usize = null,
    schema: ?dbm.Grid = null,
    col_names: []const []const u8 = &.{}, // vive na arena de schema
    data: ?dbm.Grid = null,
    search: [256:0]u8 = @splat(0),
    sort_col: ?usize = null,
    sort_desc: bool = false,
    page: u64 = 0,
    total: u64 = 0,

    sql: [8192:0]u8 = @splat(0),
    result: ?dbm.Grid = null,
    sql_msg: Msg = .{},

    // Acoes pedidas pela UI, executadas no inicio do proximo quadro (nunca no meio do desenho)
    want_open: bool = false,
    want_select: ?usize = null,
    want_reload: bool = false,
    want_run: bool = false,
    focus_sql: bool = false,

    fn deinit(app: *App) void {
        app.clearTable();
        if (app.result) |*g| g.deinit();
        app.gpa.free(app.counts);
        app.db.close();
    }

    fn clearTable(app: *App) void {
        if (app.data) |*g| g.deinit();
        if (app.schema) |*g| g.deinit();
        app.data = null;
        app.schema = null;
        app.col_names = &.{};
        app.selected = null;
    }

    fn fail(app: *App, msg: *Msg, err: dbm.Error) void {
        if (err == error.DuckDb) msg.set(true, "{s}", .{app.db.lastError()}) else msg.set(true, "Error: {t}", .{err});
    }

    fn setPath(app: *App, p: []const u8) void {
        const n = @min(p.len, app.path.len);
        @memcpy(app.path[0..n], p[0..n]);
        app.path[n] = 0;
    }

    fn open(app: *App) void {
        app.clearTable();
        if (app.result) |*g| g.deinit();
        app.result = null;
        const path = zstr(&app.path);
        app.db.openReadOnly(path) catch |e| return app.fail(&app.status, e);

        const names = app.db.table_names;
        app.gpa.free(app.counts);
        app.counts = app.gpa.alloc(u64, names.len) catch &.{};
        // shortcut: COUNT(*) per table runs on the UI thread at open (287 tables ~ instant);
        // move to a worker thread like py_qt6 if a database makes this noticeable
        for (app.counts, names) |*n, name|
            n.* = app.db.count(.{ .table = name, .tables = names, .columns = &.{} }) catch 0;
        app.status.set(false, "Loaded: {s} ({d} tables)", .{ std.fs.path.basename(path), names.len });
        if (names.len > 0) app.select(0);
    }

    fn select(app: *App, index: usize) void {
        app.clearTable();
        if (index >= app.db.table_names.len) return;
        var sch = app.db.schema(app.db.table_names[index]) catch |e| return app.fail(&app.status, e);
        const names = sch.arena.allocator().alloc([]const u8, sch.rows.len) catch {
            sch.deinit();
            return app.fail(&app.status, error.OutOfMemory);
        };
        for (names, sch.rows) |*n, row| n.* = row[0].?;
        app.schema = sch;
        app.col_names = names;
        app.selected = index;
        app.search[0] = 0;
        app.sort_col = null;
        app.page = 0;
        app.reload();
    }

    fn reload(app: *App) void {
        const index = app.selected orelse return;
        var spec: query.Spec = .{
            .table = app.db.table_names[index],
            .tables = app.db.table_names,
            .columns = app.col_names,
            .search = zstr(&app.search),
            .sort_column = if (app.sort_col) |c| app.col_names[c] else null,
            .sort_desc = app.sort_desc,
        };
        app.total = app.db.count(spec) catch |e| return app.fail(&app.status, e);
        app.page = query.clampPage(app.page, app.total, page_size);
        spec.offset = app.page * page_size;
        const g = app.db.page(spec) catch |e| return app.fail(&app.status, e);
        if (app.data) |*old| old.deinit();
        app.data = g;
    }

    fn runSql(app: *App) void {
        if (app.result) |*g| g.deinit();
        app.result = null;
        const g = app.db.run(zstr(&app.sql), &.{}) catch |e| return app.fail(&app.sql_msg, e);
        app.result = g;
        if (g.total_rows > g.rows.len)
            app.sql_msg.set(false, "{d} rows (showing the first {d})", .{ g.total_rows, g.rows.len })
        else
            app.sql_msg.set(false, "{d} rows, {d} columns", .{ g.total_rows, g.columns.len });
    }

    fn update(app: *App) void {
        if (app.want_open) app.open();
        if (app.want_select) |i| app.select(i);
        if (app.want_reload) app.reload();
        if (app.want_run) app.runSql();
        app.want_open = false;
        app.want_select = null;
        app.want_reload = false;
        app.want_run = false;
    }

    fn draw(app: *App) void {
        const vp = ig.igGetMainViewport();
        ig.igSetNextWindowPos(vp.*.WorkPos, ig.ImGuiCond_Always, .{ .x = 0, .y = 0 });
        ig.igSetNextWindowSize(vp.*.WorkSize, ig.ImGuiCond_Always);
        _ = ig.igBegin("MDB2SQL", null, ig.ImGuiWindowFlags_NoDecoration | ig.ImGuiWindowFlags_NoMove |
            ig.ImGuiWindowFlags_NoSavedSettings | ig.ImGuiWindowFlags_NoBringToFrontOnFocus);
        defer ig.igEnd();

        // Barra superior: caminho + Open + status (tambem aceita arrastar o arquivo para a janela)
        ig.igSetNextItemWidth(ig.igGetContentRegionAvail().x * 0.5);
        const enter = ig.igInputTextWithHint("##path", "path to .duckdb / .db (or drop the file here)", &app.path, app.path.len + 1, ig.ImGuiInputTextFlags_EnterReturnsTrue, null, null);
        ig.igSameLine(0, -1);
        if (ig.igButton("Open", .{ .x = 0, .y = 0 }) or enter) app.want_open = true;
        ig.igSameLine(0, -1);
        if (app.status.len == 0) ig.igTextDisabled("No database loaded") else app.status.draw();
        ig.igSeparator();

        if (!app.db.isOpen()) return;

        if (ig.igBeginChild_Str("tables", .{ .x = 320, .y = 0 }, ig.ImGuiChildFlags_ResizeX | ig.ImGuiChildFlags_Borders, 0)) app.drawTables();
        ig.igEndChild();
        ig.igSameLine(0, -1);
        if (ig.igBeginChild_Str("content", .{ .x = 0, .y = 0 }, 0, 0)) app.drawContent();
        ig.igEndChild();
    }

    fn drawTables(app: *App) void {
        ig.igSetNextItemWidth(-1);
        _ = ig.igInputTextWithHint("##filter", "filter tables", &app.table_filter, app.table_filter.len + 1, 0, null, null);
        const flags = ig.ImGuiTableFlags_RowBg | ig.ImGuiTableFlags_ScrollY | ig.ImGuiTableFlags_BordersInnerV;
        if (!ig.igBeginTable("tbl", 2, flags, .{ .x = 0, .y = 0 }, 0)) return;
        defer ig.igEndTable();
        ig.igTableSetupScrollFreeze(0, 1);
        ig.igTableSetupColumn("Table", ig.ImGuiTableColumnFlags_WidthStretch, 0, 0);
        ig.igTableSetupColumn("Rows", ig.ImGuiTableColumnFlags_WidthFixed, 0, 0);
        ig.igTableHeadersRow();
        const filter = zstr(&app.table_filter);
        for (app.db.table_names, 0..) |name, i| {
            if (filter.len > 0 and std.ascii.findIgnoreCase(name, filter) == null) continue;
            ig.igTableNextRow(0, 0);
            _ = ig.igTableNextColumn();
            ig.igPushID_Int(@intCast(i));
            // "##" + PushID: o rotulo fica vazio e o nome (que nao termina em 0) vai por textSlice
            if (ig.igSelectable_Bool("##t", app.selected == i, ig.ImGuiSelectableFlags_SpanAllColumns, .{ .x = 0, .y = 0 }))
                app.want_select = i;
            ig.igPopID();
            ig.igSameLine(0, 0);
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
            app.drawData();
        }
        if (ig.igBeginTabItem("Schema", null, 0)) {
            defer ig.igEndTabItem();
            if (app.schema) |*g| _ = drawGrid("schema", g, null);
        }
        if (ig.igBeginTabItem("SQL", null, if (app.focus_sql) ig.ImGuiTabItemFlags_SetSelected else 0)) {
            defer ig.igEndTabItem();
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

        ig.igSetNextItemWidth(260);
        if (ig.igInputTextWithHint("##search", "search all columns (Enter)", &app.search, app.search.len + 1, ig.ImGuiInputTextFlags_EnterReturnsTrue, null, null)) {
            app.page = 0;
            app.want_reload = true;
        }
        ig.igSameLine(0, -1);
        ig.igBeginDisabled(app.page == 0);
        if (ig.igButton("< Prev", .{ .x = 0, .y = 0 })) {
            app.page -= 1;
            app.want_reload = true;
        }
        ig.igEndDisabled();
        ig.igSameLine(0, -1);
        ig.igBeginDisabled(app.page + 1 >= pages);
        if (ig.igButton("Next >", .{ .x = 0, .y = 0 })) {
            app.page += 1;
            app.want_reload = true;
        }
        ig.igEndDisabled();
        ig.igSameLine(0, -1);
        const first = app.page * page_size;
        const shown = if (app.data) |g| g.rows.len else 0;
        text("{s}: page {d} of {d} | rows {d}-{d} of {d}{s}", .{
            app.db.table_names[index],                     app.page + 1,  pages,
            if (shown == 0) 0 else first + 1,              first + shown, app.total,
            if (app.search[0] != 0) " (filtered)" else "",
        });

        if (app.data) |*g| if (drawGrid("data", g, .{ .col = app.sort_col, .desc = app.sort_desc })) |s| {
            app.sort_col = s.col;
            app.sort_desc = s.desc;
            app.page = 0;
            app.want_reload = true;
        };
    }

    fn drawSql(app: *App) void {
        const run = ig.igInputTextMultiline("##sql", &app.sql, app.sql.len + 1, .{ .x = -1, .y = ig.igGetTextLineHeight() * 7 }, ig.ImGuiInputTextFlags_EnterReturnsTrue, null, null);
        if (ig.igButton("Run (Ctrl+Enter)", .{ .x = 0, .y = 0 }) or run) app.want_run = true;
        ig.igSameLine(0, -1);
        if (app.sql_msg.len == 0) ig.igTextDisabled("read-only connection") else app.sql_msg.draw();
        if (app.result) |*g| _ = drawGrid("result", g, null);
    }
};

const Sort = struct { col: ?usize, desc: bool };

// Desenha um Grid; com `sort` os cabecalhos ordenam e a nova ordenacao pedida e devolvida
fn drawGrid(id: [*:0]const u8, g: *const dbm.Grid, sort: ?Sort) ?Sort {
    // shortcut: ImGui tables hold at most 512 columns, wider results are cut at 512
    const n_cols: usize = @min(g.columns.len, 512);
    if (n_cols == 0) return null;
    var flags: c_int = ig.ImGuiTableFlags_Borders | ig.ImGuiTableFlags_RowBg | ig.ImGuiTableFlags_Resizable |
        ig.ImGuiTableFlags_ScrollX | ig.ImGuiTableFlags_ScrollY | ig.ImGuiTableFlags_SizingFixedFit;
    if (sort != null) flags |= ig.ImGuiTableFlags_Sortable | ig.ImGuiTableFlags_SortTristate;
    if (!ig.igBeginTable(id, @intCast(n_cols), flags, .{ .x = 0, .y = 0 }, 0)) return null;
    defer ig.igEndTable();

    ig.igTableSetupScrollFreeze(0, 1);
    for (g.columns[0..n_cols]) |name| ig.igTableSetupColumn(name.ptr, 0, 0, 0);
    ig.igTableHeadersRow();

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
    ig.ImGuiListClipper_Begin(clipper, @intCast(g.rows.len), -1);
    while (ig.ImGuiListClipper_Step(clipper)) {
        var start: c_int = 0;
        var end: c_int = 0;
        shim_clipper_range(clipper, &start, &end);
        for (g.rows[@intCast(start)..@intCast(end)]) |row| {
            ig.igTableNextRow(0, 0);
            for (row[0..n_cols]) |cell| {
                _ = ig.igTableNextColumn();
                if (cell) |s| textSlice(s) else ig.igTextDisabled("NULL");
            }
        }
    }
    return changed;
}

var dropped: [1024:0]u8 = @splat(0); // caminho solto na janela (callback do GLFW)

fn onDrop(_: *glfw.Window, count: i32, paths: [*][*:0]const u8) callconv(.c) void {
    if (count < 1) return;
    const p = std.mem.span(paths[0]);
    const n = @min(p.len, dropped.len);
    @memcpy(dropped[0..n], p[0..n]);
    dropped[n] = 0;
}

const usage =
    \\usage: mdb2sql-zig [database.duckdb|.db] [--table NAME] [--sql "SELECT ..."]
    \\  no database argument: uses the MDB2SQL_DB_PATH environment variable, if set
    \\
;

pub fn main(init: std.process.Init) !void {
    var app: App = .{ .gpa = init.gpa, .db = .init(init.gpa) };
    defer app.deinit();

    // Argumentos: caminho do banco e estado inicial opcional (--table, --sql)
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var start_table: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const takes_value = std.mem.eql(u8, arg, "--table") or std.mem.eql(u8, arg, "--sql");
        if (takes_value and i + 1 < args.len) {
            i += 1;
            if (arg[2] == 't') start_table = args[i] else {
                const n = @min(args[i].len, app.sql.len);
                @memcpy(app.sql[0..n], args[i][0..n]);
                app.sql[n] = 0;
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("{s}", .{usage});
            return;
        } else app.setPath(arg);
    }
    if (app.path[0] == 0) if (init.environ_map.get("MDB2SQL_DB_PATH")) |p| app.setPath(p);

    if (app.path[0] != 0) {
        app.open();
        if (start_table) |name| for (app.db.table_names, 0..) |n, idx| {
            if (std.ascii.eqlIgnoreCase(n, name)) app.select(idx);
        };
        if (app.sql[0] != 0 and app.db.isOpen()) {
            app.runSql();
            app.focus_sql = true;
        }
    }

    try glfw.init();
    defer glfw.terminate();
    glfw.windowHint(.context_version_major, 3);
    glfw.windowHint(.context_version_minor, 3);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    const window = try glfw.Window.create(1280, 800, "MDB2SQL - Database Viewer (Zig + Dear ImGui)", null, null);
    defer window.destroy();
    glfw.makeContextCurrent(window);
    glfw.swapInterval(1);
    _ = glfw.setDropCallback(window, onDrop);

    _ = ig.igCreateContext(null);
    defer ig.igDestroyContext(null);
    shim_io_setup();
    ig.igStyleColorsDark(null);
    const scale = window.getContentScale()[0];
    ig.ImGuiStyle_ScaleAllSizes(ig.igGetStyle(), scale);
    // Segoe UI quando existe (acentos legiveis); senao fica a fonte embutida do ImGui
    const font = "C:\\Windows\\Fonts\\segoeui.ttf";
    if (std.Io.Dir.cwd().access(init.io, font, .{})) |_| {
        shim_add_font(font, 17 * scale);
    } else |_| ig.igGetStyle().*.FontScaleDpi = scale;

    _ = ImGui_ImplGlfw_InitForOpenGL(window, true);
    defer ImGui_ImplGlfw_Shutdown();
    _ = ImGui_ImplOpenGL3_Init("#version 330");
    defer ImGui_ImplOpenGL3_Shutdown();

    while (!window.shouldClose()) {
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
