//! echo - print arguments
//! from cmd/echo.c

const std = @import("std");
const libc = @import("libc");

pub fn main(argv: []const []const u8) !void {
    var nflag = false;
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "-n"))
        nflag = true;

    const first: usize = 1 + @as(usize, @intFromBool(nflag));
    var len: usize = 1;
    for (argv[@min(first, argv.len)..]) |a|
        len += a.len + 1;

    const buf = libc.allocator.alloc(u8, len) catch libc.exits("no memory");

    var p: usize = 0;
    var i = first;
    while (i < argv.len) : (i += 1) {
        const s = argv[i];
        @memcpy(buf[p..][0..s.len], s);
        p += s.len;
        if (i < argv.len - 1) {
            buf[p] = ' ';
            p += 1;
        }
    }

    if (!nflag) {
        buf[p] = '\n';
        p += 1;
    }

    _ = libc.write(1, buf[0..p]) catch {
        libc.fprint(2, "echo: write error: %r\n", .{});
        libc.exits("write error");
    };
}
