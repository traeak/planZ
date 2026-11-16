//! ramfs - a file system in memory
//! from /sys/src/cmd/ramfs.c
//!
//! usage: ramfs [-Dipsubac] [-m mountpoint] [-S srvname]
//!
//! DIFF:
//!   - -D is taken and prints nothing (lib9p's chatty9p).

const std = @import("std");
const libc = @import("libc");
const p9 = @import("9p");
const sys = libc.sys;
const fcall = libc.fcall;
const pool = libc.pool;

const Req = p9.Req;
const File = p9.File;
const respond = p9.respond;

const Ebadoff = "bad file offset or count";
const Eexist = "file already exists";
const Enomem = "no memory";
const Eperm = "permission denied";
const Enotowner = "not owner";
const Elocked = "file is locked";

const Tdat = 0xbabababa;
const Tind = 0xdadadada;

const ESIZE = 64 * 1024;

const MAXFSIZE = (0x7fffffff / @sizeOf(*Ram)) * ESIZE;

/// The start of a block of the pool: for Tind an array of pointers to
/// a file's blocks follows it, for Tdat a block's bytes.
const Ram = extern struct {
    type: u32,
    size: i32,
    link: *?*Ram,

    fn ent(x: *Ram) [*]?*Ram {
        return @ptrCast(@as([*]Ram, @ptrCast(x)) + 1);
    }

    fn data(x: *Ram) [*]u8 {
        return @ptrCast(@as([*]Ram, @ptrCast(x)) + 1);
    }

    fn nent(x: *Ram) usize {
        return @as(usize, @intCast(x.size)) / @sizeOf(?*Ram);
    }
};

var private = false;

fn ramalloc(size: usize) ?*anyopaque {
    return @ptrCast(libc.sbrk(size));
}

fn rammoved(_: *anyopaque, to: *anyopaque) void {
    const x: *Ram = @ptrCast(@alignCast(to));

    x.link.* = x;
    if (x.type != Tind)
        return;

    const e = x.ent();
    for (0..x.nent()) |i| {
        if (e[i]) |y|
            y.link = &e[i];
    }
}

fn ramnolock(_: *pool.Pool) void {}

fn ramprint(_: *pool.Pool, s: []const u8) void {
    _ = sys.write(2, s);
}

fn rampanic(_: *pool.Pool, s: []const u8) noreturn {
    _ = sys.write(2, s);
    _ = sys.write(2, "\n");
    sys.exits("panic");
}

var rampool: pool.Pool = .{
    .name = "ram",
    .maxsize = 800 * 1024 * 1024,
    .minarena = 4 * 1024,
    .quantum = 32,
    .alloc = ramalloc,
    .move = rammoved,
    .lock = ramnolock,
    .unlock = ramnolock,
    .flags = 0,
    .print = ramprint,
    .panic = rampanic,
};

fn now() u32 {
    return @truncate(@as(u64, @bitCast(libc.time())));
}

fn ram(f: *File) ?*Ram {
    return @ptrCast(@alignCast(f.aux));
}

fn accessfile(f: *File, a: u32) void {
    f.d.atime = now();
    if (a & sys.AWRITE != 0) {
        f.d.mtime = f.d.atime;
        f.d.qid.vers +%= 1;
    }
}

fn fsread(r: *Req) void {
    const f = r.fid.?.file.?;
    var off = r.ifcall.offset;
    var count: i64 = r.ifcall.count;

    if (count == 0 or off >= f.d.length or f.aux == null) {
        r.ofcall.count = 0;
        respond(r, null);
        return;
    }

    var top = off + count;
    if (top > MAXFSIZE) {
        respond(r, Ebadoff);
        return;
    }

    if (top > f.d.length) {
        top = f.d.length;
        count = top - off;
    }
    var p: usize = 0;
    while (count > 0) {
        const i: usize = @intCast(@divTrunc(off, ESIZE));
        const o: usize = @intCast(@rem(off, ESIZE));

        const ind = ram(f).?;
        const x: ?*Ram = if (i < ind.nent()) ind.ent()[i] else null;
        var n: usize = undefined;
        if (x != null and o < x.?.size) {
            n = @as(usize, @intCast(x.?.size)) - o;
            if (n > count)
                n = @intCast(count);
            @memcpy(r.rbuf[p..][0..n], x.?.data()[o..][0..n]);
        } else {
            n = ESIZE - o;
            if (n > count)
                n = @intCast(count);
            @memset(r.rbuf[p..][0..n], 0);
        }
        p += n;
        off += @intCast(n);
        count -= @intCast(n);
    }
    accessfile(f, sys.AREAD);

    r.ofcall.count = @intCast(p);
    respond(r, null);
}

