//! Page faults and checking user addresses.
//! from 9/port/fault.c
//!
//! DIFF:
//!   - fault() never unwinds.  The C calls error() from inside fault()
//!     in three cases, all of them faults taken in kernel mode with an
//!     error label set (up->nerrlab != 0).  There are no error labels
//!     here; "the fault was taken in the kernel" is decided from the
//!     faulting pc and the insyscall flag (see `kernel` in fault()).
//!     In each of those cases fault() puts the C's error string in
//!     up.errstr and returns -1, and the trap handler decides how the
//!     system call fails:
//!       1. demand load failed (faulterror): pio returns the error to
//!          fixfault, which returns it to fault().  Before that pio has
//!          called faulterror exactly where the C does.  For a fault in
//!          the kernel faulterror posts the same note,
//!          "sys: i/o error in demand load accessing PATH: ERR", and
//!          returns; fault() then sets up.errstr to Eioload and returns
//!          -1 (the C does error(Eioload)).  For a fault from user mode
//!          faulterror prints "suicide: ..." and calls pexit(Eioload),
//!          as in C, and does not return.  An interrupted read (Eintr)
//!          is not an error in either: the fault is retried.
//!          The C leaves up->psstate nil and up->insyscall set when it
//!          unwinds here; fault() restores both.
//!       2. the process is being killed (Proc_exitme, Proc_exitbig):
//!          up.errstr is "Killed" or "Killed: Insufficient physical
//!          memory" and fault() returns -1; from user mode procctl()
//!          exits as in C.
//!       3. a kernel process touching a segment it may not (the C's
//!          "for segio" error(Eio)): up.errstr is Eio, return -1.
//!   - No swap: pio only loads from a text or data image, fixfault does
//!     not uncache swap pages, and "pagedout(p)" is "p == null".
//!   - vmemchr returns an index and takes the address as an integer;
//!     validaddr returns the error.
//!   - okaddr takes a 64-bit length, where the C's ulong len is 32 bits
//!     and must be non-negative as a long.
//!   - conf.copymode and PTEDEVICE are used only where the architecture
//!     has them.
//!   - userslice and userstr are new.

const std = @import("std");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const proc = @import("proc.zig");
const ql = @import("qlock.zig");
const page = @import("page.zig");
const segment = @import("segment.zig");
const pgrp = @import("pgrp.zig");
const chan = @import("chan.zig");
const devmod = @import("dev.zig");
const qio = @import("qio.zig");
const devcons = @import("devcons.zig");
const fmt = @import("fmt");
const p9 = @import("print.zig");

const mem = arch.mem;
const BY2PG = mem.BY2PG;

pub const Error = proc.Error;

const print = p9.print;
const panic = p9.panic;
const qlock = ql.qlock;
const qunlock = ql.qunlock;

const Page = portdat.Page;
const Segment = portdat.Segment;
const Image = portdat.Image;
const Proc = portdat.Proc;
const Chan = portdat.Chan;
const ERRMAX = portdat.ERRMAX;
const NDebug = portdat.NDebug;

const SG_TYPE = portdat.SG_TYPE;
const SG_TEXT = portdat.SG_TEXT;
const SG_DATA = portdat.SG_DATA;
const SG_BSS = portdat.SG_BSS;
const SG_STACK = portdat.SG_STACK;
const SG_SHARED = portdat.SG_SHARED;
const SG_PHYSICAL = portdat.SG_PHYSICAL;
const SG_FIXED = portdat.SG_FIXED;
const SG_STICKY = portdat.SG_STICKY;
const SG_RONLY = portdat.SG_RONLY;
const SG_FAULT = portdat.SG_FAULT;
const SG_CACHED = portdat.SG_CACHED;
const SG_DEVICE = portdat.SG_DEVICE;
const SG_NOEXEC = portdat.SG_NOEXEC;

const PG_MOD = portdat.PG_MOD;
const PG_REF = portdat.PG_REF;
const PG_PRIV = portdat.PG_PRIV;

/// PPN in the C: the page's address without the flag bits.
fn PPN(pa: usize) u64 {
    return if (@hasDecl(mem, "PPN")) mem.PPN(pa) else pa & ~@as(u64, BY2PG - 1);
}

/// conf.copymode: 0 is copy on write, 1 is copy on reference.
fn copymode() u32 {
    return if (@hasField(arch.Conf, "copymode")) arch.conf.copymode else 0;
}

