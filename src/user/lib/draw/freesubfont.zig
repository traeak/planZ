//! Drop a reference to a subfont.
//! From /sys/src/libdraw/freesubfont.c (9front 11952).

const libc = @import("libc");
const D = @import("libdraw.zig");

pub fn freesubfont(f_: ?*D.Subfont) void {
    const f = f_ orelse return;
    f.ref -= 1;
    if (f.ref != 0)
        return;
    D.uninstallsubfont(f);
    if (f.name) |n| libc.allocator.free(n);
    libc.allocator.free(f.info); // note: f.info must have been allocated!
    D.freeimage(f.bits) catch {};
    libc.allocator.destroy(f);
}
