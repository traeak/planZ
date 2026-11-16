//! Dates and times: the calendar, time zones, formatting and parsing.
//! from libc/port/date.c
//!
//! This file takes nothing from the system, so the host tests run it:
//! date.zig reads the zone files and the clock.
//!
//! DIFF:
//!   - Strings are slices.  The C's char arrays in Tm and Tzone stay
//!     arrays that end at their first 0 (zone(), and name()): tmparse's
//!     fuzzy zone names depend on what was in the array before.
//!   - The format is not a print verb's argument (the C's %τ with a
//!     Tmfmt): tmfmt() writes into a Fmt and returns error.Garbled
//!     where the C's verb returns -1, after which print writes
//!     nothing.  Tmfmt has fmt9 for use in a print, where a garbled
//!     format prints what came before it.
//!   - Errors are Zig errors; the C's werrstr text is in errstr().
//!   - The lock around the zones (zlock) is date.zig's, which keeps
//!     them.
//!   - loadzone() is split: parsezone() takes the file's text.
//!   - A month or week day out of range prints as nothing where the C
//!     reads past its tables.
//!
//! Fixed from C (read, each needs a format that ends early; not shown
//! against stock):
//!   - a format ending in '_', and tmparse's ending in '?', made the C
//!     read on past the format's 0;
//!   - "[...\" with nothing after the backslash did the same.
//!
//! Kept from C:
//!   - tmfill counts the leap day into yday from February 1st on, not
//!     from March 1st (m > 1).
//!   - tmparse writes the zone of "+hh:mm" as hour, "02:", minutes
//!     ("%c%d02:%02d").

const std = @import("std");
const fmt = @import("fmt");

pub const Tzsize = 150;
const Nsec = 1000 * 1000 * 1000;
const Daysec: i64 = 24 * 3600;
const Days400y = 365 * 400 + 4 * 25 - 3;
const Days4y = 365 * 4 + 1;

pub const Ctimefmt = "WW MMM _D hh:mm:ss ZZZ YYYY";

pub const Error = error{ BadZone, Garbled, BadDate };

pub const Tzone = struct {
    tzname: [32]u8 = @splat(0),
    stname: [16]u8 = @splat(0),
    dlname: [16]u8 = @splat(0),
    stdiff: i32 = 0,
    dldiff: i32 = 0,
    dlpairs: [Tzsize]i32 = @splat(0),
};

pub const Tm = struct {
    nsec: i32 = 0, // nseconds (range 0...1e9)
    sec: i32 = 0, // seconds (range 0..60)
    min: i32 = 0, // minutes (0..59)
    hour: i32 = 0, // hours (0..23)
    mday: i32 = 0, // day of the month (1..31)
    mon: i32 = 0, // month of the year (0..11)
    year: i32 = 0, // year A.D.
    wday: i32 = 0, // day of week (0..6, Sunday = 0)
    yday: i32 = 0, // day of year (0..365)
    zonebuf: [16]u8 = @splat(0), // time zone name
    tzoff: i32 = 0, // time zone delta from GMT
    tz: ?*const Tzone = null, // time zone associated with this date

    pub fn zone(tm: *const Tm) []const u8 {
        return name(&tm.zonebuf);
    }
};

/// A char array's string: up to its first 0.
pub fn name(a: []const u8) []const u8 {
    return a[0 .. std.mem.findScalar(u8, a, 0) orelse a.len];
}

/// snprint(a, sizeof a, "%s", s)
fn setname(a: []u8, s: []const u8) void {
    const n = @min(s.len, a.len - 1);
    @memcpy(a[0..n], s[0..n]);
    a[n] = 0;
}

// The C's werrstr: the text goes to errhook if there is one (date.zig
// gives the process's error string), and is kept for errstr() if not
// (the host tests; one process).
pub var errhook: ?*const fn ([]const u8) void = null;
var errbuf: [192]u8 = undefined;
var errlen: usize = 0;

pub fn errstr() []const u8 {
    return errbuf[0..errlen];
}

fn werrstr(comptime format: []const u8, args: anytype) void {
    if (errhook) |h| {
        var buf: [192]u8 = undefined;
        h(fmt.snprint(&buf, format, args));
        return;
    }
    errlen = fmt.snprint(&errbuf, format, args).len;
}

const mdays = [12]i32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
const wday = [_][]const u8{
    "Sunday",    "Monday",   "Tuesday",
    "Wednesday", "Thursday", "Friday",
    "Saturday",
};
const month = [_][]const u8{
    "January",   "February", "March",
    "April",     "May",      "June",
    "July",      "August",   "September",
    "October",   "November", "December",
};

const Tzabbrev = struct { abbr: []const u8, name: []const u8 };
const Tzoffpair = struct { abbr: []const u8, off: i32 };

// Obsolete time zone names. Hardcoded to match RFC5322
const tzabbrev = [_]Tzabbrev{
    .{ .abbr = "UT", .name = "GMT" },         .{ .abbr = "GMT", .name = "GMT" },         .{ .abbr = "UTC", .name = "GMT" },
    .{ .abbr = "EST", .name = "US_Eastern" }, .{ .abbr = "EDT", .name = "US_Eastern" },
    .{ .abbr = "CST", .name = "US_Central" }, .{ .abbr = "CDT", .name = "US_Central" },
    .{ .abbr = "MST", .name = "US_Mountain" }, .{ .abbr = "MDT", .name = "US_Mountain" },
    .{ .abbr = "PST", .name = "US_Pacific" }, .{ .abbr = "PDT", .name = "US_Pacific" },
};

