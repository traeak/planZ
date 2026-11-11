//! Shares, #σ: named unions of mounted file servers that every name
//! space can reach.  #σc is the control side, where a share is a
//! directory to create and a mount point a file to create in it and
//! write a file descriptor to; #σ shows the union of what is mounted.
//! (nusb/usbd and the other nusb drivers post themselves here.)
//! from 9/port/devshr.c
//!
//! DIFF:
//!   - A Mount's `to` cannot be nil here (portdat.zig), and createdir
//!     and unionread rely on that.  In the C a mount point exists in
//!     its share's Mhead from the moment it is created, with to == nil
//!     until a file descriptor is written to it.  Here a Shr keeps its
//!     own list of all its mount points (Shr.mpts, newest first, as the
//!     C's list is) and relink() rebuilds the Mhead's list from those
//!     that have a channel, in the same order, whenever one gains or
//!     loses it.  Mpt.to is the channel; Mpt.m is only meaningful while
//!     linked.  Mhead.lock protects both lists.
//!   - Shr and Mpt contain their Ent as the field `ent`.
//!   - Errors are Zig error returns.  shrwalk's waserror, which turns an
//!     error into a short walk, is the catch around shrwalk1; when the
//!     walk got somewhere the error text is left for the caller
//!     (proc.seterror), as devwalk does.
//!   - Strings are slices.

