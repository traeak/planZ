//! from lib9p/fid.c

const std = @import("std");
const libc = @import("libc");
const p9 = @import("lib9p.zig");
const mem = @import("mem.zig");

const Fid = p9.Fid;
const Fidpool = p9.Fidpool;

fn incfidref(v: ?*anyopaque) void {
    const f: *Fid = @ptrCast(@alignCast(v orelse return));
    p9.incref(&f.ref);
}

fn destroyfid(v: ?*anyopaque) void {
    // DIFF: the C casts the pool's destroy to take a void*; the map
    // is freed only with no pool to ask, so this is given the Fid
    const f: *Fid = @ptrCast(@alignCast(v orelse return));
    if (f.pool.destroy) |d|
        d(f);
}

pub fn allocfidpool(destroy: ?*const fn (*Fid) void) *Fidpool {
    const f = mem.create9p(Fidpool);
    f.map = p9.allocmap(incfidref);
    f.destroy = destroy;
    return f;
}

pub fn freefidpool(p: *Fidpool) void {
    p9.freemap(p.map, if (p.destroy != null) destroyfid else null);
    libc.allocator.destroy(p);
}

pub fn allocfid(pool: *Fidpool, fid: u32) ?*Fid {
    const f = mem.create9p(Fid);
    f.fid = fid;
    f.omode = -1;
    f.pool = pool;

    incfidref(f);
    incfidref(f);
    if (!p9.caninsertkey(pool.map, fid, f)) {
        closefid(f);
        closefid(f);
        return null;
    }

    return f;
}

pub fn lookupfid(pool: *Fidpool, fid: u32) ?*Fid {
    return @ptrCast(@alignCast(p9.lookupkey(pool.map, fid)));
}

pub fn closefid(f_: ?*Fid) void {
    // DIFF: closefid(nil) is a fault in C; the callers that pass what
    // removefid returned may have nothing
    const f = f_ orelse return;
    if (p9.decref(&f.ref) == 0) {
        if (f.rdir) |r|
            p9.closedirfile(r);
        if (f.pool.destroy) |d|
            d(f);
        if (f.file) |file|
            p9.closefile(file);
        libc.allocator.free(f.uid);
        libc.allocator.destroy(f);
    }
}

pub fn removefid(pool: *Fidpool, fid: u32) ?*Fid {
    return @ptrCast(@alignCast(p9.deletekey(pool.map, fid)));
}
