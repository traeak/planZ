//! Channels: the kernel's handle on a file, and the code that turns a
//! name into one by walking the process's name space.
//! from 9/port/chan.c
//!
//! DIFF:
//!   - Errors are Zig error returns.  A device's walk reports failure by
//!     returning an error where the C returns nil, so ewalk is a plain
//!     call.  Where the C leaves a message in up->errstr for the caller
//!     to raise later, the Zig returns the error at once or records it
//!     with proc.seterror.
//!   - Names are slices.  namec does not copy the name to overwrite its
//!     slashes; the elements are slices of it.  growparse is gone:
//!     parsename allocates once.
//!   - namec is split: the part under its second waserror is namec1, and
//!     the code at the label Open is nameopen.
//!   - validname knows only kernel addresses so far; checking a name
//!     that lives in user memory arrives with system calls.
//!   - incref, decref, kstrcpy and kstrdup live with the types they work
//!     on (portdat.zig, proc.zig).

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
const tod = @import("tod.zig");
const devmod = @import("dev.zig");
const pgrp = @import("pgrp.zig");
const p9 = @import("print.zig");

const print = p9.print;
const panic = p9.panic;
const lock = taslock.lock;
const unlock = taslock.unlock;
const incref = portdat.incref;
const decref = portdat.decref;

pub const Error = proc.Error;
const Chan = portdat.Chan;
const Path = portdat.Path;
const Mhead = portdat.Mhead;
const Mount = portdat.Mount;
const Walkqid = portdat.Walkqid;
const Qid = portdat.Qid;
const Dir = portdat.Dir;
const Proc = portdat.Proc;

const QTDIR = fcall.QTDIR;
const MAXWELEM = fcall.MAXWELEM;

const PATHSLOP = 20;
const PATHMSLOP = 20;

var chanalloc: struct {
    lock: taslock.Lock = .{},
    fid: i32 = 0,
    free: ?*Chan = null,
    list: ?*Chan = null,
} = .{};

const Elemlist = struct {
    elems: [][]const u8 = &.{},
    nelems: usize = 0,
    /// off[i] is where element i ends in the name, counted from the
    /// part after the prefix; off[0] is where the first one starts.
    off: []usize = &.{},
    mustbedir: bool = false,
    nerror: usize = 0,
    /// Length of the #x device part that was taken off the front.
    prefix: usize = 0,
};

fn up() *Proc {
    return arch.up().?;
}

fn dev(c: *const Chan) *const devmod.Dev {
    return devmod.devtab[c.type];
}

pub fn chanpath(c: ?*const Chan) []const u8 {
    const ch = c orelse return "<nil chan>";
    const p = ch.path orelse return "<nil path>";
    return p.str();
}

pub fn isdotdot(p: []const u8) bool {
    return std.mem.eql(u8, p, "..");
}

pub fn chandevreset() void {
    tod.todinit(); // avoid later reentry causing infinite recursion
    for (devmod.devtab) |d| {
        p9.progress(d.name); // DIFF: see print.zig
        d.reset();
    }
}

pub fn chandevinit() void {
    for (devmod.devtab) |d| d.init();
    proc.kproc("closeproc", closeproc, null);
}

pub fn chandevshutdown() void {
    // shutdown in reverse order
    var i = devmod.devtab.len;
    while (i > 0) {
        i -= 1;
        devmod.devtab[i].shutdown();
    }
}

pub fn newchan() *Chan {
    lock(&chanalloc.lock);
    var c: *Chan = undefined;
    if (chanalloc.free) |f| {
        c = f;
        chanalloc.free = c.next;
        c.next = null;
    } else {
        unlock(&chanalloc.lock);
        c = alloc.snew(Chan);
        c.* = .{};
        lock(&chanalloc.lock);
        c.link = chanalloc.list;
        chanalloc.list = c;
    }
    if (c.fid == 0) {
        chanalloc.fid += 1;
        c.fid = chanalloc.fid;
    }
    unlock(&chanalloc.lock);

    // if you get an error before associating with a dev,
    // close calls rootclose, a nop
    c.type = 0;
    c.flag = 0;
    c.ref.ref = 1;
    c.dev = 0;
    c.offset = 0;
    c.devoffset = 0;
    c.iounit = 0;
    c.umh = null;
    c.umc = null;
    c.uri = 0;
    c.dri = 0;
    c.dirrock = null;
    c.nrock = 0;
    c.ismtpt = false;
    c.mcp = null;
    c.mux = null;
    c.aux = null;
    c.mid = 0;
    c.mchan = null;
    c.mqid = .{};
    c.path = null;
    c.srvname = null;

    return c;
}

pub fn newpath(s: []const u8) *Path {
    const p = alloc.snew(Path);
    p.* = .{};
    p.len = s.len;
    p.s = alloc.snewslice(u8, s.len + PATHSLOP);
    @memcpy(p.s[0..s.len], s);
    p.ref.ref = 1;

    // Cannot use newpath for arbitrary names because the mtpt
    // array will not be populated correctly.  The names #/ and / are
    // allowed, but other names with / in them draw warnings.
    if (std.mem.findScalar(u8, s, '/') != null and !std.mem.eql(u8, s, "#/") and !std.mem.eql(u8, s, "/"))
        print("newpath: %s from %#p\n", .{ s, @returnAddress() });

    p.mlen = 1;
    p.mtpt = alloc.snewslice(?*Chan, PATHMSLOP);
    return p;
}

