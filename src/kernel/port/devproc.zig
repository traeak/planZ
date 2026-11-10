//! The process device, #p: every process as a directory of files
//! (/proc/N/{args,ctl,fd,mem,note,ns,regs,segment,status,text,wait ...})
//! that ps, kill, acid and rc read and write, plus /proc/trace.
//! from 9/port/devproc.c
//!
//! DIFF:
//!   - edf: the real-time ctl commands (period, deadline, cost,
//!     sporadic, deadlinenotes, admit, extra, expel, event) and
//!     parsetime are left out; each site is marked `DIFF: edf`.  They
//!     are not in the command table, so lookupcmd rejects them as it
//!     does any unknown command.
//!   - proctrace: /proc/trace exists and can be opened by eve (one
//!     opener at a time, as in C) but no event buffer is allocated, the
//!     scheduler hook is not installed and a read returns 0.  The
//!     `trace` ctl command fails.
//!   - syscall trace: the `syscall` file reads as empty (nothing fills
//!     Proc.syscalltrace) and the `startsyscall` ctl command fails.
//!   - watchpoints: Watchpt is opaque and the architecture has no
//!     setupwatchpts, so `watchpt` reads as empty and a write fails.
//!   - fpregs: `fpregs` and `notefpregs` fail with Enoreg on read and
//!     write, and their length is 0 unless arch.zig exports FPsave; the
//!     FPU save area is not reachable through arch.zig.
//!   - kfpregs: listed, as on 9front's pc64 (KFPSTATE), but always
//!     fails with Enoreg: the kernel has no FPU state of its own.
//!   - mem: the user/kernel split is USTKTOP, not KZERO, because the
//!     kernel's direct map of physical memory lies below KZERO here.
//!     Kernel addresses are readable by eve only inside conf.mem's
//!     kbase..klimit, and inside the kernel image only if the
//!     architecture says where it ends (arch.end).  There is no secrmem
//!     pool to exclude (alloc.secalloc uses the ordinary one).
//!   - segio, with segmentioproc and docmd, is ported here from
//!     9/port/segment.c (marked `M5: belongs in segment.zig`).  The C
//!     kproc simply copies and relies on error() unwinding out of a
//!     fault; here it first brings in every page of the range with
//!     arch.probe, the fault-safe touch, and reports a failure from
//!     that.  A user buffer is recognised by being below USTKTOP.
//!   - regs is written through a whole Ureg: the bytes written are laid
//!     over a copy of the saved registers, which arch.setregisters then
//!     checks, where the C passes the offset down.
//!   - `proc` returns the bytes of the Zig Proc, whose layout is not
//!     the C one.
//!   - The ns and fd files keep their position in Chan.nrock (the
//!     index, as in C) and Chan.mid (the C's mrock, the file offset
//!     after the last line made); this Chan has no mrock.
//!   - A slot number that names no process gives Eprocdied where the C
//!     would dereference nil, and a missing channel path prints as
//!     chanpath does.
//!   - Errors are Zig error unions; each waserror site became a defer.

