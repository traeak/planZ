//! xargs - run a command with arguments from standard input
//! from cmd/xargs.c
//!
//! DIFF: a line with a 0 byte in it is cut there, as the C's strings
//! are.

const std = @import("std");
const libc = @import("libc");

fn usage() noreturn {
    libc.fprint(2, "usage: xargs [ -n lines ] [ -p procs ] args ...\n", .{});
    libc.exits("usage");
}

fn dowait() void {
    while (true)
        _ = libc.waitpid() catch break;
}

var bp: libc.Biobuf = .{};

pub fn main(argv: []const []const u8) void {
    const a = libc.allocator;
    var lines: i64 = 10;
    var procs: i64 = 1;

    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'n' => lines = libc.atoi(args.value() orelse usage()),
        'p' => procs = libc.atoi(args.value() orelse usage()),
        else => usage(),
    };
    const cmd = args.rest();
    if (cmd.len < 1)
        usage();

    const nl: usize = @intCast(@max(lines, 0));
    const nargv = a.alloc([]const u8, cmd.len + nl) catch libc.sysfatal("malloc: %r", .{});
    const whole = a.alloc([]u8, nl) catch libc.sysfatal("malloc: %r", .{});
    @memcpy(nargv[0..cmd.len], cmd);
    bp.init(0, libc.OREAD);
    _ = libc.atexit(dowait);
    var j: i64 = 0;
    var run = true;
    while (run) : (j += 1) {
        if (j >= procs)
            _ = libc.waitpid() catch 0;
        var n: usize = 0;
        while (n < nl) : (n += 1) {
            const s = (bp.rdstr(a, '\n') catch libc.sysfatal("malloc: %r", .{})) orelse {
                if (n == 0)
                    libc.exits(null);
                run = false;
                break;
            };
            whole[n] = s;
            nargv[cmd.len + n] = s[0 .. std.mem.findScalar(u8, s, 0) orelse s.len];
        }
        const av = nargv[0 .. cmd.len + n];
        const pid = libc.fork() catch libc.sysfatal("fork: %r", .{});
        if (pid == 0) {
            libc.exec(av[0], av) catch {};
            if (!std.mem.startsWith(u8, av[0], "/") and !std.mem.startsWith(u8, av[0], "./") and
                !std.mem.startsWith(u8, av[0], "../"))
            {
                var pb: [1024]u8 = undefined;
                av[0] = libc.sprint(&pb, "/bin/%s", .{av[0]});
                libc.exec(av[0], av) catch {};
            }
            libc.sysfatal("exec: %r", .{});
        }
        for (whole[0..n]) |s|
            a.free(s);
    }
    libc.exits(null);
}