fn copypath(p: *Path) *Path {
    const pp = alloc.snew(Path);
    pp.* = .{};
    pp.ref.ref = 1;

    pp.len = p.len;
    pp.s = alloc.snewslice(u8, p.s.len);
    @memcpy(pp.s[0..p.len], p.s[0..p.len]);

    pp.mlen = p.mlen;
    pp.mtpt = alloc.snewslice(?*Chan, p.mtpt.len);
    for (0..pp.mlen) |i| {
        pp.mtpt[i] = p.mtpt[i];
        if (pp.mtpt[i]) |c| _ = incref(&c.ref);
    }

    return pp;
}

pub fn pathclose(p_: ?*Path) void {
    const p = p_ orelse return;
    if (decref(&p.ref) != 0)
        return;
    for (p.mtpt[0..p.mlen]) |m| {
        if (m) |c| cclose(c);
    }
    alloc.free(p.mtpt.ptr);
    alloc.free(p.s.ptr);
    alloc.free(p);
}

/// In place, rewrite name to compress multiple /, eliminate ., and process ..
/// (Really only called to remove a trailing .. that has been added.
/// Otherwise would need to update n->mtpt as well.)
fn fixdotdotname(p: *Path) void {
    if (p.s[0] == '#') {
        const r = std.mem.findScalar(u8, p.s[0..p.len], '/') orelse return;
        var n = lib.cleanname(p.s[r..], p.len - r);
        // The correct name is #i rather than #i/,
        // but the correct name of #/ is #/.
        if (n == 1 and p.s[r] == '/' and p.s[1] != '/')
            n = 0;
        p.len = r + n;
    } else p.len = lib.cleanname(p.s, p.len);
}

fn uniquepath(p: *Path) *Path {
    if (p.ref.ref > 1) {
        // copy on write
        const new = copypath(p);
        pathclose(p);
        return new;
    }
    return p;
}

fn addelem(p_: *Path, s: []const u8, from: ?*Chan) *Path {
    if (std.mem.eql(u8, s, "."))
        return p_;

    const p = uniquepath(p_);
    // Room for a slash, the element, and what cleanname may add.
    const a = p.len + 1 + s.len + 2;
    if (a > p.s.len) {
        const t = alloc.snewslice(u8, a + PATHSLOP);
        @memcpy(t[0..p.len], p.s[0..p.len]);
        alloc.free(p.s.ptr);
        p.s = t;
    }
    // don't insert extra slash if one is present
    if (p.len > 0 and p.s[p.len - 1] != '/' and s[0] != '/') {
        p.s[p.len] = '/';
        p.len += 1;
    }
    @memcpy(p.s[p.len..][0..s.len], s);
    p.len += s.len;
    if (isdotdot(s)) {
        fixdotdotname(p);
        if (p.mlen > 1) {
            p.mlen -= 1;
            if (p.mtpt[p.mlen]) |c| {
                p.mtpt[p.mlen] = null;
                cclose(c);
            }
        }
    } else {
        if (p.mlen >= p.mtpt.len) {
            const tt = alloc.snewslice(?*Chan, p.mlen + 1 + PATHMSLOP);
            @memcpy(tt[0..p.mlen], p.mtpt[0..p.mlen]);
            alloc.free(p.mtpt.ptr);
            p.mtpt = tt;
        }
        p.mtpt[p.mlen] = from;
        p.mlen += 1;
        if (from) |f| _ = incref(&f.ref);
    }
    return p;
}

/// Called when a Mnt's last channel goes; set by devmnt.
pub var muxclose: ?*const fn (*portdat.Mnt) void = null;

pub fn chanfree(c: *Chan) void {
    c.flag = portdat.CFREE;

    if (c.dirrock) |r| {
        alloc.free(r.ptr);
        c.dirrock = null;
        c.nrock = 0;
    }
    if (c.umh) |m| {
        putmhead(m);
        c.umh = null;
    }
    if (c.umc) |u| {
        cclose(u);
        c.umc = null;
    }
    if (c.mux) |m| {
        if (muxclose) |f| f(m);
        c.mux = null;
    }
    if (c.mchan) |m| {
        cclose(m);
        c.mchan = null;
    }
    if (c.srvname) |s| {
        alloc.free(s.ptr);
        c.srvname = null;
    }

    pathclose(c.path);
    c.path = null;

    lock(&chanalloc.lock);
    c.next = chanalloc.free;
    chanalloc.free = c;
    unlock(&chanalloc.lock);
}

// Queue a chan to be closed by one of the clunk procs.
var clunkq: struct {
    head: ?*Chan = null,
    tail: ?*Chan = null,
    nqueued: u32 = 0,
    nclosed: u32 = 0,
    l: taslock.Lock = .{},
    q: portdat.QLock = .{},
    r: portdat.Rendez = .{},
} = .{};

fn clunkwork(_: ?*anyopaque) bool {
    return clunkq.head != null;
}

fn closechanq(c: *Chan) void {
    lock(&clunkq.l);
    clunkq.nqueued +%= 1;
    c.next = null;
    if (clunkq.head != null)
        clunkq.tail.?.next = c
    else
        clunkq.head = c;
    clunkq.tail = c;
    unlock(&clunkq.l);
    _ = proc.wakeup(&clunkq.r);
}

fn closechandeq() ?*Chan {
    lock(&clunkq.l);
    const c = clunkq.head;
    if (c) |x| {
        clunkq.head = x.next;
        clunkq.nclosed +%= 1;
    }
    unlock(&clunkq.l);
    return c;
}

fn closeproc(_: ?*anyopaque) void {
    while (true) {
        var c = closechandeq();
        if (c == null) {
            ql.qlock(&clunkq.q);
            proc.tsleep(&clunkq.r, clunkwork, null, 500) catch {};
            c = closechandeq();
            if (c == null) {
                if (clunkq.q.head != null) {
                    ql.qunlock(&clunkq.q);
                    proc.pexit("no work", true);
                }
                ql.qunlock(&clunkq.q);
                continue;
            }
            if (clunkq.q.head == null)
                proc.kproc("closeproc", closeproc, null);
            ql.qunlock(&clunkq.q);
        }
        dev(c.?).close(c.?) catch {};
        chanfree(c.?);
    }
}

