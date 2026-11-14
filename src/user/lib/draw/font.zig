//! The font cache: characters loaded from subfonts into the font's
//! cache image, as strings are drawn or measured.
//! From /sys/src/libdraw/font.c (9front 11952).
//!
//! DIFF:
//!   - The text is a Text, a tagged union of UTF-8 bytes and runes,
//!     where the C takes a char** or a Rune** (one of them nil);
//!     cachechars advances it past the characters it translates.
//!   - cachechars takes the cache indices as a slice, whose length is
//!     the C's max.
//!   - loadchar's gotos are a loop over a state.
//!   - The C's unsigned arithmetic (the rune hash, the ages, the rune
//!     offset into a subfont) is done in u32 with wrapping operators,
//!     and the 16-bit Cacheinfo fields are truncated explicitly.

const std = @import("std");
const libc = @import("libc");
const D = @import("libdraw.zig");
const Font = D.Font;
const Cacheinfo = D.Cacheinfo;
const Cachefont = D.Cachefont;
const Subfont = D.Subfont;
const Rune = D.Rune;
const BPLONG = D.BPLONG;

const PJW = 0; // use NUL==pjw for invisible characters

/// Text to draw or measure: UTF-8 or runes.
pub const Text = union(enum) {
    bytes: []const u8,
    runes: []const Rune,

    pub fn empty(t: Text) bool {
        return switch (t) {
            .bytes => |s| s.len == 0,
            .runes => |r| r.len == 0,
        };
    }

    /// The first character and the length of its encoding.
    fn first(t: Text) struct { r: Rune, w: usize } {
        switch (t) {
            .bytes => |s| {
                if (s[0] < libc.Runeself)
                    return .{ .r = s[0], .w = 1 };
                const c = libc.chartorune(s);
                return .{ .r = c.r, .w = c.n };
            },
            .runes => |r| return .{ .r = r[0], .w = 1 },
        }
    }

    fn advance(t: *Text, w: usize) void {
        switch (t.*) {
            .bytes => |*s| s.* = s.*[w..],
            .runes => |*r| r.* = r.*[w..],
        }
    }

    /// Step past the first character.
    pub fn skip1(t: *Text) void {
        t.advance(t.first().w);
    }
};

/// return number of translated cache indices, 0 must retry, -1 on error
pub fn cachechars(f: *Font, text: *Text, cp: []u16, wp: *i32, subfontname: *?[]u8) i32 {
    var t = text.*;
    var wid: i32 = 0;
    subfontname.* = null;
    var i: usize = 0;
    while (i < cp.len and !t.empty()) {
        const ch = t.first();
        const r = ch.r;

        var a: u32 = ~@as(u32, 0);
        const mask: u32 = @intCast(f.cache.len - D.NFLOOK - 1);
        var h: usize = (17 *% @as(u32, r)) & mask;
        var tc: usize = h;
        var found = false;
        var c = h;
        while (c < h + D.NFLOOK) : (c += 1) {
            if (f.cache[c].value == r and f.cache[c].age != 0) {
                found = true;
                break;
            }
            if (f.cache[c].age < a) {
                a = f.cache[c].age;
                tc = c;
            }
        }
        if (found) {
            h = c;
        } else {
            // Not found; use oldest entry
            c = tc;
            h = tc;

            if (a != 0 and (f.age -% a) < 500) { // kicking out too recent; resize
                const nc = 2 * (f.cache.len - D.NFLOOK) + D.NFLOOK;
                if (nc <= D.MAXFCACHE) {
                    if (i == 0)
                        _ = fontresize(f, f.width, nc, f.maxdepth);
                    // else flush first; retry will resize
                    break;
                }
            }

            if (i > 0 and f.cache[c].age == f.age) // flush pending string output
                break;

            const j = loadchar(f, r, &f.cache[c], @intCast(h), i > 0, subfontname);
            if (j <= 0) {
                if (j < 0 or i > 0) // flush output or retry
                    break;
                return -1; // stop retrying
            }
        }

        // Found:
        wid += f.cache[c].width;
        f.cache[c].age = @truncate(f.age);
        cp[i] = @intCast(h);
        i += 1;
        t.advance(ch.w);
    }
    text.* = t;
    wp.* = wid;
    return @intCast(i);
}

