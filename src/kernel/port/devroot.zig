//! The root device, #/: the directories the name space is built on, and
//! /boot with the files that were linked into the kernel.
//! from 9/port/devroot.c
//!
//! DIFF:
//!   - A Dirtab's name is a slice, so each list keeps the storage for
//!     the names addlist copies (Dirlist.name).  The limit on a name's
//!     length is still that of the C's Dirtab.name, KNAMELEN.
//!   - A file's contents are a slice; addbootfile has no length argument
//!     and Dirlist.data holds slices.
//!   - rootread uses the whole 64-bit offset, where the C truncates it
//!     to a 32-bit ulong.
//!   - The disabled debugging print in rootread (#ifdef asdf) is left out.
//!
//! Where the tables come from: in 9front the directories of #/ are not
//! generated; rootreset adds them (bin dev env fd mnt n net net.alt proc
//! rc root srv shr) to a table that starts with the directory itself and
//! boot.  The same list is here.  What is generated, by 9/port/mkrootc
//! from the bootdir section of the kernel configuration, is bootlinks(),
//! a list of addbootfile calls that chandevreset's caller runs (see
//! 9/port/mkdevc); here whoever holds the boot files calls addbootfile.

const std = @import("std");
const fcall = @import("fcall");
const portdat = @import("portdat.zig");
const proc = @import("proc.zig");
const devmod = @import("dev.zig");
const p9 = @import("print.zig");

const print = p9.print;
const panic = p9.panic;

const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Qid = portdat.Qid;
const Dir = portdat.Dir;
const Dirtab = devmod.Dirtab;
const devdir = devmod.devdir;
const devgen = devmod.devgen;
const QTDIR = fcall.QTDIR;
const DMDIR = fcall.DMDIR;
const DEVDOTDOT = portdat.DEVDOTDOT;
const KNAMELEN = portdat.KNAMELEN;

const Qdir = 0;
const Qboot = 0x1000;

const Nrootfiles = 32;
const Nbootfiles = 32;

const Dirlist = struct {
    base: u32,
    dir: []Dirtab,
    data: [][]const u8,
    name: [][KNAMELEN]u8,
    ndir: usize,
    mdir: usize,
};

fn dirinit(comptime n: usize, comptime first: []const Dirtab) [n]Dirtab {
    var tab: [n]Dirtab = @splat(.{ .name = "", .qid = .{} });
    for (first, 0..) |d, i|
        tab[i] = d;
    return tab;
}

var rootdir: [Nrootfiles]Dirtab = dirinit(Nrootfiles, &.{
    .{ .name = "#/", .qid = .{ .path = Qdir, .vers = 0, .type = QTDIR }, .length = 0, .perm = DMDIR | 0o555 },
    .{ .name = "boot", .qid = .{ .path = Qboot, .vers = 0, .type = QTDIR }, .length = 0, .perm = DMDIR | 0o555 },
});
var rootdata: [Nrootfiles][]const u8 = @splat(&.{});
var rootname: [Nrootfiles][KNAMELEN]u8 = undefined;
var rootlist: Dirlist = .{
    .base = 0,
    .dir = &rootdir,
    .data = &rootdata,
    .name = &rootname,
    .ndir = 2,
    .mdir = Nrootfiles,
};

var bootdir: [Nbootfiles]Dirtab = dirinit(Nbootfiles, &.{
    .{ .name = "boot", .qid = .{ .path = Qboot, .vers = 0, .type = QTDIR }, .length = 0, .perm = DMDIR | 0o555 },
});
var bootdata: [Nbootfiles][]const u8 = @splat(&.{});
var bootname: [Nbootfiles][KNAMELEN]u8 = undefined;
var bootlist: Dirlist = .{
    .base = Qboot,
    .dir = &bootdir,
    .data = &bootdata,
    .name = &bootname,
    .ndir = 1,
    .mdir = Nbootfiles,
};

/// add a file to the list
fn addlist(l: *Dirlist, name: []const u8, contents: []const u8, perm: u32) void {
    if (l.ndir >= l.mdir)
        panic("too many root files", .{});
    l.data[l.ndir] = contents;
    const d = &l.dir[l.ndir];
    if (name.len >= KNAMELEN)
        panic("root file name too long: %s", .{name});
    const n = l.name[l.ndir][0..name.len];
    @memcpy(n, name);
    d.name = n;
    d.length = @intCast(contents.len);
    d.perm = perm;
    d.qid.type = 0;
    d.qid.vers = 0;
    l.ndir += 1;
    d.qid.path = l.ndir + l.base;
    if (perm & DMDIR != 0)
        d.qid.type |= QTDIR;
}