const std = @import("std");
const fcall = @import("fcall");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const lib = @import("lib.zig");
const alloc = @import("alloc.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const proc = @import("proc.zig");
const chan = @import("chan.zig");
const devmod = @import("dev.zig");
const devcons = @import("devcons.zig");
const parse = @import("parse.zig");
const pgrp = @import("pgrp.zig");
const page = @import("page.zig");
const segment = @import("segment.zig");
const fault = @import("fault.zig");
const portclock = @import("portclock.zig");
const p9 = @import("print.zig");

const print = p9.print;
const panic = p9.panic;
const lock = taslock.lock;
const unlock = taslock.unlock;
const qlock = ql.qlock;
const eqlock = ql.eqlock;
const canqlock = ql.canqlock;
const qunlock = ql.qunlock;
const incref = portdat.incref;
const cclose = chan.cclose;
const chanpath = chan.chanpath;
const iseve = devcons.iseve;
const readnum = devcons.readnum;
const readstr = devcons.readstr;
const tk2ms = portclock.tk2ms;
const mem = arch.mem;

const Error = proc.Error;
const Proc = portdat.Proc;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Qid = portdat.Qid;
const Dir = portdat.Dir;
const Segment = portdat.Segment;
const Ureg = arch.Ureg;
const Dirtab = devmod.Dirtab;
const Cmdtab = parse.Cmdtab;
const devdir = devmod.devdir;
const mkqid = devmod.mkqid;
const openmode = devmod.openmode;
const QTDIR = fcall.QTDIR;
const QTFILE = fcall.QTFILE;
const DEVDOTDOT = portdat.DEVDOTDOT;
const COPEN = portdat.COPEN;
const ERRMAX = portdat.ERRMAX;
const NUMSIZE = portdat.NUMSIZE;
const NSEG = portdat.NSEG;
const TSEG = portdat.TSEG;
const ESEG = portdat.ESEG;
const SG_TYPE = portdat.SG_TYPE;
const SG_TEXT = portdat.SG_TEXT;
const SG_FAULT = portdat.SG_FAULT;
const SG_RONLY = portdat.SG_RONLY;
const LRESPROF = segment.LRESPROF;
const BY2PG = mem.BY2PG;
const OREAD = lib.OREAD;
const OWRITE = lib.OWRITE;

const Qdir = 0;
const Qtrace = 1;
const Qargs = 2;
const Qctl = 3;
const Qfd = 4;
const Qfpregs = 5;
const Qkfpregs = 6;
const Qkregs = 7;
const Qmem = 8;
const Qnote = 9;
const Qnotefpregs = 10;
const Qnoteid = 11;
const Qnotepg = 12;
const Qns = 13;
const Qppid = 14;
const Qproc = 15;
const Qregs = 16;
const Qsegment = 17;
const Qstatus = 18;
const Qtext = 19;
const Qwait = 20;
const Qprofile = 21;
const Qsyscall = 22;
const Qwatchpt = 23;

const CMclose = 0;
const CMclosefiles = 1;
const CMfixedpri = 2;
const CMhang = 3;
const CMkill = 4;
const CMnohang = 5;
const CMnoswap = 6;
const CMpri = 7;
const CMprivate = 8;
const CMprofile = 9;
const CMstart = 10;
const CMstartstop = 11;
const CMstartsyscall = 12;
const CMstop = 13;
const CMwaitstop = 14;
const CMwired = 15;
const CMtrace = 16;
const CMinterrupt = 17;
const CMnointerrupt = 18;
// real time
// DIFF: edf — CMperiod, CMdeadline, CMcost, CMsporadic,
// CMdeadlinenotes, CMadmit, CMextra, CMexpel, CMevent.

// DIFF: proctrace — Nevents = 0x4000 and Emask size the event buffer.

const STATSIZE = 2 * 28 + 12 + 9 * 12;

/// sizeof(FPsave), if the architecture tells.
// DIFF: fpregs
const FPSAVESIZE: i64 = if (@hasDecl(arch, "FPsave")) @sizeOf(arch.FPsave) else 0;

// Status, fd, and ns are left fully readable (0444) because of their use in debugging,
// particularly on shared servers.
// Arguably, ns and fd shouldn't be readable; if you'd prefer, change them to 0000
const procdir = [_]Dirtab{
    .{ .name = "args", .qid = .{ .path = Qargs }, .length = 0, .perm = 0o660 },
    .{ .name = "ctl", .qid = .{ .path = Qctl }, .length = 0, .perm = 0o000 },
    .{ .name = "fd", .qid = .{ .path = Qfd }, .length = 0, .perm = 0o444 },
    .{ .name = "fpregs", .qid = .{ .path = Qfpregs }, .length = FPSAVESIZE, .perm = 0o000 },
    // DIFF: kfpregs
    .{ .name = "kfpregs", .qid = .{ .path = Qkfpregs }, .length = FPSAVESIZE, .perm = 0o400 },
    .{ .name = "kregs", .qid = .{ .path = Qkregs }, .length = @sizeOf(Ureg), .perm = 0o400 },
    .{ .name = "mem", .qid = .{ .path = Qmem }, .length = 0, .perm = 0o000 },
    .{ .name = "note", .qid = .{ .path = Qnote }, .length = 0, .perm = 0o000 },
    .{ .name = "notefpregs", .qid = .{ .path = Qnotefpregs }, .length = FPSAVESIZE, .perm = 0o000 },
    .{ .name = "noteid", .qid = .{ .path = Qnoteid }, .length = 0, .perm = 0o664 },
    .{ .name = "notepg", .qid = .{ .path = Qnotepg }, .length = 0, .perm = 0o000 },
    .{ .name = "ns", .qid = .{ .path = Qns }, .length = 0, .perm = 0o444 },
    .{ .name = "ppid", .qid = .{ .path = Qppid }, .length = 0, .perm = 0o444 },
    .{ .name = "proc", .qid = .{ .path = Qproc }, .length = 0, .perm = 0o400 },
    .{ .name = "regs", .qid = .{ .path = Qregs }, .length = @sizeOf(Ureg), .perm = 0o000 },
    .{ .name = "segment", .qid = .{ .path = Qsegment }, .length = 0, .perm = 0o444 },
    .{ .name = "status", .qid = .{ .path = Qstatus }, .length = STATSIZE, .perm = 0o444 },
    .{ .name = "text", .qid = .{ .path = Qtext }, .length = 0, .perm = 0o000 },
    .{ .name = "wait", .qid = .{ .path = Qwait }, .length = 0, .perm = 0o400 },
    .{ .name = "profile", .qid = .{ .path = Qprofile }, .length = 0, .perm = 0o400 },
    .{ .name = "syscall", .qid = .{ .path = Qsyscall }, .length = 0, .perm = 0o400 },
    .{ .name = "watchpt", .qid = .{ .path = Qwatchpt }, .length = 0, .perm = 0o600 },
};

const proccmd = [_]Cmdtab{
    .{ .index = CMclose, .cmd = "close", .narg = 2 },
    .{ .index = CMclosefiles, .cmd = "closefiles", .narg = 1 },
    .{ .index = CMfixedpri, .cmd = "fixedpri", .narg = 2 },
    .{ .index = CMhang, .cmd = "hang", .narg = 1 },
    .{ .index = CMnohang, .cmd = "nohang", .narg = 1 },
    .{ .index = CMnoswap, .cmd = "noswap", .narg = 1 },
    .{ .index = CMkill, .cmd = "kill", .narg = 1 },
    .{ .index = CMpri, .cmd = "pri", .narg = 2 },
    .{ .index = CMprivate, .cmd = "private", .narg = 1 },
    .{ .index = CMprofile, .cmd = "profile", .narg = 1 },
    .{ .index = CMstart, .cmd = "start", .narg = 1 },
    .{ .index = CMstartstop, .cmd = "startstop", .narg = 1 },
    .{ .index = CMstartsyscall, .cmd = "startsyscall", .narg = 1 },
    .{ .index = CMstop, .cmd = "stop", .narg = 1 },
    .{ .index = CMwaitstop, .cmd = "waitstop", .narg = 1 },
    .{ .index = CMwired, .cmd = "wired", .narg = 2 },
    .{ .index = CMtrace, .cmd = "trace", .narg = 0 },
    .{ .index = CMinterrupt, .cmd = "interrupt", .narg = 1 },
    .{ .index = CMnointerrupt, .cmd = "nointerrupt", .narg = 1 },
    // DIFF: edf — period, deadline, cost, sporadic, deadlinenotes,
    // admit, extra, expel, event.
};

// Segment type from portdat.h
const sname = [_][]const u8{ "Text", "Data", "Bss", "Stack", "Shared", "Phys", "Fixed", "Sticky" };

// Qids are, in path:
//   4 bits of file type (qids above)
//  23 bits of process slot number + 1
//       in vers,
//  32 bits of pid, for consistency checking
const QSHIFT = 5; // location in qid of proc slot #

fn QID(q: Qid) u32 {
    return @intCast(q.path & 0x0000001F);
}
const SLOTMAX = 0x4000000;
fn SLOT(q: Qid) usize {
    return ((@as(usize, @truncate(q.path)) >> QSHIFT) & (SLOTMAX - 1)) -% 1;
}
fn PID(q: Qid) u32 {
    return q.vers;
}
fn NOTEID(q: Qid) u32 {
    return q.vers;
}

/// proctab(SLOT(c->qid)).
/// DIFF: null for a slot outside the table, where the C indexes anyway.
fn slotproc(c: *const Chan) ?*Proc {
    const s = SLOT(c.qid);
    if (s >= arch.conf.nproc)
        return null;
    return proc.proctab(s);
}

// DIFF: proctrace — no tevents, tproduced or tconsumed, and no
// proctrace hook for the scheduler to call.
var tlock: taslock.Lock = .{};
var topens: i32 = 0;

/// strtol(s, nil, 10), which is what atoi is.
// M5: belongs in lib.zig
fn atoi(s: []const u8) i32 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or (s[i] >= '\t' and s[i] <= '\r'))) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    var n: i64 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        n = n * 10 + (s[i] - '0');
        if (n > std.math.maxInt(i32)) {
            // strtol saturates
            return if (neg) std.math.minInt(i32) else std.math.maxInt(i32);
        }
    }
    return @intCast(if (neg) -n else n);
}

/// What was written, as the string the C makes of it: it ends at the
/// first NUL if there is one.
fn cstr(va: []const u8) []const u8 {
    return std.mem.sliceTo(va, 0);
}