pub fn cclose(c: *Chan) void {
    if (c.ref.ref < 1 or c.flag & portdat.CFREE != 0)
        panic("cclose %#p", .{@returnAddress()});

    if (decref(&c.ref) != 0)
        return;

    if (dev(c).dc == 'M' and
        (c.flag & portdat.COPEN == 0 or c.flag & (portdat.CRCLOSE | portdat.CCACHE) == portdat.CCACHE) and
        c.qid.type & (fcall.QTEXCL | fcall.QTMOUNT | fcall.QTAUTH) == 0 and
        clunkq.nqueued -% clunkq.nclosed < 64)
    {
        closechanq(c);
        return;
    }

    dev(c).close(c) catch {};
    chanfree(c);
}

pub fn ccloseq(c: *Chan) void {
    if (c.ref.ref < 1 or c.flag & portdat.CFREE != 0)
        panic("ccloseq %#p", .{@returnAddress()});

    if (decref(&c.ref) == 0)
        closechanq(c);
}

/// Make sure we have the only copy of c.  (Copy on write.)
/// Takes over the caller's reference; on error the caller still has it.
pub fn cunique(c_: *Chan) Error!*Chan {
    var c = c_;
    if (c.ref.ref != 1) {
        const nc = try cclone(c);
        cclose(c);
        c = nc;
    }

    if (c.umh) |m| { //BUG
        print("cunique umh != nil from %#p\n", .{@returnAddress()});
        putmhead(m);
        c.umh = null;
    }

    return c;
}

pub fn eqqid(a: Qid, b: Qid) bool {
    return a.path == b.path and a.vers == b.vers;
}

pub fn eqchan(a: *const Chan, b: *const Chan, skipvers: bool) bool {
    if (a.qid.path != b.qid.path)
        return false;
    if (!skipvers and a.qid.vers != b.qid.vers)
        return false;
    if (a.type != b.type)
        return false;
    if (a.dev != b.dev)
        return false;
    return true;
}

pub fn eqchantdqid(a: *const Chan, typ: u16, devno: u32, qid: Qid, skipvers: bool) bool {
    if (a.qid.path != qid.path)
        return false;
    if (!skipvers and a.qid.vers != qid.vers)
        return false;
    if (a.type != typ)
        return false;
    if (a.dev != devno)
        return false;
    return true;
}

pub fn newmhead(from: *Chan) Error!*Mhead {
    const mh = alloc.new(Mhead) orelse return error.Enomem;
    mh.* = .{ .from = from };
    mh.ref.ref = 1;
    _ = incref(&from.ref);
    return mh;
}

/// This is necessary because there are many
/// pointers to the top of a given mount list:
///
///  - the mhead in the namespace hash table
///  - the mhead in chans returned from findmount:
///    used in namec and then by unionread.
///  - the mhead in chans returned from createdir:
///    used in the open/create race protect, which is gone.
///
/// The RWLock in the Mhead protects the mount list it contains.
/// The mount list is deleted in cunmount() and closepgrp().
/// The RWLock ensures that nothing is using the mount list at that time.
///
/// It is okay to replace c->mh with whatever you want as
/// long as you are sure you have a unique reference to it.
///
/// This comment might belong somewhere else.
pub fn putmhead(m_: ?*Mhead) void {
    const m = m_ orelse return;
    if (decref(&m.ref) != 0)
        return;
    if (m.mount != null) panic("putmhead: mount list not empty", .{});
    cclose(m.from);
    alloc.free(m);
}

pub fn cmount(new: *Chan, old: *Chan, flag: u32, spec: ?[]const u8) Error!void {
    if (old.umh != null)
        print("cmount: unexpected umh, caller %#p\n", .{@returnAddress()});

    if (QTDIR & (old.qid.type ^ new.qid.type) != 0)
        return error.Emount;

    const order = flag & lib.MORDER;
    if (old.qid.type & QTDIR == 0 and order != lib.MREPL)
        return error.Emount;

    const nm = try pgrp.newmount(new, flag, spec);
    if (new.umh) |mh| {
        ql.rlock(&mh.lock);
        if (mh.mount) |um| {
            // Not allowed to bind when the old directory is itself a union.
            // (Maybe it should be allowed, but I don't see what the semantics
            // would be.)
            //
            // We need to check mh->mount->next to tell unions apart from
            // simple mount points, so that things like
            //  mount -c fd /root
            //  bind -c /root /
            // work.
            //
            // The check of mount->mflag allows things like
            //  mount fd /root
            //  bind -c /root /
            //
            // This is far more complicated than it should be, but I don't
            // see an easier way at the moment.
            if (flag & lib.MCREATE != 0 and (um.next != null or um.mflag & lib.MCREATE == 0)) {
                ql.runlock(&mh.lock);
                pgrp.mountfree(nm);
                return error.Emount;
            }

            // copy a union when binding it onto a directory
            var f = nm;
            var u = um.next;
            while (u) |x| : (u = x.next) {
                const n = pgrp.newmount(x.to, if (order == lib.MREPL) lib.MAFTER else order, x.spec) catch |e| {
                    ql.runlock(&mh.lock);
                    pgrp.mountfree(nm);
                    return e;
                };
                f.next = n;
                f = n;
            }
        }
        ql.runlock(&mh.lock);
    }

    const pg = up().pgrp.?;
    ql.wlock(&pg.ns);
    var l: *?*Mhead = pg.mounth(old.qid);
    while (l.*) |m| : (l = &m.hash) {
        if (eqchan(m.from, old, true))
            break;
    }

    const m = l.* orelse blk: {
        // nothing mounted here yet.  create a mount
        // head and add to the hash table.
        const nmh = newmhead(old) catch |e| {
            ql.wunlock(&pg.ns);
            pgrp.mountfree(nm);
            return e;
        };

        // if this is a union mount, add the old
        // node to the mount chain.
        if (order != lib.MREPL) {
            const f = pgrp.newmount(old, 0, null) catch |e| {
                putmhead(nmh);
                ql.wunlock(&pg.ns);
                pgrp.mountfree(nm);
                return e;
            };
            f.umh = nmh;
            nmh.mount = f;
            pgrp.pgrpinsert(pg, f);
        }
        l.* = nmh;
        break :blk nmh;
    };

    var f: ?*Mount = nm;
    while (f) |x| : (f = x.next) {
        x.umh = m;
        pgrp.pgrpinsert(pg, x);
    }

    ql.wlock(&m.lock);
    var um = m.mount;
    if (um != null and order == lib.MAFTER) {
        var t = um.?;
        while (t.next) |n| t = n;
        t.next = nm;
        um = null;
    } else {
        if (order != lib.MREPL) {
            var t = nm;
            while (t.next) |n| t = n;
            t.next = um;
            um = null;
        }
        m.mount = nm;
    }
    ql.wunlock(&m.lock);

    f = um;
    while (f) |x| : (f = x.next)
        pgrp.pgrpremove(pg, x);

    ql.wunlock(&pg.ns);

    pgrp.mountfree(um);
}

