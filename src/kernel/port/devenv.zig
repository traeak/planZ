//! The environment device, #e, and the environment groups (Egrp) that
//! processes share or copy at rfork.  #ec is the global group holding
//! the kernel configuration.
//! from 9/port/devenv.c
//!
//! DIFF:
//!   - Errors are Zig error returns; the waserror sites that only
//!     released the group's lock became defer.
//!   - Egrp.ent is a slice whose length is the C's nent, and Evalue.value
//!     a slice whose length is the C's len.  A slice of length zero owns
//!     no memory: that is how the C's nil pointers are told apart.  For
//!     that to hold, envcpy gives the table back when it copied no
//!     variable, where the C keeps an empty table of ROUND(from->nent)
//!     slots.
//!   - envrealloc takes an unsigned size, so its test for a negative one
//!     is gone.
//!   - envread treats a negative offset as end of file and envwrite
//!     answers it with Etoobig, where the C would index before the value.
//!   - envhash hashes bytes as unsigned; the C's char is signed.  Only
//!     the bucket a non-ASCII name lands in differs.
//!   - ksetenv returns the error of namec or of the write, and closes
//!     the channel if the write fails, where the C leaves it open.
//!   - getconfenv returns the bytes it filled in as a slice.
//!   - iseve (9/port/auth.c) is not ported yet and is private here.

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
const devmod = @import("dev.zig");

const incref = portdat.incref;
const decref = portdat.decref;
const rlock = ql.rlock;
const runlock = ql.runlock;
const wlock = ql.wlock;
const wunlock = ql.wunlock;
const devdir = devmod.devdir;
const mkqid = devmod.mkqid;

pub const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Qid = portdat.Qid;
const Dir = portdat.Dir;
const Egrp = portdat.Egrp;
const Evalue = portdat.Evalue;
const Dirtab = devmod.Dirtab;
const QTDIR = fcall.QTDIR;
const QTFILE = fcall.QTFILE;
const DEVDOTDOT = portdat.DEVDOTDOT;
const ENVHASH = portdat.ENVHASH;
const COPEN = portdat.COPEN;
const CRCLOSE = portdat.CRCLOSE;

const Maxenvsize = 1 * portdat.MB;
const Maxvalsize = Maxenvsize / 2;

const DELTAENV = 32;

var confegrp: Egrp = .{}; // global environment group containing the kernel configuration

fn PATH(p: u32, i: usize) u64 {
    return @as(u64, p) << 32 | i;
}

fn QID(quidpath: u64) usize {
    return @as(u32, @truncate(quidpath)) & 0x7FFFFFFF;
}

fn ROUND(s: usize, sz: usize) usize {
    return (s + (sz - 1)) & ~(sz - 1);
}

/// The memory a value owns, or null: what e->value is in the C.
fn valptr(e: *const Evalue) ?*anyopaque {
    return if (e.value.len != 0) e.value.ptr else null;
}

// M3: belongs in auth.zig (9/port/auth.c).
fn iseve() bool {
    return std.mem.eql(u8, proc.eve, arch.up().?.user);
}

fn envindex(eg: *Egrp, qidpath: u64) ?*Evalue {
    const i = QID(qidpath);
    if (i >= eg.ent.len)
        return null;
    const e = eg.ent[i] orelse return null;
    if (e.path != qidpath)
        return null;
    return e;
}

fn envhash(eg: *Egrp, name: []const u8) *?*Evalue {
    var h: u32 = 0;
    for (name) |c|
        h = h *% 131 +% c;
    return &eg.hash[h % ENVHASH];
}

fn lookupname(e_: ?*Evalue, name: []const u8) ?*Evalue {
    var e = e_;
    while (e) |x| : (e = x.hash) {
        if (std.mem.eql(u8, x.name, name))
            break;
    }
    return e;
}

