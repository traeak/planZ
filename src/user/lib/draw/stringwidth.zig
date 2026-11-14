//! The width of text.
//! From /sys/src/libdraw/stringwidth.c (9front 11952).
//!
//! DIFF: as string.zig.  A Font with no display measures only what
//! its cache and the subfonts already read hold: the C reads a missing
//! subfont's file without a display, which readimage.zig cannot.

const D = @import("libdraw.zig");
const Point = D.Point;
const Font = D.Font;
const Rune = D.Rune;
const Text = D.Text;

const Max = 64;

pub fn _stringnwidth(f_: *Font, text_: Text, len_: i32) i32 {
    var f = f_;
    var text = text_;
    var len = len_;
    var cbuf: [Max]u16 = undefined;
    var subfontname: ?[]u8 = null;
    var sf: ?*D.Subfont = null;
    var twid: i32 = 0;
    var try_: i32 = 0;
    var wid: i32 = 0;

    while (!text.empty() and len > 0) {
        var max: usize = Max;
        if (len < max)
            max = @intCast(len);
        if (subfontname) |name| {
            D.freesubfont(sf);
            sf = if (f.display) |d| D._getsubfont(d, name) else null;
            if (sf == null) {
                const d = f.display orelse break;
                const df = d.defaultfont;
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

        D.agefont(f);
        twid += wid;
        len -= n;
    }
    D.freesubfont(sf);
    return twid;
}

pub fn stringnwidth(f: *Font, s: []const u8, len: i32) i32 {
    return _stringnwidth(f, .{ .bytes = s }, len);
}

pub fn stringwidth(f: *Font, s: []const u8) i32 {
    return _stringnwidth(f, .{ .bytes = s }, 1 << 24);
}

pub fn stringsize(f: *Font, s: []const u8) Point {
    return D.Pt(_stringnwidth(f, .{ .bytes = s }, 1 << 24), f.height);
}

pub fn runestringnwidth(f: *Font, r: []const Rune, len: i32) i32 {
    return _stringnwidth(f, .{ .runes = r }, len);
}

pub fn runestringwidth(f: *Font, r: []const Rune) i32 {
    return _stringnwidth(f, .{ .runes = r }, 1 << 24);
}

pub fn runestringsize(f: *Font, r: []const Rune) Point {
    return D.Pt(_stringnwidth(f, .{ .runes = r }, 1 << 24), f.height);
}
