//! srv - start a network file service: post a connection in /srv, and
//! perhaps mount it
//! from /sys/src/cmd/srv.c
//!
//! usage: srv [-abcCmnNq] [net!]host [srvname [mtpt]]
//!     or srv -e [-abcCmnNq] command [srvname [mtpt]]
//!
//! DIFF:
//!   - Without -e the connection is dialed, and the library has no
//!     dial yet (netmkaddr, dial: with the network's programs): srv
//!     says so and exits "dial".  With -e, and when the /srv file is
//!     already there, it is the C.
//!
//! Kept from C: the note handler prints "write on closed pipe" for
//! every note that is not that one and goes on, and lets that one
//! (and no other) end the program; the test reads inverted.

const std = @import("std");
const libc = @import("libc");
const auth = @import("auth");
const sys = libc.sys;

var dest: []const u8 = "system";
var mountflag: u32 = sys.MREPL;
var doauth = true;
var asnone = false;

fn usage() noreturn {
    libc.fprint(2, "usage: %s [-abcCmnNq] [net!]host [srvname [mtpt]]\n", .{libc.argv0});
    libc.fprint(2, "    or %s -e [-abcCmnNq] command [srvname [mtpt]]\n", .{libc.argv0});

    libc.exits("usage");
}

comptime {
    asm (
        \\ .text
        \\ .globl _srvnotetramp
        \\_srvnotetramp:
        \\ movq 8(%rsp), %rdi
        \\ movq 16(%rsp), %rsi
        \\ andq $-16, %rsp
        \\ call _srvignore
        \\ hlt
    );
}

extern fn _srvnotetramp() callconv(.c) void;

export fn _srvignore(_: ?*anyopaque, m: [*]const u8) callconv(.c) void {
    const c = sys.span(m);
    if (std.mem.eql(u8, c, "alarm")) {
        libc.fprint(2, "srv: timeout establishing connection to %s\n", .{dest});
        libc.exits("timeout");
    }
    if (std.mem.indexOf(u8, c, "write on closed pipe") == null) {
        libc.fprint(2, "write on closed pipe\n", .{});
        _ = sys.noted(sys.NCONT);
    }
    _ = sys.noted(sys.NDFLT);
}

fn connectcmd(cmd: []const u8) isize {
    var p: [2]i32 = undefined;

    if (sys.pipe(&p) < 0)
        return -1;
    const pid = sys.rfork(sys.RFPROC | sys.RFFDG | sys.RFREND);
    if (pid < 0) {
        libc.fprint(2, "fork failed: %r\n", .{});
        sys.exits("exec");
    }
    if (pid == 0) {
        _ = sys.rfork(sys.RFNOTEG);
        _ = sys.dup(p[0], 0);
        _ = sys.dup(p[0], 1);
        _ = sys.close(p[0]);
        _ = sys.close(p[1]);
        _ = libc.exec("/bin/rc", &.{ "rc", "-c", cmd }) catch {};
        libc.fprint(2, "exec failed: %r\n", .{});
        sys.exits("exec");
    }
    _ = sys.close(p[0]);
    return p[1];
}

fn last(s: []const u8) []const u8 {
    const p = if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| s[i + 1 ..] else s;
    return p;
}

fn afterbang(p: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, p, '!')) |i| p[i + 1 ..] else p;
}

