//! A threaded program's start, and the processes the scheduler makes.
//! from libthread/main.c
//!
//! DIFF:
//!   - The program's root has `pub const main = thread.main;` and a
//!     `pub fn threadmain`, with no arguments or the arguments as a
//!     slice, returning void or an error union; an error ends all the
//!     procs with its name (the error string for error.Plan9), after
//!     printing it.  `pub const mainstacksize` there sets the main
//!     thread's stack; the default is 64K where the C's is 8K.
//!   - _schedfork's child enters schedinit on the stack as it was in
//!     main, where the C longjmps to main's setjmp.
//!   - assert is Zig's: a failure is a panic, which ends all the procs
//!     (libc's fatalhook), where the C's __assert prints the thread
//!     and aborts.

const std = @import("std");
const root = @import("root");
const libc = @import("libc");
const sys = libc.sys;
const impl = @import("impl.zig");
const amd64 = @import("amd64.zig");
const create = @import("create.zig");
const sched = @import("sched.zig");
const rendez = @import("rendez.zig");
const note = @import("note.zig");
const lib = @import("lib.zig");
const exit = @import("exit.zig");
const channel = @import("channel.zig");

const Proc = impl.Proc;
const Execargs = impl.Execargs;

const program = root.program;

pub const mainstacksize: usize = if (@hasDecl(program, "mainstacksize")) program.mainstacksize else 64 * 1024;

var mainsp: usize = 0;
var mainargs: []const []const u8 = &.{};

fn mainlauncher(_: usize) void {
    const tm = program.threadmain;
    const Main = @typeInfo(@TypeOf(tm)).@"fn";
    const r = if (Main.param_types.len == 0) tm() else tm(mainargs);
    switch (@typeInfo(Main.return_type.?)) {
        .error_union => {
            r catch |e| {
                if (e == error.Plan9) {
                    var buf: [sys.ERRMAX]u8 = undefined;
                    const m = libc.rerrstr(&buf);
                    libc.fprint(2, "%s: %s\n", .{ libc.argv0, m });
                    exit.threadexitsall(m);
                }
                libc.fprint(2, "%s: %s\n", .{ libc.argv0, @errorName(e) });
                exit.threadexitsall(@errorName(e));
            };
        },
        .void, .noreturn => {},
        else => @compileError("threadmain must return void or !void"),
    }
    exit.threadexits("threadmain");
}

pub fn main(args: []const []const u8) noreturn {
    _ = sys.rfork(sys.RFREND);

    impl.threadprocp = libc.privalloc() orelse libc.sysfatal("libthread: no private word", .{});
    libc.qlockinit(rendez.threadrendezvous);
    libc.fatalhook = lib.threadsysfatal;
    note.init();
    mainargs = args;
    impl.setproc(create.newproc(mainlauncher, 0, mainstacksize, "threadmain", 0, 0));
    mainsp = amd64.getsp() - 256;
    sched.schedinit();
}

fn efork(e: *Execargs) noreturn {
    var buf: [sys.ERRMAX]u8 = undefined;

    _ = sys.close(e.fd[0]);
    _ = libc.exec(e.prog, e.args) catch {};
    var m = libc.rerrstr(&buf);
    if (m.len == 0)
        m = "exec failed";
    _ = sys.write(e.fd[1], m);
    sys.exits(m);
}

pub fn schedexec(e: *Execargs) i32 {
    const flag: u32 = if (exit.waitchan == null) sys.RFNOWAIT else 0;
    const pid = sys.rfork(sys.RFREND | sys.RFNOTEG | sys.RFFDG | sys.RFMEM | sys.RFPROC | flag);
    if (pid == 0)
        efork(e);
    return @intCast(pid);
}

pub fn schedfork(p: *Proc) i32 {
    const pid = sys.rfork(sys.RFPROC | sys.RFMEM | sys.RFNOWAIT | p.rforkflag);
    if (pid == 0) {
        impl.setproc(p);
        amd64.callon(mainsp, sched.schedinit);
    }
    return @intCast(pid);
}

pub fn schedexit(p: *Proc) noreturn {
    var ex: [sys.ERRMAX]u8 = undefined;
    const m = p.exitmsg();
    @memcpy(ex[0..m.len], m);
    const n = m.len;
    libc.allocator.destroy(p);
    sys.exits(if (n == 0) null else ex[0..n]);
}

pub fn schedexecwait() noreturn {
    const p = impl.getproc();
    const t = p.thread.?;
    const pid = t.ret;

    _ = sys.rfork(sys.RFCFDG);
    var got: ?libc.Waitmsg = null;
    while (true) {
        const w = libc.wait() catch break;
        if (w.pid == pid) {
            got = w;
            break;
        }
    }
    if (got) |w| {
        if (exit.waitchan) |c| {
            const wp = lib.create1(libc.Waitmsg, w);
            _ = channel.sendp(c, wp);
        }
    }
    exit.threadexits("procexec");
}
