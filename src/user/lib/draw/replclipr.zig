//! Set an image's replication flag and clipping rectangle.
//! From /sys/src/libdraw/replclipr.c (9front 11952).
//!
//! DIFF: repl is a bool.

const libc = @import("libc");
const D = @import("libdraw.zig");
const BPLONG = D.BPLONG;

pub fn replclipr(i: *D.Image, repl: bool, clipr: D.Rectangle) void {
    const b = D.bufimage(i.display, 22) catch {
        libc.fprint(2, "replclipr: %r\n", .{});
        return;
    };
    b[0] = 'c';
    BPLONG(b[1..], @bitCast(i.id));
    b[5] = @intFromBool(repl);
    BPLONG(b[6..], @bitCast(clipr.min.x));
    BPLONG(b[10..], @bitCast(clipr.min.y));
    BPLONG(b[14..], @bitCast(clipr.max.x));
    BPLONG(b[18..], @bitCast(clipr.max.y));
    i.repl = repl;
    i.clipr = clipr;
}
