//! The IP device, #I: one file tree per protocol stack (Fs), a
//! directory per protocol and under it one per conversation, with the
//! ctl, data, listen ... files that programs dial through.  Also the
//! routines the protocols share for naming their ends: local ports,
//! Fsstdconnect and friends, Fsproto, Fsprotoclone, Fsnewcall.
//! from 9/ip/devip.c
//!
//! DIFF:
//!   - Errors are Zig error returns; every waserror became defer or
//!     errdefer.  Functions that return an error string in C return
//!     Error!void (rule 2 of ipdat.zig), so connectctlmsg and
//!     announcectlmsg set the conversation back to Idle for every
//!     failure of Proto.connect and Proto.announce, raised or returned.
//!   - The gotos of ipgen (Protodir, Convdir) are the functions
//!     protodir and convdir, and those of ipread (Readstr) are calls
//!     of readstr.  fsof, protoof and convof name the C's
//!     ipfs[c->dev]->p[PROTO(c->qid)]->conv[CONV(c->qid)].
//!   - ipreset installs no format verbs: %I, %M, %V and %E are the
//!     wrappers of ipaux.zig.
//!   - ipprotoinit is a slice that the configuration sets, not a nil
//!     terminated array the linker finds.
//!   - ipopen works out the open mode first, so a bad mode fails
//!     before a conversation is cloned or its use counted; the C fails
//!     in openmode() afterwards and leaves the count raised.  The
//!     C's m2p has no entry for OEXEC and reads past the table; here
//!     OEXEC asks for read permission, as openmode treats it.
//!   - ipbread returns an empty Block where the C returns nil for a
//!     hung-up queue: Dev.bread cannot return null (as devpipe).
//!   - ipbwrite frees the block when the conversation has no write
//!     queue; the C leaks it.
//!   - The read and write offsets are truncated to 32 bits as the C's
//!     `ulong offset = off` does.
//!   - setladdrport and setraddrport cut sub-slices where the C writes
//!     NULs into its argument.
//!   - closeconv copies the multicast addresses before it hands them to
//!     ipifcdelmulti, which frees the Ipmulti they live in.
//!   - Fsrcvpcol is Fsrcvpcolx: there is no ipmux.
//!   - scalednconv: `cpuserver` is not part of the arch interface yet,
//!     so it is read through arch only if arch has it; otherwise the
//!     answer is that of a terminal, Nchans.

const std = @import("std");
const fcall = @import("fcall");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("../port/portdat.zig");
const lib = @import("../port/lib.zig");
const proc = @import("../port/proc.zig");
const alloc = @import("../port/alloc.zig");
const ab = @import("../port/allocb.zig");
const qio = @import("../port/qio.zig");
const ql = @import("../port/qlock.zig");
const devmod = @import("../port/dev.zig");
const devcons = @import("../port/devcons.zig");
const parse = @import("../port/parse.zig");
const netif = @import("../port/netif.zig");
const random = @import("../port/random.zig");
const tod = @import("../port/tod.zig");
const p9 = @import("../port/print.zig");
const ipdat = @import("ipdat.zig");
const ipaux = @import("ipaux.zig");
const netlog_ = @import("netlog.zig");
const inferno = @import("inferno.zig");
const nullmedium = @import("nullmedium.zig");
const pktmedium = @import("pktmedium.zig");
const ip_ = @import("ip.zig");
const arp = @import("arp.zig");
const ipifc = @import("ipifc.zig");
const iproute = @import("iproute.zig");

const print = p9.print;
const panic = p9.panic;
const qlock = ql.qlock;
const qunlock = ql.qunlock;
const canqlock = ql.canqlock;
const devdir = devmod.devdir;
const mkqid = devmod.mkqid;
const readstr = devcons.readstr;
const iseve = devcons.iseve;
const kstrdup = proc.kstrdup;
const commonuser = inferno.commonuser;

pub const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Qid = portdat.Qid;
const Dir = portdat.Dir;
const QLock = portdat.QLock;
const Block = ab.Block;
const Dirtab = devmod.Dirtab;
const Cmdbuf = parse.Cmdbuf;
const QTDIR = fcall.QTDIR;
const QTFILE = fcall.QTFILE;
const DEVDOTDOT = portdat.DEVDOTDOT;
const COPEN = portdat.COPEN;

const Conv = ipdat.Conv;
const Fs = ipdat.Fs;
const IPaux = ipdat.IPaux;
const Ndb = ipdat.Ndb;
const Proto = ipdat.Proto;
const IPaddrlen = ipdat.IPaddrlen;
const ERRMAX = ipdat.ERRMAX;
const Idle = ipdat.Idle;
const Announcing = ipdat.Announcing;
const Announced = ipdat.Announced;
const Connecting = ipdat.Connecting;
const Connected = ipdat.Connected;
const ipcmp = ipdat.ipcmp;
const ipmove = ipdat.ipmove;
const IPnoaddr = &ipaux.IPnoaddr;
const parseip = ipaux.parseip;
const ipismulticast = ipaux.ipismulticast;

const Qtopdir = 1; // top level directory
const Qtopbase = 2;
const Qarp = Qtopbase;
const Qbootp = 3;
const Qndb = 4;
const Qiproute = 5;
const Qipselftab = 6;
const Qlog = 7;

const Qprotodir = 8; // directory for a protocol
const Qprotobase = 9;
const Qclone = Qprotobase;
const Qstats = 10;
const Qtrans = 11;

const Qconvdir = 12; // directory for a conversation
const Qconvbase = 13;
const Qctl = Qconvbase;
const Qdata = 14;
const Qerr = 15;
const Qlisten = 16;
const Qlocal = 17;
const Qremote = 18;
const Qstatus = 19;
const Qsnoop = 20;

const Logtype = 5;
const Masktype = (1 << Logtype) - 1;
const Logconv = 12;
const Maskconv = (1 << Logconv) - 1;
const Shiftconv = Logtype;
const Logproto = 8;
const Maskproto = (1 << Logproto) - 1;
const Shiftproto = Logtype + Logconv;

const Nfs = 128;

fn TYPE(x: Qid) u32 {
    return @as(u32, @truncate(x.path)) & Masktype;
}

