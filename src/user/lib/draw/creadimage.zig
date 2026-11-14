//! Read a compressed image file (image(6)) into a new image.
//! From /sys/src/libdraw/creadimage.c (9front 11952).
//!
//! DIFF:
//!   - The display must be given, as in readimage.zig.
//!   - The third argument (dolock) is left out.

const std = @import("std");
const libc = @import("libc");
const D = @import("libdraw.zig");
const Display = D.Display;
const Image = D.Image;
const Rectangle = D.Rectangle;
const Error = D.Error;
const BPLONG = D.BPLONG;

pub fn creadimage(d: *Display, fd: i32) Error!*Image {
    var hdr: [5 * 12 + 1]u8 = undefined;

    if ((libc.readn(fd, hdr[0 .. 5 * 12]) catch 0) != 5 * 12) {
        libc.werrstr("creadimage: short header", .{});
        return error.Plan9;
    }

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
        libc.werrstr("creadimage: bad format", .{});
        return error.Plan9;
    }
    var chan: u32 = undefined;
    if (new) {
        hdr[11] = 0;
        chan = D.strtochan(hdr[0..11]);
        if (chan == 0) {
            libc.werrstr("creadimage: bad channel string %s", .{hdr[0 .. std.mem.indexOfScalar(u8, &hdr, 0) orelse 11]});
            return error.Plan9;
        }
    } else {
        const ldepth = @as(i32, hdr[10]) - '0';
        if (ldepth < 0 or ldepth > 3) {
            libc.werrstr("creadimage: bad ldepth %d", .{ldepth});
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
        libc.werrstr("creadimage: bad rectangle", .{});
        return error.Plan9;
    }

    const i = try D.allocimage(d, r, chan, false, 0);
    errdefer D.freeimage(i) catch {};
    const ncblock: usize = @intCast(D._compblocksize(r, D.chantodepth(chan)));
    const buf = libc.allocator.alloc(u8, ncblock) catch return D.nomem();
    defer libc.allocator.free(buf);
    var miny = r.min.y;
    while (miny != r.max.y) {
        if ((libc.readn(fd, hdr[0 .. 2 * 12]) catch 0) != 2 * 12) {
            libc.werrstr("creadimage: short read", .{});
            return error.Plan9;
        }
        const maxy = field(&hdr, 0);
        const nb = field(&hdr, 1);
        if (maxy <= miny or r.max.y < maxy) {
            libc.werrstr("creadimage: bad maxy %d", .{maxy});
            return error.Plan9;
        }
        if (nb <= 0 or ncblock < nb) {
            libc.werrstr("creadimage: bad count %d", .{nb});
            return error.Plan9;
        }
        const unb: usize = @intCast(nb);
        if ((libc.readn(fd, buf[0..unb]) catch 0) != unb) {
            libc.werrstr("creadimage: short read", .{});
            return error.Plan9;
        }
        const a = try D.bufimage(i.display, 21 + unb);
        a[0] = 'Y';
        BPLONG(a[1..], @bitCast(i.id));
        BPLONG(a[5..], @bitCast(r.min.x));
        BPLONG(a[9..], @bitCast(miny));
        BPLONG(a[13..], @bitCast(r.max.x));
        BPLONG(a[17..], @bitCast(maxy));
        if (!new) // old image: flip the data bits
            D._twiddlecompressed(buf[0..unb]);
        @memcpy(a[21..][0..unb], buf[0..unb]);
        miny = maxy;
    }
    return i;
}

fn field(hdr: []const u8, i: usize) i32 {
    return @truncate(libc.atoi(hdr[i * 12 ..]));
}
