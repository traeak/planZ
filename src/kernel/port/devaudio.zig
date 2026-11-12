//! The device #A: /dev/audio, audioctl, audiostat and volume.
//! from 9/port/devaudio.c
//!
//! DIFF:
//!   - waserror/poperror become errdefer; an error from a driver's
//!     volwrite while attach writes the default settings is ignored, as
//!     the C ignores it.
//!   - An Audio's entries return Zig errors (see audioif.zig).  A
//!     status or volread that fails fails the read; the C has them
//!     return a length and treats a negative one as 0.
//!   - Audiochan.data is a slice of buf, or null.
//!   - The volume table passed to genaudiovolread and genaudiovolwrite
//!     is a slice.

const std = @import("std");
const fcall = @import("fcall");
const fmt = @import("fmt");
const portdat = @import("portdat.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const ql = @import("qlock.zig");
const lib = @import("lib.zig");
const chan = @import("chan.zig");
const parse = @import("parse.zig");
const netif = @import("netif.zig");
const devcons = @import("devcons.zig");
const devmod = @import("dev.zig");
const audioif = @import("audioif.zig");
const p9 = @import("print.zig");

const print = p9.print;
const incref = portdat.incref;
const decref = portdat.decref;
const readstr = devcons.readstr;

const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const QLock = portdat.QLock;
const Dirtab = devmod.Dirtab;
const Audio = audioif.Audio;
const Volume = audioif.Volume;
const Volfn = audioif.Volfn;

const Audioprobe = struct {
    name: []const u8,
    probe: *const fn (*Audio) i32,
};

const Audiochan = struct {
    qlock: QLock = .{},

    owner: ?*Chan = null,
    adev: *Audio,

    data: ?[]const u8 = null,
    buf: [4000 + 1]u8 = undefined,
};

const Qdir = 0;
const Qaudio = 1;
const Qaudioctl = 2;
const Qaudiostat = 3;
const Qvolume = 4;

var audiodir = [_]Dirtab{
    .{ .name = ".", .qid = .{ .path = Qdir, .type = fcall.QTDIR }, .length = 0, .perm = fcall.DMDIR | 0o555 },
    .{ .name = "audio", .qid = .{ .path = Qaudio }, .length = 0, .perm = 0o666 },
    .{ .name = "audioctl", .qid = .{ .path = Qaudioctl }, .length = 0, .perm = 0o222 },
    .{ .name = "audiostat", .qid = .{ .path = Qaudiostat }, .length = 0, .perm = 0o444 },
    .{ .name = "volume", .qid = .{ .path = Qvolume }, .length = 0, .perm = 0o666 },
};

var naudioprobes: usize = 0;
var audioprobes: [16]Audioprobe = undefined;
var audiodevs: ?*Audio = null;

fn evolume() Error {
    return proc.errorf("illegal volume specifier", .{});
}

fn ebusy() Error {
    return proc.errorf("device is busy", .{});
}

pub fn addaudiocard(name: []const u8, probefn: *const fn (*Audio) i32) void {
    if (naudioprobes >= audioprobes.len)
        return;

    audioprobes[naudioprobes] = .{ .name = name, .probe = probefn };
    naudioprobes += 1;
}

fn audioreset() void {
    var ctlrno: i32 = 0;

    var pp: *?*Audio = &audiodevs;
    pp.* = alloc.new(Audio);

    for (audioprobes[0..naudioprobes]) |*probe| {
        while (true) {
            const a = pp.* orelse {
                print("audio: no memory\n", .{});
                break;
            };
            a.* = .{ .ctlrno = ctlrno, .name = probe.name };
            if (probe.probe(a) != 0)
                break;

            ctlrno += 1;
            pp = &a.next;
            pp.* = alloc.new(Audio);
        }
    }

    alloc.free(pp.*);
    pp.* = null;
}

fn audioclone(c: *Chan, adev: *Audio) ?*Audiochan {
    const ac = alloc.new(Audiochan) orelse {
        chan.cclose(c);
        return null;
    };
    ac.* = .{ .adev = adev };

    c.aux = ac;
    ac.owner = c;

    return ac;
}

fn acof(c: *Chan) *Audiochan {
    return @ptrCast(@alignCast(c.aux.?));
}

var attached: u32 = 0;

fn audioattach(spec: []const u8) Error!*Chan {
    const i = netif.strtoul(spec, 10).v;
    var ap = audiodevs;
    const adev = while (ap) |a| : (ap = a.next) {
        if (a.ctlrno == i)
            break a;
    } else return error.Enodev;

    const c = devmod.devattach('A', spec);
    c.qid.path = Qdir;

    const ac = audioclone(c, adev) orelse
        return error.Enomem;

    const bit = @as(u32, 1) << @intCast(adev.ctlrno);
    if ((attached & bit) == 0) {
        const settings = [_][]const u8{
            "speed 44100",
            "delay 1764", // 40 ms
            "master 100",
            "audio 100",
            "head 100",
            "recgain 0",
        };

        attached |= bit;
        if (adev.volwrite) |volwrite| {
            for (settings) |s| {
                @memcpy(ac.buf[0..s.len], s);
                ac.buf[s.len] = 0;
                _ = volwrite(adev, ac.buf[0..s.len], 0) catch {};
            }
        }
    }

    return c;
}

fn audioopen(c: *Chan, omode: u32) Error!*Chan {
    const ac = acof(c);
    const adev = ac.adev;
    if (c.qid.path == Qaudio) {
        const mode = try devmod.openmode(omode);
        const rd = mode == lib.OREAD or mode == lib.ORDWR;
        const wr = mode == lib.OWRITE or mode == lib.ORDWR;

        if (rd and incref(&adev.audioopenr) != 1) {
            _ = decref(&adev.audioopenr);
            return ebusy();
        }
        errdefer if (rd) {
            _ = decref(&adev.audioopenr);
        };

        if (wr and incref(&adev.audioopenw) != 1) {
            _ = decref(&adev.audioopenw);
            return ebusy();
        }
        errdefer if (wr) {
            _ = decref(&adev.audioopenw);
        };

        return devmod.devopen(c, omode, &audiodir, devmod.devgen);
    }
    return devmod.devopen(c, omode, &audiodir, devmod.devgen);
}

fn audioread(c: *Chan, a: []u8, off: i64) Error!usize {
    const ac = acof(c);
    const adev = ac.adev;

    const f = switch (c.qid.path) {
        Qdir => {
            audiodir[Qaudio].length = if (adev.buffered) |b| @intCast(b(adev)) else 0;
            return devmod.devdirread(c, a, &audiodir, devmod.devgen);
        },
        Qaudio => adev.read,
        Qaudiostat => adev.status,
        Qvolume => adev.volread,
        else => null,
    } orelse return error.Egreg;

    try ql.eqlock(&ac.qlock);
    defer ql.qunlock(&ac.qlock);

    switch (c.qid.path) {
        Qaudiostat, Qvolume => {
            // generate the text on first read
            if (ac.data == null or off == 0) {
                ac.data = null;
                const l = try f(adev, ac.buf[0 .. ac.buf.len - 1], 0);
                ac.buf[l] = 0;
                ac.data = ac.buf[0..l];
            }
            // then serve all requests from buffer
            return readstr(@intCast(off), a, ac.data.?);
        },
        else => return f(adev, a, off),
    }
}

fn audiowrite(c: *Chan, a: []const u8, off: i64) Error!usize {
    const ac = acof(c);
    const adev = ac.adev;

    switch (c.qid.path) {
        Qaudio => {
            const f = adev.write orelse return error.Egreg;
            try ql.eqlock(&ac.qlock);
            defer ql.qunlock(&ac.qlock);
            return f(adev, a, off);
        },
        Qaudioctl, Qvolume => {
            const f = (if (c.qid.path == Qaudioctl) adev.ctl else adev.volwrite) orelse
                return error.Egreg;
            try ql.eqlock(&ac.qlock);
            defer ql.qunlock(&ac.qlock);
            if (a.len >= ac.buf.len)
                return error.Etoobig;

            // copy data to audiochan buffer so it can be modified
            ac.data = null;
            @memcpy(ac.buf[0..a.len], a);
            ac.buf[a.len] = 0;
            return f(adev, ac.buf[0..a.len], 0);
        },
        else => return error.Egreg,
    }
}

fn audioclose(c: *Chan) Error!void {
    const ac = acof(c);
    const adev = ac.adev;
    if (c.qid.path == Qaudio and (c.flag & portdat.COPEN) != 0) {
        if (adev.close) |close|
            close(adev, c.mode) catch {};
        if (c.mode == lib.OWRITE or c.mode == lib.ORDWR)
            _ = decref(&adev.audioopenw);
        if (c.mode == lib.OREAD or c.mode == lib.ORDWR)
            _ = decref(&adev.audioopenr);
    }
    if (ac.owner == c) {
        ac.owner = null;
        c.aux = null;
        alloc.free(ac);
    }
}

fn audiowalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    const ac = acof(c);
    const adev = ac.adev;
    const wq = try devmod.devwalk(c, nc, name, &audiodir, devmod.devgen);
    if (wq.clone) |clone| {
        if (audioclone(clone, adev) == null) {
            alloc.free(wq);
            return error.Enomem;
        }
    }
    return wq;
}

