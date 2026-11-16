//! tmtest - print planZ's dates: tmtime, the formats, tmnorm, tmparse
//! and ctime over fixed and generated times in the zones given, for
//! comparison with 9front's libc, which tools/tmtest.c runs over the
//! same tables with the same output.  See tools/tmtest.c; the tables
//! here are copied from it.
//!
//! Not part of 9front.

const std = @import("std");
const libc = @import("libc");

var bout: libc.Biobuf = .{};
var rng: u64 = 0x9e3779b97f4a7c15;

fn next() u64 {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}

const times = [_]i64{
    0, -1, 1, 86399, 86400, -86400,
    -86401, 951782400, 951868800, 1078012800, 1078099200, 946684799,
    946684800, 978307200, 4107542400, 2147483647, 2147483648, -2147483648,
    -2147483649, 1741514400, 1741539600, 1741539601, 1762070400, 1762095600,
    1762095601, 1743865200, 1743868800, 1759593600, 1763259907, 4102444800,
    32503680000, 253402300799, -2208988800, -11644473600, -62135596800, -62135596801,
    -62167219200, -62198755200,
};

const fmts = [_]?[]const u8{
    null,
    "Y YY YYYY",
    "M MM MMM MMMM",
    "D DD Do",
    "W WW WWW",
    "h hh H HH m mm s ss a A",
    "t tt ttt u uu uuu uuuu",
    "n nn nnn nnnn nnnnn nnnnnn",
    "z Z ZZ ZZZ",
    "__D|__s|___MMM|__YY|____Z|_____ZZ|______ZZZ|__W|___a",
    "_t|__tt|____ttt|_u|___uu|____uuu|_______uuuu|__________nnnnnn",
    "[at] hh [o'clock] [[x\\]] [a[b]c]",
    "YYYY-MM-DDThh:mm:ssZZ",
    "?W ?M ?D",
    "x,y.z; é 1234567890",
    "YYY",
    "ab MMMMM cd",
    "DDD",
    "zz",
    "ZZZZ|",
    "WWWW",
    "hhh",
    "oo",
    "[unclosed",
    "aa",
};

const Parse = struct { []const u8, []const u8 };

