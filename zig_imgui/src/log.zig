// Mensagens da sessao (hora + texto), mostradas na janela Log e copiaveis
// !T: Session log: "HH:MM:SS text" lines kept in one buffer (the Log window shows and copies it)

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const max_bytes = 256 * 1024; // passou disso, as linhas mais antigas saem

pub const Log = struct {
    text: std.ArrayList(u8) = .empty, // linhas terminadas em \n, mais um 0 no fim (o ImGui le como texto C)

    pub fn deinit(l: *Log, gpa: Allocator) void {
        l.text.deinit(gpa);
    }

    // Texto sem o 0 final
    pub fn slice(l: *const Log) []const u8 {
        return if (l.text.items.len == 0) "" else l.text.items[0 .. l.text.items.len - 1];
    }

    // Uma linha "HH:MM:SS texto"; quebras de linha do texto viram espacos (uma mensagem = uma linha)
    pub fn add(l: *Log, gpa: Allocator, hms: []const u8, msg: []const u8) void {
        if (l.text.items.len > 0) l.text.items.len -= 1; // tira o 0
        defer l.text.append(gpa, 0) catch {};
        const need = hms.len + 1 + msg.len + 1;
        l.text.ensureUnusedCapacity(gpa, need + 1) catch return;
        l.text.appendSliceAssumeCapacity(hms);
        l.text.appendAssumeCapacity(' ');
        for (msg) |ch| l.text.appendAssumeCapacity(if (ch == '\n' or ch == '\r') ' ' else ch);
        l.text.appendAssumeCapacity('\n');
        if (l.text.items.len > max_bytes) {
            // corta na quebra de linha mais perto da metade
            const half = l.text.items.len / 2;
            const cut = (std.mem.indexOfScalarPos(u8, l.text.items, half, '\n') orelse half) + 1;
            std.mem.copyForwards(u8, l.text.items, l.text.items[cut..]);
            l.text.items.len -= cut;
        }
    }

    pub fn clear(l: *Log) void {
        l.text.clearRetainingCapacity();
    }
};

pub const Level = enum { info, warn, err };

// !T: What the status bar shows while the Log is collapsed: the last unread error, else the last unread warning (a
// warning never hides an unread error), and the unread counts. Errors of the SQL tab are marked: a later successful
// run takes them off the bar (the log keeps them).
pub const Alert = struct {
    level: Level = .info,
    buf: [1024]u8 = undefined,
    len: usize = 0,
    unread_err: u32 = 0,
    unread_warn: u32 = 0,
    sql_err: u32 = 0, // dos erros nao lidos, os da aba SQL
    from_sql: bool = false, // o texto atual e um erro da aba SQL

    pub fn add(a: *Alert, level: Level, s: []const u8, from_sql: bool) void {
        if (level == .info) return;
        if (level == .err) {
            a.unread_err += 1;
            if (from_sql) a.sql_err += 1;
        } else a.unread_warn += 1;
        if (level == .warn and a.unread_err > 0) return;
        a.level = level;
        a.from_sql = from_sql and level == .err;
        a.len = @min(s.len, a.buf.len);
        @memcpy(a.buf[0..a.len], s[0..a.len]);
        for (a.buf[0..a.len]) |*ch| if (ch.* == '\n' or ch.* == '\r') {
            ch.* = ' '; // uma linha na barra
        };
    }

    pub fn text(a: *const Alert) []const u8 {
        return a.buf[0..a.len];
    }

    pub fn unread(a: *const Alert) u32 {
        return a.unread_err + a.unread_warn;
    }

    // Log aberto: tudo esta a vista
    pub fn markRead(a: *Alert) void {
        a.unread_err = 0;
        a.unread_warn = 0;
        a.sql_err = 0;
    }

    // SQL rodado com sucesso: os erros do SQL anterior saem da barra e da contagem
    pub fn clearSql(a: *Alert) void {
        a.unread_err -|= a.sql_err;
        a.sql_err = 0;
        if (!a.from_sql) return;
        a.from_sql = false;
        a.len = 0;
        a.level = .info;
    }
};

