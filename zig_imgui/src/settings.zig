// Preferencias gravadas entre execucoes (%APPDATA%\mdb2sql\zig-imgui.ini) e pasta padrao dos dialogos
// !T: Persisted settings (theme, last folder used) and the default folder of the save dialogs

const std = @import("std");
const Io = std.Io;

pub const Theme = enum { system, light, dark };

pub const Settings = struct {
    theme: Theme = .system,
    last_dir_buf: [2048]u8 = undefined,
    last_dir_len: usize = 0,

    pub fn lastDir(s: *const Settings) []const u8 {
        return s.last_dir_buf[0..s.last_dir_len];
    }

    pub fn setLastDir(s: *Settings, dir: []const u8) void {
        s.last_dir_len = @min(dir.len, s.last_dir_buf.len);
        @memcpy(s.last_dir_buf[0..s.last_dir_len], dir[0..s.last_dir_len]);
    }

    // Linhas chave=valor; o que nao for reconhecido e ignorado (arquivo de outra versao)
    pub fn parse(text: []const u8) Settings {
        var s: Settings = .{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = line[0..eq];
            const value = line[eq + 1 ..];
            if (std.mem.eql(u8, key, "theme")) s.theme = std.meta.stringToEnum(Theme, value) orelse .system;
            if (std.mem.eql(u8, key, "last_dir")) s.setLastDir(value);
        }
        return s;
    }

    pub fn write(s: *const Settings, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("theme={t}\r\nlast_dir={s}\r\n", .{ s.theme, s.lastDir() });
    }

    pub fn load(io: Io, path: []const u8) Settings {
        var buf: [4096]u8 = undefined;
        const text = Io.Dir.cwd().readFile(io, path, &buf) catch return .{};
        return parse(text);
    }

    // Grava num arquivo temporario e troca: um erro no meio nao deixa o arquivo pela metade
    pub fn save(s: *const Settings, io: Io, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
        var tmp_buf: [4096]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
        {
            const file = try Io.Dir.cwd().createFile(io, tmp, .{});
            defer file.close(io);
            var wbuf: [4096]u8 = undefined;
            var fw = file.writer(io, &wbuf);
            try s.write(&fw.interface);
            try fw.end();
        }
        try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, io);
    }
};

// !T: Default folder of a save dialog: the folder of the open file; with no file open, the last folder used
pub fn defaultDir(source_path: []const u8, last_dir: []const u8) []const u8 {
    if (source_path.len > 0) if (std.fs.path.dirname(source_path)) |d| return d;
    return last_dir;
}

// Caminho completo sugerido ao dialogo (pasta + nome); sem pasta, so o nome
pub fn suggest(buf: []u8, dir: []const u8, name: []const u8) []const u8 {
    if (dir.len == 0) return name;
    const sep = if (dir[dir.len - 1] == '\\' or dir[dir.len - 1] == '/') "" else "\\";
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ dir, sep, name }) catch name;
}

// Nome de arquivo seguro a partir de um nome de tabela (sem \ / : * ? " < > |)
pub fn fileName(buf: []u8, base: []const u8, ext: []const u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    for (base[0..@min(base.len, 150)]) |ch| w.writeByte(if (std.mem.indexOfScalar(u8, "\\/:*?\"<>|", ch) != null or ch < 0x20) '_' else ch) catch break;
    w.writeAll(ext) catch {};
    return w.buffered();
}

// Tema do Windows para "Sistema": HKCU\...\Themes\Personalize\AppsUseLightTheme (sem a chave: claro)
extern "advapi32" fn RegGetValueW(key: usize, sub: [*:0]const u16, value: [*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, size: ?*u32) callconv(.winapi) i32;

pub fn systemPrefersLight() bool {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var v: u32 = 1;
    var size: u32 = @sizeOf(u32);
    const HKEY_CURRENT_USER: usize = 0x80000001;
    const RRF_RT_REG_DWORD = 0x10;
    if (RegGetValueW(HKEY_CURRENT_USER, L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"), L("AppsUseLightTheme"), RRF_RT_REG_DWORD, null, &v, &size) != 0) return true;
    return v != 0;
}

pub fn isLight(theme: Theme) bool {
    return switch (theme) {
        .light => true,
        .dark => false,
        .system => systemPrefersLight(),
    };
}

// -------------------------------------------------------------------- tests

const t = std.testing;

test "default folder of the save dialog" {
    try t.expectEqualStrings("C:\\dados", defaultDir("C:\\dados\\2026-07-14 DB4.accdb", "D:\\ultima"));
    try t.expectEqualStrings("D:\\ultima", defaultDir("", "D:\\ultima"));
    try t.expectEqualStrings("", defaultDir("", ""));
    var b: [256]u8 = undefined;
    try t.expectEqualStrings("C:\\dados\\DB4.xlsx", suggest(&b, "C:\\dados", "DB4.xlsx"));
    try t.expectEqualStrings("C:\\DB4.xlsx", suggest(&b, "C:\\", "DB4.xlsx"));
    try t.expectEqualStrings("DB4.xlsx", suggest(&b, "", "DB4.xlsx"));
    try t.expectEqualStrings("a_b_c.csv", fileName(&b, "a/b:c", ".csv"));
}

test "settings round trip through the file" {
    var s: Settings = .{ .theme = .dark };
    s.setLastDir("C:\\pasta com espaço");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, ".zig-cache/tmp/{s}/sub/zig-imgui.ini", .{tmp.sub_path});
    try s.save(t.io, path);
    const back = Settings.load(t.io, path);
    try t.expectEqual(.dark, back.theme);
    try t.expectEqualStrings("C:\\pasta com espaço", back.lastDir());
    // arquivo ausente ou estranho: padroes
    try t.expectEqual(.system, Settings.load(t.io, "nao/existe.ini").theme);
    try t.expectEqual(.system, Settings.parse("theme=roxo\nlixo\n").theme);
    _ = isLight(.system); // le o registro sem quebrar
}