fn CONV(x: Qid) usize {
    return (@as(u32, @truncate(x.path)) >> Shiftconv) & Maskconv;
}

fn PROTO(x: Qid) usize {
    return (@as(u32, @truncate(x.path)) >> Shiftproto) & Maskproto;
}

fn QID(p: usize, c: usize, y: u32) u64 {
    return (@as(u64, p) << Shiftproto) | (@as(u64, c) << Shiftconv) | y;
}

const DEVDOT = -2;

const network = "network";

var ipfs: [Nfs]?*Fs = @splat(null); // attached fs's

/// The protocols of this kernel, in the order they are to be set up;
/// set by the configuration before the first attach.
pub var ipprotoinit: []const *const fn (f: *Fs) void = &.{};

// DIFF: the three below spell out the C's chains of -> (see the head
// of the file).
fn fsof(c: *const Chan) *Fs {
    return ipfs[c.dev].?;
}

fn protoof(c: *const Chan) *Proto {
    return fsof(c).p[PROTO(c.qid)].?;
}

fn convof(c: *const Chan) *Conv {
    return protoof(c).conv[CONV(c.qid)].?;
}

fn ip3gen(c: *Chan, i: i32, dp: *Dir) i32 {
    const cv = convof(c);
    if (cv.owner.ptr == portdat.nostr.ptr)
        kstrdup(&cv.owner, proc.eve);
    if (i < 0)
        return -1;
    const q = mkqid(QID(PROTO(c.qid), CONV(c.qid), @intCast(i)), 0, QTFILE);

    var p: []const u8 = undefined;
    done: {
        switch (i) {
            else => return -1,
            Qctl => {
                devdir(c, q, "ctl", 0, cv.owner, cv.perm, dp);
                break :done;
            },
            Qdata => {
                devdir(c, q, "data", qio.qlen(cv.rq.?), cv.owner, cv.perm, dp);
                break :done;
            },
            Qerr => {
                devdir(c, q, "err", qio.qlen(cv.eq.?), cv.owner, cv.perm, dp);
                break :done;
            },
            Qlisten => {
                devdir(c, q, "listen", 0, cv.owner, cv.perm, dp);
                break :done;
            },
            Qlocal => p = "local",
            Qremote => p = "remote",
            Qsnoop => {
                if (cv.p != fsof(c).ipifc)
                    return -1;
                devdir(c, q, "snoop", qio.qlen(cv.sq.?), cv.owner, 0o400, dp);
                break :done;
            },
            Qstatus => p = "status",
        }
        devdir(c, q, p, 0, cv.owner, 0o444, dp);
    }
    dp.mtime = cv.ctime;
    return 1;
}

fn ip2gen(c: *Chan, i: i32, dp: *Dir) i32 {
    switch (i) {
        Qclone => {
            const q = mkqid(QID(PROTO(c.qid), 0, Qclone), 0, QTFILE);
            devdir(c, q, "clone", 0, network, 0o666, dp);
            return 1;
        },
        Qstats => {
            const q = mkqid(QID(PROTO(c.qid), 0, Qstats), 0, QTFILE);
            devdir(c, q, "stats", 0, network, 0o444, dp);
            return 1;
        },
        Qtrans => {
            const len = ipaux.transfsize(protoof(c)) orelse
                return -1;
            const q = mkqid(QID(PROTO(c.qid), 0, Qtrans), 0, QTFILE);
            devdir(c, q, "trans", @intCast(len), network, 0o664, dp);
            return 1;
        },
        else => {},
    }
    return -1;
}

fn ip1gen(c: *Chan, i: i32, dp: *Dir) i32 {
    var p: []const u8 = undefined;
    var len: usize = 0;

    const f = fsof(c);

    var prot: u32 = 0o666;
    if (i < 0)
        return -1;
    var q = mkqid(QID(0, 0, @intCast(i)), 0, QTFILE);
    switch (i) {
        else => return -1,
        Qarp => {
            p = "arp";
            prot = 0o664;
        },
        Qbootp => p = "bootp",
        Qndb => {
            p = "ndb";
            len = f.ndb.len;
            q.vers = f.ndb.vers;
        },
        Qiproute => {
            p = "iproute";
            prot = 0o664;
        },
        Qipselftab => {
            p = "ipselftab";
            prot = 0o444;
        },
        Qlog => p = "log",
    }
    devdir(c, q, p, @intCast(len), network, prot, dp);
    if (i == Qndb and f.ndb.mtime > devmod.kerndate)
        dp.mtime = f.ndb.mtime;
    return 1;
}

/// The entry for #I itself; the name is in up.genbuf.
fn topdir(c: *Chan, dp: *Dir) i32 {
    const up = arch.up().?;
    const q = mkqid(QID(0, 0, Qtopdir), 0, QTDIR);
    const name = fmt.snprint(up.genbuf[0 .. up.genbuf.len - 1], "#I%lud", .{c.dev});
    devdir(c, q, name, 0, network, 0o555, dp);
    return 1;
}

/// The C's label Protodir in ipgen.
fn protodir(c: *Chan, f: *Fs, s: usize, dp: *Dir) i32 {
    const p = f.p[s].?;
    if (p.connect == null)
        return 0; // protocol with no user interface
    const q = mkqid(QID(s, 0, Qprotodir), 0, QTDIR);
    devdir(c, q, p.name, 0, network, 0o555, dp);
    return 1;
}

/// The C's label Convdir in ipgen.
fn convdir(c: *Chan, f: *Fs, s: usize, dp: *Dir) i32 {
    const up = arch.up().?;
    const cv = f.p[PROTO(c.qid)].?.conv[s].?;
    const name = fmt.snprint(up.genbuf[0 .. up.genbuf.len - 1], "%d", .{s});
    const q = mkqid(QID(PROTO(c.qid), s, Qconvdir), 0, QTDIR);
    devdir(c, q, name, 0, cv.owner, 0o555, dp);
    dp.mtime = cv.ctime;
    return 1;
}

