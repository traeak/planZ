//! The dup device, #d: the process's open file descriptors as files.
//! Opening /fd/n gives the file behind descriptor n; /fd/nctl describes it.
//! from 9/port/devdup.c
//!
//! DIFF:
//!   - dupgen also stops when the descriptor is past the end of the fd
//!     array, which the C takes on trust from maxfd.
//!   - procfdprint (9/port/devproc.c) and readstr (9/port/devcons.c)
//!     are private copies here until those files are ported; each is
//!     marked with where it goes.
//!   - procfdprint prints a missing path as chanpath does, where the C
//!     would dereference nil.

const std = @import("std");
const fcall = @import("fcall");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const lib = @import("lib.zig");
const taslock = @import("taslock.zig");
const proc = @import("proc.zig");
const chan = @import("chan.zig");
const devmod = @import("dev.zig");
const sysfile = @import("sysfile.zig");
const p9 = @import("print.zig");

const panic = p9.panic;
const lock = taslock.lock;
const unlock = taslock.unlock;
const incref = portdat.incref;
const cclose = chan.cclose;
const fdtochan = sysfile.fdtochan;

const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Qid = portdat.Qid;
const Dir = portdat.Dir;
const Dirtab = devmod.Dirtab;
const devdir = devmod.devdir;
const openmode = devmod.openmode;
const QTDIR = fcall.QTDIR;
const QTFILE = fcall.QTFILE;
const QTAUTH = fcall.QTAUTH;
const DEVDOTDOT = portdat.DEVDOTDOT;
const COPEN = portdat.COPEN;

/// One line of /proc/n/fd; returns the part of s written.
/// from 9/port/devproc.c
// M4: move to devproc.zig
fn procfdprint(c: *Chan, fd: i32, s: []u8) []u8 {
    return fmt.snprint(s, "%3d %.2s %C %4ld (%.16llux %lud %.2ux) %5ld %8lld %s\n", .{
        fd,
        "r w rw"[@as(usize, c.mode & 3) << 1 ..],
        devmod.devtab[c.type].dc,
        c.dev,
        c.qid.path,
        c.qid.vers,
        c.qid.type,
        c.iounit,
        c.offset,
        chan.chanpath(c),
    });
}

/// Read from a string as if it were a file.
/// from 9/port/devcons.c
// M3: move to devcons.zig
fn readstr(off: u64, buf: []u8, str: []const u8) usize {
    if (off >= str.len)
        return 0;
    const n = @min(buf.len, str.len - off);
    @memcpy(buf[0..n], str[@intCast(off)..][0..n]);
    return n;
}

// Qid is (2*fd + (file is ctl))+1

fn dupgen(c: *Chan, _: ?[]const u8, _: []const Dirtab, s_: i32, dp: *Dir) i32 {
    const up = arch.up().?;
    const fgrp = up.fgrp.?;
    const perm = [_]u32{ 0o400, 0o200, 0o600, 0 };

    if (s_ == DEVDOTDOT) {
        devdir(c, c.qid, ".", 0, proc.eve, 0o555, dp);
        return 1;
    }
    if (s_ == 0)
        return 0;
    const s: u32 = @intCast(s_ - 1);
    if (s / 2 > fgrp.maxfd or s / 2 >= fgrp.fd.len)
        return -1;
    const f = fgrp.fd[s / 2] orelse return 0;
    var p: u32 = undefined;
    var name: []u8 = undefined;
    if (s & 1 != 0) {
        p = 0o400;
        name = fmt.snprint(&up.genbuf, "%dctl", .{s / 2});
    } else {
        p = perm[f.mode & 3];
        name = fmt.snprint(&up.genbuf, "%d", .{s / 2});
    }
    const q = devmod.mkqid(s + 1, 0, QTFILE);
    devdir(c, q, name, 0, proc.eve, p, dp);
    return 1;
}

fn dupattach(spec: []const u8) Error!*Chan {
    return devmod.devattach('d', spec);
}

fn dupwalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    return devmod.devwalk(c, nc, name, &.{}, dupgen);
}

fn dupstat(c: *Chan, db: []u8) Error!usize {
    return devmod.devstat(c, db, &.{}, dupgen);
}

fn dupopen(c: *Chan, omode: u32) Error!*Chan {
    if (omode & lib.ORCLOSE != 0)
        return error.Eperm;
    if (c.qid.type & QTDIR != 0) {
        if (omode != 0)
            return error.Eisdir;
        c.mode = 0;
        c.flag |= COPEN;
        c.offset = 0;
        return c;
    }
    if (c.qid.type & QTAUTH != 0)
        return error.Eperm;
    const twicefd: i32 = @bitCast(@as(u32, @truncate(c.qid.path -% 1)));
    const fd = @divTrunc(twicefd, 2);
    var f: *Chan = undefined;
    if (twicefd & 1 != 0) {
        // ctl file
        f = c;
        f.mode = @intCast(try openmode(omode));
        f.flag |= COPEN;
        f.offset = 0;
    } else {
        // fd file
        f = try fdtochan(fd, @intCast(try openmode(omode)), false, true);
        cclose(c);
    }
    return f;
}

fn dupclose(_: *Chan) Error!void {}

fn dupread(c: *Chan, va: []u8, offset: i64) Error!usize {
    var buf: [256]u8 = undefined;

    if (c.qid.type == QTDIR)
        return devmod.devdirread(c, va, &.{}, dupgen);
    const twicefd: i32 = @bitCast(@as(u32, @truncate(c.qid.path -% 1)));
    const fd = @divTrunc(twicefd, 2);
    if (twicefd & 1 != 0) {
        const fc = try fdtochan(fd, -1, false, true);
        const s = procfdprint(fc, fd, &buf);
        cclose(fc);
        return readstr(@bitCast(offset), va, s);
    }
    panic("dupread", .{});
}

fn dupwrite(_: *Chan, _: []const u8, _: i64) Error!usize {
    return error.Eperm;
}

pub const dupdevtab: devmod.Dev = .{
    .dc = 'd',
    .name = "dup",

    .attach = dupattach,
    .walk = dupwalk,
    .stat = dupstat,
    .open = dupopen,
    .close = dupclose,
    .read = dupread,
    .write = dupwrite,
};
