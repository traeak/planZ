//! Capabilities, #¤: the host owner (factotum) writes the hash of a
//! capability to caphash; a process that later writes the capability
//! itself, "user1@user2@key", to capuse becomes user2.
//! from 9/port/devcap.c
//!
//! DIFF:
//!   - Errors are Zig error returns.  The waserror in capwrite, which
//!     frees the copy of the capability, became a defer.
//!   - hmac_sha1 of libsec is std.crypto.auth.hmac.HmacSha1 (caphmac);
//!     tsmemcmp is std.crypto.timing_safe.eql.
//!   - The capability is not split in place with NULs: from, to and key
//!     are slices of the copy.  As in C the capability ends at the first
//!     NUL written, if there is one.
//!   - hash in capwrite is cleared on every way out, not only on
//!     success, and with secureZero so the store is not optimised away.
//!   - ncapdir is private and counts entries of capdir as in C; the
//!     tables are passed to the dev functions as capdir[0..ncapdir].
//!   - TK2SEC is not exported by arch.zig; ticks are divided by HZ here.

const std = @import("std");
const fcall = @import("fcall");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const lib = @import("lib.zig");
const ql = @import("qlock.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const devmod = @import("dev.zig");
const devcons = @import("devcons.zig");

const qlock = ql.qlock;
const qunlock = ql.qunlock;
const iseve = devcons.iseve;
const secalloc = alloc.secalloc;
const secfree = alloc.secfree;
const devgen = devmod.devgen;
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;

pub const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const QLock = portdat.QLock;
const Dirtab = devmod.Dirtab;
const QTDIR = fcall.QTDIR;
const COPEN = portdat.COPEN;

const Hashlen = HmacSha1.mac_length; // SHA1dlen
const Maxhash = 256;
const Timeout = 60; // seconds

comptime {
    std.debug.assert(Hashlen == 20);
}

/// if a process knows cap->cap, it can change user
/// to capabilty->user.
const Caphash = struct {
    next: ?*Caphash,
    ticks: u32,
    hash: [Hashlen]u8,
};

var capalloc: struct {
    qlock: QLock = .{},
    first: ?*Caphash = null,
    nhash: i32 = 0,
} = .{};

const Qdir = 0;
const Qhash = 1;
const Quse = 2;

// caphash must be last
const capdir = [_]Dirtab{
    .{ .name = ".", .qid = .{ .path = Qdir, .vers = 0, .type = QTDIR }, .length = 0, .perm = fcall.DMDIR | 0o500 },
    .{ .name = "capuse", .qid = .{ .path = Quse }, .length = 0, .perm = 0o222 },
    .{ .name = "caphash", .qid = .{ .path = Qhash }, .length = 0, .perm = 0o200 },
};
var ncapdir: usize = capdir.len;

fn capattach(spec: []const u8) Error!*Chan {
    return devmod.devattach('¤', spec);
}

fn capwalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    return devmod.devwalk(c, nc, name, capdir[0..ncapdir], devgen);
}

fn capremove(c: *Chan) Error!void {
    if (iseve() and c.qid.path == Qhash)
        ncapdir = capdir.len - 1
    else
        return error.Eperm;
}

fn capstat(c: *Chan, db: []u8) Error!usize {
    return devmod.devstat(c, db, capdir[0..ncapdir], devgen);
}

/// if the stream doesn't exist, create it
fn capopen(c: *Chan, omode: u32) Error!*Chan {
    if (c.qid.type & QTDIR != 0) {
        if (omode != lib.OREAD)
            return error.Ebadarg;
        c.mode = @intCast(omode);
        c.flag |= COPEN;
        c.offset = 0;
        return c;
    }

    switch (c.qid.path) {
        Qhash => {
            if (!iseve())
                return error.Eperm;
        },
        else => {},
    }

    c.mode = @intCast(try devmod.openmode(omode));
    c.flag |= COPEN;
    c.offset = 0;
    return c;
}

fn TK2SEC(t: u32) u32 {
    return t / arch.mem.HZ;
}

fn trimcaps() void {
    while (capalloc.first) |t| {
        if (capalloc.nhash < Maxhash and TK2SEC(arch.MACHP(0).ticks -% t.ticks) < Timeout)
            break;
        capalloc.nhash -= 1;
        capalloc.first = t.next;
        secfree(t);
    }
}

