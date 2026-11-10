//! The service registry, #s: a place to post an open channel under a
//! name so that other processes can open it, with private boards made
//! by opening clone.
//! from 9/port/devsrv.c
//!
//! DIFF:
//!   - Srv and Board start with an anonymous Link in C and the lists
//!     are walked through it with casts.  Here the Link is the member
//!     `l`, the lists are lists of Link, and SRV() and BOARD() get from
//!     a Link to the structure around it.  freelink is told which of
//!     the two it frees.
//!   - lookup and remove take null where the C passes nil for the name
//!     or ~0UL for the qid path.
//!   - Errors are Zig error returns and the waserror sites became
//!     defer.  Where the C calls cclose after dropping srvlk (srvopen,
//!     the error path of srvwrite) the order is kept, since closing a
//!     channel of this device takes the lock.
//!   - A Devgen cannot fail in this kernel, but the C srvgen raises
//!     Eperm from devpermcheck when a walk steps into a board the user
//!     may not search.  srvgen returns -1 there, and srvwalk makes the
//!     same checks first (walkperm) so that the walk still fails with
//!     Eperm.
//!   - fdtochan is from sysfile.c and is private here until that file
//!     is ported (M4).  iseve comes from devcons.zig until auth.c (M7).

const std = @import("std");
const fcall = @import("fcall");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const lib = @import("lib.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const chan = @import("chan.zig");
const devmod = @import("dev.zig");
const devcons = @import("devcons.zig");
const p9 = @import("print.zig");

const panic = p9.panic;
const incref = portdat.incref;
const decref = portdat.decref;
const rlock = ql.rlock;
const runlock = ql.runlock;
const wlock = ql.wlock;
const wunlock = ql.wunlock;
const kstrcpy = proc.kstrcpy;
const kstrdup = proc.kstrdup;
const devpermcheck = devmod.devpermcheck;
const iseve = devcons.iseve; // M7: auth.c

pub const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Qid = portdat.Qid;
const Dir = portdat.Dir;
const Proc = portdat.Proc;
const Dirtab = devmod.Dirtab;
const QTDIR = fcall.QTDIR;
const QTFILE = fcall.QTFILE;
const DEVDOTDOT = portdat.DEVDOTDOT;

fn SRVTYPE(x: u64) u2 {
    return @truncate(x);
}

fn SRVPATH(x: u64) u64 {
    return x >> 2;
}

fn SRVQID(x: u64, t: u2) u64 {
    return (x << 2) | t;
}

const Link = struct {
    link: ?*Link = null,
    name: []u8 = portdat.nostr,
    owner: []u8 = portdat.nostr,
    perm: u32 = 0,
    path: u32 = 0,
};

const Srv = struct {
    l: Link = .{},
    chan: ?*Chan = null,
};

const Board = struct {
    l: Link = .{},
    ref: portdat.Ref = .{},

    closed: i32 = 0,
    srv: ?*Link = null, // list of Srv

    // tree linkage
    parent: ?*Board = null,
    child: ?*Link = null, // list of Board

    // all boards list
    prev: *Board = undefined,
    next: *Board = undefined,
};

fn SRV(l: *Link) *Srv {
    return @fieldParentPtr("l", l);
}

fn BOARD(l: *Link) *Board {
    return @fieldParentPtr("l", l);
}

const Qsrv = 0;
const Qclone = 1;
const Qlease = 2;

const clone = "clone";

var srvlk: portdat.RWLock = .{};
var srvpath: u32 = 0;
var srvroot: Board = .{};
var rootname = "#s".*;

fn assert(ok: bool) void {
    if (!ok) panic("devsrv: assert failed, pc %#p", .{@returnAddress()});
}

fn up() *Proc {
    return arch.up().?;
}

fn aux(c: *const Chan) *Board {
    return @ptrCast(@alignCast(c.aux.?));
}

fn lookup(l: ?*Link, name: ?[]const u8, qidpath_: ?u64) ?*Link {
    var qidpath: ?u32 = null;
    if (qidpath_) |q| {
        assert(SRVTYPE(q) == Qsrv);
        qidpath = @as(u32, @truncate(SRVPATH(@as(u32, @truncate(q)))));
    }
    var lp = l;
    while (lp) |p| : (lp = p.link) {
        if (qidpath != null and p.path == qidpath.?)
            return p;
        if (name != null and std.mem.eql(u8, p.name, name.?))
            return p;
    }
    return null;
}

fn remove(l: *?*Link, name: ?[]const u8, qidpath_: ?u64) ?*Link {
    var qidpath: ?u32 = null;
    if (qidpath_) |q| {
        assert(SRVTYPE(q) == Qsrv);
        qidpath = @as(u32, @truncate(SRVPATH(@as(u32, @truncate(q)))));
    }
    var last = l;
    var lp = l.*;
    while (lp) |p| : (lp = p.link) {
        if (qidpath != null and p.path == qidpath.?)
            break;
        if (name != null and std.mem.eql(u8, p.name, name.?))
            break;
        last = &p.link;
    }
    const p = lp orelse return null;

    last.* = p.link;
    p.link = null;
    return p;
}

/// Free a Srv or a Board and the strings of its Link.
fn freelink(p: anytype) void {
    const l: *Link = &p.l;
    if (l.name.ptr != portdat.nostr.ptr)
        alloc.free(l.name.ptr);
    if (l.owner.ptr != portdat.nostr.ptr)
        alloc.free(l.owner.ptr);
    alloc.free(p);
}

/// always called with srvlock wlock'ed
fn boardclunk(b_: *Board) void {
    var b = b_;

    // srvroot is not ref-counted nor clunkable
    if (b == &srvroot)
        return;

    if (decref(&b.ref) != 0)
        return;

    // All boards must be walkable from root. So a board
    // is allowed to sit at zero references as long as it
    // still has active children. For leaf nodes we then
    // have to walk up the tree to clear now empty parents.
    while (b.closed != 0 and b.child == null) {
        assert(b.srv == null);
        assert(b.parent != null);

        // unlink from parent board
        const ch = BOARD(remove(&b.parent.?.child, b.l.name, null).?);
        assert(ch == b);

        // unlink from all boards list
        ch.prev.next = ch.next;
        ch.next.prev = ch.prev;

        b = ch.parent.?;
        freelink(ch);
    }
}

/// The name of an entry copied to up.genbuf, where it stays valid
/// after srvlk is released.
fn genname(name: []const u8) []const u8 {
    const u = up();
    kstrcpy(&u.genbuf, name);
    return std.mem.sliceTo(&u.genbuf, 0);
}

fn srvgen(c: *Chan, name: ?[]const u8, _: []const Dirtab, s_: i32, dp: *Dir) i32 {
    var s = s_;

    if (name != null and name.?.len >= up().genbuf.len)
        return -1;

    const b = aux(c);
    var sp: ?*Link = null;
    var ch: ?*Board = null;
    var isclone = false;
    var q = devmod.mkqid(~@as(u64, 0), 0, QTFILE);
    rlock(&srvlk);
    defer runlock(&srvlk);

    if (s == -2) { // dot
        ch = b;
    } else if (s == DEVDOTDOT) {
        ch = b.parent orelse &srvroot;
    } else if (name) |n| {
        if (std.mem.eql(u8, n, clone)) {
            isclone = true;
        } else {
            sp = lookup(b.srv, n, null);
            if (sp == null) {
                if (lookup(b.child, n, null)) |l| ch = BOARD(l);
            }
        }
    } else {
        if (s == 0) {
            isclone = true;
        } else {
            s -= 1;
            sp = b.srv;
            while (sp != null and s > 0) : (sp = sp.?.link)
                s -= 1;
            var cl = b.child;
            while (cl != null and s > 0) : (cl = cl.?.link)
                s -= 1;
            if (cl) |l| ch = BOARD(l);
        }
    }

    if (isclone) {
        q.path = SRVQID(SRVPATH(c.qid.path), Qclone);
        devmod.devdir(c, q, clone, 0, proc.eve, 0o444, dp);
    } else if (sp) |p| {
        q.path = SRVQID(p.path, Qsrv);
        devmod.devdir(c, q, genname(p.name), 0, p.owner, p.perm, dp);
    } else if (ch) |child| {
        if (name != null or s == DEVDOTDOT) {
            // DIFF: the C raises Eperm; srvwalk has checked already,
            // see walkperm.
            devpermcheck(child.l.owner, child.l.perm, lib.OEXEC) catch return -1;
            c.aux = child;
        }
        q.path = SRVQID(child.l.path, Qsrv);
        q.type = QTDIR;
        devmod.devdir(c, q, genname(child.l.name), 0, child.l.owner, child.l.perm | fcall.DMDIR, dp);
    } else {
        return -1;
    }

    return 1;
}

fn srvinit() void {
    srvroot.next = &srvroot;
    srvroot.prev = &srvroot;
    srvroot.l.path = srvpath;
    srvpath += 1;
    srvroot.l.name = &rootname;
    srvroot.l.perm = 0o777;
    kstrdup(&srvroot.l.owner, proc.eve);
}

fn srvattach(spec: []const u8) Error!*Chan {
    const c = devmod.devattach('s', spec);
    c.aux = &srvroot;
    return c;
}

/// DIFF: not in the C.  Fail with Eperm if walking the names from c
/// steps into a board that up may not search: the error that srvgen
/// raises in C in the middle of devwalk.
fn walkperm(c: *Chan, name: []const []const u8) Error!void {
    rlock(&srvlk);
    defer runlock(&srvlk);

    var b = aux(c);
    for (name) |n| {
        if (n.len >= up().genbuf.len)
            return;
        var ch: *Board = undefined;
        if (std.mem.eql(u8, n, ".")) {
            continue;
        } else if (std.mem.eql(u8, n, "..")) {
            ch = b.parent orelse &srvroot;
        } else {
            if (std.mem.eql(u8, n, clone) or lookup(b.srv, n, null) != null)
                return;
            ch = BOARD(lookup(b.child, n, null) orelse return);
        }
        try devpermcheck(ch.l.owner, ch.l.perm, lib.OEXEC);
        b = ch;
    }
}

fn srvwalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    if (c.qid.type & QTDIR != 0)
        try walkperm(c, name);

    const wq = try devmod.devwalk(c, nc, name, &.{}, srvgen);
    const cl = wq.clone orelse return wq;

    const b = aux(cl);
    if (b == &srvroot)
        return wq;

    _ = incref(&b.ref);
    return wq;
}

