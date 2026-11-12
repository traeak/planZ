//! touch - set a file's modification time
//! from cmd/touch.c

const libc = @import("libc");

var now: u32 = 0;

fn usage() noreturn {
    libc.fprint(2, "usage: touch [-c] [-t time] files\n", .{});
    libc.exits("usage");
}

pub fn main(argv: []const []const u8) void {
    var nocreate = false;
    var status = false;

    now = @truncate(@as(u64, @bitCast(libc.time())));
    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        't' => {
            const t = args.value() orelse usage();
            const r = libc.strtoul(t, 0);
            if (r.n == 0 or r.n != t.len)
                usage();
            now = @truncate(r.v);
        },
        'c' => nocreate = true,
        else => usage(),
    };
    const files = args.rest();
    if (files.len == 0)
        usage();
    for (files) |f| {
        if (!touch(nocreate, f))
            status = true;
    }
    if (status)
        libc.exits("touch");
}

fn touch(nocreate: bool, name: []const u8) bool {
    var stbuff = libc.nulldir();
    stbuff.mtime = now;
    if (libc.dirwstat(name, &stbuff)) |_|
        return true
    else |_| {}
    if (nocreate) {
        libc.fprint(2, "touch: %s: cannot wstat: %r\n", .{name});
        return false;
    }
    const fd = libc.create(name, libc.OREAD | libc.OEXCL, 0o666) catch {
        libc.fprint(2, "touch: %s: cannot create: %r\n", .{name});
        return false;
    };
    libc.dirfwstat(fd, &stbuff) catch {};
    libc.close(fd) catch {};
    return true;
}
