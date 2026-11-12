//! cat - catenate files
//! from cmd/cat.c

const libc = @import("libc");

const IOUNIT = 32768; // default buffer size for 9p io

var buf: [IOUNIT]u8 = undefined;

fn cat(f: i32, s: []const u8) void {
    while (true) {
        const n = libc.read(f, &buf) catch
            libc.sysfatal("error reading %s: %r", .{s});
        if (n == 0)
            break;
        if ((libc.write(1, buf[0..n]) catch 0) != n)
            libc.sysfatal("write error copying %s: %r", .{s});
    }
}

pub fn main(argv: []const []const u8) void {
    libc.argv0 = "cat";
    if (argv.len == 1) {
        cat(0, "<stdin>");
    } else for (argv[1..]) |a| {
        const f = libc.open(a, libc.OREAD) catch
            libc.sysfatal("can't open %s: %r", .{a});
        cat(f, a);
        libc.close(f) catch {};
    }
}
