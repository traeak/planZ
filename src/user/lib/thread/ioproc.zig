//! Slave I/O processes: a proc that makes the system calls that block,
//! for a thread that must stay able to be interrupted.
//! from libthread/ioproc.c, iocall.c, and ioclose.c, ioflush.c,
//! ioopen.c, ioread.c, ioreadn.c, iosleep.c, iowrite.c, which are a
//! few lines each and are together here
//!
//! DIFF:
//!   - iocall takes the operation as a function and its arguments as a
//!     tuple (the C: a function of a va_list, and the arguments after
//!     it).  The operation returns an isize, below 0 with the error
//!     string set for a failure, as a system call does.
//!   - The calls return error unions; error.Plan9 has the I/O proc's
//!     error string, or "interrupted".
//!   - No iodial: the library has no dial yet.

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const impl = @import("impl.zig");
const channel = @import("channel.zig");
const create = @import("create.zig");

const Channel = channel.Channel;
const Error = libc.Error;

const STACK = 8192;

pub const Ioproc = struct {
    ql: libc.QLock = .{},
    intr: i32 = 0,
    ctl: i32 = -1,
    c: *Channel = undefined,
    creply: *Channel = undefined,
};

const Iocall = struct {
    op: *const fn (arg: *anyopaque) isize,
    arg: *anyopaque,
    ret: isize = 0,
    err: [sys.ERRMAX]u8 = undefined,
    errlen: usize = 0,
};

/// Break off the call io is making, which fails with "interrupted".
pub fn iointerrupt(io: *Ioproc) void {
    if (io.ctl < 0)
        return;
    libc.qlock(&io.ql);
    io.intr += 1;
    if (io.intr == 1)
        _ = sys.write(io.ctl, "interrupt");
    libc.qunlock(&io.ql);
}

fn openprocctl() i32 {
    var buf: [32]u8 = undefined;
    return @intCast(sys.open(libc.sprint(&buf, "/proc/%ud/ctl", .{libc.getpid()}), sys.OWRITE | sys.OCEXEC));
}

fn xioproc(a: usize) void {
    const c: *Channel = @ptrFromInt(a);
    var io: ?*Ioproc = libc.allocator.create(Ioproc) catch null;
    if (io) |x| {
        x.* = .{};
        // open might fail, ignore it for programs like factotum
        // that don't use iointerrupt() anyway.
        x.ctl = openprocctl();
        if (channel.chancreate(@sizeOf(?*anyopaque), 0)) |cr| {
            x.creply = cr;
            x.c = c;
        } else {
            if (x.ctl >= 0)
                _ = sys.close(x.ctl);
            libc.allocator.destroy(x);
            io = null;
        }
    }
    while (channel.send(c, @ptrCast(&io)) < 0) {}
    const x = io orelse return;

    while (true) {
        var r: ?*Iocall = null;
        while (channel.recv(x.c, @ptrCast(&r)) < 0) {}
        const call = r orelse break;
        if (impl.get(&x.intr) != 0) {
            call.ret = -1;
            call.errlen = libc.sprint(&call.err, "interrupted", .{}).len;
        } else {
            call.ret = call.op(call.arg);
            if (call.ret < 0)
                call.errlen = libc.rerrstr(&call.err).len;
        }
        libc.qlock(&x.ql);
        if (x.intr != 0) {
            x.intr = 0;
            if (x.ctl >= 0)
                _ = sys.write(x.ctl, "nointerrupt");
        }
        while (channel.send(x.creply, @ptrCast(&r)) < 0) {}
        libc.qunlock(&x.ql);
    }

    if (x.ctl >= 0)
        _ = sys.close(x.ctl);
    channel.chanfree(x.c);
    channel.chanfree(x.creply);
    libc.allocator.destroy(x);
}

/// Start an I/O proc.
pub fn ioproc() *Ioproc {
    const c = channel.chancreate(@sizeOf(?*anyopaque), 0) orelse libc.sysfatal("ioproc chancreate", .{});
    _ = create.proccreate(xioproc, @intFromPtr(c), STACK);
    var io: ?*Ioproc = null;
    while (channel.recv(c, @ptrCast(&io)) < 0) {}
    return io orelse libc.sysfatal("ioproc alloc", .{});
}

/// Break off what io is doing and end it.
pub fn closeioproc(io: ?*Ioproc) void {
    const x = io orelse return;
    iointerrupt(x);
    while (channel.sendp(x.c, null) < 0) {}
}

/// Have io call op with args, and wait for the result; a threadint
/// of the waiting thread interrupts the call.
pub fn iocall(io: *Ioproc, comptime op: anytype, args: anytype) Error!usize {
    const Args = @TypeOf(args);
    const W = struct {
        fn run(a: *anyopaque) isize {
            const p: *const Args = @ptrCast(@alignCast(a));
            return @call(.auto, op, p.*);
        }
    };
    var a = args;
    var r: Iocall = .{ .op = W.run, .arg = @ptrCast(&a) };

    if (channel.sendp(io.c, &r) < 0) {
        libc.werrstr("interrupted", .{});
        return error.Plan9;
    }
    while (channel.recv(io.creply, null) < 0) {
        if (io.ctl < 0)
            continue;
        if (libc.canqlock(&io.ql)) {
            io.intr += 1;
            if (io.intr == 1)
                _ = sys.write(io.ctl, "interrupt");
            libc.qunlock(&io.ql);
        }
    }
    if (r.ret < 0) {
        libc.werrstr("%s", .{r.err[0..r.errlen]});
        return error.Plan9;
    }
    return @intCast(r.ret);
}

fn _ioclose(fd: i32) isize {
    return sys.close(fd);
}

pub fn ioclose(io: *Ioproc, fd: i32) Error!void {
    _ = try iocall(io, _ioclose, .{fd});
}

fn _ioflush() isize {
    return 0;
}

/// Wait until io has done what it was given before.
pub fn ioflush(io: *Ioproc) Error!void {
    _ = try iocall(io, _ioflush, .{});
}

fn _ioopen(name: []const u8, mode: u32) isize {
    return sys.open(name, mode);
}

pub fn ioopen(io: *Ioproc, name: []const u8, mode: u32) Error!i32 {
    return @intCast(try iocall(io, _ioopen, .{ name, mode }));
}

fn _ioread(fd: i32, buf: []u8) isize {
    return sys.read(fd, buf);
}

pub fn ioread(io: *Ioproc, fd: i32, buf: []u8) Error!usize {
    return iocall(io, _ioread, .{ fd, buf });
}

fn _ioreadn(fd: i32, buf: []u8) isize {
    var t: usize = 0;
    while (t < buf.len) {
        const m = sys.read(fd, buf[t..]);
        if (m <= 0) {
            if (t == 0)
                return m;
            break;
        }
        t += @intCast(m);
    }
    return @intCast(t);
}

pub fn ioreadn(io: *Ioproc, fd: i32, buf: []u8) Error!usize {
    return iocall(io, _ioreadn, .{ fd, buf });
}

fn _iosleep(ms: u32) isize {
    return sys.sleep(ms);
}

pub fn iosleep(io: *Ioproc, ms: u32) Error!void {
    _ = try iocall(io, _iosleep, .{ms});
}

fn _iowrite(fd: i32, buf: []const u8) isize {
    return sys.write(fd, buf);
}

pub fn iowrite(io: *Ioproc, fd: i32, buf: []const u8) Error!usize {
    return iocall(io, _iowrite, .{ fd, buf });
}