// Military timezone names
const milabbrev = [_]Tzoffpair{
    .{ .abbr = "A", .off = -1 * 3600 },  .{ .abbr = "B", .off = -2 * 3600 },  .{ .abbr = "C", .off = -3 * 3600 },
    .{ .abbr = "D", .off = -4 * 3600 },  .{ .abbr = "E", .off = -5 * 3600 },  .{ .abbr = "F", .off = -6 * 3600 },
    .{ .abbr = "G", .off = -7 * 3600 },  .{ .abbr = "H", .off = -8 * 3600 },  .{ .abbr = "I", .off = -9 * 3600 },
    .{ .abbr = "K", .off = -10 * 3600 }, .{ .abbr = "L", .off = -11 * 3600 }, .{ .abbr = "M", .off = -12 * 3600 },
    .{ .abbr = "N", .off = 1 * 3600 },   .{ .abbr = "O", .off = 2 * 3600 },   .{ .abbr = "P", .off = 3 * 3600 },
    .{ .abbr = "Q", .off = 4 * 3600 },   .{ .abbr = "R", .off = 5 * 3600 },   .{ .abbr = "S", .off = 6 * 3600 },
    .{ .abbr = "T", .off = 7 * 3600 },   .{ .abbr = "U", .off = 8 * 3600 },   .{ .abbr = "V", .off = 9 * 3600 },
    .{ .abbr = "W", .off = 10 * 3600 },  .{ .abbr = "X", .off = 11 * 3600 },  .{ .abbr = "Y", .off = 12 * 3600 },
    .{ .abbr = "Z", .off = 0 },
};

fn mod(a: i64, b: i64) i64 {
    var r = @rem(a, b);
    if (r < 0)
        r += b;
    return r;
}

fn isleap(y: i64) bool {
    return @rem(y, 4) == 0 and (@rem(y, 100) != 0 or @rem(y, 400) == 0);
}

fn isalpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// A string read as the C reads one: 0 at its end and after.
const Str = struct {
    s: []const u8,
    i: usize = 0,

    fn at(p: *const Str, off: usize) u8 {
        return if (p.i + off < p.s.len) p.s[p.i + off] else 0;
    }
    fn cur(p: *const Str) u8 {
        return p.at(0);
    }
    fn next(p: *Str) u8 {
        const c = p.cur();
        p.i += 1;
        return c;
    }
    fn rest(p: *const Str) []const u8 {
        return if (p.i < p.s.len) p.s[p.i..] else "";
    }
};

fn rdname(f: *Str, out: []u8) error{BadZone}!void {
    const n = out.len;
    while (f.cur() != 0) : (f.i += 1) {
        const c = f.cur();
        if (c != ' ' and c != '\t' and c != '\n')
            break;
    }
    var k: usize = 0;
    while (f.cur() != 0 and k != n) : (f.i += 1) {
        const c = f.cur();
        if (c == ' ' or c == '\t' or c == '\n')
            break;
        out[k] = c;
        k += 1;
    }
    // DIFF: the C puts the 0 after a name that fills the array too,
    // one byte past it
    if (k < n)
        out[k] = 0;
    const c = f.cur();
    if (k < 3 or (c != ' ' and c != '\t' and c != '\n')) {
        werrstr("truncated name", .{});
        return error.BadZone;
    }
}

fn rdlong(f: *Str) error{BadZone}!i32 {
    var s = false;
    var c: u8 = 0;
    while (true) {
        c = f.next();
        if (c == 0)
            break;
        if (c == '-')
            s = true
        else if (c != ' ' and c != '\n')
            break;
    }
    if (c == 0)
        return 0;
    var l: i32 = 0;
    while (true) {
        if (c == ' ' or c == '\n')
            break;
        if (c < '0' or c > '9') {
            werrstr("non-number %c in name", .{c});
            return error.BadZone;
        }
        l = l *% 10 +% (c - '0');
        c = f.next();
    }
    if (s)
        l = -%l;
    return l;
}

/// The text of a zone file (/env/timezone, /adm/timezone/name): two
/// names with their differences from GMT in seconds, then the pairs of
/// times between which the second holds.
pub fn parsezone(tz: *Tzone, tzname: []const u8, text: []const u8) error{BadZone}!void {
    tz.* = .{};
    if (tzname.len >= tz.tzname.len) {
        werrstr("timezone name too long", .{});
        return error.BadZone;
    }
    @memcpy(tz.tzname[0..tzname.len], tzname);
    var p: Str = .{ .s = text };
    try rdname(&p, &tz.stname);
    tz.stdiff = try rdlong(&p);
    try rdname(&p, &tz.dlname);
    tz.dldiff = try rdlong(&p);
    for (0..Tzsize) |i| {
        tz.dlpairs[i] = rdlong(&p) catch {
            werrstr("invalid transition time", .{});
            return error.BadZone;
        };
        if (tz.dlpairs[i] == 0)
            return;
    }
    werrstr("invalid timezone %s", .{tzname});
    return error.BadZone;
}

fn tzoffset(tz: ?*const Tzone, abs_: i64, tm: *Tm) void {
    var dl = false;
    const z = tz orelse {
        setname(&tm.zonebuf, "GMT");
        tm.tzoff = 0;
        return;
    };
    const abs = abs_ + z.stdiff;
    var i: usize = 0;
    // the pairs end at a 0, which parsezone always leaves
    while (i < Tzsize and z.dlpairs[i] != 0) : (i += 2) {
        if (abs > z.dlpairs[i] and i + 1 < Tzsize and abs <= z.dlpairs[i + 1]) {
            dl = true;
            break;
        }
    }
    if (dl) {
        setname(&tm.zonebuf, name(&z.dlname));
        tm.tzoff = z.dldiff;
    } else {
        setname(&tm.zonebuf, name(&z.stname));
        tm.tzoff = z.stdiff;
    }
}