/// Report a failed demand load: `s` is the error to raise, `e` what
/// the device said.  Returns only for a fault taken in the kernel,
/// where the caller then returns `s`; see the DIFF in the header.
fn faulterror(s: Error, c: ?*Chan, e: Error, kernel: bool) void {
    const up = arch.up().?;
    var buf: [ERRMAX]u8 = undefined;

    const msg = if (c != null)
        fmt.snprint(&buf, "sys: %s accessing %s: %s", .{ proc.errtext(s), chan.chanpath(c), proc.errtext(e) })
    else
        fmt.snprint(&buf, "sys: %s", .{proc.errtext(s)});
    if (kernel) {
        if (!up.kp)
            _ = proc.postnote(up, true, msg, NDebug);
        up.psstate = null;
        return; // error(s) in the C
    }
    _ = devcons.pprint("suicide: %s\n", .{msg});
    proc.pexit(proc.errtext(s), true);
}

pub fn faultnote(typ: []const u8, access: []const u8, addr: usize) void {
    var buf: [ERRMAX]u8 = undefined;

    checkpages();
    const msg = fmt.snprint(&buf, "sys: trap: %s %s addr=%#p", .{ typ, access, addr });
    _ = proc.postnote(arch.up(), true, msg, NDebug);
}

/// The I/O of pio: read the pages around `vaddr` from the image's file
/// and enter them in its cache.  Called with s unlocked.
fn pioread(s: *Segment, image: *Image, c: *Chan, vaddr: usize, daddr: usize, ask: usize) Error!void {
    if (ask <= BY2PG) {
        const new = page.newpage(vaddr, null).?;
        new.daddr = daddr;
        const k = arch.kmap(new);
        const kb = @as([*]u8, @ptrFromInt(k))[0..BY2PG];
        var unmapped = false;
        errdefer {
            if (!unmapped)
                arch.kunmap(k);
            page.putpage(new);
        }
        const n = try devmod.devtab[c.type].read(c, kb[0..ask], @intCast(daddr));
        if (n != ask)
            return error.Eshort;
        if (n < BY2PG)
            @memset(kb[n..], 0);
        arch.kunmap(k);
        unmapped = true;
        arch.settxtflush(new, s.flushme);
        page.cachepage(new, image);
        page.putpage(new);
    } else {
        const b = try devmod.devtab[c.type].bread(c, ask, daddr);
        defer qio.freeblist(b);
        var o: usize = 0;
        while (o < ask) : (o += BY2PG) {
            if (page.lookpage(image, daddr + o)) |old| {
                page.putpage(old);
                continue;
            }
            const new = page.newpage(vaddr + o, null).?;
            new.daddr = daddr + o;
            const k = arch.kmap(new);
            const kb = @as([*]u8, @ptrFromInt(k))[0..BY2PG];
            var n = ask - o;
            if (n > BY2PG)
                n = BY2PG
            else if (n < BY2PG)
                @memset(kb[n..], 0);
            if (qio.readblist(b, kb[0..n], o) != n) {
                arch.kunmap(k);
                page.putpage(new);
                return error.Eshort;
            }
            arch.kunmap(k);
            arch.settxtflush(new, s.flushme);
            page.cachepage(new, image);
            page.putpage(new);
        }
    }
}

/// Called with s locked.  Returns the slot with the page in it and s
/// still locked; null, with s unlocked, if the fault has to be taken
/// again; or an error, with s unlocked, if the page cannot be read.
fn pio(s: *Segment, addr: usize, pg_: *?*Page, kernel: bool) Error!?*?*Page {
    var pg = pg_;

    while (true) {
        // from a text/data image
        // DIFF: swap — a non-nil *pg here is a page on swap in the C.
        var daddr = s.fstart + (addr - s.base);
        const image = s.image.?;
        if (page.lookpage(image, daddr)) |new| {
            pg.* = new;
            s.used += 1;
            return pg;
        }

        const c = image.c.?;
        var ask: usize = c.iounit;
        if (ask == 0) ask = qio.qiomaxatomic;
        ask &= ~@as(usize, BY2PG - 1);
        if (ask == 0) ask = BY2PG;

        daddr = (addr - s.base) & (0 -% ask);
        if (daddr + ask > s.flen)
            ask = s.flen -| daddr;
        const vaddr = s.base + daddr;
        daddr += s.fstart;
        qunlock(&s.qlock);

        pioread(s, image, c, vaddr, daddr, ask) catch |e| {
            if (std.mem.eql(u8, proc.errtext(e), proc.errtext(error.Eintr)))
                return null;
            faulterror(error.Eioload, c, e, kernel);
            return error.Eioload;
        };

        qlock(&s.qlock);
        pg = segment.segmap(s, addr) orelse {
            qunlock(&s.qlock);
            return null;
        };

        //  race, another proc may have gotten here first
        //  (and the pager may have run on that page) while
        //  s was unlocked
        if (pg.* != null)
            return pg;
    }
}

