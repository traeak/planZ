//! mntgen - a directory in which any name walked to is there, to mount
//! on: /n and /mnt
//! from /sys/src/cmd/mntgen.c
//!
//! usage: mntgen [-s srvname] [mtpt]
//!
//! DIFF:
//!   - A name's qid is its MD5, as in C, but from Zig's standard
//!     library: libsec is not ported.
//!   - -D is taken and prints nothing (lib9p's chatty9p).

const std = @import("std");
const libc = @import("libc");
const p9 = @import("9p");
const sys = libc.sys;
const fcall = libc.fcall;

const Req = p9.Req;
const Fid = p9.Fid;
const Dir = p9.Dir;
const respond = p9.respond;

fn usage() noreturn {
    libc.fprint(2, "mntgen [-s srvname] [mtpt]\n", .{});
    libc.exits("usage");
}

var time0: u32 = 0;

const Tab = struct {
    name: []u8,
    qid: u64,
    time: u32,
    ref: i32,
};

var tab: []Tab = &.{};
var ntab: usize = 0;

fn now() u32 {
    return @truncate(@as(u64, @bitCast(libc.time())));
}

fn findtab(path: u64) ?*Tab {
    for (tab[0..ntab]) |*t| {
        if (t.qid == path)
            return t;
    }
    return null;
}

fn hash(name: []const u8) u64 {
    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(name, &digest, .{});
    return std.mem.readInt(u64, digest[0..8], .little) & ((1 << 48) - 1);
}

fn fsopen(r: *Req) void {
    if (r.ifcall.mode != sys.OREAD)
        respond(r, "permission denied")
    else
        respond(r, null);
}

fn dirgen(i: i32, d: *Dir, _: ?*anyopaque) bool {
    if (i >= @as(i32, @intCast(ntab)))
        return false;
    d.* = .{};
    d.qid.type = fcall.QTDIR;
    d.uid = p9.estrdup9p("sys");
    d.gid = p9.estrdup9p("sys");
    d.mode = fcall.DMDIR | 0o555;
    d.length = 0;
    if (i == -1) {
        d.name = p9.estrdup9p("/");
        d.atime = time0;
        d.mtime = time0;
    } else {
        const t = &tab[@intCast(i)];
        d.qid.path = t.qid;
        d.name = p9.estrdup9p(t.name);
        d.atime = t.time;
        d.mtime = t.time;
    }
    return true;
}

fn fsread(r: *Req) void {
    if (r.fid.?.qid.path == 0)
        p9.dirread9p(r, dirgen, null)
    else
        r.ofcall.count = 0;
    respond(r, null);
}

fn fsstat(r: *Req) void {
    const qid = r.fid.?.qid.path;
    if (qid == 0)
        _ = dirgen(-1, &r.d, null)
    else {
        const t = findtab(qid) orelse {
            respond(r, "path not found (???)");
            return;
        };
        _ = dirgen(@intCast(t - tab.ptr), &r.d, null);
    }
    respond(r, null);
}

fn fswalk1(fid: *Fid, name: []const u8, _: ?*anyopaque) ?[]const u8 {
    if (fid.qid.path != 0) {
        // nothing in child directory
        if (std.mem.eql(u8, name, "..")) {
            if (findtab(fid.qid.path)) |t|
                t.ref -= 1;
            fid.qid.path = 0;
            return null;
        }
        return "path not found";
    }
    // root
    if (std.mem.eql(u8, name, ".."))
        return null;
    for (tab[0..ntab]) |*t| {
        if (std.mem.eql(u8, t.name, name)) {
            t.ref += 1;
            fid.qid.path = t.qid;
            return null;
        }
    }
    const h = hash(name);
    if (findtab(h) != null)
        return "hash collision";

    // create it
    if (ntab == tab.len)
        tab = p9.erealloc9p(tab, if (tab.len == 0) 16 else tab.len * 2);
    tab[ntab] = .{
        .qid = h,
        .name = p9.estrdup9p(name),
        .time = now(),
        .ref = 1,
    };
    fid.qid.path = h;
    ntab += 1;

    return null;
}

fn fsclone(fid: *Fid, _: *Fid, _: ?*anyopaque) ?[]const u8 {
    if (findtab(fid.qid.path)) |t|
        t.ref += 1;
    return null;
}

fn fswalk(r: *Req) void {
    p9.walkandclone(r, fswalk1, fsclone, null);
}

fn fsclunk(fid: *Fid) void {
    const qid = fid.qid.path;
    if (qid == 0)
        return;
    const t = findtab(qid) orelse {
        libc.fprint(2, "warning: cannot find %llux\n", .{qid});
        return;
    };
    t.ref -= 1;
    if (t.ref == 0) {
        libc.allocator.free(t.name);
        ntab -= 1;
        t.* = tab[ntab];
    } else if (t.ref < 0)
        libc.fprint(2, "warning: negative ref count for %s\n", .{t.name});
}

fn fsattach(r: *Req) void {
    if (r.ifcall.aname.len != 0) {
        respond(r, "invalid attach specifier");
        return;
    }

    r.ofcall.qid = .{ .path = 0, .vers = 0, .type = fcall.QTDIR };
    r.fid.?.qid = r.ofcall.qid;
    respond(r, null);
}

var fs: p9.Srv = .{
    .attach = fsattach,
    .open = fsopen,
    .read = fsread,
    .stat = fsstat,
    .walk = fswalk,
    .destroyfid = fsclunk,
};

pub fn main(argv: []const []const u8) void {
    var service: ?[]const u8 = null;

    time0 = now();
    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'D' => p9.chatty9p += 1,
        's' => service = args.value() orelse usage(),
        else => usage(),
    };
    const rest = args.rest();
    if (rest.len > 1)
        usage();
    p9.postmountsrv(&fs, service, if (rest.len > 0) rest[0] else "/n", sys.MAFTER);
    libc.exits(null);
}
