//! Pipes, #|: each attach makes a pair of queues, data and data1 being
//! the two ends.
//! from 9/port/devpipe.c
//!
//! DIFF:
//!   - Errors are Zig error returns.  The waserror in pipeattach became
//!     errdefer; those in pipewrite and pipebwrite, which post the
//!     "write on closed pipe" note, became a catch around the write.
//!   - conf.pipeqsize is used where the architecture's Conf has it;
//!     otherwise a variable of this file stands in, starting at 0 so
//!     pipeinit gives it the same 256K default.
//!   - pipebread returns an empty Block where the C returns nil for a
//!     hung-up queue: Dev.bread cannot return null.  A caller sees no
//!     data either way.
//!   - pipeopen checks the open mode before counting the open, so a bad
//!     mode does not leave qref raised as it does in the C.
//!   - pipestat looks the Dirtab entry up after checking the qid, so a
//!     bad qid reaches the panic instead of indexing past pipedir.
//!   - NETTYPE, NETID and NETQID (9/port/netif.h) and exhausted
//!     (9/port/proc.c) are not ported yet and are private here.

const std = @import("std");
const fcall = @import("fcall");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const lib = @import("lib.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const alloc = @import("alloc.zig");
const ab = @import("allocb.zig");
const qio = @import("qio.zig");
const proc = @import("proc.zig");
const chan = @import("chan.zig");
const devmod = @import("dev.zig");
const p9 = @import("print.zig");

const print = p9.print;
const panic = p9.panic;
const qlock = ql.qlock;
const qunlock = ql.qunlock;
const devdir = devmod.devdir;
const mkqid = devmod.mkqid;

pub const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Qid = portdat.Qid;
const Dir = portdat.Dir;
const Lock = portdat.Lock;
const QLock = portdat.QLock;
const Queue = qio.Queue;
const Block = ab.Block;
const Dirtab = devmod.Dirtab;
const QTDIR = fcall.QTDIR;
const QTFILE = fcall.QTFILE;
const DEVDOTDOT = portdat.DEVDOTDOT;
const COPEN = portdat.COPEN;
const CMSG = portdat.CMSG;

// M3: from 9/port/netif.h, which is not ported yet.
fn NETTYPE(x: u64) u32 {
    return @as(u32, @truncate(x)) & 0x1f;
}

fn NETID(x: u64) u32 {
    return @as(u32, @truncate(x)) >> 5;
}

fn NETQID(i: u32, t: u64) u64 {
    return (i << 5) | @as(u32, @truncate(t));
}

// M3: belongs in proc.zig (9/port/proc.c).
fn exhausted(resource: []const u8) Error {
    const e = proc.errorf("no free %s", .{resource});
    p9.iprint("%s\n", .{proc.errtext(e)});
    return e;
}

const Pipe = struct {
    qlock: QLock = .{},
    ref: i32 = 0,
    q: [2]*Queue,
    qref: [2]i32 = .{ 0, 0 },
};

var pipealloc: struct {
    lock: Lock = .{},
    path: u32 = 0,
} = .{};

const Qdir = 0;
const Qdata0 = 1;
const Qdata1 = 2;

const pipedir = [_]Dirtab{
    .{ .name = ".", .qid = .{ .path = Qdir, .vers = 0, .type = QTDIR }, .length = 0, .perm = fcall.DMDIR | 0o500 },
    .{ .name = "data", .qid = .{ .path = Qdata0 }, .length = 0, .perm = 0o666 },
    .{ .name = "data1", .qid = .{ .path = Qdata1 }, .length = 0, .perm = 0o666 },
};

/// conf.pipeqsize where the architecture has one (see DIFF).
var localpipeqsize: u32 = 0;

fn pipeqsize() *u32 {
    if (@hasField(arch.Conf, "pipeqsize"))
        return &arch.conf.pipeqsize;
    return &localpipeqsize;
}

fn pipeinit() void {
    const size = pipeqsize();
    if (size.* == 0)
        size.* = 256 * 1024;
    // make pipeqsize a multiple of our i/o unit
    size.* = qio.qiomaxatomic * ((size.* + qio.qiomaxatomic - 1) / qio.qiomaxatomic);
}

/// create a pipe, no streams are created until an open
fn pipeattach(spec: []const u8) Error!*Chan {
    const c = devmod.devattach('|', spec);
    errdefer chan.chanfree(c);
    const p = alloc.new(Pipe) orelse
        return exhausted("memory");

    const q0 = qio.qopen(@intCast(pipeqsize().*), 0, null, null) orelse {
        alloc.free(p);
        return exhausted("memory");
    };
    const q1 = qio.qopen(@intCast(pipeqsize().*), 0, null, null) orelse {
        qio.qfree(q0);
        alloc.free(p);
        return exhausted("memory");
    };
    p.* = .{ .ref = 1, .q = .{ q0, q1 } };

    taslock.lock(&pipealloc.lock);
    pipealloc.path +%= 1;
    const path = pipealloc.path;
    taslock.unlock(&pipealloc.lock);

    c.qid = mkqid(NETQID(path, Qdir), 0, QTDIR);
    c.aux = p;
    c.dev = 0;
    return c;
}

fn pipegen(c: *Chan, _: ?[]const u8, tab: []const Dirtab, i_: i32, dp: *Dir) i32 {
    if (i_ == DEVDOTDOT) {
        devdir(c, c.qid, "#|", 0, proc.eve, 0o555, dp);
        return 1;
    }
    const i: usize = @intCast(i_ + 1); // skip .
    if (tab.len == 0 or i >= tab.len)
        return -1;

    const t = &tab[i];
    const p: *Pipe = @ptrCast(@alignCast(c.aux.?));
    const len: i64 = switch (t.qid.path) {
        Qdata0 => qio.qlen(p.q[0]),
        Qdata1 => qio.qlen(p.q[1]),
        else => t.length,
    };
    const q = mkqid(NETQID(NETID(c.qid.path), t.qid.path), 0, QTFILE);
    devdir(c, q, t.name, len, proc.eve, t.perm, dp);
    return 1;
}

fn pipewalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    const wq = try devmod.devwalk(c, nc, name, &pipedir, pipegen);
    if (wq.clone != null and wq.clone != c) {
        const p: *Pipe = @ptrCast(@alignCast(c.aux.?));
        qlock(&p.qlock);
        p.ref += 1;
        qunlock(&p.qlock);
    }
    return wq;
}