pub fn cunmount(mnt: *Chan, mounted: ?*Chan) Error!void {
    if (mnt.umh != null) // should not happen
        print("cunmount newp extra umh %p has %p\n", .{ mnt, mnt.umh });

    // It _can_ happen that mounted->umh is non-nil,
    // because mounted is the result of namec(Aopen)
    // (see sysfile.c:/^sysunmount).
    // If we open a union directory, it will have a umh.
    // Although surprising, this is okay, since the
    // cclose will take care of freeing the umh.

    const pg = up().pgrp.?;
    ql.wlock(&pg.ns);

    var l: *?*Mhead = pg.mounth(mnt.qid);
    while (l.*) |x| : (l = &x.hash) {
        if (eqchan(x.from, mnt, true))
            break;
    }

    const m = l.* orelse {
        ql.wunlock(&pg.ns);
        return error.Eunmount;
    };

    ql.wlock(&m.lock);
    const target = mounted orelse {
        var f = m.mount;
        while (f) |x| : (f = x.next)
            pgrp.pgrpremove(pg, x);
        f = m.mount;
        m.mount = null;
        l.* = m.hash;
        ql.wunlock(&m.lock);
        ql.wunlock(&pg.ns);
        pgrp.mountfree(f);
        putmhead(m);
        return;
    };

    var p: *?*Mount = &m.mount;
    while (p.*) |f| : (p = &f.next) {
        if (eqchan(f.to, target, true) or
            (f.to.mchan != null and eqchan(f.to.mchan.?, target, true)))
        {
            pgrp.pgrpremove(pg, f);
            p.* = f.next;
            f.next = null;
            if (m.mount == null) {
                l.* = m.hash;
                ql.wunlock(&m.lock);
                ql.wunlock(&pg.ns);
                pgrp.mountfree(f);
                putmhead(m);
                return;
            }
            ql.wunlock(&m.lock);
            ql.wunlock(&pg.ns);
            pgrp.mountfree(f);
            return;
        }
    }
    ql.wunlock(&m.lock);
    ql.wunlock(&pg.ns);
    return error.Eunion;
}

/// A new channel on the same file as c.
pub fn cclone(c: *Chan) Error!*Chan {
    if (c.ref.ref < 1 or c.flag & portdat.CFREE != 0)
        panic("cclone: %#p", .{@returnAddress()});
    const wq = try dev(c).walk(c, null, &.{});
    const nc = wq.clone.?;
    alloc.free(wq);
    nc.path = c.path;
    if (c.path) |p| _ = incref(&p.ref);
    return nc;
}

/// If something is mounted on the file (type, dev, qid), replace *cp
/// with the first thing mounted there and, if asked, *mp with the mount
/// head.
/// also used by sysfile.c:/^mountfix
pub fn findmount(cp: *?*Chan, mp: ?*?*Mhead, typ: u16, devno: u32, qid: Qid) bool {
    const pg = up().pgrp.?;
    ql.rlock(&pg.ns);
    var it = pg.mounth(qid).*;
    while (it) |m| : (it = m.hash) {
        if (eqchantdqid(m.from, typ, devno, qid, true)) {
            if (mp != null)
                _ = incref(&m.ref);
            ql.rlock(&m.lock);
            const to = m.mount.?.to;
            _ = incref(&to.ref);
            ql.runlock(&m.lock);
            ql.runlock(&pg.ns);
            if (mp) |x| {
                putmhead(x.*);
                x.* = m;
            }
            if (cp.*) |old| cclose(old);
            cp.* = to;
            return true;
        }
    }
    ql.runlock(&pg.ns);
    return false;
}