fn ipgen(c: *Chan, _: ?[]const u8, _: []const Dirtab, s_: i32, dp: *Dir) i32 {
    var s = s_;

    const f = fsof(c);

    switch (TYPE(c.qid)) {
        Qtopdir => {
            if (s == DEVDOTDOT or s == DEVDOT)
                return topdir(c, dp);
            if (s < 0)
                return -1;
            if (@as(usize, @intCast(s)) < f.np)
                return protodir(c, f, @intCast(s), dp);
            s -= @intCast(f.np);
            return ip1gen(c, s + Qtopbase, dp);
        },
        Qarp, Qbootp, Qndb, Qlog, Qiproute, Qipselftab => return ip1gen(c, @intCast(TYPE(c.qid)), dp),
        Qprotodir => {
            if (s == DEVDOTDOT)
                return topdir(c, dp);
            if (s == DEVDOT)
                return protodir(c, f, PROTO(c.qid), dp);
            if (s < 0)
                return -1;
            const ac = f.p[PROTO(c.qid)].?.ac;
            if (@as(usize, @intCast(s)) < ac)
                return convdir(c, f, @intCast(s), dp);
            s -= @intCast(ac);
            return ip2gen(c, s + Qprotobase, dp);
        },
        Qclone, Qstats, Qtrans => return ip2gen(c, @intCast(TYPE(c.qid)), dp),
        Qconvdir => {
            if (s == DEVDOTDOT) {
                const x = PROTO(c.qid);
                const q = mkqid(QID(x, 0, Qprotodir), 0, QTDIR);
                devdir(c, q, f.p[x].?.name, 0, network, 0o555, dp);
                return 1;
            }
            if (s == DEVDOT)
                return convdir(c, f, CONV(c.qid), dp);
            if (s < 0)
                return -1;
            return ip3gen(c, s + Qconvbase, dp);
        },
        Qctl, Qdata, Qerr, Qlisten, Qlocal, Qremote, Qstatus, Qsnoop => return ip3gen(c, @intCast(TYPE(c.qid)), dp),
        else => {},
    }
    return -1;
}

fn ipreset() void {
    nullmedium.nullmediumlink();
    pktmedium.pktmediumlink();

    // DIFF: no fmtinstall; see the head of the file.
}

pub fn newipaux(owner: []const u8, tag: []const u8) *IPaux {
    const a = alloc.snew(IPaux);
    a.* = .{};
    kstrdup(&a.owner, owner);
    const n = @min(tag.len, a.tag.len);
    @memcpy(a.tag[0..n], tag[0..n]);
    return a;
}

fn ipaux_(c: *const Chan) *IPaux {
    return @ptrCast(@alignCast(c.aux.?));
}

fn ATTACHER(c: *const Chan) []const u8 {
    return ipaux_(c).owner;
}

var attachlk: QLock = .{};

fn ipattach(spec: []const u8) Error!*Chan {
    const dev = netif.strtoul(spec, 10).v;
    if (dev >= Nfs)
        return error.Enodev;

    qlock(&attachlk);
    if (ipfs[dev] == null) {
        const f = alloc.snew(Fs);
        f.* = .{};
        ip_.ip_init(f);
        arp.arpinit(f);
        netlog_.netloginit(f);
        for (ipprotoinit) |init|
            init(f);
        f.dev = dev;
        arch.coherence();
        ipfs[dev] = f;
    }
    qunlock(&attachlk);

    const c = devmod.devattach('I', spec);
    c.qid = mkqid(QID(0, 0, Qtopdir), 0, QTDIR);
    c.dev = dev;

    c.aux = newipaux(commonuser(), "none");

    return c;
}

fn ipwalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    const a = ipaux_(c);

    const w = try devmod.devwalk(c, nc, name, &.{}, ipgen);
    if (w.clone) |clone|
        clone.aux = newipaux(a.owner, std.mem.sliceTo(&a.tag, 0));
    return w;
}

fn ipstat(c: *Chan, db: []u8) Error!usize {
    if (c.qid.type == QTDIR) {
        var d: Dir = .{};
        _ = ipgen(c, null, &.{}, DEVDOT, &d);
        const n = fcall.convD2M(&d, db);
        if (n == 0)
            return error.Ebadarg;
        return n;
    }

    return devmod.devstat(c, db, &.{}, ipgen);
}

fn incoming(arg: ?*anyopaque) bool {
    const conv: *Conv = @ptrCast(@alignCast(arg.?));
    return conv.incall != null;
}

// DIFF: the entry for OEXEC; see the head of the file.
const m2p = [4]u32{ 4, 2, 6, 4 };

