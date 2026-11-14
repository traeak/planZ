//! Make a Font from the text of a font file, and free one.
//! From /sys/src/libdraw/buildfont.c (9front 11952).
//!
//! DIFF:
//!   - The text is a slice and is not changed: the C writes a NUL
//!     after each subfont's name and copies it.
//!   - Fixed from C: when the text ends right after a subfont's name,
//!     the C steps past its terminating NUL (`*s++ = 0`) and reads on
//!     beyond the buffer; here the text ends there.
//!   - The display is optional, as the C's may be nil.
//!   - The cache and subfont tables are cleared as soon as they are
//!     allocated, not after the height and ascent are read, since every
//!     error here goes through freefont, which frees what the subfont
//!     table holds (the C frees the tables itself on that error).

const std = @import("std");
const libc = @import("libc");
const D = @import("libdraw.zig");
const Font = D.Font;
const Cachefont = D.Cachefont;

fn at(s: []const u8, i: usize) u8 {
    return if (i < s.len) s[i] else 0;
}

fn skip(s: []const u8, i_: usize) usize {
    var i = i_;
    while (at(s, i) == ' ' or at(s, i) == '\n' or at(s, i) == '\t')
        i += 1;
    return i;
}

/// strtol(s+i, &end, 0), returning the value and moving i to the end.
fn strtol(s: []const u8, i: *usize) i32 {
    const r = libc.strtol32(s[@min(i.*, s.len)..], 0);
    i.* += r.n;
    return r.v;
}

pub fn buildfont(d: ?*D.Display, buf: []const u8, name: []const u8) D.Error!*Font {
    const a = libc.allocator;
    const badform = "bad font format: number expected (char position %d)";

    var s: usize = 0;
    const fnt = a.create(Font) catch return D.nomem();
    fnt.* = .{ .name = &.{}, .display = d };
    fnt.name = a.dupe(u8, name) catch {
        a.destroy(fnt);
        return D.nomem();
    };
    fnt.cache = a.alloc(D.Cacheinfo, D.NFCACHE + D.NFLOOK) catch {
        a.free(fnt.name);
        a.destroy(fnt);
        return D.nomem();
    };
    fnt.subf = a.alloc(D.Cachesubf, D.NFSUBF) catch {
        a.free(fnt.cache);
        a.free(fnt.name);
        a.destroy(fnt);
        return D.nomem();
    };
    // cleared here, not after the height and ascent as in C: freefont
    // frees what the subfont table holds
    @memset(fnt.subf, .{});
    @memset(fnt.cache, .{});
    errdefer freefont(fnt);
    fnt.height = @truncate(strtol(buf, &s));
    s = skip(buf, s);
    fnt.ascent = @truncate(strtol(buf, &s));
    s = skip(buf, s);
    if (fnt.height <= 0 or fnt.ascent <= 0) {
        libc.werrstr("bad height or ascent in font file", .{});
        return error.Plan9;
    }
    fnt.width = 0;
    fnt.age = 1;
    while (true) {
        // must be looking at a number now
        if (at(buf, s) < '0' or '9' < at(buf, s)) {
            libc.werrstr(badform, .{s});
            return error.Plan9;
        }
        const min: u32 = @bitCast(strtol(buf, &s));
        s = skip(buf, s);
        // must be looking at a number now
        if (at(buf, s) < '0' or '9' < at(buf, s)) {
            libc.werrstr(badform, .{s});
            return error.Plan9;
        }
        const max: u32 = @bitCast(strtol(buf, &s));
        s = skip(buf, s);
        if (at(buf, s) == 0 or min > libc.Runemax or max > libc.Runemax or min > max) {
            libc.werrstr("illegal subfont range", .{});
            return error.Plan9;
        }
        var t = s;
        var offset = strtol(buf, &t);
        if (t > s and (at(buf, t) == ' ' or at(buf, t) == '\t' or at(buf, t) == '\n'))
            s = skip(buf, t)
        else
            offset = 0;
        const sub = a.realloc(fnt.sub, fnt.sub.len + 1) catch return D.nomem();
        fnt.sub = sub;
        const c = a.create(Cachefont) catch {
            fnt.sub = a.realloc(sub, sub.len - 1) catch sub;
            return D.nomem();
        };
        t = s;
        while (at(buf, s) != 0 and at(buf, s) != ' ' and at(buf, s) != '\n' and at(buf, s) != '\t')
            s += 1;
        const cname = a.dupe(u8, buf[t..s]) catch {
            a.destroy(c);
            fnt.sub = a.realloc(sub, sub.len - 1) catch sub;
            return D.nomem();
        };
        if (s < buf.len)
            s += 1;
        c.* = .{ .min = @intCast(min), .max = @intCast(max), .offset = offset, .name = cname, .subfontname = null };
        sub[sub.len - 1] = c;
        s = skip(buf, s);
        if (at(buf, s) == 0)
            break;
    }
    return fnt;
}

pub fn freefont(f_: ?*Font) void {
    const a = libc.allocator;
    const f = f_ orelse return;

    for (f.sub) |c| {
        if (c.subfontname) |n| a.free(n);
        a.free(c.name);
        a.destroy(c);
    }
    for (f.subf) |sf| {
        if (sf.f) |s| {
            if (f.display == null or @as(?*D.Subfont, s) != f.display.?.defaultsubfont)
                D.freesubfont(s);
        }
    }
    D.freeimage(f.cacheimage) catch {};
    a.free(f.name);
    a.free(f.cache);
    a.free(f.subf);
    a.free(f.sub);
    a.destroy(f);
}