/// Calls findmount but also updates path.
fn domount(cp: **Chan, mp: *?*Mhead, path: ?**Path) bool {
    var c: ?*Chan = cp.*;
    if (!findmount(&c, mp, cp.*.type, cp.*.dev, cp.*.qid))
        return false;
    cp.* = c.?;

    if (path) |pp| {
        const p = uniquepath(pp.*);
        if (p.mlen == 0)
            print("domount: path %s has mlen==%d\n", .{ p.str(), p.mlen })
        else {
            const from = mp.*.?.from;
            _ = incref(&from.ref);
            const lc = &p.mtpt[p.mlen - 1];
            if (lc.*) |old| cclose(old);
            lc.* = from;
        }
        pp.* = p;
    }
    return true;
}

/// If c is the right-hand-side of a mount point, returns the left hand side.
/// Changes name to reflect the fact that we've uncrossed the mountpoint,
/// so name had better be ours to change!
fn undomount(c: *Chan, path: *Path) *Chan {
    if (path.ref.ref != 1 or path.mlen == 0)
        print("undomount: path %s ref %ld mlen %d caller %#p\n", .{ path.str(), path.ref.ref, path.mlen, @returnAddress() });

    if (path.mlen > 0) {
        if (path.mtpt[path.mlen - 1]) |nc| {
            cclose(c);
            path.mtpt[path.mlen - 1] = null;
            return nc;
        }
    }
    return c;
}

/// Call dev walk.  (The C version exists to catch the error.)
fn ewalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    return dev(c).walk(c, nc, name);
}

/// Either walks all the way or not at all.  No partial results in *cp.
/// *nerror is the number of names to display in an error message.
pub fn walk(cp: **Chan, names: []const []const u8, nomount: bool, nerror: ?*usize) Error!void {
    var c = cp.*;
    _ = incref(&c.ref);
    var path = c.path.?;
    _ = incref(&path.ref);
    var mh: ?*Mhead = null;

    // While we haven't gotten all the way down the path:
    //    1. step through a mount point, if any
    //    2. send a walk request for initial dotdot or initial prefix without dotdot
    //    3. move to the first mountpoint along the way.
    //    4. repeat.
    //
    // Each time through the loop:
    //
    //  If didmount==0, c is on the undomount side of the mount point.
    //  If didmount==1, c is on the domount side of the mount point.
    //  Either way, c's full path is path.
    var didmount = false;
    var nhave: usize = 0;
    while (nhave < names.len) {
        if (c.qid.type & QTDIR == 0) {
            if (nerror) |n| n.* = nhave;
            pathclose(path);
            cclose(c);
            putmhead(mh);
            return error.Enotdir;
        }
        var ntry: usize = @min(names.len - nhave, MAXWELEM);
        var dotdot = false;
        for (0..ntry) |i| {
            if (isdotdot(names[nhave + i])) {
                if (i == 0) {
                    dotdot = true;
                    ntry = 1;
                } else ntry = i;
                break;
            }
        }

        if (!dotdot and !nomount and !didmount)
            _ = domount(&c, &mh, &path);

        var typ = c.type;
        var devno = c.dev;

        const wq: *Walkqid = ewalk(c, null, names[nhave..][0..ntry]) catch |first| blk: {
            var err = first;
            var found: ?*Walkqid = null;
            // try a union mount, if any
            if (mh != null and !nomount) {
                // mh->mount->to == c, so start at mh->mount->next
                ql.rlock(&mh.?.lock);
                var f = if (mh.?.mount) |m| m.next else null;
                while (f) |x| : (f = x.next) {
                    if (ewalk(x.to, null, names[nhave..][0..ntry])) |w| {
                        found = w;
                        typ = x.to.type;
                        devno = x.to.dev;
                        break;
                    } else |e| err = e;
                }
                ql.runlock(&mh.?.lock);
            }
            break :blk found orelse {
                cclose(c);
                pathclose(path);
                if (nerror) |n| n.* = nhave + 1;
                putmhead(mh);
                return err;
            };
        };

        didmount = false;
        var n: usize = undefined;
        var nc: ?*Chan = null;
        var nmh: ?*Mhead = null;
        if (dotdot) {
            if (wq.nqid != 1 or wq.clone == null) panic("walk: bad result for ..", .{});
            path = addelem(path, "..", null);
            nc = undomount(wq.clone.?, path);
            n = 1;
        } else {
            var i: usize = 0;
            if (!nomount) {
                while (i < wq.nqid and i + 1 < ntry) : (i += 1) {
                    if (findmount(&nc, &nmh, typ, devno, wq.qid[i])) {
                        didmount = true;
                        break;
                    }
                }
            }
            if (nc == null) { // no mount points along path
                if (wq.clone == null) {
                    cclose(c);
                    pathclose(path);
                    var err: Error = undefined;
                    if (wq.nqid == 0 or wq.qid[wq.nqid - 1].type & QTDIR != 0) {
                        if (nerror) |ne| ne.* = nhave + wq.nqid + 1;
                        err = error.Enonexist;
                    } else {
                        if (nerror) |ne| ne.* = nhave + wq.nqid;
                        err = error.Enotdir;
                    }
                    alloc.free(wq);
                    putmhead(mh);
                    return err;
                }
                n = wq.nqid;
                nc = wq.clone;
            } else { // stopped early, at a mount point
                if (wq.clone) |cl| {
                    cclose(cl);
                    wq.clone = null;
                }
                n = i + 1;
            }
            for (0..n) |k| {
                const mtpt: ?*Chan = if (k == n - 1 and nmh != null) nmh.?.from else null;
                path = addelem(path, names[nhave + k], mtpt);
            }
        }
        cclose(c);
        c = nc.?;
        putmhead(mh);
        mh = nmh;
        alloc.free(wq);
        nhave += n;
    }
    putmhead(mh);
    // DIFF: the C leaks c and path if this fails.
    c = cunique(c) catch |e| {
        cclose(c);
        pathclose(path);
        return e;
    };
    pathclose(c.path);
    c.path = path;

    cclose(cp.*);
    cp.* = c;
    if (nerror) |ne| ne.* = nhave;
}

