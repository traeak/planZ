//! tprimes - the prime sieve, a thread or a proc for each prime
//! from libthread/tprimes.c, the library's own test
//!
//! usage: tprimes [-q] [-b bufsize] [-p] [goal]
//!
//! DIFF:
//!   - The threads ask for the library's smallest stack; the C's ask
//!     for 1,024 bytes.

const std = @import("std");
const libc = @import("libc");
const thread = @import("thread");

pub const main = thread.main;

const Chan = thread.Chan(u32);

var quiet = false;
var goal: u32 = 100;
var buffer: usize = 0;
var procs = false;

fn start(c: *thread.Channel) void {
    if (procs)
        _ = thread.proccreate(primethread, c, 1024)
    else
        _ = thread.threadcreate(primethread, c, 1024);
}

fn primethread(arg: *thread.Channel) void {
    const c: Chan = .{ .c = arg };
    const p = thread.chan.recvul(c.c);
    if (p > goal)
        thread.threadexitsall(null);
    if (!quiet)
        libc.print("%d\n", .{p});
    const nc = Chan.create(buffer);
    start(nc.c);
    while (true) {
        const i = thread.chan.recvul(c.c);
        if (i % p != 0)
            _ = thread.chan.sendul(nc.c, i);
    }
}

pub fn threadmain(argv: []const []const u8) void {
    var args = libc.Args.init(argv);
    while (args.next()) |f| switch (f) {
        'q' => quiet = true,
        'b' => buffer = @intCast(libc.atoi(args.value() orelse "0")),
        'p' => procs = true,
        else => {},
    };
    if (args.rest().len > 0)
        goal = @intCast(libc.atoi(args.rest()[0]));

    const c = Chan.create(buffer);
    _ = thread.threadcreate(primethread, c.c, 1024);
    var i: u32 = 2;
    while (true) : (i += 1)
        _ = thread.chan.sendul(c.c, i);
}
