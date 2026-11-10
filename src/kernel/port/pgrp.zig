//! Process groups: the name space (Pgrp), file descriptors (Fgrp) and
//! rendezvous tags (Rgrp) that processes share or copy at rfork.
//! from 9/port/pgrp.c

const std = @import("std");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const lib = @import("lib.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const tod = @import("tod.zig");
const chan = @import("chan.zig");
const devmod = @import("dev.zig");
const p9 = @import("print.zig");

const print = p9.print;
const panic = p9.panic;
const incref = portdat.incref;
const decref = portdat.decref;

pub const Error = proc.Error;
const Pgrp = portdat.Pgrp;
const Rgrp = portdat.Rgrp;
const Fgrp = portdat.Fgrp;
const Mount = portdat.Mount;
const Mhead = portdat.Mhead;
const Chan = portdat.Chan;

const Whinesecs = 10; // frequency of out-of-resources printing

// rfork flags, from 9/port/portdat.h
pub const RFNAMEG = 1 << 0;
pub const RFENVG = 1 << 1;
pub const RFFDG = 1 << 2;
pub const RFNOTEG = 1 << 3;
pub const RFPROC = 1 << 4;
pub const RFMEM = 1 << 5;
pub const RFNOWAIT = 1 << 6;
pub const RFCNAMEG = 1 << 10;
pub const RFCENVG = 1 << 11;
pub const RFCFDG = 1 << 12;
pub const RFREND = 1 << 13;
pub const RFNOMNT = 1 << 14;

pub fn newpgrp() Error!*Pgrp {
    const p = alloc.new(Pgrp) orelse return error.Enomem;
    p.* = .{};
    p.ref.ref = 1;
    p.mntordertail = &p.mntorder;
    return p;
}

pub fn newrgrp() Error!*Rgrp {
    const r = alloc.new(Rgrp) orelse return error.Enomem;
    r.* = .{};
    r.ref.ref = 1;
    return r;
}

pub fn closergrp(r: *Rgrp) void {
    if (decref(&r.ref) == 0)
        alloc.free(r);
}

pub fn closepgrp(p: *Pgrp) void {
    if (decref(&p.ref) != 0)
        return;

    for (&p.mnthash) |*h| {
        while (h.*) |f| {
            h.* = f.hash;
            ql.wlock(&f.lock);
            const m = f.mount;
            f.mount = null;
            ql.wunlock(&f.lock);
            mountfree(m);
            chan.putmhead(f);
        }
    }
    alloc.free(p);
}

pub fn pgrpinsert(pg: *Pgrp, m: *Mount) void {
    m.order = null;
    pg.mntordertail.* = m;
    pg.mntordertail = &m.order;
}

pub fn pgrpremove(pg: *Pgrp, m: *Mount) void {
    var l: *?*Mount = &pg.mntorder;
    while (l.*) |f| : (l = &f.order) {
        if (f == m) {
            l.* = f.order;
            if (l.* == null)
                pg.mntordertail = l;
            f.order = null;
            return;
        }
    }
}

pub fn pgrpcpy(to: *Pgrp, from: *Pgrp, flag: u32) Error!void {
    ql.wlock(&to.ns);
    ql.wlock(&from.ns); // must wlock to protect from->mntorder->norder
    defer {
        ql.wunlock(&from.ns);
        ql.wunlock(&to.ns);
    }

    // always inherit devmask unconditionally
    to.devmask = from.devmask;

    if (flag & RFNAMEG == 0)
        return;

    for (0..portdat.MNTHASH) |i| {
        var l: *?*Mhead = &to.mnthash[i];
        var it = from.mnthash[i];
        while (it) |f| : (it = f.hash) {
            ql.rlock(&f.lock);
            defer ql.runlock(&f.lock);
            const mh = try chan.newmhead(f.from);
            l.* = mh;
            l = &mh.hash;
            var link: *?*Mount = &mh.mount;
            var mi = f.mount;
            while (mi) |m| : (mi = m.next) {
                const n = try newmount(m.to, m.mflag, m.spec);
                n.umh = mh;
                link.* = n;
                link = &n.next;
                m.norder = n; // for from->mntorder loop below
            }
        }
    }

    // add mounts in original mntorder
    var mi = from.mntorder;
    while (mi) |m| : (mi = m.order) {
        const n = m.norder.?;
        m.norder = null;
        pgrpinsert(to, n);
    }
}

pub fn canmount(pg: *Pgrp) bool {
    // Devmnt is not usable directly from user procs, so
    // having it masked is interpreted to block any mounts.
    const i = devmod.devno('M') orelse return false;
    return !devmasked(pg, i);
}

pub fn devmasked(pg: *Pgrp, i: u16) bool {
    return pg.devmask[i >> 3] & (@as(u8, 1) << @intCast(i & 7)) != 0;
}

pub fn devmask(pg: *Pgrp, invert_: bool, devs_: []const u8) void {
    var mask: [256 / 8]u8 = @splat(0);
    const invert: u8 = if (invert_) 0xFF else 0;

    var devs = devs_;
    while (devs.len != 0) {
        const r = lib.chartorune(devs);
        devs = devs[r.n..];
        const i = devmod.devno(r.r) orelse continue;
        mask[i >> 3] |= @as(u8, 1) << @intCast(i & 7);
    }

    ql.wlock(&pg.ns);
    for (&pg.devmask, mask) |*d, m|
        d.* |= m ^ invert;
    ql.wunlock(&pg.ns);
}

fn newfds(new: *Fgrp, n: usize) Error!void {
    const fd = alloc.newslice(?*Chan, n);
    const flag = alloc.newslice(u8, n);
    if (fd == null or flag == null) {
        if (flag) |x| alloc.free(x.ptr);
        if (fd) |x| alloc.free(x.ptr);
        return error.Enomem;
    }
    @memset(fd.?, null);
    new.fd = fd.?;
    new.flag = flag.?;
}

/// A copy of f, or a new empty file descriptor group if f is null.
pub fn dupfgrp(f_: ?*Fgrp) Error!*Fgrp {
    const new = alloc.new(Fgrp) orelse return error.Enomem;
    new.* = .{};
    new.ref.ref = 1;
    errdefer alloc.free(new);

    const f = f_ orelse {
        try newfds(new, portdat.DELTAFD);
        return new;
    };

    taslock.lock(&f.lock);
    // Make new fd list shorter if possible, preserving quantization
    var nfd: usize = @intCast(f.maxfd + 1);
    const i = nfd % portdat.DELTAFD;
    if (i != 0)
        nfd += portdat.DELTAFD - i;
    newfds(new, nfd) catch |e| {
        taslock.unlock(&f.lock);
        return e;
    };

    new.maxfd = f.maxfd;
    for (0..@intCast(f.maxfd + 1)) |k| {
        if (f.fd[k]) |c| {
            new.fd[k] = c;
            new.flag[k] = f.flag[k];
            _ = incref(&c.ref);
        }
    }
    taslock.unlock(&f.lock);

    return new;
}

pub fn closefgrp(f_: ?*Fgrp) void {
    const f = f_ orelse return;
    if (decref(&f.ref) != 0)
        return;

    // If we get into trouble, forceclosefgrp
    // will bail us out.
    const up = arch.up().?;
    up.closingfgrp = f;
    for (0..@intCast(f.maxfd + 1)) |i| {
        if (f.fd[i]) |c| {
            f.fd[i] = null;
            chan.cclose(c);
        }
    }
    up.closingfgrp = null;

    alloc.free(f.flag.ptr);
    alloc.free(f.fd.ptr);
    alloc.free(f);
}

/// Called from interrupted() because up is in the middle
/// of closefgrp and just got a kill ctl message.
/// This usually means that up has wedged because
/// of some kind of deadly embrace with mntclose
/// trying to talk to itself.  To break free, hand the
/// unclosed channels to the close queue.  Once they
/// are finished, the blocked cclose that we've
/// interrupted will finish by itself.
pub fn forceclosefgrp() void {
    const up = arch.up().?;
    if (up.procctl != portdat.Proc_exitme or up.closingfgrp == null) {
        print("bad forceclosefgrp call", .{});
        return;
    }

    const f = up.closingfgrp.?;
    for (0..@intCast(f.maxfd + 1)) |i| {
        if (f.fd[i]) |c| {
            f.fd[i] = null;
            chan.ccloseq(c);
        }
    }
}

pub fn newmount(to: *Chan, flag: u32, spec_: ?[]const u8) Error!*Mount {
    const spec = spec_ orelse "";
    const b = alloc.malloc(@sizeOf(Mount) + spec.len + 1) orelse return error.Enomem;
    const m: *Mount = @ptrCast(@alignCast(b));
    m.* = .{ .to = to, .mflag = flag };
    m.spec = b[@sizeOf(Mount)..][0..spec.len];
    @memcpy(m.spec, spec);
    _ = incref(&to.ref);
    return m;
}

pub fn mountfree(m_: ?*Mount) void {
    var m = m_;
    while (m) |f| {
        m = f.next;
        chan.cclose(f.to);
        alloc.free(f);
    }
}

var lastwhine: i64 = 0;
var whineseed: u32 = 1;

/// Wait a little for some resource to be freed, saying why once in a
/// while.
pub fn resrcwait(reason: ?[]const u8) Error!void {
    const up = arch.up() orelse panic("resrcwait: %s", .{reason orelse ""});

    const p = up.psstate;
    defer up.psstate = p;
    if (reason) |r| {
        up.psstate = r;
        const now = tod.seconds();
        // don't tie up the console with complaints
        if (now - lastwhine > Whinesecs) {
            lastwhine = now;
            print("%s\n", .{r});
        }
    }
    // DIFF: the C sleeps 100+nrand(200) ms; the kernel's random number
    // generator is not ported yet, so this spreads the waits itself.
    whineseed = whineseed *% 1103515245 +% 12345;
    try proc.tsleep(&up.sleep, proc.return0, null, 100 + (whineseed >> 16) % 200);
}