fn procgen(c: *Chan, name: ?[]const u8, tab: []const Dirtab, s_: i32, dp: *Dir) i32 {
    const up = arch.up().?;
    var s = s_;

    if (s == DEVDOTDOT) {
        devdir(c, mkqid(Qdir, 0, QTDIR), "#p", 0, proc.eve, 0o555, dp);
        return 1;
    }

    if (c.qid.path == Qdir) {
        if (s == 0) {
            devdir(c, mkqid(Qtrace, ~@as(u32, 0), QTFILE), "trace", 0, proc.eve, 0o400, dp);
            return 1;
        }

        if (name) |nm| {
            // ignore s and use name to find pid
            if (nm.len == 0)
                return -1;
            var v: u32 = 0;
            for (nm) |ch| {
                if (ch < '0' or ch > '9')
                    return -1;
                v = v *% 10 +% (ch - '0');
            }
            if (v == 0)
                return -1;
            s = proc.procindex(v);
            if (s < 0)
                return -1;
        } else {
            s -= 1;
            if (s >= arch.conf.nproc)
                return -1;
        }

        const p = proc.proctab(@intCast(s)) orelse return 0;
        const pid = p.pid;
        if (pid == 0)
            return 0;
        // String comparison is done in devwalk so name must match its formatted pid
        const pidname = fmt.snprint(up.genbuf[0 .. up.genbuf.len - 1], "%lud", .{pid});
        if (name) |nm| {
            if (!std.mem.eql(u8, nm, pidname))
                return -1;
        }
        devdir(c, mkqid(@as(u64, @intCast(s + 1)) << QSHIFT, pid, QTDIR), pidname, 0, p.user, 0o555, dp);
        return 1;
    }
    if (c.qid.path == Qtrace) {
        devdir(c, mkqid(Qtrace, ~@as(u32, 0), QTFILE), "trace", 0, proc.eve, 0o400, dp);
        return 1;
    }
    if (s >= procdir.len)
        return -1;
    if (tab.len != 0)
        panic("procgen", .{});

    const t = &procdir[@intCast(s)];
    const path = c.qid.path & ~@as(u64, (1 << QSHIFT) - 1); // slot component

    // p->procmode determines default mode for files in /proc
    const p = slotproc(c) orelse return -1;
    var perm = t.perm;
    if (perm == 0)
        perm = p.procmode
    else // just copy read bits
        perm |= p.procmode & 0o444;

    var len = t.length;
    switch (QID(c.qid)) {
        Qwait => len = p.nwait, // incorrect size, but >0 means there's something to read
        Qprofile => {
            if (p.seg[TSEG]) |q| {
                if (q.profile != null) {
                    len = @intCast((q.top - q.base) >> LRESPROF);
                    len *= @sizeOf(u32);
                }
            }
        },
        Qwatchpt => len = lenwatchpt(p),
        else => {},
    }

    devdir(c, mkqid(path | t.qid.path, c.qid.vers, QTFILE), t.name, len, p.user, perm, dp);
    return 1;
}

// DIFF: proctrace — _proctrace, the hook that records an event in
// tevents for a traced process, is not ported.

fn procinit() void {
    // slot masks: lets see how big we can go
    if (arch.conf.nproc > SLOTMAX)
        panic("warning: too many procs for devproc\n", .{});
}

fn procattach(spec: []const u8) Error!*Chan {
    return devmod.devattach('p', spec);
}

fn procwalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    return devmod.devwalk(c, nc, name, &.{}, procgen);
}

fn procstat(c: *Chan, db: []u8) Error!usize {
    return devmod.devstat(c, db, &.{}, procgen);
}

/// none can't read or write state on other
/// processes.  This is to contain access of
/// servers running as none should they be
/// subverted by, for example, a stack attack.
fn nonone(p: *Proc) Error!void {
    const up = arch.up().?;
    if (p == up)
        return;
    if (!std.mem.eql(u8, up.user, "none"))
        return;
    if (iseve())
        return;
    return error.Eperm;
}

fn changenoteid(p: *Proc, noteid: u32) Error!void {
    if (noteid == 0)
        return error.Ebadarg;
    if (noteid == p.noteid)
        return;
    if (noteid == p.pid) {
        _ = try proc.setnoteid(p, noteid);
        return;
    }
    var i: usize = 0;
    while (proc.proctab(i)) |pp| : (i += 1) {
        if (pp.noteid != noteid or pp.kp)
            continue;
        if (std.mem.eql(u8, pp.user, p.user)) {
            try nonone(pp);
            _ = try proc.setnoteid(p, noteid);
            return;
        }
    }
    return error.Eperm;
}

fn procopen(c: *Chan, omode0: u32) Error!*Chan {
    const up = arch.up().?;

    if (c.qid.type & QTDIR != 0)
        return devmod.devopen(c, omode0, &.{}, procgen);

    if (QID(c.qid) == Qtrace) {
        if (omode0 != OREAD or !iseve())
            return error.Eperm;
        lock(&tlock);
        if (topens > 0) {
            unlock(&tlock);
            return proc.errorf("already open", .{});
        }
        topens += 1;
        // DIFF: proctrace — the C allocates tevents here on first use
        // and sets proctrace = _proctrace.
        unlock(&tlock);

        // DIFF: openmode cannot fail here, omode0 is OREAD; the C
        // would leave topens raised if it did.
        c.mode = @intCast(try openmode(omode0));
        c.flag |= COPEN;
        c.offset = 0;
        return c;
    }

    const p = slotproc(c) orelse return error.Eprocdied;
    try eqlock(&p.debug);
    var locked = true;
    defer if (locked) qunlock(&p.debug);

    var pid = PID(c.qid);
    if (p.pid != pid)
        return error.Eprocdied;

    const omode = try openmode(omode0);

    switch (QID(c.qid)) {
        Qtext => {
            if (omode != OREAD)
                return error.Eperm;
            try nonone(p);
            qunlock(&p.debug);
            locked = false;
            const tc = try proctext(c, p);
            tc.offset = 0;
            cclose(c);
            return tc;
        },

        Qstatus, Qppid, Qproc, Qkfpregs, Qkregs, Qsegment, Qns, Qfd => {
            if (omode != OREAD)
                return error.Eperm;
        },

        Qctl, Qargs, Qwait, Qnoteid => {
            if (omode != OREAD) {
                // wet floor
                if (p.kp)
                    return error.Eperm;
            }
        },
        Qnote => {
            if (p.kp)
                return error.Eperm;
        },

        Qnotepg => {
            if (p.kp or omode != OWRITE)
                return error.Eperm;
            pid = p.noteid;
        },

        Qmem, Qregs, Qfpregs, Qnotefpregs, Qprofile, Qsyscall, Qwatchpt => {
            if (p.kp or p.privatemem)
                return error.Eperm;
        },

        else => {
            print("procopen %#lux\n", .{QID(c.qid)});
            return error.Egreg;
        },
    }

    // Skip nonone() check when we'r sharing the same note group.
    // This allows processes running as "none" to postnote to their
    // children.
    switch (QID(c.qid)) {
        Qnote, Qnotepg => {
            if (p.noteid != up.noteid)
                try nonone(p); // wet floor
        },
        else => try nonone(p),
    }

    // Affix pid to qid
    if (pid == 0)
        return error.Eprocdied;
    c.qid.vers = pid;

    const tc = try devmod.devopen(c, omode, &.{}, procgen);

    // The C closes tc if clearwatchpt fails; it cannot here.
    switch (QID(c.qid)) {
        Qwatchpt => {
            if ((omode0 & lib.OTRUNC) != 0)
                clearwatchpt(p);
        },
        else => {},
    }

    return tc;
}