pub fn main(argv_: []const []const u8) void {
    var srvbuf: [1024]u8 = undefined;
    var mtbuf: [1024]u8 = undefined;
    var err: [libc.ERRMAX]u8 = undefined;
    var fd: isize = -1;

    _ = sys.notify(&_srvnotetramp);

    var domount = false;
    var reallymount = false;
    var doexec = false;
    var sleeptime: u32 = 0;

    var args = libc.Args.init(argv_);
    while (args.next()) |c| switch (c) {
        'a' => {
            mountflag |= sys.MAFTER;
            domount = true;
            reallymount = true;
        },
        'b' => {
            mountflag |= sys.MBEFORE;
            domount = true;
            reallymount = true;
        },
        'c' => {
            mountflag |= sys.MCREATE;
            domount = true;
            reallymount = true;
        },
        'C' => {
            mountflag |= sys.MCACHE;
            domount = true;
            reallymount = true;
        },
        'e' => doexec = true,
        'm' => {
            domount = true;
            reallymount = true;
        },
        'N' => {
            asnone = true;
            doauth = false;
        },
        'n' => doauth = false,
        'q' => {
            domount = true;
            reallymount = false;
        },
        'r' => {}, // deprecated -r flag; ignored for compatibility
        's' => sleeptime = @intCast(libc.atoi(args.value() orelse usage())),
        else => usage(),
    };
    const argv = args.rest();

    if ((mountflag & sys.MAFTER) != 0 and (mountflag & sys.MBEFORE) != 0)
        usage();

    var srv: []const u8 = undefined;
    var mtpt: []const u8 = undefined;
    switch (argv.len) {
        1 => { // calculate srv and mtpt from address
            const p = last(argv[0]);
            srv = libc.sprint(&srvbuf, "/srv/%s", .{p});
            mtpt = libc.sprint(&mtbuf, "/n/%s", .{afterbang(p)});
        },
        2 => { // calculate mtpt from address, srv given
            srv = libc.sprint(&srvbuf, "/srv/%s", .{argv[1]});
            mtpt = libc.sprint(&mtbuf, "/n/%s", .{afterbang(last(argv[0]))});
        },
        3 => { // srv and mtpt given
            domount = true;
            reallymount = true;
            srv = libc.sprint(&srvbuf, "/srv/%s", .{argv[1]});
            mtpt = libc.sprint(&mtbuf, "%s", .{argv[2]});
        },
        else => usage(),
    }

    var tries: u32 = 0;
    dest = argv[0];
    while (true) {
        tries += 1;

        var have = false;
        if (libc.access(srv, libc.AEXIST)) {
            if (domount) {
                fd = sys.open(srv, sys.ORDWR);
                if (fd >= 0)
                    have = true
                else
                    _ = sys.remove(srv);
            } else {
                libc.fprint(2, "srv: %s already exists\n", .{srv});
                libc.exits(null);
            }
        }

        if (!have) {
            _ = sys.alarm(10000);
            if (doexec)
                fd = connectcmd(dest)
            else {
                // DIFF: see the header
                libc.werrstr("no dial in this library yet", .{});
                fd = -1;
            }
            if (fd < 0) {
                libc.fprint(2, "srv: dial %s: %r\n", .{dest});
                libc.exits("dial");
            }
            _ = sys.alarm(0);

            if (sleeptime != 0) {
                libc.fprint(2, "sleep...", .{});
                _ = sys.sleep(sleeptime * 1000);
            }

            post(srv, @intCast(fd));
        }

        // Mount:
        if (!domount or !reallymount)
            libc.exits(null);

        if (asnone) {
            auth.procsetuser("none") catch {
                libc.fprint(2, "srv %s: can't become none: %r\n", .{dest});
                libc.exits("becomenone");
            };
            tries = 0; // no retry
        }

        const failed = if (!doauth)
            sys.mount(fd, -1, mtpt, mountflag, "") < 0
        else if (auth.amount(@intCast(fd), mtpt, mountflag, "")) |_| false else |_| true;
        if (failed) {
            const e = libc.rerrstr(&err);
            const has = std.mem.indexOf;
            if (has(u8, e, "Hangup") != null or has(u8, e, "hungup") != null or has(u8, e, "timed out") != null) {
                _ = sys.remove(srv);
                if (tries == 1)
                    continue;
            }
            libc.fprint(2, "srv %s: mount failed: %s\n", .{ dest, e });
            libc.exits("mount");
        }
        libc.exits(null);
    }
}

fn post(srv: []const u8, fd: i32) void {
    var buf: [128]u8 = undefined;

    libc.fprint(2, "post...\n", .{});
    const f = sys.create(srv, sys.OWRITE, 0o666);
    if (f < 0)
        fail(libc.sprint(&buf, "create(%s)", .{srv}));
    const s = libc.sprint(&buf, "%d", .{fd});
    if (sys.write(f, s) != s.len)
        fail("write");
}

fn fail(s: []const u8) noreturn {
    libc.fprint(2, "srv %s: %s: %r\n", .{ dest, s });
    libc.exits("srv: error");
}
