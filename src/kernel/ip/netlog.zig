//! The action log of an IP stack, /net/log: a ring of text that the
//! protocols write to with netlog() when the matching flag is set, and
//! that a reader of the file drains.
//! from 9/ip/netlog.c
//!
//! DIFF:
//!   - netlog takes a Plan 9 format and an argument tuple, as print
//!     does.  Addresses are wrapped: netlog(f, Logip, "%V -> %V\n",
//!     .{ ipaux.v4(&h.src), ipaux.v4(&h.dst) }).
//!   - Netlog keeps the read position as an index into the buffer, not
//!     as a pointer, and has no `end`; its embedded Lock, QLock and
//!     Rendez are the fields lock, qlock and rendez.
//!   - netlogread and netlogctl take slices; the offset of a read is
//!     ignored as in C.  netlogopen and netlogctl return errors,
//!     netlogread too (its sleep can be interrupted); netlogclose
//!     cannot fail.
//!   - The first open empties the log.  The C leaves `len` as it was
//!     at the last close, so a new reader is given that many bytes of
//!     a buffer nothing has written yet.
//!   - netlog checks that the buffer is there once it has the lock.
//!   - The flag names of protocols that are not ported (il, igmp, gre,
//!     esp) are gone; setting an unknown name is ignored, as before.

const std = @import("std");
const fmt = @import("fmt");
const proc = @import("../port/proc.zig");
const alloc = @import("../port/alloc.zig");
const ql = @import("../port/qlock.zig");
const taslock = @import("../port/taslock.zig");
const parse = @import("../port/parse.zig");
const portdat = @import("../port/portdat.zig");
const ipdat = @import("ipdat.zig");
const ipaux = @import("ipaux.zig");

const Error = proc.Error;
const Fs = ipdat.Fs;
const Lock = portdat.Lock;
const QLock = portdat.QLock;
const Rendez = portdat.Rendez;
const Cmdtab = parse.Cmdtab;
const lock = taslock.lock;
const unlock = taslock.unlock;
const qlock = ql.qlock;
const qunlock = ql.qunlock;

const Nlog = 16 * 1024;

/// action log
pub const Netlog = struct {
    lock: Lock = .{},
    opens: i32 = 0,
    buf: ?[*]u8 = null, // Nlog bytes
    rptr: usize = 0, // DIFF: an index into buf
    len: usize = 0,

    logmask: u32 = 0, // mask of things to debug
    iponly: [ipdat.IPaddrlen]u8 = @splat(0), // ip address to print debugging for
    iponlyset: bool = false,

    qlock: QLock = .{},
    rendez: Rendez = .{},
};

const Netlogflag = struct {
    name: []const u8,
    mask: u32,
};

const flags = [_]Netlogflag{
    .{ .name = "ppp", .mask = ipdat.Logppp },
    .{ .name = "ip", .mask = ipdat.Logip },
    .{ .name = "fs", .mask = ipdat.Logfs },
    .{ .name = "tcp", .mask = ipdat.Logtcp },
    .{ .name = "icmp", .mask = ipdat.Logicmp },
    .{ .name = "udp", .mask = ipdat.Logudp },
    .{ .name = "compress", .mask = ipdat.Logcompress },
    .{ .name = "tcpwin", .mask = ipdat.Logtcp | ipdat.Logtcpwin },
    .{ .name = "tcprxmt", .mask = ipdat.Logtcp | ipdat.Logtcprxmt },
    .{ .name = "udpmsg", .mask = ipdat.Logudp | ipdat.Logudpmsg },
    .{ .name = "ipmsg", .mask = ipdat.Logip | ipdat.Logipmsg },
    .{ .name = "trans", .mask = ipdat.Logtrans },
};

pub const Ebadnetctl = "too few arguments for netlog control message";

const CMset = 0;
const CMclear = 1;
const CMonly = 2;

const routecmd = [_]Cmdtab{
    .{ .index = CMset, .cmd = "set", .narg = 0 },
    .{ .index = CMclear, .cmd = "clear", .narg = 0 },
    .{ .index = CMonly, .cmd = "only", .narg = 0 },
};

