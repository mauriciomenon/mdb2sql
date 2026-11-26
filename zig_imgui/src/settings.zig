// Preferencias gravadas entre execucoes (%APPDATA%\mdb2sql\zig-imgui.ini; Linux: ~/.config/mdb2sql/zig-imgui.ini) e
// pasta padrao dos dialogos
// !T: Persisted settings (theme, language, last folder used) and the default folder of the save dialogs

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Lang = @import("i18n.zig").Lang;

pub const Theme = enum { system, light, dark };

// Busca da aba Data: so na tabela aberta ou em todas as tabelas
pub const SearchScope = enum { table, all };

// Aba Termos: a celula inteira igual ao termo, ou a celula contem o termo
pub const TermMatch = enum { whole, contains };

// Painel de Log (REGRA_VISUAL): ~10% da altura, ate 25% (o minimo de 3 linhas e conferido pela UI)
pub const default_log_frac: f32 = 0.10;
pub const max_log_frac: f32 = 0.25;

pub fn clampLogFrac(f: f32) f32 {
    if (!(f > 0)) return default_log_frac; // NaN ou zero
    return @min(f, max_log_frac);
}

// Versao de um arquivo (a chave do Go: caminho + tamanho + data de modificacao)
pub const FileKey = struct { size: u64, mtime: i96 };

pub fn fileKey(io: Io, path: []const u8) ?FileKey {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return .{ .size = st.size, .mtime = st.mtime.nanoseconds };
}