fn procwstat(c: *Chan, db: []const u8) Error!usize {
    const up = arch.up().?;

    if (c.qid.type & QTDIR != 0)
        return error.Eperm;

    switch (QID(c.qid)) {
        Qnotepg, Qtrace => return devmod.devwstat(c, db),
        else => {},
    }

    // The strings of the Dir point into strs.
    const strs = alloc.snewslice(u8, db.len);
    defer alloc.free(strs.ptr);
    var d: Dir = .{};
    const n = fcall.convM2D(db, &d, strs);
    if (n == 0)
        return error.Eshortstat;

    const p = slotproc(c) orelse return error.Eprocdied;
    try eqlock(&p.debug);
    defer qunlock(&p.debug);

    if (p.pid != PID(c.qid))
        return error.Eprocdied;

    try nonone(p);
    if (!std.mem.eql(u8, up.user, p.user) and !iseve())
        return error.Eperm;

    if (d.uid.len != 0 and !std.mem.eql(u8, d.uid, p.user)) {
        if (!std.mem.eql(u8, d.uid, "none") and !iseve())
            return error.Eperm;
        proc.kstrdup(&p.user, d.uid);
    }
    // p->procmode determines default mode for files in /proc
    if (d.mode != ~@as(u32, 0))
        p.procmode = d.mode & 0o777;

    return n;
}

fn procclose(c: *Chan) Error!void {
    if ((c.flag & COPEN) == 0)
        return;

    switch (QID(c.qid)) {
        Qtrace => {
            lock(&tlock);
            if (topens > 0)
                topens -= 1;
            // DIFF: proctrace — if(topens == 0) proctrace = nil;
            unlock(&tlock);
        },
        Qmem => {
            if (c.aux) |x| {
                const sio: *Segio = @ptrCast(@alignCast(x));
                c.aux = null;
                // As in C, an interrupted close leaves the Segio and
                // its kproc behind.
                _ = try segio(sio, null, null, 0, 0, false);
                alloc.free(sio);
            }
        },
        else => {},
    }
}

/// The arguments of p, quoted, in buf; returns how much of buf.
fn procargs(p: *Proc, buf: []u8) usize {
    if (p.setargs)
        return fmt.snprint(buf, "%s [%s]", .{ p.text, p.args }).len;
    var a: []const u8 = p.args;
    var n: i64 = p.nargs;
    var j: usize = 0;
    while (j < buf.len) {
        if (n <= 0)
            break;
        if (j != 0) {
            buf[j] = ' ';
            j += 1;
        }
        const arg = std.mem.sliceTo(a, 0);
        const m = fmt.snprint(buf[j..], "%q", .{arg}).len;
        const k = arg.len + 1;
        a = a[@min(k, a.len)..];
        n -= @intCast(k);
        j += m;
    }
    return j;
}

fn eventsavailable(_: ?*anyopaque) bool {
    // DIFF: proctrace — tproduced > tconsumed
    return false;
}

fn prochaswaitq(x: ?*anyopaque) bool {
    const c: *Chan = @ptrCast(@alignCast(x.?));
    const p = slotproc(c) orelse return true;
    return p.pid != PID(c.qid) or p.waitq != null;
}

fn int2flag(flag: u32, s: *[10]u8) []const u8 {
    if (flag == 0)
        return s[0..0];
    var i: usize = 0;
    s[i] = '-';
    i += 1;
    if (flag & lib.MAFTER != 0) {
        s[i] = 'a';
        i += 1;
    }
    if (flag & lib.MBEFORE != 0) {
        s[i] = 'b';
        i += 1;
    }
    if (flag & lib.MCREATE != 0) {
        s[i] = 'c';
        i += 1;
    }
    if (flag & lib.MCACHE != 0) {
        s[i] = 'C';
        i += 1;
    }
    return s[0..i];
}

/// c.nrock when the last line of ns, the cd, has been made; -1 in C.
const NSDONE = std.math.maxInt(usize);

/// The next line of the ns file in buf; returns its length, 0 at the end.
fn readns1(c: *Chan, p: *Proc, buf: []u8) Error!usize {
    var flag: [10]u8 = undefined;

    const pg = p.pgrp orelse return error.Eprocdied;
    const dot = p.dot orelse return error.Eprocdied;
    if (p.pid != PID(c.qid))
        return error.Eprocdied;

    if (c.nrock == NSDONE)
        return 0;

    ql.rlock(&pg.ns);
    defer ql.runlock(&pg.ns);

    var i: usize = 0;
    var f = pg.mntorder;
    while (f) |m| : (f = m.order) {
        const k = i;
        i += 1;
        if (k >= c.nrock)
            break;
    }

    if (f) |m| {
        c.nrock = i;
        const fl = int2flag(m.mflag, &flag);
        const from = chanpath(if (m.umh) |h| h.from else null);
        if (std.mem.eql(u8, chanpath(m.to), "#M")) {
            const srv: []const u8 = if (m.to.mchan) |mc| (mc.srvname orelse chanpath(mc)) else chanpath(null);
            if (m.spec.len != 0)
                return fmt.snprint(buf, "mount %s %q %q %q\n", .{ fl, srv, from, m.spec }).len;
            return fmt.snprint(buf, "mount %s %q %q\n", .{ fl, srv, from }).len;
        }
        return fmt.snprint(buf, "bind %s %q %q\n", .{ fl, chanpath(m.to), from }).len;
    }
    c.nrock = NSDONE;
    return fmt.snprint(buf, "cd %q\n", .{chanpath(dot)}).len;
}

/// One line of /proc/n/fd and of /fd/nctl; returns the part of s written.
pub fn procfdprint(c: *Chan, fd: i32, s: []u8) []u8 {
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
        chanpath(c),
    });
}

/// The next line of the fd file in buf; returns its length, 0 at the end.
fn readfd1(c: *Chan, p: *Proc, buf: []u8) usize {
    const fg = p.fgrp orelse return 0;
    const dot = p.dot orelse return 0;
    if (p.pid != PID(c.qid))
        return 0;

    if (c.nrock == 0) {
        c.nrock = 1;
        return fmt.snprint(buf, "%s\n", .{chanpath(dot)}).len;
    }

    lock(&fg.lock);
    var n: usize = 0;
    while (true) {
        const i = c.nrock - 1;
        if (fg.maxfd < 0 or i > @as(usize, @intCast(fg.maxfd)) or i >= fg.fd.len)
            break;
        c.nrock += 1;
        if (fg.fd[i]) |fc| {
            n = procfdprint(fc, @intCast(i), buf).len;
            break;
        }
    }
    unlock(&fg.lock);

    return n;
}

