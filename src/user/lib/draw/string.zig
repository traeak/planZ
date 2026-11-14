//! Drawing text.
//! From /sys/src/libdraw/string.c (9front 11952).
//!
//! DIFF:
//!   - The text is a slice (string, stringn ...) or a slice of runes
//!     (runestring ...); _string takes a Text (font.zig) for the C's
//!     char* and Rune* of which one is nil.
//!   - bg is optional.

const libc = @import("libc");
const D = @import("libdraw.zig");
const Image = D.Image;
const Point = D.Point;
const Rectangle = D.Rectangle;
const Font = D.Font;
const Rune = D.Rune;
const Drawop = D.Drawop;
const Text = D.Text;
const BPLONG = D.BPLONG;

const Max = 100;

pub fn string(dst: *Image, pt: Point, src: *Image, sp: Point, f: *Font, s: []const u8) Point {
    return _string(dst, pt, src, sp, f, .{ .bytes = s }, 1 << 24, dst.clipr, null, D.ZP, D.SoverD);
}

pub fn stringop(dst: *Image, pt: Point, src: *Image, sp: Point, f: *Font, s: []const u8, op: Drawop) Point {
    return _string(dst, pt, src, sp, f, .{ .bytes = s }, 1 << 24, dst.clipr, null, D.ZP, op);
}

pub fn stringn(dst: *Image, pt: Point, src: *Image, sp: Point, f: *Font, s: []const u8, len: i32) Point {
    return _string(dst, pt, src, sp, f, .{ .bytes = s }, len, dst.clipr, null, D.ZP, D.SoverD);
}

pub fn stringnop(dst: *Image, pt: Point, src: *Image, sp: Point, f: *Font, s: []const u8, len: i32, op: Drawop) Point {
    return _string(dst, pt, src, sp, f, .{ .bytes = s }, len, dst.clipr, null, D.ZP, op);
}

pub fn runestring(dst: *Image, pt: Point, src: *Image, sp: Point, f: *Font, r: []const Rune) Point {
    return _string(dst, pt, src, sp, f, .{ .runes = r }, 1 << 24, dst.clipr, null, D.ZP, D.SoverD);
}

pub fn runestringop(dst: *Image, pt: Point, src: *Image, sp: Point, f: *Font, r: []const Rune, op: Drawop) Point {
    return _string(dst, pt, src, sp, f, .{ .runes = r }, 1 << 24, dst.clipr, null, D.ZP, op);
}

pub fn runestringn(dst: *Image, pt: Point, src: *Image, sp: Point, f: *Font, r: []const Rune, len: i32) Point {
    return _string(dst, pt, src, sp, f, .{ .runes = r }, len, dst.clipr, null, D.ZP, D.SoverD);
}

pub fn runestringnop(dst: *Image, pt: Point, src: *Image, sp: Point, f: *Font, r: []const Rune, len: i32, op: Drawop) Point {
    return _string(dst, pt, src, sp, f, .{ .runes = r }, len, dst.clipr, null, D.ZP, op);
}

pub fn _string(dst: *Image, pt_: Point, src: *Image, sp: Point, f_: *Font, text_: Text, len_: i32, clipr: Rectangle, bg: ?*Image, bgp_: Point, op: Drawop) Point {
    var pt = pt_;
    var bgp = bgp_;
    var f = f_;
    var text = text_;
    var len = len_;
    var cbuf: [Max]u16 = undefined;
    var subfontname: ?[]u8 = null;
    var sf: ?*D.Subfont = null;
    var try_: i32 = 0;
    var wid: i32 = 0;

    while (!text.empty() and len > 0) {
        var max: usize = Max;
        if (len < max)
            max = @intCast(len);
        if (subfontname) |name| {
            D.freesubfont(sf);
            sf = D._getsubfont(f.display.?, name);
            if (sf == null) {
                const df = f.display.?.defaultfont;
                if (df == null or df.? == f)
                    break;
                f = df.?;
            }
        }
        const n = D.cachechars(f, &text, cbuf[0..max], &wid, &subfontname);
        if (n <= 0) {
            if (n == 0) {
                try_ += 1;
                if (try_ > 10)
                    break;
                continue;
            }
            text.skip1();
            len -= 1;
            continue;
        }
        try_ = 0;

        const un: usize = @intCast(n);
        var m: usize = 47 + 2 * un;
        if (bg != null)
            m += 4 + 2 * 4;
        var b = D._bufimageop(dst.display, m, op) catch {
            libc.fprint(2, "string: %r\n", .{});
            break;
        };
        b[0] = if (bg != null) 'x' else 's';
        BPLONG(b[1..], @bitCast(dst.id));
        BPLONG(b[5..], @bitCast(src.id));
        BPLONG(b[9..], @bitCast(f.cacheimage.?.id));
        BPLONG(b[13..], @bitCast(pt.x));
        BPLONG(b[17..], @bitCast(pt.y + f.ascent));
        BPLONG(b[21..], @bitCast(clipr.min.x));
        BPLONG(b[25..], @bitCast(clipr.min.y));
        BPLONG(b[29..], @bitCast(clipr.max.x));
        BPLONG(b[33..], @bitCast(clipr.max.y));
        BPLONG(b[37..], @bitCast(sp.x));
        BPLONG(b[41..], @bitCast(sp.y));
        D.BPSHORT(b[45..], @intCast(n));
        b = b[47..];
        if (bg) |g| {
            BPLONG(b, @bitCast(g.id));
            BPLONG(b[4..], @bitCast(bgp.x));
            BPLONG(b[8..], @bitCast(bgp.y));
            b = b[12..];
        }
        for (cbuf[0..un], 0..) |c, i|
            D.BPSHORT(b[2 * i ..], c);
        pt.x += wid;
        bgp.x += wid;
        D.agefont(f);
        len -= n;
    }
    D.freesubfont(sf);
    return pt;
}
