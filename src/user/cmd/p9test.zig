//! p9test - a small threaded file server on lib9p, for the parts ramfs
//! and mntgen do not reach: a server without a file tree (walk1 and
//! clone), dirread9p, readstr, the kernel-style command parser, a
//! queue of requests done by a proc of its own (reqqueue), and flush.
//! The twin of tools/p9test.c, which is built in the guest against
//! stock lib9p and is the same server.
//!
//! usage: p9test srvname
//!
//! The files: ctl takes "set word", "add a b" and "echo ..."; str
//! reads back what they left; slow answers a read after 200ms and
//! wait after 20 seconds, both from the queue's proc.

const std = @import("std");
const libc = @import("libc");
const thread = @import("thread");
const p9 = @import("9p");
const sys = libc.sys;
const fcall = libc.fcall;

pub const main = thread.main;
pub const mainstacksize = 32 * 1024;

const Req = p9.Req;
const Fid = p9.Fid;
const respond = p9.respond;

const Qroot = 0;
const Qctl = 1;
const Qstr = 2;
const Qslow = 3;
const Qwait = 4;
const Nfile = 5;

const names = [Nfile][]const u8{ "/", "ctl", "str", "slow", "wait" };
const modes = [Nfile]u32{ fcall.DMDIR | 0o555, 0o666, 0o444, 0o444, 0o444 };

const Cset = 0;
const Cadd = 1;
const Cecho = 2;

const cmds = [_]p9.Cmdtab{
    .{ .index = Cset, .cmd = "set", .narg = 2 },
    .{ .index = Cadd, .cmd = "add", .narg = 3 },
    .{ .index = Cecho, .cmd = "echo", .narg = 0 },
};

var wordbuf: [64]u8 = undefined;
var word: []const u8 = "none";
var sum: i64 = 0;
var nclone: i32 = 0;
var nclunk: i32 = 0;
var q: *p9.Reqqueue = undefined;

fn dirgen(i_: i32, d: *p9.Dir, _: ?*anyopaque) bool {
    const i = i_ + 1;
    if (i >= Nfile)
        return false;
    const k: usize = @intCast(i);
    d.* = .{};
    d.qid.path = k;
    d.qid.type = if (k == Qroot) fcall.QTDIR else 0;
    d.mode = modes[k];
    d.name = p9.estrdup9p(names[k]);
    d.uid = p9.estrdup9p("test");
    d.gid = p9.estrdup9p("test");
    d.muid = p9.estrdup9p("");
    d.length = if (k == Qstr) 7 else 0;
    return true;
}

fn fswalk1(fid: *Fid, name: []const u8, qid: *p9.Qid) ?[]const u8 {
    if (fid.qid.path != Qroot)
        return "not a directory";
    if (std.mem.eql(u8, name, "..")) {
        qid.* = fid.qid;
        return null;
    }
    for (names[1..], 1..) |n, i| {
        if (std.mem.eql(u8, name, n)) {
            qid.* = .{ .path = i, .vers = 0, .type = 0 };
            return null;
        }
    }
    return "no such file";
}

fn fsclone(_: *Fid, _: *Fid) ?[]const u8 {
    nclone += 1;
    return null;
}

fn fsdestroyfid(_: *Fid) void {
    nclunk += 1;
}

fn fsattach(r: *Req) void {
    r.ofcall.qid = .{ .path = Qroot, .vers = 0, .type = fcall.QTDIR };
    r.fid.?.qid = r.ofcall.qid;
    respond(r, null);
}

fn fsstat(r: *Req) void {
    _ = dirgen(@as(i32, @intCast(r.fid.?.qid.path)) - 1, &r.d, null);
    respond(r, null);
}

fn slowread(r: *Req) void {
    const ms: u32 = if (r.fid.?.qid.path == Qslow) 200 else 20000;
    if (sys.sleep(ms) < 0)
        respond(r, "interrupted")
    else {
        p9.readstr(r, "slept\n");
        respond(r, null);
    }
}

fn fsread(r: *Req) void {
    var buf: [128]u8 = undefined;

    switch (r.fid.?.qid.path) {
        Qroot => {
            p9.dirread9p(r, dirgen, null);
            respond(r, null);
        },
        Qstr => {
            p9.readstr(r, libc.sprint(&buf, "word %s sum %d\n", .{ word, sum }));
            respond(r, null);
        },
        Qslow, Qwait => p9.reqqueuepush(q, r, slowread),
        else => respond(r, "nothing to read"),
    }
}

fn fswrite(r: *Req) void {
    if (r.fid.?.qid.path != Qctl) {
        respond(r, "not the ctl file");
        return;
    }
    const cb = p9.parsecmd(r.ifcall.data[0..r.ifcall.count]);
    defer p9.freecmd(cb);
    const ct = p9.lookupcmd(cb, &cmds) catch {
        p9.respondcmderror(r, cb, "%r", .{});
        return;
    };
    switch (ct.index) {
        Cset => word = libc.sprint(&wordbuf, "%s", .{cb.f[1]}),
        Cadd => sum += libc.atoi(cb.f[1]) + libc.atoi(cb.f[2]),
        Cecho => {
            if (cb.f.len > 3) {
                p9.respondcmderror(r, cb, "too many words (%d)", .{cb.f.len});
                return;
            }
        },
        else => {},
    }
    r.ofcall.count = r.ifcall.count;
    respond(r, null);
}

fn fsflush(r: *Req) void {
    p9.reqqueueflush(q, r.oldreq.?);
    respond(r, null);
}

fn fsend(_: *p9.Srv) void {
    thread.threadexitsall(null);
}

var fs: p9.Srv = .{
    .attach = fsattach,
    .walk1 = fswalk1,
    .clone = fsclone,
    .destroyfid = fsdestroyfid,
    .stat = fsstat,
    .read = fsread,
    .write = fswrite,
    .flush = fsflush,
    .end = fsend,
};

pub fn threadmain(argv: []const []const u8) void {
    if (argv.len != 2)
        libc.sysfatal("usage: p9test srvname", .{});
    q = p9.reqqueuecreate();
    p9.threadpostmountsrv(&fs, argv[1], null, 0);
    thread.threadexits(null);
}
