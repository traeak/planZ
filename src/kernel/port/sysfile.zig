//! The file system calls: file descriptors, open, read, write, seek,
//! stat, bind, mount and the rewriting of directory reads to show the
//! name space.
//! from 9/port/sysfile.c
//!
//! DIFF:
//!   - A handler takes *Sargs and returns Error!usize where the C takes
//!     a va_list and raises errors with error().  Each waserror site is
//!     a defer or errdefer.
//!   - User addresses arrive as usize and become slices through
//!     fault.userslice and fault.userstr; a file name is not copied
//!     here, since namec and validnamedup copy it.
//!   - openmode is in dev.zig, which needed it first.
//!   - Buffers are slices and the directory-entry code (dirfixed,
//!     dirname, dirsetname, mountrock, mountrockread, mountfix) works
//!     with indices into them where the C moves pointers.  It also
//!     checks the lengths found in directory entries against the buffer,
//!     which the C takes on trust: a slice index out of range would be
//!     a kernel panic here, and the data can come from a file server.
//!     A malformed entry is treated as "too short" (see each function).
//!   - dirname returns the name as a slice, or null if the entry is too
//!     short to hold one.
//!   - Chan.dirrock is a slice whose length is mrock in the C.
//!   - Mount.to is never nil, so unionread does not test it.
//!   - Arithmetic on file offsets wraps instead of trapping, since the
//!     values are the user's.
//!   - fdclose ignores a negative fd, which the C would use as an index.
//!   - legacy: sys_read, sys_write, sysoseek, sys_mount, sys_stat and
//!     sys_fstat fail the way the C's own sys_wstat and sys_fwstat do
//!     ("old ... system call - recompile"); packoldstat is gone with
//!     them.
//!   - wstat on a mount point reports "is a mount point: 'path'" with a
//!     plain errorf; chan.namelenerror, which shortens a long path
//!     nicely, is private to chan.zig.
//!   - dirchanstat (9/port/chan.c) is private here until chan.zig has
//!     it; it keeps the strings in a second area after the stat buffer
//!     where the C converts in place.
//!   - evenaddr is an architecture hook that arch.zig does not have yet;
//!     it does nothing on amd64.  The two call sites are marked.
//!   - mount cache: this version of sysfile.c makes no cache.c calls, so
//!     there is nothing to leave out.

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
const pgrp = @import("pgrp.zig");
const fault = @import("fault.zig");
const devcons = @import("devcons.zig");
const devmnt = @import("devmnt.zig");
const p9 = @import("print.zig");

const print = p9.print;
const lock = taslock.lock;
const unlock = taslock.unlock;
const incref = portdat.incref;
const cclose = chan.cclose;
const namec = chan.namec;
const openmode = devmod.openmode;
const validaddr = fault.validaddr;
const userslice = fault.userslice;
const userstr = fault.userstr;
const userstrn = fault.userstrn;

pub const Error = proc.Error;
const Sargs = portdat.Sargs;
const Chan = portdat.Chan;
const Path = portdat.Path;
const Fgrp = portdat.Fgrp;
const Mhead = portdat.Mhead;
const Mount = portdat.Mount;
const Proc = portdat.Proc;
const Dir = portdat.Dir;

const DELTAFD = portdat.DELTAFD;
const QTDIR = fcall.QTDIR;
const BIT8SZ = fcall.BIT8SZ;
const BIT16SZ = fcall.BIT16SZ;
const BIT32SZ = fcall.BIT32SZ;
const BIT64SZ = fcall.BIT64SZ;
const STATFIXLEN = fcall.STATFIXLEN;
const GBIT8 = fcall.GBIT8;
const GBIT16 = fcall.GBIT16;
const GBIT32 = fcall.GBIT32;
const GBIT64 = fcall.GBIT64;
const PBIT16 = fcall.PBIT16;

fn up() *Proc {
    return arch.up().?;
}

fn dev(c: *const Chan) *const devmod.Dev {
    return devmod.devtab[c.type];
}

// The sys*() routines needn't poperror() as they return directly to syscall().

fn unlockfgrp(f: *Fgrp) void {
    const ex = f.exceed;
    f.exceed = 0;
    unlock(&f.lock);
    if (ex != 0)
        _ = devcons.pprint("warning: process exceeds %d file descriptors\n", .{ex});
}

fn growfd(f: *Fgrp, fd: i32) i32 { // fd is always >= 0
    const nfd: i32 = @intCast(f.fd.len);
    if (fd < nfd)
        return 0;
    if (fd >= nfd + DELTAFD)
        return -1; // out of range
    // Unbounded allocation is unwise; besides, there are only 16 bits
    // of fid in 9P
    if (nfd >= 5000) {
        print("no free file descriptors\n", .{});
        return -1;
    }
    const oldfd = f.fd;
    const oldflag = f.flag;
    const n: usize = @intCast(nfd + DELTAFD);
    const newfd_ = alloc.newslice(?*Chan, n);
    const newflag_ = alloc.newslice(u8, n);
    if (newfd_ == null or newflag_ == null) {
        if (newflag_) |x| alloc.free(x.ptr);
        if (newfd_) |x| alloc.free(x.ptr);
        print("no free file descriptors\n", .{});
        return -1;
    }
    const nfds = newfd_.?;
    const nflags = newflag_.?;
    @memset(nfds, null);
    @memset(nflags, 0);
    @memcpy(nfds[0..oldfd.len], oldfd);
    @memcpy(nflags[0..oldflag.len], oldflag);
    f.fd = nfds;
    f.flag = nflags;
    if (fd > f.maxfd) {
        if (@divTrunc(fd, 100) > @divTrunc(f.maxfd, 100))
            f.exceed = @divTrunc(fd, 100) * 100;
        f.maxfd = fd;
    }
    if (oldfd.len != 0) alloc.free(oldfd.ptr);
    if (oldflag.len != 0) alloc.free(oldflag.ptr);
    return 1;
}

