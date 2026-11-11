//! cloadmemimage: load an image from data in the compressed format.
//! From /sys/src/libmemdraw/cload.c.
//!
//! DIFF:
//!   - The data is a slice.
//!   - The 1K window `mem` is static, not on the stack (kernel stacks
//!     are 8K); like the C's static `par` here and in load.c it relies
//!     on the caller's lock (devdraw's drawlock).

const draw = @import("../libdraw/draw.zig");
const memdraw = @import("memdraw.zig");
const kernel = @import("kernel.zig");
const badrect = @import("../libdraw/badrect.zig").badrect;
const rectinrect = @import("../libdraw/arith.zig").rectinrect;
const bytesperline = @import("../libdraw/bytesperline.zig").bytesperline;
const byteaddr = @import("alloc.zig").byteaddr;
const hwdraw = @import("hwdraw.zig").hwdraw;

const Rectangle = draw.Rectangle;
const Memimage = memdraw.Memimage;
const Memdrawparam = memdraw.Memdrawparam;
const NMEM = draw.NMEM;
const NMATCH = draw.NMATCH;
const werrstr = kernel.werrstr;

var par: Memdrawparam = undefined;
var mem: [NMEM]u8 = undefined;

pub fn cloadmemimage(i: *Memimage, r: Rectangle, data: []const u8) i32 {
    if (badrect(r) or !rectinrect(r, i.r)) {
        werrstr("cloadmemimage: bad rectangle", .{});
        return -1;
    }

    // avoid sw cursor
    par.dst = i;
    par.src = null;
    par.mask = null;
    par.r = r;
    _ = hwdraw(&par);

    const bpl: usize = @intCast(bytesperline(r, i.depth));
    var u: usize = 0;
    const eu = data.len;
    @memset(&mem, 0);
    var memp: usize = 0;
    const emem: usize = NMEM;
    var y = r.min.y;
    var linep = byteaddr(i, .{ .x = r.min.x, .y = y });
    var elinep = linep + bpl;
    while (true) {
        if (linep == elinep) {
            y += 1;
            if (y == r.max.y)
                break;
            linep = byteaddr(i, .{ .x = r.min.x, .y = y });
            elinep = linep + bpl;
        }
        if (u == eu) {
            werrstr("cloadmemimage: buffer too small", .{});
            return -1;
        }
        const c: usize = data[u];
        u += 1;
        if (c >= 128) {
            var cnt = c - 128 + 1;
            while (cnt != 0) : (cnt -= 1) {
                if (u == eu) {
                    werrstr("cloadmemimage: buffer too small", .{});
                    return -1;
                }
                if (linep == elinep) {
                    werrstr("cloadmemimage: phase error", .{});
                    return -1;
                }
                linep[0] = data[u];
                linep += 1;
                mem[memp] = data[u];
                memp += 1;
                u += 1;
                if (memp == emem)
                    memp = 0;
            }
        } else {
            if (u == eu) {
                werrstr("cloadmemimage: short buffer", .{});
                return -1;
            }
            const offs: usize = @as(usize, data[u]) + ((c & 3) << 8) + 1;
            u += 1;
            var omemp: usize = undefined;
            if (memp < offs)
                omemp = memp + (NMEM - offs)
            else
                omemp = memp - offs;
            var cnt = (c >> 2) + NMATCH;
            while (cnt != 0) : (cnt -= 1) {
                if (linep == elinep) {
                    werrstr("cloadmemimage: phase error", .{});
                    return -1;
                }
                linep[0] = mem[omemp];
                linep += 1;
                mem[memp] = mem[omemp];
                memp += 1;
                omemp += 1;
                if (omemp == emem)
                    omemp = 0;
                if (memp == emem)
                    memp = 0;
            }
        }
    }
    return @intCast(u);
}

test "cloadmemimage" {
    const std = @import("std");
    const t = std.testing;
    const alloc = @import("alloc.zig");
    const unloadmemimage = @import("unload.zig").unloadmemimage;
    const r: Rectangle = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 8, .y = 4 } };
    const i = alloc.allocmemimage(r, draw.GREY8).?;
    defer alloc.freememimage(i);

    // line 0: 4 literal bytes, then 4 copied from 4 back;
    // line 1: 5 literals, then 3 from 5 back;
    // lines 2 and 3: 8 from 16 back, twice.  A run never crosses a line.
    const comp = [_]u8{
        0x83,   1,  2,      3,  4,
        1 << 2, 3,  0x84,   9,  8,
        7,      6,  5,      0,  4,
        5 << 2, 15, 5 << 2, 15,
    };
    try t.expectEqual(@as(i32, comp.len), cloadmemimage(i, r, &comp));
    var out: [32]u8 = undefined;
    try t.expectEqual(@as(i32, 32), unloadmemimage(i, r, &out));
    const want = [_]u8{ 1, 2, 3, 4, 1, 2, 3, 4, 9, 8, 7, 6, 5, 9, 8, 7 };
    try t.expectEqualSlices(u8, &(want ++ want), &out);

    // a run across the end of a line is a phase error; short data fails
    try t.expectEqual(@as(i32, -1), cloadmemimage(i, .{ .min = .{}, .max = .{ .x = 3, .y = 1 } }, &comp));
    try t.expectEqual(@as(i32, -1), cloadmemimage(i, r, comp[0..7]));
    // loading only the first two lines takes only their bytes
    try t.expectEqual(@as(i32, 15), cloadmemimage(i, .{ .min = .{}, .max = .{ .x = 8, .y = 2 } }, &comp));
}