fn tmfill(tm: *Tm, abs: i64, nsec: i64) void {
    const zrel = abs + tm.tzoff;
    var t = @rem(zrel, Daysec);
    var e = @divTrunc(zrel, Daysec);
    if (t < 0) {
        t += Daysec;
        e -= 1;
    }

    t += @divTrunc(nsec, Nsec);
    tm.sec = @intCast(mod(t, 60));
    t = @divTrunc(t, 60);
    tm.min = @intCast(mod(t, 60));
    t = @divTrunc(t, 60);
    tm.hour = @intCast(mod(t, 24));
    tm.wday = @intCast(mod(e + 4, 7));

    // Split up year, month, day.
    //
    // Implemented according to "Algorithm 199,
    // conversions between calendar  date and
    // Julian day number", Robert G. Tantzen,
    // Air Force Missile Development
    // Center, Holloman AFB, New Mex.
    //
    // Lots of magic.
    var j = @divTrunc(zrel + 2440588 * Daysec, Daysec) - 1721119;
    var y = @divTrunc(4 * j - 1, Days400y);
    j = 4 * j - 1 - Days400y * y;
    var d = @divTrunc(j, 4);
    j = @divTrunc(4 * d + 3, Days4y);
    d = 4 * d + 3 - Days4y * j;
    d = @divTrunc(d + 4, 4);
    var m = @divTrunc(5 * d - 3, 153);
    d = 5 * d - 3 - 153 * m;
    d = @divTrunc(d + 5, 5);
    y = 100 * y + j;

    if (m < 10)
        m += 3
    else {
        m -= 9;
        y += 1;
    }

    // there's no year 0
    if (y <= 0)
        y -= 1;
    // and if j negative, the day and month are also negative
    if (m < 0)
        m += 12;
    if (d < 0 and m >= 1 and m <= 12)
        d += mdays[@intCast(m - 1)];

    var yday = d - 1;
    var i: i64 = 0;
    while (i < m - 1 and i < 12) : (i += 1)
        yday += mdays[@intCast(i)];
    if (m > 1 and isleap(y))
        yday += 1;
    tm.yday = @truncate(yday);
    tm.year = @truncate(y - 1900);
    tm.mon = @truncate(m - 1);
    tm.mday = @truncate(d);
    tm.nsec = @intCast(mod(nsec, Nsec));
}

pub fn tmtime(tm: *Tm, abs: i64, tz: ?*const Tzone) void {
    tmtimens(tm, abs, 0, tz);
}

pub fn tmtimens(tm: *Tm, abs: i64, ns: i32, tz: ?*const Tzone) void {
    tm.tz = tz;
    tzoffset(tz, abs, tm);
    tmfill(tm, abs, ns);
}

/// The time now, given nsec()'s value.
pub fn tmnowns(tm: *Tm, ns: i64, tz: ?*const Tzone) void {
    tmtimens(tm, @divTrunc(ns, Nsec), @intCast(mod(ns, Nsec)), tz);
}

pub fn tmnorm(tm: *Tm) i64 {
    var m: i64 = undefined;
    var y: i64 = undefined;
    if (tm.mon > 1) {
        m = @as(i64, tm.mon) - 2;
        y = @as(i64, tm.year) + 1900;
    } else {
        m = @as(i64, tm.mon) + 10;
        y = @as(i64, tm.year) + 1899;
    }
    const d: i64 = tm.mday;
    const c = @divTrunc(y, 100);
    const yadj = y - 100 * c;
    const j = @divTrunc(c * Days400y, 4) +
        @divTrunc(Days4y * yadj, 4) +
        @divTrunc(153 * m + 2, 5) + d -
        719469;
    var abs = j * Daysec;
    abs += @as(i64, tm.hour) * 3600;
    abs += @as(i64, tm.min) * 60;
    abs += tm.sec;
    if (tm.tz) |z| {
        tzoffset(z, abs - tm.tzoff, tm);
        tzoffset(z, abs - tm.tzoff, tm);
    }
    abs -= tm.tzoff;
    tmfill(tm, abs, tm.nsec);
    return abs;
}

fn P(pad: i32, w: i32) i32 {
    return if (pad < w) 0 else pad - w;
}

fn tab(t: []const []const u8, i: i32) []const u8 {
    return if (i >= 0 and i < t.len) t[@intCast(i)] else "";
}

/// fmtrune of a char: a byte of the format goes out as it is (a
/// char of 0x80 or more is negative, so less than Runeself).
fn fmtrune(f: *fmt.Fmt, c: u8) void {
    f.putc(c);
}

/// A time and the format to print it in, for a print's argument:
/// print("%τ", .{tmfmtarg(&tm, null)}) with any verb letter.
pub const Tmfmt = struct {
    format: ?[]const u8,
    tm: *const Tm,

    pub fn fmt9(self: Tmfmt, f: *fmt.Fmt) void {
        tmfmt(f, self.tm, self.format) catch {};
    }
};

pub fn tmfmtarg(tm: *const Tm, format: ?[]const u8) Tmfmt {
    return .{ .format = format, .tm = tm };
}

