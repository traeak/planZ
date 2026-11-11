//! Channel descriptors as text.
//! From /sys/src/libdraw/chan.c.
//!
//! DIFF:
//!   - chantostr takes the buffer as a slice and returns the text
//!     written into it (nil for a bad descriptor); it also stores the
//!     terminating NUL when there is room, as the C always does.
//!   - strtochan takes a slice; the text ends at the slice's end, at a
//!     NUL or at white space.

const draw = @import("draw.zig");
const TYPE = draw.TYPE;
const NBITS = draw.NBITS;

const channames = "rgbkamx";

pub fn chantostr(buf: []u8, cc: u32) ?[]u8 {
    if (chantodepth(cc) == 0)
        return null;

    // reverse the channel descriptor so we can easily generate the string in the right order
    var rc: u32 = 0;
    var c: u32 = cc;
    while (c != 0) : (c >>= 8) {
        rc <<= 8;
        rc |= c & 0xFF;
    }

    var p: usize = 0;
    c = rc;
    while (c != 0) : (c >>= 8) {
        buf[p] = channames[TYPE(c)];
        p += 1;
        buf[p] = '0' + @as(u8, @intCast(NBITS(c)));
        p += 1;
    }
    if (p < buf.len)
        buf[p] = 0;

    return buf[0..p];
}

// avoid pulling in ctype when using with drawterm etc.
fn isspace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

pub fn strtochan(s: []const u8) u32 {
    var c: u32 = 0;
    var d: u32 = 0;
    var usedt: u32 = 0;
    var p: usize = 0;
    while (p < s.len and s[p] != 0 and isspace(s[p]))
        p += 1;

    while (p < s.len and s[p] != 0 and !isspace(s[p])) {
        var t: u32 = 0;
        while (t < channames.len and channames[t] != s[p])
            t += 1;
        if (t == channames.len)
            return 0;
        if (t != draw.CIgnore and usedt & (@as(u32, 1) << @intCast(t)) != 0)
            return 0;
        if (p + 1 >= s.len or s[p + 1] < '0' or s[p + 1] > '9')
            return 0;
        const n: u32 = s[p + 1] - '0';
        d += n;
        c = (c << 8) | draw.__DC(t, n);
        p += 2;
        usedt |= @as(u32, 1) << @intCast(t);
    }
    if (d == 0 or (d > 8 and d % 8 != 0) or (d < 8 and 8 % d != 0))
        return 0;
    return c;
}

pub fn chantodepth(c_: u32) i32 {
    var c = c_;
    var n: u32 = 0;
    while (c != 0) : (c >>= 8) {
        if (TYPE(c) >= draw.NChan or NBITS(c) > 8 or NBITS(c) <= 0)
            return 0;
        n += NBITS(c);
    }
    if (n == 0 or (n > 8 and n % 8 != 0) or (n < 8 and 8 % n != 0))
        return 0;
    return @intCast(n);
}

test "chan" {
    const std = @import("std");
    const t = std.testing;
    var buf: [16]u8 = undefined;
    const Case = struct { s: []const u8, c: u32, d: i32 };
    const cases = [_]Case{
        .{ .s = "k1", .c = draw.GREY1, .d = 1 },
        .{ .s = "k2", .c = draw.GREY2, .d = 2 },
        .{ .s = "k4", .c = draw.GREY4, .d = 4 },
        .{ .s = "k8", .c = draw.GREY8, .d = 8 },
        .{ .s = "m8", .c = draw.CMAP8, .d = 8 },
        .{ .s = "x1r5g5b5", .c = draw.RGB15, .d = 16 },
        .{ .s = "r5g6b5", .c = draw.RGB16, .d = 16 },
        .{ .s = "r8g8b8", .c = draw.RGB24, .d = 24 },
        .{ .s = "r8g8b8a8", .c = draw.RGBA32, .d = 32 },
        .{ .s = "a8r8g8b8", .c = draw.ARGB32, .d = 32 },
        .{ .s = "x8r8g8b8", .c = draw.XRGB32, .d = 32 },
        .{ .s = "b8g8r8", .c = draw.BGR24, .d = 24 },
        .{ .s = "x8b8g8r8", .c = draw.XBGR32, .d = 32 },
    };
    for (cases) |c| {
        try t.expectEqual(c.c, strtochan(c.s));
        try t.expectEqual(c.d, chantodepth(c.c));
        try t.expectEqualStrings(c.s, chantostr(&buf, c.c).?);
    }
    try t.expectEqual(draw.XRGB32, strtochan("  x8r8g8b8 junk"));
    try t.expectEqual(@as(u32, 0), strtochan("r8r8"));
    try t.expectEqual(@as(u32, 0), strtochan("r8g8b"));
    try t.expectEqual(@as(u32, 0), strtochan("q8"));
    try t.expectEqual(@as(u32, 0), strtochan("k3"));
    try t.expectEqual(@as(u32, 0), strtochan("r5g5b5"));
    try t.expectEqual(@as(u32, 0), strtochan(""));
    try t.expect(strtochan("x8x8x8x8") != 0);
    try t.expectEqual(@as(i32, 0), chantodepth(0));
    try t.expectEqual(@as(i32, 0), chantodepth(draw.CHAN1(draw.CGrey, 3)));
    try t.expectEqual(@as(i32, 0), chantodepth(draw.CHAN1(9, 8)));
    try t.expect(chantostr(&buf, 0) == null);
}