/// this assumes that the fgrp is locked
fn findfreefd(f: *Fgrp, start: i32) i32 {
    var fd = start;
    while (fd < f.fd.len) : (fd += 1) {
        if (f.fd[@intCast(fd)] == null)
            break;
    }
    if (fd >= f.fd.len and growfd(f, fd) < 0)
        return -1;
    return fd;
}

/// Put c in the lowest free file descriptor of the current process.
/// Returns the descriptor, or -1 if there is none; the caller still
/// owns c then.
pub fn newfd(c: *Chan, mode: u32) i32 {
    const f = up().fgrp.?;
    lock(&f.lock);
    const fd = findfreefd(f, 0);
    if (fd < 0) {
        unlockfgrp(f);
        return -1;
    }
    if (fd > f.maxfd)
        f.maxfd = fd;
    f.fd[@intCast(fd)] = c;

    // per file-descriptor flags
    var flag: u8 = 0;
    if (mode & lib.OCEXEC != 0)
        flag |= portdat.CCEXEC;
    f.flag[@intCast(fd)] = flag;

    unlockfgrp(f);
    return fd;
}

fn newfd2(fd: *[2]i32, c: [2]*Chan) i32 {
    const f = up().fgrp.?;
    lock(&f.lock);
    fd[0] = findfreefd(f, 0);
    if (fd[0] < 0) {
        unlockfgrp(f);
        return -1;
    }
    fd[1] = findfreefd(f, fd[0] + 1);
    if (fd[1] < 0) {
        unlockfgrp(f);
        return -1;
    }
    if (fd[1] > f.maxfd)
        f.maxfd = fd[1];
    f.fd[@intCast(fd[0])] = c[0];
    f.fd[@intCast(fd[1])] = c[1];
    f.flag[@intCast(fd[0])] = 0;
    f.flag[@intCast(fd[1])] = 0;
    unlockfgrp(f);
    return 0;
}

/// The Chan of a file descriptor of the current process, checked
/// against the access mode wanted (mode < 0: any).  With chkmnt a
/// channel that is the message channel of a mount is refused.  With
/// iref the caller gets a reference to it, to cclose.
pub fn fdtochan(fd: i32, mode: i32, chkmnt: bool, iref: bool) Error!*Chan {
    const f = up().fgrp.?;

    lock(&f.lock);
    const c = blk: {
        if (fd >= 0 and fd < f.fd.len) {
            if (f.fd[@intCast(fd)]) |c|
                break :blk c;
        }
        unlock(&f.lock);
        return error.Ebadfd;
    };
    if (iref)
        _ = incref(&c.ref);
    unlock(&f.lock);

    if (chkmnt and c.flag & portdat.CMSG != 0) {
        if (iref)
            cclose(c);
        return error.Ebadusefd;
    }

    if (mode < 0 or c.mode == lib.ORDWR)
        return c;

    if (mode & lib.OTRUNC != 0 and c.mode == lib.OREAD) {
        if (iref)
            cclose(c);
        return error.Ebadusefd;
    }

    if (mode & ~@as(i32, lib.OTRUNC) != c.mode) {
        if (iref)
            cclose(c);
        return error.Ebadusefd;
    }
    return c;
}

// DIFF: openmode is in dev.zig.

pub fn sysfd2path(a: *Sargs) Error!usize {
    const fd = a.next(i32);
    const ubuf = a.next(usize);
    const len = a.next(u32);
    const buf = try userslice(ubuf, len, true);
    const c = try fdtochan(fd, -1, false, true);
    // snprint(buf, len, "%s", chanpath(c)): what fits, then a NUL
    if (buf.len > 0) {
        const s = fmt.snprint(buf[0 .. buf.len - 1], "%s", .{chan.chanpath(c)});
        buf[s.len] = 0;
    }
    cclose(c);
    return 0;
}

pub fn syspipe(a: *Sargs) Error!usize {
    var fd: [2]i32 = undefined;

    const uaddr = a.next(usize);
    const ubuf = try userslice(uaddr, @sizeOf([2]i32), true);
    // M4: evenaddr(uaddr), an arch hook that does nothing on amd64
    const ufd: *align(1) [2]i32 = @ptrCast(ubuf.ptr);

    fd[0] = -1;
    fd[1] = -1;
    ufd[0] = -1;
    ufd[1] = -1;
    var c0 = try namec("#|", portdat.Atodir, 0, 0);
    var c1_: ?*Chan = null;
    errdefer {
        cclose(c0);
        if (c1_) |x| cclose(x);
    }
    var c1 = try chan.cclone(c0);
    c1_ = c1;
    chan.walk(&c0, &.{"data"}, true, null) catch return error.Egreg;
    chan.walk(&c1, &.{"data1"}, true, null) catch return error.Egreg;
    c1_ = c1;
    c0 = try dev(c0).open(c0, lib.ORDWR);
    c1 = try dev(c1).open(c1, lib.ORDWR);
    c1_ = c1;
    if (newfd2(&fd, .{ c0, c1 }) < 0)
        return error.Enofd;
    ufd[0] = fd[0];
    ufd[1] = fd[1];
    return 0;
}