fn audiostat(c: *Chan, dp: []u8) Error!usize {
    const ac = acof(c);
    const adev = ac.adev;
    if (c.qid.path == Qaudio)
        audiodir[Qaudio].length = if (adev.buffered) |b| @intCast(b(adev)) else 0;
    return devmod.devstat(c, dp, &audiodir, devmod.devgen);
}

/// audioread() made sure the buffer is big enougth so a full volume
/// table can be serialized in one pass.
pub fn genaudiovolread(adev: *Audio, a: []u8, _: i64, vol: []const Volume, volget: Volfn, caps: u32) Error!usize {
    var p: usize = 0;
    for (vol, 0..) |*vt, i| {
        if (vt.cap != 0 and (vt.cap & caps) == 0)
            continue;
        var v: [2]i32 = .{ 0, 0 };
        if (volget(adev, i, &v) != 0)
            continue;
        if (vt.type == audioif.Absolute) {
            p += fmt.snprint(a[p..], "%s %d\n", .{ vt.name, v[0] }).len;
        } else {
            const r: i32 = @intCast(@abs(vt.range));
            if (r == 0)
                continue;
            for (&v) |*x| {
                if (x.* < 0)
                    x.* = 0;
                if (x.* > r)
                    x.* = r;
                if (vt.range < 0)
                    x.* = r - x.*;
                x.* = @divTrunc(x.* * 100, r);
            }
            switch (vt.type) {
                audioif.Left => p += fmt.snprint(a[p..], "%s %d\n", .{ vt.name, v[0] }).len,
                audioif.Right => p += fmt.snprint(a[p..], "%s %d\n", .{ vt.name, v[1] }).len,
                audioif.Stereo => p += fmt.snprint(a[p..], "%s %d %d\n", .{ vt.name, v[0], v[1] }).len,
                else => {},
            }
        }
    }

    return p;
}

