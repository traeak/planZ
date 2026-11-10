//! Segments, the page tables that describe them, and the cache of
//! text images.
//! from 9/port/segment.c
//!
//! DIFF:
//!   - Errors are returned (Error!T) where the C calls error(); every
//!     waserror block became explicit unlocks or a defer, at the same
//!     places.
//!   - No swap: the onswap/putswap/dupswap paths and Segment.swapped
//!     are gone, and "pagedout(p)" is just "p == null".
//!   - A Pte's first and last are indices (see portdat.zig), an empty
//!     one has first = PTEPERTAB and last = 0.
//!   - Segment.map is a slice; its length is the C's mapsize.  The Pte
//!     the C allocates after the Segment is still in the same
//!     allocation (prepte).
//!   - A function's own name cannot be reused for a parameter in Zig,
//!     so the segno parameters are called `sno`.
//!   - newimage treats 0 pages as 1; in C the hash size wraps to 0.
//!   - attachimage uses conf.nimage only if the architecture has it.
//!   - segflush1 rounds `from` down with ~(BY2PG-1).  The C has
//!     `from &= ~(BY2PG)`, which clears one bit and can take `from`
//!     below s->base, where segpeek's assert panics.
//!   - segfree1 writes to user memory with the segment unlocked; the C
//!     ignores a fault there with waserror.  Here a fault that cannot
//!     be fixed is whatever the trap handler makes of fault() == -1;
//!     the sites are marked `// M4:`.
//!   - segio, segmentioproc and their helpers are not ported: only
//!     devsegment and devproc's memory files use them (devsegment is
//!     in "What is dropped" in PLAN.md).  _globalsegattach stays as the
//!     hook segattach consults.
//!   - procflushmmu, procflushseg, procflushpseg and procflushothers
//!     are from 9/port/proc.c; they are at the end of this file because
//!     proc.zig does not know about segments.
//!   - segflush and segfree return Error!i32, always 0, as the C's int.

