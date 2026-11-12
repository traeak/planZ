//! The process system calls: rfork, exec, exits, await, notes, sleep,
//! alarm, error strings, segments, rendezvous and semaphores.
//! from 9/port/sysproc.c
//!
//! DIFF:
//!   - A handler takes *Sargs and returns Error!usize where the C takes
//!     a va_list and raises errors with error().  Each waserror site is
//!     a defer, an errdefer or a catch; see sysrfork and sysexec.
//!   - dosyscall and donotify are in syscall.zig; return0 is in proc.zig
//!     and only named here.
//!   - User addresses arrive as usize.  The new stack that sysexec
//!     builds is addressed with integers (charp, argv, tos are usize)
//!     and written through small helpers (ubytes, uword, putword,
//!     putstr, ustrlen).
//!   - Strings are slices: file, elem and the interpreter's arguments
//!     carry no NUL in the kernel and get one when they are copied to
//!     the stack.  up.text and up.args are slices too.
//!   - sysrfork: the part the C runs under the "abortion" waserror is
//!     the function rforkchild.  abortion() does spllo() first, as
//!     every other first function of a process does.
//!   - sysexec is two functions.  sysexec checks the arguments and is
//!     the C's outermost waserror ("Disaster after commit"); exec1 is
//!     everything inside it.  The inner waserror blocks are errdefers
//!     in exec1, which have all run by the time sysexec sees the error.
//!     tc is null while no channel is open (between a script and its
//!     interpreter).
//!   - sysexec: the a.out header is read through an Exec laid out
//!     here; only arch.AOUT_MAGIC is accepted, and the segment
//!     alignment comes from the same table as the C's switch (segalign).
//!     The error text given to pexit after the point of no return is
//!     copied to the stack first, because pexit can overwrite
//!     up.errstr.
//!   - mount cache: cclunk(tc) in sysexec is cache.c and is left out.
//!   - edf, swap and syscall trace are not ported; each site is marked.
//!   - legacy: sys_wait fails with "old wait system call - recompile"
//!     (it needs OWaitmsg).  sys_errstr and sys_nsec are one line each
//!     and are kept.
//!   - sysawait and werrstr format with fmt.snprint, which does not
//!     write a NUL; it is added here.
//!   - sysnoted: the saved-Ureg pointer that comes back from user
//!     memory must be aligned for a Ureg, or the process dies as for
//!     any other bad ureg.  The C accepts it and fails later, or not
//!     at all; a misaligned *Ureg is not something Zig can hold.
//!   - Semaphores: the address checks that syssemacquire,
//!     systsemacquire and syssemrelease each spell out in C are one
//!     function, semaddr.  The address must be aligned for a long (Ebadarg
//!     otherwise) on every architecture, since the value is used with
//!     atomic operations through a *i32.  Sema.waiting is read and
//!     written with atomic loads and stores as well as the C's
//!     coherence() calls.
//!   - evenaddr is an architecture hook in C; here it is a private
//!     function on top of arch.validalign.
//!   - NCONT, NDFLT, NSAVE, NRSTR (libc.h), fullrune and utfecpy (libc)
//!     are private here until lib.zig has them.
//!   - A fault on user memory inside the kernel cannot unwind (see
//!     fault.zig), so where the C counts on error() from a fault after
//!     validaddr (canacquire, the argument copy in sysexec) this kernel
//!     panics if the address has gone away in between.

