// Dialogos de abrir/salvar: Windows (comdlg32) ou Linux (zenity). Bloqueiam ate o usuario escolher.
// !T: Native open/save file dialogs: GetOpenFileNameW / GetSaveFileNameW on Windows, zenity on Linux

const std = @import("std");
const builtin = @import("builtin");
const i18n = @import("db").i18n;

const is_windows = builtin.os.tag == .windows;

// Texto UTF-16 fixo (os filtros longos passam do limite padrao de avaliacao em tempo de compilacao)
fn L(comptime s: []const u8) [*:0]const u16 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        break :blk std.unicode.utf8ToUtf16LeStringLiteral(s);
    };
}

const OPENFILENAMEW = extern struct {
    lStructSize: u32,
    hwndOwner: ?*anyopaque = null,
    hInstance: ?*anyopaque = null,
    lpstrFilter: ?[*:0]const u16 = null,
    lpstrCustomFilter: ?[*]u16 = null,
    nMaxCustFilter: u32 = 0,
    nFilterIndex: u32 = 0,
    lpstrFile: [*]u16,
    nMaxFile: u32,
    lpstrFileTitle: ?[*]u16 = null,
    nMaxFileTitle: u32 = 0,
    lpstrInitialDir: ?[*:0]const u16 = null,
    lpstrTitle: ?[*:0]const u16 = null,
    Flags: u32 = 0,
    nFileOffset: u16 = 0,
    nFileExtension: u16 = 0,
    lpstrDefExt: ?[*:0]const u16 = null,
    lCustData: usize = 0,
    lpfnHook: ?*anyopaque = null,
    lpTemplateName: ?[*:0]const u16 = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: u32 = 0,
    FlagsEx: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(OPENFILENAMEW) == 152); // tamanho da struct da API em x64
}

extern "comdlg32" fn GetOpenFileNameW(ofn: *OPENFILENAMEW) callconv(.winapi) c_int;
extern "comdlg32" fn GetSaveFileNameW(ofn: *OPENFILENAMEW) callconv(.winapi) c_int;

const OFN_OVERWRITEPROMPT = 0x2;
const OFN_HIDEREADONLY = 0x4;
const OFN_NOCHANGEDIR = 0x8; // o dialogo nao pode trocar o diretorio atual do processo
const OFN_PATHMUSTEXIST = 0x800;
const OFN_FILEMUSTEXIST = 0x1000;
const OFN_EXPLORER = 0x80000;

pub const Kind = enum { open_db, save_csv, save_xlsx, save_duckdb, save_sqlite };

// Tipos de Salvar / Salvar como, na ordem da lista da caixa
pub const SaveType = enum {
    sqlite,
    duckdb,
    xlsx,

    pub fn ext(t: SaveType) []const u8 {
        return switch (t) {
            .sqlite => ".sqlite",
            .duckdb => ".duckdb",
            .xlsx => ".xlsx",
        };
    }

    // Tipo de um arquivo pela extensao; null = outra extensao (ou nenhuma)
    pub fn ofPath(path: []const u8) ?SaveType {
        const e = std.fs.path.extension(path);
        for ([_]SaveType{ .sqlite, .duckdb, .xlsx }) |t| if (std.ascii.eqlIgnoreCase(e, t.ext())) return t;
        return null;
    }
};

pub const Saved = struct { path: []const u8, type: SaveType };

pub const max_path = 1024; // em unidades UTF-16
pub const PathBuf = [max_path * 3]u8; // pior caso em UTF-8

// Filtros: Access primeiro, depois SQLite e DuckDB (mesma ordem em toda a interface)
const open_patterns = "*.accdb;*.mdb;*.sqlite;*.sqlite3;*.db;*.duckdb";

// Linux: o zenity nao pode ser executado (a UI avisa; o caminho ainda pode ser digitado na caixa)
pub var unavailable = false;

// Caminho escolhido em UTF-8 dentro de `out`, ou null se o usuario cancelou (ou nao ha dialogo: Linux sem zenity).
// `initial` e o caminho sugerido: pasta + nome (o dialogo abre nessa pasta), ou so a pasta (abrir).
pub fn pick(io: std.Io, kind: Kind, owner: ?*anyopaque, initial: []const u8, out: *PathBuf) ?[]const u8 {
    return if (is_windows) pickWindows(kind, owner, initial, out) else pickZenity(io, kind, initial, out);
}