/// Print tm in a format (the C's τconv); null is ctime's.
pub fn tmfmt(f: *fmt.Fmt, tm: *const Tm, format: ?[]const u8) error{Garbled}!void {
    const whole = format orelse Ctimefmt;
    var p: Str = .{ .s = whole };
    while (p.cur() != 0) {
        var w: i32 = 1;
        var pad: i32 = 0;
        while (p.cur() == '_') {
            pad += 1;
            p.i += 1;
        }
        const c0 = p.next();
        // Fixed from C: the format ended in '_'
        if (c0 == 0)
            break;
        while (p.cur() == c0) {
            w += 1;
            p.i += 1;
        }
        pad += w;
        bad: {
            switch (c0) {
                // Ignore '?' so we can share parse and format strings
                '?' => continue,
                'Y' => switch (w) {
                    1 => f.print("%*d", .{ pad, tm.year +% 1900 }),
                    2 => f.print("%*d", .{ pad, @rem(tm.year, 100) }),
                    4 => f.print("%*d", .{ pad, tm.year +% 1900 }),
                    else => break :bad,
                },
                'M' => switch (w) {
                    1 => f.print("%*d", .{ pad, tm.mon +% 1 }),
                    2 => f.print("%*s%02d", .{ pad - 2, "", tm.mon +% 1 }),
                    3 => f.print("%*.3s", .{ pad, tab(&month, tm.mon) }),
                    4 => f.print("%*s", .{ pad, tab(&month, tm.mon) }),
                    else => break :bad,
                },
                'D' => switch (w) {
                    1 => f.print("%*d", .{ pad, tm.mday }),
                    2 => f.print("%*s%02d", .{ pad - 2, "", tm.mday }),
                    else => break :bad,
                },
                'o' => {
                    if (w != 1) break :bad;
                    switch (tm.mday) {
                        1, 21, 31 => f.puts("st"),
                        2, 22 => f.puts("nd"),
                        3, 23 => f.puts("rd"),
                        else => f.puts("th"),
                    }
                },
                'W' => switch (w) {
                    1 => f.print("%*d", .{ pad, tm.wday +% 1 }),
                    2 => f.print("%*.3s", .{ pad, tab(&wday, tm.wday) }),
                    3 => f.print("%*s", .{ pad, tab(&wday, tm.wday) }),
                    else => break :bad,
                },
                'H' => switch (w) {
                    1 => f.print("%*d", .{ pad, @rem(tm.hour, 12) }),
                    2 => f.print("%*s%02d", .{ pad - 2, "", @rem(tm.hour, 12) }),
                    else => break :bad,
                },
                'h' => switch (w) {
                    1 => f.print("%*d", .{ pad, tm.hour }),
                    2 => f.print("%*s%02d", .{ pad - 2, "", tm.hour }),
                    else => break :bad,
                },
                'm' => switch (w) {
                    1 => f.print("%*d", .{ pad, tm.min }),
                    2 => f.print("%*s%02d", .{ pad - 2, "", tm.min }),
                    else => break :bad,
                },
                's' => switch (w) {
                    1 => f.print("%*d", .{ pad, tm.sec }),
                    2 => f.print("%*s%02d", .{ pad - 2, "", tm.sec }),
                    else => break :bad,
                },
                't' => {
                    const v = @divTrunc(tm.nsec, 1000 * 1000);
                    switch (w) {
                        1 => f.print("%*d", .{ pad, @rem(v, 1000) }),
                        2, 3 => f.print("%*s%03d", .{ P(pad, 3), "", @rem(v, 1000) }),
                        else => break :bad,
                    }
                },
                'u' => {
                    const v = @divTrunc(tm.nsec, 1000);
                    switch (w) {
                        1 => f.print("%*d", .{ pad, @rem(v, 1000) }),
                        2 => f.print("%*s%03d", .{ P(pad, 3), "", @rem(v, 1000) }),
                        3 => f.print("%*d", .{ P(pad, 6), v }),
                        4 => f.print("%*s%06d", .{ P(pad, 6), "", v }),
                        else => break :bad,
                    }
                },
                'n' => {
                    const v = tm.nsec;
                    switch (w) {
                        1 => f.print("%*d", .{ pad, @rem(v, 1000) }),
                        2 => f.print("%*s%03d", .{ P(pad, 3), "", @rem(v, 1000) }),
                        3 => f.print("%*d", .{ pad, @rem(v, 1000 * 1000) }),
                        4 => f.print("%*s%06d", .{ P(pad, 6), "", @rem(v, 1000000) }),
                        5 => f.print("%*d", .{ pad, v }),
                        6 => f.print("%*s%09d", .{ P(pad, 9), "", v }),
                        else => break :bad,
                    }
                },
                'z', 'Z' => {
                    if (c0 == 'z' and w != 1)
                        break :bad;
                    const sgn: u8 = if (tm.tzoff < 0) '-' else '+';
                    const off = if (tm.tzoff < 0) -%tm.tzoff else tm.tzoff;
                    const h = @divTrunc(off, 3600);
                    const m = @rem(@divTrunc(off, 60), 60);
                    if (w < 3 and pad < 5)
                        pad = 5;
                    switch (w) {
                        1 => f.print("%*s%c%02d%02d", .{ pad - 5, "", sgn, h, m }),
                        2 => f.print("%*s%c%02d:%02d", .{ pad - 5, "", sgn, h, m }),
                        3 => f.print("%*s", .{ pad, tm.zone() }),
                        else => {},
                    }
                },
                'A', 'a' => {
                    if (w != 1)
                        break :bad;
                    const am = if (c0 == 'a')
                        (if (tm.hour < 12) "am" else "pm")
                    else
                        (if (tm.hour < 12) "AM" else "PM");
                    f.print("%*s", .{ pad, am });
                },
                '[' => {
                    var depth: i32 = 1;
                    while (p.cur() != 0) {
                        if (p.cur() == '[')
                            depth += 1;
                        if (p.cur() == ']')
                            depth -= 1;
                        if (p.cur() == '\\')
                            p.i += 1;
                        if (depth == 0)
                            break;
                        // Fixed from C: the backslash was the last
                        if (p.cur() == 0)
                            break;
                        fmtrune(f, p.next());
                    }
                    if (p.next() != ']')
                        break :bad;
                },
                else => {
                    while (w > 0) : (w -= 1)
                        fmtrune(f, c0);
                },
            }
            continue;
        }
        werrstr("garbled format %s", .{whole});
        return error.Garbled;
    }
}

fn getnum(ps: *Str, maxw: usize, ok: *bool) i32 {
    var n: i32 = 0;
    var k: usize = 0;
    while (k != maxw and ps.at(k) >= '0' and ps.at(k) <= '9') : (k += 1) {
        n *%= 10;
        n +%= ps.at(k) - '0';
    }
    ok.* = k != 0;
    ps.i += k;
    return n;
}

fn tolower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

