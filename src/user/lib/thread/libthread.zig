//! libthread: procs (processes that share memory), threads within a
//! proc (which run one at a time and switch only where they wait), and
//! the channels they talk through.  thread.h, and the library's
//! functions under their C names, as libc.zig is for libc.
//! from 9front 11952's /sys/src/libthread, one file per C file in
//! this directory (ioproc.zig holds the io*.c files)
//!
//! A threaded program has, in its root file:
//!
//!     pub const main = thread.main;
//!     pub fn threadmain(args: []const []const u8) void { ... }
//!
//! and optionally `pub const mainstacksize = n;`.  It ends with
//! threadexitsall, or when its last thread returns or calls
//! threadexits.  A thread must not call libc's spawn, or rfork with
//! RFMEM: procs are made with proccreate and procrfork, whose rfork is
//! done on the proc's own stack (a thread's stack is in shared memory,
//! where two processes cannot both run; fork, which shares none, is
//! safe).  Notes are taken with threadnotify, not atnotify.
//!
//! DIFF (all files):
//!   - A thread's function takes one argument of any type that fits
//!     in a word (a pointer, an integer, an enum, a bool, or void);
//!     threadcreate, proccreate and procrfork here wrap it.
//!   - Chan(T) is a channel of T with typed send and recv that return
//!     errors; the C's untyped channel is channel.zig's, under
//!     `Channel` and `chan`.
//!   - Stack sizes: see create.zig.  Debug prints, chanprint's and
//!     threadsetname's formats, procexecl, iodial: see the files.

const std = @import("std");
const libc = @import("libc");

const impl = @import("impl.zig");
const amd64 = @import("amd64.zig");
const channel_ = @import("channel.zig");
const chanprint_ = @import("chanprint.zig");
const create_ = @import("create.zig");
const exec_ = @import("exec.zig");
const exit_ = @import("exit.zig");
const id_ = @import("id.zig");
const ioproc_ = @import("ioproc.zig");
const kill_ = @import("kill.zig");
const main_ = @import("main.zig");
const note_ = @import("note.zig");
const ref_ = @import("ref.zig");
const sched_ = @import("sched.zig");

pub const main = main_.main;
pub const mainstacksize = main_.mainstacksize;

/// The untyped channel and its functions, as in C.
pub const chan = channel_;
pub const Channel = channel_.Channel;
pub const Alt = channel_.Alt;
pub const ChanOp = channel_.ChanOp;
pub const alt = channel_.alt;
pub const chanprint = chanprint_.chanprint;

pub const ChanError = error{
    /// The channel is closed.
    Closed,
    /// The thread was interrupted (threadint) while it waited.
    Interrupted,
};

/// A channel of values of type T.
pub fn Chan(comptime T: type) type {
    return struct {
        c: *Channel,

        const Self = @This();

        /// A channel with room for n values; 0 for one where each
        /// send waits for its receive.
        pub fn create(n: usize) Self {
            return .{ .c = channel_.chancreate(@sizeOf(T), n) orelse @panic("chancreate: element of size 0") };
        }

        pub fn free(s: Self) void {
            channel_.chanfree(s.c);
        }

        /// False if it was closed already.
        pub fn close(s: Self) bool {
            return channel_.chanclose(s.c);
        }

        /// How many values are left to receive from a closed channel;
        /// null if it is not closed.
        pub fn closing(s: Self) ?usize {
            const n = channel_.chanclosing(s.c);
            return if (n < 0) null else @intCast(n);
        }

        fn failed(s: Self) ChanError {
            return if (channel_.chanclosing(s.c) >= 0) error.Closed else error.Interrupted;
        }

        pub fn send(s: Self, v: T) ChanError!void {
            if (channel_.send(s.c, @ptrCast(&v)) < 0)
                return s.failed();
        }

        pub fn recv(s: Self) ChanError!T {
            var v: T = undefined;
            if (channel_.recv(s.c, @ptrCast(&v)) < 0)
                return s.failed();
            return v;
        }

        /// False if the value could not be sent at once.
        pub fn nbsend(s: Self, v: T) ChanError!bool {
            const r = channel_.nbsend(s.c, @ptrCast(&v));
            if (r < 0)
                return s.failed();
            return r != 0;
        }

        /// Null if there was nothing to receive.
        pub fn nbrecv(s: Self) ChanError!?T {
            var v: T = undefined;
            const r = channel_.nbrecv(s.c, @ptrCast(&v));
            if (r < 0)
                return s.failed();
            return if (r == 0) null else v;
        }

        /// An entry for alt: receive into v.
        pub fn rcv(s: Self, v: ?*T) Alt {
            return .{ .c = s.c, .v = @ptrCast(v), .op = .CHANRCV };
        }

        /// An entry for alt: send what v points to.
        pub fn snd(s: Self, v: *const T) Alt {
            return .{ .c = s.c, .v = @ptrCast(@constCast(v)), .op = .CHANSND };
        }
    };
}