fn srvstat(c: *Chan, db: []u8) Error!usize {
    // devstat cheats for dir stats, we care about our dir perms
    if (c.qid.type == QTDIR) {
        var d: Dir = .{};
        _ = srvgen(c, null, &.{}, -2, &d);
        const n = fcall.convD2M(&d, db);
        if (n == 0)
            return error.Ebadarg;
        return n;
    }

    return devmod.devstat(c, db, &.{}, srvgen);
}

fn srvopen(c: *Chan, omode: u32) Error!*Chan {
    if (omode & lib.OTRUNC != 0)
        return error.Eexist;
    if (omode & lib.ORCLOSE != 0)
        return error.Eperm;
    const mode = try devmod.openmode(omode);

    const b = aux(c);
    if (SRVTYPE(c.qid.path) == Qclone) {
        var buf: [64]u8 = undefined;

        wlock(&srvlk);
        defer wunlock(&srvlk);

        if (b.closed != 0)
            return error.Eshutdown;
        const ch = alloc.snew(Board);
        ch.* = .{};
        ch.ref.ref = 1;
        ch.l.perm = 0o770;
        var name: []const u8 = undefined;
        while (true) {
            ch.l.path = srvpath;
            srvpath +%= 1;
            name = fmt.snprint(&buf, "%ld", .{ch.l.path});
            if (lookup(b.srv, name, null) == null)
                break;
        }
        kstrdup(&ch.l.name, name);
        kstrdup(&ch.l.owner, up().user);

        // link to all boards list
        ch.next = &srvroot;
        ch.prev = srvroot.prev;
        ch.next.prev = ch;
        ch.prev.next = ch;

        // link to parent board
        ch.parent = b;
        ch.l.link = b.child;
        b.child = &ch.l;

        c.aux = ch;
        c.qid.path = SRVQID(ch.l.path, Qlease);
        c.mode = @intCast(mode);
        boardclunk(b);
        return c;
    }

    const nc = nc: {
        rlock(&srvlk);
        defer runlock(&srvlk);

        if (c.qid.type == QTDIR) {
            if (omode != lib.OREAD)
                return error.Eisdir;
            try devpermcheck(b.l.owner, b.l.perm, omode);
            c.mode = @intCast(mode);
            c.flag |= portdat.COPEN;
            c.offset = 0;
            return c;
        }
        if (b.closed != 0)
            return error.Eshutdown;

        const sp = SRV(lookup(b.srv, null, c.qid.path) orelse return error.Eshutdown);
        const sc = sp.chan orelse return error.Eshutdown;
        if (mode != sc.mode and sc.mode != lib.ORDWR)
            return error.Eperm;
        try devpermcheck(sp.l.owner, sp.l.perm, omode);

        _ = incref(&sc.ref);
        break :nc sc;
    };

    chan.cclose(c);
    return nc;
}