fn ipopen(c: *Chan, omode: u32) Error!*Chan {
    var perm = m2p[omode & 3];

    // DIFF: at the end in C; see the head of the file.
    const mode = try devmod.openmode(omode);

    const f = fsof(c);

    switch (TYPE(c.qid)) {
        else => {},
        Qndb => try ndbopen(&f.ndb, omode),
        Qlog => try netlog_.netlogopen(f),
        Qiproute, Qarp => {
            if (omode != lib.OREAD and !iseve())
                return error.Eperm;
        },
        Qtrans => {
            if (omode != lib.OREAD and !iseve())
                return error.Eperm;
            if (omode & lib.OTRUNC != 0)
                _ = try ipaux.transwrite(protoof(c), &.{}, 0);
        },
        Qtopdir, Qprotodir, Qconvdir, Qstatus, Qremote, Qlocal, Qstats, Qbootp, Qipselftab => {
            if (omode != lib.OREAD)
                return error.Eperm;
        },
        Qsnoop => {
            if (omode != lib.OREAD)
                return error.Eperm;
            const cv = convof(c);
            if (!std.mem.eql(u8, ATTACHER(c), cv.owner) and !iseve())
                return error.Eperm;
            _ = portdat.incref(&cv.snoopers);
        },
        Qclone => {
            const p = protoof(c);
            qlock(&p.qlock);
            const cv = Fsprotoclone(p, ATTACHER(c));
            qunlock(&p.qlock);
            const ncv = cv orelse return error.Enodev;
            c.qid = mkqid(QID(p.x, ncv.x, Qctl), 0, QTFILE);
        },
        Qdata, Qctl, Qerr => {
            const p = protoof(c);
            qlock(&p.qlock);
            defer qunlock(&p.qlock);
            const cv = p.conv[CONV(c.qid)].?;
            qlock(&cv.qlock);
            defer qunlock(&cv.qlock);
            if (std.mem.eql(u8, ATTACHER(c), cv.owner))
                perm <<= 6;
            if ((perm & cv.perm) != perm and !iseve())
                return error.Eperm;

            cv.inuse += 1;
            if (cv.inuse == 1) {
                kstrdup(&cv.owner, ATTACHER(c));
                cv.perm = 0o660;
            }
        },
        Qlisten => {
            const cv = convof(c);
            {
                qlock(&cv.qlock);
                defer qunlock(&cv.qlock);
                if (std.mem.eql(u8, ATTACHER(c), cv.owner))
                    perm <<= 6;
                if ((perm & cv.perm) != perm and !iseve())
                    return error.Eperm;

                if (cv.state != Announced)
                    return proc.errorf("not announced", .{});

                cv.inuse += 1;
            }
            {
                errdefer closeconv(cv);

                var nc: ?*Conv = null;
                while (nc == null) {
                    // give up if we got a hangup
                    if (qio.qisclosed(cv.rq.?))
                        return proc.errorf("listen hungup", .{});

                    qlock(&cv.listenq);
                    defer qunlock(&cv.listenq);

                    // wait for a connect
                    try proc.sleep(&cv.listenr, incoming, cv);

                    qlock(&cv.qlock);
                    nc = cv.incall;
                    if (nc) |n| {
                        cv.incall = n.next;
                        c.qid = mkqid(QID(PROTO(c.qid), n.x, Qctl), 0, QTFILE);
                    }
                    qunlock(&cv.qlock);
                }
            }
            closeconv(cv);
        },
    }
    c.mode = @intCast(mode);
    c.flag |= COPEN;
    c.offset = 0;
    return c;
}

fn ipcreate(_: *Chan, _: []const u8, _: u32, _: u32) Error!*Chan {
    return error.Eperm;
}

fn ipremove(_: *Chan) Error!void {
    return error.Eperm;
}

fn ipwstat(c: *Chan, dp: []const u8) Error!usize {
    const f = fsof(c);
    switch (TYPE(c.qid)) {
        else => return error.Eperm,
        Qctl, Qdata => {},
    }

    // DIFF: the C allocates the Dir with its strings after it; here
    // only the strings are allocated.
    const strs = alloc.smalloc(dp.len + 4)[0 .. dp.len + 4];
    defer alloc.free(strs.ptr);
    var dir: Dir = .{};
    const n = fcall.convM2D(dp, &dir, strs);
    if (n == 0)
        return error.Eshortstat;

    const cv = f.p[PROTO(c.qid)].?.conv[CONV(c.qid)].?;
    qlock(&cv.qlock);
    defer qunlock(&cv.qlock);
    if (!std.mem.eql(u8, ATTACHER(c), cv.owner) and !iseve())
        return error.Eperm;
    if (dir.uid.len != 0) {
        if (!std.mem.eql(u8, dir.uid, commonuser()) and !iseve())
            return error.Eperm;
        kstrdup(&cv.owner, dir.uid);
    }
    if (dir.mode != ~@as(u32, 0))
        cv.perm = dir.mode & 0o666;

    return n;
}

pub fn closeconv(cv: *Conv) void {
    qlock(&cv.qlock);

    cv.inuse -= 1;
    if (cv.inuse > 0) {
        qunlock(&cv.qlock);
        return;
    }

    // close all incoming calls since no listen will ever happen
    while (cv.incall) |nc| {
        cv.incall = nc.next;
        closeconv(nc);
    }
    cv.incall = null;

    kstrdup(&cv.owner, network);
    cv.perm = 0o660;

    while (cv.multi) |mp| {
        // DIFF: copies; see the head of the file.
        const ma = mp.ma;
        const ia = mp.ia;
        ipifc.ipifcdelmulti(cv, &ma, &ia);
    }

    if (cv.p.?.close) |close|
        close(cv);

    cv.state = Idle;
    qunlock(&cv.qlock);
}

fn ipclose(c: *Chan) Error!void {
    const f = fsof(c);
    switch (TYPE(c.qid)) {
        else => {},
        Qlog => {
            if (c.flag & COPEN != 0)
                netlog_.netlogclose(f);
        },
        Qdata, Qctl, Qerr => {
            if (c.flag & COPEN != 0)
                closeconv(convof(c));
        },
        Qsnoop => {
            if (c.flag & COPEN != 0)
                _ = portdat.decref(&convof(c).snoopers);
        },
    }
    const a = ipaux_(c);
    if (a.owner.ptr != portdat.nostr.ptr)
        alloc.free(a.owner.ptr);
    alloc.free(a);
}

const Maxstring = 128;
const Maxstate = 32 * 1024;
const Maxstats = 32 * 1024;

/// The low 32 bits of a file offset: the C's `ulong offset = off`.
fn off32(off: i64) usize {
    return @as(u32, @truncate(@as(u64, @bitCast(off))));
}

