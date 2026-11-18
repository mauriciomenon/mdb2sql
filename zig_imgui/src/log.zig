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
