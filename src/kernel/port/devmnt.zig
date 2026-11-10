//! The mount driver, #M: the 9P client.  Every file reached through a
//! mounted file server is a channel of this device, and each operation
//! on one is a 9P RPC on the server's channel.
//! from 9/port/devmnt.c
//!
//! DIFF:
//!   - Errors.  error()/waserror()/nexterror() are Zig error returns.
//!     A function that allocates a Mntrpc frees it with `defer mntfree`,
//!     which is what each "if(waserror()){ mntfree(r); nexterror(); }"
//!     did.  mountio's `while(waserror())` loop is a loop around
//!     mountio1 (new, the body of the C loop) with the handler in its
//!     catch; see there.
//!   - The C compares up->errstr with Eintr and Ehungup in mountio.
//!     Here an error is a tag or error.Str with the text in up.errstr,
//!     so iserr() compares the text of whichever it is, which gives the
//!     same answer as the C in both cases.
//!   - A server's Rerror becomes proc.errorf("%s", ename): error.Str
//!     with the server's text in up.errstr, never an error tag, even
//!     when the text is that of one.
//!   - mount cache: cache.c is not ported.  cinit, copen, cread, cwrite,
//!     cupdate, cclunk, ctrunc, mntcache() and cachedchan() are left out,
//!     each site marked "DIFF: mount cache".  MCACHE is accepted by
//!     mntattach and does nothing: CCACHE is never set on a channel, and
//!     mountio does not keep a copy of a Twrite for the cache.
//!   - Read ahead (Mntrah, mntrahinit, mntrahread, mntdefer, mntproc,
//!     rahproc) is ported, but its only caller is cache.c, so nothing
//!     calls it yet.  Mntrah is declared here because portdat.zig does
//!     not have it.
//!   - Mnt is opaque in portdat.zig; Chan.mux is converted with muxof().
//!     chan.muxclose is a hook variable that mntreset points at muxclose.
//!   - The embedded Lock and Rendez of Mnt, Mntalloc, Mntproc and Mntrah
//!     are the fields `lock` and `rendez`.
//!   - Strings and buffers are slices.  mntversion takes the version as
//!     a buffer holding a NUL-terminated string (empty for nil), which
//!     is also where the answer goes when returnlen is not 0.
//!   - Fcall strings and data decoded by convM2S are slices into the
//!     reply's first block, r.b, so they live as long as the C's do:
//!     until mntfree.  The data slice of an Rread is cleared, because
//!     the data is in the block list and only its header was pulled up.
//!   - mntwalk returns an error where the C returns nil.  When the
//!     server answers a walk of one or more names with no qids and no
//!     error (the C returns nil with whatever is in up->errstr) it
//!     returns Enonexist.
//!   - mntchk panics if the mount channel has no Mnt; the C prints and
//!     then dereferences nil.
//!   - mntbwrite frees the block if no Mntrpc can be allocated; the C
//!     leaks it.
//!   - mntrpcread returns -1 instead of dereferencing nil if the queue
//!     runs out of blocks in the middle of a message.
//!   - Mntrpc.done and Mnt.rip are read without the Mnt lock (rpcattn,
//!     mountio, rahdone), so they are accessed with atomics.
//!   - fmtinstall of %F and %D is gone with libc's fmt.
//!   - exhausted() is a private copy until proc.zig has it.