fn ipread(ch: *Chan, a: []u8, off: i64) Error!usize {
    const offset = off32(off);

    const f = fsof(ch);

    switch (TYPE(ch.qid)) {
        else => return error.Eperm,
        Qtopdir, Qprotodir, Qconvdir => return devmod.devdirread(ch, a, &.{}, ipgen),
        Qarp => return arp.arpread(f.arp.?, a, offset),
        Qbootp => return inferno.bootpread(a, offset),
        Qndb => return ndbread(&f.ndb, a, offset),
        Qiproute => return iproute.routeread(f, a, offset),
        Qipselftab => return ipifc.ipselftabread(f, a, offset),
        Qlog => return netlog_.netlogread(f, a, offset),
        Qctl => {
            var buf: [16]u8 = undefined;
            const s = fmt.snprint(buf[0..15], "%lud", .{CONV(ch.qid)});
            return readstr(offset, a, s);
        },
        Qremote => {
            const buf = alloc.smalloc(Maxstring)[0 .. Maxstring - 1];
            defer alloc.free(buf.ptr);
            const x = protoof(ch);
            const c = x.conv[CONV(ch.qid)].?;
            const n = if (x.remote) |remote|
                remote(c, buf)
            else
                fmt.snprint(buf, "%I!%d\n", .{ ipaux.ip(&c.iphash.raddr), c.iphash.rport }).len;
            return readstr(offset, a, buf[0..n]);
        },
        Qlocal => {
            const x = protoof(ch);
            const c = x.conv[CONV(ch.qid)].?;
            if (x == f.ipifc and x.local != null) {
                const buf = alloc.smalloc(Maxstate)[0 .. Maxstate - 1];
                defer alloc.free(buf.ptr);
                const n = x.local.?(c, buf);
                return readstr(offset, a, buf[0..n]);
            }
            const buf = alloc.smalloc(Maxstring)[0 .. Maxstring - 1];
            defer alloc.free(buf.ptr);
            const n = if (x.local) |local|
                local(c, buf)
            else
                fmt.snprint(buf, "%I!%d\n", .{ ipaux.ip(&c.iphash.laddr), c.iphash.lport }).len;
            return readstr(offset, a, buf[0..n]);
        },
        Qstatus => {
            const buf = alloc.smalloc(Maxstate)[0 .. Maxstate - 1];
            defer alloc.free(buf.ptr);
            const x = protoof(ch);
            const c = x.conv[CONV(ch.qid)].?;
            const n = x.state.?(c, buf);
            return readstr(offset, a, buf[0..n]);
        },
        Qdata => return qio.qread(convof(ch).rq.?, a),
        Qerr => return qio.qread(convof(ch).eq.?, a),
        Qsnoop => return qio.qread(convof(ch).sq.?, a),
        Qstats => {
            const x = protoof(ch);
            const stats = x.stats orelse
                return proc.errorf("stats not implemented", .{});
            const buf = alloc.smalloc(Maxstats)[0 .. Maxstats - 1];
            defer alloc.free(buf.ptr);
            const n = stats(x, buf);
            return readstr(offset, a, buf[0..n]);
        },
        Qtrans => return ipaux.transread(protoof(ch), a, offset),
    }
}

fn ipbread(ch: *Chan, n: usize, offset: u64) Error!*Block {
    switch (TYPE(ch.qid)) {
        // DIFF: an empty block for nil; see the head of the file.
        Qdata => return try qio.qbread(convof(ch).rq.?, n) orelse ab.allocb(0),
        else => return devmod.devbread(ch, n, offset),
    }
}

/// set local address to be that of the ifc closest to remote address
fn setladdr(c: *Conv) void {
    ipifc.findlocalip(c.p.?.f.?, &c.iphash.laddr, &c.iphash.raddr);
}

/// set a local port making sure the quad of raddr,rport,laddr,lport is unique
pub fn setluniqueport(c: *Conv, lport: u16) Error!void {
    const p = c.p.?;

    qlock(&p.qlock);
    defer qunlock(&p.qlock);
    var x: usize = 0;
    while (x < p.nc) : (x += 1) {
        const xp = p.conv[x] orelse
            break;
        if (xp == c)
            continue;
        if ((xp.state == Connected or xp.state == Announced) and
            xp.iphash.lport == lport and
            xp.iphash.rport == c.iphash.rport and
            ipcmp(&xp.iphash.raddr, &c.iphash.raddr) == 0 and
            ipcmp(&xp.iphash.laddr, &c.iphash.laddr) == 0)
            return proc.errorf("address in use", .{});
    }
    var l = p.translations;
    while (l) |q| : (l = q.next) {
        if (q.backward.lport == lport and
            q.backward.rport == c.iphash.rport and
            ipcmp(&q.backward.raddr, &c.iphash.raddr) == 0 and
            ipcmp(&q.backward.laddr, &c.iphash.laddr) == 0)
            return proc.errorf("address in use", .{});
    }
    c.iphash.lport = lport;
}

/// is lport in use by anyone?
pub fn lportinuse(p: *Proto, lport: u16) bool {
    var x: usize = 0;
    while (x < p.nc) : (x += 1) {
        const xp = p.conv[x] orelse
            break;
        if (xp.iphash.lport == lport)
            return true;
    }
    var l = p.translations;
    while (l) |q| : (l = q.next) {
        if (q.backward.lport == lport)
            return true;
    }
    return false;
}

/// find a unused local port for a protocol.
///
/// p needs to be locked
pub fn unusedlport(p: *Proto) ?u16 {
    // Unrestricted ports are chosen randomly
    // between 2^15 and 2^16.  There are at most
    // 4*Nchan = 4096 ports in use at any given time,
    // so even in the worst case, a random probe has a
    // 1 - 4096/2^15 = 87% chance of success.
    // If 64 successive probes fail, there is a bug somewhere
    // (or a once in 10^58 event has happened, but that's
    // less likely than a venti collision).
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const port: u16 = @intCast((1 << 15) + random.nrand(1 << 15));
        if (!lportinuse(p, port))
            return port;
    }
    return null;
}

/// pick a local port and set it
fn setlport(c: *Conv) Error!void {
    const p = c.p.?;
    qlock(&p.qlock);
    defer qunlock(&p.qlock);
    if (c.restricted) {
        // Restricted ports cycle between 600 and 1024.
        var i: usize = 0;
        while (i < 1024 - 600) : (i += 1) {
            if (p.nextrport >= 1024 or p.nextrport < 600)
                p.nextrport = 600;
            const port = p.nextrport;
            p.nextrport += 1;
            if (!lportinuse(p, port)) {
                c.iphash.lport = port;
                return;
            }
        }
    } else {
        if (unusedlport(p)) |port| {
            c.iphash.lport = port;
            return;
        }
    }
    return proc.errorf("no ports available", .{});
}

/// The C's `x = strtol(str, &p, 10); if(p <= str || strchr("!", *p) ==
/// nil) return "bad numeric port";`: the port, truncated to 16 bits as
/// the C's assignment to a ushort does, and what follows the number.
fn numericport(str: []const u8) Error!struct { port: u16, rest: []const u8 } {
    const r = netif.strtoul(str, 10);
    if (r.n == 0 or (r.n < str.len and str[r.n] != '!'))
        return proc.errorf("bad numeric port", .{});
    return .{ .port = @truncate(r.v), .rest = str[r.n..] };
}