fn srvcreate(c: *Chan, name: []const u8, omode: u32, perm: u32) Error!*Chan {
    if (try devmod.openmode(omode) != lib.OWRITE)
        return error.Eperm;

    if (name.len >= up().genbuf.len)
        return error.Etoolong;

    if (std.mem.eql(u8, name, clone))
        return error.Eexist;

    const sp = alloc.snew(Srv);
    sp.* = .{};
    kstrdup(&sp.l.name, name);
    kstrdup(&sp.l.owner, up().user);

    const b = aux(c);
    {
        errdefer freelink(sp);
        wlock(&srvlk);
        defer wunlock(&srvlk);

        if (b.closed != 0)
            return error.Eshutdown;
        try devpermcheck(b.l.owner, b.l.perm, lib.OWRITE);
        if (lookup(b.srv, name, null) != null)
            return error.Eexist;
        if (lookup(b.child, name, null) != null)
            return error.Eexist;

        sp.l.perm = perm & 0o777;
        sp.l.path = srvpath;
        srvpath +%= 1;

        c.qid.path = SRVQID(sp.l.path, Qsrv);
        c.qid.type = QTFILE;

        sp.l.link = b.srv;
        b.srv = &sp.l;
    }

    c.flag |= portdat.COPEN;
    c.mode = lib.OWRITE;

    return c;
}