fn envgen(c: *Chan, name: ?[]const u8, _: []const Dirtab, s: i32, dp: *Dir) i32 {
    const up = arch.up().?;

    const eg = envgrp(c);
    if (s == DEVDOTDOT) {
        c.qid.vers = eg.vers;
        devdir(c, c.qid, "#e", 0, proc.eve, 0o775, dp);
        return 1;
    }
    rlock(&eg.lock);
    defer runlock(&eg.lock);
    var e: *Evalue = undefined;
    if (c.qid.type & QTDIR == 0) {
        e = envindex(eg, c.qid.path) orelse return -1;
    } else if (name) |n| {
        if (n.len >= up.genbuf.len)
            return -1;
        e = lookupname(envhash(eg, n).*, n) orelse return -1;
    } else if (s >= 0 and @as(usize, @intCast(s)) < eg.ent.len) {
        e = eg.ent[@intCast(s)] orelse
            return 0; // deleted, try next
    } else {
        return -1;
    }
    // make sure name string continues to exist after we release lock
    proc.kstrcpy(&up.genbuf, e.name);
    const q = mkqid(e.path, e.vers, QTFILE);
    devdir(c, q, up.genbuf[0..@min(e.name.len, up.genbuf.len - 1)], @intCast(e.value.len), proc.eve, if (eg == &confegrp or eg != up.egrp) 0o664 else 0o666, dp);
    return 1;
}

fn envattach(spec: []const u8) Error!*Chan {
    var egrp: ?*Egrp = null;

    if (spec.len != 0) {
        if (!std.mem.eql(u8, spec, "c"))
            return error.Ebadarg;
        egrp = &confegrp;
    }

    const c = devmod.devattach('e', spec);
    c.aux = egrp;
    return c;
}

fn envwalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    return devmod.devwalk(c, nc, name, &.{}, envgen);
}

fn envstat(c: *Chan, db: []u8) Error!usize {
    return devmod.devstat(c, db, &.{}, envgen);
}

/// Resize memory charged to eg; a new size of 0 frees it, returns null
/// and cannot fail.
fn envrealloc(eg: *Egrp, old: ?*anyopaque, newsize: usize) Error!?[*]u8 {
    const oldsize = if (old) |o| alloc.msize(o) else 0;

    if (newsize == 0) {
        eg.alloc -= oldsize;
        alloc.free(old);
        return null;
    }
    if (eg != &confegrp and (eg.alloc + newsize) -% oldsize > Maxenvsize)
        return error.Enomem;
    const new = alloc.realloc(old, newsize) orelse
        return error.Enomem;
    eg.alloc += alloc.msize(new);
    eg.alloc -= oldsize;
    alloc.setmalloctag(new, @returnAddress());
    return new;
}

fn envopen(c: *Chan, omode: u32) Error!*Chan {
    const eg = envgrp(c);
    if (c.qid.type & QTDIR != 0) {
        if (omode != lib.OREAD)
            return error.Eperm;
    } else {
        const trunc = omode & lib.OTRUNC != 0;
        if (omode != lib.OREAD and !envwritable(c))
            return error.Eperm;
        if (trunc)
            wlock(&eg.lock)
        else
            rlock(&eg.lock);
        defer {
            if (trunc)
                wunlock(&eg.lock)
            else
                runlock(&eg.lock);
        }
        const e = envindex(eg, c.qid.path) orelse
            return error.Enonexist;
        if (trunc and e.value.len > 0) {
            _ = envrealloc(eg, valptr(e), 0) catch unreachable; // free
            e.value = &.{};
            e.vers +%= 1;
        }
        c.qid.vers = e.vers;
    }
    c.mode = @intCast(try devmod.openmode(omode));
    _ = incref(&eg.ref);
    c.aux = eg;
    c.offset = 0;
    c.flag |= COPEN;
    return c;
}