fn samePath(a: []const u8, b: []const u8) bool {
    return if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

// !T: An Access file converted and saved as SQLite: the source and the saved file, each with its key when saved.
// Kept between runs: the same Access file, unchanged, opens the saved SQLite without converting or asking; if either
// file changed (or the SQLite is gone), the Access file is converted again.
pub const Saved = struct {
    src_buf: [1024]u8 = undefined,
    src_len: usize = 0,
    src_key: FileKey = .{ .size = 0, .mtime = 0 },
    dest_buf: [1024]u8 = undefined,
    dest_len: usize = 0,
    dest_key: FileKey = .{ .size = 0, .mtime = 0 },

    pub fn src(e: *const Saved) []const u8 {
        return e.src_buf[0..e.src_len];
    }

    pub fn dest(e: *const Saved) []const u8 {
        return e.dest_buf[0..e.dest_len];
    }

    fn make(src_path: []const u8, sk: FileKey, dest_path: []const u8, dk: FileKey) ?Saved {
        // tab e quebra de linha separam os campos no arquivo de configuracoes
        for ([_][]const u8{ src_path, dest_path }) |p| if (p.len == 0 or p.len > 1024 or std.mem.indexOfAny(u8, p, "\t\r\n") != null) return null;
        var e: Saved = .{ .src_len = src_path.len, .src_key = sk, .dest_len = dest_path.len, .dest_key = dk };
        @memcpy(e.src_buf[0..src_path.len], src_path);
        @memcpy(e.dest_buf[0..dest_path.len], dest_path);
        return e;
    }
};
pub const max_saved = 8; // os mais recentes

pub const Settings = struct {
    theme: Theme = .system,
    lang: Lang = .en,
    log_open: bool = false, // painel de Log aberto (padrao: recolhido)
    log_frac: f32 = default_log_frac, // altura do painel de Log, fracao da janela
    search_scope: SearchScope = .table, // escopo padrao da busca
    term_match: TermMatch = .whole, // comparacao padrao da pesquisa de termos
    show_null: bool = false, // ligado, NULL aparece como "NULL"; desligado (padrao), celula vazia
    last_dir_buf: [2048]u8 = undefined,
    last_dir_len: usize = 0,
    saved: [max_saved]Saved = undefined, // Access convertido e salvo, o mais recente primeiro
    saved_len: usize = 0,

    // Lembra (no comeco da lista) o SQLite salvo de `src_path`, com as chaves dos dois arquivos agora
    pub fn rememberSaved(s: *Settings, io: Io, src_path: []const u8, dest_path: []const u8) void {
        const e = Saved.make(src_path, fileKey(io, src_path) orelse return, dest_path, fileKey(io, dest_path) orelse return) orelse return;
        s.putSaved(e);
    }

    fn putSaved(s: *Settings, e: Saved) void {
        // a entrada antiga do mesmo arquivo sai; cheia, a mais antiga sai
        var n: usize = 0;
        for (s.saved[0..s.saved_len]) |old| {
            if (!samePath(old.src(), e.src())) {
                s.saved[n] = old;
                n += 1;
            }
        }
        if (n == max_saved) n -= 1;
        std.mem.copyBackwards(Saved, s.saved[1 .. n + 1], s.saved[0..n]);
        s.saved[0] = e;
        s.saved_len = n + 1;
    }

    // SQLite salvo deste Access, se nenhum dos dois mudou desde que foi salvo; null = converter
    pub fn savedFor(s: *const Settings, io: Io, src_path: []const u8) ?[]const u8 {
        for (s.saved[0..s.saved_len]) |*e| {
            if (!samePath(e.src(), src_path)) continue;
            const sk = fileKey(io, src_path) orelse return null;
            const dk = fileKey(io, e.dest()) orelse return null;
            if (std.meta.eql(sk, e.src_key) and std.meta.eql(dk, e.dest_key)) return e.dest();
            return null;
        }
        return null;
    }

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
            if (std.mem.eql(u8, key, "lang")) s.lang = std.meta.stringToEnum(Lang, value) orelse .en;
            if (std.mem.eql(u8, key, "last_dir")) s.setLastDir(value);
            if (std.mem.eql(u8, key, "log_open")) s.log_open = std.mem.eql(u8, value, "1");
            if (std.mem.eql(u8, key, "log_frac")) s.log_frac = clampLogFrac(std.fmt.parseFloat(f32, value) catch default_log_frac);
            if (std.mem.eql(u8, key, "search_scope")) s.search_scope = std.meta.stringToEnum(SearchScope, value) orelse .table;
            if (std.mem.eql(u8, key, "term_match")) s.term_match = std.meta.stringToEnum(TermMatch, value) orelse .whole;
            if (std.mem.eql(u8, key, "show_null")) s.show_null = std.mem.eql(u8, value, "1");
            // saved=<tamanho>|<data>|<tamanho do sqlite>|<data do sqlite>|<access>TAB<sqlite> (na ordem: mais recente primeiro)
            if (std.mem.eql(u8, key, "saved") and s.saved_len < max_saved) if (parseSaved(value)) |e| {
                s.saved[s.saved_len] = e;
                s.saved_len += 1;
            };
        }
        return s;
    }

    fn parseSaved(value: []const u8) ?Saved {
        var it = std.mem.splitScalar(u8, value, '|');
        var nums: [4]i128 = undefined;
        for (&nums) |*n| n.* = std.fmt.parseInt(i128, it.next() orelse return null, 10) catch return null;
        const paths = it.rest();
        const tab = std.mem.indexOfScalar(u8, paths, '\t') orelse return null;
        if (nums[0] < 0 or nums[2] < 0) return null;
        return Saved.make(paths[0..tab], .{ .size = @intCast(nums[0]), .mtime = std.math.cast(i96, nums[1]) orelse return null }, paths[tab + 1 ..], .{ .size = @intCast(nums[2]), .mtime = std.math.cast(i96, nums[3]) orelse return null });
    }

    pub fn write(s: *const Settings, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("theme={t}\r\nlang={t}\r\nlog_open={d}\r\nlog_frac={d:.3}\r\nsearch_scope={t}\r\nterm_match={t}\r\nshow_null={d}\r\nlast_dir={s}\r\n", .{
            s.theme,        s.lang,       @intFromBool(s.log_open),  s.log_frac,
            s.search_scope, s.term_match, @intFromBool(s.show_null), s.lastDir(),
        });
        for (s.saved[0..s.saved_len]) |*e|
            try w.print("saved={d}|{d}|{d}|{d}|{s}\t{s}\r\n", .{ e.src_key.size, e.src_key.mtime, e.dest_key.size, e.dest_key.mtime, e.src(), e.dest() });
    }

    pub fn load(io: Io, path: []const u8) Settings {
        var buf: [32768]u8 = undefined;
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
    const sep = if (dir[dir.len - 1] == '\\' or dir[dir.len - 1] == '/') "" else std.fs.path.sep_str;
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ dir, sep, name }) catch name;
}