/// cistrncmp(s, t, n) == 0
fn cihas(s: *const Str, t: []const u8, n: usize) bool {
    for (0..n) |i| {
        const a = tolower(s.at(i));
        const b: u8 = if (i < t.len) tolower(t[i]) else 0;
        if (a != b)
            return false;
        if (a == 0)
            return true;
    }
    return true;
}

fn lookup(s: *Str, table: []const []const u8, len: ?usize, ok: *bool) i32 {
    for (table, 0..) |t, i| {
        const nc = len orelse t.len;
        if (cihas(s, t, nc)) {
            s.i += nc;
            ok.* = true;
            return @intCast(i);
        }
    }
    ok.* = false;
    return -1;
}

fn strspn(p: *const Str, set: []const u8) usize {
    var n: usize = 0;
    while (p.at(n) != 0 and std.mem.findScalar(u8, set, p.at(n)) != null)
        n += 1;
    return n;
}

/// Parse str by a format.  tzload gives a zone by name ("local", or
/// one of tzabbrev's), or null.  Returns how much of str was used.
pub fn tmparse(tm: *Tm, format: []const u8, str: []const u8, tz: ?*const Tzone, tzload: *const fn ([]const u8) ?*const Tzone) error{ Garbled, BadDate }!usize {
    var p: Str = .{ .s = format };
    var s: Str = .{ .s = str };
    var tzo: i32 = 0;
    var ampm: i32 = -1;
    var zoned = false;
    var zparsed: ?*const Tzone = null;
    var sloppy = false;
    var c0: u8 = 0xff; // the C's -1, printed with %c
    // Default all fields
    tm.* = .{};
    tmtime(tm, 0, null);
    if (p.cur() == '~') {
        sloppy = true;
        p.i += 1;
    }

    baddate: {
        badfmt: {
            // Skip whitespace
            while (true) : (s.i += 1) {
                switch (s.cur()) {
                    ' ', '\t', '\n', 0x0c, '\r', 0x0b => continue,
                    else => {},
                }
                break;
            }
            while (p.cur() != 0) {
                var w: i32 = 1;
                c0 = p.next();
                if (c0 == '?') {
                    w = -1;
                    c0 = p.next();
                    // Fixed from C: the format ended in '?'
                    if (c0 == 0)
                        break;
                }
                while (p.cur() == c0) {
                    if (w != -1) w += 1;
                    p.i += 1;
                }
                var ok = true;
                switch (c0) {
                    'Y' => switch (w) {
                        -1 => {
                            tm.year = getnum(&s, 4, &ok);
                            if (tm.year > 100) tm.year -= 1900;
                        },
                        1 => tm.year = getnum(&s, 4, &ok) - 1900,
                        2 => tm.year = getnum(&s, 2, &ok),
                        3, 4 => tm.year = getnum(&s, 4, &ok) - 1900,
                        else => break :badfmt,
                    },
                    'M' => switch (w) {
                        -1 => {
                            tm.mon = getnum(&s, 2, &ok) - 1;
                            if (!ok) tm.mon = lookup(&s, &month, null, &ok);
                            if (!ok) tm.mon = lookup(&s, &month, 3, &ok);
                        },
                        1, 2 => tm.mon = getnum(&s, 2, &ok) - 1,
                        3 => tm.mon = lookup(&s, &month, 3, &ok),
                        4 => tm.mon = lookup(&s, &month, null, &ok),
                        else => break :badfmt,
                    },
                    'D' => switch (w) {
                        -1, 1, 2 => tm.mday = getnum(&s, 2, &ok),
                        else => break :badfmt,
                    },
                    'o' => {
                        const r = s.rest();
                        if (std.mem.startsWith(u8, r, "th") or
                            std.mem.startsWith(u8, r, "rd") or
                            std.mem.startsWith(u8, r, "nd") or
                            std.mem.startsWith(u8, r, "st"))
                            s.i += 2
                        else
                            break :badfmt;
                    },
                    'W' => switch (w) {
                        -1 => {
                            tm.wday = lookup(&s, &wday, null, &ok);
                            if (!ok) tm.wday = lookup(&s, &wday, 3, &ok);
                            if (!ok) tm.wday = getnum(&s, 1, &ok) - 1;
                        },
                        1 => tm.wday = getnum(&s, 1, &ok) - 1,
                        2 => tm.wday = lookup(&s, &wday, 3, &ok),
                        3 => tm.wday = lookup(&s, &wday, null, &ok),
                        else => break :badfmt,
                    },
                    'h' => switch (w) {
                        -1, 1, 2 => tm.hour = getnum(&s, 2, &ok),
                        else => break :badfmt,
                    },
                    'm' => switch (w) {
                        -1, 1, 2 => tm.min = getnum(&s, 2, &ok),
                        else => break :badfmt,
                    },
                    's' => switch (w) {
                        -1, 1, 2 => tm.sec = getnum(&s, 2, &ok),
                        else => break :badfmt,
                    },
                    't' => switch (w) {
                        -1, 1, 2, 3 => tm.nsec +%= getnum(&s, 3, &ok) *% 1000000,
                        else => {},
                    },
                    'u' => switch (w) {
                        -1, 1, 2 => tm.nsec +%= getnum(&s, 3, &ok) *% 1000,
                        3, 4 => tm.nsec +%= getnum(&s, 6, &ok) *% 1000,
                        else => {},
                    },
                    'n' => switch (w) {
                        1, 2 => tm.nsec +%= getnum(&s, 3, &ok),
                        3, 4 => tm.nsec +%= getnum(&s, 6, &ok),
                        -1, 5, 6 => tm.nsec +%= getnum(&s, 9, &ok),
                        else => {},
                    },
                    'z', 'Z' => zone: {
                        if (c0 == 'z' and w != 1)
                            break :badfmt;
                        var zs: i32 = 0;
                        zoned = true;
                        switch (s.next()) {
                            '+' => zs = 1,
                            '-' => zs = -1,
                            else => s.i -= 1,
                        }
                        const q = s.i;
                        // The C's switch(w), whose cases fall through:
                        // names (-1, 3), then +hhmm (-1, 1), then
                        // +hh:mm (-1, 2).
                        fuzzy: {
                            if (w == -1 or w == 3) {
                                // Ugly Hack:
                                // Ctime is defined as printing a 3-character timezone
                                // name. The timezone name is ambiguous. For example,
                                // EST refers to both Australian and American eastern
                                // time. On top of that, we don't want to make the
                                // tzabbrev table exhaustive. So, we put in this hack:
                                //
                                // Before we consult the well known table of timezones,
                                // we check if the local time matches the timezone name.
                                //
                                // If you want unambiguous timezone parsing, use numeric
                                // timezone offsets (Z, ZZ formats).
                                if (tzload("local")) |local| {
                                    const st = name(&local.stname);
                                    if (cihas(&s, st, st.len)) {
                                        s.i += st.len;
                                        zparsed = local;
                                        break :zone;
                                    }
                                    const dl = name(&local.dlname);
                                    if (cihas(&s, dl, dl.len)) {
                                        s.i += dl.len;
                                        zparsed = local;
                                        break :zone;
                                    }
                                }
                                for (tzabbrev) |a| {
                                    const n = a.abbr.len;
                                    if (cihas(&s, a.abbr, n) and !isalpha(s.at(n))) {
                                        s.i += n;
                                        zparsed = tzload(a.name);
                                        if (zparsed == null) {
                                            werrstr("unloadable zone %s (%s)", .{ a.abbr, a.name });
                                            if (w != -1)
                                                return error.BadDate;
                                        }
                                        break :zone;
                                    }
                                }
                                for (milabbrev) |m| {
                                    const n = m.abbr.len;
                                    if (cihas(&s, m.abbr, n) and !isalpha(s.at(n))) {
                                        setname(&tm.zonebuf, m.abbr);
                                        tzo = m.off;
                                        break :zone;
                                    }
                                }
                                if (w != -1)
                                    break :fuzzy;
                            }
                            if (w == -1 or w == 1) {
                                // offset: [+-]hhmm
                                const z0 = getnum(&s, 4, &ok);
                                if (s.i - q == 4) {
                                    const z1 = @rem(z0, 100);
                                    if (@divTrunc(z0, 100) > 13 or z1 >= 60)
                                        break :baddate;
                                    tzo = zs * (3600 * @divTrunc(z0, 100) + 60 * z1);
                                    var zb: [32]u8 = undefined;
                                    setname(&tm.zonebuf, fmt.snprint(&zb, "%c%02d%02d", .{ @as(u8, if (zs < 0) '-' else '+'), @divTrunc(z0, 100), z1 }));
                                    break :zone;
                                }
                                if (w != -1)
                                    break :baddate;
                            }
                            if (w == -1 or w == 2) {
                                s.i = q;
                                // offset: [+-]hh:mm
                                const z0 = getnum(&s, 2, &ok);
                                if (s.next() != ':')
                                    break :fuzzy;
                                const z1 = getnum(&s, 2, &ok);
                                if (z1 > 60)
                                    break :fuzzy;
                                tzo = zs * (3600 * z0 + 60 * z1);
                                var zb: [32]u8 = undefined;
                                setname(&tm.zonebuf, fmt.snprint(&zb, "%c%d02:%02d", .{ @as(u8, if (zs < 0) '-' else '+'), z0, z1 }));
                                break :zone;
                            }
                        }
                        if (w != -1)
                            break :baddate;
                        // Final fuzzy fallback: If we have what looks like an
                        // unknown timezone abbreviation, keep the zone name,
                        // but give it a timezone offset of 0. This allows us
                        // to avoid rejecting zones outside of RFC5322.
                        s.i = q;
                        while (s.cur() != 0) : (s.i += 1) {
                            if (!isalpha(s.cur()))
                                break;
                        }
                        if (s.i - q >= 3 and !isalpha(s.cur())) {
                            // strncpy(tm->zone, q, s - q): no 0 added, and
                            // DIFF: the C does not stop at the array's end
                            const n = @min(s.i - q, tm.zonebuf.len);
                            @memcpy(tm.zonebuf[0..n], str[q..][0..n]);
                            tzo = 0;
                            ok = true;
                            break :zone;
                        }
                        break :baddate;
                    },
                    'A', 'a' => {
                        if (cihas(&s, "am", 2))
                            ampm = 0
                        else if (cihas(&s, "pm", 2))
                            ampm = 1
                        else
                            break :baddate;
                        s.i += 2;
                    },
                    '[' => {
                        var depth: i32 = 1;
                        while (p.cur() != 0) {
                            if (p.cur() == '[')
                                depth += 1;
                            if (p.cur() == ']')
                                depth -= 1;
                            if (p.cur() == '\\')
                                p.i += 1;
                            if (depth == 0)
                                break;
                            if (s.cur() == 0)
                                break :baddate;
                            if (s.next() != p.next())
                                break :baddate;
                        }
                        if (p.cur() != ']')
                            break :badfmt;
                        p.i += 1;
                    },
                    '_', ',', ' ' => {
                        const c = s.cur();
                        if (c != ' ' and c != '\t' and c != ',' and c != '\n' and c != 0)
                            break :baddate;
                        p.i += strspn(&p, " ,_\t\n");
                        s.i += strspn(&s, " ,\t\n");
                    },
                    else => {
                        if (s.cur() == 0)
                            break :baddate;
                        if (s.next() != c0)
                            break :baddate;
                    },
                }
                if (!ok)
                    break :baddate;
            }

            if (!sloppy and ampm != -1 and (tm.hour < 1 or tm.hour > 12))
                break :baddate;
            if (ampm == 0 and tm.hour == 12)
                tm.hour = 0
            else if (ampm == 1 and tm.hour < 12)
                tm.hour += 12;
            // If we're allowing sloppy date ranges,
            // we'll normalize out of range values.
            if (!sloppy) {
                const leap = isleap(@as(i64, tm.year) + 1900);
                if (tm.yday < 0 or tm.yday > 365 + @as(i32, @intFromBool(leap)))
                    break :baddate;
                if (tm.wday < 0 or tm.wday > 6)
                    break :baddate;
                if (tm.mon < 0 or tm.mon > 11)
                    break :baddate;
                var md = mdays[@intCast(tm.mon)];
                if (tm.mon == 1 and leap)
                    md += 1;
                if (tm.mday < 0 or tm.mday > md)
                    break :baddate;
                if (tm.hour < 0 or tm.hour > 24)
                    break :baddate;
                if (tm.min < 0 or tm.min > 59)
                    break :baddate;
                if (tm.sec < 0 or tm.sec > 60)
                    break :baddate;
                if (tm.nsec < 0 or tm.nsec > Nsec)
                    break :baddate;
            }

            // Normalizing gives us the local time,
            // but because we havnen't applied the
            // timezone, we think we're GMT. So, we
            // need to shift backwards. Then, we move
            // the "GMT that was local" back to local
            // time.
            var abs = tmnorm(tm);
            tm.tzoff = tzo;
            if (!zoned)
                tzoffset(tz, abs, tm)
            else if (zparsed) |z| {
                tzoffset(z, abs, tm);
                tzoffset(z, abs + tm.tzoff, tm);
            }
            abs -= tm.tzoff;
            if (tz != null or !zoned)
                tmtimens(tm, abs, tm.nsec, tz);
            return @min(s.i, str.len);
        }
        werrstr("garbled format %s near '%s'", .{ format, p.rest() });
        return error.Garbled;
    }
    werrstr("invalid %c component in '%s'", .{ c0, str });
    return error.BadDate;
}