// setupwatchpts(Proc *p, Watchpt *wp, int nwp) is defined for all arches separately.
// It tests whether wp is a valid set of watchpoints and errors out otherwise.
// If and only if they are valid, it sets up all watchpoints (clearing any preexisting ones).
// This is to make sure that failed writes to watchpt don't touch the existing watchpoints.

fn clearwatchpt(p: *Proc) void {
    // DIFF: watchpoints — setupwatchpts(p, nil, 0);
    alloc.free(p.watchpt);
    p.watchpt = null;
    p.nwatchpt = 0;
}

fn lenwatchpt(pr: *Proc) i64 {
    // careful, not holding debug lock
    return @as(i64, pr.nwatchpt) * (10 + 4 * @sizeOf(usize));
}

fn readwatchpt(_: *Proc, _: []u8) usize {
    // careful, length has to match lenwatchpt()
    // DIFF: watchpoints — nothing sets any, so there are no lines of
    //   "%c%c%c %#.16p %#.16p\n" (r, w, x or -, address, length)
    // to make.
    return 0;
}

fn writewatchpt(_: *Proc, _: []const u8, _: u64) Error!usize {
    // DIFF: watchpoints — needs the Watchpt structure (portdat.zig has
    // it opaque) and the architecture's setupwatchpts.
    return proc.errorf("watchpoints not supported", .{});
}

/// userspace can't pass negative file offset for a
/// 64 bit kernel address, so we use 63 bit and sign
/// extend to 64 bit.
fn off2addr(off: i64) usize {
    return @bitCast((off << 1) >> 1);
}

/// Where the kernel image ends, if the architecture tells.
fn kernelend() ?usize {
    return if (@hasDecl(arch, "end")) arch.end() else null;
}

fn procread(c: *Chan, va: []u8, off: i64) Error!usize {
    const up = arch.up().?;
    var statbuf: [1024]u8 = undefined;
    // What snprint(statbuf, sizeof(statbuf), ...) can fill.
    const sb = statbuf[0 .. statbuf.len - 1];
    var n = va.len;
    var j: usize = 0;

    var offset: usize = @as(u32, @truncate(@as(u64, @bitCast(off))));
    if (c.qid.type & QTDIR != 0)
        return devmod.devdirread(c, va, &.{}, procgen);

    if (QID(c.qid) == Qtrace) {
        if (!eventsavailable(null))
            return 0;
        // DIFF: proctrace — the C copies out whole Traceevents here.
        return 0;
    }

    const p = slotproc(c) orelse return error.Eprocdied;
    if (p.pid != PID(c.qid))
        return error.Eprocdied;

    switch (QID(c.qid)) {
        Qmem => {
            const addr = off2addr(off);
            // DIFF: USTKTOP where the C has KZERO; see the header.
            if (addr < mem.USTKTOP)
                return procctlmemio(c, p, addr, va, true);

            // DIFF: no poolisoverlap(secrmem, addr, n)
            if (!iseve())
                return error.Eperm;

            // validate kernel addresses
            if (kernelend()) |end| {
                if (addr >= mem.KZERO and addr < end) {
                    if (addr +% n > end)
                        n = end - addr;
                    @memcpy(va[0..n], @as([*]const u8, @ptrFromInt(addr))[0..n]);
                    return n;
                }
            }
            for (&arch.conf.mem) |*cm| {
                // klimit-1 because klimit might be zero!
                if (cm.kbase <= addr and addr <= cm.klimit -% 1) {
                    if (addr +% n >= cm.klimit -% 1)
                        n = cm.klimit -% addr;
                    @memcpy(va[0..n], @as([*]const u8, @ptrFromInt(addr))[0..n]);
                    return n;
                }
            }
            return error.Ebadarg;
        },

        Qctl => return readnum(offset, va, p.pid, NUMSIZE),

        Qnoteid => return readnum(offset, va, p.noteid, NUMSIZE),

        Qppid => return readnum(offset, va, p.parentpid, NUMSIZE),

        Qprofile => {
            const s = p.seg[TSEG] orelse return proc.errorf("profile is off", .{});
            const prof = s.profile orelse return proc.errorf("profile is off", .{});
            const bytes = std.mem.sliceAsBytes(prof);
            const i = ((s.top - s.base) >> LRESPROF) * @sizeOf(u32);
            return readstr(offset, va, bytes[0..@min(i, bytes.len)]);
        },

        Qproc => return readstr(offset, va, std.mem.asBytes(p)),

        Qregs => {
            const r = p.dbgreg orelse return error.Enoreg;
            return readstr(offset, va, std.mem.asBytes(r));
        },

        Qkregs => {
            var kur: Ureg = std.mem.zeroes(Ureg);
            arch.setkernur(&kur, p);
            return readstr(offset, va, std.mem.asBytes(&kur));
        },

        // DIFF: kfpregs — if(p->kfpstate < FPinactive) error(Enoreg),
        // and there is never any kernel FPU state.
        Qkfpregs => return error.Enoreg,

        // DIFF: fpregs — the C returns notefpsave(p) or p->fpsave,
        // sizeof(FPsave) bytes, and Enoreg when there is no state.
        Qnotefpregs, Qfpregs => return error.Enoreg,

        Qstatus => {
            const sps = p.psstate orelse proc.statename(p.state);
            j = fmt.snprint(sb, "%-27s %-27s %-11s " ++
                "%11lud %11lud %11lud " ++
                "%11lud %11lud %11lud " ++
                "%11lud %11lud %11lud\n", .{
                p.text,
                p.user,
                sps,
                tk2ms(p.time[portdat.TUser]),
                tk2ms(p.time[portdat.TSys]),
                tk2ms(arch.MACHP(0).ticks -% p.time[portdat.TReal]),
                tk2ms(p.time[portdat.TCUser]),
                tk2ms(p.time[portdat.TCSys]),
                tk2ms(p.time[portdat.TCReal]),
                @as(u32, @truncate(page.procpagecount(p) * BY2PG / 1024)),
                p.basepri,
                p.priority,
            }).len;
            // DIFF: edf — none of the status fields come from edf in
            // this version of the C either.
            return readstr(offset, va, sb[0..j]);
        },

        Qsegment => {
            j = 0;
            for (p.seg) |x| {
                const s = x orelse continue;
                j += fmt.snprint(sb[j..], "%-6s %c%c %8p %8p %4ld\n", .{
                    sname[s.type & SG_TYPE],
                    @as(u8, if (s.type & SG_FAULT != 0) 'F' else if (s.type & SG_RONLY != 0) 'R' else ' '),
                    @as(u8, if (s.profile != null) 'P' else ' '),
                    s.base,
                    s.top,
                    s.ref.ref,
                }).len;
            }
            return readstr(offset, va, sb[0..j]);
        },

        Qwait => {
            if (!canqlock(&p.qwaitr))
                return error.Einuse;

            const wq = blk: {
                defer qunlock(&p.qwaitr);

                lock(&p.exl);
                while (p.waitq == null and p.pid == PID(c.qid)) {
                    if (up == p and p.nchild == 0) {
                        unlock(&p.exl);
                        return error.Enochild;
                    }
                    unlock(&p.exl);
                    try proc.sleep(&p.waitr, prochaswaitq, c);
                    lock(&p.exl);
                }
                if (p.pid != PID(c.qid)) {
                    unlock(&p.exl);
                    return error.Eprocdied;
                }
                const w = p.waitq.?;
                p.waitq = w.next;
                p.nwait -= 1;
                unlock(&p.exl);
                break :blk w;
            };

            j = fmt.snprint(sb, "%d %lud %lud %lud %q", .{
                wq.w.pid,
                wq.w.time[portdat.TUser],
                wq.w.time[portdat.TSys],
                wq.w.time[portdat.TReal],
                std.mem.sliceTo(&wq.w.msg, 0),
            }).len;
            alloc.free(wq);
            return readstr(0, va, sb[0..j]);
        },

        else => {},
    }

    {
        try eqlock(&p.debug);
        defer qunlock(&p.debug);

        if (p.pid != PID(c.qid))
            return error.Eprocdied;

        switch (QID(c.qid)) {
            Qns, Qfd => {
                // c.mid is mrock in the C
                if (offset == 0 or offset != c.mid) {
                    c.nrock = 0;
                    c.mid = 0;
                }
                while (true) {
                    if (QID(c.qid) == Qns)
                        j = try readns1(c, p, sb)
                    else
                        j = readfd1(c, p, sb);
                    if (j == 0)
                        break;
                    c.mid += @intCast(j);
                    if (c.mid > offset)
                        break;
                }
                const i = @as(i64, c.mid) - @as(i64, @intCast(offset));
                if (i <= 0 or i > j)
                    return 0;
                if (i < n)
                    n = @intCast(i);
                offset = j - @as(usize, @intCast(i));
                // and to statbufread, below
            },

            Qargs => j = procargs(p, sb),

            Qwatchpt => j = readwatchpt(p, sb),

            Qsyscall => {
                // DIFF: syscall trace — nothing sets p.syscalltrace.
                if (p.syscalltrace) |t|
                    return readstr(offset, va, t);
                return 0;
            },

            Qnote => {
                if (n < 1) // must accept at least the '\0'
                    return error.Etoosmall;
                if (p.nnote == 0)
                    return 0;
                const note = p.note[0] orelse panic("procread: no note", .{});
                const msg = std.mem.sliceTo(&note.msg, 0);
                const i = msg.len + 1;
                if (i < n)
                    n = i;
                @memcpy(va[0 .. n - 1], msg[0 .. n - 1]);
                va[n - 1] = 0;
                proc.freenote(note);
                p.nnote -= 1;
                const nn: usize = @intCast(p.nnote);
                if (nn == 0)
                    p.notepending = false
                else
                    std.mem.copyForwards(?*portdat.Note, p.note[0..nn], p.note[1 .. nn + 1]);
                p.note[nn] = null;
                return n;
            },

            else => {
                print("unknown qid in procwread\n", .{});
                return error.Egreg;
            },
        }
    }

    // statbufread, for ns, fd, args and watchpt: p.debug is released
    if (offset >= j)
        return 0;
    if (offset + n > j)
        n = j - offset;
    @memcpy(va[0..n], sb[offset..][0..n]);
    return n;
}