/// c is a mounted non-creatable directory.  find a creatable one.
/// Takes c on success; on error the caller still has it.
pub fn createdir(c: *Chan, m: *Mhead) Error!*Chan {
    ql.rlock(&m.lock);
    defer ql.runlock(&m.lock);
    var f = m.mount;
    while (f) |x| : (f = x.next) {
        if (x.mflag & lib.MCREATE != 0) {
            const nc = try cclone(x.to);
            cclose(c);
            return nc;
        }
    }
    return error.Enocreate;
}

/// The name is known to be valid.
/// An empty string will set nelem=0.
/// A path ending in / or /. or /.//./ etc. will have
/// e.mustbedir = 1, so that we correctly
/// reject, e.g., "/adm/users/." when /adm/users is a file
/// rather than a directory.
fn parsename(name: []const u8, e: *Elemlist) void {
    // No more elements than every other byte being a slash.
    e.elems = alloc.snewslice([]const u8, name.len / 2 + 1);
    e.off = alloc.snewslice(usize, name.len / 2 + 2);
    e.nelems = 0;
    var pos = skipslash(name, 0);
    e.off[0] = pos;
    while (true) {
        pos = skipslash(name, pos);
        if (pos == name.len) {
            e.off[e.nelems] = name.len;
            e.mustbedir = true;
            break;
        }
        const slash = std.mem.findScalarPos(u8, name, pos, '/') orelse {
            e.elems[e.nelems] = name[pos..];
            e.nelems += 1;
            e.off[e.nelems] = name.len;
            e.mustbedir = false;
            break;
        };
        e.elems[e.nelems] = name[pos..slash];
        e.nelems += 1;
        e.off[e.nelems] = slash;
        pos = slash + 1;
    }
}

/// Build the error "err: 'name'" for the first `len` bytes of aname,
/// shortened if it would not fit, and return it.
fn namelenerror(aname: []const u8, len_: usize, err: Error) Error {
    const p = up();
    const ERRMAX = portdat.ERRMAX;

    // The text of a run-time error is in up.errstr, which is about to
    // be written; keep it in the other buffer, as the C does.
    if (err == error.Str) proc.swaperr();
    const etext: []const u8 = if (err == error.Str) std.mem.sliceTo(p.syserrstr, 0) else proc.errtext(err);

    var len = len_;
    var name: []const u8 = undefined;
    var dots: []const u8 = "";
    // If the name is short enough, just use the whole thing.
    if (len < ERRMAX / 3 or len + etext.len < 2 * ERRMAX / 3) {
        name = aname[0..len];
    } else {
        // Print a suffix of the name, but try to get a little info.
        const ename = len;
        var next = ename;
        var start = ename;
        while (true) {
            start = next;
            if (next == 0)
                break;
            while (next > 0) {
                next -= 1;
                if (aname[next] == '/')
                    break;
            }
            len = ename - next;
            if (!(len < ERRMAX / 3 or len + etext.len < 2 * ERRMAX / 3))
                break;
        }

        // If the name is ridiculously long, chop it.
        if (start == ename) {
            start = ename - ERRMAX / 4;
            // walk out of current UTF sequence
            var i: usize = 0;
            while (start < ename and aname[start] & 0xC0 == 0x80 and i < lib.UTFmax) : (i += 1)
                start += 1;
        }
        name = aname[start..ename];
        dots = "...";
    }
    const g = fmt.snprint(p.genbuf[0 .. p.genbuf.len - 1], "%s%s", .{ dots, name });
    return proc.errorf("%s: %#q", .{ etext, g });
}

/// Turn a name into a channel.
///
/// Opening with amode Aopen, Acreate, Aremove, or Aaccess guarantees
/// that the result will be the only reference to that particular fid.
/// This is necessary since we might pass the result to
/// devtab[]->remove().
///
/// Opening Atodir or Amount does not guarantee this.
///
/// Under certain circumstances, opening Aaccess will cause
/// an unnecessary clone in order to get a cunique Chan so it
/// can attach the correct name.  Sysstat and sys_stat need the
/// correct name so they can rewrite the stat info.
pub fn namec(aname_: []const u8, amode: u32, omode: u32, perm: u32) Error!*Chan {
    const p = up();
    if (aname_.len == 0)
        return proc.errorf("empty file name", .{});
    const aname = try validnamedup(aname_, true);
    defer alloc.free(aname.ptr);

    var name: []const u8 = aname;

    // Find the starting off point (the current slash, the root of
    // a device tree, or the current dot) as well as the name to
    // evaluate starting there.
    var nomount = false;
    var c: *Chan = undefined;
    switch (name[0]) {
        '/' => {
            c = p.slash.?;
            _ = incref(&c.ref);
        },
        '#' => {
            nomount = true;
            var n: usize = 0;
            while (name.len != 0 and (name[0] != '/' or n < 2)) {
                if (n >= p.genbuf.len - 1)
                    return error.Efilename;
                p.genbuf[n] = name[0];
                n += 1;
                name = name[1..];
            }
            p.genbuf[n] = 0;
            const r = lib.chartorune(p.genbuf[1..n]);
            const speci = r.n + 1;
            const t = devmod.devno(r.r) orelse return error.Ebadsharp;

            // When sandboxing, unmounting a sharp from a union is a valid
            // operation even if the device is blocked.
            // Doing any walks down the device could leak information
            // about the existence of files.
            if ((amode != portdat.Aunmount or speci < n or name.len != 0) and pgrp.devmasked(p.pgrp.?, t))
                return error.Enoattach;
            c = try devmod.devtab[t].attach(p.genbuf[speci..n]);
        },
        else => {
            c = p.dot.?;
            _ = incref(&c.ref);
        },
    }

    var e: Elemlist = .{ .prefix = aname.len - name.len };
    namec1(&c, name, &e, amode, omode, perm, nomount) catch |err| {
        cclose(c);
        alloc.free(e.elems.ptr);

        // Prepare nice error, showing first e.nerror elements of name.
        if (e.nerror == 0) {
            alloc.free(e.off.ptr);
            return err;
        }
        if (e.off[e.nerror] == 0)
            print("nerror=%d but off=%d\n", .{ e.nerror, e.off[e.nerror] });
        const len = e.prefix + e.off[e.nerror];
        alloc.free(e.off.ptr);
        return namelenerror(aname, len, err);
    };

    // place final element in genbuf for e.g. exec
    proc.kstrcpy(&p.genbuf, if (e.nelems > 0) e.elems[e.nelems - 1] else ".");
    alloc.free(e.elems.ptr);
    alloc.free(e.off.ptr);
    return c;
}

