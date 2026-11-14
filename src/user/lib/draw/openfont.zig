//! Open a font file.
//! From /sys/src/libdraw/openfont.c (9front 11952).

const libc = @import("libc");
const D = @import("libdraw.zig");

fn readfile(name: []const u8) ?[]u8 {
    const HUNK = 8 * 1024;
    const a = libc.allocator;

    var s = a.alloc(u8, HUNK) catch return null;
    var n: usize = 0;
    const f = libc.open(name, libc.OREAD | libc.OCEXEC) catch {
        a.free(s);
        return null;
    };
    defer libc.close(f) catch {};
    while (true) {
        const r = libc.read(f, s[n..][0..HUNK]) catch {
            a.free(s);
            return null;
        };
        if (r == 0)
            break;
        n += r;
        s = a.realloc(s, n + HUNK) catch {
            a.free(s);
            return null;
        };
    }
    return a.realloc(s, n) catch s[0..n];
}

pub fn openfont(d: ?*D.Display, name: []const u8) D.Error!*D.Font {
    const buf = readfile(name) orelse {
        libc.werrstr("openfont: %r", .{});
        return error.Plan9;
    };
    defer libc.allocator.free(buf);
    return D.buildfont(d, buf, name);
}