/// set a local address and port from a string of the form
///     [address!]port[!r]
pub fn setladdrport(c: *Conv, str_: []const u8, announcing: bool) Error!void {
    var str = str_;
    var addr: [IPaddrlen]u8 = undefined;

    // ignore restricted part if it exists.  it's
    // meaningless on local ports.
    var p: ?[]const u8 = null;
    if (std.mem.findScalar(u8, str, '!')) |i| {
        p = str[i + 1 ..];
        str = str[0..i];
        if (std.mem.eql(u8, p.?, "r"))
            p = null;
    }

    c.iphash.lport = 0;
    const port = p orelse blk: {
        if (announcing)
            ipmove(&c.iphash.laddr, IPnoaddr)
        else
            setladdr(c);
        break :blk str;
    };
    if (p != null) {
        if (std.mem.eql(u8, str, "*"))
            ipmove(&c.iphash.laddr, IPnoaddr)
        else {
            if (parseip(&addr, str) == -1)
                return error.Ebadip;
            if (ipifc.ipforme(c.p.?.f.?, &addr) != 0 or ipismulticast(&addr) != 0)
                ipmove(&c.iphash.laddr, &addr)
            else
                return proc.errorf("not a local IP address", .{});
        }
    }

    // one process can get all connections
    if (announcing and std.mem.eql(u8, port, "*")) {
        if (!iseve())
            return error.Eperm;
        return setluniqueport(c, 0);
    }

    const r = try numericport(port);

    if (r.port == 0)
        return setlport(c);
    return setluniqueport(c, r.port);
}

fn setraddrport(c: *Conv, str: []const u8) Error!void {
    const i = std.mem.findScalar(u8, str, '!') orelse
        return proc.errorf("malformed address", .{});
    if (parseip(&c.iphash.raddr, str[0..i]) == -1)
        return error.Ebadip;

    // the C stores the port before it checks the syntax
    c.iphash.rport = @truncate(netif.strtoul(str[i + 1 ..], 10).v);
    const r = try numericport(str[i + 1 ..]);

    if (std.mem.find(u8, r.rest, "!r") != null)
        c.restricted = true;
}

/// called by protocol connect routine to set addresses
pub fn Fsstdconnect(c: *Conv, argv: []const []const u8) Error!void {
    switch (argv.len) {
        else => return proc.errorf("bad args to connect", .{}),
        2 => {
            try setraddrport(c, argv[1]);
            setladdr(c);
            try setlport(c);
        },
        3 => {
            try setraddrport(c, argv[1]);
            try setladdrport(c, argv[2], false);
        },
    }

    c.ipversion = ipaux.convipvers(c);
}

/// initiate connection and sleep till its set up
fn connected(a: ?*anyopaque) bool {
    const c: *Conv = @ptrCast(@alignCast(a.?));
    return c.state == Connected;
}

/// Called, and returns, with c locked.
fn connectctlmsg(x: *Proto, c: *Conv, cb: *Cmdbuf) Error!void {
    if (c.state != Idle)
        return error.Econinuse;
    const connect = x.connect orelse
        return proc.errorf("connect not supported", .{});
    c.cerr[0] = 0;
    c.state = Connecting;
    connect(c, cb.f) catch |e| {
        c.state = Idle;
        return e;
    };
    qunlock(&c.qlock);
    const r = proc.sleep(&c.cr, connected, c);
    qlock(&c.qlock);
    try r;

    if (c.cerr[0] != 0)
        return proc.errorf("%s", .{std.mem.sliceTo(&c.cerr, 0)});
}

/// called by protocol announce routine to set addresses
pub fn Fsstdannounce(c: *Conv, argv: []const []const u8) Error!void {
    @memset(&c.iphash.raddr, 0);
    c.iphash.rport = 0;
    switch (argv.len) {
        else => {},
        2 => return setladdrport(c, argv[1], true),
    }
    return proc.errorf("bad args to announce", .{});
}

/// initiate announcement and sleep till its set up
fn announced(a: ?*anyopaque) bool {
    const c: *Conv = @ptrCast(@alignCast(a.?));
    return c.state == Announced;
}

/// Called, and returns, with c locked.
fn announcectlmsg(x: *Proto, c: *Conv, cb: *Cmdbuf) Error!void {
    if (c.state != Idle)
        return error.Econinuse;
    const announce = x.announce orelse
        return proc.errorf("announce not supported", .{});
    c.cerr[0] = 0;
    c.state = Announcing;
    announce(c, cb.f) catch |e| {
        c.state = Idle;
        return e;
    };
    qunlock(&c.qlock);
    const r = proc.sleep(&c.cr, announced, c);
    qlock(&c.qlock);
    try r;

    if (c.cerr[0] != 0)
        return proc.errorf("%s", .{std.mem.sliceTo(&c.cerr, 0)});
}

/// called by protocol bind routine to set addresses
pub fn Fsstdbind(c: *Conv, argv: []const []const u8) Error!void {
    switch (argv.len) {
        else => {},
        2 => return setladdrport(c, argv[1], false),
    }
    return proc.errorf("bad args to bind", .{});
}

fn bindctlmsg(x: *Proto, c: *Conv, cb: *Cmdbuf) Error!void {
    if (x.bind) |bind|
        try bind(c, cb.f)
    else
        try Fsstdbind(c, cb.f);
}

fn tosctlmsg(c: *Conv, cb: *Cmdbuf) void {
    if (cb.nf < 2)
        c.tos = 0
    else
        c.tos = @bitCast(netif.atoi(cb.f[1]));
}

fn ttlctlmsg(c: *Conv, cb: *Cmdbuf) void {
    if (cb.nf < 2)
        c.ttl = ipdat.MAXTTL
    else
        c.ttl = @bitCast(netif.atoi(cb.f[1]));
}