// asctime's static buffer: the C prints into 30 bytes, puts no 0 after
// what it printed, and returns the buffer.
var ascbuf: [30]u8 = @splat(0);

/// "Sun Nov 15 21:05:00 MST 2026\n", cut at 29 bytes.
pub fn asctime(tm: *const Tm) []const u8 {
    var f: fmt.Fmt = .{ .buf = ascbuf[0..29] };
    tmfmt(&f, tm, "WW MMM _D hh:mm:ss ZZZ YYYY\n") catch {};
    ascbuf[29] = 0;
    return name(&ascbuf);
}

/// asctime's buffer whole, for those who take the date by position
/// as ls does: what an earlier, longer date left is still there.
pub fn ascraw() *const [30]u8 {
    return &ascbuf;
}

// ---- host tests ----

const tst = std.testing;

fn show(tm: *const Tm, format: ?[]const u8) []const u8 {
    const S = struct {
        var b: [256]u8 = undefined;
    };
    var f: fmt.Fmt = .{ .buf = &S.b };
    tmfmt(&f, tm, format) catch return "GARBLED";
    return S.b[0..f.n];
}

fn nozone(_: []const u8) ?*const Tzone {
    return null;
}

const mountain = "MST -25200 MDT -21600\n" ++
    " 1583661600 1604217600 1615111200 1636272000 1647165600 1667721600\n" ++
    " 1678615200 1699171200 1710064800 1730620800 1741514400 1762070400\n";