fn pickWindows(kind: Kind, owner: ?*anyopaque, initial: []const u8, out: *PathBuf) ?[]const u8 {
    var file: [max_path]u16 = @splat(0);
    var dir: [max_path:0]u16 = @splat(0);
    if (kind == .open_db) {
        // abrir: so a pasta inicial
        const n = std.unicode.wtf8ToWtf16Le(&dir, initial) catch 0;
        dir[@min(n, max_path - 1)] = 0;
    } else if (initial.len < max_path) {
        // nome invalido em UTF-8: fica sem sugestao
        const n = std.unicode.wtf8ToWtf16Le(&file, initial) catch 0;
        @memset(file[n..], 0);
    }
    var ofn: OPENFILENAMEW = .{
        .lStructSize = @sizeOf(OPENFILENAMEW),
        .hwndOwner = owner,
        .lpstrFile = &file,
        .nMaxFile = file.len,
        .lpstrInitialDir = if (dir[0] != 0) &dir else null,
        .Flags = OFN_EXPLORER | OFN_NOCHANGEDIR | OFN_PATHMUSTEXIST | OFN_HIDEREADONLY,
    };
    const ok = switch (kind) {
        .open_db => blk: {
            ofn.lpstrFilter = switch (i18n.lang) {
                inline else => |l| L(@field(i18n.catalogs[@backingInt(l)], "dlg_databases") ++ " (" ++ open_patterns ++ ")\x00" ++ open_patterns ++ "\x00" ++
                    "Access (*.accdb;*.mdb)\x00*.accdb;*.mdb\x00SQLite (*.sqlite;*.sqlite3;*.db)\x00*.sqlite;*.sqlite3;*.db\x00" ++
                    "DuckDB (*.duckdb;*.db)\x00*.duckdb;*.db\x00" ++ @field(i18n.catalogs[@backingInt(l)], "dlg_all_files") ++ " (*.*)\x00*.*\x00"),
            };
            ofn.Flags |= OFN_FILEMUSTEXIST;
            break :blk GetOpenFileNameW(&ofn);
        },
        else => blk: {
            ofn.lpstrFilter, ofn.lpstrDefExt = switch (kind) {
                .save_csv => .{ L("CSV UTF-8 (*.csv)\x00*.csv\x00"), L("csv") },
                .save_xlsx => .{ L("Excel (*.xlsx)\x00*.xlsx\x00"), L("xlsx") },
                .save_duckdb => .{ L("DuckDB (*.duckdb)\x00*.duckdb\x00"), L("duckdb") },
                .save_sqlite => .{ L("SQLite (*.sqlite)\x00*.sqlite\x00"), L("sqlite") },
                .open_db => unreachable,
            };
            ofn.Flags |= OFN_OVERWRITEPROMPT;
            break :blk GetSaveFileNameW(&ofn);
        },
    };
    if (ok == 0) return null;
    return out[0..std.unicode.wtf16LeToWtf8(out, std.mem.sliceTo(&file, 0))];
}

// !T: Save box of File > Save and Save as: the title, the three types (SQLite, DuckDB, Excel) and the type `first`
// already chosen in the list. `initial` = folder + suggested name. The type returned is the one of the extension of
// the chosen file (the box changes the extension with the type); with another extension, the type chosen in the list.
pub fn pickSave(io: std.Io, owner: ?*anyopaque, title: []const u8, initial: []const u8, first: SaveType, out: *PathBuf) ?Saved {
    return if (is_windows) pickSaveWindows(owner, title, initial, first, out) else pickSaveZenity(io, title, initial, first, out);
}

fn pickSaveWindows(owner: ?*anyopaque, title: []const u8, initial: []const u8, first: SaveType, out: *PathBuf) ?Saved {
    var file: [max_path]u16 = @splat(0);
    if (initial.len < max_path) {
        const n = std.unicode.wtf8ToWtf16Le(&file, initial) catch 0;
        @memset(file[n..], 0);
    }
    var title_w: [512:0]u16 = @splat(0);
    const tn = if (title.len < title_w.len) std.unicode.wtf8ToWtf16Le(&title_w, title) catch 0 else 0;
    title_w[tn] = 0;
    var ofn: OPENFILENAMEW = .{
        .lStructSize = @sizeOf(OPENFILENAMEW),
        .hwndOwner = owner,
        .lpstrFile = &file,
        .nMaxFile = file.len,
        .lpstrFilter = L("SQLite (*.sqlite)\x00*.sqlite\x00DuckDB (*.duckdb)\x00*.duckdb\x00Excel (*.xlsx)\x00*.xlsx\x00"),
        .nFilterIndex = switch (first) {
            .sqlite => 1,
            .duckdb => 2,
            .xlsx => 3,
        },
        // com extensao padrao a caixa poe a do tipo escolhido na lista quando o usuario nao digita uma
        .lpstrDefExt = switch (first) {
            .sqlite => L("sqlite"),
            .duckdb => L("duckdb"),
            .xlsx => L("xlsx"),
        },
        .lpstrTitle = if (tn > 0) &title_w else null,
        .Flags = OFN_EXPLORER | OFN_NOCHANGEDIR | OFN_PATHMUSTEXIST | OFN_HIDEREADONLY | OFN_OVERWRITEPROMPT,
    };
    if (GetSaveFileNameW(&ofn) == 0) return null;
    const path = out[0..std.unicode.wtf16LeToWtf8(out, std.mem.sliceTo(&file, 0))];
    const listed: SaveType = switch (ofn.nFilterIndex) {
        2 => .duckdb,
        3 => .xlsx,
        else => .sqlite,
    };
    return .{ .path = path, .type = SaveType.ofPath(path) orelse listed };
}

