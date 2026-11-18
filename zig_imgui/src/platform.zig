// O pouco que muda entre Windows e Linux na UI: caixa de mensagem, abrir link, barra de titulo escura, fonte
// !T: Platform bits of the GUI (Windows API or Linux tools); the dialogs are in dialog.zig

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

// Convencao de chamada das funcoes do OpenGL (APIENTRY)
pub const glcc: std.builtin.CallingConvention = if (is_windows) .winapi else .c;

extern "user32" fn MessageBoxW(hwnd: ?*anyopaque, text: [*:0]const u16, caption: [*:0]const u16, kind: c_uint) callconv(.winapi) c_int;
extern "dwmapi" fn DwmSetWindowAttribute(hwnd: ?*anyopaque, attr: c_uint, value: *const c_int, size: c_uint) callconv(.winapi) c_long;
extern "shell32" fn ShellExecuteW(hwnd: ?*anyopaque, op: [*:0]const u16, file: [*:0]const u16, params: ?[*:0]const u16, dir: ?[*:0]const u16, show: c_int) callconv(.winapi) ?*anyopaque;

pub const Icon = enum { info, err };

// Caixa de mensagem (o exe de release do Windows nao tem console). Linux: stderr e, se houver, o zenity.
pub fn messageBox(io: ?std.Io, title: []const u8, text_utf8: []const u8, icon: Icon) void {
    const text = text_utf8[0..@min(text_utf8.len, 1000)];
    if (is_windows) {
        var wide: [2048:0]u16 = undefined;
        const n = std.unicode.wtf8ToWtf16Le(wide[0 .. wide.len - 1], text) catch 0;
        wide[n] = 0;
        var cap: [128:0]u16 = undefined;
        const cn = std.unicode.wtf8ToWtf16Le(cap[0 .. cap.len - 1], title[0..@min(title.len, 100)]) catch 0;
        cap[cn] = 0;
        _ = MessageBoxW(null, &wide, &cap, if (icon == .err) 0x10 else 0x40);
        return;
    }
    std.debug.print("{s}\n", .{text});
    const i = io orelse return;
    var b: [1100]u8 = undefined;
    const arg = std.fmt.bufPrint(&b, "--text={s}", .{text}) catch return;
    var tb: [140]u8 = undefined;
    const targ = std.fmt.bufPrint(&tb, "--title={s}", .{title}) catch return;
    var child = std.process.spawn(i, .{
        .argv = &.{ "zenity", if (icon == .err) "--error" else "--info", "--no-markup", targ, arg },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(i) catch {};
}

// Abre a URL (ja conferida pelo chamador) no navegador padrao
pub fn openUrl(io: std.Io, url: [:0]const u8) void {
    if (is_windows) {
        var wide: [128:0]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], url) catch return;
        wide[n] = 0;
        _ = ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), &wide, null, null, 1); // SW_SHOWNORMAL
        return;
    }
    // xdg-open volta logo; o filho e esperado numa thread para nao virar zumbi nem travar a UI
    var child = std.process.spawn(io, .{ .argv = &.{ "xdg-open", url }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return;
    _ = child.wait(io) catch {};
}

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlclose(handle: *anyopaque) c_int;

// Linux: a biblioteca do sistema carrega (o GLFW a abre do mesmo jeito); so para dizer o que falta
pub fn libLoads(name: []const u8) bool {
    if (is_windows) return true;
    var buf: [128]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return false;
    const h = dlopen(z, 1) orelse return false; // RTLD_LAZY
    _ = dlclose(h);
    return true;
}

// Barra de titulo escura no Windows 11 (no Linux quem decide e o tema do sistema)
pub fn darkTitleBar(hwnd: ?*anyopaque, dark: bool) void {
    if (!is_windows) return;
    const v: c_int = @intFromBool(dark);
    _ = DwmSetWindowAttribute(hwnd, 20, &v, @sizeOf(c_int)); // DWMWA_USE_IMMERSIVE_DARK_MODE
}

// Fonte da interface: a primeira que existir (acentos legiveis); nenhuma = a fonte embutida do ImGui
pub const fonts = if (is_windows)
    [_][:0]const u8{"C:\\Windows\\Fonts\\segoeui.ttf"}
else
    [_][:0]const u8{
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
    };

// Fonte monoespacada do painel de Log
pub const mono_fonts = if (is_windows)
    [_][:0]const u8{ "C:\\Windows\\Fonts\\consola.ttf", "C:\\Windows\\Fonts\\cour.ttf" }
else
    [_][:0]const u8{
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    };
