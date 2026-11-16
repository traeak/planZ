//! mount - attach a 9P service to the name space
//! from /sys/src/cmd/mount.c
//!
//! usage: mount [-a|-b] [-cCnNq] [-k keypattern] /srv/service dir [spec]

const std = @import("std");
const libc = @import("libc");
const auth = @import("auth");
const sys = libc.sys;

var keyspec: []const u8 = "";
var spec: []const u8 = "";
var flag: u32 = sys.MREPL;
var qflag = false;
var noauth = false;
var asnone = false;

fn amount0(fd: i32, mntpt: []const u8, flags: u32, aname: []const u8, keys: []const u8) isize {
    const afd = sys.fauth(fd, aname);
    if (afd >= 0) {
        if (auth.auth_proxy(@intCast(afd), auth.amount_getkey, "proto=p9any role=client %s", .{keys})) |ai|
            auth.auth_freeAI(ai)
        else |_|
            libc.fprint(2, "%s: auth_proxy: %r\n", .{libc.argv0});
    }
    const rv = sys.mount(fd, afd, mntpt, flags, aname);
    if (afd >= 0)
        _ = sys.close(afd);
    return rv;
}

comptime {
    asm (
        \\ .text
        \\ .globl _mountnotetramp
        \\_mountnotetramp:
        \\ movq 8(%rsp), %rdi
        \\ movq 16(%rsp), %rsi
        \\ andq $-16, %rsp
        \\ call _mountcatch
        \\ hlt
    );
}

extern fn _mountnotetramp() callconv(.c) void;

// DIFF: the kernel enters a note handler the Plan 9 way, so a small
// trampoline calls it (as libc's atnotify has).
export fn _mountcatch(_: ?*anyopaque, m: [*]const u8) callconv(.c) void {
    const s = sys.span(m);
    libc.fprint(2, "%s: %s\n", .{ libc.argv0, s });
    libc.exits(s);
}

pub fn main(argv_: []const []const u8) void {
    var args = libc.Args.init(argv_);
    while (args.next()) |c| switch (c) {
        'a' => flag |= sys.MAFTER,
        'b' => flag |= sys.MBEFORE,
        'c' => flag |= sys.MCREATE,
        'C' => flag |= sys.MCACHE,
        'k' => keyspec = args.value() orelse usage(),
        'N' => {
            asnone = true;
            noauth = true;
        },
        'n' => noauth = true,
        'q' => qflag = true,
        else => usage(),
    };
    const argv = args.rest();

    if (argv.len == 3)
        spec = argv[2]
    else if (argv.len != 2)
        usage();

    if ((flag & sys.MAFTER) != 0 and (flag & sys.MBEFORE) != 0)
        usage();

    const fd = sys.open(argv[0], sys.ORDWR);
    if (fd < 0) {
        if (qflag)
            libc.exits(null);
        libc.fprint(2, "%s: can't open %s: %r\n", .{ libc.argv0, argv[0] });
        libc.exits("open");
    }

    if (asnone) {
        auth.procsetuser("none") catch {
            if (qflag)
                libc.exits(null);
            libc.fprint(2, "%s: can't become none: %r\n", .{libc.argv0});
            libc.exits("becomenone");
        };
    }

    _ = sys.notify(&_mountnotetramp);
    const rv = if (noauth)
        sys.mount(fd, -1, argv[1], flag, spec)
    else
        amount0(@intCast(fd), argv[1], flag, spec, keyspec);
    if (rv < 0) {
        if (qflag)
            libc.exits(null);
        libc.fprint(2, "%s: mount %s: %r\n", .{ libc.argv0, argv[1] });
        libc.exits("mount");
    }
    libc.exits(null);
}

fn usage() noreturn {
    libc.fprint(2, "usage: mount [-a|-b] [-cCnNq] [-k keypattern] /srv/service dir [spec]\n", .{});
    libc.exits("usage");
}