test "the calendar, GMT" {
    var tm: Tm = .{};
    tmtime(&tm, 0, null);
    try tst.expectEqualStrings("Thu Jan  1 00:00:00 GMT 1970", show(&tm, null));
    try tst.expectEqual(@as(i32, 0), tm.yday);
    tmtime(&tm, 951782400, null); // 2000-02-29
    try tst.expectEqualStrings("2000-02-29 Tue 00:00:00 +0000", show(&tm, "YYYY-MM-DD WW hh:mm:ss Z"));
    // Kept from C: the leap day is counted from February 1st
    try tst.expectEqual(@as(i32, 60), tm.yday);
    tmtime(&tm, 1763259900, null);
    try tst.expectEqualStrings("Sun Nov 16 02:25:00 GMT 2025", show(&tm, null));
    tmtime(&tm, -1, null);
    try tst.expectEqualStrings("Wed Dec 31 23:59:59 GMT 1969", show(&tm, null));
    tmtime(&tm, 4102444800, null); // past 32 bits
    try tst.expectEqualStrings("2100-01-01", show(&tm, "YYYY-MM-DD"));
    // a round trip over many days
    var abs: i64 = -3_000_000_000;
    while (abs < 6_000_000_000) : (abs += 86400 * 37 + 3601) {
        tmtime(&tm, abs, null);
        try tst.expectEqual(abs, tmnorm(&tm));
    }
}

test "a zone: either side of a change, and on it" {
    var z: Tzone = .{};
    try parsezone(&z, "local", mountain);
    try tst.expectEqualStrings("MST", name(&z.stname));
    try tst.expectEqual(@as(i32, -21600), z.dldiff);
    var tm: Tm = .{};
    // the pairs are local standard time: 1741514400 is 2025-03-09 10:00 GMT less 7h... the change
    tmtime(&tm, 1741514400 + 25200, &z);
    try tst.expectEqualStrings("MST", tm.zone());
    tmtime(&tm, 1741514400 + 25200 + 1, &z);
    try tst.expectEqualStrings("MDT", tm.zone());
    try tst.expectEqual(@as(i32, -21600), tm.tzoff);
    tmtime(&tm, 1762070400 + 25200, &z);
    try tst.expectEqualStrings("MDT", tm.zone());
    tmtime(&tm, 1762070400 + 25200 + 1, &z);
    try tst.expectEqualStrings("MST", tm.zone());
    try tst.expectEqualStrings("-0700 -07:00 MST", show(&tm, "Z ZZ ZZZ"));
    // tmnorm finds the zone again
    tmtime(&tm, 1750000000, &z);
    try tst.expectEqual(@as(i64, 1750000000), tmnorm(&tm));
    try tst.expectEqualStrings("MDT", tm.zone());
}