fn fswrite(r: *Req) void {
    const f = r.fid.?.file.?;
    var off = r.ifcall.offset;
    var count: i64 = r.ifcall.count;

    if (f.d.mode & fcall.DMAPPEND != 0)
        off = f.d.length;

    if (count == 0) {
        r.ofcall.count = 0;
        respond(r, null);
        return;
    }

    const top = off + count;
    if (top > MAXFSIZE) {
        respond(r, Ebadoff);
        return;
    }

    var n: usize = @as(usize, @intCast(@divTrunc(top + ESIZE - 1, ESIZE))) * @sizeOf(?*Ram);
    var x = ram(f);
    if (x == null or x.?.size < n) {
        const nx: *Ram = @ptrCast(@alignCast(pool.poolrealloc(&rampool, x, @sizeOf(Ram) + n) orelse {
            respond(r, Enomem);
            return;
        }));
        const link: *?*Ram = @ptrCast(&f.aux);
        if (link.* == null) {
            nx.* = .{ .type = Tind, .size = 0, .link = link };
            link.* = nx;
        } else if (nx != link.*)
            rammoved(@ptrCast(link.*.?), nx);
        const old: usize = @intCast(nx.size);
        @memset(nx.data()[old..n], 0);
        nx.size = @intCast(n);
        x = nx;
    }

    const src = r.ifcall.data;
    var p: usize = 0;
    while (count > 0) {
        const i: usize = @intCast(@divTrunc(off, ESIZE));
        const o: usize = @intCast(@rem(off, ESIZE));

        n = ESIZE - o;
        if (n > count)
            n = @intCast(count);

        var b = ram(f).?.ent()[i];
        if (b == null or b.?.size < o + n) {
            const nb: *Ram = @ptrCast(@alignCast(pool.poolrealloc(&rampool, b, @sizeOf(Ram) + o + n) orelse {
                respond(r, Enomem);
                return;
            }));
            // the pool may have moved the file's index
            const link: *?*Ram = &ram(f).?.ent()[i];
            if (link.* == null) {
                nb.type = Tdat;
                nb.size = 0;
            }
            if (o > nb.size) {
                const old: usize = @intCast(nb.size);
                @memset(nb.data()[old..o], 0);
            }
            nb.size = @intCast(o + n);
            nb.link = link;
            link.* = nb;
            b = nb;
        }

        @memcpy(b.?.data()[o..][0..n], src[p..][0..n]);
        p += n;
        off += @intCast(n);
        count -= @intCast(n);
    }

    if (top > f.d.length)
        f.d.length = top;
    accessfile(f, sys.AWRITE);

    r.ofcall.count = @intCast(p);
    respond(r, null);
}

fn truncfile(f: *File, l: i64) void {
    if (ram(f)) |x| {
        const n = x.nent();
        var i: usize = @intCast(@divTrunc(l, ESIZE));
        if (i < n) {
            const o: i32 = @intCast(@rem(l, ESIZE));
            const e = x.ent();
            if (o != 0 and e[i] != null) {
                if (o < e[i].?.size)
                    e[i].?.size = o;
                i += 1;
            }
            while (i < n) : (i += 1) {
                if (e[i]) |b| {
                    pool.poolfree(&rampool, b);
                    e[i] = null;
                }
            }
        }
        if (l == 0) {
            pool.poolfree(&rampool, x);
            f.aux = null;
        }
    }
    f.d.length = l;
}

fn fswstat(r: *Req) void {
    const eql = std.mem.eql;
    const f = r.fid.?.file.?;
    const u = r.fid.?.uid;
    const d = &r.d;
    const nomode = ~@as(u32, 0);

    perm: {
        // To change length, must have write permission on file.
        if (d.length != -1 and d.length != f.d.length) {
            if (d.length > MAXFSIZE) {
                respond(r, Ebadoff);
                return;
            }
            if (!p9.hasperm(f, u, sys.AWRITE) or (f.d.mode & fcall.DMDIR) != 0)
                break :perm;
        }

        // To change name, must have write permission in parent.
        if (d.name.len != 0 and !eql(u8, d.name, f.d.name)) {
            const w = f.parent orelse break :perm;
            p9.incref(&w.ref);
            if (!p9.hasperm(w, u, sys.AWRITE)) {
                p9.closefile(w);
                break :perm;
            }
            if (p9.walkfile(w, d.name)) |x| {
                p9.closefile(x);
                respond(r, Eexist);
                return;
            }
        }

        // To change mode, must be owner or group leader.
        // Because of lack of users file, leader=>group itself.
        if (d.mode != nomode and f.d.mode != d.mode) {
            if (!eql(u8, u, f.d.uid) and !eql(u8, u, f.d.gid)) {
                respond(r, Enotowner);
                return;
            }
        }

        // To change group, must be owner and member of new group,
        // or leader of current group and leader of new group.
        // Second case cannot happen, but we check anyway.
        if (d.gid.len != 0 and !eql(u8, f.d.gid, d.gid)) {
            if (!eql(u8, u, f.d.uid) and !(eql(u8, u, f.d.gid) and eql(u8, u, d.gid))) {
                respond(r, Enotowner);
                return;
            }
        }

        if (d.mode != nomode) {
            f.d.mode = d.mode;
            f.d.qid.type = @intCast(f.d.mode >> 24);
        }
        if (d.name.len != 0) {
            libc.allocator.free(f.d.name);
            f.d.name = p9.estrdup9p(d.name);
        }
        if (d.length != -1 and d.length != f.d.length)
            truncfile(f, d.length);

        accessfile(f, sys.AWRITE);
        if (d.mtime != ~@as(u32, 0))
            f.d.mtime = d.mtime;

        respond(r, null);
        return;
    }
    respond(r, Eperm);
}