pub fn sysdup(a: *Sargs) Error!usize {
    const f = up().fgrp.?;

    var fd = a.next(i32);

    // Close after dup'ing, so date > #d/1 works
    const c = try fdtochan(fd, -1, false, true);
    fd = a.next(i32);
    if (fd != -1) {
        lock(&f.lock);
        if (fd < 0 or growfd(f, fd) < 0) {
            unlockfgrp(f);
            cclose(c);
            return error.Ebadfd;
        }
        if (fd > f.maxfd)
            f.maxfd = fd;

        const oc = f.fd[@intCast(fd)];
        f.fd[@intCast(fd)] = c;
        f.flag[@intCast(fd)] = 0;
        unlockfgrp(f);
        if (oc) |x|
            cclose(x);
    } else {
        errdefer cclose(c);
        fd = newfd(c, 0);
        if (fd < 0)
            return error.Enofd;
    }
    return @intCast(fd);
}

pub fn sysopen(a: *Sargs) Error!usize {
    const uname = a.next(usize);
    const mode = a.next(u32);
    _ = try openmode(mode); // error check only
    return open(try userstr(uname), mode);
}

/// DIFF (new): planZ's open(name, namelen, mode).
pub fn sysopenn(a: *Sargs) Error!usize {
    const uname = a.next(usize);
    const unamelen = a.next(usize);
    const mode = a.next(u32);
    _ = try openmode(mode); // error check only
    return open(try userstrn(uname, unamelen), mode);
}

fn open(name: []const u8, mode: u32) Error!usize {
    const c = try namec(name, portdat.Aopen, mode, 0);
    errdefer cclose(c);
    const fd = newfd(c, mode);
    if (fd < 0)
        return error.Enofd;
    return @intCast(fd);
}

/// Close file descriptor fd of the current process.  With a non-zero
/// flag, only if the descriptor or its channel has one of those flags.
pub fn fdclose(fd_: i32, flag: u32) void {
    const f = up().fgrp.?;
    var fd = fd_;

    lock(&f.lock);
    // DIFF: a negative fd is ignored
    const c: ?*Chan = if (fd >= 0 and fd <= f.maxfd) f.fd[@intCast(fd)] else null;
    if (c == null or (flag != 0 and (f.flag[@intCast(fd)] | c.?.flag) & flag == 0)) {
        unlock(&f.lock);
        return;
    }
    f.fd[@intCast(fd)] = null;
    if (fd == f.maxfd) {
        while (fd > 0 and f.fd[@intCast(fd)] == null) {
            fd -= 1;
            f.maxfd = fd;
        }
    }
    unlock(&f.lock);
    cclose(c.?);
}

pub fn sysclose(a: *Sargs) Error!usize {
    const fd = a.next(i32);
    _ = try fdtochan(fd, -1, false, false);
    fdclose(fd, 0);
    return 0;
}

/// Read a union directory: each member in turn, remembering in c.uri
/// and c.umc where the reading has got to.
pub fn unionread(c: *Chan, va: []u8) Error!usize {
    try ql.eqlock(&c.umqlock);
    const m = c.umh.?;
    ql.rlock(&m.lock);
    var mount = m.mount;
    // bring mount in sync with c->uri and c->umc
    var i: i32 = 0;
    while (mount != null and i < c.uri) : (i += 1)
        mount = mount.?.next;

    var nr: usize = 0;
    while (mount) |mt| {
        // Error causes component of union to be skipped
        // DIFF: mt.to cannot be nil
        if (unionread1(c, mt, va)) |n| {
            nr = n;
        } else |_| {}
        if (nr > 0)
            break;

        // Advance to next element
        c.uri += 1;
        if (c.umc) |u| {
            cclose(u);
            c.umc = null;
        }
        mount = mt.next;
    }
    ql.runlock(&m.lock);
    ql.qunlock(&c.umqlock);
    return nr;
}

/// The part of unionread that is under waserror in the C.
fn unionread1(c: *Chan, mount: *Mount, va: []u8) Error!usize {
    if (c.umc == null) {
        const nc = try chan.cclone(mount.to);
        c.umc = nc;
        // if the open fails c.umc is still the clone, as in the C;
        // unionread closes it
        c.umc = try dev(nc).open(nc, lib.OREAD);
    }

    const u = c.umc.?;
    const nr = try dev(u).read(u, va, u.offset);
    u.offset +%= @intCast(nr);
    return nr;
}

fn unionrewind(c: *Chan) Error!void {
    try ql.eqlock(&c.umqlock);
    c.uri = 0;
    if (c.umc) |u| {
        cclose(u);
        c.umc = null;
    }
    ql.qunlock(&c.umqlock);
}

/// Where the name's count is in a directory entry.
const DIRNAMEOFF = BIT16SZ + BIT16SZ + BIT32SZ + BIT8SZ + BIT32SZ + BIT64SZ +
    BIT32SZ + BIT32SZ + BIT32SZ + BIT64SZ;

/// p is from the entry to the end of the data.  Returns the length of
/// the entry, or null if it is longer than the data.
fn dirfixed(p: []const u8, d: *Dir) ?usize {
    const len = @as(usize, GBIT16(p, 0)) + BIT16SZ;
    if (len > p.len)
        return null;
    // DIFF: the C reads the fixed part without looking
    if (p.len < DIRNAMEOFF)
        return null;

    var o: usize = BIT16SZ; // ignore size
    d.type = devmod.devno(GBIT16(p, o)) orelse 0xFFFF;
    o += BIT16SZ;
    d.dev = GBIT32(p, o);
    o += BIT32SZ;
    d.qid.type = GBIT8(p, o);
    o += BIT8SZ;
    d.qid.vers = GBIT32(p, o);
    o += BIT32SZ;
    d.qid.path = GBIT64(p, o);
    o += BIT64SZ;
    d.mode = GBIT32(p, o);
    o += BIT32SZ;
    d.atime = GBIT32(p, o);
    o += BIT32SZ;
    d.mtime = GBIT32(p, o);
    o += BIT32SZ;
    d.length = @bitCast(GBIT64(p, o));

    return len;
}