const parses = [_]Parse{
    .{ "YYYY-MM-DD hh:mm:ss", "2025-11-16 02:25:07" },
    .{ "YYYY-MM-DD hh:mm:ss", "   2025-11-16 02:25:07 and more" },
    .{ "?WW ?MMM ?D hh:mm:ss ?Z YYYY", "Sunday nov 16 02:25:07 +0100 2025" },
    .{ "WW MMM _D hh:mm:ss ZZZ YYYY", "Sun Nov 16 02:25:07 GMT 2025" },
    .{ "WW MMM _D hh:mm:ss ZZZ YYYY", "Sun Nov  6 02:25:07 EST 2025" },
    .{ "WW MMM _D hh:mm:ss ZZZ YYYY", "Sun Jul  6 02:25:07 PDT 2025" },
    .{ "WW MMM _D hh:mm:ss ZZZ YYYY", "Sun Jul  6 02:25:07 XYZ 2025" },
    .{ "WW MMM _D hh:mm:ss ?Z YYYY", "Sun Jul  6 02:25:07 XYZ 2025" },
    .{ "WW MMM _D hh:mm:ss ?Z YYYY", "Sun Jul  6 02:25:07 ABCDEFGHIJKLMNO 2025" },
    .{ "WW MMM _D hh:mm:ss ?Z YYYY", "Sun Jul  6 02:25:07 AB 2025" },
    .{ "YYYY/M/D h:mm a", "2025/3/9 12:05 am" },
    .{ "YYYY/M/D h:mm a", "2025/3/9 12:05 PM" },
    .{ "YYYY/M/D h:mm A", "2025/3/9 1:05 pm" },
    .{ "YYYY/M/D h:mm a", "2025/3/9 13:05 pm" },
    .{ "~YYYY/M/D h:mm a", "2025/3/9 13:05 pm" },
    .{ "YYYY/M/D h:mm a", "2025/3/9 0:05 xm" },
    .{ "YYYY Z", "2025 +0530" },
    .{ "YYYY Z", "2025 -1400" },
    .{ "YYYY Z", "2025 +0560" },
    .{ "YYYY Z", "2025 +053" },
    .{ "YYYY ZZ", "2025 -05:30" },
    .{ "YYYY ZZ", "2025 +5:61" },
    .{ "YYYY ZZ", "2025 0530" },
    .{ "YYYY ?Z", "2025 +05:30" },
    .{ "YYYY ?Z", "2025 -0800" },
    .{ "YYYY ?Z", "2025 Z" },
    .{ "YYYY ZZZ", "2025 Z" },
    .{ "YYYY ZZZ", "2025 n" },
    .{ "YYYY ZZZ", "2025 UTC" },
    .{ "YYYY ZZZ", "2025 ut" },
    .{ "YYYY ZZZ", "2025 +0100" },
    .{ "YYYY ZZZZ", "2025 GMT" },
    .{ "YYYY zz", "2025 GMT" },
    .{ "YYYY z", "2025 +0200" },
    .{ "YY M D", "25 3 9" },
    .{ "Y", "1999" },
    .{ "?Y", "99" },
    .{ "?Y", "1999" },
    .{ "YYY", "2025" },
    .{ "MMMM D, YYYY", "March 9, 2025" },
    .{ "MMMM D, YYYY", "marc 9, 2025" },
    .{ "MMM D,YYYY", "mar   9 ,, 2025" },
    .{ "?M/D/YYYY", "March/9/2025" },
    .{ "?M/D/YYYY", "Mar/9/2025" },
    .{ "?M/D/YYYY", "3/9/2025" },
    .{ "Do MMM", "9th Mar" },
    .{ "Do MMM", "9 Mar" },
    .{ "W WW WWW", "2 Mon Monday" },
    .{ "?W", "tue" },
    .{ "?W", "3" },
    .{ "W", "9" },
    .{ "hh:mm:ss.ttt", "23:59:60.999" },
    .{ "hh:mm:ss.uuuu", "23:59:59.123456" },
    .{ "hh:mm:ss.nnnnnn", "01:02:03.123456789" },
    .{ "hh:mm:ss.?n", "01:02:03.5" },
    .{ "hh:mm", "24:00" },
    .{ "hh:mm", "25:00" },
    .{ "hh:mm", "12:60" },
    .{ "~hh:mm", "25:61" },
    .{ "YYYY-MM-DD", "2025-13-01" },
    .{ "~YYYY-MM-DD", "2025-13-01" },
    .{ "YYYY-MM-DD", "2025-02-29" },
    .{ "YYYY-MM-DD", "2024-02-29" },
    .{ "YYYY-MM-DD", "2025-02-00" },
    .{ "YYYY-MM-DD", "2025-00-10" },
    .{ "~YYYY-MM-DD", "2025-00-00" },
    .{ "YYYY-MM-DD", "2025-1-1" },
    .{ "YYYY-MM-DD", "25-01-01" },
    .{ "YYYY-MM-DD", "" },
    .{ "", "" },
    .{ "", "x" },
    .{ "[date:] YYYY", "date: 2025" },
    .{ "[date:] YYYY", "data: 2025" },
    .{ "[a[b]c\\]d] YYYY", "a[b]c]d 2025" },
    .{ "[open YYYY", "open 2025" },
    .{ "YYYY_MM", "2025 03" },
    .{ "YYYY MM", "2025,\t03" },
    .{ "YYYY MM", "2025x03" },
    .{ "DDD", "123" },
    .{ "hhh", "123" },
    .{ "q", "q" },
    .{ "q", "r" },
    .{ "YYYY-MM-DD hh:mm", "2025-07-04 12:00" },
    .{ "YYYY-MM-DD hh:mm", "2025-01-04 12:00" },
    .{ "YYYY-MM-DD hh:mm", "2025-03-09 02:30" },
    .{ "YYYY-MM-DD hh:mm", "2025-11-02 01:30" },
    .{ "YYYY-MM-DD hh:mm ZZZ", "2025-11-02 01:30 MST" },
    .{ "YYYY-MM-DD hh:mm ZZZ", "2025-07-04 12:00 EDT" },
    .{ "YYYY-MM-DD hh:mm Z", "2025-07-04 12:00 +0000" },
};

