//! from lib9p/req.c

const std = @import("std");
const libc = @import("libc");
const p9 = @import("lib9p.zig");
const mem = @import("mem.zig");
const fcall = libc.fcall;

const Req = p9.Req;
const Reqpool = p9.Reqpool;

fn increqref(v: ?*anyopaque) void {
    const r: *Req = @ptrCast(@alignCast(v orelse return));
    p9.incref(&r.ref);
}

fn destroyreq(v: ?*anyopaque) void {
    const r: *Req = @ptrCast(@alignCast(v orelse return));
    if (r.pool) |p| {
        if (p.destroy) |d|
            d(r);
    }
}

pub fn allocreqpool(destroy: ?*const fn (*Req) void) *Reqpool {
    const f = mem.create9p(Reqpool);
    f.map = p9.allocmap(increqref);
    f.destroy = destroy;
    return f;
}

pub fn freereqpool(p: *Reqpool) void {
    p9.freemap(p.map, if (p.destroy != null) destroyreq else null);
    libc.allocator.destroy(p);
}

pub fn allocreq(pool: *Reqpool, tag: u32) ?*Req {
    const r = mem.create9p(Req);
    r.tag = tag;
    r.pool = pool;

    increqref(r);
    increqref(r);
    if (!p9.caninsertkey(pool.map, tag, r)) {
        closereq(r);
        closereq(r);
        return null;
    }

    return r;
}

pub fn lookupreq(pool: *Reqpool, tag: u32) ?*Req {
    return @ptrCast(@alignCast(p9.lookupkey(pool.map, tag)));
}

fn freestr(s: []const u8) void {
    if (s.len != 0)
        libc.allocator.free(s);
}

pub fn closereq(r_: ?*Req) void {
    const r = r_ orelse return;

    if (p9.decref(&r.ref) == 0) {
        if (r.fid) |f|
            p9.closefid(f);
        if (r.newfid) |f|
            p9.closefid(f);
        if (r.afid) |f|
            p9.closefid(f);
        if (r.oldreq) |o|
            closereq(o);
        for (r.flush) |f|
            p9.respond(f, null);
        libc.allocator.free(r.flush);
        switch (r.ifcall.type) {
            fcall.Tstat => {
                libc.allocator.free(r.statbuf);
                freestr(r.d.name);
                freestr(r.d.uid);
                freestr(r.d.gid);
                freestr(r.d.muid);
            },
            else => {},
        }
        if (r.pool.?.destroy) |d|
            d(r);
        libc.allocator.free(r.buf);
        libc.allocator.free(r.rbuf);
        libc.allocator.destroy(r);
    }
}

pub fn removereq(pool: *Reqpool, tag: u32) ?*Req {
    return @ptrCast(@alignCast(p9.deletekey(pool.map, tag)));
}