/// The name in the directory entry p, which starts DIRNAMEOFF+BIT16SZ
/// into it.
/// DIFF: null if p is too short to hold the name.
fn dirname(p: []const u8) ?[]const u8 {
    if (p.len < DIRNAMEOFF + BIT16SZ)
        return null;
    const n: usize = GBIT16(p, DIRNAMEOFF);
    if (DIRNAMEOFF + BIT16SZ + n > p.len)
        return null;
    return p[DIRNAMEOFF + BIT16SZ ..][0..n];
}

/// Replace the name in the directory entry in p[0..n] with `name`.
/// p.len is maxn in the C.  Returns the new length of the entry, or
/// BIT16SZ if it does not fit; the size field then says how much is
/// needed.
fn dirsetname(name: []const u8, p: []u8, n: usize) usize {
    if (n == BIT16SZ)
        return BIT16SZ;

    // DIFF: an entry too short to have a name, or longer than the
    // buffer it is in, is treated like one that does not fit
    if (n > p.len)
        return BIT16SZ;
    const olen = (dirname(p[0..n]) orelse return BIT16SZ).len;
    const oname = DIRNAMEOFF + BIT16SZ;
    const len = name.len;

    const nn = n + len - olen;
    PBIT16(p, 0, @truncate(nn - BIT16SZ));
    if (nn > p.len)
        return BIT16SZ;

    if (len != olen)
        @memmove(p[oname + len ..][0 .. n - (oname + olen)], p[oname + olen .. n]);
    PBIT16(p, oname - 2, @truncate(len));
    @memcpy(p[oname..][0..len], name);
    return nn;
}

fn ROUND(s: usize, sz: usize) usize {
    return (s + sz - 1) & ~(sz - 1);
}

/// Mountfix might have caused the fixed results of the directory read
/// to overflow the buffer.  Catch the overflow in c->dirrock.
/// The data is op[0..pe.*] and p is where an entry starts.
fn mountrock(c: *Chan, op: []const u8, p_: usize, pe: *usize) void {
    const e = pe.*;
    var p = p_;
    var len: usize = undefined;

    // find last directory entry
    while (true) {
        // DIFF: a count that is cut off by the end of the data, or an
        // entry that runs past it, ends at e
        if (p + BIT16SZ > e) {
            len = e - p;
            break;
        }
        len = BIT16SZ + @as(usize, GBIT16(op, p));
        if (p + len >= e) {
            len = e - p;
            break;
        }
        p += len;
    }

    // save it away
    ql.qlock(&c.rockqlock);
    const mrock = if (c.dirrock) |r| r.len else 0;
    if (c.nrock + len > mrock) {
        const n = ROUND(c.nrock + len, 1024);
        const r = alloc.smalloc(n)[0..n];
        if (c.dirrock) |old| {
            @memcpy(r[0..c.nrock], old[0..c.nrock]);
            alloc.free(old.ptr);
        }
        c.dirrock = r;
    }
    @memcpy(c.dirrock.?[c.nrock..][0..len], op[p..][0..len]);
    c.nrock += len;
    ql.qunlock(&c.rockqlock);

    // drop it
    pe.* = p;
}

/// Satisfy a directory read with the results saved in c->dirrock.
fn mountrockread(c: *Chan, op: []u8, nn: *usize) bool {
    // common case
    if (c.nrock == 0)
        return false;

    // copy out what we can
    ql.qlock(&c.rockqlock);
    const rock = c.dirrock.?;
    var rp: usize = 0;
    const erp = c.nrock;
    var p: usize = 0;
    const ep = op.len;
    while (rp + BIT16SZ <= erp) {
        const dirlen = BIT16SZ + @as(usize, GBIT16(rock, rp));
        if (p + dirlen > ep)
            break;
        // DIFF: an entry that runs off the rock cannot be given out;
        // forget what is left
        if (rp + dirlen > erp) {
            rp = erp;
            c.nrock = 0;
            break;
        }
        @memcpy(op[p..][0..dirlen], rock[rp..][0..dirlen]);
        p += dirlen;
        rp += dirlen;
    }

    if (p == 0) {
        ql.qunlock(&c.rockqlock);
        return false;
    }

    // shift the rest
    if (rp != erp)
        @memmove(rock[0 .. erp - rp], rock[rp..erp]);
    c.nrock = erp - rp;

    nn.* = p;
    ql.qunlock(&c.rockqlock);
    return true;
}

fn mountrewind(c: *Chan) void {
    c.nrock = 0;
}