fn ipwrite(ch: *Chan, a: []const u8, off: i64) Error!usize {
    var ia: [IPaddrlen]u8 = undefined;
    var ma: [IPaddrlen]u8 = undefined;
    const offset = off32(off);
    const n = a.len;

    const f = fsof(ch);

    switch (TYPE(ch.qid)) {
        else => return error.Eperm,
        Qdata => {
            const c = convof(ch);

            const wq = c.wq orelse
                return error.Eperm;

            _ = try qio.qwrite(wq, a);
        },
        Qarp => return arp.arpwrite(f, a),
        Qiproute => return iproute.routewrite(f, ch, a),
        Qtrans => return ipaux.transwrite(protoof(ch), a, offset),
        Qlog => {
            try netlog_.netlogctl(f, a);
            return n;
        },
        Qndb => return ndbwrite(&f.ndb, a, offset),
        Qctl => {
            const x = protoof(ch);
            const c = x.conv[CONV(ch.qid)].?;
            const cb = try parse.parsecmd(a);
            defer alloc.free(cb);

            qlock(&c.qlock);
            defer qunlock(&c.qlock);
            if (cb.nf < 1)
                return proc.errorf("short control request", .{});
            const cmd = cb.f[0];
            if (std.mem.eql(u8, cmd, "connect"))
                try connectctlmsg(x, c, cb)
            else if (std.mem.eql(u8, cmd, "announce"))
                try announcectlmsg(x, c, cb)
            else if (std.mem.eql(u8, cmd, "bind"))
                try bindctlmsg(x, c, cb)
            else if (std.mem.eql(u8, cmd, "ttl"))
                ttlctlmsg(c, cb)
            else if (std.mem.eql(u8, cmd, "tos"))
                tosctlmsg(c, cb)
            else if (std.mem.eql(u8, cmd, "ignoreadvice"))
                c.ignoreadvice = true
            else if (std.mem.eql(u8, cmd, "addmulti")) {
                if (cb.nf < 2)
                    return proc.errorf("addmulti needs interface address", .{});
                if (cb.nf == 2) {
                    if (parseip(&ia, cb.f[1]) == -1)
                        return error.Ebadip;
                    if (ipcmp(&c.iphash.raddr, IPnoaddr) == 0 or ipismulticast(&c.iphash.laddr) != 0)
                        try ipifc.ipifcaddmulti(c, &c.iphash.laddr, &ia)
                    else
                        try ipifc.ipifcaddmulti(c, &c.iphash.raddr, &ia);
                } else {
                    if (parseip(&ia, cb.f[1]) == -1 or
                        parseip(&ma, cb.f[2]) == -1)
                        return error.Ebadip;
                    try ipifc.ipifcaddmulti(c, &ma, &ia);
                }
            } else if (std.mem.eql(u8, cmd, "delmulti") or
                std.mem.eql(u8, cmd, "remmulti"))
            {
                if (cb.nf < 2)
                    return proc.errorf("delmulti needs interface address", .{});
                if (parseip(&ia, cb.f[1]) == -1)
                    return error.Ebadip;
                if (ipcmp(&c.iphash.raddr, IPnoaddr) == 0 or ipismulticast(&c.iphash.laddr) != 0)
                    ipifc.ipifcdelmulti(c, &c.iphash.laddr, &ia)
                else
                    ipifc.ipifcdelmulti(c, &c.iphash.raddr, &ia);
            } else if (x.ctl) |ctl|
                try ctl(c, cb.f)
            else
                return proc.errorf("unknown control request", .{});
        },
    }
    return n;
}

fn ipbwrite(ch: *Chan, bp: *Block, offset: u64) Error!usize {
    switch (TYPE(ch.qid)) {
        Qdata => {
            const c = convof(ch);

            const wq = c.wq orelse {
                ab.freeb(bp); // DIFF: see the head of the file
                return error.Eperm;
            };

            return qio.qbwrite(wq, bp);
        },
        else => return devmod.devbwrite(ch, bp, offset),
    }
}

pub const ipdevtab: devmod.Dev = .{
    .dc = 'I',
    .name = "ip",

    .reset = ipreset,
    .attach = ipattach,
    .walk = ipwalk,
    .stat = ipstat,
    .open = ipopen,
    .create = ipcreate,
    .close = ipclose,
    .read = ipread,
    .bread = ipbread,
    .write = ipwrite,
    .bwrite = ipbwrite,
    .remove = ipremove,
    .wstat = ipwstat,
};

pub fn Fsproto(f: *Fs, p: *Proto) i32 {
    if (f.np >= ipdat.Maxproto)
        return -1;

    p.f = f;

    if (p.ipproto >= 0) {
        const t: usize = @intCast(p.ipproto);
        if (f.t2p[t] != null)
            return -1;
        f.t2p[t] = p;
    }

    p.qid.type = QTDIR;
    p.qid.path = QID(f.np, 0, Qprotodir);
    if (p.nc > Maskconv + 1) {
        print("Fsproto: %s nc %d > %d\n", .{ p.name, p.nc, @as(u32, Maskconv + 1) });
        p.nc = Maskconv + 1;
    }
    p.conv = alloc.newslice(?*Conv, p.nc + 1) orelse
        panic("Fsproto", .{});
    @memset(p.conv, null);

    p.x = f.np;
    p.nextrport = 600;
    f.p[f.np] = p;
    f.np += 1;

    return 0;
}

/// return true if this protocol is
/// built in
pub fn Fsbuiltinproto(f: *Fs, proto: u8) bool {
    return f.t2p[proto] != null;
}

/// The part of Fsprotoclone that makes conversation x of p, between the
/// C's waserror and poperror; null if it cannot be made.
fn newconv(p: *Proto, x: usize) ?*Conv {
    const c = alloc.new(Conv) orelse
        return null;
    c.* = .{};
    newconv1(p, c, x) catch {
        qio.qfree(c.rq);
        qio.qfree(c.wq);
        qio.qfree(c.eq);
        qio.qfree(c.sq);
        alloc.free(c.ptcl);
        alloc.free(c);
        return null;
    };
    return c;
}

fn newconv1(p: *Proto, c: *Conv, x: usize) Error!void {
    c.p = p;
    c.x = x;
    if (p.ptclsize != 0)
        c.ptcl = alloc.malloc(p.ptclsize) orelse return error.Enomem;
    c.eq = qio.qopen(1024, qio.Qmsg, null, null) orelse
        return error.Enomem;
    try p.create.?(c);
    if (c.rq == null or c.wq == null)
        return error.Enomem;
}

