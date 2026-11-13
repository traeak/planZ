//! rc's buffered I/O and its print.
//! from cmd/rc/io.c and io.h
//!
//! DIFF:
//!   - pfmt's format is known at compile time: each verb is checked
//!     against its argument's type when rc is built, where the C's
//!     varargs trust the caller.  The verbs and what they print are the
//!     C's.
//!   - An io's buffer is a slice with the positions bufp and ebuf in it.
//!     closeiostr gives the bytes written (the C's 0-ended string) and
//!     the buffer shrinks to them.

const std = @import("std");
const rc = @import("rc.zig");
const plan9 = @import("plan9.zig");
const pcmd_ = @import("pcmd.zig");
const trap = @import("trap.zig");

pub const EOF: i32 = -1;
const NBUF = 32768; // IOUNIT

pub const Io = struct {
    fd: i32,
    buf: []u8,
    bufp: usize,
    ebuf: usize,
    next: ?*Io = null,
};

pub fn pfmt(f: *Io, comptime fmt: []const u8, args: anytype) void {
    comptime var ai = 0;
    comptime var i = 0;
    inline while (i < fmt.len) : (i += 1) {
        if (fmt[i] != '%') {
            pchr(f, fmt[i]);
        } else if (i + 1 == fmt.len) { // "blah%"?
            break;
        } else {
            i += 1;
            switch (fmt[i]) {
                'c' => {
                    pchr(f, @truncate(@as(u32, @bitCast(@as(i32, args[ai])))));
                    ai += 1;
                },
                'd' => {
                    pdec(f, @intCast(args[ai]));
                    ai += 1;
                },
                'o' => {
                    poct(f, @intCast(args[ai]));
                    ai += 1;
                },
                'p' => {
                    pptr(f, @intFromPtr(args[ai]));
                    ai += 1;
                },
                'Q' => {
                    pquo(f, args[ai]);
                    ai += 1;
                },
                'q' => {
                    pwrd(f, args[ai]);
                    ai += 1;
                },
                's' => {
                    pstr(f, args[ai]);
                    ai += 1;
                },
                't' => {
                    pcmd_.pcmd(f, args[ai]);
                    ai += 1;
                },
                'v' => {
                    pval(f, args[ai]);
                    ai += 1;
                },
                else => pchr(f, fmt[i]),
            }
        }
    }
    if (ai != args.len)
        @compileError("pfmt: " ++ fmt ++ ": wrong number of arguments");
}

pub fn pchr(b: *Io, c: u8) void {
    if (b.bufp >= b.ebuf)
        flushio(b);
    b.buf[b.bufp] = c;
    b.bufp += 1;
}

pub fn rchr(b: *Io) i32 {
    if (b.bufp >= b.ebuf)
        return emptyiobuf(b);
    const c = b.buf[b.bufp];
    b.bufp += 1;
    return c;
}

fn instop(stop: []const u8, c: u8) bool {
    // strchr finds the string's own 0
    return c == 0 or std.mem.indexOfScalar(u8, stop, c) != null;
}

/// Read a string ended by any byte of stop, skipping those before it;
/// null at the end of the input.
pub fn rstr(b: *Io, stop: []const u8) ?[]u8 {
    while (true) {
        const l = rchr(b);
        if (l == EOF)
            return null;
        if (!(l != 0 and instop(stop, @intCast(l))))
            break;
    }
    b.bufp -= 1;

    var s: ?[]u8 = null;
    var l: usize = 0;
    while (true) {
        const p = b.buf[b.bufp..b.ebuf];
        const n = p.len;
        if (n > 0) {
            for (0..n) |m| {
                if (!instop(stop, p[m]))
                    continue;

                b.bufp += m + 1;
                if (m > 0 or s == null) {
                    s = grow(s, l + m);
                    @memcpy(s.?[l..][0..m], p[0..m]);
                    l += m;
                }
                return s.?[0..l];
            }
            s = grow(s, l + n);
            @memcpy(s.?[l..][0..n], p);
            l += n;
            b.bufp += n;
        }
        if (emptyiobuf(b) == EOF)
            return if (s) |x| x[0..l] else null;
        b.bufp -= 1;
    }
}

fn grow(s: ?[]u8, n: usize) []u8 {
    return if (s) |x| rc.erealloc(x, n) else rc.emalloc(n);
}

pub fn pquo(f: *Io, s: []const u8) void {
    pchr(f, '\'');
    for (s) |c| {
        if (c == '\'')
            pchr(f, c);
        pchr(f, c);
    }
    pchr(f, '\'');
}