fn pipestat(c: *Chan, db: []u8) Error!usize {
    var dir: Dir = .{};

    const p: *Pipe = @ptrCast(@alignCast(c.aux.?));
    const path = NETTYPE(c.qid.path);

    switch (path) {
        Qdir => {
            const d = &pipedir[path];
            devdir(c, c.qid, d.name, 0, proc.eve, d.perm, &dir);
        },
        Qdata0 => {
            const d = &pipedir[path];
            devdir(c, c.qid, d.name, qio.qlen(p.q[0]), proc.eve, d.perm, &dir);
        },
        Qdata1 => {
            const d = &pipedir[path];
            devdir(c, c.qid, d.name, qio.qlen(p.q[1]), proc.eve, d.perm, &dir);
        },
        else => panic("pipestat", .{}),
    }
    const n = fcall.convD2M(&dir, db);
    if (n < fcall.BIT16SZ)
        return error.Eshortstat;
    return n;
}

/// if the stream doesn't exist, create it
fn pipeopen(c: *Chan, omode: u32) Error!*Chan {
    if (c.qid.type & QTDIR != 0) {
        if (omode != lib.OREAD)
            return error.Ebadarg;
        c.mode = @intCast(omode);
        c.flag |= COPEN;
        c.offset = 0;
        return c;
    }

    const mode = try devmod.openmode(omode);

    const p: *Pipe = @ptrCast(@alignCast(c.aux.?));
    qlock(&p.qlock);
    switch (NETTYPE(c.qid.path)) {
        Qdata0 => p.qref[0] += 1,
        Qdata1 => p.qref[1] += 1,
        else => {},
    }
    qunlock(&p.qlock);

    c.mode = @intCast(mode);
    c.flag |= COPEN;
    c.offset = 0;
    c.iounit = qio.qiomaxatomic;
    return c;
}