/// The part of namec whose errors are reported with the name: on error
/// *cp is still a channel the caller must close.
fn namec1(cp: **Chan, name: []const u8, e: *Elemlist, amode: u32, omode_: u32, perm: u32, nomount: bool) Error!void {
    var omode = omode_;

    // Build a list of elements in the name.
    parsename(name, e);

    // On create, ....
    if (amode == portdat.Acreate) {
        // perm must have DMDIR if last element is / or /.
        if (e.mustbedir and perm & fcall.DMDIR == 0) {
            e.nerror = e.nelems;
            return proc.errorf("create without DMDIR", .{});
        }

        // don't try to walk the last path element just yet.
        if (e.nelems == 0)
            return error.Eexist;
        e.nelems -= 1;
    }

    walk(cp, e.elems[0..e.nelems], nomount, &e.nerror) catch |err| {
        if (e.nerror > e.nelems) {
            print("namec %s walk error nerror=%d\n", .{ name, e.nerror });
            e.nerror = 0;
        }
        return err;
    };

    if (e.mustbedir and cp.*.qid.type & QTDIR == 0)
        return proc.errorf("not a directory", .{});

    if (amode == portdat.Aopen and omode & 3 == lib.OEXEC and cp.*.qid.type & QTDIR != 0)
        return proc.errorf("cannot exec directory", .{});

    switch (amode) {
        portdat.Aunmount, portdat.Abind => {
            // When unmounting, the channel must be opend when not a directory
            // in order to get the real chan from something like /srv/cs or /fd/0.
            if (amode == portdat.Aunmount and cp.*.qid.type & QTDIR == 0)
                return nameopen(cp, amode, omode, nomount);

            // no need to maintain path - cannot dotdot an Abind
            var m: ?*Mhead = null;
            if (!nomount)
                _ = domount(cp, &m, null);
            cp.* = cunique(cp.*) catch |err| {
                putmhead(m);
                return err;
            };
            cp.*.umh = m;
        },

        portdat.Aaccess, portdat.Aremove, portdat.Aopen => return nameopen(cp, amode, omode, nomount),

        portdat.Atodir => {
            // Directories (e.g. for cd) are left before the mount point,
            // so one may mount on / or . and see the effect.
            if (cp.*.qid.type & QTDIR == 0)
                return error.Enotdir;
        },

        portdat.Amount => {
            // When mounting on an already mounted upon directory,
            // one wants subsequent mounts to be attached to the
            // original directory, not the replacement.  Don't domount.
        },

        portdat.Acreate => {
            // We've already walked all but the last element.
            // If the last exists, try to open it OTRUNC.
            // If omode&OEXCL is set, just give up.
            e.nelems += 1;
            e.nerror += 1;
            const last = e.elems[e.nelems - 1 ..][0..1];
            if (walk(cp, last, nomount, null)) |_| {
                if (omode & lib.OEXCL != 0)
                    return error.Eexist;
                omode |= lib.OTRUNC;
                return nameopen(cp, amode, omode, nomount);
            } else |_| {}

            // The semantics of the create(2) system call are that if the
            // file exists and can be written, it is to be opened with truncation.
            // On the other hand, the create(5) message fails if the file exists.
            // If we get two create(2) calls happening simultaneously,
            // they might both get here and send create(5) messages, but only
            // one of the messages will succeed.  To provide the expected create(2)
            // semantics, the call with the failed message needs to try the above
            // walk again, opening for truncation.  This correctly solves the
            // create/create race, in the sense that any observable outcome can
            // be explained as one happening before the other.
            // The create/create race is quite common.  For example, it happens
            // when two rc subshells simultaneously update the same
            // environment variable.
            //
            // The implementation still admits a create/create/remove race:
            // (A) walk to file, fails
            // (B) walk to file, fails
            // (A) create file, succeeds, returns
            // (B) create file, fails
            // (A) remove file, succeeds, returns
            // (B) walk to file, return failure.
            //
            // This is hardly as common as the create/create race, and is really
            // not too much worse than what might happen if (B) got a hold of a
            // file descriptor and then the file was removed -- either way (B) can't do
            // anything with the result of the create call.  So we don't care about this race.
            //
            // Applications that care about more fine-grained decision of the races
            // can use the OEXCL flag to get at the underlying create(5) semantics;
            // by default we provide the common case.
            //
            // We need to stay behind the mount point in case we
            // need to do the first walk again (should the create fail).
            //
            // We also need to cross the mount point and find the directory
            // in the union in which we should be creating.
            //
            // The channel staying behind is c, the one moving forward is cnew.
            var m: ?*Mhead = null;
            var cnew: ?*Chan = null;
            if (trycreate(cp.*, &cnew, &m, last[0], omode, perm, nomount)) |_| {
                const nc = cnew.?;
                if (omode & lib.ORCLOSE != 0)
                    nc.flag |= portdat.CRCLOSE;
                putmhead(m);
                cclose(cp.*);
                cp.* = nc;
                nc.path = addelem(nc.path.?, last[0], null);
            } else |err| {
                // create failed
                if (cnew) |x| cclose(x);
                putmhead(m);
                if (omode & lib.OEXCL != 0)
                    return err;
                // save error
                const saved = err == error.Str;
                if (saved) proc.swaperr();
                // note: we depend that walk does not error
                walk(cp, last, nomount, null) catch {
                    if (saved) proc.swaperr();
                    return err; // report true error
                };
                // restore error
                if (saved) proc.swaperr();
                omode |= lib.OTRUNC;
                return nameopen(cp, amode, omode, nomount);
            }
        },

        else => panic("unknown namec access %d", .{amode}),
    }
}

