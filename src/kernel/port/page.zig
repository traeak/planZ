//! The pool of user pages and the page cache of each Image.
//! from 9/port/page.c
//!
//! DIFF:
//!   - No swap.  Pages are never written out, so there is no Swapalloc
//!     and nothing here waits for a pageout.  What remains of the
//!     paging numbers (highwater, headroom) is kept in this file since
//!     freepages, newpage and needpages still use them, and "%lldM swap"
//!     is gone from the line pageinit prints.
//!   - The part of 9/port/devswap.c that still means something without
//!     a swap file is here, after page.c's own functions: kickpager,
//!     killbig, reclaim and the pager process, which reclaims cached
//!     image pages and, when that frees nothing, lets broken processes
//!     go and then kills the largest process.  pagerinit starts it
//!     (the C starts it from swapinit, devswap's init entry).  Each
//!     place where the C goes on to page out is marked `// DIFF: swap`.
//!     reclaim does not look at fscache (no mount cache, cache.c) or
//!     swapimage.
//!   - No page colouring: newpage takes the head of the free list.
//!   - pageinit does not skip pages whose kernel address would be 0 or
//!     -BY2PG (cankaddr/KADDR in the C): that is a property of pc64's
//!     KZERO window and the arch interface has no cankaddr.  It also
//!     leaves the kernel image (end - KTZERO) out of the total it
//!     prints, since no portable name gives the image's size.
//!   - palloc.pages is a slice over the whole array; palloc.user says
//!     how many of them are in use.
//!   - newpage returns an optional; it is null only when `locked` was
//!     given and had to be released, as in C.
//!   - Page.daddr is only the offset in an image, never a swap address.
//!   - procpagecount is from 9/port/proc.c; it is here because proc.zig
//!     does not know about segments.