/// add a root file
pub fn addbootfile(name: []const u8, contents: []const u8) void {
    addlist(&bootlist, name, contents, 0o555);
}

/// add a root directory
fn addrootdir(name: []const u8) void {
    addlist(&rootlist, name, &.{}, DMDIR | 0o555);
}

fn rootreset() void {
    addrootdir("bin");
    addrootdir("dev");
    addrootdir("env");
    addrootdir("fd");
    addrootdir("mnt");
    addrootdir("n");
    addrootdir("net");
    addrootdir("net.alt");
    addrootdir("proc");
    addrootdir("rc");
    addrootdir("root");
    addrootdir("srv");
    addrootdir("shr");
}

fn rootattach(spec: []const u8) Error!*Chan {
    return devmod.devattach('/', spec);
}

fn rootgen(c: *Chan, name: ?[]const u8, _: []const Dirtab, s: i32, dp: *Dir) i32 {
    const path: i32 = @bitCast(@as(u32, @truncate(c.qid.path)));
    switch (path) {
        Qdir => {
            if (s == DEVDOTDOT) {
                devdir(c, .{ .path = Qdir, .vers = 0, .type = QTDIR }, "#/", 0, proc.eve, 0o555, dp);
                return 1;
            }
            return devgen(c, name, rootlist.dir[0..rootlist.ndir], s, dp);
        },
        Qboot => {
            if (s == DEVDOTDOT) {
                devdir(c, .{ .path = Qdir, .vers = 0, .type = QTDIR }, "#/", 0, proc.eve, 0o555, dp);
                return 1;
            }
            return devgen(c, name, bootlist.dir[0..bootlist.ndir], s, dp);
        },
        else => {
            if (s == DEVDOTDOT) {
                if (path < Qboot)
                    devdir(c, .{ .path = Qdir, .vers = 0, .type = QTDIR }, "#/", 0, proc.eve, 0o555, dp)
                else
                    devdir(c, .{ .path = Qboot, .vers = 0, .type = QTDIR }, "#/", 0, proc.eve, 0o555, dp);
                return 1;
            }
            if (s != 0)
                return -1;
            var t: i32 = undefined;
            var l: *Dirlist = undefined;
            if (path < Qboot) {
                t = path - 1;
                l = &rootlist;
            } else {
                t = path - Qboot - 1;
                l = &bootlist;
            }
            if (t >= l.ndir)
                return -1;
            if (t < 0) {
                print("rootgen %llud %d %d\n", .{ c.qid.path, s, t });
                panic("whoops", .{});
            }
            const d = &l.dir[@intCast(t)];
            devdir(c, d.qid, d.name, d.length, proc.eve, d.perm, dp);
            return 1;
        },
    }
}

fn rootwalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    return devmod.devwalk(c, nc, name, &.{}, rootgen);
}

fn rootstat(c: *Chan, dp: []u8) Error!usize {
    return devmod.devstat(c, dp, &.{}, rootgen);
}

fn rootopen(c: *Chan, omode: u32) Error!*Chan {
    return devmod.devopen(c, omode, &.{}, devgen);
}

/// sysremove() knows this is a nop
fn rootclose(_: *Chan) Error!void {}

fn rootread(c: *Chan, buf: []u8, off: i64) Error!usize {
    const offset: u64 = @bitCast(off);
    var n = buf.len;

    var t: u32 = @truncate(c.qid.path);
    switch (t) {
        Qdir, Qboot => return devmod.devdirread(c, buf, &.{}, rootgen),
        else => {},
    }

    var l: *Dirlist = undefined;
    if (t < Qboot) {
        l = &rootlist;
    } else {
        t -= Qboot;
        l = &bootlist;
    }

    t -= 1;
    if (t >= l.ndir)
        return error.Egreg;

    const d = &l.dir[t];
    const data = l.data[t];
    const length: u64 = @intCast(d.length);
    if (offset >= length)
        return 0;
    if (n > length - offset)
        n = @intCast(length - offset);
    @memcpy(buf[0..n], data[@intCast(offset)..][0..n]);
    return n;
}

fn rootwrite(_: *Chan, _: []const u8, _: i64) Error!usize {
    return error.Egreg;
}

pub const rootdevtab: devmod.Dev = .{
    .dc = '/',
    .name = "root",

    .reset = rootreset,
    .attach = rootattach,
    .walk = rootwalk,
    .stat = rootstat,
    .open = rootopen,
    .close = rootclose,
    .read = rootread,
    .write = rootwrite,
};