/// The create itself: find the directory to create in, get a channel of
/// our own on it, and send the create.  *cnew is always what the caller
/// must close if this fails.
fn trycreate(c: *Chan, cnew: *?*Chan, m: *?*Mhead, elem: []const u8, omode: u32, perm: u32, nomount: bool) Error!void {
    if (!nomount and findmount(cnew, m, c.type, c.dev, c.qid)) {
        cnew.* = try createdir(cnew.*.?, m.*.?);
    } else {
        cnew.* = c;
        _ = incref(&c.ref);
    }

    // We need our own copy of the Chan because we're
    // about to send a create, which will move it.  Once we have
    // our own copy, we can fix the name, which might be wrong
    // if findmount gave us a new Chan.
    const nc = try cunique(cnew.*.?);
    cnew.* = nc;
    pathclose(nc.path);
    nc.path = c.path;
    _ = incref(&nc.path.?.ref);

    cnew.* = try dev(nc).create(nc, elem, omode & ~@as(u32, lib.OEXCL | lib.OCEXEC), perm);
}

/// The label Open in the C namec: cross the mount point, take our own
/// copy of the channel, and for the opening modes open it.  On error
/// *cp is still a channel the caller must close.
fn nameopen(cp: **Chan, amode: u32, omode: u32, nomount: bool) Error!void {
    // save&update the name; domount might change c
    var path = cp.*.path.?;
    _ = incref(&path.ref);
    var m: ?*Mhead = null;
    if (!nomount)
        _ = domount(cp, &m, &path);

    // our own copy to open or remove
    const c = cunique(cp.*) catch |err| {
        putmhead(m);
        pathclose(path);
        return err;
    };
    cp.* = c;

    // now it's our copy anyway, we can put the name back
    pathclose(c.path);
    c.path = path;

    // record whether c is on a mount point
    c.ismtpt = m != null;

    switch (amode) {
        portdat.Aaccess, portdat.Aremove => putmhead(m),

        portdat.Aopen, portdat.Acreate, portdat.Aunmount => {
            // only save the mount head if it's a multiple element union
            if (m) |mh| {
                ql.rlock(&mh.lock);
                if (mh.mount != null and mh.mount.?.next != null) {
                    c.umh = mh;
                    ql.runlock(&mh.lock);
                } else {
                    ql.runlock(&mh.lock);
                    putmhead(mh);
                }
            }

            cp.* = try dev(c).open(c, omode & ~@as(u32, lib.OCEXEC));
            if (omode & lib.ORCLOSE != 0)
                cp.*.flag |= portdat.CRCLOSE;
        },
        else => unreachable,
    }
}

/// name is valid. skip leading / and ./ as much as possible
/// DIFF: works on a position in the name.
pub fn skipslash(name: []const u8, pos_: usize) usize {
    var pos = pos_;
    while (pos < name.len and (name[pos] == '/' or (name[pos] == '.' and (pos + 1 == name.len or name[pos + 1] == '/'))))
        pos += 1;
    return pos;
}

/// Characters not allowed in a file name: control characters, slash
/// (unless the caller says so) and DEL.
fn isfrog(c: u8) bool {
    return c < 0x20 or c == '/' or c == 0x7f;
}

/// Check that the name
///  a) is shorter than 2^16 bytes, so it can fit in a 9P string field.
///  b) contains no frogs.
/// The parameter slashok flags whether a slash character is an error
/// or a valid character.
///
/// With `dup`, returns a copy of the name for the caller to free.
fn validname0(aname: []const u8, slashok: bool, dup: bool) Error!?[]u8 {
    if (aname.len >= 1 << 16)
        return error.Etoolong;

    for (aname) |c| {
        // all characters above '~' are ok
        if (c < lib.Runeself and isfrog(c) and (!slashok or c != '/')) {
            const p = up();
            const s = fmt.snprint(p.genbuf[0 .. p.genbuf.len - 1], "%s: %q", .{ proc.errtext(error.Ebadchar), aname });
            return proc.errorf("%s", .{s});
        }
    }
    if (!dup) return null;
    const s = alloc.snewslice(u8, aname.len + 1);
    @memcpy(s[0..aname.len], aname);
    return s[0..aname.len];
}

pub fn validname(aname: []const u8, slashok: bool) Error!void {
    _ = try validname0(aname, slashok, false);
}

pub fn validnamedup(aname: []const u8, slashok: bool) Error![]u8 {
    return (try validname0(aname, slashok, true)).?;
}

pub fn isdir(c: *const Chan) Error!void {
    if (c.qid.type & QTDIR != 0)
        return;
    return error.Enotdir;
}