pub fn agefont(f: *Font) void {
    f.age +%= 1;
    if (f.age == 65536) {
        //
        // Renormalize ages
        //
        for (f.cache) |*c| {
            if (c.age != 0) {
                c.age >>= 2;
                c.age += 1;
            }
        }
        for (f.subf) |*s| {
            if (s.age != 0) {
                if (s.age < D.SUBFAGE) { // and s.cf.name != nil, which it never is
                    // clean up
                    if (f.display == null or @as(?*Subfont, s.f) != f.display.?.defaultsubfont)
                        D.freesubfont(s.f);
                    s.cf = null;
                    s.f = null;
                    s.age = 0;
                } else {
                    s.age >>= 2;
                    s.age += 1;
                }
            }
        }
        f.age = (65536 >> 2) + 1;
    }
}

fn cf2subfont(cf: *Cachefont, f: *Font) ?*Subfont {
    const name = cf.subfontname orelse blk: {
        var depth: i32 = 8;
        if (f.display) |d| {
            if (d.screenimage) |si|
                depth = si.depth;
        }
        const n = D.subfontname(cf.name, f.name, depth) orelse return null;
        cf.subfontname = n;
        break :blk n;
    };
    return D.lookupsubfont(f.display, name);
}

/// return 1 if load succeeded, 0 if failed, -1 if must retry
pub fn loadchar(f: *Font, r: Rune, c: *Cacheinfo, h: i32, noflush: bool, subfontname: *?[]u8) i32 {
    var pic: u32 = r;
    var cf: *Cachefont = undefined;
    var si: usize = undefined; // the Cachesubf: f.subf[si]
    var fi: *D.Fontchar = undefined;

    const State = enum { again, try_pjw, found, found2 };
    sw: switch (State.again) {
        .again => {
            for (f.sub) |s| {
                if (s.min <= pic and pic <= s.max) {
                    cf = s;
                    continue :sw .found;
                }
            }
            continue :sw .try_pjw;
        },
        .try_pjw => {
            if (pic != PJW) {
                pic = PJW;
                continue :sw .again;
            }
            return 0;
        },
        .found => {
            //
            // Choose exact or oldest
            //
            var oi: usize = 0;
            for (f.subf, 0..) |*s, i| {
                if (s.cf == cf) {
                    si = i;
                    continue :sw .found2;
                }
                if (s.age < f.subf[oi].age)
                    oi = i;
            }
            si = oi;

            if (f.subf[si].f) |old| {
                var toss = f.age -% f.subf[si].age > D.SUBFAGE or f.subf.len > D.MAXSUBF;
                if (!toss) { // too recent; grow instead
                    if (libc.allocator.realloc(f.subf, f.subf.len + D.DSUBF)) |ns| {
                        si = f.subf.len;
                        f.subf = ns;
                        @memset(f.subf[si..], .{});
                    } else |_| toss = true;
                }
                if (toss) {
                    // ancient data; toss
                    D.freesubfont(old);
                    f.subf[si] = .{};
                }
            }
            const subf = &f.subf[si];
            subf.age = 0;
            subf.cf = null;
            subf.f = cf2subfont(cf, f);
            const sf = subf.f orelse {
                if (cf.subfontname == null)
                    continue :sw .try_pjw;
                subfontname.* = cf.subfontname;
                return -1;
            };

            subf.cf = cf;
            if (sf.ascent > f.ascent and f.display != null) {
                // should print something? this is a mistake in the font file
                // must prevent c.top from going negative when loading cache
                const d: i32 = sf.ascent - f.ascent;
                const b = sf.bits;
                D.draw(b, b.r, b, null, D.addpt(b.r.min, D.Pt(0, d)));
                D.draw(b, D.Rect(b.r.min.x, b.r.max.y - d, b.r.max.x, b.r.max.y), f.display.?.black, null, b.r.min);
                var i: usize = 0;
                while (i < sf.n) : (i += 1) {
                    sf.info[i].top = @intCast(@max(@as(i32, sf.info[i].top) - d, 0));
                    sf.info[i].bottom = @intCast(@max(@as(i32, sf.info[i].bottom) - d, 0));
                }
                sf.ascent = @intCast(f.ascent);
            }
            continue :sw .found2;
        },
        .found2 => {
            const subf = &f.subf[si];
            const sf = subf.f.?;
            subf.age = f.age;

            // possible overflow here, but works out okay
            pic +%= @bitCast(cf.offset);
            pic -%= cf.min;
            if (pic >= @as(u32, @intCast(sf.n)))
                continue :sw .try_pjw;
            fi = &sf.info[pic];
            if (fi.width == 0)
                continue :sw .try_pjw;
        },
    }

    const sf = f.subf[si].f.?;
    const wid: i32 = sf.info[pic + 1].x - fi.x;
    if (f.width < wid or f.width == 0 or f.maxdepth < sf.bits.depth or
        (f.display != null and f.cacheimage == null))
    {
        //
        // Flush, free, reload (easier than reformatting f.b)
        //
        if (noflush)
            return -1;
        if (f.width < wid)
            f.width = @intCast(wid);
        if (f.maxdepth < sf.bits.depth)
            f.maxdepth = sf.bits.depth;
        if (!fontresize(f, f.width, f.cache.len, f.maxdepth))
            return -1;
        // c is still valid as didn't reallocate f.cache
    }
    c.value = r;
    c.width = fi.width;
    c.x = @truncate(@as(u32, @bitCast(h *% f.width)));
    c.left = fi.left;
    const d = f.display orelse return 1;
    const b = D.bufimage(d, 37) catch return 0;
    const top: i32 = @as(i32, fi.top) + (f.ascent - sf.ascent);
    const bottom: i32 = @as(i32, fi.bottom) + (f.ascent - sf.ascent);
    b[0] = 'l';
    BPLONG(b[1..], @bitCast(f.cacheimage.?.id));
    BPLONG(b[5..], @bitCast(sf.bits.id));
    D.BPSHORT(b[9..], @intCast(h));
    BPLONG(b[11..], c.x);
    BPLONG(b[15..], @bitCast(top));
    BPLONG(b[19..], @bitCast(@as(i32, c.x) + wid));
    BPLONG(b[23..], @bitCast(bottom));
    BPLONG(b[27..], @bitCast(fi.x));
    BPLONG(b[31..], fi.top);
    b[35] = @bitCast(fi.left);
    b[36] = fi.width;
    return 1;
}