/// The part of mountfix that is under waserror in the C: stat what is
/// mounted, nc, into *buf (allocated or grown as needed) and give the
/// result the name of the entry being replaced.  Returns the length of
/// the new entry.
fn mountfixstat(nc: *Chan, entry: []const u8, buf: *?[]u8) Error!usize {
    // DIFF: an entry without a whole name is not rewritten
    const name = dirname(entry) orelse return error.Eshortstat;
    if (buf.* == null) {
        const nbuf = 4096;
        buf.* = alloc.smalloc(nbuf)[0..nbuf];
    }
    var l = try dev(nc).stat(nc, buf.*.?);
    if (l < BIT16SZ)
        return error.Eshortstat;
    const rest = BIT16SZ + @as(usize, GBIT16(buf.*.?, 0)) + name.len;
    if (rest > buf.*.?.len) {
        alloc.free(buf.*.?.ptr);
        buf.* = null;
        buf.* = alloc.smalloc(rest)[0..rest];
        l = try dev(nc).stat(nc, buf.*.?);
    }
    l = dirsetname(name, buf.*.?, l);
    if (l <= BIT16SZ)
        return error.Eshortstat;
    return l;
}

/// Rewrite the results of a directory read to reflect current
/// name space bindings and mounts.  Specifically, replace
/// directory entries for bind and mount points with the results
/// of statting what is mounted there.  Except leave the old names.
/// The data is op[0..n] and op.len is maxn in the C.
fn mountfix(c: *Chan, op: []u8, n: usize) Error!usize {
    const maxn = op.len;
    var d: Dir = .{};

    var p: usize = 0;
    var buf: ?[]u8 = null;
    defer if (buf) |b| alloc.free(b.ptr);
    var e: usize = n;
    var dirlen: usize = undefined;
    while (p + BIT16SZ < e) : (p += dirlen) {
        dirlen = dirfixed(op[p..e], &d) orelse break;
        var nc: ?*Chan = null;
        var mh: ?*Mhead = null;
        if (chan.findmount(&nc, &mh, d.type, d.dev, d.qid)) {
            rewrite: {
                // If it's a union directory and the original is
                // in the union, don't rewrite anything.
                ql.rlock(&mh.?.lock);
                var m = mh.?.mount;
                while (m) |x| : (m = x.next) {
                    if (chan.eqchantdqid(x.to, d.type, d.dev, d.qid, true)) {
                        ql.runlock(&mh.?.lock);
                        break :rewrite;
                    }
                }
                ql.runlock(&mh.?.lock);

                const l = mountfixstat(nc.?, op[p..][0..dirlen], &buf) catch break :rewrite;

                // Shift data in buffer to accomodate new entry,
                // possibly overflowing into rock.
                var rest = e - (p + dirlen);
                if (l > dirlen) {
                    while (p + l + rest > maxn) {
                        mountrock(c, op, p, &e);
                        if (e == p) {
                            dirlen = 0;
                            break :rewrite;
                        }
                        rest = e - (p + dirlen);
                    }
                }
                if (l != dirlen) {
                    @memmove(op[p + l ..][0..rest], op[p + dirlen ..][0..rest]);
                    dirlen = l;
                    e = p + dirlen + rest;
                }

                // Rewrite directory entry.
                @memcpy(op[p..][0..l], buf.?[0..l]);
            }
            // Norewrite:
            cclose(nc.?);
            chan.putmhead(mh);
        }
    }

    if (p != e)
        return proc.errorf("oops in rockfix", .{});

    return e;
}

/// A long from the user as a length: a negative one becomes a length
/// that no address range has, as the C's conversion to ulong makes it.
fn ulen(n: i32) usize {
    return @bitCast(@as(isize, n));
}

fn read(fd: i32, ubuf: usize, n: usize, offp: ?i64) Error!usize {
    const p = try userslice(ubuf, n, true);
    const c = try fdtochan(fd, lib.OREAD, true, true);
    defer cclose(c);

    // The offset is passed through on directories, normally.
    // Sysseek complains, but pread is used by servers like exportfs,
    // that shouldn't need to worry about this issue.
    //
    // Notice that c->devoffset is the offset that c's dev is seeing.
    // The number of bytes read on this fd (c->offset) may be different
    // due to rewritings in rockfix.
    const off: i64 = offp orelse c.offset; // nil: use and maintain channel's offset
    if (off < 0)
        return error.Enegoff;

    if (off == 0) { // rewind to the beginning of the directory
        if (offp == null or c.qid.type & QTDIR != 0) {
            c.offset = 0;
            c.devoffset = 0;
        }
        mountrewind(c);
        try unionrewind(c);
    }

    var nn: usize = 0;
    var nnn: usize = 0;
    if (c.qid.type & QTDIR != 0) {
        if (mountrockread(c, p, &nn)) {
            // do nothing: mountrockread filled buffer
        } else if (c.umh != null) {
            nn = try unionread(c, p);
        } else {
            if (off != c.offset)
                return error.Edirseek;
            nn = try dev(c).read(c, p, c.devoffset);
        }
        nnn = try mountfix(c, p, nn);
    } else {
        nn = try dev(c).read(c, p, off);
        nnn = nn;
    }

    if (offp == null or c.qid.type & QTDIR != 0) {
        lock(&c.lock);
        c.devoffset +%= @intCast(nn);
        c.offset +%= @intCast(nnn);
        unlock(&c.lock);
    }

    return nnn;
}

pub fn sys_read(_: *Sargs) Error!usize {
    // DIFF: legacy
    return proc.errorf("old read system call - recompile", .{});
}

pub fn syspread(a: *Sargs) Error!usize {
    const fd = a.next(i32);
    const buf = a.next(usize);
    const len = a.next(i32);
    const off = a.next(i64);
    const offp: ?i64 = if (off != -1) off else null; // ~0ULL
    return read(fd, buf, ulen(len), offp);
}

