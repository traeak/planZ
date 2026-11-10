//! Map of physical address space: what kind of thing is at each address
//! and which parts have been handed out.
//! from 9/port/memmap.c

const std = @import("std");
const taslock = @import("taslock.zig");
const print = @import("print.zig").print;

const Allocated: u32 = 1 << 31;

/// "No address", as -1 in the C interface.
pub const none: u64 = std.math.maxInt(u64);

const Mapent = struct {
    type: u32,
    addr: u64,
    size: u64,
};

var mapalloc: struct {
    lock: taslock.Lock = .{},
    n: usize = 0, // sorted entries
    m: usize = 0, // entries appended since the last sort
    a: [256]Mapent = undefined,
} = .{};

fn dump1(e: *const Mapent) void {
    print("%.16llux-%.16llux %lux\n", .{ e.addr, e.addr + e.size, e.type });
}

fn insert(addr: u64, size: u64, typ: u32) bool {
    if (size == 0 or addr == none or addr +% (size - 1) < addr)
        return false;
    if (mapalloc.n + mapalloc.m >= mapalloc.a.len)
        return false;
    mapalloc.a[mapalloc.n + mapalloc.m] = .{ .type = typ, .addr = addr, .size = size };
    mapalloc.m += 1;
    return true;
}

fn lookup(addr: u64) ?*Mapent {
    if (addr == none) return null;
    for (mapalloc.a[0..mapalloc.n]) |*i| {
        if (i.addr > addr) break;
        if (addr - i.addr < i.size) return i;
    }
    return null;
}

fn lessThan(_: void, a: Mapent, b: Mapent) bool {
    if (a.addr != b.addr) return a.addr < b.addr;
    return a.type < b.type;
}

/// Merge the appended entries into the sorted part.  Where ranges
/// overlap the higher type wins; adjacent ranges of one type are joined.
fn sort() void {
    const a = &mapalloc.a;
    while (mapalloc.m != 0) {
        mapalloc.n += mapalloc.m;
        mapalloc.m = 0;
        std.sort.insertion(Mapent, a[0..mapalloc.n], {}, lessThan);

        const e = mapalloc.n;
        var d: usize = 0;
        var i: usize = 0;
        while (i < e) : (i += 1) {
            if (a[i].size == 0) continue;
            var j = i + 1;
            while (j < e) : (j += 1) {
                if (a[j].size == 0) continue;
                if (a[j].addr - a[i].addr >= a[i].size) break;
                if (a[j].type <= a[i].type) {
                    if (a[j].addr - a[i].addr + a[j].size <= a[i].size) {
                        a[j].size = 0;
                    } else {
                        a[j].size -= a[i].addr + a[i].size - a[j].addr;
                        a[j].addr = a[i].addr + a[i].size;
                    }
                    continue;
                }
                if (a[j].addr - a[i].addr + a[j].size < a[i].size) {
                    if (!insert(a[j].addr + a[j].size, a[i].size - (a[j].addr + a[j].size - a[i].addr), a[i].type))
                        continue;
                }
                a[i].size = a[j].addr - a[i].addr;
                if (a[i].size == 0) break;
            }
            if (a[i].size == 0) continue;
            if (d > 0) {
                const p = &a[d - 1];
                if (a[i].addr - p.addr == p.size and a[i].type == p.type) {
                    p.size += a[i].size;
                    a[i].size = 0;
                    continue;
                }
            }
            a[d] = a[i];
            d += 1;
        }
        if (mapalloc.m > 0)
            std.mem.copyForwards(Mapent, a[d..][0..mapalloc.m], a[e..][0..mapalloc.m]);
        mapalloc.n = d;
    }
}

pub fn memmapdump() void {
    taslock.lock(&mapalloc.lock);
    defer taslock.unlock(&mapalloc.lock);
    sort();
    for (mapalloc.a[0..mapalloc.n]) |*e| dump1(e);
}

/// The base of the first range of `typ` above `addr`, or of the first
/// one at all if `addr` is `none`.
pub fn memmapnext(addr: u64, typ: u32) u64 {
    taslock.lock(&mapalloc.lock);
    defer taslock.unlock(&mapalloc.lock);
    sort();
    for (mapalloc.a[0..mapalloc.n]) |*i| {
        if ((i.type ^ typ) & ~Allocated == 0 and (addr == none or i.addr > addr))
            return i.addr;
    }
    return none;
}

/// How much of the range holding `addr` is left after rounding `addr`
/// up to `alignment` (0 for none).
pub fn memmapsize(addr: u64, alignment: u64) u64 {
    taslock.lock(&mapalloc.lock);
    defer taslock.unlock(&mapalloc.lock);
    sort();
    const i = lookup(addr) orelse return 0;
    var a = addr;
    if (alignment != 0)
        a = (a + alignment - 1) & ~(alignment - 1);
    if (a - i.addr < i.size)
        return i.size - (a - i.addr);
    return 0;
}

pub fn memmapadd(addr: u64, size: u64, typ: u32) void {
    taslock.lock(&mapalloc.lock);
    defer taslock.unlock(&mapalloc.lock);
    if (insert(addr, size, typ & ~Allocated)) {
        if (mapalloc.n + mapalloc.m >= mapalloc.a.len - 1)
            sort();
    }
}

/// Take `size` bytes of `typ` at `addr`, or anywhere if `addr` is
/// `none`.  Returns the address, or `none`.
pub fn memmapalloc(addr_: u64, size: u64, alignment: u64, typ_: u32) u64 {
    const typ = typ_ & ~Allocated;
    var addr = addr_;
    taslock.lock(&mapalloc.lock);
    defer taslock.unlock(&mapalloc.lock);
    sort();
    if (addr != none) {
        const i = lookup(addr) orelse return none;
        if (i.type != typ) return none;
        if (alignment != 0) {
            addr = (addr + alignment - 1) & ~(alignment - 1);
            if (addr - i.addr >= i.size) return none;
        }
        if (addr - i.addr + size > i.size) return none;
        if (size > 0 and !insert(addr, size, typ | Allocated)) return none;
        return addr;
    }
    for (mapalloc.a[0..mapalloc.n]) |*i| {
        if (i.type != typ) continue;
        addr = i.addr;
        if (alignment != 0) {
            addr = (addr + alignment - 1) & ~(alignment - 1);
            if (addr - i.addr >= i.size) continue;
        }
        if (addr - i.addr + size <= i.size) {
            if (size > 0 and !insert(addr, size, typ | Allocated)) return none;
            return addr;
        }
    }
    return none;
}

pub fn memmapfree(addr: u64, size: u64, typ: u32) void {
    taslock.lock(&mapalloc.lock);
    defer taslock.unlock(&mapalloc.lock);
    sort();
    const i = lookup(addr) orelse return;
    if (i.type != (typ | Allocated) or addr - i.addr + size > i.size)
        return;
    if (i.addr < addr)
        _ = insert(i.addr, addr - i.addr, i.type);
    // DIFF: the C computes the size of this tail as
    // addr - i->addr + i->size - size, which is too long.
    if (addr - i.addr + size < i.size)
        _ = insert(addr + size, i.size - (addr - i.addr) - size, i.type);
    i.type &= ~Allocated;
}