test "zone files that are wrong" {
    var z: Tzone = .{};
    try tst.expectError(error.BadZone, parsezone(&z, "x", "AB 0 CD 0\n"));
    try tst.expectEqualStrings("truncated name", errstr());
    try tst.expectError(error.BadZone, parsezone(&z, "x", "GMT 0 GMT 0 12x4 5\n"));
    try tst.expectEqualStrings("invalid transition time", errstr());
    try tst.expectError(error.BadZone, parsezone(&z, "x", "GMT z"));
    try tst.expectEqualStrings("non-number z in name", errstr());
    try tst.expectError(error.BadZone, parsezone(&z, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "GMT 0 GMT 0\n"));
    try parsezone(&z, "x", "GMT 0 GMT 0\n");
    try parsezone(&z, "x", "   NZST 43200 NZDT 46800\n"); // no pairs
    try tst.expectEqual(@as(i32, 43200), z.stdiff);
}

test "formats" {
    var tm: Tm = .{};
    tmtimens(&tm, 1763259907, 123456789, null); // Sun Nov 16 02:25:07 2025
    try tst.expectEqualStrings("2025 25 2025", show(&tm, "Y YY YYYY"));
    try tst.expectEqualStrings("11 11 Nov November", show(&tm, "M MM MMM MMMM"));
    try tst.expectEqualStrings("16 16 16th", show(&tm, "D DD Do"));
    try tst.expectEqualStrings("1 Sun Sunday", show(&tm, "W WW WWW"));
    try tst.expectEqualStrings("2 02 2 02 25 25 7 07 am AM", show(&tm, "h hh H HH m mm s ss a A"));
    try tst.expectEqualStrings("123 123 123", show(&tm, "t tt ttt"));
    try tst.expectEqualStrings("456 456 123456 123456", show(&tm, "u uu uuu uuuu"));
    try tst.expectEqualStrings("789 789 456789 456789 123456789 123456789", show(&tm, "n nn nnn nnnn nnnnn nnnnnn"));
    try tst.expectEqualStrings(" 16|  7|   Nov", show(&tm, "__D|__s|___MMM"));
    try tst.expectEqualStrings("at 02 o'clock x]", show(&tm, "[at] hh [o'clock] [[x\\]]"));
    try tst.expectEqualStrings("GARBLED", show(&tm, "YYY"));
    try tst.expectEqualStrings("garbled format YYY", errstr());
    try tst.expectEqualStrings("GARBLED", show(&tm, "zz"));
    try tst.expectEqualStrings("", show(&tm, "ZZZZ"));
    try tst.expectEqualStrings("x", show(&tm, "x_"));
    try tst.expectEqualStrings("Sun Nov 16 02:25:07 GMT 2025\n", asctime(&tm));
}

test "parsing" {
    var tm: Tm = .{};
    _ = try tmparse(&tm, "YYYY-MM-DD hh:mm:ss", "2025-11-16 02:25:07", null, nozone);
    try tst.expectEqual(@as(i64, 1763259907), tmnorm(&tm));
    try tst.expectEqual(@as(i32, 0), tm.wday);
    _ = try tmparse(&tm, "?WW ?MMM ?D hh:mm:ss ?Z YYYY", "Sunday nov 16 02:25:07 +0100 2025", null, nozone);
    try tst.expectEqual(@as(i64, 1763259907 - 3600), tmnorm(&tm));
    try tst.expectEqualStrings("+0100", tm.zone());
    _ = try tmparse(&tm, "YYYY/M/D h:mm a", "  2025/3/9 12:05 am", null, nozone);
    try tst.expectEqualStrings("2025-03-09 00:05", show(&tm, "YYYY-MM-DD hh:mm"));
    // Kept from C: the zone's text
    _ = try tmparse(&tm, "YYYY ZZ", "2025 -05:30", null, nozone);
    try tst.expectEqualStrings("-502:30", tm.zone());
    try tst.expectEqual(@as(i32, -(5 * 3600 + 30 * 60)), tm.tzoff);
    // a military zone, and one nobody knows
    _ = try tmparse(&tm, "YYYY ZZZ", "2025 Z", null, nozone);
    try tst.expectEqualStrings("Z", tm.zone());
    _ = try tmparse(&tm, "YYYY ?Z", "2025 WXYZ", null, nozone);
    try tst.expectEqualStrings("WXYZ", tm.zone());
    // the end is returned
    try tst.expectEqual(@as(usize, 4), try tmparse(&tm, "YYYY", "2025 and more", null, nozone));

    try tst.expectError(error.BadDate, tmparse(&tm, "YYYY-MM-DD", "2025-13-01", null, nozone));
    try tst.expectEqualStrings("invalid D component in '2025-13-01'", errstr());
    _ = try tmparse(&tm, "~YYYY-MM-DD", "2025-13-01", null, nozone);
    try tst.expectEqualStrings("2026-01-01", show(&tm, "YYYY-MM-DD"));
    try tst.expectError(error.BadDate, tmparse(&tm, "YYYY-MM-DD", "2025-02-30", null, nozone));
    try tst.expectError(error.Garbled, tmparse(&tm, "DDD", "123", null, nozone));
    try tst.expectEqualStrings("garbled format DDD near ''", errstr());
    try tst.expectError(error.BadDate, tmparse(&tm, "hh", "x", null, nozone));
    // in a zone
    var z: Tzone = .{};
    try parsezone(&z, "local", mountain);
    _ = try tmparse(&tm, "YYYY-MM-DD hh:mm", "2025-07-04 12:00", &z, nozone);
    try tst.expectEqualStrings("MDT", tm.zone());
    try tst.expectEqual(@as(i64, 1751652000), tmnorm(&tm));
}