pub fn netloginit(f: *Fs) void {
    const alog = alloc.snew(Netlog);
    alog.* = .{};
    f.alog = alog;
}

pub fn netlogopen(f: *Fs) Error!void {
    const alog = f.alog.?;

    lock(&alog.lock);
    defer unlock(&alog.lock);
    if (alog.opens == 0) {
        if (alog.buf == null)
            alog.buf = alloc.malloc(Nlog) orelse return error.Enomem;
        alog.rptr = 0;
        alog.len = 0; // DIFF: see the head of the file
    }
    alog.opens += 1;
}

pub fn netlogclose(f: *Fs) void {
    const alog = f.alog.?;

    lock(&alog.lock);
    alog.opens -= 1;
    if (alog.opens == 0) {
        alloc.free(alog.buf);
        alog.buf = null;
    }
    unlock(&alog.lock);
}

fn netlogready(a: ?*anyopaque) bool {
    const f: *Fs = @ptrCast(@alignCast(a.?));

    return f.alog.?.len != 0;
}

pub fn netlogread(f: *Fs, a: []u8, _: usize) Error!usize {
    const alog = f.alog.?;
    var n = a.len;

    qlock(&alog.qlock);
    defer qunlock(&alog.qlock);

    while (true) {
        lock(&alog.lock);
        if (alog.len != 0) {
            if (n > alog.len)
                n = alog.len;
            var d: usize = 0;
            const rptr = alog.rptr;
            alog.rptr += n;
            if (alog.rptr >= Nlog) {
                d = alog.rptr - Nlog;
                alog.rptr = d;
            }
            alog.len -= n;
            unlock(&alog.lock);

            const buf = alog.buf.?;
            const i = n - d;
            @memcpy(a[0..i], buf[rptr..][0..i]);
            @memcpy(a[i..n], buf[0..d]);
            break;
        } else unlock(&alog.lock);

        try proc.sleep(&alog.rendez, netlogready, f);
    }

    return n;
}

pub fn netlogctl(f: *Fs, s: []const u8) Error!void {
    const alog = f.alog.?;
    var set: bool = undefined;

    const cb = try parse.parsecmd(s);
    defer alloc.free(cb);

    if (cb.nf < 2)
        return proc.errorf("%s", .{Ebadnetctl});

    const ct = try parse.lookupcmd(cb, &routecmd);

    switch (ct.index) {
        CMset => set = true,

        CMclear => set = false,

        CMonly => {
            _ = ipaux.parseip(&alog.iponly, cb.f[1]);
            alog.iponlyset = ipdat.ipcmp(&alog.iponly, &ipaux.IPnoaddr) != 0;
            return;
        },

        else => return parse.cmderror(cb, "unknown ip control message"),
    }

    for (cb.f[1..cb.nf]) |arg| {
        const fp = for (&flags) |*fp| {
            if (std.mem.eql(u8, fp.name, arg))
                break fp;
        } else continue;
        if (set)
            alog.logmask |= fp.mask
        else
            alog.logmask &= ~fp.mask;
    }
}

pub fn netlog(f: *Fs, mask: u32, comptime format: []const u8, args: anytype) void {
    const alog = f.alog.?;
    var buf: [256]u8 = undefined;

    if (alog.logmask & mask == 0)
        return;

    if (alog.opens == 0)
        return;

    // the C's buffer keeps a byte for the NUL
    const msg = fmt.snprint(buf[0 .. buf.len - 1], format, args);
    const n = msg.len;

    lock(&alog.lock);
    const log = alog.buf orelse {
        // DIFF: closed since the test above
        unlock(&alog.lock);
        return;
    };
    if (alog.len + n > Nlog) {
        const i = alog.len + n - Nlog;
        alog.len -= i;
        alog.rptr += i;
        if (alog.rptr >= Nlog)
            alog.rptr -= Nlog;
    }
    var t = alog.rptr + alog.len;
    alog.len += n;
    for (msg) |c| {
        if (t >= Nlog)
            t -= Nlog;
        log[t] = c;
        t += 1;
    }
    unlock(&alog.lock);

    _ = proc.wakeup(&alog.rendez);
}