// zenity nao diz o tipo escolhido nem deixa escolher o inicial: o tipo inicial e o primeiro filtro, e o arquivo sem
// uma das tres extensoes ganha a do tipo inicial
fn pickSaveZenity(io: std.Io, title: []const u8, initial: []const u8, first: SaveType, out: *PathBuf) ?Saved {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{ "zenity", "--file-selection", "--save", "--confirm-overwrite" }) catch return null;
    argv.append(a, std.fmt.allocPrint(a, "--title={s}", .{title}) catch return null) catch return null;
    const order: [3]SaveType = switch (first) {
        .sqlite => .{ .sqlite, .duckdb, .xlsx },
        .duckdb => .{ .duckdb, .sqlite, .xlsx },
        .xlsx => .{ .xlsx, .sqlite, .duckdb },
    };
    for (order) |t| argv.append(a, switch (t) {
        .sqlite => "--file-filter=SQLite | *.sqlite",
        .duckdb => "--file-filter=DuckDB | *.duckdb",
        .xlsx => "--file-filter=Excel | *.xlsx",
    }) catch return null;
    if (initial.len > 0) argv.append(a, std.fmt.allocPrint(a, "--filename={s}", .{initial}) catch return null) catch return null;
    const path = runZenity(io, a, argv.items, out) orelse return null;
    if (SaveType.ofPath(path)) |t| return .{ .path = path, .type = t };
    const ext = first.ext();
    if (path.len + ext.len > out.len) return null;
    @memcpy(out[path.len..][0..ext.len], ext);
    return .{ .path = out[0 .. path.len + ext.len], .type = first };
}

// !T: Native folder picker (IFileOpenDialog with FOS_PICKFOLDERS on Windows, zenity --directory on Linux), opened in
// `initial`. null = canceled, or no dialog available.
pub fn pickFolder(io: std.Io, owner: ?*anyopaque, initial: []const u8, out: *PathBuf) ?[]const u8 {
    if (is_windows) return pickFolderWindows(owner, initial, out);
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{ "zenity", "--file-selection", "--directory" }) catch return null;
    if (initial.len > 0) argv.append(a, std.fmt.allocPrint(a, "--filename={s}/", .{initial}) catch return null) catch return null;
    return runZenity(io, a, argv.items, out);
}

const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
const clsid_file_open_dialog: GUID = .{ .a = 0xDC1C5A9C, .b = 0xE88A, .c = 0x4DDE, .d = .{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 } };
const iid_file_open_dialog: GUID = .{ .a = 0xD57C7288, .b = 0xD4AD, .c = 0x4768, .d = .{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60 } };
const iid_shell_item: GUID = .{ .a = 0x43826D1E, .b = 0xE718, .c = 0x42EE, .d = .{ 0xBC, 0x55, 0xA1, 0xE2, 0x61, 0xC3, 0x7B, 0xFE } };

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) i32;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, context: u32, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) i32;
extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) callconv(.winapi) void;
extern "shell32" fn SHCreateItemFromParsingName(path: [*:0]const u16, bind: ?*anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) i32;

// Metodo numero `index` da tabela de um objeto COM (todo objeto: 0 QueryInterface, 1 AddRef, 2 Release)
fn com(obj: *anyopaque, index: usize, comptime Fn: type) *const Fn {
    const vtable: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return @ptrCast(vtable.*[index]);
}

fn release(obj: *anyopaque) void {
    _ = com(obj, 2, fn (*anyopaque) callconv(.winapi) u32)(obj);
}

