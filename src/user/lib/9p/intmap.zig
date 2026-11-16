//! Maps from ulongs to void*s.
//! from lib9p/intmap.c

const std = @import("std");
const libc = @import("libc");
const mem = @import("mem.zig");

const NHASH = 128;

const Intlist = struct {
    id: u32 = 0,
    aux: ?*anyopaque = null,
    link: ?*Intlist = null,
};

pub const Incfn = *const fn (?*anyopaque) void;

pub const Intmap = struct {
    rw: libc.RWLock = .{},
    hash: [NHASH]?*Intlist = @splat(null),
    inc: Incfn = nop,
};

fn hashid(id: u32) usize {
    return id % NHASH;
}

fn nop(_: ?*anyopaque) void {}

pub fn allocmap(inc: ?Incfn) *Intmap {
    const m = mem.create9p(Intmap);
    m.inc = inc orelse nop;
    return m;
}

pub fn freemap(map: *Intmap, destroy_: ?Incfn) void {
    const destroy = destroy_ orelse nop;
    for (map.hash) |h| {
        var p = h;
        while (p) |x| {
            p = x.link;
            destroy(x.aux);
            libc.allocator.destroy(x);
        }
    }
    libc.allocator.destroy(map);
}

fn llookup(map: *Intmap, id: u32) *?*Intlist {
    var lf: *?*Intlist = &map.hash[hashid(id)];
    while (lf.*) |f| : (lf = &f.link) {
        if (f.id == id)
            break;
    }
    return lf;
}

/// The RWlock is used as expected except that we allow
/// inc() to be called while holding it.  This is because we're
/// locking changes to the tree structure, not to the references.
/// Inc() is expected to have its own locking.
pub fn lookupkey(map: *Intmap, id: u32) ?*anyopaque {
    libc.rlock(&map.rw);
    defer libc.runlock(&map.rw);
    if (llookup(map, id).*) |f| {
        map.inc(f.aux);
        return f.aux;
    }
    return null;
}

pub fn insertkey(map: *Intmap, id: u32, v: ?*anyopaque) ?*anyopaque {
    libc.wlock(&map.rw);
    defer libc.wunlock(&map.rw);
    if (llookup(map, id).*) |f| {
        // no decrement for ov because we're returning it
        const ov = f.aux;
        f.aux = v;
        return ov;
    }
    const f = mem.create9p(Intlist);
    f.id = id;
    f.aux = v;
    const h = hashid(id);
    f.link = map.hash[h];
    map.hash[h] = f;
    return null;
}

pub fn caninsertkey(map: *Intmap, id: u32, v: ?*anyopaque) bool {
    libc.wlock(&map.rw);
    defer libc.wunlock(&map.rw);
    if (llookup(map, id).* != null)
        return false;
    const f = mem.create9p(Intlist);
    f.id = id;
    f.aux = v;
    const h = hashid(id);
    f.link = map.hash[h];
    map.hash[h] = f;
    return true;
}

pub fn deletekey(map: *Intmap, id: u32) ?*anyopaque {
    libc.wlock(&map.rw);
    defer libc.wunlock(&map.rw);
    const lf = llookup(map, id);
    if (lf.*) |f| {
        const ov = f.aux;
        lf.* = f.link;
        libc.allocator.destroy(f);
        return ov;
    }
    return null;
}