const std = @import("std");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const proc = @import("proc.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const alloc = @import("alloc.zig");
const chan = @import("chan.zig");
const page = @import("page.zig");
const fault = @import("fault.zig");
const portclock = @import("portclock.zig");
const p9 = @import("print.zig");

const mem = arch.mem;
const BY2PG = mem.BY2PG;
const PTEMAPMEM = mem.PTEMAPMEM;
const PTEPERTAB = mem.PTEPERTAB;
const SEGMAPSIZE = mem.SEGMAPSIZE;
const PGROUND = mem.PGROUND;

pub const Error = proc.Error;

const panic = p9.panic;
const lock = taslock.lock;
const unlock = taslock.unlock;
const qlock = ql.qlock;
const qunlock = ql.qunlock;
const incref = portdat.incref;
const decref = portdat.decref;

const Lock = portdat.Lock;
const QLock = portdat.QLock;
const Page = portdat.Page;
const Pte = portdat.Pte;
const Segment = portdat.Segment;
const Image = portdat.Image;
const Physseg = portdat.Physseg;
const Proc = portdat.Proc;
const Chan = portdat.Chan;

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
const SG_CACHED = portdat.SG_CACHED;
const SG_DEVICE = portdat.SG_DEVICE;
const SG_NOEXEC = portdat.SG_NOEXEC;

const NSEG = portdat.NSEG;
const SSEG = portdat.SSEG;
const TSEG = portdat.TSEG;
const DSEG = portdat.DSEG;
const BSEG = portdat.BSEG;
const ESEG = portdat.ESEG;

pub const SEGMAXSIZE: usize = SEGMAPSIZE * PTEMAPMEM;

/// log(2) of profiling resolution; from portdat.h
pub const LRESPROF = 3;

fn assert(ok: bool) void {
    if (!ok) panic("assert failed at %#p", .{@returnAddress()});
}

/// Attachable segment types
var physseg: [10]Physseg = .{
    .{ .attr = SG_SHARED, .name = "shared", .pa = 0, .size = SEGMAXSIZE },
    .{ .attr = SG_BSS, .name = "memory", .pa = 0, .size = SEGMAXSIZE },
    .{},
    .{},
    .{},
    .{},
    .{},
    .{},
    .{},
    .{},
};

var physseglock: Lock = .{};

const IHASHSIZE = 64;
fn ihash(s: u64) *?*Image {
    return &imagealloc.hash[@intCast(s % IHASHSIZE)];
}
var imagealloc: struct {
    lock: Lock = .{},

    ireclaim: QLock = .{}, // mutex on reclaiming idle images

    pgidle: usize = 0, // pages in idle list (reclaimable)

    nidle: usize = 0,
    idle: ?*Image = null,
    hash: [IHASHSIZE]?*Image = @splat(null),
} = .{};

pub var _globalsegattach: ?*const fn ([]const u8) ?*Segment = null;

/// conf.nimage, where the architecture has one.
fn nimage() usize {
    return if (@hasField(arch.Conf, "nimage")) arch.conf.nimage else 200;
}

comptime {
    // newseg puts a Pte straight after the Segment.
    if (@alignOf(Pte) > @alignOf(Segment) or @sizeOf(Segment) % @alignOf(Pte) != 0)
        @compileError("Segment/Pte alignment");
}

/// The pre-allocated Pte after a (non-physical) Segment; (Pte*)(s+1).
fn prepte(s: *Segment) *Pte {
    return @ptrFromInt(@intFromPtr(s) + @sizeOf(Segment));
}

fn ssegmapp(s: *Segment) [*]?*Pte {
    return &s.ssegmap;
}

pub fn newseg(typ: u32, base: usize, size: usize) Error!*Segment {
    assert((base & (BY2PG - 1)) == 0);

    if (size > (SEGMAPSIZE * PTEPERTAB))
        return error.Enovmem;

    const raw = alloc.malloc(if ((typ & SG_TYPE) != SG_PHYSICAL)
        @sizeOf(Segment) + @sizeOf(Pte)
    else
        @sizeOf(Segment)) orelse return error.Enomem;
    const s: *Segment = @ptrCast(@alignCast(raw));
    s.* = .{};

    s.ref.ref = 1;
    s.type = typ;
    s.size = size;
    s.base = base;
    s.top = base + (size * BY2PG);
    s.used = 0;
    s.sema.prev = &s.sema;
    s.sema.next = &s.sema;

    s.firstproc = @intCast(arch.conf.nproc);
    s.lastproc = -1;
    s.segno = -1;

    switch (typ & SG_TYPE) {
        SG_TEXT => s.flushme = true,
        SG_PHYSICAL => {
            s.map = &.{};
            s.freepte = null;
            return s;
        },
        else => {},
    }

    // pre-allocated Pte
    s.freepte = prepte(s);

    const mapsize = std.mem.alignForward(usize, size, PTEPERTAB) / PTEPERTAB;
    if (mapsize > s.ssegmap.len) {
        s.map = alloc.newslice(?*Pte, mapsize) orelse {
            alloc.free(s);
            return error.Enomem;
        };
    } else {
        s.map = s.ssegmap[0..];
    }

    return s;
}

/// Must be called with p.seglock locked.
pub fn attachseg(p: *Proc, sno: usize, s: *Segment) void {
    const i: i32 = @intCast(p.index);

    qlock(&s.qlock);
    if (i < s.firstproc)
        s.firstproc = i;
    if (i > s.lastproc)
        s.lastproc = i;
    s.segno = @intCast(sno);
    qunlock(&s.qlock);

    p.seg[sno] = s;
}

pub fn segno(p: *Proc, s: *Segment) i32 {
    const i = s.segno;

    if (i < 0 or p.seg[@intCast(i)] == s)
        return i;
    for (p.seg, 0..) |x, j| {
        if (x == s)
            return @intCast(j);
    }
    return -1;
}

/// Must be called with p.seglock locked
pub fn detachseg(p: *Proc, sno: usize) ?*Segment {
    const s = p.seg[sno];
    p.seg[sno] = null;
    return s;
}

pub fn putseg(s_: ?*Segment) void {
    const s = s_ orelse return;

    if (s.image) |i| {
        //  We must hold image lock here during
        //  decref() to prevent someone from taking
        //  a reference to our segment from the cache.
        //  Just letting decref(s) drop to zero *before*
        //  and then checking s->ref again under image
        //  lock is not sufficient, as someone can grab
        //  a reference and then call putseg() again;
        //  freeing segment. By the time we hold image lock,
        //  the segment would be freed from under us.
        lock(&i.lock);
        if (decref(&s.ref) != 0) {
            unlock(&i.lock);
            return;
        }
        if (i.s == s)
            i.s = null;
        putimage(i);
    } else if (decref(&s.ref) != 0)
        return;

    assert(s.sema.prev == &s.sema);
    assert(s.sema.next == &s.sema);

    if (s.map.len > 0) {
        var np: usize = 0;
        var fh: ?*Page = null;
        var ft: ?*Page = null;

        for (s.map) |x| {
            const pte = x orelse continue;
            var j = pte.first;
            while (j <= pte.last) : (j += 1) {
                var entry = pte.pages[j] orelse continue;
                // DIFF: swap — if(onswap(entry)) putswap(entry)
                entry = page.deadpage(entry) orelse continue;
                if (ft) |tail|
                    tail.next = entry
                else
                    fh = entry;
                ft = entry;
                np += 1;
            }
            if (pte != prepte(s))
                alloc.free(pte);
        }

        page.freepages(fh, ft, np);

        if (s.map.ptr != ssegmapp(s))
            alloc.free(s.map);
    }

    if (s.profile) |prof|
        alloc.free(prof);

    alloc.free(s);
}

fn ptealloc(s: *Segment) ?*Pte {
    var new: *Pte = undefined;
    if (s.freepte) |f| {
        new = f;
        s.freepte = null;
    } else {
        new = alloc.new(Pte) orelse return null;
    }
    new.first = PTEPERTAB;
    new.last = 0;

    return new;
}

fn ptecpy(new: *Pte, old: *Pte) *Pte {
    new.first = old.first;
    var j = old.first;
    while (j <= old.last) : (j += 1) {
        const entry = old.pages[j] orelse continue;
        // DIFF: swap — if(onswap(entry)) dupswap(entry)
        _ = incref(&entry.ref);
        new.last = j;
        new.pages[j] = entry;
    }
    return new;
}

/// A segment for a child of up to have in slot `sno`: the same one or
/// a copy.  Null if there is nothing in the slot or it is ESEG.
pub fn dupseg(sno: usize, share: bool) Error!?*Segment {
    const up = arch.up().?;

    const s = up.seg[sno] orelse return null;
    if (sno == ESEG)
        return null;

    qlock(&s.qlock);
    // The C's waserror here unlocks s; each failure below does.
    var n: *Segment = undefined;
    sameseg: {
        switch (s.type & SG_TYPE) {
            SG_STACK => {
                n = newseg(s.type, s.base, s.size) catch |e| {
                    qunlock(&s.qlock);
                    return e;
                };
            },

            SG_BSS => { // Just copy on write
                if (share)
                    break :sameseg;
                n = newseg(s.type, s.base, s.size) catch |e| {
                    qunlock(&s.qlock);
                    return e;
                };
            },

            SG_DATA => { // Copy on write plus demand load info
                if (sno == TSEG) {
                    n = data2txt(s) catch |e| {
                        qunlock(&s.qlock);
                        return e;
                    };
                    qunlock(&s.qlock);
                    return n;
                }
                if (share)
                    break :sameseg;
                n = newseg(s.type, s.base, s.size) catch |e| {
                    qunlock(&s.qlock);
                    return e;
                };
                n.image = s.image;
                n.fstart = s.fstart;
                n.flen = s.flen;
                _ = incref(&s.image.?.ref);
            },

            // SG_TEXT, SG_SHARED, SG_PHYSICAL, SG_FIXED, SG_STICKY:
            // New segment shares pte set
            else => break :sameseg,
        }
        for (s.map, 0..) |x, i| {
            if (x) |old| {
                const pte = ptealloc(n) orelse {
                    qunlock(&s.qlock);
                    putseg(n);
                    return error.Enomem;
                };
                n.map[i] = ptecpy(pte, old);
            }
        }
        n.used = s.used;
        n.flushme = s.flushme;
        if (s.ref.ref > 1)
            procflushseg(s);
        qunlock(&s.qlock);
        return n;
    }
    _ = incref(&s.ref);
    qunlock(&s.qlock);
    return s;
}

/// Must be called with s locked
pub fn segpeek(s: *Segment, addr: usize) ?*Page {
    assert(addr < s.top);
    assert(addr >= s.base);

    const soff = addr - s.base;
    const pte = s.map[soff / PTEMAPMEM] orelse return null;
    return pte.pages[(soff & (PTEMAPMEM - 1)) / BY2PG];
}

/// Must be called with s locked
pub fn segmap(s: *Segment, addr: usize) ?*?*Page {
    assert(addr < s.top);
    assert(addr >= s.base);

    const soff = addr - s.base;
    const pte = s.map[soff / PTEMAPMEM] orelse blk: {
        const new = ptealloc(s) orelse return null;
        s.map[soff / PTEMAPMEM] = new;
        break :blk new;
    };

    const pg = (soff & (PTEMAPMEM - 1)) / BY2PG;
    if (pg < pte.first)
        pte.first = pg;
    if (pg > pte.last)
        pte.last = pg;

    return &pte.pages[pg];
}

///  Insert new Page into Segmnet s.
///  On error, calls putpage(new).
pub fn segpage(s: *Segment, new: *Page) Error!void {
    qlock(&s.qlock);
    const pg = segmap(s, new.va) orelse {
        qunlock(&s.qlock);
        page.putpage(new);
        return error.Enomem;
    };
    arch.settxtflush(new, s.flushme);
    assert(pg.* == null);
    pg.* = new;
    s.used += 1;
    qunlock(&s.qlock);
}

pub fn relocateseg(s: *Segment, base: usize) void {
    assert((base & (BY2PG - 1)) == 0);

    qlock(&s.qlock);
    const offset = base -% s.base;
    for (s.map) |x| {
        const pte = x orelse continue;
        var j = pte.first;
        while (j <= pte.last) : (j += 1) {
            if (pte.pages[j]) |pg|
                pg.va +%= offset;
        }
    }
    s.base +%= offset;
    s.top +%= offset;
    qunlock(&s.qlock);
}

pub fn newimage(pages: usize) ?*Image {
    // make power of two
    var pghsize: u32 = @truncate(@max(pages, 1) - 1);
    pghsize |= pghsize >> 16;
    pghsize |= pghsize >> 8;
    pghsize |= pghsize >> 4;
    pghsize |= pghsize >> 2;
    pghsize |= pghsize >> 1;
    pghsize +%= 1;
    if (pghsize == 0) // DIFF: 2^32 pages would wrap to no hash at all
        pghsize = 1 << 31;

    if (pghsize > 1024)
        pghsize >>= 4;

    comptime {
        if (@alignOf(?*Page) > @alignOf(Image) or @sizeOf(Image) % @alignOf(?*Page) != 0)
            @compileError("Image/pghash alignment");
    }
    const raw = alloc.malloc(@sizeOf(Image) + pghsize * @sizeOf(?*Page)) orelse return null;
    const i: *Image = @ptrCast(@alignCast(raw));
    i.* = .{};

    i.ref.ref = 1;
    const h: [*]?*Page = @ptrFromInt(@intFromPtr(i) + @sizeOf(Image));
    i.pghash = h[0..pghsize];

    return i;
}

/// remove from idle list
fn busyimage(i: *Image) void {
    // not on idle list?
    const link = i.link orelse return;

    link.* = i.next;
    if (i.next) |next|
        next.link = link;
    i.link = null;
    i.next = null;
    imagealloc.pgidle -= @intCast(i.pgref);
    imagealloc.nidle -= 1;
}

/// The image for the file open on c, with a new reference and locked.
/// The caller unlocks it.
pub fn attachimage(c: *Chan, pages: usize) Error!*Image {
    var i: *Image = undefined;

    retry: while (true) {
        lock(&imagealloc.lock);

        // Search the image cache for remains of the text from a previous
        // or currently running incarnation
        var x = ihash(c.qid.path).*;
        const found = while (x) |f| : (x = f.hash) {
            if (chan.eqchantdqid(c, f.type, f.dev, f.qid, false)) {
                _ = incref(&f.ref);
                busyimage(f);
                break f;
            }
        } else null;
        if (found) |f| {
            i = f;
            break :retry;
        }

        const new: ?*Image = if (imagealloc.nidle > nimage()) null else newimage(pages);
        i = new orelse {
            unlock(&imagealloc.lock);
            if (imagealloc.nidle == 0)
                return error.Enomem;
            if ((try imagereclaim(0)) == 0)
                _ = proc.freebroken(); // can use the memory
            continue :retry;
        };
        i.type = c.type;
        i.dev = c.dev;
        i.qid = c.qid;
        const l = ihash(c.qid.path);
        i.hash = l.*;
        l.* = i;
        break :retry;
    }
    // found:
    i.nattach +%= 1;
    unlock(&imagealloc.lock);
    lock(&i.lock);
    if (i.c == null) {
        i.c = c;
        _ = incref(&c.ref);
    }
    return i;
}

/// insert into idle list
fn idleimage(i: *Image) void {
    // already on idle list?
    if (i.link != null)
        return;

    var l: *?*Image = &imagealloc.idle;
    var j = imagealloc.idle;
    // sort by least frequenty and most pages used first
    while (j) |x| : ({
        l = &x.next;
        j = x.next;
    }) {
        const c: i32 = @bitCast(x.nattach -% i.nattach);
        if (c < 0)
            continue;
        if (c > 0)
            break;
        if (x.pgref < i.pgref)
            break;
    }
    i.next = j;
    if (j) |x|
        x.link = &i.next;
    i.link = l;
    l.* = i;
    imagealloc.pgidle += @intCast(i.pgref);
    imagealloc.nidle += 1;
}

/// putimage(): called with image locked and unlocks
pub fn putimage(i: *Image) void {
    var r = decref(&i.ref);
    if (i.notext) {
        unlock(&i.lock);
        return;
    }
    var c: ?*Chan = null;
    if (r == 0) {
        assert(i.pgref == 0);
        assert(i.s == null);
        lock(&imagealloc.lock);
        r = i.ref.ref;
        if (r == 0) {
            c = i.c;
            i.c = null;
            busyimage(i);

            var l = ihash(i.qid.path);
            var f = l.*;
            while (f) |x| : (f = x.hash) {
                if (x == i) {
                    l.* = i.hash;
                    break;
                }
                l = &x.hash;
            }
        }
        unlock(&imagealloc.lock);
    } else if (r == i.pgref) {
        assert(i.pgref > 0);
        assert(i.s == null);
        if (i.link == null) {
            c = i.c;
            i.c = null;

            lock(&imagealloc.lock);
            idleimage(i);
            unlock(&imagealloc.lock);
        }
    }
    unlock(&i.lock);

    if (r == 0)
        alloc.free(i);

    if (c) |x|
        chan.ccloseq(x); // does not block
}

pub fn imagecached() usize {
    return imagealloc.pgidle;
}

pub fn imagereclaim(pages: usize) Error!usize {
    try ql.eqlock(&imagealloc.ireclaim);

    lock(&imagealloc.lock);
    var np: usize = 0;
    while (np < pages or imagealloc.nidle > nimage()) {
        const i = imagealloc.idle orelse break;
        _ = incref(&i.ref);
        busyimage(i);
        unlock(&imagealloc.lock);

        np += page.pagereclaim(i);

        lock(&i.lock);
        putimage(i);

        lock(&imagealloc.lock);
    }
    unlock(&imagealloc.lock);

    qunlock(&imagealloc.ireclaim);

    return np;
}

///  Must be called with s locked.
///
///  This relies on s->ref > 1 indicating that
///  the segment is shared with other processes
///  different from the calling one.
///
///  The calling process (up) is responsible for
///  flushing its own TBL by calling flushmmu()
///  afterwards when returning a non-zero value
fn segfreemap(s: *Segment, from_: usize, to_: usize) bool {
    const to = to_ & ~@as(usize, BY2PG - 1);
    var from = PGROUND(from_);
    if (from >= to)
        return false;

    var fh: ?*Page = null;
    var ft: ?*Page = null;
    var np: usize = 0;
    var flush = false;

    const soff = from - s.base;
    var poff: usize = (soff & (PTEMAPMEM - 1)) / BY2PG;
    var i: usize = soff / PTEMAPMEM;
    done: while (i < s.map.len) : ({
        i += 1;
        poff = 0;
    }) {
        const pte = s.map[i] orelse {
            from = (from | (PTEMAPMEM - 1)) + 1;
            if (from >= to)
                break :done;
            continue;
        };

        var pg = poff;
        while (pg < PTEPERTAB) : (pg += 1) {
            if (pg == pte.first)
                pte.first += 1;
            if (pte.pages[pg]) |e| {
                pte.pages[pg] = null;
                // DIFF: swap — if(onswap(entry)) putswap(entry), s->swapped--
                if (page.deadpage(e)) |entry| {
                    if (ft) |tail|
                        tail.next = entry
                    else
                        fh = entry;
                    ft = entry;
                    np += 1;
                }
                flush = true;
                s.used -= 1;
            }
            from += BY2PG;
            if (from >= to)
                break :done;
        }

        if (poff == 0) {
            s.map[i] = null;
            if (pte == prepte(s))
                s.freepte = pte
            else
                alloc.free(pte);
        }
    }

    // skip TLB flush when no pages have been changed
    if (!flush)
        return false;

    // we have to make sure other processors flush the
    // entries from their TLBs before any pages are freed.
    if (s.ref.ref > 1)
        procflushseg(s);

    page.freepages(fh, ft, np);

    // tell caller it should flush its TLB
    return true;
}

pub fn ibrk(sno: usize, newtop_: usize) Error!usize {
    const up = arch.up().?;
    var newtop = newtop_;

    const s = up.seg[sno] orelse return error.Ebadarg;

    if (newtop == 0)
        return s.base;

    qlock(&s.qlock);

    // We may start with the bss overlapping the data
    if (newtop < s.base) {
        if (sno != BSEG or up.seg[DSEG] == null or newtop < up.seg[DSEG].?.base) {
            qunlock(&s.qlock);
            return error.Enovmem;
        }
        newtop = s.base;
    }

    newtop = PGROUND(newtop);
    const newsize = (newtop - s.base) / BY2PG;
    done: {
        if (newtop < s.top) {
            // do not shrink a segment shared with other procs, as the
            // to-be-freed address space may have been passed to the kernel
            // already by another proc and is past the validaddr stage.
            if (s.ref.ref > 1) {
                qunlock(&s.qlock);
                return error.Einuse;
            }
            if (!segfreemap(s, newtop, s.top))
                break :done; // skip flushmmu()
            s.top = newtop;
            s.size = newsize;
            qunlock(&s.qlock);
            arch.flushmmu();
            return 0;
        }

        if (isoverlap(s.top, newtop - s.top) != null) {
            qunlock(&s.qlock);
            return error.Esoverlap;
        }

        if (newsize > (SEGMAPSIZE * PTEPERTAB)) {
            qunlock(&s.qlock);
            return error.Enovmem;
        }
        const mapsize = std.mem.alignForward(usize, newsize, PTEPERTAB) / PTEPERTAB;
        if (mapsize > s.map.len) {
            const map = alloc.newslice(?*Pte, mapsize) orelse {
                qunlock(&s.qlock);
                return error.Enomem;
            };
            @memcpy(map[0..s.map.len], s.map);
            if (s.map.ptr != ssegmapp(s))
                alloc.free(s.map);
            s.map = map;
        }
    }
    s.top = newtop;
    s.size = newsize;
    qunlock(&s.qlock);
    return 0;
}

pub fn isoverlap(base: usize, len: usize) ?*Segment {
    const up = arch.up().?;

    const top = base +% len;
    for (up.seg) |x| {
        const s = x orelse continue;
        if (top > s.base and base < s.top)
            return s;
    }
    return null;
}

pub fn addphysseg(new: *const Physseg) ?*Physseg {
    // Check not already entered and there is room
    // for a new entry and the terminating null entry.
    lock(&physseglock);
    var n: usize = 0;
    while (physseg[n].name.len != 0) : (n += 1) {
        if (std.mem.eql(u8, physseg[n].name, new.name)) {
            unlock(&physseglock);
            return null;
        }
    }
    if (n >= physseg.len - 2) {
        unlock(&physseglock);
        return null;
    }
    physseg[n] = new.*;
    unlock(&physseglock);

    return &physseg[n];
}

pub fn findphysseg(name: []const u8) ?*Physseg {
    var n: usize = 0;
    while (physseg[n].name.len != 0) : (n += 1) {
        if (std.mem.eql(u8, physseg[n].name, name))
            return &physseg[n];
    }

    return null;
}

fn unusedsegno(i_: i32) i32 {
    const up = arch.up().?;
    var i: usize = if (i_ < 0 or i_ == ESEG or up.seg[@intCast(i_)] != null) 0 else @intCast(i_);
    while (i < NSEG) : (i += 1) {
        if (up.seg[i] == null and i != ESEG)
            return @intCast(i);
    }
    return -1;
}

pub fn segattach(attr_: u32, name: []const u8, va_: usize, len_: usize) Error!usize {
    const up = arch.up().?;
    var attr = attr_;
    var va = va_;
    var len = len_;

    if (va != 0 and va >= mem.USTKTOP)
        return error.Ebadarg;

    qlock(&up.seglock);
    // The C unlocks in a waserror and again at the end.
    defer qunlock(&up.seglock);

    //  first look for a global segment with the
    //  same name
    if (_globalsegattach) |f| {
        if (f(name)) |s| {
            va = s.base;
            len = s.top - va;
            if (isoverlap(va, len) != null)
                return error.Esoverlap;
            const sno = unusedsegno(s.segno);
            if (sno < 0)
                return error.Enovmem;
            attachseg(up, @intCast(sno), s);
            return va;
        }
    }

    // round up va+len
    len +%= va & (BY2PG - 1);
    len = (len +% (BY2PG - 1)) & ~@as(usize, BY2PG - 1);

    if (len == 0)
        return error.Ebadarg;

    // Find a hole in the address space.
    // Starting at the lowest possible stack address - len,
    // check for an overlapping segment, and repeat at the
    // base of that segment - len until either a hole is found
    // or the address space is exhausted.  Ensure that we don't
    // map the zero page.
    if (va == 0) {
        var os = up.seg[SSEG];
        while (os) |o| : (os = isoverlap(va, len)) {
            va = o.base;
            if (len >= va)
                return error.Enovmem;
            va -= len;
        }
    }

    va &= ~@as(usize, BY2PG - 1);
    if (va == 0 or (va +% len) > mem.USTKTOP or (va +% len) < va)
        return error.Ebadarg;

    if (isoverlap(va, len) != null)
        return error.Esoverlap;

    const ps = findphysseg(name) orelse return error.Ebadarg;

    if (len > ps.size)
        return error.Enovmem;

    const sno = unusedsegno(-1);
    if (sno < 0)
        return error.Enovmem;

    // Turn off what is not allowed
    attr &= ~@as(u32, SG_TYPE | SG_CACHED | SG_DEVICE);

    // Copy in defaults
    attr |= ps.attr;

    const s = try newseg(attr, va, len / BY2PG);
    s.pseg = ps;
    attachseg(up, @intCast(sno), s);

    return va;
}

fn segflush1(s: *Segment, from_: usize, to_: usize) bool {
    if ((s.type & SG_NOEXEC) != 0)
        return false;

    if ((s.type & SG_RONLY) != 0 and s.flushme)
        return false;

    s.flushme = true;
    if (s.ref.ref > 1)
        procflushseg(s);

    if (s.map.len == 0)
        return true;

    // DIFF: the C has from &= ~(BY2PG); see the header.
    var from = from_ & ~@as(usize, BY2PG - 1);
    const to = PGROUND(to_);
    while (from < to) {
        if (segpeek(s, from)) |p|
            arch.settxtflush(p, true);
        from += BY2PG;
    }

    return true;
}

fn ubytes(addr: usize, n: usize) []u8 {
    return @as([*]u8, @ptrFromInt(addr))[0..n];
}

fn segfree1(s: *Segment, from: usize, to: usize) bool {
    if ((s.type & SG_RONLY) != 0 or s.map.len == 0)
        return false;

    var fill: u8 = 0;
    switch (s.type & SG_TYPE) {
        SG_FIXED, SG_STICKY => {
            qunlock(&s.qlock);
            // M4: the C ignores a fault here (waserror).
            @memset(ubytes(from, to - from), fill);
            qlock(&s.qlock);
            return false;
        },
        SG_PHYSICAL, SG_TEXT => return false,

        SG_DATA => {
            var ato = to & ~@as(usize, BY2PG - 1);
            var afrom = PGROUND(from);
            const image = s.image.?;

            // reset partially covered pages to original image data.
            if (afrom > to) {
                afrom = to;
                ato = to;
            }
            if (from < afrom and segpeek(s, from) != null) {
                if (page.lookpage(image, s.fstart + (from & ~@as(usize, BY2PG - 1)) - s.base)) |p| {
                    qunlock(&s.qlock);
                    const k = arch.kmap(p);
                    // M4: the C ignores a fault here (waserror).
                    @memcpy(ubytes(from, afrom - from), ubytes(k + (from & (BY2PG - 1)), afrom - from));
                    arch.kunmap(k);
                    page.putpage(p);
                    qlock(&s.qlock);
                }
            }
            if (ato < to and ato >= from and segpeek(s, ato) != null) {
                if (page.lookpage(image, s.fstart + ato - s.base)) |p| {
                    qunlock(&s.qlock);
                    const k = arch.kmap(p);
                    // M4: the C ignores a fault here (waserror).
                    @memcpy(ubytes(ato, to - ato), ubytes(k, to - ato));
                    arch.kunmap(k);
                    page.putpage(p);
                    qlock(&s.qlock);
                }
            }
            return segfreemap(s, afrom, ato);
        },

        // SG_STACK, SG_BSS, SG_SHARED
        else => {
            if ((s.type & SG_TYPE) == SG_STACK)
                fill = 0xfe;
            var ato = to & ~@as(usize, BY2PG - 1);
            var afrom = PGROUND(from);

            // fill partial covered pages with pattern
            if (afrom > to) {
                afrom = to;
                ato = to;
            }
            if (from < afrom and segpeek(s, from) != null) {
                qunlock(&s.qlock);
                // M4: the C ignores a fault here (waserror).
                @memset(ubytes(from, afrom - from), fill);
                qlock(&s.qlock);
            }
            if (ato < to and ato >= from and segpeek(s, ato) != null) {
                qunlock(&s.qlock);
                // M4: the C ignores a fault here (waserror).
                @memset(ubytes(ato, to - ato), fill);
                qlock(&s.qlock);
            }
            return segfreemap(s, afrom, ato);
        },
    }
}

fn withsegrange(va: usize, len: usize, fun: *const fn (*Segment, usize, usize) bool) Error!i32 {
    const up = arch.up().?;

    var from = va;
    const to = from +% len;
    if (to < from or to > mem.USTKTOP)
        return error.Ebadarg;

    var flush = false;
    while (from < to) {
        const s = fault.seg(up, from, true) orelse {
            if (flush)
                arch.flushmmu();
            return error.Ebadarg;
        };
        const top = s.top;
        if (to <= top) {
            if (fun(s, from, to)) flush = true;
            qunlock(&s.qlock);
            break;
        }
        if (fun(s, from, top)) flush = true;
        qunlock(&s.qlock);
        from = top;
    }

    if (flush)
        arch.flushmmu();

    return 0;
}

pub fn segflush(va: usize, len: usize) Error!i32 {
    return withsegrange(va, len, segflush1);
}

pub fn segfree(va: usize, len: usize) Error!i32 {
    return withsegrange(va, len, segfree1);
}

pub fn segclock(pc_: usize) void {
    const up = arch.up().?;
    var pc = pc_;

    const s = up.seg[TSEG] orelse return;
    const profile = s.profile orelse return;
    profile[0] +%= portclock.tk2ms(1);
    if (pc >= s.base and pc < s.top) {
        pc -= s.base;
        profile[pc >> LRESPROF] +%= portclock.tk2ms(1);
    }
}

pub fn txt2data(s: *Segment) Error!*Segment {
    const ps = try newseg(SG_DATA, s.base, s.size);
    ps.image = s.image;
    ps.fstart = s.fstart;
    ps.flen = s.flen;
    ps.flushme = true;
    _ = incref(&s.image.?.ref);
    return ps;
}

pub fn data2txt(s: *Segment) Error!*Segment {
    const i = s.image.?;
    lock(&i.lock);
    if (i.s) |ps| {
        if (ps.flen == s.flen) {
            assert(ps.image == i);
            _ = incref(&ps.ref);
            unlock(&i.lock);
            return ps;
        }
    }
    const ps = newseg(SG_TEXT | SG_RONLY, s.base, s.size) catch |e| {
        unlock(&i.lock);
        return e;
    };
    ps.image = i;
    ps.fstart = s.fstart;
    ps.flen = s.flen;
    if (i.s == null)
        i.s = ps;
    _ = incref(&i.ref);
    unlock(&i.lock);
    return ps;
}

// DIFF: segio, segmentioproc, docmd, cmddone and cmdready are not
// ported; see the header.

//
// from 9/port/proc.c
//

///  wait till all matching processes have comitted to flush their mmu
fn procflushmmu(firstproc: i32, lastproc: i32, match: *const fn (*Proc, ?*anyopaque) bool, a: ?*anyopaque) void {
    var ticks: [mem.MAXMACH]u32 = undefined;
    var await: [mem.MAXMACH]?*Proc = undefined;
    const nmach: usize = arch.conf.nmach;

    //  tell all matching processes to flush their mmu's
    @memset(await[0..nmach], null);
    var nwait: usize = 0;
    var i: i32 = firstproc;
    while (i <= lastproc and i >= 0 and i < arch.conf.nproc) : (i += 1) {
        const p = proc.proctab(@intCast(i)) orelse break;
        if (@backingInt(p.state) > @backingInt(portdat.State.New) and match(p, a)) {
            p.newtlb = true;
            for (0..nmach) |nm| {
                if (arch.MACHP(nm).proc == p) {
                    arch.coherence();
                    ticks[nm] = arch.MACHP(nm).ticks;
                    if (await[nm] == null)
                        nwait += 1;
                    await[nm] = p;
                }
            }
        }
    }

    //  wait for all other processors to switch task
    //  or take a clock interrupt and flush their mmu's
    //  (see hzclock()).
    //
    //  the ticks check ensures that we make progress
    //  when newtlb flag is set again by someone else.
    while (true) {
        if (nwait == 0 or (nwait == 1 and await[@intCast(arch.m().machno)] != null))
            break;

        proc.sched();

        for (0..nmach) |nm| {
            const p = await[nm] orelse continue;
            if (arch.MACHP(nm).proc != p or !p.newtlb or arch.MACHP(nm).ticks != ticks[nm]) {
                await[nm] = null;
                nwait -= 1;
            }
        }
    }
}

fn matchseg(p: *Proc, a: ?*anyopaque) bool {
    return segno(p, @ptrCast(@alignCast(a.?))) >= 0;
}
// from 9/port/proc.c
pub fn procflushseg(s: *Segment) void {
    procflushmmu(s.firstproc, s.lastproc, matchseg, s);
}

fn matchpseg(p: *Proc, a: ?*anyopaque) bool {
    const ps: *Physseg = @ptrCast(@alignCast(a.?));
    for (p.seg) |x| {
        if (x) |s| {
            if (s.pseg == ps)
                return true;
        }
    }
    return false;
}
// from 9/port/proc.c
pub fn procflushpseg(ps: *Physseg) void {
    procflushmmu(0, @intCast(arch.conf.nproc), matchpseg, ps);
}

fn matchother(p: *Proc, a: ?*anyopaque) bool {
    return @intFromPtr(p) != @intFromPtr(a);
}
// from 9/port/proc.c
pub fn procflushothers() void {
    procflushmmu(0, @intCast(arch.conf.nproc), matchother, arch.up());
}
