//! bind - change the name space
//! from cmd/bind.c

const libc = @import("libc");

pub fn main(argv: []const []const u8) void {
    var flag: u32 = 0;
    var qflag = false;

    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'a' => flag |= libc.sys.MAFTER,
        'b' => flag |= libc.sys.MBEFORE,
        'c' => flag |= libc.sys.MCREATE,
        'q' => qflag = true,
        else => usage(),
    };
    const a = args.rest();
    if (a.len != 2 or ((flag & libc.sys.MAFTER) != 0 and (flag & libc.sys.MBEFORE) != 0))
        usage();

    libc.bind(a[0], a[1], flag) catch {
        if (qflag)
            libc.exits(null);
        // try to give a less confusing error than the default
        if (!libc.access(a[0], 0))
            libc.fprint(2, "bind: %s: %r\n", .{a[0]})
        else if (!libc.access(a[1], 0))
            libc.fprint(2, "bind: %s: %r\n", .{a[1]})
        else
            libc.fprint(2, "bind %s %s: %r\n", .{ a[0], a[1] });
        libc.exits("bind");
    };
    libc.exits(null);
}

fn usage() noreturn {
    libc.fprint(2, "usage: bind [-b|-a|-c|-bc|-ac] new old\n", .{});
    libc.exits("usage");
}