fn pr(comptime format: []const u8, args: anytype) void {
    bout.print(format, args) catch libc.sysfatal("write: %r", .{});
}

fn show(tm: *const libc.Tm) void {
    pr("%d %d:%d:%d.%d %d/%d/%d w%d y%d [%s] %d", .{
        tm.year, tm.hour, tm.min,  tm.sec,  tm.nsec,
        tm.mday, tm.mon,  tm.year, tm.wday, tm.yday,
        tm.zone(), tm.tzoff,
    });
}

/// snprint(buf, n, "%τ", tmfmt(tm, format)): what was printed before a
/// garbled format stays.
fn stamp(buf: []u8, tm: *const libc.Tm, format: ?[]const u8) []const u8 {
    var f: libc.fmt.Fmt = .{ .buf = buf[0 .. buf.len - 1] };
    libc.tmfmt(&f, tm, format) catch {};
    return buf[0..f.n];
}

pub fn main(argv: []const []const u8) void {
    var buf: [256]u8 = undefined;
    var tm: libc.Tm = .{};

    bout.init(1, libc.OWRITE);
    for (argv[1..]) |arg| {
        var tz: ?*const libc.Tzone = null;
        if (!std.mem.eql(u8, arg, "nil")) {
            tz = libc.tzload(arg) orelse {
                pr("zone %s: %r\n", .{arg});
                continue;
            };
        }
        pr("zone %s\n", .{arg});
        for (times, 0..) |t, i| {
            tm = .{};
            libc.tmtimens(&tm, t, @intCast(i * 1001001), tz);
            pr("time %lld: ", .{t});
            show(&tm);
            pr("\n", .{});
            for (fmts) |f|
                pr("\t%s|%s|\n", .{ f orelse "nil", stamp(&buf, &tm, f) });
            pr("\tasctime %s", .{libc.asctime(&tm)});
            const n = libc.tmnorm(&tm);
            pr("\tnorm %lld ", .{n});
            show(&tm);
            pr("\n", .{});
        }
        for (parses) |p| {
            tm = .{};
            pr("parse %s|%s|: ", .{ p[0], p[1] });
            const end = libc.tmparse(&tm, p[0], p[1], tz) catch {
                pr("%r\n", .{});
                continue;
            };
            show(&tm);
            pr(" end %d", .{end});
            const n = libc.tmnorm(&tm);
            pr(" norm %lld ", .{n});
            show(&tm);
            pr("\n", .{});
        }
        for (0..3000) |i| {
            var t: i64 = @as(i64, @bitCast(next())) >> 30;
            if (i % 3 == 0)
                t = @intCast(next() >> 33);
            tm = .{};
            libc.tmtime(&tm, t, tz);
            pr("%lld: ", .{t});
            show(&tm);
            const s = stamp(&buf, &tm, "YYYY-MM-DD WWW hh:mm:ss ZZ ZZZ");
            pr(" %s %lld\n", .{ s, libc.tmnorm(&tm) });
        }
    }
    // ctime and localtime, which take a long
    pr("ctime %s", .{libc.ctime(0)});
    pr("ctime %s", .{libc.ctime(1763259907)});
    pr("ctime %s", .{libc.ctime(-1)});
    pr("ctime %s", .{libc.ctime(0x7fffffff)});
    tm = libc.localtime(1751652000);
    show(&tm);
    pr("\n", .{});
    tm = libc.gmtime(1751652000);
    show(&tm);
    pr("\n", .{});
    bout.term() catch {};
    libc.exits(null);
}
