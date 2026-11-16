//! Notes: the library takes the process's notes and gives them to the
//! functions of threadnotify, later if a channel operation is under
//! way.
//! from libthread/note.c
//!
//! DIFF:
//!   - A handler takes the note as a slice and returns a bool.
//!   - The kernel enters the handler the Plan 9 way (a null return
//!     address, then the Ureg pointer and the message, on the stack),
//!     so a small trampoline calls threadnote; init is the C's
//!     notify(_threadnote).
//!   - The C reads the note's text after giving the note back; the
//!     copy made before is used.

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const impl = @import("impl.zig");
const exit = @import("exit.zig");

const Proc = impl.Proc;
const Lock = impl.Lock;
const lock = impl.lock;
const unlock = impl.unlock;
const get = impl.get;
const set = impl.set;

const NFN = 33;

/// A note handler: returns true if it handled the note.  ureg is null
/// when the note is given late, outside the kernel's handler.
pub const Notefn = *const fn (ureg: ?*anyopaque, msg: []const u8) bool;

const Note = struct {
    inuse: Lock = .{},
    proc: ?*Proc = null, // recipient
    s: [sys.ERRMAX]u8 = undefined, // arg2
    n: usize = 0,
};

var notes: [128]Note = @splat(.{});
var onnote: [NFN]?Notefn = @splat(null);
var onnotepid: [NFN]i32 = @splat(0);
var onnotelock: Lock = .{};

/// Add f to the note handlers of this proc (in), or take it out.
pub fn threadnotify(f: Notefn, in: bool) bool {
    var from: ?Notefn = null;
    var to: ?Notefn = null;
    var topid: i32 = 0;

    if (in) {
        to = f;
        topid = impl.getproc().pid;
    } else from = f;
    lock(&onnotelock);
    defer unlock(&onnotelock);
    for (&onnote, &onnotepid) |*o, *pid| {
        if (o.* == from) {
            o.* = to;
            pid.* = topid;
            return true;
        }
    }
    return false;
}

fn delayednotes(p: *Proc, v: ?*anyopaque) void {
    var sbuf: [sys.ERRMAX]u8 = undefined;

    if (!get(&p.pending))
        return;

    set(&p.pending, false);
    for (&notes) |*n| {
        if (get(&n.proc) == p) {
            const s = sbuf[0..n.n];
            @memcpy(s, n.s[0..n.n]);
            set(&n.proc, null);
            unlock(&n.inuse);

            var handled = false;
            for (0..NFN) |i| {
                const f = onnote[i] orelse continue;
                if (onnotepid[i] != p.pid)
                    continue;
                if (f(v, s)) {
                    handled = true;
                    break;
                }
            }
            if (!handled) {
                if (v != null)
                    _ = sys.noted(sys.NDFLT)
                else if (std.mem.startsWith(u8, s, "sys:"))
                    sys.exits("abort");
                exit.threadexitsall(s);
            }
        }
    }
}

comptime {
    asm (
        \\ .text
        \\ .globl _threadnotetramp
        \\_threadnotetramp:
        \\ movq 8(%rsp), %rdi
        \\ movq 16(%rsp), %rsi
        \\ andq $-16, %rsp
        \\ call _threadnote
        \\ hlt
    );
}

extern fn _threadnotetramp() callconv(.c) void;

pub fn init() void {
    _ = sys.notify(&_threadnotetramp);
}

export fn _threadnote(v: ?*anyopaque, sp: [*]const u8) callconv(.c) void {
    const s = sys.span(sp);
    if (std.mem.startsWith(u8, s, "sys:"))
        _ = sys.noted(sys.NDFLT);

    if (impl.exitsall()) |status|
        sys.exits(if (status.len == 0) null else status);

    if (std.mem.eql(u8, s, "threadint"))
        _ = sys.noted(sys.NCONT);

    const p = impl.getprocornull() orelse {
        _ = sys.noted(sys.NDFLT);
        unreachable;
    };

    const n = for (&notes) |*n| {
        if (libc.canlock(&n.inuse))
            break n;
    } else libc.sysfatal("libthread: too many delayed notes", .{});
    n.n = @min(s.len, sys.ERRMAX - 1);
    @memcpy(n.s[0..n.n], s[0..n.n]);
    set(&n.proc, p);
    set(&p.pending, true);
    if (!get(&p.splhi))
        delayednotes(p, v);
    _ = sys.noted(sys.NCONT);
}

pub fn procsplhi() bool {
    const p = impl.getproc();
    const s = get(&p.splhi);
    set(&p.splhi, true);
    return s;
}

pub fn procsplx(s: bool) void {
    const p = impl.getproc();
    set(&p.splhi, s);
    if (s)
        return;
    if (get(&p.pending))
        delayednotes(p, null);
}