fn remcap(hash: *const [Hashlen]u8) ?*Caphash {
    qlock(&capalloc.qlock);

    // timeout old caps
    trimcaps();

    // find the matching capability
    var l = &capalloc.first;
    while (l.*) |t| {
        if (std.crypto.timing_safe.eql([Hashlen]u8, hash.*, t.hash))
            break;
        l = &t.next;
    }
    const t = l.*;
    if (t) |p| {
        capalloc.nhash -= 1;
        l.* = p.next;
    }
    qunlock(&capalloc.qlock);

    return t;
}

/// add a capability, throwing out any old ones
fn addcap(hash: *const [Hashlen]u8) void {
    const p: *Caphash = @ptrCast(@alignCast(secalloc(@sizeOf(Caphash))));
    p.hash = hash.*;
    p.next = null;
    p.ticks = arch.MACHP(0).ticks;

    qlock(&capalloc.qlock);

    // make room for one extra
    trimcaps();

    // add new one
    var l = &capalloc.first;
    while (l.*) |t|
        l = &t.next;
    l.* = p;
    capalloc.nhash += 1;

    qunlock(&capalloc.qlock);
}

fn capclose(_: *Chan) Error!void {}

fn capread(c: *Chan, va: []u8, _: i64) Error!usize {
    switch (c.qid.path) {
        Qdir => return devmod.devdirread(c, va, capdir[0..ncapdir], devgen),
        else => return error.Eperm,
    }
}

/// The hash of a capability: HMAC-SHA1 of "user1@user2" (or "user")
/// keyed by the capability's key; hmac_sha1(from, key) in the C.
fn caphmac(from: []const u8, key: []const u8, hash: *[Hashlen]u8) void {
    HmacSha1.create(hash, from, key);
}

fn capwrite(c: *Chan, va: []const u8, _: i64) Error!usize {
    var hash: [Hashlen]u8 = undefined;
    defer std.crypto.secureZero(u8, &hash);
    const n = va.len;

    switch (c.qid.path) {
        Qhash => {
            if (!iseve())
                return error.Eperm;
            if (n < Hashlen)
                return error.Eshort;
            hash = va[0..Hashlen].*;
            addcap(&hash);
        },

        Quse => {
            if (n >= 1024)
                return error.Etoobig;
            // copy key to avoid a fault in hmac_xx
            const cp = secalloc(n + 1);
            defer secfree(cp);
            @memcpy(cp[0..n], va);
            cp[n] = 0;

            const s = std.mem.sliceTo(cp[0..n], 0);
            const at = std.mem.findScalarLast(u8, s, '@') orelse
                return error.Eshort;
            var from: []const u8 = s[0..at];
            const key: []const u8 = s[at + 1 ..];

            caphmac(from, key, &hash);

            // if a from user is supplied, make sure it matches
            var to = from;
            if (std.mem.findScalar(u8, from, '@')) |i| {
                to = from[i + 1 ..];
                from = from[0..i];
                if (!std.mem.eql(u8, from, arch.up().?.user))
                    return proc.errorf("capability must match user", .{});
            }

            const p = remcap(&hash) orelse
                return proc.errorf("invalid capability %s@%s", .{ from, key });
            secfree(p);

            proc.procsetuser(to);
        },

        else => return error.Eperm,
    }

    return n;
}

pub const capdevtab: devmod.Dev = .{
    .dc = '¤',
    .name = "cap",

    .attach = capattach,
    .walk = capwalk,
    .stat = capstat,
    .open = capopen,
    .close = capclose,
    .read = capread,
    .write = capwrite,
    .remove = capremove,
};

// Expected values computed on the host with
//   python3 -c 'import hmac,hashlib; print(hmac.new(b"KEY", b"MSG", hashlib.sha1).hexdigest())'
// and checked with  printf MSG | openssl dgst -sha1 -hmac KEY
test "caphmac" {
    var hash: [Hashlen]u8 = undefined;
    var want: [Hashlen]u8 = undefined;

    caphmac("glenda@none", "0123456789abcdef", &hash);
    _ = try std.fmt.hexToBytes(&want, "8d6f7e5e65c6135c4599d3ba6122634edfbee961");
    try std.testing.expectEqualSlices(u8, &want, &hash);

    caphmac("none", "secret", &hash);
    _ = try std.fmt.hexToBytes(&want, "6061a9b287104e16cc743d7235d9d0c0b739ab69");
    try std.testing.expectEqualSlices(u8, &want, &hash);
}