// Nome de arquivo seguro a partir de um nome de tabela (sem \ / : * ? " < > |)
pub fn fileName(buf: []u8, base: []const u8, ext: []const u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    for (base[0..@min(base.len, 150)]) |ch| w.writeByte(if (std.mem.indexOfScalar(u8, "\\/:*?\"<>|", ch) != null or ch < 0x20) '_' else ch) catch break;
    w.writeAll(ext) catch {};
    return w.buffered();
}

// Tema do sistema para "Sistema". Windows: HKCU\...\Themes\Personalize\AppsUseLightTheme (sem a chave: claro).
// Linux: GTK_THEME terminado em ":dark" ou com "-dark" no nome e escuro; o resto, claro.
extern "advapi32" fn RegGetValueW(key: usize, sub: [*:0]const u16, value: [*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, size: ?*u32) callconv(.winapi) i32;

pub fn systemPrefersLight(gtk_theme: []const u8) bool {
    if (builtin.os.tag != .windows) return std.ascii.findIgnoreCase(gtk_theme, "dark") == null;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var v: u32 = 1;
    var size: u32 = @sizeOf(u32);
    const HKEY_CURRENT_USER: usize = 0x80000001;
    const RRF_RT_REG_DWORD = 0x10;
    if (RegGetValueW(HKEY_CURRENT_USER, L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"), L("AppsUseLightTheme"), RRF_RT_REG_DWORD, null, &v, &size) != 0) return true;
    return v != 0;
}

pub fn isLight(theme: Theme, gtk_theme: []const u8) bool {
    return switch (theme) {
        .light => true,
        .dark => false,
        .system => systemPrefersLight(gtk_theme),
    };
}

// -------------------------------------------------------------------- tests

const t = std.testing;

test "Access converted and saved: reused while neither file changes, kept between runs, newest first" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    var b3: [256]u8 = undefined;
    const src = try std.fmt.bufPrint(&b1, ".zig-cache/tmp/{s}/DB4.accdb", .{tmp.sub_path});
    const dest = try std.fmt.bufPrint(&b2, ".zig-cache/tmp/{s}/DB4.sqlite", .{tmp.sub_path});
    const ini = try std.fmt.bufPrint(&b3, ".zig-cache/tmp/{s}/zig-imgui.ini", .{tmp.sub_path});
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = src, .data = "access v1" });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = dest, .data = "SQLite format 3\x00" });
    var s: Settings = .{};
    try t.expect(s.savedFor(t.io, src) == null); // nada salvo: converte
    s.rememberSaved(t.io, src, dest);
    try t.expectEqualStrings(dest, s.savedFor(t.io, src).?);
    // a resposta vale na proxima execucao (gravada e lida de novo)
    try s.save(t.io, ini);
    var back = Settings.load(t.io, ini);
    try t.expectEqual(1, back.saved_len);
    try t.expectEqualStrings(dest, back.savedFor(t.io, src).?);
    // o Access mudou (tamanho): converte de novo
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = src, .data = "access v2, maior" });
    try t.expect(back.savedFor(t.io, src) == null);
    // salvo de novo: uma entrada so para o mesmo arquivo; o SQLite apagado: converte de novo
    back.rememberSaved(t.io, src, dest);
    try t.expectEqual(1, back.saved_len);
    try t.expect(back.savedFor(t.io, src) != null);
    try Io.Dir.cwd().deleteFile(t.io, dest);
    try t.expect(back.savedFor(t.io, src) == null);
    // no maximo max_saved, o mais recente primeiro; linha estragada e ignorada
    var many: Settings = .{};
    for (0..max_saved + 2) |i| {
        var nb: [32]u8 = undefined;
        many.putSaved(Saved.make(try std.fmt.bufPrint(&nb, "C:\\a{d}.accdb", .{i}), .{ .size = i, .mtime = 1 }, "C:\\x.sqlite", .{ .size = 1, .mtime = 1 }).?);
    }
    try t.expectEqual(max_saved, many.saved_len);
    try t.expectEqualStrings("C:\\a9.accdb", many.saved[0].src());
    try t.expectEqual(0, Settings.parse("saved=1|2|x|4|a\tb\r\nsaved=1|2|3|4|sem tab\r\n").saved_len);
    try t.expect(Saved.make("a\tb", .{ .size = 1, .mtime = 1 }, "c", .{ .size = 1, .mtime = 1 }) == null);
}