/// called with protocol locked
pub fn Fsprotoclone(p: *Proto, user: []const u8) ?*Conv {
    const c: *Conv = retry: while (true) {
        var pp: usize = 0;
        while (pp < p.nc) : (pp += 1) {
            const xc = p.conv[pp] orelse {
                const nc = newconv(p, pp) orelse
                    return null;
                qlock(&nc.qlock);
                p.conv[pp] = nc;
                p.ac += 1;
                break :retry nc;
            };
            if (canqlock(&xc.qlock)) {
                // make sure both processes and protocol
                // are done with this Conv
                if (xc.inuse == 0 and (p.inuse == null or !p.inuse.?(xc)))
                    break :retry xc;

                qunlock(&xc.qlock);
            }
        }
        if (p.gc) |gc| {
            print("Fsprotoclone: garbage collecting %s Convs\n", .{p.name});
            if (gc(p))
                continue :retry;
        }
        return null;
    };

    c.inuse = 1;
    kstrdup(&c.owner, user);
    c.perm = 0o660;
    c.state = Idle;
    ipmove(&c.iphash.laddr, IPnoaddr);
    ipmove(&c.iphash.raddr, IPnoaddr);
    c.routehint.a = null;
    c.routehint.r = null;
    c.routehint.rgen = 0;
    c.iphash.lport = 0;
    c.iphash.rport = 0;
    c.restricted = false;
    c.ignoreadvice = false;
    c.ttl = ipdat.MAXTTL;
    c.tos = 0;
    c.ctime = @truncate(@as(u64, @bitCast(tod.seconds())));
    qio.qreopen(c.rq.?);
    qio.qreopen(c.wq.?);
    qio.qreopen(c.eq.?);

    qunlock(&c.qlock);
    return c;
}

pub fn Fsconnected(c: *Conv, msg: ?[]const u8) void {
    if (msg) |s| {
        if (s.len != 0) {
            // strncpy(c->cerr, msg, ERRMAX-1)
            const n = @min(s.len, ERRMAX - 1);
            @memcpy(c.cerr[0..n], s[0..n]);
            @memset(c.cerr[n .. ERRMAX - 1], 0);
        }
    }

    switch (c.state) {
        Announcing => c.state = Announced,
        Connecting => c.state = Connected,
        else => {},
    }

    _ = proc.wakeup(&c.cr);
}

/// DIFF: no ipmux; see the head of the file.
pub fn Fsrcvpcol(f: *Fs, proto: u8) ?*Proto {
    return f.t2p[proto];
}

pub fn Fsrcvpcolx(f: *Fs, proto: u8) ?*Proto {
    return f.t2p[proto];
}

var beenhere: bool = false;

/// called with protocol locked
pub fn Fsnewcall(c: *Conv, raddr: *const [IPaddrlen]u8, rport: u16, laddr: *const [IPaddrlen]u8, lport: u16, version: u8) ?*Conv {
    qlock(&c.qlock);
    var i: usize = 0;
    var l = &c.incall;
    while (l.*) |n| : (l = &n.next)
        i += 1;
    if (i >= ipdat.Maxincall) {
        qunlock(&c.qlock);
        if (!beenhere) {
            beenhere = true;
            print("Fsnewcall: incall queue full (%d) on port %d\n", .{ i, c.iphash.lport });
        }
        return null;
    }

    // find a free conversation
    const nc = Fsprotoclone(c.p.?, c.owner) orelse {
        qunlock(&c.qlock);
        return null;
    };
    ipmove(&nc.iphash.raddr, raddr);
    nc.iphash.rport = rport;
    ipmove(&nc.iphash.laddr, laddr);
    nc.iphash.lport = lport;
    nc.next = null;
    l.* = nc;
    nc.state = Connected;
    nc.ipversion = version;

    qunlock(&c.qlock);

    _ = proc.wakeup(&c.listenr);

    return nc;
}

fn ndbopen(ndb: *Ndb, omode_: u32) Error!void {
    const trunc = omode_ & lib.OTRUNC != 0;
    const omode = try devmod.openmode(omode_);

    if ((omode == lib.OWRITE or omode == lib.ORDWR or trunc) and !iseve())
        return error.Eperm;

    if (trunc) {
        qlock(&ndb.qlock);
        alloc.free(ndb.buf);
        ndb.buf = null;
        ndb.len = 0;
        ndb.vers +%= 1;
        ndb.mtime = @truncate(@as(u64, @bitCast(tod.seconds())));
        qunlock(&ndb.qlock);
    }
}

fn ndbwrite(ndb: *Ndb, a: []const u8, off: usize) Error!usize {
    const n = a.len;

    qlock(&ndb.qlock);
    defer qunlock(&ndb.qlock);
    if (off > ndb.len or off + n >= 32 * 1024)
        return error.Eio;
    if (n > 0) {
        if (off + n > ndb.len) {
            const nb = alloc.realloc(ndb.buf, off + n) orelse
                return error.Enomem;
            ndb.buf = nb;
            ndb.len = off + n;
        }
        @memcpy(ndb.buf.?[off..][0..n], a);
        ndb.vers +%= 1;
        ndb.mtime = @truncate(@as(u64, @bitCast(tod.seconds())));
    }
    return n;
}

fn ndbread(ndb: *Ndb, a: []u8, off: usize) Error!usize {
    var n = a.len;

    qlock(&ndb.qlock);
    defer qunlock(&ndb.qlock);
    if (off >= ndb.len)
        n = 0
    else {
        if (off + n > ndb.len)
            n = ndb.len - off;
        @memcpy(a[0..n], ndb.buf.?[off..][0..n]);
    }
    return n;
}

pub fn scalednconv() usize {
    // DIFF: see the head of the file.
    const cpuserver: bool = if (@hasDecl(arch, "cpuserver")) arch.cpuserver else false;
    if (cpuserver and arch.conf.npage * arch.mem.BY2PG >= 128 * portdat.MB)
        return ipdat.Nchans * 4;
    return ipdat.Nchans;
}
