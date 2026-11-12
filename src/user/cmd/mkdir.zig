//! mkdir - make a directory
//! from cmd/mkdir.c

const std = @import("std");
const libc = @import("libc");

var e: ?[]const u8 = null;
var mode: u32 = 0o777;

fn usage() noreturn {
    libc.fprint(2, "usage: mkdir [-p] [-m mode] dir...\n", .{});
    libc.exits("usage");
}

fn makedir(s: []const u8) bool {
    if (libc.access(s, libc.AEXIST)) {
        libc.fprint(2, "mkdir: %s already exists\n", .{s});
        e = "error";
        return false;
    }
    const f = libc.create(s, libc.OREAD, libc.DMDIR | mode) catch {
        libc.fprint(2, "mkdir: can't create %s: %r\n", .{s});
        e = "error";
        return false;
    };
    libc.close(f) catch {};
    return true;
}

fn mkdirp(s: []const u8) void {
    // DIFF: prefixes of the slice, where the C writes a NUL at each '/'
    var p: usize = 1;
    while (p < s.len) : (p += 1) {
        if (s[p] != '/')
            continue;
        if (!libc.access(s[0..p], libc.AEXIST) and !makedir(s[0..p]))
            return;
    }
    if (!libc.access(s, libc.AEXIST))
        _ = makedir(s);
}

pub fn main(argv: []const []const u8) void {
    var pflag = false;
    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'm' => {
            const m = args.value() orelse usage();
            const r = libc.strtoul(m, 8);
            if (r.v > 0o777)
                usage();
            mode = @intCast(r.v);
        },
        'p' => pflag = true,
        else => usage(),
    };
    for (args.rest()) |d| {
        if (pflag)
            mkdirp(d)
        else
            _ = makedir(d);
    }
    libc.exits(e);
}