const std = @import("std");
const fcall = @import("fcall");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const errmod = @import("error.zig");
const lib = @import("lib.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const alloc = @import("alloc.zig");
const ab = @import("allocb.zig");
const qio = @import("qio.zig");
const proc = @import("proc.zig");
const chan = @import("chan.zig");
const devmod = @import("dev.zig");
const sysfile = @import("sysfile.zig");
const p9 = @import("print.zig");

const print = p9.print;
const panic = p9.panic;
const lock = taslock.lock;
const unlock = taslock.unlock;
const incref = portdat.incref;
const cclose = chan.cclose;
const chanpath = chan.chanpath;
const sleep = proc.sleep;
const wakeup = proc.wakeup;
const freeb = ab.freeb;
const BLEN = ab.BLEN;

pub const Error = proc.Error;
const Chan = portdat.Chan;
const Proc = portdat.Proc;
const Lock = portdat.Lock;
const Rendez = portdat.Rendez;
const Walkqid = portdat.Walkqid;
const Block = ab.Block;
const Queue = qio.Queue;
const Fcall = fcall.Fcall;

const BIT8SZ = fcall.BIT8SZ;
const BIT16SZ = fcall.BIT16SZ;
const BIT32SZ = fcall.BIT32SZ;
const BIT64SZ = fcall.BIT64SZ;
const IOHDRSZ = fcall.IOHDRSZ;
const QTDIR = fcall.QTDIR;

// References are managed as follows:
// The channel to the server - a network connection or pipe - has one
// reference for every Chan open on the server.  The server channel has
// c->mux set to the Mnt used for muxing control to that server.  Mnts
// have no reference count; they go away when c goes away.
// Each channel derived from the mount point has mchan set to c,
// and increfs/decrefs mchan to manage references on the server
// connection.

const MAXRPC = IOHDRSZ + 32768; // maximum size of any RPC
const MAXRPC0 = IOHDRSZ + 8192; // maximum size of Tversion/Rversion pair

pub const Mntrpc = struct {
    c: *Chan = undefined, // Channel for whom we are working
    list: ?*Mntrpc = null, // Free/pending list
    request: Fcall = .{}, // Outgoing file system protocol message
    reply: Fcall = .{}, // Incoming reply
    m: ?*Mnt = null, // Mount device during rpc
    z: ?*Rendez = null, // Place to hang out
    w: ?*Block = null, // copy of write rpc for cache
    b: ?*Block = null, // reply blocks
    flushed: ?*Mntrpc = null, // message this one flushes
    done: u8 = 0, // Rpc completed

    fn isdone(r: *const Mntrpc) u8 {
        return @atomicLoad(u8, &r.done, .seq_cst);
    }

    fn setdone(r: *Mntrpc, v: u8) void {
        @atomicStore(u8, &r.done, v, .seq_cst);
    }
};

const Mntproc = struct {
    rendez: Rendez = .{},

    m: ?*Mnt = null,
    r: ?*Mntrpc = null,
    a: ?*anyopaque = null,
    f: ?*const fn (*Mntrpc, ?*anyopaque) void = null,
};

pub const Mnt = struct {
    lock: Lock = .{},
    // references are counted using c->ref; channels on this mount point incref(c->mchan) == Mnt.c
    c: ?*Chan = null, // Channel to file service
    rip: ?*Proc = null, // Reader in progress
    queue: ?*Mntrpc = null, // Queue of pending requests on this channel
    defered: [8]Mntproc = @splat(.{}), // Worker processes for defered RPCs (read ahead)
    id: u32 = 0, // Multiplexer id for channel check
    msize: u32 = 0, // data + IOHDRSZ
    list: ?*Mnt = null, // Free list
    version: []u8 = portdat.nostr, // 9P version
    q: ?*Queue = null, // input queue
};

/// Read-ahead state of one cached file.
/// from 9/port/portdat.h
pub const Mntrah = struct {
    rendez: Rendez = .{},

    off: i64 = 0,
    seq: i64 = 0,
    vers: u32 = 0,

    i: u32 = 0,
    r: [8]?*Mntrpc = @splat(null),
};

const TAGSHIFT = 5;
const TAGMASK = (1 << TAGSHIFT) - 1;
const NMASK = (64 * 1024) >> TAGSHIFT;

// offset to data in Twrite request
const Twritehdr = BIT32SZ + BIT8SZ + BIT16SZ + BIT32SZ + BIT64SZ + BIT32SZ;

const Mntalloc = struct {
    lock: Lock = .{},
    list: ?*Mnt = null, // Mount devices in use
    mntfree: ?*Mnt = null, // Free list
    rpcfree: ?*Mntrpc = null,
    nrpcfree: u32 = 0,
    nrpcused: u32 = 0,
    id: u32 = 0,
    tagmask: [NMASK]u32 = @splat(0),
};

var mntalloc: Mntalloc = .{};

// DIFF: mount cache
// #define cachedchan(c) (((c)->flag & CCACHE) != 0 && (c)->mcp != nil)

const Esbadstat = "invalid directory entry received from server";
const Enoversion = "version not established for mount channel";

/// The Mnt of a server channel.
fn muxof(c: *const Chan) ?*Mnt {
    return @ptrCast(@alignCast(c.mux));
}

/// Is e the error whose text is that of `want`?  What the C asks with
/// strcmp(up->errstr, Ewant).
fn iserr(e: Error, want: Error) bool {
    return std.mem.eql(u8, proc.errtext(e), errmod.errstr(want));
}

// M3: belongs in proc.zig (9/port/proc.c).
fn exhausted(resource: []const u8) Error {
    const e = proc.errorf("no free %s", .{resource});
    p9.iprint("%s\n", .{proc.errtext(e)});
    return e;
}

fn up() *Proc {
    return arch.up().?;
}

fn dev(c: *const Chan) *const devmod.Dev {
    return devmod.devtab[c.type];
}

fn mntreset() void {
    mntalloc.id = 1;
    mntalloc.tagmask[0] = 1; // don't allow 0 as a tag
    mntalloc.tagmask[NMASK - 1] = 0x80000000; // don't allow NOTAG
    // DIFF: no fmtinstall('F', fcallfmt) and fmtinstall('D', dirfmt)
    // We can't install %M since eipfmt does and is used in the kernel [sape]

    // DIFF: mount cache
    // cinit();

    chan.muxclose = muxclosehook;
}

/// Version is not multiplexed: message sent only once per connection.
///
/// `version` holds the version wanted as a NUL-terminated string, or is
/// empty for the default.  If returnlen is not 0 the version agreed on
/// is stored at its start, without a NUL, and must fit in returnlen
/// bytes.  Returns the length of the agreed version.
pub fn mntversion(c: *Chan, version: []u8, msize_: i32, returnlen: usize) Error!usize {
    try ql.eqlock(&c.umqlock); // make sure no one else does this until we've established ourselves
    var locked = true;
    defer if (locked) ql.qunlock(&c.umqlock);

    // defaults
    var msize: i64 = msize_;
    if (msize == 0)
        msize = MAXRPC;
    if (msize > c.iounit and c.iounit != 0)
        msize = c.iounit;
    var v: []const u8 = std.mem.sliceTo(version, 0);
    if (v.len == 0)
        v = fcall.VERSION9P;

    // validity
    if (msize < 0)
        return proc.errorf("bad iounit in version call", .{});
    if (!std.mem.startsWith(u8, v, fcall.VERSION9P))
        return proc.errorf("bad 9P version specification", .{});

    if (muxof(c)) |m| {
        locked = false;
        ql.qunlock(&c.umqlock);

        var buf: [128]u8 = undefined;
        const k = @min(m.version.len, buf.len - 1);
        @memcpy(buf[0..k], m.version[0..k]);
        if (!std.mem.startsWith(u8, v, buf[0..k]))
            return proc.errorf("incompatible 9P versions %s %s", .{ buf[0..k], v });
        if (returnlen > 0) {
            if (returnlen < k)
                return error.Eshort;
            @memmove(version[0..k], buf[0..k]);
        }
        return k;
    }

    var f: Fcall = .{};
    f.type = fcall.Tversion;
    f.tag = fcall.NOTAG;
    f.msize = @intCast(msize);
    f.version = v;
    const msg = (alloc.malloc(MAXRPC0) orelse
        return exhausted("version memory"))[0..MAXRPC0];
    defer alloc.free(msg.ptr);
    var k = fcall.convS2M(&f, msg);
    if (k == 0)
        return proc.errorf("bad fversion conversion on send", .{});

    lock(&c.lock);
    const oo = c.offset;
    c.offset += @intCast(k);
    unlock(&c.lock);

    var l = try dev(c).write(c, msg[0..k], oo);
    if (l < k) {
        lock(&c.lock);
        c.offset -= @intCast(k - l);
        unlock(&c.lock);
        return proc.errorf("short write in fversion", .{});
    }

    // message sent; receive and decode reply
    k = 0;
    while (k < BIT32SZ or (k < fcall.GBIT32(msg, 0) and k < MAXRPC0)) : (k += l) {
        l = try dev(c).read(c, msg[k..MAXRPC0], c.offset);
        if (l == 0)
            return proc.errorf("EOF receiving fversion reply", .{});
        lock(&c.lock);
        c.offset += @intCast(l);
        unlock(&c.lock);
    }

    l = fcall.convM2S(msg[0..k], &f);
    if (l != k)
        return proc.errorf("bad fversion conversion on reply", .{});
    if (f.type != fcall.Rversion) {
        if (f.type == fcall.Rerror)
            return proc.errorf("%s", .{f.ename});
        return proc.errorf("unexpected reply type in fversion", .{});
    }
    if (f.msize > msize)
        return proc.errorf("server tries to increase msize in fversion", .{});
    if (f.msize < 256 or f.msize > 1024 * 1024)
        return proc.errorf("nonsense value of msize in fversion", .{});
    k = f.version.len;
    if (!std.mem.startsWith(u8, v, f.version))
        return proc.errorf("bad 9P version returned from server", .{});
    if (returnlen > 0 and returnlen < k)
        return error.Eshort;

    var vs: []u8 = portdat.nostr;
    proc.kstrdup(&vs, f.version);
    const q = qio.qopen(10 * MAXRPC, 0, null, null) orelse {
        alloc.free(vs.ptr);
        return exhausted("mount queues");
    };

    // now build Mnt associated with this connection
    lock(&mntalloc.lock);
    var m: *Mnt = undefined;
    if (mntalloc.mntfree) |fm| {
        m = fm;
        mntalloc.mntfree = m.list;
    } else {
        unlock(&mntalloc.lock);
        m = alloc.new(Mnt) orelse {
            qio.qfree(q);
            alloc.free(vs.ptr);
            return exhausted("mount devices");
        };
        m.* = .{};
        lock(&mntalloc.lock);
    }
    m.list = mntalloc.list;
    mntalloc.list = m;
    m.version = vs;
    m.id = mntalloc.id;
    mntalloc.id += 1;
    m.q = q;
    m.msize = f.msize;
    unlock(&mntalloc.lock);

    if (returnlen > 0)
        @memmove(version[0..k], f.version); // length was checked above

    lock(&m.lock);
    m.queue = null;
    @atomicStore(?*Proc, &m.rip, null, .seq_cst);

    c.flag |= portdat.CMSG;
    c.mux = @ptrCast(m);
    m.c = c;
    unlock(&m.lock);

    return k;
}

/// The channel of the authentication file for `spec` on the server at
/// the other end of c.  The caller keeps its reference to c.
pub fn mntauth(c_: *Chan, spec: []const u8) Error!*Chan {
    const m = muxof(c_) orelse blk: {
        _ = try mntversion(c_, &.{}, 0, 0);
        break :blk muxof(c_) orelse
            return proc.errorf("%s", .{Enoversion});
    };

    const c = mntchan();
    // Close must not be called since it will
    // call mnt recursively
    errdefer chan.chanfree(c);

    const r = try mntralloc(c);
    defer mntfree(r);

    r.request.type = fcall.Tauth;
    r.request.afid = @bitCast(c.fid);
    r.request.uname = up().user;
    r.request.aname = spec;
    try mountrpc(m, r);

    c.qid = r.reply.aqid;
    c.mchan = m.c;
    _ = incref(&m.c.?.ref);
    c.mqid = c.qid;
    c.mode = lib.ORDWR;
    c.iounit = m.msize - IOHDRSZ;

    return c;
}

/// Attach to the file server on the other end of c (authenticated
/// through ac if it is not nil) and return the channel of its root.
/// The caller keeps its references to c and ac.
pub fn mntattach(c_: *Chan, ac: ?*Chan, spec: []const u8, flags: u32) Error!*Chan {
    if (ac) |x| {
        if (x.mchan != c_)
            return error.Ebadusefd;
    }

    const m = muxof(c_) orelse blk: {
        _ = try mntversion(c_, &.{}, 0, 0);
        break :blk muxof(c_) orelse
            return proc.errorf("%s", .{Enoversion});
    };

    const c = mntchan();
    // Close must not be called since it will
    // call mnt recursively
    errdefer chan.chanfree(c);

    const r = try mntralloc(c);
    defer mntfree(r);

    r.request.type = fcall.Tattach;
    r.request.fid = @bitCast(c.fid);
    if (ac) |x|
        r.request.afid = @bitCast(x.fid)
    else
        r.request.afid = fcall.NOFID;
    r.request.uname = up().user;
    r.request.aname = spec;
    try mountrpc(m, r);

    c.qid = r.reply.qid;
    c.mchan = m.c;
    _ = incref(&m.c.?.ref);
    c.mqid = c.qid;

    // DIFF: mount cache
    // if(flags&MCACHE)
    //     c->flag |= CCACHE;
    _ = flags;
    return c;
}

fn noattach(_: []const u8) Error!*Chan {
    return error.Enoattach;
}

fn mntchan() *Chan {
    const c = devmod.devattach('M', "");
    lock(&mntalloc.lock);
    c.dev = mntalloc.id;
    mntalloc.id += 1;
    unlock(&mntalloc.lock);

    if (c.mchan != null)
        panic("mntchan non-zero %p", .{c.mchan});
    return c;
}

fn mntwalk(c: *Chan, nc_: ?*Chan, name: []const []const u8) Error!*Walkqid {
    if (nc_ != null)
        print("mntwalk: nc != nil\n", .{});
    if (name.len > fcall.MAXWELEM)
        return proc.errorf("devmnt: too many name elements", .{});
    var alloced = false;
    const wq = alloc.snew(Walkqid);
    wq.* = .{};
    errdefer {
        if (alloced) {
            if (wq.clone) |x| cclose(x);
        }
        alloc.free(wq);
    }

    const m = mntchk(c);
    const r = try mntralloc(c);
    defer mntfree(r);
    const nc = nc_ orelse blk: {
        const n = devmod.devclone(c);
        // Until the other side accepts this fid, we can't mntclose it.
        // Therefore set type to 0 for now; rootclose is known to be safe.
        n.type = 0;
        // DIFF: mount cache
        // nc->flag |= (c->flag & CCACHE);
        alloced = true;
        break :blk n;
    };
    wq.clone = nc;

    r.request.type = fcall.Twalk;
    r.request.fid = @bitCast(c.fid);
    r.request.newfid = @bitCast(nc.fid);
    r.request.nwname = @intCast(name.len);
    for (name, 0..) |n, i|
        r.request.wname[i] = n;

    try mountrpc(m, r);

    if (r.reply.nwqid > name.len)
        return proc.errorf("too many QIDs returned by walk", .{});
    if (r.reply.nwqid < name.len) {
        if (alloced)
            cclose(nc);
        wq.clone = null;
        if (r.reply.nwqid == 0) {
            // DIFF: the C frees wq and returns nil without an error.
            // The errdefer frees wq; clone is nil by now.
            return error.Enonexist;
        }
    }

    // move new fid onto mnt device and update its qid
    if (wq.clone) |clone| {
        if (clone != c) {
            clone.type = c.type;
            clone.mchan = c.mchan;
            _ = incref(&c.mchan.?.ref);
        }
        if (r.reply.nwqid > 0)
            clone.qid = r.reply.wqid[r.reply.nwqid - 1];
    }
    wq.nqid = r.reply.nwqid;
    for (0..wq.nqid) |i|
        wq.qid[i] = r.reply.wqid[i];

    return wq;
}

fn mntstat(c: *Chan, dp: []u8) Error!usize {
    var n = dp.len;
    if (n < BIT16SZ)
        return error.Eshortstat;
    const m = mntchk(c);
    const r = try mntralloc(c);
    defer mntfree(r);
    r.request.type = fcall.Tstat;
    r.request.fid = @bitCast(c.fid);
    try mountrpc(m, r);

    if (r.reply.nstat > n) {
        n = BIT16SZ;
        fcall.PBIT16(dp, 0, r.reply.nstat -% 2);
    } else {
        n = r.reply.nstat;
        @memmove(dp[0..n], r.reply.stat[0..n]);
        try sysfile.validstat(dp[0..n]);
        mntdirfix(dp, c);
    }
    return n;
}

fn mntopencreate(typ: u8, c: *Chan, name: []const u8, omode: u32, perm: u32) Error!*Chan {
    const m = mntchk(c);
    const r = try mntralloc(c);
    defer mntfree(r);
    r.request.type = typ;
    r.request.fid = @bitCast(c.fid);
    r.request.mode = @truncate(omode);
    if (typ == fcall.Tcreate) {
        r.request.perm = perm;
        r.request.name = name;
    }
    try mountrpc(m, r);

    c.qid = r.reply.qid;
    c.offset = 0;
    c.mode = @intCast(try devmod.openmode(omode));
    c.iounit = r.reply.iounit;
    if (c.iounit == 0 or c.iounit > m.msize - IOHDRSZ)
        c.iounit = m.msize - IOHDRSZ;
    c.flag |= portdat.COPEN;

    // DIFF: mount cache
    // if(c->flag & CCACHE){
    //     if(copen(c))
    //     if(type == Tcreate || (omode&OTRUNC) != 0)
    //         ctrunc(c);
    // }

    return c;
}

fn mntopen(c: *Chan, omode: u32) Error!*Chan {
    return mntopencreate(fcall.Topen, c, "", omode, 0);
}

fn mntcreate(c: *Chan, name: []const u8, omode: u32, perm: u32) Error!*Chan {
    return mntopencreate(fcall.Tcreate, c, name, omode, perm);
}

fn mntclunk(c: *Chan, t: u8) Error!void {
    // DIFF: mount cache
    // cclunk(c);
    const m = mntchk(c);
    const r = try mntralloc(c);
    defer mntfree(r);
    r.request.type = t;
    r.request.fid = @bitCast(c.fid);
    try mountrpc(m, r);
}

pub fn muxclose(m: *Mnt) void {
    while (m.queue) |r| {
        m.queue = r.list;
        mntfree(r);
    }
    m.id = 0;
    if (m.version.ptr != portdat.nostr.ptr)
        alloc.free(m.version.ptr);
    m.version = portdat.nostr;
    qio.qfree(m.q);
    m.q = null;

    lock(&mntalloc.lock);
    var l = &mntalloc.list;
    var f = l.*;
    while (f) |x| : (f = x.list) {
        if (x == m) {
            l.* = m.list;
            break;
        }
        l = &x.list;
    }
    m.list = mntalloc.mntfree;
    mntalloc.mntfree = m;
    unlock(&mntalloc.lock);
}

/// What chan.muxclose is set to: chanfree knows a Mnt only as the
/// opaque type of portdat.zig.
fn muxclosehook(m: *portdat.Mnt) void {
    muxclose(@ptrCast(@alignCast(m)));
}

fn mntclose(c: *Chan) Error!void {
    return mntclunk(c, fcall.Tclunk);
}

fn mntremove(c: *Chan) Error!void {
    return mntclunk(c, fcall.Tremove);
}

fn mntwstat(c: *Chan, dp: []const u8) Error!usize {
    const m = mntchk(c);
    const r = try mntralloc(c);
    defer mntfree(r);
    r.request.type = fcall.Twstat;
    r.request.fid = @bitCast(c.fid);
    r.request.nstat = @truncate(dp.len);
    r.request.stat = dp;
    try mountrpc(m, r);

    // DIFF: mount cache
    // if(c->flag & CCACHE)
    // if(GBIT64(&dp[STATFIXLEN-4*BIT16SZ-BIT64SZ]) != ~0ULL)
    //     ctrunc(c);

    return dp.len;
}

fn mntread(c: *Chan, buf: []u8, off: i64) Error!usize {
    const n = try mntrdwr(fcall.Tread, c, buf, off);
    if (c.qid.type & QTDIR != 0) {
        var p: usize = 0;
        const e = n;
        while (p + BIT16SZ < e) {
            const dirlen = BIT16SZ + @as(usize, fcall.GBIT16(buf, p));
            if (p + dirlen > e)
                break;
            try sysfile.validstat(buf[p..][0..dirlen]);
            mntdirfix(buf[p..], c);
            p += dirlen;
        }
        if (p != e)
            return proc.errorf("%s", .{Esbadstat});
    }
    return n;
}

fn mntwrite(c: *Chan, buf: []const u8, off: i64) Error!usize {
    return mntrdwr(fcall.Twrite, c, buf, off);
}

// DIFF: mount cache
// mntcache(Mntrpc *r), which gives the data of an Rread or of an
// acknowledged Twrite to the cache, is not ported.

fn mntbread(c: *Chan, n_: usize, off: u64) Error!*Block {
    var n = n_;

    // DIFF: mount cache (|| cachedchan(c))
    if (n > c.iounit)
        return devmod.devbread(c, n, off);

    const m = mntchk(c);
    const r = try mntralloc(c);
    defer mntfree(r);
    r.request.type = fcall.Tread;
    r.request.fid = @bitCast(c.fid);
    r.request.offset = @bitCast(off);
    r.request.count = @intCast(n);
    try mountrpc(m, r);
    const b = qio.concatblock(r.b.?);
    r.b = null;
    if (r.reply.count < n)
        n = r.reply.count;
    if (BLEN(b) > n)
        b.wp = b.rp + n;

    return b;
}

fn mntbwrite(c: *Chan, b_: *Block, off: u64) Error!usize {
    var b = b_;

    var n = BLEN(b);
    // DIFF: mount cache (|| cachedchan(c))
    if (n > c.iounit)
        return devmod.devbwrite(c, b, off);

    const m = mntchk(c);
    const r = mntralloc(c) catch |e| {
        // DIFF: the C leaks the block here
        freeb(b);
        return e;
    };
    defer mntfree(r);
    r.request.type = fcall.Twrite;
    r.request.fid = @bitCast(c.fid);
    r.request.offset = @bitCast(off);
    r.request.count = @intCast(n);
    // prepend Twrite header
    b = qio.padblock(b, Twritehdr);
    r.request.data = (b.rp + Twritehdr)[0..n];
    r.w = b;
    if (fcall.convS2M(&r.request, b.rp[0..BLEN(b)]) == 0)
        return error.Emsize;
    try mountrpc(m, r);
    if (r.reply.count < n)
        n = r.reply.count;

    return n;
}

/// DIFF: buf is const because a write passes its data here too; a read
/// casts that away where it stores the reply.
fn mntrdwr(typ: u8, c: *Chan, buf: []const u8, off_: i64) Error!usize {
    var off = off_;

    const m = mntchk(c);
    var uba = buf;
    var cnt: usize = 0;

    while (true) {
        var nreq: u32 = std.math.cast(u32, uba.len) orelse std.math.maxInt(u32);
        if (nreq > c.iounit)
            nreq = c.iounit;

        // DIFF: mount cache
        // if(type == Tread && cachedchan(c)) {
        //     nr = cread(c, uba, nreq, off);
        //     if(nr > 0) {
        //         nreq = nr;
        //         goto Next;
        //     }
        // }

        var nr: u32 = undefined;
        {
            const r = try mntralloc(c);
            defer mntfree(r);
            r.request.type = typ;
            r.request.fid = @bitCast(c.fid);
            r.request.offset = off;
            r.request.data = uba[0..nreq];
            r.request.count = nreq;
            try mountrpc(m, r);
            // DIFF: mount cache
            // if(cachedchan(c))
            //     mntcache(r);
            nr = r.reply.count;
            if (nr > nreq)
                nr = nreq;
            if (typ == fcall.Tread)
                nr = @intCast(qio.readblist(r.b, @constCast(uba[0..nr]), 0));
        }

        off += nr;
        uba = uba[nr..];
        cnt += nr;
        if (nr != nreq or uba.len == 0 or up().nnote != 0)
            break;
    }
    return cnt;
}

fn mntprocwork(a: ?*anyopaque) bool {
    const p: *Mntproc = @ptrCast(@alignCast(a.?));
    return p.f != null;
}

fn mntproc(a: ?*anyopaque) void {
    const p: *Mntproc = @ptrCast(@alignCast(a.?));

    const m = p.m.?;
    while (true) {
        // the C's "while(waserror()) ;" comes back here from any error
        proc.tsleep(&p.rendez, mntprocwork, p, 500) catch continue;

        lock(&m.lock);
        const f = p.f orelse {
            p.m = null;
            unlock(&m.lock);
            proc.pexit("no work", true);
        };
        const r = p.r.?;
        const c = r.c;
        unlock(&m.lock);

        f(r, p.a);

        lock(&m.lock);
        p.r = null;
        p.a = null;
        p.f = null;
        unlock(&m.lock);

        cclose(c);
    }
}

fn mntdefer(f: *const fn (*Mntrpc, ?*anyopaque) void, r: *Mntrpc, a: ?*anyopaque) bool {
    const m = mntchk(r.c);
    lock(&m.lock);
    for (&m.defered) |*p| {
        if (p.f != null)
            continue;

        _ = incref(&r.c.ref);
        r.m = m;
        p.r = r;
        p.a = a;
        p.f = f;

        if (p.m == null) {
            p.m = m;
            unlock(&m.lock);
            proc.kproc("mntproc", mntproc, p);
        } else {
            unlock(&m.lock);
            _ = wakeup(&p.rendez);
        }
        return true;
    }
    unlock(&m.lock);
    return false;
}

fn rahproc(r: *Mntrpc, a: ?*anyopaque) void {
    const rah: *Mntrah = @ptrCast(@alignCast(a.?));

    mountrpc(r.m.?, r) catch {};
    r.setdone(2);
    _ = wakeup(&rah.rendez);
}

fn rahdone(v: ?*anyopaque) bool {
    const r: *Mntrpc = @ptrCast(@alignCast(v.?));
    return r.isdone() == 2;
}

fn rahfindrpc(rah: *Mntrah, off: i64) ?*Mntrpc {
    for (rah.r) |x| {
        const r = x orelse continue;
        const n: i64 = r.request.count;
        const o = r.request.offset;
        if (off >= o and off < o + n)
            return r;
    }
    return null;
}

pub fn mntrahinit(rah: *Mntrah) void {
    for (&rah.r) |*rr| {
        if (rr.*) |r| {
            // the C's "while(waserror()) ;": a note does not end the wait
            while (!rahdone(r))
                sleep(&rah.rendez, rahdone, r) catch {};
            rr.* = null;
            mntfree(r);
        }
    }
    rah.i = 0;

    rah.off = 0;
    rah.seq = 0;
}

pub fn mntrahread(rah: *Mntrah, c: *Chan, buf_: []u8, off_: i64) Error!usize {
    var buf = buf_;
    var off = off_;
    var len: i64 = @intCast(buf.len);

    if (len <= 0)
        return 0;
    if (off != rah.off) {
        rah.off = off;
        if (rahfindrpc(rah, off) == null)
            rah.seq = 0;
    }
    rah.off += len;
    rah.seq += len;
    const iounit: i64 = c.iounit;
    if (rah.seq >= 2 * iounit) {
        const w = @divTrunc(off, iounit) * iounit;
        const e = w + rah.seq;
        var o = w;
        while (o < e) : (o += iounit) {
            if (rahfindrpc(rah, o) != null)
                continue;

            const rr = &rah.r[rah.i % rah.r.len];
            if (rr.*) |old| {
                if (!rahdone(old) or (old.request.offset >= w and old.request.offset < e))
                    break;
                rr.* = null;
                mntfree(old);
            }

            const r = try mntralloc(c);
            r.request.type = fcall.Tread;
            r.request.fid = @bitCast(c.fid);
            r.request.offset = o;
            r.request.count = c.iounit;
            if (!mntdefer(rahproc, r, rah)) {
                mntfree(r);
                break;
            }
            rr.* = r;
            rah.i +%= 1;
        }
    }

    var tot: usize = 0;
    while (len > 0) {
        const r = rahfindrpc(rah, off) orelse break;
        while (!rahdone(r))
            try sleep(&rah.rendez, rahdone, r);

        switch (r.reply.type) {
            fcall.Rflush => return error.Eintr,
            fcall.Rerror => return proc.errorf("%s", .{r.reply.ename}),
            fcall.Rread => {},
            else => return error.Emountrpc,
        }
        // DIFF: mount cache
        // mntcache(r);
        var n: i64 = r.request.count;
        const o = r.request.offset;
        if (r.reply.count < n)
            n = r.reply.count;
        n -= off - o;
        if (n <= 0)
            break;
        if (len < n)
            n = len;
        const nn = qio.readblist(r.b, buf[0..@intCast(n)], @intCast(off - o));
        buf = buf[nn..];
        off += @intCast(nn);
        tot += nn;
        len -= @intCast(nn);
    }
    if (tot > 0) {
        rah.off -= len;
        rah.seq -= len;
    }

    return tot;
}

fn mountrpc(m: *Mnt, r: *Mntrpc) Error!void {
    r.reply.tag = 0;
    r.reply.type = fcall.Tmax; // can't ever be a valid message type

    try mountio(m, r);

    const t = r.reply.type;
    switch (t) {
        fcall.Rerror => return proc.errorf("%s", .{r.reply.ename}),
        fcall.Rflush => return error.Eintr,
        else => {
            if (t == r.request.type + 1)
                return;
            const p = up();
            print("mnt: proc %s %lud: mismatch from %s %s rep %#p tag %d fid %d T%d R%d rp %d\n", .{
                p.text,       p.pid,         chanpath(m.c), chanpath(r.c),
                r,            r.request.tag, r.request.fid, r.request.type,
                r.reply.type, r.reply.tag,
            });
            return error.Emountrpc;
        },
    }
}

/// Send r's request and wait until it is answered.
///
/// DIFF: the C is one function whose body sits in "while(waserror())".
/// The body is mountio1; what the C does when an error unwinds to the
/// waserror is the catch here:
///   - if this process was the reader, let another one take over;
///   - if the error is a note (Eintr), queue a Tflush for the request
///     and go round again to send it and wait for its answer, the
///     original request staying on the queue so that its own answer can
///     still arrive first;
///   - for any other error, or if no Tflush can be allocated (the inner
///     waserror of the C), take the request and every flush chained to
///     it off the queue, free the flushes, and return the error with
///     the original request for the caller to free.
fn mountio(m: *Mnt, r_: *Mntrpc) Error!void {
    var r = r_;

    while (true) {
        mountio1(m, r) catch |first| {
            var err = first;
            if (@atomicLoad(?*Proc, &m.rip, .seq_cst) == up())
                mntgate(m);
            if (iserr(err, error.Eintr)) {
                if (mntflushalloc(r)) |fr| {
                    r = fr;
                    continue;
                } else |e| err = e;
            }
            r = mntflushfree(m, r);
            switch (r.request.type) {
                fcall.Tremove, fcall.Tclunk => {
                    // botch, abandon fid
                    if (!iserr(err, error.Ehungup))
                        r.c.fid = 0;
                },
                else => {},
            }
            return err;
        };
        return;
    }
}

/// DIFF (new): the body of the C mountio's loop.  An error returned
/// from here is handled by the catch in mountio.
fn mountio1(m: *Mnt, r: *Mntrpc) Error!void {
    lock(&m.lock);
    r.z = &up().sleep;
    r.m = m;
    r.list = m.queue;
    m.queue = r;
    unlock(&m.lock);

    // Transmit a file system rpc
    var b: *Block = undefined;
    if (r.w) |w| {
        // Already converted by mntbwrite()
        b = w;
        r.w = null;
    } else {
        var n = fcall.sizeS2M(&r.request);
        b = ab.allocb(n);
        n = fcall.convS2M(&r.request, b.wp[0..n]);
        if (n == 0 or n > m.msize) {
            freeb(b);
            return error.Emsize;
        }
        b.wp += n;

        // DIFF: mount cache
        // Save request for mntcache()
        // if(r->request.type == Twrite && cachedchan(r->c))
        //     r->w = copyblock(b, n);
    }
    _ = try dev(m.c.?).bwrite(m.c.?, b, 0);

    // Gate readers onto the mount point one at a time
    while (true) {
        lock(&m.lock);
        if (m.rip == null)
            break;
        unlock(&m.lock);
        try sleep(r.z.?, rpcattn, r);
        if (r.isdone() != 0) {
            _ = mntflushfree(m, r);
            return;
        }
    }
    @atomicStore(?*Proc, &m.rip, up(), .seq_cst);
    unlock(&m.lock);
    while (r.isdone() == 0) {
        if (try mntrpcread(m, r) < 0)
            return error.Emountrpc;
        mountmux(m, r);
    }
    mntgate(m);
    _ = mntflushfree(m, r);
}

/// DIFF: bread never returns nil here.  A device at end of file returns
/// an empty block, for which qaddlist returns 0.
fn doread(m: *Mnt, len: usize) Error!i32 {
    const q = m.q.?;
    while (qio.qlen(q) < len) {
        const b = try dev(m.c.?).bread(m.c.?, m.msize, 0);
        if (qio.qaddlist(q, b) == 0)
            return -1;
    }
    return 0;
}

fn mntrpcread(m: *Mnt, r: *Mntrpc) Error!i32 {
    const q = m.q.?;

    r.reply.type = 0;
    r.reply.tag = 0;

    // read at least length, type, and tag and pullup to a single block
    if (try doread(m, BIT32SZ + BIT8SZ + BIT16SZ) < 0)
        return -1;
    var nb = qio.pullupqueue(q, BIT32SZ + BIT8SZ + BIT16SZ) orelse return -1;

    // read in the rest of the message, avoid ridiculous (for now) message sizes
    var len: usize = fcall.GBIT32(nb.rp[0..BIT32SZ], 0);
    if (len < BIT32SZ + BIT8SZ + BIT16SZ or len > m.msize) {
        qio.qflush(q);
        return -1;
    }
    if (try doread(m, len) < 0)
        return -1;

    // pullup the header (i.e. everything except data)
    const t = nb.rp[BIT32SZ];
    var hlen: usize = switch (t) {
        fcall.Rread => BIT32SZ + BIT8SZ + BIT16SZ + BIT32SZ,
        else => len,
    };
    nb = qio.pullupqueue(q, hlen) orelse return -1;

    // The slice is the whole message although only its header is known
    // to be in this block: for an Rread convM2S does not look at the
    // data, only at where it would end.
    if (fcall.convM2S(nb.rp[0..len], &r.reply) == 0) {
        // bad message, dump it
        print("mntrpcread: convM2S failed\n", .{});
        _ = qio.qdiscard(q, len);
        return -1;
    }
    // DIFF: the data of an Rread is r.b, not this
    if (r.reply.type == fcall.Rread)
        r.reply.data = "";

    // hang the data off of the fcall struct
    var l: *?*Block = &r.b;
    l.* = null;
    while (true) {
        const b = qio.qremove(q) orelse return -1; // DIFF: the C does not check
        if (hlen > 0) {
            b.rp += hlen;
            len -= hlen;
            hlen = 0;
        }
        const i = BLEN(b);
        if (i <= len) {
            len -= i;
            l.* = b;
            l = &b.next;
        } else {
            // split block and put unused bit back
            nb = ab.allocb(i - len);
            @memcpy(nb.wp[0 .. i - len], (b.rp + len)[0 .. i - len]);
            b.wp = b.rp + len;
            nb.wp += i - len;
            qio.qputback(q, nb);
            l.* = b;
            return 0;
        }
        if (len == 0)
            break;
    }

    return 0;
}

fn mntgate(m: *Mnt) void {
    lock(&m.lock);
    @atomicStore(?*Proc, &m.rip, null, .seq_cst);
    var q = m.queue;
    while (q) |x| : (q = x.list) {
        if (x.isdone() == 0) {
            if (wakeup(x.z.?) != null)
                break;
        }
    }
    unlock(&m.lock);
}

fn mountmux(m: *Mnt, r: *Mntrpc) void {
    lock(&m.lock);
    var l = &m.queue;
    var q = l.*;
    while (q) |x| : (q = x.list) {
        // look for a reply to a message
        if (x.request.tag == r.reply.tag) {
            l.* = x.list;
            if (x == r) {
                x.setdone(1);
                unlock(&m.lock);
                return;
            }
            // Completed someone else.
            // Trade pointers to receive buffer.
            x.reply = r.reply;
            x.b = r.b;
            r.b = null;
            const z = x.z.?;
            arch.coherence();
            x.setdone(1);
            _ = wakeup(z);
            unlock(&m.lock);
            return;
        }
        l = &x.list;
    }
    unlock(&m.lock);
    print("mnt: unexpected reply from %s tag %ud; type %d\n", .{ chanpath(m.c), r.reply.tag, r.reply.type });
}

/// Create a new flush request and chain the previous
/// requests from it
fn mntflushalloc(r: *Mntrpc) Error!*Mntrpc {
    const fr = try mntralloc(r.c);
    fr.request.type = fcall.Tflush;
    if (r.request.type == fcall.Tflush)
        fr.request.oldtag = r.request.oldtag
    else
        fr.request.oldtag = r.request.tag;
    fr.flushed = r;

    return fr;
}

/// Free a chain of flushes.  Remove each unanswered
/// flush and the original message from the unanswered
/// request queue.  Mark the original message as done
/// and if it hasn't been answered set the reply to to
/// Rflush. Return the original rpc.
fn mntflushfree(m: *Mnt, r_: *Mntrpc) *Mntrpc {
    var r = r_;
    while (true) {
        const fr = r.flushed;
        if (r.isdone() == 0) {
            r.reply.type = fcall.Rflush;
            mntqrm(m, r);
        }
        const next = fr orelse break;
        mntfree(r);
        r = next;
    }
    return r;
}

fn alloctag() u16 {
    for (&mntalloc.tagmask, 0..) |*vp, i| {
        var v = vp.*;
        if (v == 0xffffffff)
            continue;
        var j: u5 = 0;
        while (v & 1 != 0) : (j += 1)
            v >>= 1;
        vp.* |= @as(u32, 1) << j;
        return @intCast(i << TAGSHIFT | j);
    }
    panic("no friggin tags left", .{});
}

fn freetag(t: u16) void {
    mntalloc.tagmask[t >> TAGSHIFT] &= ~(@as(u32, 1) << @as(u5, @intCast(t & TAGMASK)));
}

fn mntralloc(c: *Chan) Error!*Mntrpc {
    var new: *Mntrpc = undefined;

    got: {
        if (mntalloc.nrpcfree != 0) {
            lock(&mntalloc.lock);
            if (mntalloc.rpcfree) |f| {
                new = f;
                mntalloc.rpcfree = f.list;
                mntalloc.nrpcfree -= 1;
                break :got;
            }
            unlock(&mntalloc.lock);
        }
        new = alloc.new(Mntrpc) orelse
            return exhausted("mount rpc header");
        new.* = .{};
        lock(&mntalloc.lock);
        new.request.tag = alloctag();
    }
    mntalloc.nrpcused += 1;
    unlock(&mntalloc.lock);
    new.c = c;
    new.setdone(0);
    new.flushed = null;
    new.b = null;
    new.w = null;
    return new;
}

fn mntfree(r: *Mntrpc) void {
    freeb(r.w);
    qio.freeblist(r.b);
    lock(&mntalloc.lock);
    mntalloc.nrpcused -= 1;
    if (mntalloc.nrpcfree < 32) {
        r.list = mntalloc.rpcfree;
        mntalloc.rpcfree = r;
        mntalloc.nrpcfree += 1;
        unlock(&mntalloc.lock);
        return;
    }
    freetag(r.request.tag);
    unlock(&mntalloc.lock);
    alloc.free(r);
}

fn mntqrm(m: *Mnt, r: *Mntrpc) void {
    lock(&m.lock);
    r.setdone(1);

    var l = &m.queue;
    var f = l.*;
    while (f) |x| : (f = x.list) {
        if (x == r) {
            l.* = r.list;
            break;
        }
        l = &x.list;
    }
    unlock(&m.lock);
}

fn mntchk(c: *Chan) *Mnt {
    // This routine is mostly vestiges of prior lives; now it's just sanity checking
    const mchan = c.mchan orelse
        panic("mntchk 1: nil mchan c %s", .{chanpath(c)});

    const m = muxof(mchan) orelse {
        print("mntchk 2: nil mux c %s c->mchan %s \n", .{ chanpath(c), chanpath(mchan) });
        // DIFF: the C goes on to dereference nil
        panic("mntchk 2: nil mux", .{});
    };

    // Was it closed and reused (was error(Eshutdown); now, it cannot happen)
    if (m.id == 0 or m.id >= c.dev)
        panic("mntchk 3: can't happen", .{});

    return m;
}

/// Rewrite channel type and dev for in-flight data to
/// reflect local values.  These entries are known to be
/// the first two in the Dir encoding after the count.
fn mntdirfix(dirbuf: []u8, c: *Chan) void {
    const r = dev(c).dc;
    var p: usize = BIT16SZ; // skip count
    fcall.PBIT16(dirbuf, p, @truncate(r));
    p += BIT16SZ;
    fcall.PBIT32(dirbuf, p, c.dev);
}

fn rpcattn(v: ?*anyopaque) bool {
    const r: *Mntrpc = @ptrCast(@alignCast(v.?));
    return r.isdone() != 0 or @atomicLoad(?*Proc, &r.m.?.rip, .seq_cst) == null;
}

pub const mntdevtab: devmod.Dev = .{
    .dc = 'M',
    .name = "mnt",

    .reset = mntreset,
    .attach = noattach,
    .walk = mntwalk,
    .stat = mntstat,
    .open = mntopen,
    .create = mntcreate,
    .close = mntclose,
    .read = mntread,
    .bread = mntbread,
    .write = mntwrite,
    .bwrite = mntbwrite,
    .remove = mntremove,
    .wstat = mntwstat,
};
