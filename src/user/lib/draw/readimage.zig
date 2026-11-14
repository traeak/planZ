//! Read an image file (image(6)) into a new image.
//! From /sys/src/libdraw/readimage.c (9front 11952).
//!
//! DIFF:
//!   - The display must be given: the C's readimage of no display
//!     (which reads the file and keeps no pixels) is left out.
//!   - The third argument (dolock) is left out.

const libc = @import("libc");
const D = @import("libdraw.zig");
const Display = D.Display;
const Image = D.Image;
const Rectangle = D.Rectangle;
const Error = D.Error;

pub fn readimage(d: *Display, fd: i32) Error!*Image {
    var hdr: [5 * 12 + 1]u8 = undefined;

    if ((libc.readn(fd, hdr[0..11]) catch 0) != 11)
        return error.Plan9;
    if (std.mem.eql(u8, hdr[0..11], "compressed\n"))
        return D.creadimage(d, fd);

    if ((libc.readn(fd, hdr[11 .. 5 * 12]) catch 0) != 5 * 12 - 11)
        return error.Plan9;
    var chunk: i64 = d.bufsize - 32; // a little room for header

    //
    // distinguish new channel descriptor from old ldepth.
    // channel descriptors have letters as well as numbers,
    // while ldepths are a single digit formatted as %-11d.
    //
    var new = false;
    for (hdr[0..10]) |c| {
        if (c != ' ') {
            new = true;
            break;
        }
    }
    if (hdr[11] != ' ') {
        libc.werrstr("readimage: bad format", .{});
        return error.Plan9;
    }
    var chan: u32 = undefined;
    if (new) {
        hdr[11] = 0;
        chan = D.strtochan(hdr[0..11]);
        if (chan == 0) {
            libc.werrstr("readimage: bad channel string %s", .{cstr(hdr[0..11])});
            return error.Plan9;
        }
    } else {
        const ldepth = @as(i32, hdr[10]) - '0';
        if (ldepth < 0 or ldepth > 3) {
            libc.werrstr("readimage: bad ldepth %d", .{ldepth});
            return error.Plan9;
        }
        chan = D.drawld2chan[@intCast(ldepth)];
    }

    var r: Rectangle = undefined;
    r.min.x = field(&hdr, 1);
    r.min.y = field(&hdr, 2);
    r.max.x = field(&hdr, 3);
    r.max.y = field(&hdr, 4);
    if (r.min.x > r.max.x or r.min.y > r.max.y) {
        libc.werrstr("readimage: bad rectangle", .{});
        return error.Plan9;
    }

    var miny = r.min.y;
    const maxy = r.max.y;

    const l: i64 = D.bytesperline(r, D.chantodepth(chan));
    if (l > chunk)
        chunk = l;
    const i = try D.allocimage(d, r, chan, false, 0xFFFFFFFF);
    errdefer D.freeimage(i) catch {};
    const tmp = libc.allocator.alloc(u8, @intCast(chunk)) catch return D.nomem();
    defer libc.allocator.free(tmp);
    while (maxy > miny) {
        var dy: i64 = maxy - miny;
        if (dy * l > chunk)
            dy = @divTrunc(chunk, l);
        const n: usize = @intCast(dy * l);
        const m = libc.readn(fd, tmp[0..n]) catch 0;
        if (m != n) {
            libc.werrstr("readimage: read count %d not %d: %r", .{ m, n });
            return error.Plan9;
        }
        if (!new) // an old image: must flip all the bits
            for (tmp) |*b| {
                b.* ^= 0xFF;
            };

        _ = try D.loadimage(i, D.Rect(r.min.x, miny, r.max.x, miny + @as(i32, @intCast(dy))), tmp);
        miny += @intCast(dy);
    }
    return i;
}

fn field(hdr: []const u8, i: usize) i32 {
    return @truncate(libc.atoi(hdr[i * 12 ..]));
}

/// The text before the first NUL, as C's %s prints it.
fn cstr(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, 0) orelse s.len];
}

const std = @import("std");