/// returns whether resize succeeded && f.cache is unchanged
fn fontresize(f: *Font, wid_: i32, ncache: usize, depth_: i32) bool {
    var ret = false;
    const depth = if (depth_ <= 0) 1 else depth_;
    const wid = if (wid_ <= 0) 1 else wid_;

    resize: {
        if (f.display) |d| {
            const new = D.allocimage(d, D.Rect(0, 0, @as(i32, @intCast(ncache)) * wid, f.height), D.CHAN1(D.CGrey, @intCast(depth)), false, 0) catch {
                libc.fprint(2, "font cache resize failed: %r\n", .{});
                break :resize;
            };

            const b = D.bufimage(d, 1 + 4 + 4 + 1) catch {
                D.freeimage(new) catch {};
                break :resize;
            };
            b[0] = 'i';
            BPLONG(b[1..], @bitCast(new.id));
            BPLONG(b[5..], @intCast(ncache));
            b[9] = @truncate(@as(u16, @bitCast(f.ascent)));

            D.freeimage(f.cacheimage) catch {};
            f.cacheimage = new;
        }
        // Nodisplay:
        f.width = @intCast(wid);
        f.maxdepth = depth;
        ret = true;
        if (f.cache.len != ncache) {
            if (libc.allocator.alloc(Cacheinfo, ncache)) |i| {
                ret = false;
                libc.allocator.free(f.cache);
                f.cache = i;
            } else |_| {}
            // else just wipe the cache clean and things will be ok
        }
    }
    // Return:
    @memset(f.cache, .{});
    return ret;
}