// Hora local "HH:MM:SS"
pub fn localTime(buf: *[8]u8) []const u8 {
    var h: u32 = 0;
    var m: u32 = 0;
    var s: u32 = 0;
    if (builtin.os.tag == .windows) {
        var st: SYSTEMTIME = undefined;
        GetLocalTime(&st);
        h = st.hour;
        m = st.minute;
        s = st.second;
    } else {
        const now = time(null);
        var tm: Tm = undefined;
        if (localtime_r(&now, &tm) != null) {
            h = @intCast(tm.hour);
            m = @intCast(tm.min);
            s = @intCast(tm.sec);
        }
    }
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch buf;
}

const SYSTEMTIME = extern struct { year: u16, month: u16, day_of_week: u16, day: u16, hour: u16, minute: u16, second: u16, ms: u16 };
extern "kernel32" fn GetLocalTime(st: *SYSTEMTIME) callconv(.winapi) void;
// struct tm do C: os campos usados vem primeiro; o resto (tm_gmtoff, tm_zone da glibc) fica no espaco de sobra
const Tm = extern struct { sec: c_int, min: c_int, hour: c_int, mday: c_int, mon: c_int, year: c_int, wday: c_int, yday: c_int, isdst: c_int, rest: [4]usize };
extern "c" fn time(t: ?*c_long) c_long;
extern "c" fn localtime_r(t: *const c_long, out: *Tm) ?*Tm;

const t = std.testing;

test "status bar alert: last error wins over warnings; a successful SQL run clears its own errors only" {
    var a: Alert = .{};
    a.add(.info, "Loaded", false);
    try t.expectEqual(0, a.unread());
    a.add(.warn, "aviso", false);
    try t.expectEqualStrings("aviso", a.text());
    a.add(.err, "Erro na consulta SQL: syntax error", true);
    a.add(.warn, "outro aviso", false); // nao esconde o erro
    try t.expectEqualStrings("Erro na consulta SQL: syntax error", a.text());
    try t.expectEqual(3, a.unread());
    // SQL certo depois: o erro do SQL sai da barra e da contagem; os avisos continuam contados
    a.clearSql();
    try t.expectEqualStrings("", a.text());
    try t.expectEqual(2, a.unread());
    // erro de outra origem nao e apagado por um SQL certo
    a.add(.err, "Erro no banco: x", false);
    a.clearSql();
    try t.expectEqualStrings("Erro no banco: x", a.text());
    try t.expectEqual(3, a.unread());
    a.markRead();
    try t.expectEqual(0, a.unread());
    a.add(.err, "linha 1\nlinha 2", true);
    try t.expectEqualStrings("linha 1 linha 2", a.text());
}

test "log lines carry the time, stay one line each and drop the oldest past the limit" {
    var l: Log = .{};
    defer l.deinit(t.allocator);
    try t.expectEqualStrings("", l.slice());
    l.add(t.allocator, "10:00:00", "Loaded: DB4.accdb");
    l.add(t.allocator, "10:00:01", "two\r\nlines");
    try t.expectEqualStrings("10:00:00 Loaded: DB4.accdb\n10:00:01 two  lines\n", l.slice());
    try t.expectEqual(0, l.text.items[l.text.items.len - 1]); // texto C para o ImGui
    const long: [1000]u8 = @splat('x');
    for (0..400) |_| l.add(t.allocator, "10:00:02", &long);
    try t.expect(l.text.items.len <= max_bytes + 1100);
    try t.expect(std.mem.startsWith(u8, l.slice(), "10:00:02 x")); // as primeiras sairam, inteiras
    l.clear();
    try t.expectEqualStrings("", l.slice());
    var b: [8]u8 = undefined;
    const now = localTime(&b);
    try t.expectEqual(8, now.len);
    try t.expectEqual(':', now[2]);
}