fn write(fd: i32, ubuf: usize, len: usize, offp: ?i64) Error!usize {
    const buf = try userslice(ubuf, len, false);
    var n: i64 = 0;
    const c = try fdtochan(fd, lib.OWRITE, true, true);
    defer cclose(c);
    errdefer if (offp == null) {
        lock(&c.lock);
        c.offset -%= n;
        unlock(&c.lock);
    };

    if (c.qid.type & QTDIR != 0)
        return error.Eisdir;

    n = @intCast(len);

    var off: i64 = undefined;
    if (offp) |o| {
        off = o;
    } else { // use and maintain channel's offset
        lock(&c.lock);
        off = c.offset;
        c.offset +%= n;
        unlock(&c.lock);
    }

    if (off < 0)
        return error.Enegoff;

    const m = try dev(c).write(c, buf, off);
    if (offp == null and m < len) {
        lock(&c.lock);
        c.offset -%= n - @as(i64, @intCast(m));
        unlock(&c.lock);
    }

    return m;
}

pub fn sys_write(_: *Sargs) Error!usize {
    // DIFF: legacy
    return proc.errorf("old write system call - recompile", .{});
}

pub fn syspwrite(a: *Sargs) Error!usize {
    const fd = a.next(i32);
    const buf = a.next(usize);
    const len = a.next(i32);
    const off = a.next(i64);
    const offp: ?i64 = if (off != -1) off else null; // ~0ULL
    return write(fd, buf, ulen(len), offp);
}

fn sseek(fd: i32, o: i64, typ: i32) Error!i64 {
    var off: i64 = undefined;

    const c = try fdtochan(fd, -1, true, true);
    defer cclose(c);
    if (dev(c).dc == '|')
        return error.Eisstream;

    switch (typ) {
        0 => {
            off = o;
            if (c.qid.type & QTDIR != 0 and off != 0)
                return error.Eisdir;
            if (off < 0)
                return error.Enegoff;
            c.offset = off;
        },

        1 => {
            if (c.qid.type & QTDIR != 0)
                return error.Eisdir;
            lock(&c.lock); // lock for read/write update
            off = o +% c.offset;
            if (off < 0) {
                unlock(&c.lock);
                return error.Enegoff;
            }
            c.offset = off;
            unlock(&c.lock);
        },

        2 => {
            if (c.qid.type & QTDIR != 0)
                return error.Eisdir;
            const d = try dirchanstat(c);
            off = d.length +% o;
            alloc.free(d);
            if (off < 0)
                return error.Enegoff;
            c.offset = off;
        },

        else => return error.Ebadarg,
    }
    c.uri = 0;
    c.dri = 0;
    return off;
}

pub fn sysseek(a: *Sargs) Error!usize {
    const uv = a.next(usize);
    // M4: evenaddr(uv), an arch hook that does nothing on amd64
    const v: *align(1) i64 = @ptrCast((try userslice(uv, @sizeOf(i64), true)).ptr);

    const fd = a.next(i32);
    const n = a.next(i64);
    const t = a.next(i32);

    v.* = try sseek(fd, n, t);

    return 0;
}

pub fn sysoseek(_: *Sargs) Error!usize {
    // DIFF: legacy
    return proc.errorf("old seek system call - recompile", .{});
}

/// Check that s is one well-formed stat buffer with an acceptable name.
pub fn validstat(s: []const u8) Error!void {
    var buf: [64]u8 = undefined;

    if (fcall.statcheck(s) < 0)
        return error.Ebadstat;
    // verify that name entry is acceptable
    var p: usize = STATFIXLEN - 4 * BIT16SZ; // location of first string
    // s now points at count for first string.
    // if it's too long, let the server decide; this is
    // only for his protection anyway. otherwise
    // we'd have to allocate and waserror.
    const m: usize = GBIT16(s, p);
    p += BIT16SZ;
    if (m + 1 > buf.len)
        return;
    @memcpy(buf[0..m], s[p..][0..m]);
    // the C makes a string of it, so it ends at the first NUL
    const name = std.mem.sliceTo(buf[0..m], 0);
    // name could be '/'
    if (!std.mem.eql(u8, name, "/"))
        try chan.validname(name, false);
}

fn pathlast(p_: ?*Path) ?[]const u8 {
    const p = p_ orelse return null;
    if (p.len == 0)
        return null;
    const s = p.str();
    if (std.mem.findScalarLast(u8, s, '/')) |i|
        return s[i + 1 ..];
    return s;
}

pub fn sysfstat(a: *Sargs) Error!usize {
    const fd = a.next(i32);
    const us = a.next(usize);
    const l = a.next(u32);
    const s = try userslice(us, l, true);
    const c = try fdtochan(fd, -1, false, true);
    defer cclose(c);
    var r = try dev(c).stat(c, s);
    if (pathlast(c.path)) |name|
        r = dirsetname(name, s, r);
    return r;
}

pub fn sysstat(a: *Sargs) Error!usize {
    const uname = a.next(usize);
    const us = a.next(usize);
    const l = a.next(u32);
    const s = try userslice(us, l, true);
    return stat(try userstr(uname), s);
}

/// DIFF (new): planZ's stat(name, namelen, buf, len).
pub fn sysstatn(a: *Sargs) Error!usize {
    const uname = a.next(usize);
    const unamelen = a.next(usize);
    const us = a.next(usize);
    const l = a.next(u32);
    const s = try userslice(us, l, true);
    return stat(try userstrn(uname, unamelen), s);
}

fn stat(aname: []const u8, s: []u8) Error!usize {
    const c = try namec(aname, portdat.Aaccess, 0, 0);
    defer cclose(c);
    var r = try dev(c).stat(c, s);
    if (pathlast(c.path)) |name|
        r = dirsetname(name, s, r);
    return r;
}

