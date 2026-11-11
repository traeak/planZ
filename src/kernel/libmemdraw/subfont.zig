//! Memsubfont allocation.
//! From /sys/src/libmemdraw/subfont.c.
//!
//! DIFF: the name is a slice, copied with a NUL after it.

const draw = @import("../libdraw/draw.zig");
const memdraw = @import("memdraw.zig");
const kernel = @import("kernel.zig");
const freememimage = @import("alloc.zig").freememimage;

const Fontchar = draw.Fontchar;
const Memimage = memdraw.Memimage;
const Memsubfont = memdraw.Memsubfont;

pub fn allocmemsubfont(name: ?[]const u8, n: i32, height: i32, ascent: i32, info: [*]Fontchar, i: *Memimage) ?*Memsubfont {
    const f = kernel.new(Memsubfont) orelse return null;
    f.min = 0;
    f.n = @intCast(n);
    f.height = @intCast(height);
    f.ascent = @intCast(ascent);
    f.info = info;
    f.bits = i;
    if (name) |s| {
        // as strdup: a failed copy leaves the name nil
        if (kernel.malloc(s.len + 1)) |p| {
            @memcpy(p[0..s.len], s);
            f.name = p[0..s.len];
        } else f.name = null;
    } else f.name = null;
    return f;
}

pub fn freememsubfont(f_: ?*Memsubfont) void {
    const f = f_ orelse return;
    kernel.free(f.info); // note: f->info must have been malloc'ed!
    freememimage(f.bits);
    if (f.name) |s| kernel.free(s);
    kernel.free(f);
}