/// Called with s locked; unlocks it.  0 if the page is now mapped, -1
/// if the fault has to be taken again, an error if a demand load
/// failed.
fn fixfault(s: *Segment, addr_: usize, read: bool, kernel: bool) Error!i32 {
    const up = arch.up().?;
    const addr = addr_ & ~@as(usize, BY2PG - 1);
    var pg = segment.segmap(s, addr) orelse {
        qunlock(&s.qlock);
        pgrp.resrcwait("no memory for segmap") catch {};
        return -1;
    };

    var new: *Page = undefined;
    var mmuphys: u64 = undefined;
    const typ = s.type & SG_TYPE;
    switch (typ) {
        SG_TEXT => { // Demand load
            if (pg.* == null)
                pg = (try pio(s, addr, pg, kernel)) orelse return -1;
            new = pg.*.?;
            mmuphys = PPN(new.pa) | mem.PTERONLY | mem.PTECACHED | mem.PTEVALID;
            new.modref = PG_REF;
        },

        SG_BSS, SG_SHARED, SG_STACK, SG_DATA, SG_STICKY => sw: {
            if (typ == SG_BSS or typ == SG_SHARED or typ == SG_STACK) { // fill on demand
                if (pg.* == null) {
                    const n = page.newpage(addr, &s.qlock) orelse return -1;
                    pg.* = page.fillpage(n, if (typ == SG_STACK) 0xfe else 0);
                    s.used += 1;
                }
                // wet floor
            }
            if (typ != SG_STICKY) { // SG_DATA: Demand load/pagein/copy on write
                if (pg.* == null)
                    pg = (try pio(s, addr, pg, kernel)) orelse return -1;

                //  It's only possible to copy on write if
                //  we're the only user of the segment.
                if (read and copymode() == 0 and s.ref.ref == 1) {
                    new = pg.*.?;
                    mmuphys = PPN(new.pa) | mem.PTERONLY | mem.PTECACHED | mem.PTEVALID;
                    new.modref |= PG_REF;
                    break :sw;
                }

                const old = pg.*.?;
                // DIFF: swap — the C uncaches a page of swapimage that
                // nobody else refers to here.
                if (old.ref.ref > 1 or old.image != null) {
                    const n = page.newpage(addr, &s.qlock) orelse return -1;
                    page.copypage(old, n);
                    arch.settxtflush(n, s.flushme);
                    pg.* = n;
                    // s->used count unchanged
                    page.putpage(old);
                }
                // wet floor
            }
            // SG_STICKY: Never paged out
            new = pg.*.?;
            mmuphys = PPN(new.pa) | mem.PTEWRITE | mem.PTECACHED | mem.PTEVALID;
            new.modref |= if (up.privatemem) PG_PRIV | PG_MOD | PG_REF else PG_MOD | PG_REF;
        },

        SG_FIXED => { // Never paged out
            new = pg.*.?;
            mmuphys = PPN(new.pa) | mem.PTEWRITE | mem.PTEUNCACHED | mem.PTEVALID;
            new.modref |= if (up.privatemem) PG_PRIV | PG_MOD | PG_REF else PG_MOD | PG_REF;
        },

        else => panic("fault", .{}),
    }

    // arch.PTENOEXEC() is 0 where the C has no PTENOEXEC.
    if ((s.type & SG_NOEXEC) != 0 or !s.flushme)
        mmuphys |= arch.PTENOEXEC();

    qunlock(&s.qlock);

    arch.putmmu(addr, mmuphys, new);

    return 0;
}

/// Called with s locked; unlocks it.
fn mapphys(s: *Segment, addr_: usize, attr: u32) void {
    var pg: Page = .{};

    const addr = addr_ & ~@as(usize, BY2PG - 1);
    pg.ref.ref = 1;
    pg.va = addr;
    pg.pa = s.pseg.?.pa + (addr - s.base);
    arch.settxtflush(&pg, s.flushme);

    var mmuphys: u64 = PPN(pg.pa) | mem.PTEVALID;
    if ((attr & SG_RONLY) == 0)
        mmuphys |= mem.PTEWRITE
    else
        mmuphys |= mem.PTERONLY;

    if ((attr & SG_NOEXEC) != 0 or !s.flushme)
        mmuphys |= arch.PTENOEXEC();

    if (@hasDecl(mem, "PTEDEVICE") and (attr & SG_DEVICE) != 0)
        mmuphys |= @field(mem, "PTEDEVICE")
    else if ((attr & SG_CACHED) == 0)
        mmuphys |= mem.PTEUNCACHED
    else
        mmuphys |= mem.PTECACHED;

    qunlock(&s.qlock);

    arch.putmmu(addr, mmuphys, &pg);
}