fn procwrite(c: *Chan, va: []const u8, off: i64) Error!usize {
    var n = va.len;

    const offset: usize = @as(u32, @truncate(@as(u64, @bitCast(off))));
    if (c.qid.type & QTDIR != 0)
        return error.Eisdir;

    // use the remembered noteid in the channel qid
    if (QID(c.qid) == Qnotepg) {
        if (n >= ERRMAX)
            return error.Etoobig;
        proc.postnotepg(NOTEID(c.qid), cstr(va), portdat.NUser);
        return n;
    }

    // DIFF: proctrace — the C takes proctab(SLOT) of the trace file's
    // qid here, which is slot -1.
    const p = slotproc(c) orelse return error.Eprocdied;
    try eqlock(&p.debug);
    defer qunlock(&p.debug);

    if (p.pid != PID(c.qid))
        return error.Eprocdied;

    switch (QID(c.qid)) {
        Qargs => {
            if (offset != 0 or n >= ERRMAX)
                return error.Etoobig;
            proc.kstrdup(&p.args, cstr(va));
            p.nargs = 0;
            p.setargs = true;
        },

        Qmem => {
            if (p.state != .Stopped)
                return error.Ebadctl;
            // segio only reads from the buffer when writing memory
            n = try procctlmemio(c, p, off2addr(off), @constCast(va), false);
        },

        Qregs => {
            if (offset >= @sizeOf(Ureg))
                n = 0
            else if (offset + n > @sizeOf(Ureg))
                n = @sizeOf(Ureg) - offset;
            const dbgreg = p.dbgreg orelse return error.Enoreg;
            // DIFF: setregisters(p->dbgreg, (char*)(p->dbgreg)+offset, va, n)
            var ur = dbgreg.*;
            if (n > 0)
                @memcpy(std.mem.asBytes(&ur)[offset..][0..n], va[0..n]);
            arch.setregisters(dbgreg, &ur);
        },

        // DIFF: fpregs — the C copies over notefpsave(p) or p->fpsave.
        Qnotefpregs, Qfpregs => return error.Enoreg,

        Qctl => try procctlreq(p, va),

        Qnote => {
            if (n >= ERRMAX)
                return error.Etoobig;
            if (!proc.postnote(p, false, cstr(va), portdat.NUser))
                return proc.errorf("note not posted", .{});
        },

        Qnoteid => {
            if (offset != 0 or n >= ERRMAX)
                return error.Etoobig;
            try changenoteid(p, @bitCast(atoi(cstr(va))));
        },

        Qwatchpt => _ = try writewatchpt(p, va, @bitCast(off)),

        else => {
            print("unknown qid in procwrite\n", .{});
            return error.Egreg;
        },
    }
    return n;
}

pub const procdevtab: devmod.Dev = .{
    .dc = 'p',
    .name = "proc",

    .init = procinit,
    .attach = procattach,
    .walk = procwalk,
    .stat = procstat,
    .open = procopen,
    .close = procclose,
    .read = procread,
    .write = procwrite,
    .wstat = procwstat,
};

fn proctext(c: *Chan, p: *Proc) Error!*Chan {
    try eqlock(&p.seglock);
    defer qunlock(&p.seglock);

    if (@backingInt(p.state) <= @backingInt(portdat.State.New) or p.pid != PID(c.qid))
        return error.Eprocdied;
    const s = p.seg[TSEG] orelse return error.Enonexist;
    const i = s.image orelse return error.Enonexist;
    lock(&i.lock);
    const tc = i.c;
    if (i.notext or tc == null or (tc.?.flag & COPEN) == 0 or tc.?.mode != OREAD) {
        unlock(&i.lock);
        return error.Enonexist;
    }
    _ = incref(&tc.?.ref);
    unlock(&i.lock);

    return tc.?;
}