/// genaudiovolwrite modifies the buffer that gets passed to it. this
/// is ok as long as it is called from inside Audio.volwrite() because
/// audiowrite() copies the data to Audiochan.buf[] and inserts a
/// terminating \0 byte before calling Audio.volwrite().
pub fn genaudiovolwrite(adev: *Audio, a: []u8, _: i64, vol: []const Volume, volset: Volfn, caps: u32) Error!usize {
    var lines = std.mem.splitScalar(u8, a, '\n');
    while (lines.next()) |line_| {
        // tokenize edits the line in place
        const line = a[@intFromPtr(line_.ptr) - @intFromPtr(a.ptr) ..][0..line_.len];
        var mtok: [4][]u8 = undefined;
        var ntok = parse.tokenize(line, &mtok);
        if (ntok <= 0)
            continue;
        var tok: [4][]const u8 = undefined;
        for (mtok[0..ntok], 0..) |t, k| tok[k] = t;
        if (ntok == 1) {
            tok[1] = tok[0];
            tok[0] = "master";
            ntok = 2;
        }
        const i = for (vol, 0..) |*vt, idx| {
            if (vt.cap != 0 and (vt.cap & caps) == 0)
                continue;
            if (!std.ascii.eqlIgnoreCase(vt.name, tok[0]))
                continue;

            if (ntok > 2 and (std.ascii.eqlIgnoreCase(tok[1], "out") or std.ascii.eqlIgnoreCase(tok[1], "in"))) {
                ntok -= 1;
                std.mem.copyForwards([]const u8, tok[1..ntok], tok[2 .. ntok + 1]);
            }

            var v: [2]i32 = .{ 0, 0 };
            if (ntok > 1) {
                v[0] = netif.atoi(tok[1]);
                v[1] = v[0];
            }
            if (ntok > 2)
                v[1] = netif.atoi(tok[2]);
            if (vt.type == audioif.Absolute) {
                _ = volset(adev, idx, &v);
            } else {
                const r: i32 = @intCast(@abs(vt.range));
                for (&v) |*x| {
                    x.* = @divTrunc(50 +% x.* *% r, 100);
                    if (x.* < 0)
                        x.* = 0;
                    if (x.* > r)
                        x.* = r;
                    if (vt.range < 0)
                        x.* = r - x.*;
                }
                _ = volset(adev, idx, &v);
            }
            break idx;
        } else vol.len;
        if (i == vol.len)
            return evolume();
    }

    return a.len;
}

pub const audiodevtab: devmod.Dev = .{
    .dc = 'A',
    .name = "audio",

    .reset = audioreset,
    .attach = audioattach,
    .walk = audiowalk,
    .stat = audiostat,
    .open = audioopen,
    .close = audioclose,
    .read = audioread,
    .write = audiowrite,
};