pub fn syschdir(a: *Sargs) Error!usize {
    return chdir(try userstr(a.next(usize)));
}

/// DIFF (new): planZ's chdir(name, namelen).
pub fn syschdirn(a: *Sargs) Error!usize {
    const uname = a.next(usize);
    return chdir(try userstrn(uname, a.next(usize)));
}

fn chdir(name: []const u8) Error!usize {
    const c = try namec(name, portdat.Atodir, 0, 0);
    const p = up();
    cclose(p.dot.?);
    p.dot = c;
    return 0;
}

/// DIFF: the strings arrive as Ustr, which is either a 0-terminated
/// string's address (9front's calls) or an (address, length) pair
/// (planZ's), and are read only where the C reads them.
const Ustr = struct {
    addr: usize,
    len: ?usize = null,

    fn get(u: Ustr) Error![]const u8 {
        return if (u.len) |n| userstrn(u.addr, n) else userstr(u.addr);
    }
};

fn bindmount(ismount: bool, fd: i32, afd: i32, arg0: Ustr, arg1: Ustr, flag: u32, uspec: Ustr) Error!usize {
    if (flag & ~@as(u32, lib.MMASK) != 0 or flag & lib.MORDER == (lib.MBEFORE | lib.MAFTER))
        return error.Ebadarg;

    var spec: ?[]u8 = null;
    defer if (spec) |s| alloc.free(s.ptr);

    const c0: *Chan = if (ismount) blk: {
        if (!pgrp.canmount(up().pgrp.?))
            return error.Enoattach;

        spec = try chan.validnamedup(try uspec.get(), true);
        const bc = try fdtochan(fd, lib.ORDWR, false, true);
        defer cclose(bc);
        var ac: ?*Chan = null;
        if (afd >= 0)
            ac = try fdtochan(afd, lib.ORDWR, false, true);
        defer if (ac) |x| cclose(x);
        break :blk try devmnt.mntattach(bc, ac, spec.?, flag & lib.MCACHE);
    } else try namec(try arg0.get(), portdat.Abind, 0, 0);
    {
        defer cclose(c0);
        const c1 = try namec(try arg1.get(), portdat.Amount, 0, 0);
        defer cclose(c1);
        try chan.cmount(c0, c1, flag, spec);
    }
    if (ismount)
        fdclose(fd, 0);
    // DIFF: cmount returns nothing; the C's always returns 0
    return 0;
}

pub fn sysbind(a: *Sargs) Error!usize {
    const arg0 = a.next(usize);
    const arg1 = a.next(usize);
    const flag = a.next(u32);
    return bindmount(false, -1, -1, .{ .addr = arg0 }, .{ .addr = arg1 }, flag, .{ .addr = 0 });
}

/// DIFF (new): planZ's bind(new, newlen, old, oldlen, flag).
pub fn sysbindn(a: *Sargs) Error!usize {
    const arg0: Ustr = .{ .addr = a.next(usize), .len = a.next(usize) };
    const arg1: Ustr = .{ .addr = a.next(usize), .len = a.next(usize) };
    const flag = a.next(u32);
    return bindmount(false, -1, -1, arg0, arg1, flag, .{ .addr = 0, .len = 0 });
}

pub fn sysmount(a: *Sargs) Error!usize {
    const fd = a.next(i32);
    const afd = a.next(i32);
    const arg1 = a.next(usize);
    const flag = a.next(u32);
    const spec = a.next(usize);
    return bindmount(true, fd, afd, .{ .addr = 0 }, .{ .addr = arg1 }, flag, .{ .addr = spec });
}

/// DIFF (new): planZ's mount(fd, afd, old, oldlen, flag, spec, speclen).
pub fn sysmountn(a: *Sargs) Error!usize {
    const fd = a.next(i32);
    const afd = a.next(i32);
    const arg1: Ustr = .{ .addr = a.next(usize), .len = a.next(usize) };
    const flag = a.next(u32);
    const spec: Ustr = .{ .addr = a.next(usize), .len = a.next(usize) };
    return bindmount(true, fd, afd, .{ .addr = 0, .len = 0 }, arg1, flag, spec);
}

pub fn sys_mount(_: *Sargs) Error!usize {
    // DIFF: legacy
    return proc.errorf("old mount system call - recompile", .{});
}

pub fn sysunmount(a: *Sargs) Error!usize {
    const name = a.next(usize);
    const old = a.next(usize);
    return unmount(if (name == 0) null else .{ .addr = name }, .{ .addr = old });
}

/// DIFF (new): planZ's unmount(name, namelen, old, oldlen); a name of
/// length 0 is none, as a nil name is in 9front's.
pub fn sysunmountn(a: *Sargs) Error!usize {
    const name: Ustr = .{ .addr = a.next(usize), .len = a.next(usize) };
    const old: Ustr = .{ .addr = a.next(usize), .len = a.next(usize) };
    return unmount(if (name.len == 0) null else name, old);
}

fn unmount(name: ?Ustr, old: Ustr) Error!usize {
    const cmount = try namec(try old.get(), portdat.Amount, 0, 0);
    defer cclose(cmount);
    if (name == null) {
        try chan.cunmount(cmount, null);
    } else {
        const cmounted = try namec(try name.?.get(), portdat.Aunmount, lib.OREAD, 0);
        defer cclose(cmounted);
        try chan.cunmount(cmount, cmounted);
    }
    return 0;
}

