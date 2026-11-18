// Linux: em que sistema de janelas abrir (REGRA_X11): X11 primeiro; Wayland so como reserva, com aviso na abertura
// dizendo o que falta para o X11 e como instalar na distro; variavel do usuario manda e nao gera aviso.
// Aqui fica so a decisao (sem efeito colateral, testavel); main.zig le o ambiente, testa as bibliotecas e abre a janela.
// !T: Linux display backend decision: user variable > X11 > Wayland fallback (with a warning) > error

const std = @import("std");
const i18n = @import("i18n.zig");

pub const help_url = "https://github.com/mauriciomenon/mdb2sql/blob/master/zig_imgui/README.md#linux-x11-and-wayland";

// Bibliotecas do X11 que o GLFW carrega e o pacote nao leva (o .deb as declara em Depends)
pub const x11_libs = [_][]const u8{ "libX11.so.6", "libXrandr.so.2", "libXinerama.so.1", "libXcursor.so.1", "libXi.so.6" };

pub const Family = enum { debian, fedora, arch, opensuse, other };

// Pacote de cada biblioteca por familia de distro (mesma ordem de x11_libs) e o do servidor X (XWayland)
const packages = [_][5][]const u8{
    .{ "libx11-6", "libxrandr2", "libxinerama1", "libxcursor1", "libxi6" }, // debian/ubuntu
    .{ "libX11", "libXrandr", "libXinerama", "libXcursor", "libXi" }, // fedora/rhel
    .{ "libx11", "libxrandr", "libxinerama", "libxcursor", "libxi" }, // arch
    .{ "libX11-6", "libXrandr2", "libXinerama1", "libXcursor1", "libXi6" }, // opensuse
};
const server_package = [_][]const u8{ "xwayland", "xorg-x11-server-Xwayland", "xorg-xwayland", "xwayland" };
const installer = [_][]const u8{ "sudo apt install", "sudo dnf install", "sudo pacman -S", "sudo zypper install" };

pub const Env = struct {
    user: ?[]const u8 = null, // MDB2SQL_DISPLAY (x11 | wayland), escolha do usuario
    display: ?[]const u8 = null, // DISPLAY
    wayland_display: ?[]const u8 = null, // WAYLAND_DISPLAY; definido e vazio = o usuario desligou o Wayland
};

pub const Backend = enum { x11, wayland };

pub const Decision = struct {
    backend: Backend,
    fallback: ?Backend = null, // se o primeiro nao abrir
    warn: bool = false, // Wayland por reserva: avisar na abertura
    user_set: bool = false,
};

// !T: The decision. missing = X11 libraries that failed to load (only looked at when DISPLAY is set).
pub fn decide(env: Env, missing: []const []const u8) Decision {
    if (env.user) |u| {
        if (std.ascii.eqlIgnoreCase(u, "wayland")) return .{ .backend = .wayland, .user_set = true };
        if (std.ascii.eqlIgnoreCase(u, "x11")) return .{ .backend = .x11, .user_set = true };
    }
    // WAYLAND_DISPLAY definido e vazio: o usuario tirou o Wayland; so X11, sem aviso
    if (env.wayland_display) |w| if (w.len == 0) return .{ .backend = .x11, .user_set = true };
    const has_display = if (env.display) |d| d.len > 0 else false;
    if (has_display and missing.len == 0) return .{ .backend = .x11, .fallback = .wayland };
    return .{ .backend = .wayland, .warn = true };
}

pub fn family(os_release: []const u8) Family {
    const id = field(os_release, "ID");
    const like = field(os_release, "ID_LIKE");
    const pairs = [_]struct { []const u8, Family }{
        .{ "debian", .debian }, .{ "ubuntu", .debian }, .{ "fedora", .fedora },     .{ "rhel", .fedora },
        .{ "centos", .fedora }, .{ "arch", .arch },     .{ "opensuse", .opensuse }, .{ "suse", .opensuse },
    };
    for ([_][]const u8{ id, like }) |s| {
        var words = std.mem.tokenizeScalar(u8, s, ' ');
        while (words.next()) |w| for (pairs) |p| {
            if (std.ascii.eqlIgnoreCase(w, p[0]) or std.mem.startsWith(u8, w, p[0])) return p[1];
        };
    }
    return .other;
}