/// Called with p.debug held; gives it up while waiting and holds it
/// again on return, error or not.
fn procstopwait(p: *Proc, ctl: i32) Error!void {
    const up = arch.up().?;

    if (p.pdbg != null)
        return error.Einuse;
    if (procstopped(p) or p.state == .Broken)
        return;
    const pid = p.pid;
    if (pid == 0)
        return error.Eprocdied;
    if (ctl != 0)
        p.procctl = ctl;
    if (p == up)
        return;
    p.pdbg = up;
    qunlock(&p.debug);
    const state = up.psstate;
    up.psstate = "Stopwait";
    proc.sleep(&up.sleep, procstopped, p) catch |e| {
        up.psstate = state;
        qlock(&p.debug);
        if (p.pdbg == up)
            p.pdbg = null;
        return e;
    };
    up.psstate = state;
    qlock(&p.debug);
    if (p.pid != pid)
        return error.Eprocdied;
}

/// Called with p.debug held; gives it up around each cclose.
fn procctlclosefiles(p: *Proc, all: bool, fd_: i32) Error!void {
    if (fd_ < 0)
        return error.Ebadfd;
    var fd: usize = @intCast(fd_);
    const f = p.fgrp orelse return error.Eprocdied;

    _ = incref(&f.ref);
    lock(&f.lock);
    while (f.maxfd >= 0 and fd <= @as(usize, @intCast(f.maxfd)) and fd < f.fd.len) {
        if (f.fd[fd]) |fc| {
            f.fd[fd] = null;
            unlock(&f.lock);
            qunlock(&p.debug);
            cclose(fc);
            qlock(&p.debug);
            lock(&f.lock);
        }
        if (!all)
            break;
        fd += 1;
    }
    unlock(&f.lock);
    pgrp.closefgrp(f);
}

// DIFF: edf — parsetime, which reads a time with a unit (s, ms, µs, ns)
// for the period, deadline and cost commands, is not ported.

fn procctlreq(p: *Proc, va: []const u8) Error!void {
    const up = arch.up().?;

    const cb = try parse.parsecmd(va);
    defer alloc.free(cb);

    const ct = try parse.lookupcmd(cb, &proccmd);

    switch (ct.index) {
        CMclose => try procctlclosefiles(p, false, atoi(cb.f[1])),
        CMclosefiles => try procctlclosefiles(p, true, 0),
        CMhang => p.hang = true,
        CMkill => proc.killproc(p, portdat.Proc_exitme),
        CMnohang => p.hang = false,
        CMnoswap => p.noswap = true,
        CMpri => {
            const pri = atoi(cb.f[1]);
            if (pri > portdat.PriNormal and !iseve())
                return error.Eperm;
            proc.procpriority(p, pri, false);
        },
        CMfixedpri => {
            const pri = atoi(cb.f[1]);
            if (pri > portdat.PriNormal and !iseve())
                return error.Eperm;
            proc.procpriority(p, pri, true);
        },
        CMprivate => {
            p.privatemem = true;
            // pages will now get marked private
            // when faulted in for writing
            // so force a tlb flush.
            p.newtlb = true;
            if (p == up)
                arch.flushmmu();
        },
        CMprofile => {
            const s = p.seg[TSEG] orelse return error.Egreg;
            if ((s.type & SG_TYPE) != SG_TEXT) // won't expand
                return error.Egreg;
            try eqlock(&s.qlock);
            defer qunlock(&s.qlock);
            const npc = (s.top - s.base) >> LRESPROF;
            if (s.profile) |prof| {
                @memset(prof, 0);
            } else {
                s.profile = alloc.newslice(u32, npc) orelse return error.Enomem;
            }
        },
        CMstart => {
            if (p.state != .Stopped)
                return error.Ebadctl;
            proc.ready(p);
        },
        CMstartstop => {
            if (p.state != .Stopped)
                return error.Ebadctl;
            p.procctl = portdat.Proc_traceme;
            proc.ready(p);
            try procstopwait(p, portdat.Proc_traceme);
        },
        CMstartsyscall => {
            // DIFF: syscall trace — the C sets Proc_tracesyscall,
            // readies p and waits for it to stop at its next system
            // call; nothing here would stop it.
            if (p.state != .Stopped)
                return error.Ebadctl;
            return proc.errorf("syscall tracing not supported", .{});
        },
        CMstop => try procstopwait(p, portdat.Proc_stopme),
        CMwaitstop => try procstopwait(p, 0),
        CMwired => proc.procwired(p, atoi(cb.f[1])),
        CMtrace => {
            // DIFF: proctrace — the C toggles p->trace with one field,
            // sets it from the second with two, error("args") otherwise.
            switch (cb.nf) {
                1, 2 => return proc.errorf("proc trace not supported", .{}),
                else => return proc.errorf("args", .{}),
            }
        },
        CMinterrupt => proc.procinterrupt(p),
        CMnointerrupt => {
            if (p.nnote == 0)
                p.notepending = false
            else
                return proc.errorf("notes pending", .{});
        },
        // real time
        // DIFF: edf — CMperiod, CMdeadline, CMcost, CMsporadic,
        // CMdeadlinenotes, CMadmit, CMextra, CMexpel and CMevent.
        else => {},
    }
}

fn procstopped(a: ?*anyopaque) bool {
    const p: *Proc = @ptrCast(@alignCast(a.?));
    return p.state == .Stopped;
}

/// Read or write the memory of p at `offset`.  `a` is only read from
/// when writing.
fn procctlmemio(c: *Chan, p: *Proc, offset: usize, a: []u8, read: bool) Error!usize {
    var s: *Segment = undefined;
    var sio: *Segio = undefined;
    {
        try eqlock(&p.seglock);
        defer qunlock(&p.seglock);

        if (@backingInt(p.state) <= @backingInt(portdat.State.New) or p.pid != PID(c.qid))
            return error.Eprocdied;
        s = fault.seg(p, offset, true) orelse return error.Ebadarg;
        // s is locked
        const i = segment.segno(p, s);
        if (i < 0) {
            qunlock(&s.qlock);
            return error.Egreg; // segment gone
        }
        if (!read and (s.type & SG_TYPE) == SG_TEXT) {
            const n = segment.txt2data(s) catch |e| {
                qunlock(&s.qlock);
                return e;
            };
            if (!proc.canpage(p) or segment.detachseg(p, @intCast(i)) != s) {
                segment.putseg(n);
                qunlock(&s.qlock);
                return error.Egreg;
            }
            segment.attachseg(p, @intCast(i), n);
            qunlock(&s.qlock);
            segment.putseg(s);
            s = n;
        } else {
            qunlock(&s.qlock);
        }
        if (c.aux) |x| {
            sio = @ptrCast(@alignCast(x));
        } else {
            sio = alloc.snew(Segio);
            sio.* = .{};
            c.aux = sio;
        }
        _ = incref(&s.ref); // for us while we copy
    }

    defer segment.putseg(s);
    return segio(sio, s, a.ptr, a.len, @intCast(offset - s.base), read);
}

