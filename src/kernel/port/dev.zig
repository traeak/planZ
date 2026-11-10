//! The device interface and the routines most devices build on.
//! from 9/port/dev.c
//!
//! DIFF:
//!   - Dev has no power or config entries; nothing in a 2011-or-later
//!     configuration uses them.  Entries a device leaves out get the
//!     dev* default at compile time, where the C lists them by hand.
//!   - Entries return Zig errors.  walk returns an error where the C
//!     returns nil.  close can fail too (devmnt's does); cclose ignores it.
//!   - devtab is a slice set at boot from the configuration, not a
//!     nil-terminated array written by a script.
//!   - A Dirtab is passed as one slice (table and length).

const std = @import("std");
const fcall = @import("fcall");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const lib = @import("lib.zig");
const alloc = @import("alloc.zig");
const ab = @import("allocb.zig");
const proc = @import("proc.zig");
const tod = @import("tod.zig");
const chan = @import("chan.zig");
const p9 = @import("print.zig");

const print = p9.print;
const panic = p9.panic;

pub const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Qid = portdat.Qid;
const Dir = portdat.Dir;
const Block = ab.Block;
const QTDIR = fcall.QTDIR;
const DEVDOTDOT = portdat.DEVDOTDOT;

pub const Dev = struct {
    dc: lib.Rune,
    name: []const u8,

    reset: *const fn () void = devreset,
    init: *const fn () void = devinit,
    shutdown: *const fn () void = devshutdown,
    attach: *const fn (spec: []const u8) Error!*Chan,
    walk: *const fn (c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid,
    stat: *const fn (c: *Chan, db: []u8) Error!usize,
    open: *const fn (c: *Chan, omode: u32) Error!*Chan,
    create: *const fn (c: *Chan, name: []const u8, omode: u32, perm: u32) Error!*Chan = devcreate,
    close: *const fn (c: *Chan) Error!void,
    read: *const fn (c: *Chan, buf: []u8, offset: i64) Error!usize,
    bread: *const fn (c: *Chan, n: usize, offset: u64) Error!*Block = devbread,
    write: *const fn (c: *Chan, buf: []const u8, offset: i64) Error!usize,
    bwrite: *const fn (c: *Chan, bp: *Block, offset: u64) Error!usize = devbwrite,
    remove: *const fn (c: *Chan) Error!void = devremove,
    wstat: *const fn (c: *Chan, db: []const u8) Error!usize = devwstat,
};

pub const Dirtab = struct {
    name: []const u8,
    qid: Qid,
    length: i64 = 0,
    perm: u32 = 0,
};

/// Returns 1 and fills in *dp for entry i, 0 to skip it, -1 when there
/// are no more.  See the long comment below.
pub const Devgen = *const fn (c: *Chan, name: ?[]const u8, tab: []const Dirtab, i: i32, dp: *Dir) i32;

/// The devices in this kernel; entry 0 must be the root device.
pub var devtab: []const *const Dev = &.{};

/// Build time of the kernel, the modification time of device files.
pub var kerndate: u32 = 0;

pub fn mkqid(path: u64, vers: u32, typ: u8) Qid {
    return .{ .path = path, .vers = vers, .type = typ };
}

/// The index in devtab of the device with character c.
pub fn devno(c: lib.Rune) ?u16 {
    for (devtab, 0..) |d, i| {
        if (d.dc == c) return @intCast(i);
    }
    return null;
}

pub fn devdir(c: *const Chan, qid_: Qid, n: []const u8, length: i64, user: []const u8, perm: u32, db: *Dir) void {
    var qid = qid_;
    db.name = n;
    if (c.flag & portdat.CMSG != 0)
        qid.type |= fcall.QTMOUNT;
    db.qid = qid;
    db.type = @truncate(devtab[c.type].dc);
    db.dev = c.dev;
    db.mode = perm;
    db.mode |= @as(u32, qid.type) << 24;
    db.atime = @truncate(@as(u64, @bitCast(tod.seconds())));
    db.mtime = kerndate;
    db.length = length;
    db.uid = user;
    db.gid = proc.eve;
    db.muid = user;
}

// (here, Devgen is the prototype; devgen is the function in dev.c.)
//
// a Devgen is expected to return the directory entry for ".."
// if you pass it s==DEVDOTDOT (-1).  otherwise...
//
// there are two contradictory rules.
//
// (i) if c is a directory, a Devgen is expected to list its children
// as you iterate s.
//
// (ii) whether or not c is a directory, a Devgen is expected to list
// its siblings as you iterate s.
//
// devgen always returns the list of children in the root
// directory.  thus it follows (i) when c is the root and (ii) otherwise.
// many other Devgens follow (i) when c is a directory and (ii) otherwise.
//
// devwalk assumes (i).  it knows that devgen breaks (i)
// for children that are themselves directories, and explicitly catches them.
//
// devstat assumes (ii).  if the Devgen in question follows (i)
// for this particular c, devstat will not find the necessary info.
// with our particular Devgen functions, this happens only for
// directories, so devstat makes something up, assuming
// c->name, c->qid, eve, DMDIR|0555.
//
// devdirread assumes (i).  the callers have to make sure
// that the Devgen satisfies (i) for the chan being read.

/// the zeroth element of the table MUST be the directory itself for ..
pub fn devgen(c: *Chan, name: ?[]const u8, tab: []const Dirtab, i_: i32, dp: *Dir) i32 {
    if (tab.len == 0)
        return -1;
    var t: usize = 0;
    if (i_ == DEVDOTDOT) {
        // nothing
    } else if (name) |n| {
        t = 1;
        while (t < tab.len) : (t += 1) {
            if (std.mem.eql(u8, tab[t].name, n))
                break;
        }
        if (t == tab.len)
            return -1;
    } else {
        // skip over the first element, that for . itself
        t = @intCast(i_ + 1);
        if (t >= tab.len)
            return -1;
    }
    devdir(c, tab[t].qid, tab[t].name, tab[t].length, proc.eve, tab[t].perm, dp);
    return 1;
}

pub fn devreset() void {}

pub fn devinit() void {}

pub fn devshutdown() void {}

pub fn devattach(tc: lib.Rune, spec: []const u8) *Chan {
    const c = chan.newchan();
    c.qid = mkqid(0, 0, QTDIR);
    c.type = devno(tc).?;
    const buf = alloc.snewslice(u8, 1 + lib.UTFmax + spec.len + 1);
    c.path = chan.newpath(fmt.snprint(buf, "#%C%s", .{ tc, spec }));
    alloc.free(buf.ptr);
    return c;
}

pub fn devclone(c: *Chan) *Chan {
    if (c.flag & portdat.COPEN != 0)
        panic("clone of open file type %C", .{devtab[c.type].dc});

    const nc = chan.newchan();

    nc.type = c.type;
    nc.dev = c.dev;
    nc.mode = c.mode;
    nc.qid = c.qid;
    nc.offset = c.offset;
    nc.umh = null;
    nc.aux = c.aux;
    nc.mid = c.mid;
    nc.mqid = c.mqid;
    nc.mcp = c.mcp;
    return nc;
}

pub fn devwalk(c: *Chan, nc_: ?*Chan, name: []const []const u8, tab: []const Dirtab, gen: Devgen) Error!*Walkqid {
    if (name.len > 0)
        try chan.isdir(c);

    const alloced = nc_ == null;
    const wq = alloc.snew(Walkqid);
    wq.* = .{};
    const nc = nc_ orelse blk: {
        const n = devclone(c);
        n.type = 0; // device doesn't know about this channel yet
        break :blk n;
    };
    wq.clone = nc;

    var dir: Dir = .{};
    var failed: ?Error = null;
    names: for (name, 0..) |n, j| {
        if (nc.qid.type & QTDIR == 0) {
            if (j == 0) failed = error.Enotdir;
            break :names;
        }
        if (std.mem.eql(u8, n, ".")) {
            wq.qid[wq.nqid] = nc.qid;
            wq.nqid += 1;
            continue;
        }
        if (std.mem.eql(u8, n, "..")) {
            if (gen(nc, null, tab, DEVDOTDOT, &dir) != 1) {
                print("devgen walk .. in dev%s %llux broken\n", .{ devtab[c.type].name, c.qid.path });
                failed = proc.errorf("broken devgen", .{});
                break :names;
            }
            nc.qid = dir.qid;
            wq.qid[wq.nqid] = nc.qid;
            wq.nqid += 1;
            continue;
        }

        // Ugly problem: If we're using devgen, make sure we're
        // walking the directory itself, represented by the first
        // entry in the table, and not trying to step into a sub-
        // directory of the table, e.g. /net/net. Devgen itself
        // should take care of the problem, but it doesn't have
        // the necessary information (that we're doing a walk).
        var found = false;
        if (!(gen == &devgen and nc.qid.path != tab[0].qid.path)) {
            var i: i32 = 0;
            while (true) : (i += 1) {
                const r = gen(nc, n, tab, i, &dir);
                if (r == -1) break;
                if (r == 1 and std.mem.eql(u8, n, dir.name)) {
                    nc.qid = dir.qid;
                    found = true;
                    break;
                }
            }
        }
        if (!found) {
            if (j == 0)
                failed = error.Enonexist
            else
                proc.seterror(error.Enonexist);
            break :names;
        }
        wq.qid[wq.nqid] = nc.qid;
        wq.nqid += 1;
    }

    if (failed) |err| {
        if (alloced) chan.cclose(nc);
        alloc.free(wq);
        return err;
    }

    // We processed at least one name, so will return some data.
    // If we didn't process all nname entries succesfully, we drop
    // the cloned channel and return just the Qids of the walks.
    if (wq.nqid < name.len) {
        if (alloced)
            chan.cclose(nc);
        wq.clone = null;
    } else {
        // attach cloned channel to same device
        nc.type = c.type;
    }
    return wq;
}

pub fn devstat(c: *Chan, db: []u8, tab: []const Dirtab, gen: Devgen) Error!usize {
    var dir: Dir = .{};
    var i: i32 = 0;
    while (true) : (i += 1) {
        switch (gen(c, null, tab, i, &dir)) {
            -1 => {
                if (c.qid.type & QTDIR != 0) {
                    var elem: []const u8 = "???";
                    if (c.path) |p| {
                        const s = p.str();
                        elem = if (std.mem.eql(u8, s, "/"))
                            "/"
                        else if (std.mem.findScalarLast(u8, s, '/')) |k| s[k + 1 ..] else s;
                    }
                    devdir(c, c.qid, elem, 0, proc.eve, 0o555, &dir);
                    const n = fcall.convD2M(&dir, db);
                    if (n == 0)
                        return error.Ebadarg;
                    return n;
                }
                return error.Enonexist;
            },
            1 => if (c.qid.path == dir.qid.path) {
                if (c.flag & portdat.CMSG != 0)
                    dir.mode |= fcall.DMMOUNT;
                const n = fcall.convD2M(&dir, db);
                if (n == 0)
                    return error.Ebadarg;
                return n;
            },
            else => {},
        }
    }
}

pub fn devdirread(c: *Chan, d: []u8, tab: []const Dirtab, gen: Devgen) Error!usize {
    var dir: Dir = .{};
    var m: usize = 0;
    while (m < d.len) : (c.dri += 1) {
        switch (gen(c, null, tab, c.dri, &dir)) {
            -1 => return m,
            1 => {
                const dsz = fcall.convD2M(&dir, d[m..]);
                if (dsz <= fcall.BIT16SZ) { // <= not < because this isn't stat; read is stuck
                    if (m == 0)
                        return error.Eshort;
                    return m;
                }
                m += dsz;
            },
            else => {},
        }
    }
    return m;
}

/// error(Eperm) if open permission not granted for up->user.
pub fn devpermcheck(fileuid: []const u8, perm_: u32, omode: u32) Error!void {
    const access = [_]u32{ 0o400, 0o200, 0o600, 0o100 };
    const user = arch.up().?.user;
    var perm = perm_;
    if (std.mem.eql(u8, user, fileuid))
        perm <<= 0
    else if (std.mem.eql(u8, user, proc.eve))
        perm <<= 3
    else
        perm <<= 6;

    const t = access[omode & 3];
    if (t & perm != t)
        return error.Eperm;
}

pub fn devopen(c: *Chan, omode: u32, tab: []const Dirtab, gen: Devgen) Error!*Chan {
    var dir: Dir = .{};
    var i: i32 = 0;
    while (true) : (i += 1) {
        const r = gen(c, null, tab, i, &dir);
        if (r == -1) break;
        if (r == 1 and c.qid.path == dir.qid.path) {
            try devpermcheck(dir.uid, dir.mode, omode);
            break;
        }
    }
    c.offset = 0;
    if (c.qid.type & QTDIR != 0 and omode != lib.OREAD)
        return error.Eperm;
    c.mode = @intCast(try openmode(omode));
    c.flag |= portdat.COPEN;
    return c;
}

/// The access mode in an open mode, with OEXEC read as OREAD.
/// from 9/port/sysfile.c
pub fn openmode(o_: u32) Error!u32 {
    const o = o_ & ~@as(u32, lib.OTRUNC | lib.OCEXEC | lib.ORCLOSE);
    if (o > lib.OEXEC)
        return error.Ebadarg;
    if (o == lib.OEXEC)
        return lib.OREAD;
    return o;
}

pub fn devcreate(_: *Chan, _: []const u8, _: u32, _: u32) Error!*Chan {
    return error.Eperm;
}

pub fn devbread(c: *Chan, n: usize, offset: u64) Error!*Block {
    const bp = ab.allocb(n);
    errdefer ab.freeb(bp);
    bp.wp += try devtab[c.type].read(c, bp.wp[0..n], @bitCast(offset));
    return bp;
}

pub fn devbwrite(c: *Chan, bp: *Block, offset: u64) Error!usize {
    defer ab.freeb(bp);
    return devtab[c.type].write(c, bp.rp[0..ab.BLEN(bp)], @bitCast(offset));
}

pub fn devremove(_: *Chan) Error!void {
    return error.Eperm;
}

pub fn devwstat(_: *Chan, _: []const u8) Error!usize {
    return error.Eperm;
}