fn fscreate(r: *Req) void {
    const dir = r.fid.?.file.?;
    var p = r.ifcall.perm;
    if ((p & fcall.DMDIR) != 0)
        p = (p & ~@as(u32, 0o777)) | ((p & dir.d.mode) & 0o777)
    else
        p = (p & ~@as(u32, 0o666)) | ((p & dir.d.mode) & 0o666);
    const f = p9.createfile(dir, r.ifcall.name, r.fid.?.uid, p, null) catch {
        p9.responderror(r);
        return;
    };
    f.d.mtime = now();
    f.d.atime = f.d.mtime;
    f.aux = null;
    // Kept from C: the fid's reference to the directory is not given up
    r.fid.?.file = f;
    r.ofcall.qid = f.d.qid;
    respond(r, null);
}

fn fsopen(r: *Req) void {
    const f = r.fid.?.file.?;
    if ((f.d.mode & fcall.DMEXCL) != 0) {
        if (f.ref.ref > 2 and @as(i32, @bitCast(now() -% f.d.atime)) < 300) {
            respond(r, Elocked);
            return;
        }
    }
    if ((f.d.mode & fcall.DMAPPEND) == 0 and (r.ifcall.mode & sys.OTRUNC) != 0) {
        truncfile(f, 0);
        accessfile(f, sys.AWRITE);
    }
    respond(r, null);
}

fn fsdestroyfid(fid: *p9.Fid) void {
    const f = fid.file orelse return;
    // Kept from C: removefile gives up the fid's reference and the fid
    // still has the file, so closefid gives it up once more; the File
    // is on the free list by then, where the count is not looked at
    if (fid.omode != -1 and (fid.omode & sys.ORCLOSE) != 0 and f.parent != null)
        p9.removefile(f) catch {};
}

fn fsdestroyfile(f: *File) void {
    truncfile(f, 0);
}

fn fsstart(_: *p9.Srv) void {
    var buf: [40]u8 = undefined;

    if (private) {
        const ctl = sys.open(libc.sprint(&buf, "/proc/%d/ctl", .{libc.getpid()}), sys.OWRITE);
        if (ctl < 0)
            libc.sysfatal("can't protect memory: %r", .{});
        _ = sys.write(ctl, "noswap\n");
        _ = sys.write(ctl, "private\n");
        _ = sys.close(ctl);
    }
}

var fs: p9.Srv = .{
    .open = fsopen,
    .read = fsread,
    .write = fswrite,
    .wstat = fswstat,
    .create = fscreate,
    .destroyfid = fsdestroyfid,

    .start = fsstart,
};

fn usage() noreturn {
    libc.fprint(2, "usage: %s [-Dipsubac] [-m mountpoint] [-S srvname]\n", .{libc.argv0});
    libc.exits("usage");
}

pub fn main(argv: []const []const u8) void {
    var srvname: ?[]const u8 = null;
    var mtpt: ?[]const u8 = "/tmp";
    var mountflags: u32 = 0;
    var stdio = false;

    fs.tree = p9.alloctree(null, null, fcall.DMDIR | 0o777, fsdestroyfile);

    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'D' => p9.chatty9p += 1,
        's' => {
            srvname = "ramfs";
            mtpt = null;
        },
        'S' => {
            srvname = args.value() orelse usage();
            mtpt = null;
        },
        'm' => mtpt = args.value() orelse usage(),
        'i' => stdio = true,
        'p' => private = true,
        'u' => rampool.maxsize = ~@as(usize, 0),
        'b' => mountflags |= sys.MBEFORE,
        'c' => mountflags |= sys.MCREATE,
        'a' => mountflags |= sys.MAFTER,
        else => usage(),
    };
    if (args.rest().len > 0)
        usage();

    if (stdio) {
        fs.infd = 0;
        fs.outfd = 1;
        p9.srv(&fs);
        libc.exits(null);
    }

    if (srvname == null and mtpt == null)
        libc.sysfatal("must specify -S, or -m option", .{});

    if (mountflags == 0)
        mountflags = sys.MREPL | sys.MCREATE;
    p9.postmountsrv(&fs, srvname, mtpt, mountflags);
    libc.exits(null);
}
