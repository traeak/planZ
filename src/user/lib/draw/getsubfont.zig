//! Read a subfont from its file.
//! From /sys/src/libdraw/getsubfont.c (9front 11952).
//!
//! Default version: treat as file name

const libc = @import("libc");
const D = @import("libdraw.zig");

pub fn _getsubfont(d: *D.Display, name: []const u8) ?*D.Subfont {
    const fd = libc.open(name, libc.OREAD | libc.OCEXEC) catch {
        libc.fprint(2, "getsubfont: can't open %s: %r\n", .{name});
        return null;
    };
    defer libc.close(fd) catch {};
    return D.readsubfont(d, name, fd) catch {
        libc.fprint(2, "getsubfont: can't read %s: %r\n", .{name});
        return null;
    };
}