fn envcreate(c: *Chan, name: []const u8, omode_: u32, _: u32) Error!*Chan {
    const up = arch.up().?;

    if (c.qid.type != QTDIR or !envwritable(c))
        return error.Eperm;

    const n = name.len + 1;
    if (n > up.genbuf.len)
        return error.Etoolong;

    const omode = try devmod.openmode(omode_);
    const eg = envgrp(c);
    {
        wlock(&eg.lock);
        defer wunlock(&eg.lock);

        const h = envhash(eg, name);
        if (lookupname(h.*, name) != null)
            return error.Eexist;

        var i = eg.low;
        while (i < eg.ent.len) : (i += 1) {
            if (eg.ent[i] == null)
                break;
        }

        if (i >= eg.ent.len) {
            const nent = eg.ent.len;
            if (nent % DELTAENV == 0) {
                const t: [*]?*Evalue = @ptrCast(@alignCast((try envrealloc(eg, if (nent != 0) @ptrCast(eg.ent.ptr) else null, (nent + DELTAENV) * @sizeOf(?*Evalue))).?));
                eg.ent = t[0..nent];
            }
            i = nent;
            eg.ent = eg.ent.ptr[0 .. nent + 1];
            eg.ent[i] = null;
            eg.low = i;
        }

        const b = (try envrealloc(eg, null, @sizeOf(Evalue) + n)).?;
        const e: *Evalue = @ptrCast(@alignCast(b));
        e.* = .{};
        e.name = b[@sizeOf(Evalue)..][0..name.len];
        @memcpy(e.name, name);
        e.name.ptr[name.len] = 0;
        e.value = &.{};
        e.vers = 0;
        eg.path +%= 1;
        e.path = PATH(eg.path, i);
        e.hash = h.*;
        h.* = e;
        eg.ent[i] = e;
        eg.low = i + 1;
        eg.vers +%= 1;
        c.qid = mkqid(e.path, e.vers, QTFILE);
    }
    _ = incref(&eg.ref);
    c.aux = eg;
    c.offset = 0;
    c.mode = @intCast(omode);
    c.flag |= COPEN;
    return c;
}

fn envremove(c: *Chan) Error!void {
    if (c.qid.type & QTDIR != 0 or !envwritable(c))
        return error.Eperm;

    const eg = envgrp(c);
    wlock(&eg.lock);
    defer wunlock(&eg.lock);
    const e = envindex(eg, c.qid.path) orelse
        return error.Enonexist;
    var h = envhash(eg, e.name);
    while (h.*) |x| : (h = &x.hash) {
        if (x == e) {
            h.* = e.hash;
            break;
        }
    }
    const i = QID(c.qid.path);
    eg.ent[i] = null;
    if (i < eg.low)
        eg.low = i;
    eg.vers +%= 1;

    // free
    _ = envrealloc(eg, valptr(e), 0) catch unreachable;
    _ = envrealloc(eg, e, 0) catch unreachable;
}

fn envclose(c: *Chan) Error!void {
    if (c.flag & COPEN != 0) {
        // cclose can't fail, so errors from remove will be ignored.
        // since permissions aren't checked,
        // envremove can't not remove it if its there.
        if (c.flag & CRCLOSE != 0)
            envremove(c) catch {};
        closeegrp(@ptrCast(@alignCast(c.aux.?)));
        c.aux = null;
    }
}

fn envread(c: *Chan, a: []u8, off: i64) Error!usize {
    if (c.qid.type & QTDIR != 0)
        return devmod.devdirread(c, a, &.{}, envgen);

    const eg = envgrp(c);
    rlock(&eg.lock);
    defer runlock(&eg.lock);
    const e = envindex(eg, c.qid.path) orelse
        return error.Enonexist;
    const len = e.value.len;
    if (off < 0 or off >= len)
        return 0;
    const o: usize = @intCast(off);
    const n = @min(a.len, len - o);
    // M4: copies to a user address; how a fault unwinds is decided there.
    @memcpy(a[0..n], e.value[o..][0..n]);
    return n;
}

fn envwrite(c: *Chan, a: []const u8, off: i64) Error!usize {
    const n = a.len;

    const eg = envgrp(c);
    wlock(&eg.lock);
    defer wunlock(&eg.lock);
    const e = envindex(eg, c.qid.path) orelse
        return error.Enonexist;
    if (off < 0 or off > Maxvalsize or n > (Maxvalsize - @as(usize, @intCast(off))))
        return error.Etoobig;
    const o: usize = @intCast(off);
    const olen = e.value.len;
    if (o + n > olen) {
        const v = (try envrealloc(eg, valptr(e), o + n)).?;
        e.value = v[0 .. o + n];
    }
    // M4: copies from a user address; how a fault unwinds is decided there.
    @memcpy(e.value[o..][0..n], a); // might fault
    if (o > olen)
        @memset(e.value[olen..o], 0);
    e.vers +%= 1;
    eg.vers +%= 1;
    return n;
}

pub const envdevtab: devmod.Dev = .{
    .dc = 'e',
    .name = "env",

    .attach = envattach,
    .walk = envwalk,
    .stat = envstat,
    .open = envopen,
    .create = envcreate,
    .close = envclose,
    .read = envread,
    .write = envwrite,
    .remove = envremove,
};

