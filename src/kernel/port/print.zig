//! Kernel console output.
//! from the output half of 9/port/devcons.c (print, iprint, panic,
//! putstrn0, kmesg)
//!
//! DIFF: there is no console queue yet, so print writes straight to the
//! registered consoles as iprint does; devcons adds the queue (M3).

const std = @import("std");
const arch = @import("../arch.zig");
const fmt = @import("fmt");
const taslock = @import("taslock.zig");

const PRINTSIZE = 256;

/// A place console output goes: the serial port, the screen.
pub const Consputs = *const fn ([]const u8) void;

var consoles: [4]?Consputs = @splat(null);

pub fn addconsole(f: Consputs) void {
    for (&consoles) |*c| {
        if (c.* == null) {
            c.* = f;
            return;
        }
    }
}

/// The kernel message buffer behind /dev/kmesg: the last output, kept so
/// it can be read after the screen has scrolled.
pub var kmesg: struct {
    buf: [16384]u8 = undefined,
    n: usize = 0,
} = .{};

fn kmesgputs(s: []const u8) void {
    const b = &kmesg.buf;
    // take the tail of huge writes
    const str = if (s.len > b.len) s[s.len - b.len ..] else s;
    // slide the buffer down to make room
    if (kmesg.n + str.len > b.len) {
        const d = kmesg.n + str.len - b.len;
        std.mem.copyForwards(u8, b[0 .. kmesg.n - d], b[d..kmesg.n]);
        kmesg.n -= d;
    }
    @memcpy(b[kmesg.n..][0..str.len], str);
    kmesg.n += str.len;
}

/// Print a string on the console.
pub fn putstrn(s: []const u8) void {
    if (s.len == 0) return;
    // One writer at a time, so lines from different processors do not
    // mix.  A panic prints regardless: the lock's holder may be the
    // processor that is panicking, or one that will never run again.
    const locked = !panicking;
    if (locked) taslock.ilock(&conslock);
    kmesgputs(s);
    for (consoles) |c| {
        if (c) |f| f(s);
    }
    if (locked) taslock.iunlock(&conslock);
}

var conslock: taslock.Lock = .{};

fn flush(f: *fmt.Fmt) void {
    putstrn(f.buf[0..f.n]);
    f.n = 0;
}

pub fn print(comptime format: []const u8, args: anytype) void {
    var buf: [PRINTSIZE]u8 = undefined;
    var f: fmt.Fmt = .{ .buf = &buf, .flush = flush };
    fmt.fmtprint(&f, format, args);
    flush(&f);
}

/// Print from interrupt level.
pub fn iprint(comptime format: []const u8, args: anytype) void {
    const s = arch.splhi();
    print(format, args);
    arch.splx(s);
}

pub var panicking: bool = false;

pub fn panic(comptime format: []const u8, args: anytype) noreturn {
    _ = arch.splhi();
    // A panic while panicking would only bury the first message.
    if (!panicking) {
        panicking = true;
        print("panic: " ++ format ++ "\n", args);
        arch.dumpstack();
    }
    arch.stop();
}
