// Dialogos nativos de abrir/salvar do Windows (comdlg32). Bloqueiam ate o usuario escolher.
// !T: Native Windows open/save file dialogs through GetOpenFileNameW / GetSaveFileNameW

const std = @import("std");
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

pub const max_path = 1024; // em unidades UTF-16
pub const PathBuf = [max_path * 3]u8; // pior caso em UTF-8

// Caminho escolhido em UTF-8 dentro de `out`, ou null se o usuario cancelou.
// `initial` e o caminho sugerido: pasta + nome (o dialogo abre nessa pasta), ou so a pasta (abrir).
pub fn pick(kind: Kind, owner: ?*anyopaque, initial: []const u8, out: *PathBuf) ?[]const u8 {
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
            ofn.lpstrFilter = L("Databases (*.duckdb;*.db;*.sqlite;*.sqlite3;*.mdb;*.accdb)\x00*.duckdb;*.db;*.sqlite;*.sqlite3;*.mdb;*.accdb\x00" ++
                "DuckDB (*.duckdb;*.db)\x00*.duckdb;*.db\x00SQLite (*.sqlite;*.sqlite3)\x00*.sqlite;*.sqlite3\x00" ++
                "Access (*.mdb;*.accdb)\x00*.mdb;*.accdb\x00All files (*.*)\x00*.*\x00");
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