pub fn pwrd(f: *Io, s: []const u8) void {
    var t: usize = 0;
    while (t < s.len) : (t += 1) {
        const c = s[t];
        // the C's char is signed: bytes from 0x80 up are never special
        if (c < 0x80 and (c <= ' ' or std.mem.indexOfScalar(u8, "`^#*[]=|\\?${}()'<>&;", c) != null))
            break;
    }
    if (t == 0 or t < s.len)
        pquo(f, s)
    else
        pstr(f, s);
}

pub fn pptr(f: *Io, v: u64) void {
    const hex = "0123456789ABCDEF";
    if (v >> 32 != 0) {
        var n: i32 = 60;
        while (n >= 32) : (n -= 4)
            pchr(f, hex[@intCast((v >> @intCast(n)) & 0xF)]);
    }
    var n: i32 = 28;
    while (n >= 0) : (n -= 4)
        pchr(f, hex[@intCast((v >> @intCast(n)) & 0xF)]);
}

pub fn pstr(f: *Io, s_: ?[]const u8) void {
    const s = s_ orelse "(null)";
    for (s) |c|
        pchr(f, c);
}

pub fn pdec(f: *Io, n_: i32) void {
    var n = n_;
    if (n < 0) {
        n = -%n;
        if (n >= 0) {
            pchr(f, '-');
            pdec(f, n);
            return;
        }
        // n is two's complement minimum integer
        n = 1 -% n;
        pchr(f, '-');
        pdec(f, @divTrunc(n, 10));
        pchr(f, @bitCast(@as(i8, @truncate(@rem(n, 10) + '1'))));
        return;
    }
    if (n > 9)
        pdec(f, @divTrunc(n, 10));
    pchr(f, @intCast(@rem(n, 10) + '0'));
}

pub fn poct(f: *Io, n: u32) void {
    if (n > 7)
        poct(f, n >> 3);
    pchr(f, @intCast((n & 7) + '0'));
}

pub fn pval(f: *Io, a_: ?*rc.Word) void {
    var a = a_ orelse return;
    while (a.next) |n| {
        pwrd(f, a.word);
        pchr(f, ' ');
        a = n;
    }
    pwrd(f, a.word);
}

fn newio(buf: []u8, len: usize, fd: i32) *Io {
    const f = rc.new(Io);
    f.* = .{ .fd = fd, .buf = buf, .bufp = 0, .ebuf = len };
    return f;
}

/// Open a string buffer for writing.
pub fn openiostr() *Io {
    const buf = rc.emalloc(100 + 1);
    @memset(buf, 0);
    return newio(buf, 100, -1);
}

/// Return the buf, free the io
pub fn closeiostr(f: *Io) []u8 {
    const n = std.mem.indexOfScalar(u8, f.buf[0..f.bufp], 0) orelse f.bufp;
    const buf = rc.erealloc(f.buf, n);
    rc.destroy(f);
    return buf;
}

/// Use a open file descriptor for reading.
pub fn openiofd(fd: i32) *Io {
    return newio(rc.emalloc(NBUF), 0, fd);
}

/// Open a corebuffer to read.  EOF occurs after reading len characters
/// from buf, which the io owns.
pub fn openiocore(buf: []u8) *Io {
    return newio(buf, buf.len, -1);
}

pub fn flushio(f: *Io) void {
    if (f.fd < 0) {
        const n = f.ebuf;
        f.buf = rc.erealloc(f.buf, n + n + 1);
        f.bufp = n;
        f.ebuf = n + n;
        @memset(f.buf[n..], 0);
    } else {
        const n = f.bufp;
        if (n != 0 and plan9.Write(f.fd, f.buf[0..n]) != n) {
            if (trap.ntrap != 0)
                trap.dotrap();
        }
        f.bufp = 0;
        f.ebuf = NBUF;
    }
}

pub fn closeio(f: *Io) void {
    if (f.fd >= 0)
        plan9.Close(f.fd);
    rc.a.free(f.buf);
    rc.destroy(f);
}

pub fn emptyiobuf(f: *Io) i32 {
    if (f.fd < 0)
        return EOF;
    const n = plan9.Read(f.fd, f.buf[0..NBUF]);
    if (n <= 0)
        return EOF;
    f.bufp = 0;
    f.ebuf = @intCast(n);
    f.bufp += 1;
    return f.buf[0];
}