/// The last entry of an alt that waits.
pub const altend: Alt = .{ .op = .CHANEND };
/// The last entry of an alt that does not wait.
pub const altnoblk: Alt = .{ .op = .CHANNOBLK };

fn toword(arg: anytype) usize {
    const T = @TypeOf(arg);
    return switch (@typeInfo(T)) {
        .void => 0,
        .pointer => @intFromPtr(arg),
        .optional => @intFromPtr(arg),
        .int => |i| if (i.signedness == .signed) @bitCast(@as(isize, arg)) else @as(usize, arg),
        .comptime_int => @bitCast(@as(isize, arg)),
        .bool => @intFromBool(arg),
        .@"enum" => @intFromEnum(arg),
        else => @compileError("a thread's argument must fit in a word"),
    };
}

fn fromword(comptime T: type, w: usize) T {
    return switch (@typeInfo(T)) {
        .void => {},
        .pointer, .optional => @ptrFromInt(w),
        .int => |i| if (i.signedness == .signed) @intCast(@as(isize, @bitCast(w))) else @intCast(w),
        .bool => w != 0,
        .@"enum" => @enumFromInt(w),
        else => @compileError("a thread's argument must fit in a word"),
    };
}

fn wrap(comptime f: anytype) amd64.Threadfn {
    const P = @typeInfo(@TypeOf(f)).@"fn".param_types[0].?;
    return struct {
        fn run(w: usize) void {
            f(fromword(P, w));
        }
    }.run;
}

/// Start a thread in this proc that runs f(arg); returns its id.  It
/// first runs when the caller waits or yields.
pub fn threadcreate(comptime f: anytype, arg: anytype, stacksize: usize) i32 {
    const P = @typeInfo(@TypeOf(f)).@"fn".param_types[0].?;
    return create_.threadcreate(wrap(f), toword(@as(P, arg)), stacksize);
}

/// Start a proc whose first thread runs f(arg); returns that thread's
/// id.
pub fn proccreate(comptime f: anytype, arg: anytype, stacksize: usize) i32 {
    const P = @typeInfo(@TypeOf(f)).@"fn".param_types[0].?;
    return create_.proccreate(wrap(f), toword(@as(P, arg)), stacksize);
}

/// As proccreate, with flags for the rfork besides RFPROC, RFMEM and
/// RFNOWAIT.
pub fn procrfork(comptime f: anytype, arg: anytype, stacksize: usize, rforkflag: u32) i32 {
    const P = @typeInfo(@TypeOf(f)).@"fn".param_types[0].?;
    return create_.procrfork(wrap(f), toword(@as(P, arg)), stacksize, rforkflag);
}

pub const Minstack = create_.Minstack;
pub const procexec = exec_.procexec;
pub const threadexits = exit_.threadexits;
pub const threadexitsall = exit_.threadexitsall;

/// The channel that gets the exit message of each program started by
/// procexec, once this has been called.
pub fn threadwaitchan() Chan(*libc.Waitmsg) {
    return .{ .c = exit_.threadwaitchan() };
}

pub const threadid = id_.threadid;
pub const threadpid = id_.threadpid;
pub const threadsetgrp = id_.threadsetgrp;
pub const threadgetgrp = id_.threadgetgrp;
pub const threadsetname = id_.threadsetname;
pub const threadgetname = id_.threadgetname;
pub const threaddata = id_.threaddata;
pub const procdata = id_.procdata;
pub const threadint = kill_.threadint;
pub const threadintgrp = kill_.threadintgrp;
pub const threadkill = kill_.threadkill;
pub const threadkillgrp = kill_.threadkillgrp;
pub const Notefn = note_.Notefn;
pub const threadnotify = note_.threadnotify;
pub const Ref = ref_.Ref;
pub const incref = ref_.incref;
pub const decref = ref_.decref;
pub const yield = sched_.yield;
pub const needstack = sched_.needstack;

pub const Ioproc = ioproc_.Ioproc;
pub const ioproc = ioproc_.ioproc;
pub const closeioproc = ioproc_.closeioproc;
pub const iointerrupt = ioproc_.iointerrupt;
pub const iocall = ioproc_.iocall;
pub const ioclose = ioproc_.ioclose;
pub const ioflush = ioproc_.ioflush;
pub const ioopen = ioproc_.ioopen;
pub const ioread = ioproc_.ioread;
pub const ioreadn = ioproc_.ioreadn;
pub const iosleep = ioproc_.iosleep;
pub const iowrite = ioproc_.iowrite;

/// The most a thread's stack has held so far, in bytes, for the thread
/// that asks (the stack is filled with 0xFE when it is made).
pub fn stackused() usize {
    const t = impl.getproc().thread.?;
    var i: usize = 0;
    while (i < t.stk.len and t.stk[i] == 0xFE)
        i += 1;
    return t.stk.len - i;
}
