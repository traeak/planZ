//! Processes, the environment and notes.
//! from libc/9sys/fork.c, wait.c, waitpid.c, getpid.c, getenv.c,
//! putenv.c, postnote.c and libc/port/atnotify.c
//!
//! DIFF:
//!   - wait returns the Waitmsg by value, the exit message in it (at
//!     most ERRMAX bytes, which is what the kernel keeps); the C
//!     mallocs it.
//!   - getenv returns memory from the allocator passed in, or null if
//!     the variable is not set; putenv takes the value as a slice.
//!   - atnotify's functions take the message as a slice.  The kernel
//!     enters a note handler the Plan 9 way (a null return address,
//!     then the Ureg pointer and the message, on the stack), so a small
//!     trampoline calls the Zig notifier.

const std = @import("std");
const sys = @import("sys.zig");
const libc = @import("libc.zig");
const string = @import("string.zig");

const Allocator = std.mem.Allocator;
const Error = libc.Error;

pub fn fork() Error!i32 {
    return libc.rfork(sys.RFPROC | sys.RFFDG | sys.RFREND);
}

pub fn getpid() u32 {
    return libc.tos.pid;
}

pub const Waitmsg = struct {
    pid: i32,
    /// of child and its children; user, system, real
    time: [3]u32,
    msgbuf: [sys.ERRMAX]u8,
    msglen: usize,

    /// The exit message; empty for a normal exit.
    pub fn msg(w: *const Waitmsg) []const u8 {
        return w.msgbuf[0..w.msglen];
    }
};

/// Wait for a child to exit.
pub fn wait() Error!Waitmsg {
    var buf: [512]u8 = undefined;
    const n = sys.await(buf[0 .. buf.len - 1]);
    if (n < 0)
        return error.Plan9;
    var fld: [5][]u8 = undefined;
    if (string.tokenize(buf[0..@intCast(n)], &fld) != fld.len) {
        libc.werrstr("couldn't parse wait message", .{});
        return error.Plan9;
    }
    var w: Waitmsg = .{
        .pid = @truncate(string.atoi(fld[0])),
        .time = .{
            @truncate(@as(u64, @bitCast(string.atoi(fld[1])))),
            @truncate(@as(u64, @bitCast(string.atoi(fld[2])))),
            @truncate(@as(u64, @bitCast(string.atoi(fld[3])))),
        },
        .msgbuf = undefined,
        .msglen = @min(fld[4].len, sys.ERRMAX),
    };
    @memcpy(w.msgbuf[0..w.msglen], fld[4][0..w.msglen]);
    return w;
}

/// Wait for a child to exit and return its pid.
pub fn waitpid() Error!i32 {
    return (try wait()).pid;
}

fn envname(buf: []u8, name: []const u8) Error![]const u8 {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.findScalar(u8, name, '/') != null or std.mem.findScalar(u8, name, 0) != null or
        name.len >= buf.len - 5)
    {
        libc.werrstr("bad env name: %s", .{name});
        return error.Plan9;
    }
    return libc.sprint(buf, "/env/%s", .{name});
}

/// The value of an environment variable, or null if it is not set.
/// NULs (between the elements of a list) become spaces, as in C.
pub fn getenv(a: Allocator, name: []const u8) (Error || Allocator.Error)!?[]u8 {
    var path: [100]u8 = undefined;
    const p = try envname(&path, name);
    const f = libc.open(p, sys.OREAD | sys.OCEXEC) catch
        return null;
    defer _ = sys.close(f);
    var s: std.ArrayList(u8) = .empty;
    errdefer s.deinit(a);
    while (true) {
        try s.ensureUnusedCapacity(a, 100);
        const r = sys.read(f, s.unusedCapacitySlice());
        if (r < 0)
            return error.Plan9;
        if (r == 0)
            break;
        s.items.len += @intCast(r);
    }
    var n = s.items.len;
    while (n > 0 and s.items[n - 1] == 0)
        n -= 1;
    s.items.len = n;
    for (s.items) |*c| {
        if (c.* == 0)
            c.* = ' ';
    }
    return try s.toOwnedSlice(a);
}

pub fn putenv(name: []const u8, val: []const u8) Error!void {
    var path: [100]u8 = undefined;
    const p = try envname(&path, name);
    const f = try libc.create(p, sys.OWRITE | sys.OCEXEC, 0o664);
    defer _ = sys.close(f);
    if (try libc.write(f, val) != val.len)
        return error.Plan9;
}

pub const PNPROC = 1;
pub const PNGROUP = 2;

/// Send a note to a process or its note group.
pub fn postnote(group: u32, pid: u32, note: []const u8) Error!void {
    var file: [32]u8 = undefined;
    const s = switch (group) {
        PNPROC => libc.sprint(&file, "/proc/%ud/note", .{pid}),
        PNGROUP => libc.sprint(&file, "/proc/%ud/notepg", .{pid}),
        else => {
            libc.werrstr("bad note group", .{});
            return error.Plan9;
        },
    };
    const f = try libc.open(s, sys.OWRITE | sys.OCEXEC);
    defer _ = sys.close(f);
    if (try libc.write(f, note) != note.len)
        return error.Plan9;
}

/// A note handler: returns true if it handled the note.
pub const Notefn = *const fn (ureg: *anyopaque, msg: []const u8) bool;

const NFN = 33;
var onnot: [NFN]?Notefn = @splat(null);
var onnotlock: u32 = 0;
var init = false;

comptime {
    asm (
        \\ .text
        \\ .globl _libc_notetramp
        \\_libc_notetramp:
        \\ movq 8(%rsp), %rdi
        \\ movq 16(%rsp), %rsi
        \\ andq $-16, %rsp
        \\ call _libc_notifier
        \\ hlt
    );
}

extern fn _libc_notetramp() callconv(.c) void;

export fn _libc_notifier(v: *anyopaque, s: [*:0]const u8) callconv(.c) void {
    const msg = std.mem.span(s);
    for (onnot) |f| {
        if (f) |fun| {
            if (fun(v, msg)) {
                _ = sys.noted(sys.NCONT);
                return;
            }
        }
    }
    _ = sys.noted(sys.NDFLT);
}

fn lock() void {
    while (@atomicRmw(u32, &onnotlock, .Xchg, 1, .acquire) != 0)
        _ = sys.sleep(0);
}

fn unlock() void {
    @atomicStore(u32, &onnotlock, 0, .release);
}

/// Add f to the note handlers (in), or remove it.  Returns whether it
/// was added or removed.
pub fn atnotify(f: Notefn, in: bool) bool {
    if (!init) {
        _ = sys.notify(@ptrCast(&_libc_notetramp));
        init = true;
    }
    var ret = false;
    lock();
    if (in) {
        for (&onnot) |*p| {
            if (p.* == null) {
                p.* = f;
                ret = true;
                break;
            }
        }
    } else {
        var n: usize = 0;
        for (&onnot) |*p| {
            if (p.*) |g| {
                if (!ret and g == f) {
                    p.* = null;
                    ret = true;
                } else n += 1;
            }
        }
        if (n == 0) {
            init = false;
            _ = sys.notify(null);
        }
    }
    unlock();
    return ret;
}