fn pickFolderWindows(owner: ?*anyopaque, initial: []const u8, out: *PathBuf) ?[]const u8 {
    const init_hr = CoInitializeEx(null, 0x2); // COINIT_APARTMENTTHREADED; S_OK e S_FALSE pedem CoUninitialize
    defer if (init_hr >= 0) CoUninitialize();
    var created: ?*anyopaque = null;
    if (CoCreateInstance(&clsid_file_open_dialog, null, 1, &iid_file_open_dialog, &created) < 0) return null; // CLSCTX_INPROC_SERVER
    const dlg = created orelse return null;
    defer release(dlg);
    // IFileDialog: 3 Show, 9 SetOptions, 10 GetOptions, 12 SetFolder, 20 GetResult
    var options: u32 = 0;
    _ = com(dlg, 10, fn (*anyopaque, *u32) callconv(.winapi) i32)(dlg, &options);
    // FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_NOCHANGEDIR
    _ = com(dlg, 9, fn (*anyopaque, u32) callconv(.winapi) i32)(dlg, options | 0x20 | 0x40 | 0x8);
    var dir: [max_path:0]u16 = @splat(0);
    if (initial.len > 0 and initial.len < max_path) {
        const n = std.unicode.wtf8ToWtf16Le(&dir, initial) catch 0;
        dir[n] = 0;
        var folder: ?*anyopaque = null;
        if (n > 0 and SHCreateItemFromParsingName(&dir, null, &iid_shell_item, &folder) >= 0) if (folder) |f| {
            _ = com(dlg, 12, fn (*anyopaque, *anyopaque) callconv(.winapi) i32)(dlg, f);
            release(f);
        };
    }
    if (com(dlg, 3, fn (*anyopaque, ?*anyopaque) callconv(.winapi) i32)(dlg, owner) < 0) return null; // cancelado
    var result: ?*anyopaque = null;
    if (com(dlg, 20, fn (*anyopaque, *?*anyopaque) callconv(.winapi) i32)(dlg, &result) < 0) return null;
    const item = result orelse return null;
    defer release(item);
    var name: ?[*:0]u16 = null;
    // IShellItem: 5 GetDisplayName; 0x80058000 = SIGDN_FILESYSPATH
    if (com(item, 5, fn (*anyopaque, u32, *?[*:0]u16) callconv(.winapi) i32)(item, 0x80058000, &name) < 0) return null;
    const wide = name orelse return null;
    defer CoTaskMemFree(wide);
    const path = std.mem.span(wide);
    if (std.unicode.calcWtf8Len(path) > out.len) return null;
    return out[0..std.unicode.wtf16LeToWtf8(out, path)];
}

// Roda o zenity: o caminho escolhido sai no stdout; cancelar sai com codigo 1
fn runZenity(io: std.Io, a: std.mem.Allocator, argv: []const []const u8, out: *PathBuf) ?[]const u8 {
    const res = std.process.run(a, io, .{ .argv = argv }) catch {
        unavailable = true;
        return null;
    };
    if (!res.term.success()) return null;
    const path = std.mem.trimEnd(u8, res.stdout, "\r\n");
    if (path.len == 0 or path.len > out.len) return null;
    @memcpy(out[0..path.len], path);
    return out[0..path.len];
}

// zenity --file-selection com o filtro do tipo
fn pickZenity(io: std.Io, kind: Kind, initial: []const u8, out: *PathBuf) ?[]const u8 {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{ "zenity", "--file-selection" }) catch return null;
    const filter: []const u8 = switch (kind) {
        .open_db => std.fmt.allocPrint(a, "--file-filter={s} | *.accdb *.mdb *.sqlite *.sqlite3 *.db *.duckdb", .{i18n.tr("dlg_databases")}) catch return null,
        .save_csv => "--file-filter=CSV | *.csv",
        .save_xlsx => "--file-filter=Excel | *.xlsx",
        .save_duckdb => "--file-filter=DuckDB | *.duckdb",
        .save_sqlite => "--file-filter=SQLite | *.sqlite",
    };
    argv.append(a, filter) catch return null;
    if (kind != .open_db) argv.appendSlice(a, &.{ "--save", "--confirm-overwrite" }) catch return null;
    if (initial.len > 0) {
        // pasta inicial: termina em / para o zenity abrir dentro dela
        const f = if (kind == .open_db) std.fmt.allocPrint(a, "--filename={s}/", .{initial}) else std.fmt.allocPrint(a, "--filename={s}", .{initial});
        argv.append(a, f catch return null) catch return null;
    }
    return runZenity(io, a, argv.items, out);
}