fn srvremove(c: *Chan) Error!void {
    const b = aux(c);
    const sp = sp: {
        wlock(&srvlk);
        defer wunlock(&srvlk);
        defer boardclunk(b);

        if (c.qid.type == QTDIR)
            return error.Eperm;
        switch (SRVTYPE(c.qid.path)) {
            Qlease, Qclone => return error.Eperm,
            else => {},
        }

        const sp = SRV(lookup(b.srv, null, c.qid.path) orelse return error.Enonexist);

        if (!std.mem.eql(u8, sp.l.owner, up().user) and !iseve())
            return error.Eperm;

        _ = remove(&b.srv, null, c.qid.path);
        break :sp sp;
    };

    if (sp.chan) |sc|
        chan.cclose(sc);
    freelink(sp);
}

fn srvwstat(c: *Chan, dp: []const u8) Error!usize {
    var d: Dir = .{};

    switch (SRVTYPE(c.qid.path)) {
        Qlease, Qclone => return error.Eperm,
        else => {},
    }
    if (c.qid.type == QTDIR and aux(c) == &srvroot)
        return error.Eperm;

    const strs = alloc.snewslice(u8, dp.len + 1);
    defer alloc.free(strs.ptr);
    const n = fcall.convM2D(dp, &d, strs);
    if (n == 0)
        return error.Eshortstat;

    const b = aux(c);
    wlock(&srvlk);
    defer wunlock(&srvlk);

    if (b.closed != 0)
        return error.Eshutdown;

    const lp = if (c.qid.type == QTDIR)
        &b.l
    else
        lookup(b.srv, null, c.qid.path) orelse return error.Enonexist;

    if (!std.mem.eql(u8, lp.owner, up().user) and !iseve())
        return error.Eperm;

    if (d.name.len != 0 and !std.mem.eql(u8, lp.name, d.name)) {
        if (std.mem.findScalar(u8, d.name, '/') != null)
            return error.Ebadchar;
        if (d.name.len >= up().genbuf.len)
            return error.Etoolong;

        // Ensure new name doesn't conflict with old names
        if (std.mem.eql(u8, d.name, clone))
            return error.Eexist;
        const s = if (c.qid.type == QTDIR) b.parent.? else b;
        if (lookup(s.srv, d.name, null) != null)
            return error.Eexist;
        if (lookup(s.child, d.name, null) != null)
            return error.Eexist;
        kstrdup(&lp.name, d.name);
    }
    if (d.uid.len != 0)
        kstrdup(&lp.owner, d.uid);
    if (d.mode != ~@as(u32, 0))
        lp.perm = d.mode & 0o777;

    return n;
}

fn srvclose(c: *Chan) Error!void {
    if (c.flag & portdat.CRCLOSE != 0 and SRVTYPE(c.qid.path) != Qlease) {
        // in theory we need to override any changes in removability
        // since open, but since all that's checked is the owner,
        // which is immutable, all is well.
        srvremove(c) catch {};
        return;
    }

    const b = aux(c);
    if (b == &srvroot)
        return;

    wlock(&srvlk);
    if (SRVTYPE(c.qid.path) != Qlease) {
        boardclunk(b);
        wunlock(&srvlk);
        return;
    }

    // free later after releasing srvlk
    var lp = b.srv;
    b.srv = null;
    b.closed += 1;
    boardclunk(b);
    wunlock(&srvlk);

    while (lp) |l| {
        lp = l.link;
        const sp = SRV(l);
        if (sp.chan) |sc|
            chan.ccloseq(sc);
        freelink(sp);
    }
}

