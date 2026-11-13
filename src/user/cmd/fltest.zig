//! fltest - print planZ's %e %f %g and strtod over generated values,
//! for comparison with 9front's libc, which tools/fltest.c runs with the
//! same generator and the same output.  See tools/fltest.c.
//!
//! Not part of 9front.

const libc = @import("libc");

var bout: libc.Biobuf = .{};
var rng: u64 = 0x9e3779b97f4a7c15;

fn next() u64 {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}

const edges = [_]u64{
    0x0000000000000000, 0x8000000000000000, 0x0000000000000001,
    0x000fffffffffffff, 0x0010000000000000, 0x7fefffffffffffff,
    0x3ff0000000000000, 0xbff0000000000000, 0x3fb999999999999a,
    0x3fe0000000000000, 0x4004000000000000, 0x44b52d02c7e14af6,
    0x44b52d02c7e14af7, 0x4340000000000001, 0x7ff8000000000000,
    0xfff8000000000000, 0x7ff0000000000000, 0xfff0000000000000,
    0x3ee4f8b588e368f1, 0x3f1a36e2eb1c432d, 0x412e847f00000000,
    0x4023000000000000, 0x3fee666666666666, 0x3fa999999999999a,
    0x3fefffffffffffff, 0x4024000000000000, 0x40c3880000000000,
    0x3f50624dd2f1a9fc, 0x7e37e43c8800759c, 0x0360000000000000,
    0x3feffffffffffff0, 0x40fe847fffffffff, 0x4197d78400000000,
    0x3c9cd2b297d889bc, 0x0000000000000400, 0x00000000deadbeef,
    0x400921fb54442d18, 0x4005bf0a8b145769,
};

const fmts = [_][]const u8{
    "|%g", "|%.17g", "|%e", "|%.0e", "|%f", "|%.30f", "|%#g", "|%+e", "|% f",
    "|%-12.3E", "|%.3g", "|%G", "|%10.4f", "|%.15e", "|%.1f", "|%#.0f",
};

fn show(v: f64) void {
    const b: u64 = @bitCast(v);
    bout.print("%.16llux", .{b}) catch {};
    inline for (fmts, 0..) |f, i| {
        // see tools/fltest.c: stock's buffer is a byte short for this
        if (i == 5 and v <= -1e308) {
            _ = bout.write("|skip") catch {};
        } else {
            var buf: [512]u8 = undefined;
            _ = bout.write(libc.fmt.snprint(buf[0 .. buf.len - 1], f, .{v})) catch {};
        }
    }
    bout.putc('\n') catch {};
}

const fixed = [_][]const u8{
    "0",                       "-0",                      "  12",                    "+.5",                     "-.5e-3", "1e", "1e+", "1e-x", ".e5", "e5", ".",
    "-",                       "00012.500",               "0.0000",                  "nan",                     "NaN(1)", "-nan", "inf", "-Infinity",
    "infin",                   "1e400",                   "-1e400",                  "1e-400",                  "2.2250738585072011e-308",
    "2.2250738585072012e-308", "4.9406564584124654e-324", "2.4703282292062327e-324",
    "2.4703282292062328e-324", "1.7976931348623157e308",  "1.7976931348623158e308",
    "1.7976931348623159e308",  "9007199254740993",        "9007199254740992.5",
    "123456789012345678901234567890", "0.1",               "0.30000000000000004",     "1e23",
    "8.98846567431158e307",    "1x",                      "\t\n 7",                  "1.5E+2",                  "1.5e+02z", "1e2147483648",
    "1e-2147483649",
};

fn showstr(s: []const u8) void {
    const r = libc.strtod(s);
    const b: u64 = @bitCast(r.v);
    bout.print("%.16llux %ld\n", .{ b, r.n }) catch {};
}

pub fn main() void {
    bout.init(1, libc.OWRITE);
    for (edges) |e|
        show(@bitCast(e));
    for (0..10000) |_|
        show(@bitCast(next()));
    for (0..2000) |_| {
        const b = next();
        const n: f64 = @floatFromInt(@as(i64, @intCast(b % 2000000)));
        const sign: f64 = if ((b >> 40) & 1 != 0) -1 else 1;
        show(n / 8.0 * sign);
    }

    for (fixed) |s|
        showstr(s);
    // 1 followed by 1600 zeros, and a point and 1600 zeros then 1
    var s: [2000]u8 = undefined;
    s[0] = '1';
    @memset(s[1..1601], '0');
    showstr(s[0..1601]);
    s[0] = '0';
    s[1] = '.';
    @memset(s[2..1602], '0');
    s[1602] = '1';
    showstr(s[0..1603]);
    // generated decimals: sign, 1 to 25 digits with a point somewhere, an exponent
    for (0..10000) |_| {
        const b = next();
        var p: usize = 0;
        if (b & 1 != 0) {
            s[p] = '-';
            p += 1;
        }
        const nd = 1 + (b >> 1) % 25;
        for (0..nd) |j| {
            if (j == (b >> 8) % 30) {
                s[p] = '.';
                p += 1;
            }
            s[p] = @intCast('0' + next() % 10);
            p += 1;
        }
        const ex: i32 = @as(i32, @intCast((b >> 16) % 700)) - 350;
        p += libc.fmt.snprint(s[p..], "e%d", .{ex}).len;
        showstr(s[0..p]);
    }
    bout.term() catch {};
    libc.exits(null);
}