/// Handle a fault at `addr` by the instruction at `pc`.  Returns 0 if
/// the access can be retried, -1 if the address is bad; for a fault
/// taken in the kernel -1 can also mean a failed demand load or a
/// process being killed, with the reason in up.errstr.
pub fn fault(addr: usize, pc: usize, read: bool) i32 {
    const up = arch.up() orelse
        panic("fault: no user process pc=%#p addr=%#p", .{ pc, addr });

    if (up.nlocks != 0) {
        const l = up.lastlock;
        print("fault: nlocks %d, proc %lud %s, addr %#p, lock %#p, lpc %#p\n", .{
            up.nlocks, up.pid, up.text, addr, l, if (l) |x| x.pc else 0,
        });
    }

    const pnd = up.notepending;
    const ins = up.insyscall;
    up.insyscall = 1;
    const sps = up.psstate;
    up.psstate = "Fault";

    // DIFF: stands for up->nerrlab != 0, which in C is true exactly
    // when the fault was taken in kernel mode (the trap handler's own
    // waserror).  User text is below KZERO on every architecture.
    const kernel = ins != 0 or pc >= mem.KZERO;

    arch.m().pfault +%= 1;

    while (true) {
        const lastflush = up.tlbflush;
        _ = arch.spllo();

        const s = seg(up, addr, true) orelse { // leaves s locked if seg != nil
            up.psstate = sps;
            up.insyscall = ins;
            return -1;
        };

        var attr = s.type;
        if ((attr & SG_TYPE) == SG_PHYSICAL)
            attr |= s.pseg.?.attr;

        // The C reads
        //   (attr & SG_FAULT) != 0 || read? exec check: (attr & SG_RONLY) != 0
        // and ?: binds looser than ||, so the test is this one.
        const bad = if ((attr & SG_FAULT) != 0 or read)
            ((attr & SG_NOEXEC) != 0 or !s.flushme) and (addr & ~@as(usize, BY2PG - 1)) == (pc & ~@as(usize, BY2PG - 1))
        else
            (attr & SG_RONLY) != 0;
        if (bad) {
            qunlock(&s.qlock);
            up.psstate = sps;
            up.insyscall = ins;
            if (up.kp and kernel) // for segio
                proc.seterror(error.Eio); // DIFF: error(Eio)
            return -1;
        }

        var done = false;
        if ((attr & SG_TYPE) == SG_PHYSICAL) {
            mapphys(s, addr, attr);
            done = true;
        } else {
            const r = fixfault(s, addr, read, kernel) catch |e| {
                // DIFF: the C unwinds from faulterror with error(s).
                up.psstate = sps;
                up.insyscall = ins;
                proc.seterror(e);
                return -1;
            };
            done = r == 0;
        }
        if (done) {
            if (up.tlbflush == lastflush)
                break;
            // TLB might be stale, go around
        }

        _ = arch.splhi();
        switch (up.procctl) {
            portdat.Proc_exitme, portdat.Proc_exitbig => {
                if (kernel) {
                    up.psstate = sps;
                    up.insyscall = ins;
                    up.notepending = up.notepending or pnd;
                    // DIFF: error("Killed...")
                    proc.kstrcpy(up.errstr, if (up.procctl == portdat.Proc_exitbig)
                        "Killed: Insufficient physical memory"
                    else
                        "Killed");
                    return -1;
                }
                proc.procctl();
            },
            else => {},
        }
    }

    up.psstate = sps;
    up.insyscall = ins;
    up.notepending = up.notepending or pnd;

    return 0;
}

/// Called only in a system call
///
/// Is [addr, addr+len) in the current process's address space, and
/// writable if `write`?
pub fn okaddr(addr_: usize, len_: usize, write: bool) bool {
    const up = arch.up().?;
    var addr = addr_;
    var len = len_;

    if (@as(isize, @bitCast(len)) >= 0 and len <= 0 -% addr) {
        while (true) {
            const s = seg(up, addr, false) orelse break;
            if (write and (s.type & SG_RONLY) != 0)
                break;

            if (addr + len > s.top) {
                len -= s.top - addr;
                addr = s.top;
                continue;
            }
            return true;
        }
    }
    return false;
}