const std = @import("std");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const lib = @import("lib.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const chan = @import("chan.zig");
const devmod = @import("dev.zig");
const pgrp = @import("pgrp.zig");
const devenv = @import("devenv.zig");
const segment = @import("segment.zig");
const fault = @import("fault.zig");
const sysfile = @import("sysfile.zig");
const alarm = @import("alarm.zig");
const tod = @import("tod.zig");
const portclock = @import("portclock.zig");
const parse = @import("parse.zig");
const devcons = @import("devcons.zig");
const p9 = @import("print.zig");

const mem = arch.mem;
const BY2PG = mem.BY2PG;
const BY2WD = mem.BY2WD;
const PGSHIFT = mem.PGSHIFT;
const PGROUND = mem.PGROUND;
const UTZERO = mem.UTZERO;
const USTKTOP = mem.USTKTOP;
const USTKSIZE = mem.USTKSIZE;

const panic = p9.panic;
const pprint = devcons.pprint;
const lock = taslock.lock;
const unlock = taslock.unlock;
const qlock = ql.qlock;
const qunlock = ql.qunlock;
const incref = portdat.incref;
const cclose = chan.cclose;
const namec = chan.namec;
const validaddr = fault.validaddr;
const okaddr = fault.okaddr;
const vmemchr = fault.vmemchr;
const userslice = fault.userslice;
const userstr = fault.userstr;
const userstrn = fault.userstrn;
const newseg = segment.newseg;
const attachseg = segment.attachseg;
const detachseg = segment.detachseg;
const putseg = segment.putseg;

pub const Error = proc.Error;
const Sargs = portdat.Sargs;
const Proc = portdat.Proc;
const Segment = portdat.Segment;
const Image = portdat.Image;
const Sema = portdat.Sema;
const Chan = portdat.Chan;
const Tos = portdat.Tos;
const Waitmsg = portdat.Waitmsg;
const Ureg = arch.Ureg;

const ERRMAX = portdat.ERRMAX;
const NSEG = portdat.NSEG;
const SSEG = portdat.SSEG;
const TSEG = portdat.TSEG;
const DSEG = portdat.DSEG;
const BSEG = portdat.BSEG;
const ESEG = portdat.ESEG;
const SG_TYPE = portdat.SG_TYPE;
const SG_TEXT = portdat.SG_TEXT;
const SG_DATA = portdat.SG_DATA;
const SG_BSS = portdat.SG_BSS;
const SG_STACK = portdat.SG_STACK;
const SG_SHARED = portdat.SG_SHARED;
const SG_RONLY = portdat.SG_RONLY;
const SG_CEXEC = portdat.SG_CEXEC;
const SG_NOEXEC = portdat.SG_NOEXEC;
const NDebug = portdat.NDebug;
const TUser = portdat.TUser;
const TSys = portdat.TSys;
const TReal = portdat.TReal;

const RFNAMEG = pgrp.RFNAMEG;
const RFENVG = pgrp.RFENVG;
const RFFDG = pgrp.RFFDG;
const RFNOTEG = pgrp.RFNOTEG;
const RFPROC = pgrp.RFPROC;
const RFMEM = pgrp.RFMEM;
const RFNOWAIT = pgrp.RFNOWAIT;
const RFCNAMEG = pgrp.RFCNAMEG;
const RFCENVG = pgrp.RFCENVG;
const RFCFDG = pgrp.RFCFDG;
const RFREND = pgrp.RFREND;
const RFNOMNT = pgrp.RFNOMNT;

// arguments of noted(), from /sys/include/libc.h
// M4: move to lib.zig
const NCONT = 0; // continue after note
const NDFLT = 1; // terminate after note
const NSAVE = 2; // clear note but hold state
const NRSTR = 3; // restore saved state

// from /sys/include/a.out.h

/// The a.out(6) header.  Every field is big-endian in the file.
const Exec = extern struct {
    magic: u32, // magic number
    text: u32, // size of text segment
    data: u32, // size of initialized data
    bss: u32, // size of uninitialized data
    syms: u32, // size of symbol table
    entry: u32, // entry point
    spsz: u32, // size of pc/sp offset table
    pcsz: u32, // size of pc/line number table
};

const HDR_MAGIC = 0x00008000; // header expansion

fn _MAGIC(f: u32, b: u32) u32 {
    return f | (((4 * b) + 0) * b + 7);
}
const V_MAGIC = _MAGIC(0, 16); // mips 3000 BE
const P_MAGIC = _MAGIC(0, 24); // mips 3000 LE
const S_MAGIC = _MAGIC(HDR_MAGIC, 26); // amd64
const R_MAGIC = _MAGIC(HDR_MAGIC, 28); // arm64

/// What sysexec reads of a file: the Exec and, with HDR_MAGIC, the
/// 64-bit entry point after it.  u.ehdr in the C.
const Ehdr = extern struct {
    exec: Exec,
    hdr: [1]u64,
};

comptime {
    if (@sizeOf(Exec) != 32 or @sizeOf(Ehdr) != 40) @compileError("a.out header layout");
}

/// The bytes at a user address that has been checked.
fn ubytes(addr: usize, n: usize) []u8 {
    return @as([*]u8, @ptrFromInt(addr))[0..n];
}

/// The word at a user address that has been checked.
fn uword(addr: usize) usize {
    return @as(*align(1) const usize, @ptrFromInt(addr)).*;
}

fn putword(addr: usize, v: usize) void {
    @as(*align(1) usize, @ptrFromInt(addr)).* = v;
}

/// Copy s and a NUL to a user address; memmove(addr, s, strlen(s)+1).
fn putstr(addr: usize, s: []const u8) void {
    const d = ubytes(addr, s.len + 1);
    @memcpy(d[0..s.len], s);
    d[s.len] = 0;
}

/// strlen of the string at an address on the new stack.
fn ustrlen(addr: usize) usize {
    return std.mem.len(@as([*:0]const u8, @ptrFromInt(addr)));
}

/// What the architecture's evenaddr does in C: an address that must be
/// aligned for a word.
// M4: move to arch.zig
fn evenaddr(addr: usize) Error!void {
    if (!arch.validalign(addr)) {
        _ = proc.postnote(arch.up(), true, "sys: odd address", NDebug);
        return error.Ebadarg;
    }
}

/// from libc/port/rune.c
// M4: move to lib.zig
fn fullrune(s: []const u8) bool {
    if (s.len == 0)
        return false;
    const c = s[0];
    if (c < 0x80) // Tx
        return true;
    if (c < 0xE0) // T3
        return s.len >= 2;
    if (c < 0xF0) // T4
        return s.len >= 3;
    return s.len >= 4;
}

/// Copy the string at the start of `from` into `to`, cutting it at a
/// rune boundary if it does not fit; `to` always ends up terminated.
/// At most to.len bytes of `from` are looked at.  Returns the length
/// of the result.
/// from libc/port/utfecpy.c
// M4: move to lib.zig
fn utfecpy(to: []u8, from: []const u8) usize {
    if (to.len == 0)
        return 0;
    const n = @min(to.len, from.len);
    if (std.mem.findScalar(u8, from[0..n], 0)) |i| {
        @memcpy(to[0 .. i + 1], from[0 .. i + 1]);
        return i;
    }
    @memcpy(to[0..n], from[0..n]);
    var end = n;
    if (end == to.len) {
        while (end > 0) {
            end -= 1;
            if (to[end] & 0xC0 != 0x80)
                break;
        }
    }
    to[end] = 0;
    return end;
}

pub fn sysr1(_: *Sargs) Error!usize {
    if (!devcons.iseve())
        return error.Eperm;
    return 0;
}

fn abortion() callconv(.c) noreturn {
    // DIFF: the C leaves interrupts off until pexit first blocks
    _ = arch.spllo();
    proc.pexit("fork aborted", true);
}

/// Code using RFNOMNT expects to block all but
/// the following devices.
const nomntdevs = "|decp";

/// The part of sysrfork that gives the child p its memory and groups.
/// The C runs it under a waserror that aborts the child; sysrfork does
/// that when this fails.
fn rforkchild(p: *Proc, flag: u32) Error!void {
    const up = arch.up().?;

    // Make a new set of memory segments
    const n = flag & RFMEM != 0;
    {
        qlock(&p.seglock);
        defer qunlock(&p.seglock);
        for (0..NSEG) |i| {
            if (try segment.dupseg(i, n)) |s|
                attachseg(p, i, s);
        }
    }

    // File descriptors
    if (flag & (RFFDG | RFCFDG) != 0) {
        if (flag & RFFDG != 0)
            p.fgrp = try pgrp.dupfgrp(up.fgrp)
        else
            p.fgrp = try pgrp.dupfgrp(null);
    } else {
        p.fgrp = up.fgrp;
        _ = incref(&up.fgrp.?.ref);
    }

    // Process groups
    if (flag & (RFNAMEG | RFCNAMEG) != 0) {
        p.pgrp = try pgrp.newpgrp();
        try pgrp.pgrpcpy(p.pgrp.?, up.pgrp.?, flag);
    } else {
        p.pgrp = up.pgrp;
        _ = incref(&up.pgrp.?.ref);
    }

    // Rendezvous group
    if (flag & RFREND != 0)
        p.rgrp = try pgrp.newrgrp()
    else {
        p.rgrp = up.rgrp;
        _ = incref(&up.rgrp.?.ref);
    }

    // Environment group
    if (flag & (RFENVG | RFCENVG) != 0) {
        p.egrp = try devenv.newegrp();
        if (flag & RFENVG != 0)
            try devenv.envcpy(p.egrp.?, up.egrp.?);
    } else {
        p.egrp = up.egrp;
        _ = incref(&up.egrp.?.ref);
    }

    arch.procfork(p);
}

pub fn sysrfork(a: *Sargs) Error!usize {
    const up = arch.up().?;

    const flag = a.next(u32);
    // Check flags before we commit
    if ((flag & (RFFDG | RFCFDG)) == (RFFDG | RFCFDG))
        return error.Ebadarg;
    if ((flag & (RFNAMEG | RFCNAMEG)) == (RFNAMEG | RFCNAMEG))
        return error.Ebadarg;
    if ((flag & (RFENVG | RFCENVG)) == (RFENVG | RFCENVG))
        return error.Ebadarg;

    if ((flag & RFPROC) == 0) {
        if (flag & (RFMEM | RFNOWAIT) != 0)
            return error.Ebadarg;

        const ofg = up.fgrp;
        const opg = up.pgrp;
        const org = up.rgrp;
        const oeg = up.egrp;

        {
            errdefer {
                if (up.fgrp != ofg) {
                    pgrp.closefgrp(up.fgrp);
                    up.fgrp = ofg;
                }
                if (up.pgrp != opg) {
                    pgrp.closepgrp(up.pgrp.?);
                    up.pgrp = opg;
                }
                if (up.rgrp != org) {
                    pgrp.closergrp(up.rgrp.?);
                    up.rgrp = org;
                }
                if (up.egrp != oeg) {
                    devenv.closeegrp(up.egrp.?);
                    up.egrp = oeg;
                }
            }

            // File descriptors
            if (flag & (RFFDG | RFCFDG) != 0) {
                if (flag & RFFDG != 0)
                    up.fgrp = try pgrp.dupfgrp(ofg)
                else
                    up.fgrp = try pgrp.dupfgrp(null);
            }

            // Process group
            if (flag & (RFNAMEG | RFCNAMEG) != 0) {
                up.pgrp = try pgrp.newpgrp();
                try pgrp.pgrpcpy(up.pgrp.?, opg.?, flag);
            }

            // Rendezvous group
            if (flag & RFREND != 0)
                up.rgrp = try pgrp.newrgrp();

            // Environment group
            if (flag & (RFENVG | RFCENVG) != 0) {
                up.egrp = try devenv.newegrp();
                if (flag & RFENVG != 0)
                    try devenv.envcpy(up.egrp.?, oeg.?);
            }

            if (ofg != up.fgrp)
                pgrp.closefgrp(ofg);
            if (opg != up.pgrp)
                pgrp.closepgrp(opg.?);
            if (org != up.rgrp)
                pgrp.closergrp(org.?);
            if (oeg != up.egrp)
                devenv.closeegrp(oeg.?);
        }

        if (flag & RFNOMNT != 0)
            pgrp.devmask(up.pgrp.?, true, nomntdevs);

        if (flag & RFNOTEG != 0) {
            qlock(&up.debug);
            _ = proc.setnoteid(up, 0) catch {}; // can't error() with 0 argument
            qunlock(&up.debug);
        }
        return 0;
    }

    const p = proc.newproc() orelse return proc.errorf("no procs", .{});

    qlock(&up.debug);
    qlock(&p.debug);

    p.scallnr = up.scallnr;
    p.s = up.s;
    p.slash = up.slash;
    p.dot = up.dot;
    _ = incref(&p.dot.?.ref);

    p.nnote = 0;
    p.notify = up.notify;
    p.notified = false;
    p.notepending = false;
    p.lastnote = null;

    if ((flag & RFNOTEG) == 0)
        p.noteid = up.noteid;

    p.procmode = up.procmode;
    p.privatemem = up.privatemem;
    p.noswap = up.noswap;
    p.hang = up.hang;
    // DIFF: syscall trace — the child of a traced process is traced
    p.kp = false;

    // Craft a return frame which will cause the child to pop out of
    // the scheduler in user mode with the return register zero
    arch.forkchild(p, up.dbgreg.?);

    proc.kstrdup(&p.text, up.text);
    proc.kstrdup(&p.user, up.user);
    proc.kstrdup(&p.args, "");
    p.nargs = 0;
    p.setargs = false;

    p.insyscall = 0;
    p.time = @splat(0);
    p.time[TReal] = arch.MACHP(0).ticks;
    p.kentry = up.kentry;
    p.pcycles = -%@as(i64, @bitCast(p.kentry));

    const pid = proc.pidalloc(p);

    qunlock(&p.debug);
    qunlock(&up.debug);

    // Abort the child process on error
    rforkchild(p, flag) catch |e| {
        p.kp = true;
        arch.kprocchild(p, abortion);
        proc.ready(p);
        return e;
    };

    if (flag & RFNOMNT != 0)
        pgrp.devmask(p.pgrp.?, true, nomntdevs);

    if ((flag & RFNOWAIT) == 0) {
        p.parent = up;
        lock(&up.exl);
        up.nchild += 1;
        unlock(&up.exl);
    }

    //  since the bss/data segments are now shareable,
    //  any mmu info about this process is now stale
    //  (i.e. has bad properties) and has to be discarded.
    arch.flushmmu();

    proc.procpriority(p, @intCast(up.basepri), up.fixedpri);
    if (up.wired)
        proc.procwired(p, up.affinity);

    proc.ready(p);
    proc.sched();
    return pid;
}

pub fn beswal(l: u32) u32 {
    return std.mem.bigToNative(u32, l);
}

pub fn beswav(v: u64) u64 {
    return std.mem.bigToNative(u64, v);
}

/// The alignment (as a mask) of the data segment of an executable with
/// this magic number; the switch in the C's sysexec.
fn segalign(magic: u32) usize {
    return switch (magic) {
        S_MAGIC => 0x1fffff, // 2MB segment alignment for amd64
        P_MAGIC, // 16K segment alignment for spim
        V_MAGIC, // 16K segment alignment for mips
        => 0x3fff,
        R_MAGIC => 0xffff, // 64K segment alignment for arm64
        else => BY2PG - 1,
    };
}

pub fn sysexec(a: *Sargs) Error!usize {
    const ufile = a.next(usize);
    try validaddr(ufile, 1, false);
    const argp = a.next(usize);
    try evenaddr(argp);
    try validaddr(argp, 2 * BY2WD, false);
    if (uword(argp) == 0)
        return error.Ebadarg;
    return exec0(try userstr(ufile), .{ .cstr = argp });
}

/// DIFF (new): one argument of planZ's exec, as the user passes it.
pub const Upair = extern struct {
    ptr: u64,
    len: u64,
};

/// DIFF (new): planZ's exec(file, filelen, args, nargs), where args is
/// an array of nargs (pointer, length) pairs.  The array is copied into
/// the kernel once, so another process sharing the memory cannot change
/// a pair between its check and its use.  The new process's stack is
/// the same as 9front's exec makes (argv of 0-terminated strings), since
/// the program may be a stock C one.
pub fn sysexecn(a: *Sargs) Error!usize {
    const ufile = a.next(usize);
    const unamelen = a.next(usize);
    const uargs = a.next(usize);
    const nargs = a.next(usize);
    // each argument takes at least a pointer and a 0 on the new stack
    if (nargs < 1 or nargs >= USTKSIZE / (BY2WD + 1))
        return error.Ebadarg;
    if (uargs % @alignOf(Upair) != 0)
        return error.Ebadarg;
    const ua = try userslice(uargs, nargs * @sizeOf(Upair), false);
    const pairs = alloc.newslice(Upair, nargs) orelse return error.Enomem;
    defer alloc.free(pairs.ptr);
    @memcpy(std.mem.sliceAsBytes(pairs), ua);
    return exec0(try userstrn(ufile, unamelen), .{ .pairs = pairs });
}

/// DIFF (new): where exec's user arguments come from.
const Uargs = union(enum) {
    /// 9front's: the address of a nil-ended array of addresses of
    /// 0-terminated strings
    cstr: usize,
    /// planZ's: the kernel's copy of the (pointer, length) pairs
    pairs: []const Upair,
};

fn exec0(ufile: []const u8, uargs: Uargs) Error!usize {
    const up = arch.up().?;

    // The C's outermost waserror.  By the time exec1 has returned an
    // error it has released everything else it held.
    return exec1(ufile, uargs) catch |e| {
        // Disaster after commit
        if (up.seg[SSEG] == null) {
            var estr: [ERRMAX]u8 = undefined;
            const t = proc.errtext(e);
            const n = @min(t.len, estr.len);
            @memcpy(estr[0..n], t[0..n]);
            proc.pexit(estr[0..n], true);
        }
        qlock(&up.seglock);
        const s = detachseg(up, ESEG);
        qunlock(&up.seglock);
        if (s != null) {
            putseg(s);
            arch.flushmmu();
        }
        return e;
    };
}

/// The body of sysexec, from the point where the C sets its first
/// error label.
fn exec1(ufile: []const u8, uargs_: Uargs) Error!usize {
    const up = arch.up().?;
    var uargs = uargs_;
    var buf: [256]u8 align(@alignOf(Ehdr)) = undefined; // u.buf
    const ehdr: *const Ehdr = @ptrCast(&buf); // u.ehdr
    var progarg: [32 + 1][]u8 = undefined;

    const file = try chan.validnamedup(ufile, true);
    errdefer alloc.free(file.ptr);

    // DIFF: null between closing a script and opening its interpreter,
    // where the C has popped the waserror that closes it.
    var tc: ?*Chan = try namec(file, portdat.Aopen, lib.OEXEC, 0);
    errdefer if (tc) |c| cclose(c);

    // Last path element becomes up->text (and argv[0] for script)
    var elem: []u8 = portdat.nostr;
    proc.kstrdup(&elem, std.mem.sliceTo(&up.genbuf, 0));
    errdefer alloc.free(elem.ptr);

    // Attach new stack segment, place it below current stack
    var tstk: usize = undefined;
    {
        qlock(&up.seglock);
        defer qunlock(&up.seglock);
        var s = up.seg[SSEG].?;
        while (true) {
            tstk = s.base;
            if (tstk <= USTKSIZE)
                return error.Enovmem;
            s = segment.isoverlap(tstk - USTKSIZE, USTKSIZE) orelse break;
        }
        attachseg(up, ESEG, try newseg(SG_STACK | SG_NOEXEC, tstk - USTKSIZE, USTKSIZE / BY2PG));
    }

    // Setup TOS; paged in on demand
    var tos: usize = tstk - @sizeOf(Tos);
    {
        const t: *Tos = @ptrFromInt(tos);
        t.* = .{};
        t.cyclefreq = if (@hasField(arch.Mach, "cyclefreq")) arch.m().cyclefreq else 0;
    }

    // Stash interpreter args below TOS
    var charp: usize = tos;
    var argc: usize = 0;

    // Read a.out(6) header
    var magic: u32 = 0;
    var n: usize = 0;
    var indir: usize = 0;
    while (true) : (indir += 1) {
        n = try devmod.devtab[tc.?.type].read(tc.?, &buf, 0);
        if (n >= @sizeOf(Exec)) {
            magic = beswal(ehdr.exec.magic);
            if (magic == arch.AOUT_MAGIC)
                break; // for binary
        }

        // Process #! /bin/sh args ...
        if (n <= 2 or buf[0] != '#' or buf[1] != '!')
            return error.Ebadexec;
        const nl = std.mem.findScalar(u8, buf[2..n], '\n') orelse return error.Ebadexec;
        // the C makes a string of the line, so it ends at the first NUL
        const line = buf[2..][0 .. std.mem.findScalar(u8, buf[2..][0..nl], 0) orelse nl];

        // First arg becomes complete file name
        if (indir == 0) {
            argc += 1;
            n = file.len + 1;
            charp -= n;
            if (charp <= tstk - USTKSIZE)
                return error.Enovmem;
            putstr(charp, file);
        } else if (indir >= 8)
            return error.Ebadexec;

        var i = parse.tokenize(line, &progarg);
        if (i < 1 or i >= progarg.len)
            return error.Ebadexec;

        // Push interpreter args in reverse order
        argc += i;
        while (i > 0) {
            i -= 1;
            const arg = progarg[i];
            n = arg.len + 1;
            charp -= n;
            if (charp <= tstk - USTKSIZE)
                return error.Enovmem;
            putstr(charp, arg);
        }
        cclose(tc.?);
        tc = null;

        // Open interpreter
        tc = try namec(progarg[0], portdat.Aopen, lib.OEXEC, 0);
    }

    // Process a.out(6) header
    var entry: usize = undefined;
    var text: usize = undefined;
    if (magic & HDR_MAGIC != 0) {
        if (n < @sizeOf(Ehdr))
            return error.Ebadexec;
        entry = beswav(ehdr.hdr[0]);
        text = UTZERO + @sizeOf(Ehdr);
    } else {
        entry = beswal(ehdr.exec.entry);
        text = UTZERO + @sizeOf(Exec);
    }
    if (entry < text)
        return error.Ebadexec;
    text += beswal(ehdr.exec.text);
    if (text <= entry or text >= (USTKTOP - USTKSIZE))
        return error.Ebadexec;

    var algn: usize = segalign(magic);

    const adata = (text + algn) & ~algn;
    text -= UTZERO;
    const data: usize = beswal(ehdr.exec.data);
    const bss: usize = beswal(ehdr.exec.bss);
    algn = BY2PG - 1;

    const abss = (adata + data + algn) & ~algn;
    const ebss = (adata + data + bss + algn) & ~algn;
    if (adata >= (USTKTOP - USTKSIZE) or abss >= (USTKTOP - USTKSIZE) or ebss >= (USTKTOP - USTKSIZE))
        return error.Ebadexec;

    // Replace argv[0] with script name
    if (indir != 0) {
        n = ustrlen(charp) + 1;
        charp += n;
        n = elem.len + 1;
        charp -= n;
        if (charp <= tstk - USTKSIZE)
            return error.Enovmem;
        putstr(charp, elem);
        switch (uargs) {
            .cstr => |*argp| argp.* += BY2WD,
            .pairs => |*pairs| pairs.* = pairs.*[1..],
        }
    }

    // Count user arguments
    var nbytes: usize = tstk - charp;
    var i: usize = 0;
    switch (uargs) {
        .cstr => |argp| while (true) : (i += 1) {
            const ap = argp + i * BY2WD; // &argp[i]
            const ua = uword(ap);
            if (ua == 0)
                break;
            try validaddr(ua, 1, false);
            const e = (try vmemchr(ua, 0, USTKSIZE - nbytes)) orelse return error.Ebadarg;
            nbytes += e + 1;
            if (nbytes >= USTKSIZE)
                return error.Enovmem;
            // crossing page boundary?
            if ((ap & (BY2PG - 1)) >= BY2PG - BY2WD)
                try validaddr(ap + BY2WD, BY2WD, false);
        },
        .pairs => |pairs| for (pairs) |p| {
            if (p.len >= USTKSIZE - nbytes)
                return error.Enovmem;
            _ = try userstrn(p.ptr, p.len);
            nbytes += p.len + 1;
            if (nbytes >= USTKSIZE)
                return error.Enovmem;
            i += 1;
        },
    }
    argc += i;
    if (argc < 1)
        return error.Ebadarg;

    var ssize: usize = BY2WD * (argc + 1) + ((nbytes + (BY2WD - 1)) & ~@as(usize, BY2WD - 1));

    // 8-byte align SP for those (e.g. sparc) that need it.
    // execregs() will subtract another 4 bytes for argc.
    if (BY2WD == 4 and (ssize + 4) & 7 != 0)
        ssize += 4;

    if (PGROUND(ssize) >= USTKSIZE)
        return error.Enovmem;

    // save interpreter args
    var ia = charp;

    // Now we know the actual stack size and argument count,
    // copy in the strings to charp and build argv[] array.
    var argv: usize = tstk - ssize;
    charp = tstk - nbytes;

    i = 0;
    if (indir != 0) { // move interpreter args down before user args
        while (i < argc and ia < tos) : (i += 1) {
            n = ustrlen(ia) + 1;
            @memmove(ubytes(charp, n), ubytes(ia, n));
            putword(argv + i * BY2WD, charp + (USTKTOP - tstk));
            charp += n;
            ia += n;
        }
    }
    var j: usize = 0; // index into uargs.pairs
    while (i < argc) : (i += 1) {
        switch (uargs) {
            .cstr => |*argp| {
                const ua = uword(argp.*);
                argp.* += BY2WD;
                try validaddr(ua, 1, false);
                if (charp >= tos)
                    return error.Ebadarg;
                const e = (try vmemchr(ua, 0, tos - charp)) orelse return error.Ebadarg;
                n = e + 1;
                @memmove(ubytes(charp, n), ubytes(ua, n));
            },
            .pairs => |pairs| {
                const p = pairs[j];
                j += 1;
                if (p.len >= tos - charp)
                    return error.Ebadarg;
                const src = try userstrn(p.ptr, p.len);
                const dst = ubytes(charp, p.len + 1);
                @memmove(dst[0..p.len], src);
                // A 0 byte cannot be carried in the new stack's
                // 0-terminated argv.  The check is on the copy, which no
                // other process can change.
                if (std.mem.findScalar(u8, dst[0..p.len], 0) != null)
                    return error.Ebadarg;
                dst[p.len] = 0;
                n = p.len + 1;
            },
        }
        putword(argv + i * BY2WD, charp + (USTKTOP - tstk));
        charp += n;
    }
    putword(argv + i * BY2WD, 0);

    // Copy args for proc(3); easiest from new process's stack
    const astart = tstk - nbytes;
    var nargs: usize = charp - astart;
    if (nargs > 128) // don't waste too much space on huge arg lists
        nargs = 128;
    const args = (alloc.malloc(nargs) orelse return error.Enomem)[0..nargs];
    errdefer alloc.free(args.ptr);
    @memcpy(args, ubytes(astart, nargs));
    if (nargs > 0 and args[nargs - 1] != 0) {
        // make sure last arg is NUL-terminated
        // put NUL at UTF-8 character boundary
        i = nargs - 1;
        while (i > 0) : (i -= 1) {
            if (fullrune(args[i..nargs]))
                break;
        }
        args[i] = 0;
        nargs = i + 1;
    }

    // Attach text segment
    // attachimage returns a locked cache image
    const img = try segment.attachimage(tc.?, (PGROUND(text) + PGROUND(data)) >> PGSHIFT);
    const ts: *Segment = blk: {
        if (img.s) |cached| {
            if (cached.flen == text) {
                if (cached.image != img) panic("sysexec: text segment of another image", .{});
                _ = incref(&cached.ref);
                segment.putimage(img);
                break :blk cached;
            }
        }
        const new = newseg(SG_TEXT | SG_RONLY, UTZERO, PGROUND(text) >> PGSHIFT) catch |e| {
            segment.putimage(img);
            return e;
        };
        new.image = img;
        new.fstart = 0;
        new.flen = text;
        img.s = new;
        unlock(&img.lock);
        break :blk new;
    };

    // Committed.
    // Free old memory. (in reverse order)
    // Special segments are maintained across exec
    {
        qlock(&up.seglock);
        defer qunlock(&up.seglock);

        i = NSEG - 1;
        while (i > ESEG) : (i -= 1) {
            if (up.seg[i]) |s| {
                if ((s.type & SG_CEXEC) != 0)
                    putseg(detachseg(up, i));
            }
        }
        i = ESEG;
        while (i > 0) {
            i -= 1;
            putseg(detachseg(up, i));
        }

        // From here to the end of this block up.seg[SSEG] is nil, and
        // an error kills the process (see sysexec).

        // Text. Shared.
        if (ts.ref.ref <= 0) panic("sysexec: text segment ref", .{});
        attachseg(up, TSEG, ts);

        // Data. Shared.
        var s = try newseg(SG_DATA, adata, PGROUND(data) >> PGSHIFT);
        s.image = img;
        s.fstart = text;
        s.flen = data;
        _ = incref(&img.ref);
        attachseg(up, DSEG, s);

        // BSS. Zero fill on demand
        attachseg(up, BSEG, try newseg(SG_BSS, abss, (ebss - abss) >> PGSHIFT));

        // Move the stack
        s = detachseg(up, ESEG).?;
        segment.relocateseg(s, USTKTOP - USTKSIZE);
        attachseg(up, SSEG, s);
    }

    // Nothing below fails: the C pops all its error labels here.

    if (tc.? == img.c) {
        // avoid double caching
        tc.?.flag &= ~@as(u16, portdat.CCACHE);
        // DIFF: mount cache — cclunk(tc)
    }
    cclose(tc.?);
    tc = null;
    alloc.free(file.ptr);

    // Close on exec
    if (up.fgrp) |f| {
        var fd: i32 = 0;
        while (fd <= f.maxfd) : (fd += 1)
            sysfile.fdclose(fd, portdat.CCEXEC);
    }

    qlock(&up.debug);
    if (up.text.ptr != portdat.nostr.ptr)
        alloc.free(up.text.ptr);
    up.text = elem;
    if (up.args.ptr != portdat.nostr.ptr)
        alloc.free(up.args.ptr);
    up.args = args[0..nargs];
    up.nargs = @intCast(nargs);
    up.setargs = false;

    proc.freenotes(up);
    proc.freenote(up.lastnote);
    up.lastnote = null;
    up.notify = 0;
    up.notified = false;
    up.noteureg = null;
    up.privatemem = false;
    up.noswap = false;
    up.pcycles = -%@as(i64, @bitCast(up.kentry));
    arch.procsetup(up);
    qunlock(&up.debug);

    up.errbuf0[0] = 0;
    up.errbuf1[0] = 0;

    //  At this point, the mmu contains info about the old address
    //  space and needs to be flushed
    arch.flushmmu();

    if (up.hang)
        up.procctl = portdat.Proc_stopme;

    tos = USTKTOP - @sizeOf(Tos);
    argv = USTKTOP - ssize;

    return arch.execregs(entry, argc, argv, tos);
}

/// DIFF: defined in proc.zig, which needed it first.
pub const return0 = proc.return0;

pub fn syssleep(a: *Sargs) Error!usize {
    const up = arch.up().?;

    const ms = a.next(i32);
    if (ms <= 0) {
        // DIFF: edf — an admitted real-time process calls edfyield()
        proc.yield();
    } else {
        try proc.tsleep(&up.sleep, return0, null, @intCast(ms));
    }
    return 0;
}

pub fn sysalarm(a: *Sargs) Error!usize {
    return alarm.procalarm(a.next(u32));
}

pub fn sysexits(a: *Sargs) Error!usize {
    const inval = "invalid exit string";
    var buf: [ERRMAX]u8 = undefined;

    const ustatus = a.next(usize);
    var status: ?[]const u8 = null;
    if (ustatus != 0) {
        status = blk: {
            validaddr(ustatus, 1, false) catch break :blk inval;
            const e = vmemchr(ustatus, 0, ERRMAX) catch break :blk inval;
            if (e) |len|
                break :blk ubytes(ustatus, len);
            @memcpy(&buf, ubytes(ustatus, ERRMAX));
            buf[ERRMAX - 1] = 0;
            break :blk buf[0 .. ERRMAX - 1];
        };
    }
    proc.pexit(status, true);
}

/// DIFF (new): planZ's exits(msg, msglen).  A null address is no
/// message, as in exits(nil); the message is cut at ERRMAX-1 bytes or
/// at a 0 byte, as 9front's exits reads it.
pub fn sysexitsn(a: *Sargs) Error!usize {
    const inval = "invalid exit string";
    var buf: [ERRMAX]u8 = undefined;

    const ustatus = a.next(usize);
    const ulen = @min(a.next(usize), ERRMAX - 1);
    var status: ?[]const u8 = null;
    if (ustatus != 0) {
        status = blk: {
            const u = userstrn(ustatus, ulen) catch break :blk inval;
            // copied, so it cannot change under pexit
            @memcpy(buf[0..u.len], u);
            const m = buf[0..u.len];
            break :blk m[0 .. std.mem.findScalar(u8, m, 0) orelse m.len];
        };
    }
    proc.pexit(status, true);
}

pub fn sys_wait(_: *Sargs) Error!usize {
    // DIFF: legacy
    return proc.errorf("old wait system call - recompile", .{});
}

pub fn sysawait(a: *Sargs) Error!usize {
    var w: Waitmsg = .{};

    const p = a.next(usize);
    const n = a.next(u32);
    const buf = try userslice(p, n, true);
    _ = try proc.pwait(&w);
    // snprint(p, n, ...): what fits, then a NUL
    if (buf.len == 0)
        return 0;
    const s = fmt.snprint(buf[0 .. buf.len - 1], "%d %lud %lud %lud %q", .{
        w.pid,
        w.time[TUser],
        w.time[TSys],
        w.time[TReal],
        std.mem.sliceTo(&w.msg, 0),
    });
    buf[s.len] = 0;
    return s.len;
}

pub fn werrstr(comptime format: []const u8, args: anytype) void {
    const up = arch.up() orelse return;

    const s = fmt.snprint(up.syserrstr[0 .. ERRMAX - 1], format, args);
    up.syserrstr[s.len] = 0;
}

fn generrstr(ubuf: usize, nbuf_: u32) Error!usize {
    const up = arch.up().?;
    var nbuf: usize = nbuf_;

    if (nbuf == 0)
        return error.Ebadarg;
    if (nbuf > ERRMAX)
        nbuf = ERRMAX;
    const buf = try userslice(ubuf, nbuf, true);

    const err = up.errstr;
    _ = utfecpy(err[0..nbuf], buf);
    _ = utfecpy(buf, up.syserrstr);

    up.errstr = up.syserrstr;
    up.syserrstr = err;

    return 0;
}

pub fn syserrstr(a: *Sargs) Error!usize {
    const buf = a.next(usize);
    const len = a.next(u32);
    return generrstr(buf, len);
}

/// compatibility for old binaries
pub fn sys_errstr(a: *Sargs) Error!usize {
    return generrstr(a.next(usize), 64);
}

pub fn sysnotify(a: *Sargs) Error!usize {
    const up = arch.up().?;

    const f = a.next(usize);
    if (f != 0)
        try validaddr(f, @sizeOf(usize), false);
    up.notify = f;
    return 0;
}

// DIFF: donotify is in syscall.zig.

pub fn sysnoted(a: *Sargs) Error!usize {
    const up = arch.up().?;

    const arg = a.next(i32);

    qlock(&up.debug);
    if (up.notified) {
        _ = arch.splhi();
        arch.fpunoted(up);
        _ = arch.spllo();
    } else if (arg != NRSTR) {
        qunlock(&up.debug);
        return error.Ebadarg;
    }
    qunlock(&up.debug);

    const nureg: usize = if (up.noteureg) |u| @intFromPtr(u) else 0;
    if (!okaddr(nureg -% BY2WD, BY2WD + @sizeOf(Ureg), false)) {
        _ = pprint("suicide: bad ureg in noted or call to noted when not notified\n", .{});
        proc.pexit("Suicide", false);
    }

    // The C's switch falls through from one case to the next.
    switch (arg) {
        NCONT, NRSTR, NSAVE => {
            if (arg != NSAVE) {
                // word under Ureg is old ureg
                const old = uword(nureg - BY2WD);
                // DIFF: see the header
                if (old % @alignOf(Ureg) != 0) {
                    _ = pprint("suicide: bad ureg in noted or call to noted when not notified\n", .{});
                    proc.pexit("Suicide", false);
                }
                up.noteureg = @ptrFromInt(old);
                // wet floor
            }
            if (!arch.noted(up.dbgreg.?, @ptrFromInt(nureg), arg)) {
                _ = pprint("suicide: trap in noted\n", .{});
                proc.pexit("Suicide", false);
            }
        },
        else => {
            // DIFF: the C would use a nil lastnote
            const lastnote = up.lastnote orelse proc.pexit("Suicide", false);
            if (arg != NDFLT)
                lastnote.flag = NDebug;
            _ = arch.noted(up.dbgreg.?, @ptrFromInt(nureg), arg); // for debugging
            const msg = std.mem.sliceTo(&lastnote.msg, 0);
            if (lastnote.flag == NDebug)
                _ = pprint("suicide: %s\n", .{msg});
            proc.pexit(msg, lastnote.flag != NDebug);
        },
    }

    // allow next note
    up.notified = false;

    return 0;
}

pub fn syssegbrk(a: *Sargs) Error!usize {
    const up = arch.up().?;

    const s = fault.seg(up, a.next(usize), false) orelse return error.Ebadarg;

    switch (s.type & SG_TYPE) {
        SG_BSS, SG_SHARED => {},
        else => return error.Ebadarg,
    }

    const i = segment.segno(up, s);
    if (i < 0)
        return error.Ebadarg;

    return segment.ibrk(@intCast(i), a.next(usize));
}

pub fn syssegattach(a: *Sargs) Error!usize {
    const attr = a.next(i32);
    const uname = a.next(usize);
    const va = a.next(usize);
    const len = a.next(u32);
    try validaddr(uname, 1, false);
    const name = try chan.validnamedup(try userstr(uname), true);
    defer alloc.free(name.ptr);
    return segment.segattach(@bitCast(attr), name, va, len);
}

/// DIFF (new): planZ's segattach(attr, class, classlen, va, len).
pub fn syssegattachn(a: *Sargs) Error!usize {
    const attr = a.next(i32);
    const uname = a.next(usize);
    const unamelen = a.next(usize);
    const va = a.next(usize);
    const len = a.next(u32);
    const name = try chan.validnamedup(try userstrn(uname, unamelen), true);
    defer alloc.free(name.ptr);
    return segment.segattach(@bitCast(attr), name, va, len);
}

pub fn syssegdetach(a: *Sargs) Error!usize {
    const up = arch.up().?;

    const s = blk: {
        qlock(&up.seglock);
        defer qunlock(&up.seglock);

        const s = fault.seg(up, a.next(usize), false) orelse return error.Ebadarg;

        // Check we are not detaching the initial stack segment.
        const i = segment.segno(up, s);
        if (i < 0 or i == SSEG)
            return error.Ebadarg;

        break :blk detachseg(up, @intCast(i));
    };

    putseg(s);

    // Ensure we flush any entries from the lost segment
    arch.flushmmu();
    return 0;
}

pub fn syssegflush(a: *Sargs) Error!usize {
    const va = a.next(usize);
    const len = a.next(u32);
    return @intCast(try segment.segflush(va, len));
}

pub fn syssegfree(a: *Sargs) Error!usize {
    const va = a.next(usize);
    const len = a.next(u32);
    return @intCast(try segment.segfree(va, len));
}

/// For binary compatibility
pub fn sysbrk_(a: *Sargs) Error!usize {
    return segment.ibrk(BSEG, a.next(usize));
}

pub fn sysrendezvous(a: *Sargs) Error!usize {
    const up = arch.up().?;

    const tag = a.next(usize);
    const new = a.next(usize);
    const rgrp = up.rgrp.?;
    var l: *?*Proc = &rgrp.rendhash[tag & (portdat.RENDHASH - 1)]; // REND(up->rgrp, tag)

    lock(&rgrp.lock);
    var it = l.*;
    while (it) |p| : (it = p.rendhash) {
        if (p.rendtag == tag) {
            l.* = p.rendhash;
            const val = p.rendval;
            p.rendval = new;
            unlock(&rgrp.lock);

            proc.ready(p);

            return val;
        }
        l = &p.rendhash;
    }

    // Going to sleep here
    up.rendtag = tag;
    up.rendval = new;
    up.rendhash = l.*;
    l.* = up;
    up.state = .Rendezvous;
    unlock(&rgrp.lock);

    proc.sched();

    return up.rendval;
}

// The implementation of semaphores is complicated by needing
// to avoid rescheduling in syssemrelease, so that it is safe
// to call from real-time processes.  This means syssemrelease
// cannot acquire any qlocks, only spin locks.
//
// Semacquire and semrelease must both manipulate the semaphore
// wait list.  Lock-free linked lists only exist in theory, not
// in practice, so the wait list is protected by a spin lock.
//
// The semaphore value *addr is stored in user memory, so it
// cannot be read or written while holding spin locks.
//
// Thus, we can access the list only when holding the lock, and
// we can access the semaphore only when not holding the lock.
// This makes things interesting.  Note that sleep's condition function
// is called while holding two locks - r and up->rlock - so it cannot
// access the semaphore value either.
//
// An acquirer announces its intention to try for the semaphore
// by putting a Sema structure onto the wait list and then
// setting Sema.waiting.  After one last check of semaphore,
// the acquirer sleeps until Sema.waiting==0.  A releaser of n
// must wake up n acquirers who have Sema.waiting set.  It does
// this by clearing Sema.waiting and then calling wakeup.
//
// There are three interesting races here.
//
// The first is that in this particular sleep/wakeup usage, a single
// wakeup can rouse a process from two consecutive sleeps!
// The ordering is:
//
//     (a) set Sema.waiting = 1
//     (a) call sleep
//     (b) set Sema.waiting = 0
//     (a) check Sema.waiting inside sleep, return w/o sleeping
//     (a) try for semaphore, fail
//     (a) set Sema.waiting = 1
//     (a) call sleep
//     (b) call wakeup(a)
//     (a) wake up again
//
// This is okay - semacquire will just go around the loop
// again.  It does mean that at the top of the for(;;) loop in
// semacquire, phore.waiting might already be set to 1.
//
// The second is that a releaser might wake an acquirer who is
// interrupted before he can acquire the lock.  Since
// release(n) issues only n wakeup calls -- only n can be used
// anyway -- if the interrupted process is not going to use his
// wakeup call he must pass it on to another acquirer.
//
// The third race is similar to the second but more subtle.  An
// acquirer sets waiting=1 and then does a final canacquire()
// before going to sleep.  The opposite order would result in
// missing wakeups that happen between canacquire and
// waiting=1.  (In fact, the whole point of Sema.waiting is to
// avoid missing wakeups between canacquire() and sleep().) But
// there can be spurious wakeups between a successful
// canacquire() and the following semdequeue().  This wakeup is
// not useful to the acquirer, since he has already acquired
// the semaphore.  Like in the previous case, though, the
// acquirer must pass the wakeup call along.
//
// This is all rather subtle.  The code below has been verified
// with the spin model /sys/src/9/port/semaphore.p.  The
// original code anticipated the second race but not the first
// or third, which were caught only with spin.  The first race
// is mentioned in /sys/doc/sleep.ps, but I'd forgotten about it.
// It was lucky that my abstract model of sleep/wakeup still managed
// to preserve that behavior.
//
// I remain slightly concerned about memory coherence
// outside of locks.  The spin model does not take
// queued processor writes into account so we have to
// think hard.  The only variables accessed outside locks
// are the semaphore value itself and the boolean flag
// Sema.waiting.  The value is only accessed with cmpswap,
// whose job description includes doing the right thing as
// far as memory coherence across processors.  That leaves
// Sema.waiting.  To handle it, we call coherence() before each
// read and after each write.        - rsc

/// The C's cmpswap: if *addr is old, make it new.
fn cmpswap(addr: *i32, old: i32, new: i32) bool {
    return @cmpxchgStrong(i32, addr, old, new, .seq_cst, .seq_cst) == null;
}

/// DIFF: Sema.waiting is an atomic flag as well (Portability rules).
fn setwaiting(p: *Sema, v: bool) void {
    @atomicStore(bool, &p.waiting, v, .seq_cst);
}

fn waiting(p: *const Sema) bool {
    return @atomicLoad(bool, &p.waiting, .seq_cst);
}

/// Add semaphore p with addr a to list in seg.
fn semqueue(s: *Segment, a: *i32, p: *Sema) void {
    p.* = .{};
    p.addr = a;
    lock(&s.sema.r.lock); // uses s->sema.Rendez.Lock, but no one else is
    p.next = &s.sema;
    p.prev = s.sema.prev;
    p.next.?.prev = p;
    p.prev.?.next = p;
    unlock(&s.sema.r.lock);
}

/// Remove semaphore p from list in seg.
fn semdequeue(s: *Segment, p: *Sema) void {
    lock(&s.sema.r.lock);
    p.next.?.prev = p.prev;
    p.prev.?.next = p.next;
    unlock(&s.sema.r.lock);
}

/// Wake up n waiters with addr a on list in seg.
fn semwakeup(s: *Segment, a: *i32, n_: i32) void {
    var n = n_;

    lock(&s.sema.r.lock);
    var p = s.sema.next.?;
    while (p != &s.sema and n > 0) : (p = p.next.?) {
        if (p.addr == a and waiting(p)) {
            setwaiting(p, false);
            arch.coherence();
            _ = proc.wakeup(&p.r);
            n -= 1;
        }
    }
    unlock(&s.sema.r.lock);
}

/// Add delta to semaphore and wake up waiters as appropriate.
fn semrelease(s: *Segment, addr: *i32, delta: i32) i32 {
    var value: i32 = undefined;

    while (true) {
        value = @atomicLoad(i32, addr, .seq_cst);
        if (cmpswap(addr, value, value +% delta))
            break;
    }
    semwakeup(s, addr, delta);
    return value +% delta;
}

/// Try to acquire semaphore using compare-and-swap
fn canacquire(addr: *i32) bool {
    while (true) {
        const value = @atomicLoad(i32, addr, .seq_cst);
        if (value <= 0)
            break;
        if (cmpswap(addr, value, value - 1))
            return true;
    }
    return false;
}

/// Should we wake up?
fn semawoke(p: ?*anyopaque) bool {
    arch.coherence();
    return !waiting(@ptrCast(@alignCast(p.?)));
}

/// Acquire semaphore (subtract 1).
fn semacquire(s: *Segment, addr: *i32, block: bool) Error!usize {
    var phore: Sema = undefined;

    if (canacquire(addr))
        return 1;
    if (!block)
        return 0;
    semqueue(s, addr, &phore);
    // acquired = !waserror(): the error, if any, is kept until the
    // semaphore is off the list
    var err: ?Error = null;
    while (true) {
        setwaiting(&phore, true);
        arch.coherence();
        if (canacquire(addr))
            break;
        proc.sleep(&phore.r, semawoke, &phore) catch |e| {
            err = e;
            break;
        };
    }
    semdequeue(s, &phore);
    arch.coherence(); // not strictly necessary due to lock in semdequeue
    if (!waiting(&phore))
        semwakeup(s, addr, 1);
    if (err) |e|
        return e;
    return 1;
}

/// Acquire semaphore or time-out
fn tsemacquire(s: *Segment, addr: *i32, ms_: u32) Error!usize {
    var ms = ms_;
    var phore: Sema = undefined;

    if (canacquire(addr))
        return 1;
    if (ms == 0)
        return 0;
    var timedout = false;
    semqueue(s, addr, &phore);
    var err: ?Error = null;
    while (true) {
        setwaiting(&phore, true);
        arch.coherence();
        if (canacquire(addr))
            break;
        var t = arch.MACHP(0).ticks;
        proc.tsleep(&phore.r, semawoke, &phore, ms) catch |e| {
            err = e;
            break;
        };
        t = portclock.tk2ms(arch.MACHP(0).ticks -% t);
        if (t >= ms) {
            timedout = true;
            break;
        }
        ms -= t;
    }
    semdequeue(s, &phore);
    arch.coherence(); // not strictly necessary due to lock in semdequeue
    if (!waiting(&phore))
        semwakeup(s, addr, 1);
    if (err) |e|
        return e;
    return @intFromBool(!timedout);
}

/// The checks the three semaphore calls make of their address: the
/// writable segment it is in and the semaphore itself.
/// DIFF: the C repeats this in each call.
fn semaddr(uaddr: usize, s: *?*Segment) Error!*i32 {
    const up = arch.up().?;

    try evenaddr(uaddr);
    s.* = fault.seg(up, uaddr, false);
    if (s.* == null or (s.*.?.type & SG_RONLY) != 0 or uaddr +% @sizeOf(i32) > s.*.?.top) {
        try validaddr(uaddr, @sizeOf(i32), true);
        return error.Ebadarg;
    }
    // DIFF: see the header
    if (uaddr % @alignOf(i32) != 0)
        return error.Ebadarg;
    return @ptrFromInt(uaddr);
}

pub fn syssemacquire(a: *Sargs) Error!usize {
    var s: ?*Segment = null;

    const uaddr = a.next(usize);
    const block = a.next(i32);
    const addr = try semaddr(uaddr, &s);
    if (@atomicLoad(i32, addr, .seq_cst) < 0)
        return error.Ebadarg;
    return semacquire(s.?, addr, block != 0);
}

pub fn systsemacquire(a: *Sargs) Error!usize {
    var s: ?*Segment = null;

    const uaddr = a.next(usize);
    const ms = a.next(u32);
    const addr = try semaddr(uaddr, &s);
    if (@atomicLoad(i32, addr, .seq_cst) < 0)
        return error.Ebadarg;
    return tsemacquire(s.?, addr, ms);
}

pub fn syssemrelease(a: *Sargs) Error!usize {
    var s: ?*Segment = null;

    const uaddr = a.next(usize);
    const delta = a.next(i32);
    const addr = try semaddr(uaddr, &s);
    // delta == 0 is a no-op, not a release
    if (delta < 0 or @atomicLoad(i32, addr, .seq_cst) < 0)
        return error.Ebadarg;
    return @bitCast(@as(isize, semrelease(s.?, addr, delta)));
}

/// For binary compatibility
pub fn sys_nsec(a: *Sargs) Error!usize {
    // return in register on 64bit machine
    if (@sizeOf(usize) == @sizeOf(i64))
        return @bitCast(@as(isize, @intCast(tod.nsec())));

    const uv = a.next(usize);
    try evenaddr(uv);
    const v = try userslice(uv, @sizeOf(i64), true);
    std.mem.writeInt(i64, v[0..8], tod.nsec(), .little);
    return 0;
}

// DIFF: dosyscall is in syscall.zig, with the system call table.
