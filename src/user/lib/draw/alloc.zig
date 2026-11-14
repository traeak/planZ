//! Allocating, naming and freeing images.
//! From /sys/src/libdraw/alloc.c (9front 11952).
//!
//! DIFF:
//!   - repl is a bool, nameimage's in too.
//!   - nameimage, _freeimage1 and freeimage return an error union for
//!     the C's 0 or -1.
//!   - nameimage puts the name's length in one byte as the C does,
//!     and so a name of 256 bytes or more is cut short by the length,
//!     not refused (Kept from C).

const libc = @import("libc");
const D = @import("libdraw.zig");
const Display = D.Display;
const Image = D.Image;
const Rectangle = D.Rectangle;
const Error = D.Error;
const BPLONG = D.BPLONG;

pub fn allocimage(d: *Display, r: Rectangle, chan: u32, repl: bool, col: u32) Error!*Image {
    return _allocimage(null, d, r, chan, repl, col, 0, 0);
}

pub fn _allocimage(ai: ?*Image, d: *Display, r: Rectangle, chan: u32, repl: bool, col: u32, screenid: i32, refresh: i32) Error!*Image {
    if (D.badrect(r)) {
        libc.werrstr("bad rectangle", .{});
        return error.Plan9;
    }
    if (chan == 0) {
        libc.werrstr("bad channel descriptor", .{});
        return error.Plan9;
    }

    const depth = D.chantodepth(chan);
    if (depth == 0) {
        libc.werrstr("allocimage: %s", .{"bad channel descriptor"});
        return error.Plan9;
    }

    const a = D.bufimage(d, 1 + 4 + 4 + 1 + 4 + 1 + 4 * 4 + 4 * 4 + 4) catch {
        libc.werrstr("allocimage: %r", .{});
        return error.Plan9;
    };
    d.imageid += 1;
    const id = d.imageid;
    a[0] = 'b';
    BPLONG(a[1..], @bitCast(id));
    BPLONG(a[5..], @bitCast(screenid));
    a[9] = @truncate(@as(u32, @bitCast(refresh)));
    BPLONG(a[10..], chan);
    a[14] = @intFromBool(repl);
    BPLONG(a[15..], @bitCast(r.min.x));
    BPLONG(a[19..], @bitCast(r.min.y));
    BPLONG(a[23..], @bitCast(r.max.x));
    BPLONG(a[27..], @bitCast(r.max.y));
    const clipr = if (repl)
        // huge but not infinite, so various offsets will leave it huge, not overflow
        D.Rect(-0x3FFFFFFF, -0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF)
    else
        r;
    BPLONG(a[31..], @bitCast(clipr.min.x));
    BPLONG(a[35..], @bitCast(clipr.min.y));
    BPLONG(a[39..], @bitCast(clipr.max.x));
    BPLONG(a[43..], @bitCast(clipr.max.y));
    BPLONG(a[47..], col);

    const i = ai orelse libc.allocator.create(Image) catch {
        if (D.bufimage(d, 1 + 4)) |f| {
            f[0] = 'f';
            BPLONG(f[1..], @bitCast(id));
            D.flushimage(d, false) catch {};
        } else |_| {}
        libc.werrstr("allocimage: %s", .{"no memory"});
        return error.Plan9;
    };
    i.display = d;
    i.id = id;
    i.depth = depth;
    i.chan = chan;
    i.r = r;
    i.clipr = clipr;
    i.repl = repl;
    i.screen = null;
    i.next = null;
    return i;
}

pub fn namedimage(d: *Display, name: []const u8) Error!*Image {
    var buf: [12 * 12 + 1]u8 = undefined;

    const n = name.len;
    if (n >= 256) {
        libc.werrstr("namedimage: %s", .{"name too long"});
        return error.Plan9;
    }
    errdefer libc.werrstr("namedimage: %r", .{});
    // flush pending data so we don't get error allocating the image
    D.flushimage(d, false) catch {};
    const a = try D.bufimage(d, 1 + 4 + 1 + n);
    d.imageid += 1;
    const id = d.imageid;
    a[0] = 'n';
    BPLONG(a[1..], @bitCast(id));
    a[5] = @intCast(n);
    @memcpy(a[6..][0..n], name);
    try D.flushimage(d, false);

    if ((libc.pread(d.ctlfd, &buf, 0) catch 0) < 12 * 12)
        return error.Plan9;
    buf[12 * 12] = 0;

    errdefer {
        // Error1:
        if (D.bufimage(d, 1 + 4)) |f| {
            f[0] = 'f';
            BPLONG(f[1..], @bitCast(id));
            D.flushimage(d, false) catch {};
        } else |_| {}
    }
    const i = libc.allocator.create(Image) catch {
        libc.werrstr("no memory", .{});
        return error.Plan9;
    };
    errdefer libc.allocator.destroy(i);
    i.* = .{ .display = d, .id = id };
    const chan = D.strtochan(buf[2 * 12 ..][0..12]);
    if (chan == 0) {
        libc.werrstr("bad channel '%s' from devdraw", .{buf[2 * 12 ..][0..12]});
        return error.Plan9;
    }
    i.chan = chan;
    i.depth = D.chantodepth(chan);
    i.repl = field(&buf, 3) != 0;
    i.r.min.x = field(&buf, 4);
    i.r.min.y = field(&buf, 5);
    i.r.max.x = field(&buf, 6);
    i.r.max.y = field(&buf, 7);
    i.clipr.min.x = field(&buf, 8);
    i.clipr.min.y = field(&buf, 9);
    i.clipr.max.x = field(&buf, 10);
    i.clipr.max.y = field(&buf, 11);
    i.screen = null;
    i.next = null;
    return i;
}

fn field(info: []const u8, i: usize) i32 {
    return @truncate(libc.atoi(info[i * 12 ..]));
}

pub fn nameimage(i: *Image, name: []const u8, in: bool) Error!void {
    const n = name.len;
    const a = try D.bufimage(i.display, 1 + 4 + 1 + 1 + n);
    a[0] = 'N';
    BPLONG(a[1..], @bitCast(i.id));
    a[5] = @intFromBool(in);
    a[6] = @truncate(n);
    @memcpy(a[7..][0..n], name);
    try D.flushimage(i.display, false);
}

pub fn _freeimage1(i_: ?*Image) Error!void {
    const i = i_ orelse return;
    const d = i.display;
    const a = try D.bufimage(d, 1 + 4);
    a[0] = 'f';
    BPLONG(a[1..], @bitCast(i.id));

    if (i.screen != null) {
        var w: *?*Image = &d.windows;
        while (w.*) |wi| {
            if (wi == i) {
                w.* = i.next;
                break;
            }
            w = &wi.next;
        }
    }
}

pub fn freeimage(i: ?*Image) Error!void {
    const ret = _freeimage1(i);
    if (i) |p| libc.allocator.destroy(p);
    return ret;
}
