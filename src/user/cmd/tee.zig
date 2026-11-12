//! tee - pipe fitting
//! from cmd/tee.c

const std = @import("std");
const libc = @import("libc");

const FDSTART = 3;

var in: [libc.IOUNIT]u8 = undefined;

fn intignore(_: *anyopaque, msg: []const u8) bool {
    return std.mem.eql(u8, msg, "interrupt");
}

pub fn main(argv: []const []const u8) void {
    var aflag = false;
    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'a' => aflag = true,
        'i' => _ = libc.atnotify(intignore, true),
        'u' => {}, // uflag is ignored and undocumented; it's a relic from Unix
        else => {
            libc.fprint(2, "usage: tee [-ai] [file ...]\n", .{});
            libc.exits("usage");
        },
    };

    var n: i32 = 0;
    for (args.rest()) |f| {
        const fd = if (aflag) blk: {
            const i = libc.open(f, libc.OWRITE) catch
                libc.create(f, libc.OWRITE, 0o666) catch null;
            if (i) |x| _ = libc.seek(x, 0, 2) catch {};
            break :blk i;
        } else libc.create(f, libc.OWRITE, 0o666) catch null;
        if (fd) |i| {
            if (i != n + FDSTART)
                _ = libc.dup(i, n + FDSTART) catch {};
            n += 1;
        } else libc.fprint(2, "tee: cannot open %s: %r\n", .{f});
    }

    while (true) {
        const r = libc.read(0, &in) catch 0;
        if (r == 0)
            libc.exits(null);
        var i: i32 = 0;
        while (i < n) : (i += 1)
            _ = libc.sys.write(i + FDSTART, in[0..r]);
        _ = libc.sys.write(1, in[0..r]);
    }
}
