//! Permanent kernel memory: allocations that are rarely or never freed.
//! Everything else in the kernel's share of memory is carved from here.
//! from 9/port/xalloc.c

const std = @import("std");
const arch = @import("../arch.zig");
const taslock = @import("taslock.zig");
const p9 = @import("print.zig");
const print = p9.print;
const panic = p9.panic;

const mem = arch.mem;

const Nhole = 128;
const Magichole = 0x484F4C45; // HOLE

const Hole = struct {
    addr: usize = 0,
    size: usize = 0,
    top: usize = 0,
    link: ?*Hole = null,
};

// DIFF: size is a full word; the C uses ulong, which cannot describe
// the multi-gigabyte arrays a machine with a lot of memory needs.
const Xhdr = extern struct {
    size: usize,
    magix: usize,
};

const hdrsize = @sizeOf(Xhdr);

var xlists: struct {
    lock: taslock.Lock = .{},
    hole: [Nhole]Hole = @splat(.{}),
    flist: ?*Hole = null,
    table: ?*Hole = null,
} = .{};

pub fn xinit() void {
    const conf = arch.conf;

    for (xlists.hole[0 .. Nhole - 1], 1..) |*h, i|
        h.link = &xlists.hole[i];
    xlists.flist = &xlists.hole[0];

    var kpages = conf.npage - conf.upages;
    for (&conf.mem) |*cm| {
        const n = @min(cm.npage, kpages);
        // give to kernel
        if (n > 0) {
            cm.kbase = arch.kaddr(cm.base);
            cm.klimit = cm.kbase + n * mem.BY2PG;
            xhole(cm.base, cm.klimit - cm.kbase);
            kpages -= n;
        }
        // anything left over: cm.npage - nkpages(cm)
        // will be given to user by pageinit()
    }
    xsummary();
}

pub fn xspanalloc(size: usize, alignment: usize, span: usize) usize {
    const a = xalloc(size + alignment + span) orelse
        panic("xspanalloc: %lud %d %lux", .{ size, alignment, span });
    var v = a;
    if (span > 2) {
        v = (a + span) & ~(span - 1);
        var t = v - a;
        if (t > 0) xhole(arch.paddr(a), t);
        t = a + span - v;
        if (t > 0) xhole(arch.paddr(v + size + alignment), t);
    }
    if (alignment > 1)
        v = (v + alignment) & ~(alignment - 1);
    return v;
}

pub fn xallocz(size_: usize, zero: bool) ?usize {
    // add room for magix & size overhead, round up to nearest vlong
    const size = (size_ + mem.BY2V + hdrsize) & ~@as(usize, mem.BY2V - 1);

    taslock.ilock(&xlists.lock);
    var l: *?*Hole = &xlists.table;
    while (l.*) |h| : (l = &h.link) {
        if (h.size >= size) {
            const p: *Xhdr = @ptrFromInt(arch.kaddr(h.addr));
            h.addr += size;
            h.size -= size;
            if (h.size == 0) {
                l.* = h.link;
                h.link = xlists.flist;
                xlists.flist = h;
            }
            taslock.iunlock(&xlists.lock);
            if (zero)
                @memset(@as([*]u8, @ptrCast(p))[0..size], 0);
            p.magix = Magichole;
            p.size = size;
            return @intFromPtr(p) + hdrsize;
        }
    }
    taslock.iunlock(&xlists.lock);
    return null;
}

pub fn xalloc(size: usize) ?usize {
    return xallocz(size, true);
}

pub fn xfree(p: usize) void {
    const x: *Xhdr = @ptrFromInt(p - hdrsize);
    if (x.magix != Magichole) {
        xsummary();
        panic("xfree(%#p) %#ux != %#lux", .{ p, @as(usize, Magichole), x.magix });
    }
    xhole(arch.paddr(@intFromPtr(x)), x.size);
}

/// Give [addr, addr+size) of physical memory to the allocator.
pub fn xhole(addr: usize, size: usize) void {
    if (size == 0) return;

    const top = addr + size;
    taslock.ilock(&xlists.lock);
    defer taslock.iunlock(&xlists.lock);

    var l: *?*Hole = &xlists.table;
    while (l.*) |h| : (l = &h.link) {
        if (h.top == addr) {
            h.size += size;
            h.top = h.addr + h.size;
            if (h.link) |c| {
                if (h.top == c.addr) {
                    h.top += c.size;
                    h.size += c.size;
                    h.link = c.link;
                    c.link = xlists.flist;
                    xlists.flist = c;
                }
            }
            return;
        }
        if (h.addr > addr) break;
    }
    if (l.*) |h| {
        if (top == h.addr) {
            h.addr -= size;
            h.size += size;
            return;
        }
    }

    const h = xlists.flist orelse {
        print("xfree: no free holes, leaked %llud bytes\n", .{size});
        return;
    };
    xlists.flist = h.link;
    h.addr = addr;
    h.top = top;
    h.size = size;
    h.link = l.*;
    l.* = h;
}

pub fn xsummary() void {
    var i: usize = 0;
    var h = xlists.flist;
    while (h) |x| : (h = x.link) i += 1;
    print("%d holes free\n", .{i});

    var s: usize = 0;
    h = xlists.table;
    while (h) |x| : (h = x.link) {
        print("%#8.8p %#8.8p %llud\n", .{ x.addr, x.top, x.size });
        s += x.size;
    }
    print("%llud bytes free\n", .{s});
}