pub fn newegrp() Error!*Egrp {
    const eg = alloc.new(Egrp) orelse return error.Enomem;
    eg.* = .{};
    eg.ref.ref = 1;
    return eg;
}

pub fn envcpy(to: *Egrp, from: *Egrp) Error!void {
    rlock(&from.lock);
    defer runlock(&from.lock);

    to.ent = &.{};
    const mem = try envrealloc(to, null, ROUND(from.ent.len, DELTAENV) * @sizeOf(?*Evalue));
    const tab: ?[*]?*Evalue = @ptrCast(@alignCast(mem));
    // An Egrp with no entries has no table (see DIFF), also when an
    // allocation below fails before the first one is in.
    defer if (to.ent.len == 0) {
        _ = envrealloc(to, mem, 0) catch unreachable;
    };
    for (from.ent) |fe| {
        const e = fe orelse continue;
        const t = tab.?;
        const nent = to.ent.len;
        const h = envhash(to, e.name);
        const n = e.name.len + 1;
        const b = (try envrealloc(to, null, @sizeOf(Evalue) + n)).?;
        const ne: *Evalue = @ptrCast(@alignCast(b));
        ne.* = .{};
        ne.name = b[@sizeOf(Evalue)..][0..e.name.len];
        @memcpy(ne.name, e.name);
        ne.name.ptr[e.name.len] = 0;
        ne.value = &.{};
        ne.vers = 0;
        to.path +%= 1;
        ne.path = PATH(to.path, nent);
        ne.hash = h.*;
        h.* = ne;
        t[nent] = ne;
        to.ent = t[0 .. nent + 1];
        if (e.value.len > 0) {
            const v = (try envrealloc(to, null, e.value.len)).?;
            @memcpy(v[0..e.value.len], e.value);
            ne.value = v[0..e.value.len];
        }
    }
    to.low = to.ent.len;
}

pub fn closeegrp(eg: *Egrp) void {
    if (decref(&eg.ref) != 0 or eg == &confegrp)
        return;
    for (eg.ent) |ent| {
        const e = ent orelse continue;
        alloc.free(valptr(e));
        alloc.free(e);
    }
    if (eg.ent.len != 0)
        alloc.free(eg.ent.ptr);
    alloc.free(eg);
}

fn envgrp(c: *Chan) *Egrp {
    if (c.aux) |a|
        return @ptrCast(@alignCast(a));
    return arch.up().?.egrp.?;
}

fn envwritable(c: *Chan) bool {
    return c.aux == null or c.aux == @as(?*anyopaque, @ptrCast(arch.up().?.egrp)) or iseve();
}

/// to let the kernel set environment variables
pub fn ksetenv(ename: []const u8, eval: []const u8, conf: bool) Error!void {
    var buf: [2 * portdat.KNAMELEN]u8 = undefined;

    const name = fmt.snprint(&buf, "#e%s/%s", .{ if (conf) "c" else "", ename });
    const c = try chan.namec(name, portdat.Acreate, lib.OWRITE, 0o666);
    defer chan.cclose(c);
    _ = try devmod.devtab[c.type].write(c, eval, 0);
}

/// Return a copy of configuration environment as a sequence of strings.
/// The strings alternate between name and value.  A zero length name string
/// indicates the end of the list
pub fn getconfenv() Error![]u8 {
    const eg = &confegrp;

    rlock(&eg.lock);
    defer runlock(&eg.lock);
    var n: usize = 1;
    for (eg.ent) |ent| {
        const e = ent orelse continue;
        n += e.name.len + e.value.len + 2;
    }
    const p = alloc.malloc(n) orelse
        return error.Enomem;
    var q: usize = 0;
    for (eg.ent) |ent| {
        const e = ent orelse continue;
        @memcpy(p[q..][0..e.name.len], e.name);
        p[q + e.name.len] = 0;
        q += e.name.len + 1;
        @memcpy(p[q..][0..e.value.len], e.value);
        var m = e.value.len;
        while (m > 0) : (m -= 1) {
            if (p[q + m - 1] != 0)
                break;
        }
        for (p[q .. q + m]) |*ch| {
            if (ch.* == 0)
                ch.* = ' ';
        }
        p[q + m] = 0;
        q += m + 1;
    }
    p[q] = 0;

    return p[0 .. q + 1];
}