fn srvread(c: *Chan, va: []u8, off: i64) Error!usize {
    if (SRVTYPE(c.qid.path) == Qlease) {
        const b = aux(c);
        rlock(&srvlk);
        defer runlock(&srvlk);
        return devcons.readstr(@as(u32, @truncate(@as(u64, @bitCast(off)))), va, b.l.name);
    }
    try chan.isdir(c);
    return devmod.devdirread(c, va, &.{}, srvgen);
}

/// strtoul(s, 0, 0): optional white space and sign, then a number in
/// base 16 after 0x, 8 after 0, 10 otherwise, up to the first character
/// that is not a digit.  Overflow wraps where the C saturates.
fn strtoul(s: []const u8) u32 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or (s[i] >= '\t' and s[i] <= '\r'))) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    var base: u32 = 10;
    if (i < s.len and s[i] == '0') {
        base = 8;
        if (i + 2 < s.len and (s[i + 1] == 'x' or s[i + 1] == 'X') and std.ascii.isHex(s[i + 2])) {
            base = 16;
            i += 2;
        }
    }
    var n: u32 = 0;
    while (i < s.len) : (i += 1) {
        const d = std.fmt.charToDigit(s[i], 16) catch break;
        if (d >= base) break;
        n = n *% base +% d;
    }
    return if (neg) 0 -% n else n;
}

/// The channel behind a file descriptor of the current process.
/// from 9/port/sysfile.c
// M4: move to sysfile.zig
fn fdtochan(fd: i32, mode: i32, chkmnt: bool, iref: bool) Error!*Chan {
    const f = up().fgrp.?;

    taslock.lock(&f.lock);
    const c = blk: {
        if (fd >= 0 and @as(usize, @intCast(fd)) < f.fd.len) {
            if (f.fd[@intCast(fd)]) |c| break :blk c;
        }
        taslock.unlock(&f.lock);
        return error.Ebadfd;
    };
    if (iref)
        _ = incref(&c.ref);
    taslock.unlock(&f.lock);

    if (chkmnt and c.flag & portdat.CMSG != 0) {
        if (iref)
            chan.cclose(c);
        return error.Ebadusefd;
    }

    if (mode < 0 or c.mode == lib.ORDWR)
        return c;

    if (mode & lib.OTRUNC != 0 and c.mode == lib.OREAD) {
        if (iref)
            chan.cclose(c);
        return error.Ebadusefd;
    }

    if (mode & ~@as(i32, lib.OTRUNC) != c.mode) {
        if (iref)
            chan.cclose(c);
        return error.Ebadusefd;
    }
    return c;
}

fn srvwrite(c: *Chan, va: []const u8, _: i64) Error!usize {
    const n = va.len;

    if (SRVTYPE(c.qid.path) == Qlease)
        return error.Eperm;

    if (n >= 32)
        return error.Etoobig;
    const fd: i32 = @bitCast(strtoul(std.mem.sliceTo(va, 0)));

    const c1 = try fdtochan(fd, -1, false, true); // error check and inc ref
    // after srvlk is released: closing a #s channel takes it
    errdefer chan.cclose(c1);

    const b = aux(c);
    wlock(&srvlk);
    defer wunlock(&srvlk);

    if (b.closed != 0)
        return error.Eshutdown;
    if (c1.qid.type & fcall.QTAUTH != 0)
        return proc.errorf("cannot post auth file in srv", .{});
    const sp = SRV(lookup(b.srv, null, c.qid.path) orelse return error.Enonexist);

    if (sp.chan != null)
        return error.Ebadusefd;

    sp.chan = c1;

    if (c1.srvname == null) {
        var s: []u8 = portdat.nostr;
        kstrdup(&s, c.path.?.str());
        c1.srvname = s;
    }

    return n;
}

pub const srvdevtab: devmod.Dev = .{
    .dc = 's',
    .name = "srv",

    .init = srvinit,
    .attach = srvattach,
    .walk = srvwalk,
    .stat = srvstat,
    .open = srvopen,
    .create = srvcreate,
    .close = srvclose,
    .read = srvread,
    .write = srvwrite,
    .remove = srvremove,
    .wstat = srvwstat,
};

pub fn srvrenameuser(old: []const u8, new: []const u8) void {
    wlock(&srvlk);
    var b = &srvroot;
    while (true) {
        if (std.mem.eql(u8, b.l.owner, old))
            kstrdup(&b.l.owner, new);
        var lp = b.srv;
        while (lp) |sp| : (lp = sp.link) {
            if (std.mem.eql(u8, sp.owner, old))
                kstrdup(&sp.owner, new);
        }
        b = b.next;
        if (b == &srvroot)
            break;
    }
    wunlock(&srvlk);
}