// Valor de CHAVE=valor do os-release, sem aspas; "" se nao houver
pub fn field(os_release: []const u8, key: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, os_release, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > key.len and std.mem.startsWith(u8, line, key) and line[key.len] == '=')
            return std.mem.trim(u8, line[key.len + 1 ..], "\"'");
    }
    return "";
}

// Texto do aviso no idioma atual. no_server = DISPLAY ausente; missing = bibliotecas que nao carregaram
pub fn warning(buf: []u8, os_release: []const u8, no_server: bool, missing: []const []const u8) []const u8 {
    var what_buf: [256]u8 = undefined;
    var what: std.Io.Writer = .fixed(&what_buf);
    var pkgs_buf: [256]u8 = undefined;
    var pkgs: std.Io.Writer = .fixed(&pkgs_buf);
    const fam = family(os_release);
    if (no_server) {
        what.writeAll(i18n.tr("display_no_server")) catch {};
        if (fam != .other) pkgs.print(" {s}", .{server_package[@backingInt(fam)]}) catch {};
    }
    for (missing) |lib| {
        if (what.end > 0) what.writeAll(", ") catch {};
        what.writeAll(lib) catch {};
        if (fam == .other) continue;
        for (x11_libs, 0..) |l, i| if (std.mem.eql(u8, l, lib)) pkgs.print(" {s}", .{packages[@backingInt(fam)][i]}) catch {};
    }
    if (fam == .other or pkgs.end == 0)
        return i18n.fmt(buf, "display_warning_other", .{ what.buffered(), help_url });
    var cmd_buf: [320]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "{s}{s}", .{ installer[@backingInt(fam)], pkgs.buffered() }) catch "";
    var name = field(os_release, "PRETTY_NAME");
    if (name.len == 0) name = field(os_release, "NAME");
    return i18n.fmt(buf, "display_warning", .{ what.buffered(), name, cmd, help_url });
}

// -------------------------------------------------------------------- tests

const t = std.testing;

const debian_os = "PRETTY_NAME=\"Debian GNU/Linux 13 (trixie)\"\nNAME=\"Debian GNU/Linux\"\nID=debian\n";
const ubuntu_os = "PRETTY_NAME=\"Ubuntu 24.04.3 LTS\"\nID=ubuntu\nID_LIKE=debian\n";
const fedora_os = "NAME=\"Fedora Linux\"\nID=fedora\nPRETTY_NAME=\"Fedora Linux 43 (Workstation Edition)\"\n";
const arch_os = "NAME=\"Arch Linux\"\nPRETTY_NAME=\"Arch Linux\"\nID=arch\n";
const suse_os = "NAME=\"openSUSE Tumbleweed\"\nID=\"opensuse-tumbleweed\"\nID_LIKE=\"opensuse suse\"\nPRETTY_NAME=\"openSUSE Tumbleweed\"\n";
const void_os = "NAME=\"Void\"\nID=\"void\"\nPRETTY_NAME=\"Void Linux\"\n";