pub fn syscreate(a: *Sargs) Error!usize {
    const uname = a.next(usize);
    const mode = a.next(u32);
    const perm = a.next(u32);
    _ = try openmode(mode & ~@as(u32, lib.OEXCL)); // error check only; OEXCL okay here
    return create(try userstr(uname), mode, perm);
}

/// DIFF (new): planZ's create(name, namelen, mode, perm).
pub fn syscreaten(a: *Sargs) Error!usize {
    const uname = a.next(usize);
    const unamelen = a.next(usize);
    const mode = a.next(u32);
    const perm = a.next(u32);
    _ = try openmode(mode & ~@as(u32, lib.OEXCL)); // error check only; OEXCL okay here
    return create(try userstrn(uname, unamelen), mode, perm);
}

fn create(name: []const u8, mode: u32, perm: u32) Error!usize {
    const c = try namec(name, portdat.Acreate, mode, perm);
    errdefer cclose(c);
    const fd = newfd(c, mode);
    if (fd < 0)
        return error.Enofd;
    return @intCast(fd);
}

pub fn sysremove(a: *Sargs) Error!usize {
    return remove(try userstr(a.next(usize)));
}

/// DIFF (new): planZ's remove(name, namelen).
pub fn sysremoven(a: *Sargs) Error!usize {
    const uname = a.next(usize);
    return remove(try userstrn(uname, a.next(usize)));
}

fn remove(name: []const u8) Error!usize {
    const c = try namec(name, portdat.Aremove, 0, 0);
    // Removing mount points is disallowed to avoid surprises
    // (which should be removed: the mount point or the mounted Chan?).
    if (c.ismtpt) {
        cclose(c);
        return error.Eismtpt;
    }
    // Remove clunks the fid, but we need to recover the Chan
    // so fake it up.  rootclose() is known to be a nop.
    defer {
        c.type = 0;
        cclose(c);
    }
    try dev(c).remove(c);
    return 0;
}

/// Takes c: it is closed whether or not the wstat works.
fn wstat(c: *Chan, d: []const u8) Error!usize {
    defer cclose(c);
    if (c.ismtpt) {
        // Renaming mount points is disallowed to avoid surprises
        // (which should be renamed? the mount point or the mounted Chan?).
        if (dirname(d)) |name| {
            if (name.len != 0) {
                // M4: this is namelenerror(p, strlen(p), Eismtpt), which
                // is private to chan.zig
                return proc.errorf("%s: %#q", .{ proc.errtext(error.Eismtpt), chan.chanpath(c) });
            }
        }
    }
    return dev(c).wstat(c, d);
}

pub fn syswstat(a: *Sargs) Error!usize {
    const uname = a.next(usize);
    const us = a.next(usize);
    const l = a.next(u32);
    const s = try userslice(us, l, false);
    try validstat(s);
    const c = try namec(try userstr(uname), portdat.Aaccess, 0, 0);
    return wstat(c, s);
}

/// DIFF (new): planZ's wstat(name, namelen, buf, len).
pub fn syswstatn(a: *Sargs) Error!usize {
    const uname = a.next(usize);
    const unamelen = a.next(usize);
    const us = a.next(usize);
    const l = a.next(u32);
    const s = try userslice(us, l, false);
    try validstat(s);
    const c = try namec(try userstrn(uname, unamelen), portdat.Aaccess, 0, 0);
    return wstat(c, s);
}

pub fn sysfwstat(a: *Sargs) Error!usize {
    const fd = a.next(i32);
    const us = a.next(usize);
    const l = a.next(u32);
    const s = try userslice(us, l, false);
    try validstat(s);
    const c = try fdtochan(fd, -1, true, true);
    return wstat(c, s);
}

// DIFF: legacy: no packoldstat.

pub fn sys_stat(_: *Sargs) Error!usize {
    // DIFF: legacy
    return proc.errorf("old stat system call - recompile", .{});
}

pub fn sys_fstat(_: *Sargs) Error!usize {
    // DIFF: legacy
    return proc.errorf("old fstat system call - recompile", .{});
}

pub fn sys_wstat(_: *Sargs) Error!usize {
    return proc.errorf("old wstat system call - recompile", .{});
}

pub fn sys_fwstat(_: *Sargs) Error!usize {
    return proc.errorf("old fwstat system call - recompile", .{});
}

const DIRSIZE = STATFIXLEN + 16 * 4; // enough for encoded stat buf + some reasonable strings

/// Stat c into an allocated Dir, which the caller frees.
/// from 9/port/chan.c
/// DIFF: the allocation is the Dir, the stat buffer, and then as much
/// again for the strings, which the C converts in place.
// M4: move to chan.zig
fn dirchanstat(c: *Chan) Error!*Dir {
    var nd: usize = DIRSIZE;
    for (0..2) |_| { // should work by the second try
        const size = BIT16SZ + nd;
        const mem = alloc.smalloc(@sizeOf(Dir) + 2 * size);
        const d: *Dir = @ptrCast(@alignCast(mem));
        errdefer alloc.free(d);
        d.* = .{};
        const buf = mem[@sizeOf(Dir)..][0..size];
        const strs = mem[@sizeOf(Dir) + size ..][0..size];
        const n = try dev(c).stat(c, buf);
        if (n < BIT16SZ)
            return error.Eshortstat;
        nd = GBIT16(buf, 0); // upper bound on size of Dir + strings
        if (nd <= n) {
            if (fcall.convM2D(buf[0..n], d, strs) == 0)
                return error.Eshortstat;
            return d;
        }
        // else sizeof(Dir)+BIT16SZ+nd is plenty
        alloc.free(d);
    }
    return error.Eshortstat;
}