const std = @import("std");
const fcall = @import("fcall");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const lib = @import("lib.zig");
const ql = @import("qlock.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const chan = @import("chan.zig");
const pgrp = @import("pgrp.zig");
const devmod = @import("dev.zig");
const devcons = @import("devcons.zig");
const devmnt = @import("devmnt.zig");
const sysfile = @import("sysfile.zig");
const netif = @import("netif.zig");

const qlock = ql.qlock;
const qunlock = ql.qunlock;
const rlock = ql.rlock;
const runlock = ql.runlock;
const wlock = ql.wlock;
const wunlock = ql.wunlock;
const incref = portdat.incref;
const decref = portdat.decref;
const cclose = chan.cclose;
const devdir = devmod.devdir;
const kstrdup = proc.kstrdup;

const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Qid = portdat.Qid;
const Dir = portdat.Dir;
const Ref = portdat.Ref;
const QLock = portdat.QLock;
const Mhead = portdat.Mhead;
const Mount = portdat.Mount;
const Dirtab = devmod.Dirtab;
const QTDIR = fcall.QTDIR;
const QTFILE = fcall.QTFILE;
const DMDIR = fcall.DMDIR;
const COPEN = portdat.COPEN;
const CRCLOSE = portdat.CRCLOSE;
const OREAD = lib.OREAD;
const OWRITE = lib.OWRITE;
const ORDWR = lib.ORDWR;

const Qroot = 0;
const Qcroot = 1;
const Qshr = 2;
const Qcshr = 3;
const Qcmpt = 4;

const Ent = struct {
    ref: Ref = .{},
    id: u32 = 0,
    name: []u8 = portdat.nostr,
    owner: []u8 = portdat.nostr,
    perm: u32 = 0,
};

const Shr = struct {
    ent: Ent = .{},
    umh: Mhead = .{ .from = undefined },
    next: ?*Shr = null,
    /// DIFF: all the mount points of the share, newest first.
    mpts: ?*Mpt = null,
};

const Mpt = struct {
    ent: Ent = .{},
    /// DIFF: in the share's Mhead while `to` is not null.
    m: Mount = .{ .to = undefined },
    to: ?*Chan = null,
    mflag: u32 = 0,
    next: ?*Mpt = null,
};

const Sch = struct {
    level: u32 = Qroot,

    shr: ?*Shr = null,
    mpt: ?*Mpt = null,

    chan: ?*Chan = null,
};

var shrslk: QLock = .{};
var shrs: ?*Shr = null;

var shrid: u32 = 0;
var mptid: u32 = 0;

fn tompt(m: *Mount) *Mpt {
    return @fieldParentPtr("m", m);
}

/// DIFF: make the share's Mhead list the mount points that have a
/// channel, in the order of shr.mpts.  Called with umh.lock held for
/// writing.
fn relink(shr: *Shr) void {
    var tail: *?*Mount = &shr.umh.mount;
    var p = shr.mpts;
    while (p) |mpt| : (p = mpt.next) {
        const to = mpt.to orelse continue;
        mpt.m = .{ .to = to, .mflag = mpt.mflag };
        tail.* = &mpt.m;
        tail = &mpt.m.next;
    }
    tail.* = null;
}

fn tosch(c: *Chan) Error!*Sch {
    const sch: *Sch = @ptrCast(@alignCast(c.aux orelse
        return proc.errorf("nil chan aux", .{})));
    if (sch.chan != c)
        return proc.errorf("bad chan", .{});
    return sch;
}

fn shrinit() void {
    shrid = 1;
    mptid = 1;
}

fn freestr(s: []u8) void {
    if (s.ptr != portdat.nostr.ptr)
        alloc.free(s.ptr);
}

fn putmpt(mpt: *Mpt) void {
    if (decref(&mpt.ent.ref) != 0)
        return;
    if (mpt.to) |to|
        cclose(to);
    freestr(mpt.ent.name);
    freestr(mpt.ent.owner);
    alloc.free(mpt);
}

fn putshr(shr: *Shr) void {
    if (decref(&shr.ent.ref) != 0)
        return;
    freestr(shr.ent.name);
    freestr(shr.ent.owner);
    alloc.free(shr);
}

fn shrqid(level: u32, id: u32) Qid {
    return .{
        .type = if (level == Qcmpt) QTFILE else QTDIR,
        .path = @as(u64, id) << 4 | level,
        .vers = 0,
    };
}

fn shrattach(spec: []const u8) Error!*Chan {
    if (!(std.mem.eql(u8, spec, "c") or spec.len == 0))
        return error.Enoattach;
    const c = devmod.devattach('σ', spec);

    const sch = alloc.snew(Sch);
    sch.* = .{};
    sch.level = if (spec.len != 0) Qcroot else Qroot;
    sch.mpt = null;
    sch.shr = null;
    sch.chan = c;
    c.aux = sch;
    c.qid = shrqid(sch.level, 0);

    return c;
}

fn shrclone(c: *Chan) Error!*Chan {
    const och = try tosch(c);
    const nc = devmod.devclone(c);
    const sch = alloc.snew(Sch);
    sch.* = och.*;
    if (sch.shr) |shr|
        _ = incref(&shr.ent.ref);
    if (sch.mpt) |mpt|
        _ = incref(&mpt.ent.ref);
    sch.chan = nc;
    nc.aux = sch;
    return nc;
}

fn shrclunk(c: *Chan) Error!void {
    const sch = try tosch(c);
    c.aux = null;
    sch.chan = null;
    if (sch.mpt) |mpt|
        putmpt(mpt);
    if (sch.shr) |shr|
        putshr(shr);
    alloc.free(sch);
}

fn shrwalk(c: *Chan, nc_: ?*Chan, name: []const []const u8) Error!*Walkqid {
    var alloced = false;
    const nc = nc_ orelse blk: {
        const n = try shrclone(c);
        alloced = true;
        break :blk n;
    };
    const wq = alloc.snew(Walkqid);
    wq.* = .{};
    wq.nqid = 0;
    wq.clone = nc;
    shrwalk1(wq, nc, name, alloced) catch |err| {
        if (alloced)
            cclose(wq.clone.?);
        if (wq.nqid > 0) {
            wq.clone = null;
            proc.seterror(err);
            return wq;
        }
        alloc.free(wq);
        return err;
    };
    return wq;
}

/// DIFF: what the waserror in shrwalk protects.
fn shrwalk1(wq: *Walkqid, nc: *Chan, name: []const []const u8, alloced: bool) Error!void {
    const sch = try tosch(nc);
    for (name, 0..) |nam, j| {
        if (nc.qid.type != QTDIR)
            return error.Enotdir;

        if (std.mem.eql(u8, nam, ".")) {
            // nop
        } else if (std.mem.eql(u8, nam, "..")) {
            switch (sch.level) {
                Qshr => {
                    sch.level = Qroot;
                    nc.qid = shrqid(sch.level, 0);
                },
                Qcshr => {
                    sch.level = Qcroot;
                    nc.qid = shrqid(sch.level, 0);
                },
                else => return error.Egreg,
            }
            putshr(sch.shr.?);
            sch.shr = null;
        } else if (sch.level == Qcroot or sch.level == Qroot) {
            qlock(&shrslk);
            var s = shrs;
            while (s) |shr| : (s = shr.next) {
                if (std.mem.eql(u8, nam, shr.ent.name)) {
                    _ = incref(&shr.ent.ref);
                    break;
                }
            }
            qunlock(&shrslk);
            const shr = s orelse
                return error.Enonexist;
            sch.level = if (sch.level == Qcroot) Qcshr else Qshr;
            sch.shr = shr;
            nc.qid = shrqid(sch.level, shr.ent.id);
        } else if (sch.level == Qcshr) {
            const shr = sch.shr.?;
            const h = &shr.umh;
            rlock(&h.lock);
            var p = shr.mpts;
            while (p) |mpt| : (p = mpt.next) {
                if (std.mem.eql(u8, nam, mpt.ent.name)) {
                    _ = incref(&mpt.ent.ref);
                    break;
                }
            }
            runlock(&h.lock);
            const mpt = p orelse
                return error.Enonexist;
            sch.mpt = mpt;
            sch.level = Qcmpt;
            nc.qid = shrqid(sch.level, mpt.ent.id);
        } else if (sch.level == Qshr) {
            const shr = sch.shr.?;
            const h = &shr.umh;
            var wq2: ?*Walkqid = null;
            rlock(&h.lock);
            var mp = h.mount;
            while (mp) |m| : (mp = m.next) {
                if (wq2 != null)
                    break;
                wq2 = devmod.devtab[m.to.type].walk(m.to, null, name[j..]) catch continue;
            }
            runlock(&h.lock);
            const w2 = wq2 orelse
                return error.Enonexist;
            @memcpy(wq.qid[wq.nqid..][0..w2.nqid], w2.qid[0..w2.nqid]);
            wq.nqid += w2.nqid;
            if (alloced)
                cclose(wq.clone.?);
            wq.clone = w2.clone;
            alloc.free(w2);
            return;
        } else return error.Egreg;
        wq.qid[wq.nqid] = nc.qid;
        wq.nqid += 1;
    }
}

fn shrgen(c: *Chan, _: ?[]const u8, _: []const Dirtab, s_: i32, dp: *Dir) i32 {
    const up = arch.up().?;
    var s = s_;

    const sch = tosch(c) catch return -1;
    switch (sch.level) {
        Qroot, Qcroot => {
            qlock(&shrslk);
            var p = shrs;
            while (p != null and s > 0) : (p = p.?.next)
                s -= 1;
            const shr = p orelse {
                qunlock(&shrslk);
                return -1;
            };
            const name = fmt.snprint(&up.genbuf, "%s", .{shr.ent.name});
            if (sch.level == Qroot)
                devdir(c, shrqid(Qshr, shr.ent.id), name, 0, shr.ent.owner, shr.ent.perm & ~@as(u32, 0o222), dp)
            else
                devdir(c, shrqid(Qcshr, shr.ent.id), name, 0, shr.ent.owner, shr.ent.perm, dp);
            qunlock(&shrslk);
            return 1;
        },
        Qcshr => {
            const shr = sch.shr.?;
            const h = &shr.umh;
            rlock(&h.lock);
            var p = shr.mpts;
            while (p != null and s > 0) : (p = p.?.next)
                s -= 1;
            const mpt = p orelse {
                runlock(&h.lock);
                return -1;
            };
            const name = fmt.snprint(&up.genbuf, "%s", .{mpt.ent.name});
            devdir(c, shrqid(Qcmpt, mpt.ent.id), name, 0, mpt.ent.owner, mpt.ent.perm, dp);
            runlock(&h.lock);
            return 1;
        },
        else => return -1,
    }
}

fn shrstat(c: *Chan, db: []u8) Error!usize {
    var dir: Dir = .{};

    const sch = try tosch(c);
    switch (sch.level) {
        Qroot => devdir(c, c.qid, "#σ", 0, proc.eve, 0o555, &dir),
        Qcroot => devdir(c, c.qid, "#σc", 0, proc.eve, 0o777, &dir),
        Qshr => {
            const e = &sch.shr.?.ent;
            devdir(c, c.qid, e.name, 0, e.owner, e.perm & ~@as(u32, 0o222), &dir);
        },
        Qcshr => {
            const e = &sch.shr.?.ent;
            devdir(c, c.qid, e.name, 0, e.owner, e.perm, &dir);
        },
        Qcmpt => {
            const e = &sch.mpt.?.ent;
            devdir(c, c.qid, e.name, 0, e.owner, e.perm, &dir);
        },
        else => return error.Egreg,
    }
    const rc = fcall.convD2M(&dir, db);
    if (rc == 0)
        return error.Ebadarg;
    return rc;
}

fn shropen(c: *Chan, omode: u32) Error!*Chan {
    if (c.qid.type == QTDIR and omode != OREAD)
        return error.Eisdir;

    const mode = try devmod.openmode(omode);
    const sch = try tosch(c);
    switch (sch.level) {
        Qroot, Qcroot => {},
        Qshr, Qcshr => {
            const shr = sch.shr.?;
            try devmod.devpermcheck(shr.ent.owner, shr.ent.perm, mode);
        },
        Qcmpt => {
            if (omode & lib.OTRUNC != 0)
                return error.Eexist;
            if (omode & lib.ORCLOSE != 0)
                return error.Eperm;
            const shr = sch.shr.?;
            const mpt = sch.mpt.?;
            try devmod.devpermcheck(mpt.ent.owner, mpt.ent.perm, mode);
            rlock(&shr.umh.lock);
            const nc = blk: {
                if (mpt.to) |to| {
                    if (to.mchan) |mc|
                        break :blk mc;
                }
                runlock(&shr.umh.lock);
                return error.Eshutdown;
            };
            _ = incref(&nc.ref);
            runlock(&shr.umh.lock);
            if (mode != nc.mode) {
                cclose(nc);
                return error.Eperm;
            }
            cclose(c);
            return nc;
        },
        else => return error.Egreg,
    }
    c.mode = @intCast(mode);
    c.flag |= COPEN;
    c.offset = 0;
    return c;
}

fn shrcreate(c: *Chan, name: []const u8, omode: u32, perm: u32) Error!*Chan {
    const up = arch.up().?;

    const mode = try devmod.openmode(omode);
    const sch = try tosch(c);
    switch (sch.level) {
        Qcroot, Qcshr => {
            if (std.mem.eql(u8, up.user, "none"))
                return error.Eperm;
        },
        else => {},
    }
    switch (sch.level) {
        Qshr => {
            _ = incref(&c.ref);
            // createdir takes the reference when it succeeds
            const nc = chan.createdir(c, &sch.shr.?.umh) catch |e| {
                cclose(c);
                return e;
            };
            const nnc = devmod.devtab[nc.type].create(nc, name, omode, perm) catch |e| {
                cclose(nc);
                return e;
            };
            cclose(c);
            return nnc;
        },
        Qcroot => {
            if (!pgrp.canmount(up.pgrp.?))
                return error.Enoattach;
            if ((perm & DMDIR) == 0 or mode != OREAD)
                return error.Eperm;
            if (name.len >= up.genbuf.len)
                return error.Etoolong;
            qlock(&shrslk);
            var s = shrs;
            while (s) |x| : (s = x.next) {
                if (std.mem.eql(u8, name, x.ent.name)) {
                    qunlock(&shrslk);
                    return error.Eexist;
                }
            }

            const shr = alloc.snew(Shr);
            shr.* = .{};
            _ = incref(&shr.ent.ref);
            shr.ent.id = shrid;
            shrid += 1;

            kstrdup(&shr.ent.name, name);
            kstrdup(&shr.ent.owner, up.user);
            shr.ent.perm = perm;

            _ = incref(&shr.ent.ref);
            shr.next = shrs;
            shrs = shr;

            qunlock(&shrslk);

            sch.level = Qcshr;
            c.qid = shrqid(sch.level, shr.ent.id);
            sch.shr = shr;
        },
        Qcshr => {
            if (!pgrp.canmount(up.pgrp.?))
                return error.Enoattach;
            if ((perm & DMDIR) != 0 or mode != OWRITE)
                return error.Eperm;

            const shr = sch.shr.?;
            if (std.mem.eql(u8, shr.ent.owner, proc.eve) and !devcons.iseve())
                return error.Eperm;
            try devmod.devpermcheck(shr.ent.owner, shr.ent.perm, ORDWR);

            if (name.len >= up.genbuf.len)
                return error.Etoolong;

            const h = &shr.umh;
            wlock(&h.lock);
            var p = shr.mpts;
            while (p) |x| : (p = x.next) {
                if (std.mem.eql(u8, name, x.ent.name)) {
                    wunlock(&h.lock);
                    return error.Eexist;
                }
            }

            const mpt = alloc.snew(Mpt);
            mpt.* = .{};
            _ = incref(&mpt.ent.ref);
            mpt.ent.id = mptid;
            mptid += 1;

            kstrdup(&mpt.ent.name, name);
            kstrdup(&mpt.ent.owner, up.user);
            mpt.ent.perm = perm;

            _ = incref(&mpt.ent.ref);
            mpt.mflag = if (shr.mpts == null) lib.MCREATE else 0;
            mpt.next = shr.mpts;
            shr.mpts = mpt;

            wunlock(&h.lock);

            sch.level = Qcmpt;
            c.qid = shrqid(sch.level, mpt.ent.id);
            sch.mpt = mpt;
        },
        else => return error.Eperm,
    }
    c.flag |= COPEN;
    c.mode = @intCast(mode);
    return c;
}

fn shrremove(c: *Chan) Error!void {
    const sch = try tosch(c);
    defer shrclunk(c) catch {};
    var shr: *Shr = undefined;
    switch (sch.level) {
        Qcshr, Qcmpt => {
            shr = sch.shr.?;
            if (!devcons.iseve()) {
                if (std.mem.eql(u8, shr.ent.owner, proc.eve))
                    return error.Eperm;
                try devmod.devpermcheck(shr.ent.owner, shr.ent.perm, ORDWR);
            }
        },
        else => return error.Eperm,
    }
    switch (sch.level) {
        Qcshr => {
            const h = &shr.umh;
            qlock(&shrslk);
            rlock(&h.lock);
            if (shr.mpts != null) {
                runlock(&h.lock);
                qunlock(&shrslk);
                return proc.errorf("directory not empty", .{});
            }
            runlock(&h.lock);
            var sl: *?*Shr = &shrs;
            while (sl.*) |x| : (sl = &x.next) {
                if (x == shr) {
                    sl.* = shr.next;
                    shr.next = null;
                    putshr(shr);
                    break;
                }
            }
            qunlock(&shrslk);
        },
        Qcmpt => {
            var bc: ?*Chan = null;
            const mpt = sch.mpt.?;
            const h = &shr.umh;
            wlock(&h.lock);
            var ml: *?*Mpt = &shr.mpts;
            while (ml.*) |x| : (ml = &x.next) {
                if (x == mpt) {
                    ml.* = mpt.next;
                    mpt.next = null;
                    bc = mpt.to;
                    mpt.to = null;
                    relink(shr);
                    putmpt(mpt);
                    break;
                }
            }
            wunlock(&h.lock);
            if (bc) |b|
                cclose(b);
        },
        else => {},
    }
}

fn shrwstat(c: *Chan, dp: []const u8) Error!usize {
    const up = arch.up().?;
    var d: Dir = .{};

    const strs = alloc.smalloc(dp.len)[0..dp.len];
    defer alloc.free(strs);
    const n = fcall.convM2D(dp, &d, strs);
    if (n == 0)
        return error.Eshortstat;

    var h: ?*Mhead = null;
    const sch = try tosch(c);
    var ent: *Ent = undefined;
    switch (sch.level) {
        Qcshr => {
            ent = &sch.shr.?.ent;
            qlock(&shrslk);
        },
        Qcmpt => {
            ent = &sch.mpt.?.ent;
            h = &sch.shr.?.umh;
            wlock(&h.?.lock);
        },
        else => return error.Eperm,
    }
    defer {
        if (h) |mh|
            wunlock(&mh.lock)
        else
            qunlock(&shrslk);
    }

    if (!std.mem.eql(u8, ent.owner, up.user) and !devcons.iseve())
        return error.Eperm;

    if (d.name.len != 0 and !std.mem.eql(u8, ent.name, d.name)) {
        if (std.mem.findScalar(u8, d.name, '/') != null)
            return error.Ebadchar;
        if (d.name.len >= up.genbuf.len)
            return error.Etoolong;
        kstrdup(&ent.name, d.name);
    }
    if (d.uid.len != 0)
        kstrdup(&ent.owner, d.uid);
    if (d.mode != ~@as(u32, 0))
        ent.perm = d.mode & 0o777;

    return n;
}

fn shrread(c: *Chan, va: []u8, _: i64) Error!usize {
    const sch = try tosch(c);
    switch (sch.level) {
        Qroot, Qcroot, Qcshr => return devmod.devdirread(c, va, &.{}, shrgen),
        Qshr => {
            const omh = c.umh;
            c.umh = &sch.shr.?.umh;
            defer c.umh = omh;
            return sysfile.unionread(c, va);
        },
        else => return error.Egreg,
    }
}

fn shrwrite(c: *Chan, va: []const u8, _: i64) Error!usize {
    const up = arch.up().?;

    if (!pgrp.canmount(up.pgrp.?))
        return error.Enoattach;
    const sch = try tosch(c);
    if (sch.level != Qcmpt)
        return error.Egreg;

    // the text ends at a NUL, as the C's copy does
    var buf = va;
    if (std.mem.findScalar(u8, buf, 0)) |k|
        buf = buf[0..k];

    const r = netif.strtou(u32, buf, 10);
    if (r.n == 0 or (r.n < buf.len and buf[r.n] != '\n'))
        return error.Ebadarg;
    const fd: i32 = @bitCast(r.v);
    const aname: []const u8 = if (r.n + 1 < buf.len) buf[r.n + 1 ..] else "";

    const c0 = blk: {
        const bc = try sysfile.fdtochan(fd, ORDWR, false, true);
        defer cclose(bc);
        break :blk try devmnt.mntattach(bc, null, aname, 0);
    };

    const mpt = sch.mpt.?;
    const shr = sch.shr.?;
    const h = &shr.umh;
    wlock(&h.lock);
    const bc = mpt.to;
    mpt.to = c0;
    relink(shr);
    wunlock(&h.lock);

    if (bc) |b|
        cclose(b);

    return va.len;
}

fn shrclose(c: *Chan) Error!void {
    if (c.flag & CRCLOSE != 0)
        try shrremove(c)
    else
        try shrclunk(c);
}

pub const shrdevtab: devmod.Dev = .{
    .dc = 'σ',
    .name = "shr",

    .init = shrinit,
    .attach = shrattach,
    .walk = shrwalk,
    .stat = shrstat,
    .open = shropen,
    .create = shrcreate,
    .close = shrclose,
    .read = shrread,
    .write = shrwrite,
    .remove = shrremove,
    .wstat = shrwstat,
};

fn chowner(ent: *Ent, old: []const u8, new: []const u8) void {
    if (ent.owner.ptr != portdat.nostr.ptr and std.mem.eql(u8, old, ent.owner))
        kstrdup(&ent.owner, new);
}

pub fn shrrenameuser(old: []const u8, new: []const u8) void {
    qlock(&shrslk);
    var s = shrs;
    while (s) |shr| : (s = shr.next) {
        wlock(&shr.umh.lock);
        var p = shr.mpts;
        while (p) |mpt| : (p = mpt.next)
            chowner(&mpt.ent, old, new);
        wunlock(&shr.umh.lock);
        chowner(&shr.ent, old, new);
    }
    qunlock(&shrslk);
}