//
// Reading and writing the memory of a segment from outside the process
// it belongs to.
// from 9/port/segment.c
//
// M5: belongs in segment.zig
//

// M5: belongs in portdat.zig
const Segio = struct {
    qlock: ql.QLock = .{},
    cmdwait: portdat.Rendez = .{},
    replywait: portdat.Rendez = .{},

    p: ?*Proc = null, // segmentio kproc
    s: ?*Segment = null,

    data: [*]u8 = undefined,
    addr: usize = 0,
    dlen: usize = 0,
    cmd: i32 = Cnone,
    /// DIFF: the C keeps a pointer to the kproc's errstr; here the
    /// error and, for error.Str, a copy of its text.
    err: ?Error = null,
    errtext: [ERRMAX]u8 = @splat(0),
};

// commands to segmentioproc
const Cnone = 0;
const Cread = 1;
const Cwrite = 2;
const Cdie = 3;

fn cmddone(arg: ?*anyopaque) bool {
    const sio: *Segio = @ptrCast(@alignCast(arg.?));
    return sio.cmd == Cnone;
}

fn docmd(sio: *Segio, cmd: i32) Error!void {
    sio.err = null;
    sio.cmd = cmd;
    // while(waserror()) ; in the C: a note does not end the wait, it
    // starts it again.
    while (true) {
        _ = proc.wakeup(&sio.cmdwait);
        proc.sleep(&sio.replywait, cmddone, sio) catch continue;
        break;
    }
    if (sio.err) |e| {
        if (e == error.Str)
            return proc.errorf("%s", .{std.mem.sliceTo(&sio.errtext, 0)});
        return e;
    }
}

fn cmdready(arg: ?*anyopaque) bool {
    const sio: *Segio = @ptrCast(@alignCast(arg.?));
    return sio.cmd != Cnone;
}

/// A private copy of segment.zig's.
// M5: belongs in segment.zig
fn unusedsegno(i_: i32) usize {
    const up = arch.up().?;
    var i: usize = if (i_ < 0 or i_ == ESEG or up.seg[@intCast(i_)] != null) 0 else @intCast(i_);
    while (i < NSEG) : (i += 1) {
        if (up.seg[i] == null and i != ESEG)
            return i;
    }
    panic("segmentio: no free segment slot", .{});
}

/// DIFF (new): bring in every page of [addr, addr+len) of the kproc's
/// address space, for writing if `write`.  The C lets the memmove
/// fault and unwinds out of the trap with error(); a trap cannot
/// unwind Zig code, so the faults are taken here, in arch.probe, which
/// can fail.  fault() leaves the reason in up.errstr.
fn segtouch(addr: usize, len: usize, write: bool) Error!void {
    if (len == 0)
        return;
    var a = addr & ~@as(usize, BY2PG - 1);
    const last = (addr + len - 1) & ~@as(usize, BY2PG - 1);
    while (true) : (a += BY2PG) {
        // what the C raises when fault() gives no better reason
        proc.seterror(error.Eio);
        if (!arch.probe(a, write))
            return error.Str;
        if (a == last)
            break;
    }
}

/// One command for segmentioproc: the body of its loop that the C
/// guards with waserror.  Returns true when told to die.
fn segmentiocmd(sio: *Segio, segno: *usize) Error!bool {
    const up = arch.up().?;

    if (sio.s) |s| {
        if (up.seg[segno.*] != s) {
            qlock(&up.seglock);
            const tmp = segment.detachseg(up, segno.*);
            _ = incref(&s.ref);
            segno.* = unusedsegno(s.segno);
            segment.attachseg(up, segno.*, s);
            qunlock(&up.seglock);
            segment.putseg(tmp);

            arch.flushmmu();
        }
    }
    const user = @as([*]u8, @ptrFromInt(sio.addr))[0..sio.dlen];
    switch (sio.cmd) {
        Cread => {
            try segtouch(sio.addr, sio.dlen, false);
            @memcpy(sio.data[0..sio.dlen], user);
        },
        Cwrite => {
            try segtouch(sio.addr, sio.dlen, true);
            @memcpy(user, sio.data[0..sio.dlen]);
            if (sio.s.?.flushme)
                _ = try segment.segflush(sio.addr, sio.dlen);
        },
        Cdie => return true,
        else => {},
    }
    return false;
}

fn segmentioproc(arg: ?*anyopaque) void {
    const sio: *Segio = @ptrCast(@alignCast(arg.?));
    const up = arch.up().?;

    qlock(&up.seglock);
    sio.p = up;
    _ = incref(&sio.s.?.ref);
    var segno = unusedsegno(sio.s.?.segno);
    segment.attachseg(up, segno, sio.s.?);
    qunlock(&up.seglock);

    var done = false;
    while (!done) {
        // while(waserror()) ; in the C
        proc.sleep(&sio.cmdwait, cmdready, sio) catch {};
        if (segmentiocmd(sio, &segno)) |d| {
            done = d;
        } else |e| {
            if (e == error.Str)
                proc.kstrcpy(&sio.errtext, proc.errtext(e));
            sio.err = e;
        }
        sio.cmd = Cnone;
        _ = proc.wakeup(&sio.replywait);
    }

    proc.pexit("done", true);
}

/// Read into or write from `a` the n bytes at offset `off` of segment
/// s, through sio's kproc; with s null, stop the kproc.
fn segio(sio: *Segio, s_: ?*Segment, a: ?[*]u8, n_: usize, off: i64, read: bool) Error!usize {
    var n = n_;
    var b = a;
    var bounce: ?[*]u8 = null;
    defer alloc.free(bounce);

    if (s_) |s| {
        const m = s.top - s.base;
        if (off < 0 or @as(usize, @intCast(off)) >= m) {
            if (!read)
                return error.Ebadarg;
            return 0;
        }
        const o: usize = @intCast(off);
        if (o + n > m) {
            if (!read)
                return error.Ebadarg;
            n = m - o;
        }

        // DIFF: (uintptr)a < KZERO in the C; see the header.
        if (@intFromPtr(a.?) < mem.USTKTOP) {
            bounce = alloc.smalloc(n);
            b = bounce;
            if (!read)
                @memcpy(bounce.?[0..n], a.?[0..n]);
        }
    }

    {
        try eqlock(&sio.qlock);
        defer qunlock(&sio.qlock);

        sio.s = s_;
        const s = s_ orelse {
            if (sio.p != null) {
                try docmd(sio, Cdie);
                sio.p = null;
            }
            return 0;
        };
        if (sio.p == null) {
            sio.cmd = Cnone;
            proc.kproc("segmentio", segmentioproc, sio);
        }
        sio.addr = s.base + @as(usize, @intCast(off));
        sio.data = b.?;
        sio.dlen = n;
        try docmd(sio, if (read) Cread else Cwrite);
    }

    if (bounce) |x| {
        if (read)
            @memcpy(a.?[0..n], x[0..n]);
    }
    return n;
}