test "default folder of the save dialog" {
    const s = std.fs.path.sep_str;
    try t.expectEqualStrings("C:" ++ s ++ "dados", defaultDir("C:" ++ s ++ "dados" ++ s ++ "2026-07-14 DB4.accdb", "D:\\ultima"));
    try t.expectEqualStrings("D:\\ultima", defaultDir("", "D:\\ultima"));
    try t.expectEqualStrings("", defaultDir("", ""));
    var b: [256]u8 = undefined;
    try t.expectEqualStrings("C:" ++ s ++ "dados" ++ s ++ "DB4.xlsx", suggest(&b, "C:" ++ s ++ "dados", "DB4.xlsx"));
    try t.expectEqualStrings("C:\\DB4.xlsx", suggest(&b, "C:\\", "DB4.xlsx"));
    try t.expectEqualStrings("DB4.xlsx", suggest(&b, "", "DB4.xlsx"));
    try t.expectEqualStrings("a_b_c.csv", fileName(&b, "a/b:c", ".csv"));
}

test "settings round trip through the file" {
    var s: Settings = .{ .theme = .dark, .lang = .pt_br, .log_open = true, .log_frac = 0.22, .search_scope = .all, .term_match = .contains, .show_null = true };
    s.setLastDir("C:\\pasta com espaço");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, ".zig-cache/tmp/{s}/sub/zig-imgui.ini", .{tmp.sub_path});
    try s.save(t.io, path);
    const back = Settings.load(t.io, path);
    try t.expectEqual(.dark, back.theme);
    try t.expectEqual(.pt_br, back.lang);
    try t.expect(back.log_open);
    try t.expectApproxEqAbs(@as(f32, 0.22), back.log_frac, 0.001);
    try t.expectEqual(.all, back.search_scope);
    try t.expectEqual(.contains, back.term_match);
    try t.expectEqual(.whole, Settings.parse("term_match=x\n").term_match); // padrao: valor inteiro
    try t.expect(back.show_null);
    // padrao: busca na tabela aberta, NULL como celula vazia (arquivo de versao anterior tambem)
    try t.expectEqual(.table, Settings.parse("theme=dark\n").search_scope);
    try t.expect(!Settings.parse("theme=dark\n").show_null);
    // a opcao "copiar com cabecalho" saiu (o menu da celula tem os dois itens): arquivo antigo com ela abre igual
    // e ela nao volta a ser gravada
    const old = Settings.parse("show_null=1\r\ncopy_header=1\r\nlast_dir=C:\\x\r\n");
    try t.expect(old.show_null);
    try t.expectEqualStrings("C:\\x", old.lastDir());
    var wb: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&wb);
    try old.write(&w);
    try t.expect(std.mem.indexOf(u8, w.buffered(), "copy_header") == null);
    try t.expectEqual(.table, Settings.parse("search_scope=x\n").search_scope);
    // padrao: Log recolhido, 10%; fracao fora do limite volta para dentro
    try t.expect(!Settings.parse("").log_open);
    try t.expectEqual(default_log_frac, Settings.parse("").log_frac);
    try t.expectEqual(max_log_frac, Settings.parse("log_frac=0.9").log_frac);
    try t.expectEqual(default_log_frac, Settings.parse("log_frac=x").log_frac);
    try t.expectEqualStrings("C:\\pasta com espaço", back.lastDir());
    // arquivo ausente ou estranho: padroes
    try t.expectEqual(.system, Settings.load(t.io, "nao/existe.ini").theme);
    try t.expectEqual(.system, Settings.parse("theme=roxo\nlixo\n").theme);
    try t.expectEqual(.en, Settings.load(t.io, "nao/existe.ini").lang); // ingles e o padrao
    try t.expectEqual(.es, Settings.parse("lang=es\n").lang);
    try t.expectEqual(.en, Settings.parse("lang=klingon\n").lang);
    _ = isLight(.system, ""); // le o registro sem quebrar
    if (builtin.os.tag != .windows) try t.expect(!systemPrefersLight("Adwaita:dark") and systemPrefersLight("Adwaita"));
}