fn pipeclose(c: *Chan) Error!void {
    const p: *Pipe = @ptrCast(@alignCast(c.aux.?));
    qlock(&p.qlock);

    if (c.flag & COPEN != 0) {
        // closing either side hangs up the stream
        switch (NETTYPE(c.qid.path)) {
            Qdata0 => {
                p.qref[0] -= 1;
                if (p.qref[0] == 0) {
                    qio.qhangup(p.q[1], null);
                    qio.qclose(p.q[0]);
                }
            },
            Qdata1 => {
                p.qref[1] -= 1;
                if (p.qref[1] == 0) {
                    qio.qhangup(p.q[0], null);
                    qio.qclose(p.q[1]);
                }
            },
            else => {},
        }
    }

    // if both sides are closed, they are reusable
    if (p.qref[0] == 0 and p.qref[1] == 0) {
        qio.qreopen(p.q[0]);
        qio.qreopen(p.q[1]);
    }

    // free the structure on last close
    p.ref -= 1;
    if (p.ref == 0) {
        qunlock(&p.qlock);
        alloc.free(p.q[0]);
        alloc.free(p.q[1]);
        alloc.free(p);
    } else {
        qunlock(&p.qlock);
    }
}

fn piperead(c: *Chan, va: []u8, _: i64) Error!usize {
    const p: *Pipe = @ptrCast(@alignCast(c.aux.?));

    switch (NETTYPE(c.qid.path)) {
        Qdir => return devmod.devdirread(c, va, &pipedir, pipegen),
        Qdata0 => return qio.qread(p.q[0], va),
        Qdata1 => return qio.qread(p.q[1], va),
        else => panic("piperead", .{}),
    }
}

fn pipebread(c: *Chan, n: usize, offset: u64) Error!*Block {
    const p: *Pipe = @ptrCast(@alignCast(c.aux.?));

    switch (NETTYPE(c.qid.path)) {
        Qdata0 => return try qio.qbread(p.q[0], n) orelse ab.allocb(0),
        Qdata1 => return try qio.qbread(p.q[1], n) orelse ab.allocb(0),
        else => {},
    }

    return devmod.devbread(c, n, offset);
}

/// a write to a closed pipe causes a note to be sent to
/// the process.
fn pipewrite(c: *Chan, va: []const u8, _: i64) Error!usize {
    if (!arch.islo())
        print("pipewrite hi %#p\n", .{@returnAddress()});

    const p: *Pipe = @ptrCast(@alignCast(c.aux.?));

    const q = switch (NETTYPE(c.qid.path)) {
        Qdata0 => p.q[1],
        Qdata1 => p.q[0],
        else => panic("pipewrite", .{}),
    };
    return qio.qwrite(q, va) catch |e| {
        // avoid notes when pipe is a mounted queue
        if (c.flag & CMSG == 0)
            _ = proc.postnote(arch.up(), true, "sys: write on closed pipe", portdat.NUser);
        return e;
    };
}

fn pipebwrite(c: *Chan, bp: *Block, _: u64) Error!usize {
    const p: *Pipe = @ptrCast(@alignCast(c.aux.?));

    const q = switch (NETTYPE(c.qid.path)) {
        Qdata0 => p.q[1],
        Qdata1 => p.q[0],
        else => panic("pipebwrite", .{}),
    };
    return qio.qbwrite(q, bp) catch |e| {
        // avoid notes when pipe is a mounted queue
        if (c.flag & CMSG == 0)
            _ = proc.postnote(arch.up(), true, "sys: write on closed pipe", portdat.NUser);
        return e;
    };
}

fn pipewstat(c: *Chan, dp: []const u8) Error!usize {
    var d: Dir = .{};

    const n = fcall.convM2D(dp, &d, null);
    if (n == 0)
        return error.Eshortstat;

    const p: *Pipe = @ptrCast(@alignCast(c.aux.?));
    switch (NETTYPE(c.qid.path)) {
        Qdir => return error.Eperm,
        Qdata0, Qdata1 => {
            if (@as(u64, @bitCast(d.length)) > pipeqsize().*)
                return error.Ebadarg;
            qio.qsetlimit(p.q[0], @intCast(d.length));
            qio.qsetlimit(p.q[1], @intCast(d.length));
        },
        else => panic("pipewstat", .{}),
    }

    return n;
}

pub const pipedevtab: devmod.Dev = .{
    .dc = '|',
    .name = "pipe",

    .init = pipeinit,
    .attach = pipeattach,
    .walk = pipewalk,
    .stat = pipestat,
    .open = pipeopen,
    .close = pipeclose,
    .read = piperead,
    .bread = pipebread,
    .write = pipewrite,
    .bwrite = pipebwrite,
    .wstat = pipewstat,
};