const std = @import("std");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const proc = @import("proc.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const xalloc = @import("xalloc.zig");
const segment = @import("segment.zig");
const p9 = @import("print.zig");

const mem = arch.mem;
const BY2PG = mem.BY2PG;

const print = p9.print;
const panic = p9.panic;
const lock = taslock.lock;
const unlock = taslock.unlock;
const incref = portdat.incref;
const decref = portdat.decref;

const Page = portdat.Page;
const Image = portdat.Image;
const Proc = portdat.Proc;
const Segment = portdat.Segment;
const QLock = portdat.QLock;
const Rendez = portdat.Rendez;
const Rendezq = portdat.Rendezq;
const Confmem = arch.Confmem;

pub var palloc: portdat.Palloc = .{};

/// Paging numbers; swapalloc.highwater and swapalloc.headroom in the C.
pub var highwater: usize = 0; // Pager starts running
pub var headroom: usize = 0; // Space pager frees under highwater

/// Where the pager waits; swapalloc.r in the C.
var pagerr: Rendez = .{};

pub fn nkpages(cm: *const Confmem) usize {
    return ((cm.klimit - cm.kbase) + BY2PG - 1) / BY2PG;
}

pub fn pageinit() void {
    if (palloc.pages.len == 0) {
        var np: usize = 0;
        for (&arch.conf.mem) |*cm|
            np += cm.npage - nkpages(cm);
        const a = xalloc.xalloc(np * @sizeOf(Page)) orelse panic("pageinit", .{});
        palloc.pages = @as([*]Page, @ptrFromInt(a))[0..np];
    }

    palloc.freecount = 0;
    palloc.head = null;

    var t: *?*Page = &palloc.head;
    var n: usize = 0;

    for (&arch.conf.mem) |*cm| {
        var j = nkpages(cm);
        while (j < cm.npage) : (j += 1) {
            const p = &palloc.pages[n];
            p.* = .{};
            p.pa = cm.base + j * BY2PG;
            // DIFF: no cankaddr/KADDR check, no colour.
            t.* = p;
            t = &p.next;
            palloc.freecount += 1;
            n += 1;
        }
    }

    palloc.user = n;
    const u: u64 = @as(u64, palloc.user) * BY2PG;

    // Paging numbers
    highwater = (palloc.user * 5) / 100;
    headroom = highwater + (highwater / 4);

    var m: u64 = 0;
    for (&arch.conf.mem) |*cm| {
        if (cm.npage != 0)
            m += @as(u64, cm.npage) * BY2PG;
    }
    // DIFF: the C adds PGROUND(end - KTZERO), the kernel image.

    print("%lldM memory: ", .{(m + 1024 * 1024 - 1) / (1024 * 1024)});
    print("%lldM kernel data, ", .{(m - u + 1024 * 1024 - 1) / (1024 * 1024)});
    print("%lldM user\n", .{u / (1024 * 1024)});
    // DIFF: swap — no "%lldM swap".
}

pub fn freepages(head_: ?*Page, tail_: ?*Page, np_: usize) void {
    const head = head_ orelse return;
    var np = np_;
    var tail: *Page = undefined;
    if (tail_) |x| {
        tail = x;
    } else {
        tail = head;
        np = 1;
        while (true) : (np += 1) {
            tail.ref.ref = 0;
            tail = tail.next orelse break;
        }
    }
    lock(&palloc.lock);
    tail.next = palloc.head;
    palloc.head = head;
    if (palloc.freecount <= highwater) {
        palloc.freecount += np;
        if (palloc.freecount > highwater)
            _ = proc.wakeup(&palloc.pwait[1].r);
        _ = proc.wakeup(&palloc.pwait[0].r);
    } else {
        palloc.freecount += np;
    }
    unlock(&palloc.lock);
}

pub fn pagereclaim(i_: ?*Image) usize {
    const i = i_ orelse return 0;

    lock(&i.lock);
    const mp = i.pgref;
    if (mp == 0) {
        unlock(&i.lock);
        return 0;
    }
    var np: usize = 0;
    var fh: ?*Page = null;
    var ft: ?*Page = null;
    done: {
        for (i.pghash) |*h| {
            var l: *?*Page = h;
            var x: ?*?*Page = null;
            var q = l.*;
            while (q) |p| : (q = p.next) {
                if (p.ref.ref == 0)
                    x = l;
                l = &p.next;
            }
            const xp = x orelse continue;

            const p = xp.*.?;
            xp.* = p.next;
            p.next = null;
            p.image = null;
            p.daddr = ~@as(usize, 0);

            if (ft) |tail|
                tail.next = p
            else
                fh = p;
            ft = p;
            np += 1;

            i.pgref -= 1;
            if (i.pgref == 0) {
                segment.putimage(i);
                break :done;
            }
            _ = decref(&i.ref);
        }
        unlock(&i.lock);
    }
    freepages(fh, ft, np);
    return np;
}

pub fn needpages(_: ?*anyopaque) bool {
    return palloc.freecount < headroom;
}

fn havepages(_: ?*anyopaque) bool {
    return palloc.freecount > highwater or (arch.up().?.noswap and palloc.freecount > 0);
}

/// A page for user address `va`, holding one reference.  If `locked`
/// is given and there is no memory, it is unlocked while waiting and
/// null is returned for the caller to start again; without `locked`
/// the result is never null.
pub fn newpage(va: usize, locked: ?*QLock) ?*Page {
    const up = arch.up().?;

    lock(&palloc.lock);
    while (!havepages(null)) {
        unlock(&palloc.lock);
        if (locked) |l|
            ql.qunlock(l);

        // The C ignores an interrupted eqlock or sleep here
        // (if(!waserror())) and so do we.
        const q = &palloc.pwait[@intFromBool(!up.noswap)];
        if (ql.eqlock(&q.qlock)) |_| {
            proc.sleep(&q.r, havepages, null) catch {};
            ql.qunlock(&q.qlock);
        } else |_| {}

        // If called from fault and we lost the lock from
        // underneath don't waste time allocating and freeing
        // a page. Fault will call newpage again when it has
        // reacquired the locks
        if (locked != null)
            return null;

        lock(&palloc.lock);
    }

    // DIFF: no colours; the C first tries for the page's colour.
    const p = palloc.head.?;
    palloc.head = p.next;
    p.next = null;
    palloc.freecount -= 1;
    if (palloc.freecount <= highwater) {
        unlock(&palloc.lock);
        kickpager();
    } else {
        unlock(&palloc.lock);
    }

    p.ref.ref = 1;
    p.va = va;
    p.modref = 0;
    arch.inittxtflush(p);

    return p;
}

/// deadpage() decrements the page refcount
/// and returns the page when it becomes freeable.
pub fn deadpage(p: *Page) ?*Page {
    if (p.image != null) {
        _ = decref(&p.ref);
        return null;
    }
    if (decref(&p.ref) != 0)
        return null;
    return p;
}

pub fn putpage(p_: *Page) void {
    if (deadpage(p_)) |p|
        freepages(p, p, 1);
}

pub fn copypage(f: *Page, t: *Page) void {
    const ks = arch.kmap(f);
    const kd = arch.kmap(t);
    @memcpy(@as([*]u8, @ptrFromInt(kd))[0..BY2PG], @as([*]const u8, @ptrFromInt(ks))[0..BY2PG]);
    arch.kunmap(ks);
    arch.kunmap(kd);
}

pub fn fillpage(p_: ?*Page, c: u8) ?*Page {
    if (p_) |p| {
        const k = arch.kmap(p);
        @memset(@as([*]u8, @ptrFromInt(k))[0..BY2PG], c);
        arch.kunmap(k);
    }
    return p_;
}

pub fn cachepage(p: *Page, i: *Image) void {
    const daddr = p.daddr;
    const h = i.pghashp(daddr);
    lock(&i.lock);
    defer unlock(&i.lock);
    var x = h.*;
    while (x) |q| : (x = q.next) {
        if (q.daddr == daddr)
            return;
    }
    if (p.image != null)
        return;
    p.image = i;
    p.next = h.*;
    h.* = p;
    _ = incref(&i.ref);
    i.pgref += 1;
}

pub fn uncachepage(p: *Page) void {
    const i = p.image orelse return;
    var l = i.pghashp(p.daddr);
    lock(&i.lock);
    if (p.image == i) {
        var x = l.*;
        while (x) |q| : (x = q.next) {
            if (q == p) {
                l.* = p.next;
                p.next = null;
                p.image = null;
                p.daddr = ~@as(usize, 0);
                i.pgref -= 1;
                segment.putimage(i);
                return;
            }
            l = &q.next;
        }
    }
    unlock(&i.lock);
}

pub fn lookpage(i: *Image, daddr: usize) ?*Page {
    const h = i.pghashp(daddr);
    var l = h;
    lock(&i.lock);
    var x = l.*;
    while (x) |p| : (x = p.next) {
        if (p.daddr == daddr) {
            l.* = p.next;
            p.next = h.*;
            h.* = p;
            _ = incref(&p.ref);
            unlock(&i.lock);
            return p;
        }
        l = &p.next;
    }
    unlock(&i.lock);

    return null;
}

pub fn cachedel(i: *Image, daddr: usize) void {
    if (lookpage(i, daddr)) |p| {
        uncachepage(p);
        putpage(p);
    }
}

pub fn zeroprivatepages() void {
    // in case of a panic, we might not have a process
    // context to do the clearing of the private pages.
    if (arch.up() == null) {
        if (!p9.panicking)
            panic("zeroprivatepages: no process", .{});
        return;
    }

    lock(&palloc.lock);
    for (palloc.pages[0..palloc.user]) |*p| {
        if (p.modref & portdat.PG_PRIV != 0) {
            _ = incref(&p.ref);
            _ = fillpage(p, 0);
            _ = decref(&p.ref);
        }
    }
    unlock(&palloc.lock);
}

// from 9/port/proc.c
pub fn procpagecount(p: *Proc) usize {
    var pages: usize = 0;
    for (p.seg) |x| {
        if (x) |s|
            pages += s.used;
    }
    return pages;
}

//
// What is left of the pager.
// from 9/port/devswap.c
//

/// proctab(i), or null past the end of the table.
fn ptab(i: usize) ?*Proc {
    if (i >= arch.conf.nproc)
        return null;
    return proc.proctab(i);
}

/// Start the pager.  Called once there are processes; swapinit in the C.
pub fn pagerinit() void {
    // DIFF: swap — no swap map, no iolist.
    proc.kproc("pager", pager, null);
}

pub fn kickpager() void {
    _ = proc.wakeup(&pagerr);
}

fn killbig() void {
    var max: usize = 0;
    var kp_: ?*Proc = null;
    var i: usize = 0;
    while (ptab(i)) |p| : (i += 1) {
        if (@backingInt(p.state) <= @backingInt(portdat.State.New) or p.kp or p.parentpid == 0)
            continue;
        if (p.procctl == portdat.Proc_exitbig)
            return; // try later when done exiting
        if ((p.noswap or (p.procmode & 0o222) == 0) and std.mem.eql(u8, proc.eve, p.user))
            continue;
        const l = procpagecount(p);
        if (l > max) {
            kp_ = p;
            max = l;
        }
    }
    const kp = kp_ orelse return;
    if (!ql.canqlock(&kp.debug))
        return;
    if (!ql.canqlock(&kp.seglock)) {
        ql.qunlock(&kp.debug);
        return;
    }
    if (!needpages(null)) {
        ql.qunlock(&kp.seglock);
        ql.qunlock(&kp.debug);
        return;
    }
    const s = kp.seg[portdat.BSEG];
    proc.killproc(kp, portdat.Proc_exitbig);
    ql.qunlock(&kp.debug);
    if (s != null and s.?.ref.ref > 1) {
        i = 0;
        while (ptab(i)) |p| : (i += 1) {
            if (p == kp or p.seg[portdat.BSEG] != s or !ql.canqlock(&p.debug))
                continue;
            proc.killproc(p, portdat.Proc_exitbig);
            ql.qunlock(&p.debug);
        }
    }
    ql.qunlock(&kp.seglock);
}

fn reclaim() bool {
    while (true) {
        // DIFF: no fscache (cache.c) to reclaim from first.
        var np: usize = 0;
        if (np < headroom)
            np += segment.imagereclaim(headroom - np) catch 0;
        // DIFF: swap — the C goes on to reclaim from swapimage.
        if (!needpages(null))
            return true; // have pages, done
        if (np == 0)
            return false; // didnt reclaim, need to swap
        proc.sched();
    }
}

fn pager(_: ?*anyopaque) void {
    const up = arch.up().?;

    // The C's while(waserror()); is the catch on the sleep below.
    while (true) {
        up.psstate = "Reclaim";
        if (reclaim()) {
            up.psstate = "Idle";
            proc.sleep(&pagerr, needpages, null) catch {};
            continue;
        }

        // DIFF: swap — with a swap file the C would now age and page out
        // the segments of each process in turn and write them with
        // executeio.  Without one it does what follows (Killbig:).
        if (proc.freebroken() == 0)
            killbig();
        proc.sched();
    }
}