test "display decision: user variable, X11 first, Wayland fallback with warning" {
    // variavel do usuario manda, sem aviso
    try t.expectEqual(Decision{ .backend = .wayland, .user_set = true }, decide(.{ .user = "wayland", .display = ":0" }, &.{}));
    try t.expectEqual(Decision{ .backend = .x11, .user_set = true }, decide(.{ .user = "X11" }, &.{"libXi.so.6"}));
    try t.expectEqual(Decision{ .backend = .x11, .user_set = true }, decide(.{ .display = ":0", .wayland_display = "" }, &.{}));
    // X11 inteiro: X11, com o Wayland so se o X11 nao abrir
    try t.expectEqual(Decision{ .backend = .x11, .fallback = .wayland }, decide(.{ .display = ":0", .wayland_display = "wayland-0" }, &.{}));
    // sem DISPLAY ou com biblioteca faltando: Wayland e aviso
    try t.expectEqual(Decision{ .backend = .wayland, .warn = true }, decide(.{ .wayland_display = "wayland-0" }, &.{}));
    try t.expectEqual(Decision{ .backend = .wayland, .warn = true }, decide(.{ .display = "" }, &.{}));
    try t.expectEqual(Decision{ .backend = .wayland, .warn = true }, decide(.{ .display = ":0" }, &.{"libXcursor.so.1"}));
    // valor desconhecido na variavel do usuario: decisao normal
    try t.expectEqual(Decision{ .backend = .x11, .fallback = .wayland }, decide(.{ .user = "mir", .display = ":1" }, &.{}));
}

test "display warning text per distro family, with the install command and the help link" {
    defer i18n.lang = .en;
    i18n.lang = .en;
    var b: [1024]u8 = undefined;
    try t.expectEqual(.debian, family(debian_os));
    try t.expectEqual(.debian, family(ubuntu_os));
    try t.expectEqual(.fedora, family(fedora_os));
    try t.expectEqual(.arch, family(arch_os));
    try t.expectEqual(.opensuse, family(suse_os));
    try t.expectEqual(.other, family(void_os));
    try t.expectEqualStrings("Debian GNU/Linux 13 (trixie)", field(debian_os, "PRETTY_NAME"));

    try t.expectEqualStrings("X11 unavailable; the program is using Wayland (fallback). Missing: X server (DISPLAY not set). " ++
        "To use X11 on Debian GNU/Linux 13 (trixie): sudo apt install xwayland. Help: " ++ help_url, warning(&b, debian_os, true, &.{}));
    try t.expectEqualStrings("X11 unavailable; the program is using Wayland (fallback). Missing: libXcursor.so.1, libXi.so.6. " ++
        "To use X11 on Ubuntu 24.04.3 LTS: sudo apt install libxcursor1 libxi6. Help: " ++ help_url, warning(&b, ubuntu_os, false, &.{ "libXcursor.so.1", "libXi.so.6" }));
    try t.expect(std.mem.indexOf(u8, warning(&b, fedora_os, true, &.{"libX11.so.6"}), "sudo dnf install xorg-x11-server-Xwayland libX11.") != null);
    try t.expect(std.mem.indexOf(u8, warning(&b, arch_os, true, &.{}), "on Arch Linux: sudo pacman -S xorg-xwayland.") != null);
    try t.expect(std.mem.indexOf(u8, warning(&b, suse_os, false, &.{"libXrandr.so.2"}), "sudo zypper install libXrandr2.") != null);
    // distro desconhecida: so o que falta, sem comando
    try t.expectEqualStrings("X11 unavailable; the program is using Wayland (fallback). Missing: X server (DISPLAY not set), libX11.so.6. Help: " ++ help_url, warning(&b, void_os, true, &.{"libX11.so.6"}));
    try t.expect(std.mem.indexOf(u8, warning(&b, "", true, &.{}), "sudo") == null);
    // traduzido
    i18n.lang = .pt_br;
    try t.expect(std.mem.startsWith(u8, warning(&b, debian_os, true, &.{}), "X11 indisponível; o programa está usando Wayland (reserva). Falta: servidor X (DISPLAY não definido)."));
    i18n.lang = .es;
    try t.expect(std.mem.indexOf(u8, warning(&b, debian_os, true, &.{}), "Ayuda: ") != null);
    for (catalogsHaveNoEllipsis()) |ok| try t.expect(ok);
}

fn catalogsHaveNoEllipsis() [3]bool {
    var out: [3]bool = undefined;
    inline for (i18n.catalogs, 0..) |C, i| {
        out[i] = std.mem.indexOf(u8, C.display_warning, "...") == null and std.mem.indexOf(u8, C.display_warning_other, "...") == null;
    }
    return out;
}