/// error(Ebadarg) unless okaddr.
pub fn validaddr(addr: usize, len: usize, write: bool) Error!void {
    if (!okaddr(addr, len, write)) {
        _ = devcons.pprint("suicide: invalid address %#p/%lud in sys call pc=%#p\n", .{ addr, len, arch.userpc() });
        _ = proc.postnote(arch.up(), true, "sys: bad address in syscall", NDebug);
        return error.Ebadarg;
    }
    try prefault(addr, len, write);
}

/// DIFF (new): bring every page of a checked range in now, where a
/// failure can still be returned to the caller as an error.  The C lets
/// the fault happen later, in the middle of the system call, and
/// unwinds from there with error(); Zig code cannot be unwound from a
/// trap.  With no swap a page that is in stays in, so after this only
/// another process unmapping the range can make an access fail.
fn prefault(addr: usize, len: usize, write: bool) Error!void {
    if (len == 0) return;
    var a = addr & ~@as(usize, BY2PG - 1);
    const last = (addr + len - 1) & ~@as(usize, BY2PG - 1);
    while (true) : (a += BY2PG) {
        if (!arch.probe(a, write)) {
            // fault() left the reason in up.errstr.
            return error.Str;
        }
        if (a == last) break;
    }
}

fn ubytes(addr: usize, n: usize) []const u8 {
    return @as([*]const u8, @ptrFromInt(addr))[0..n];
}

/// &s[0] is known to be a valid address.  The index of the first byte
/// equal to c in the n bytes at user address s, or null; an error if
/// the search runs off the address space.
pub fn vmemchr(s: usize, c: u8, n_: usize) Error!?usize {
    var n = n_;
    var a = s;
    while (true) {
        const m = BY2PG - (a & (BY2PG - 1));
        if (n <= m)
            break;
        // spans pages; handle this page
        if (std.mem.findScalar(u8, ubytes(a, m), c)) |i|
            return a - s + i;
        a += m;
        n -= m;
        if (a < mem.KZERO)
            try validaddr(a, 1, false);
    }

    // fits in one page
    if (std.mem.findScalar(u8, ubytes(a, n), c)) |i|
        return a - s + i;
    return null;
}

/// DIFF (new): a slice over validated user memory.
pub fn userslice(addr: usize, len: usize, write: bool) Error![]u8 {
    try validaddr(addr, len, write);
    return @as([*]u8, @ptrFromInt(addr))[0..len];
}

/// DIFF (new): the NUL-terminated string at a user address, as a slice
/// of user memory without the NUL.  Fails with Etoolong past 2^16
/// bytes, which is what a 9P string can carry.
pub fn userstr(addr: usize) Error![]const u8 {
    try validaddr(addr, 1, false);
    const n = (try vmemchr(addr, 0, 1 << 16)) orelse return error.Etoolong;
    return @as([*]const u8, @ptrFromInt(addr))[0..n];
}

/// DIFF (new): a string passed as (address, length), for planZ's slice
/// system calls, as a slice of user memory.  Fails with Etoolong at
/// 2^16 bytes or more, before touching memory.  A length of 0 gives an
/// empty slice whatever the address, without checking it.
pub fn userstrn(addr: usize, len: usize) Error![]const u8 {
    if (len >= 1 << 16)
        return error.Etoolong;
    if (len == 0)
        return &.{};
    return userslice(addr, len, false);
}

/// The segment of p holding addr, locked if `dolock`.
pub fn seg(p: *Proc, addr: usize, dolock: bool) ?*Segment {
    for (p.seg) |x| {
        const s = x orelse continue;
        if (addr >= s.base and addr < s.top) {
            if (!dolock)
                return s;

            qlock(&s.qlock);
            if (addr >= s.base and addr < s.top)
                return s;
            qunlock(&s.qlock);
        }
    }

    return null;
}

pub fn checkpages() void {
    const up = arch.up() orelse return;

    for (up.seg) |x| {
        const s = x orelse continue;
        qlock(&s.qlock);
        if (s.map.len > 0 and !up.newtlb) {
            var addr = s.base;
            while (addr < s.top) : (addr += BY2PG) {
                if (segment.segpeek(s, addr)) |p|
                    arch.checkmmu(addr, p.pa);
            }
        }
        qunlock(&s.qlock);
    }
}
