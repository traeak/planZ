//! A server's side of authentication: the file that Tauth makes, on
//! which the client and factotum talk until factotum says who the
//! client is.
//! from lib9p/auth.c
//!
//! A server that wants its clients authenticated sets Srv.auth to
//! auth9p, calls authattach at the start of its attach, sends reads
//! and writes of a fid whose qid has QTAUTH to authread and
//! authwrite, and calls authdestroy from destroyfid.

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const fcall = libc.fcall;
const auth = @import("auth");
const p9 = @import("lib9p.zig");
const mem = @import("mem.zig");

const Req = p9.Req;
const Fid = p9.Fid;
const respond = p9.respond;

const Afid = struct {
    rpc: ?*auth.AuthRpc = null,
    uname: []u8 = &.{},
    aname: []u8 = &.{},
    authok: bool = false,
    afd: i32 = -1,
};

var authgen: u64 = 1 << 63;

pub fn auth9p(r: *Req) void {
    const afid = mem.create9p(Afid);
    ok: {
        afid.afd = @intCast(sys.open("/mnt/factotum/rpc", sys.ORDWR | sys.OCEXEC));
        if (afid.afd < 0)
            break :ok;

        afid.rpc = auth.auth_allocrpc(afid.afd) orelse break :ok;

        if (r.ifcall.uname.len == 0)
            break :ok;
        afid.uname = mem.estrdup9p(r.ifcall.uname);
        afid.aname = mem.estrdup9p(r.ifcall.aname);

        const spec = r.srv.keyspec orelse "proto=p9any role=server";

        if (auth.auth_rpc(afid.rpc.?, "start", spec) != .ARok)
            break :ok;

        const fid = r.afid.?;
        authgen += 1;
        fid.qid = .{ .type = fcall.QTAUTH, .path = authgen, .vers = 0 };
        fid.omode = sys.ORDWR;
        r.ofcall.qid = fid.qid;
        fid.aux = afid;
        respond(r, null);
        return;
    }
    if (afid.rpc) |rpc|
        auth.auth_freerpc(rpc);
    libc.allocator.free(afid.uname);
    libc.allocator.free(afid.aname);
    if (afid.afd >= 0)
        _ = sys.close(afid.afd);
    libc.allocator.destroy(afid);
    p9.responderror(r);
}

/// What factotum has for the client, into data: its count, or null
/// when the conversation is done and the client is who it says.
fn _authread(afid: *Afid, data: []u8) libc.Error!?usize {
    const rpc = afid.rpc.?;
    switch (auth.auth_rpc(rpc, "read", "")) {
        .ARdone => {
            const ai = try auth.auth_getinfo(rpc);
            defer auth.auth_freeAI(ai);
            if (!std.mem.eql(u8, afid.uname, ai.cuid)) {
                libc.werrstr("auth uname mismatch", .{});
                return error.Plan9;
            }
            afid.authok = true;
            return null;
        },
        .ARok => {
            if (data.len < rpc.arg.len) {
                libc.werrstr("authread count too small", .{});
                return error.Plan9;
            }
            @memcpy(data[0..rpc.arg.len], rpc.arg);
            return rpc.arg.len;
        },
        else => {
            libc.werrstr("authrpc botch", .{});
            return error.Plan9;
        },
    }
}

fn afidof(fid: *Fid) ?*Afid {
    if (fid.qid.type != fcall.QTAUTH)
        return null;
    return @ptrCast(@alignCast(fid.aux));
}

pub fn authread(r: *Req) void {
    const afid = afidof(r.fid.?) orelse {
        respond(r, "not an auth fid");
        return;
    };
    const n = _authread(afid, r.rbuf[0..r.ifcall.count]) catch {
        p9.responderror(r);
        return;
    };
    r.ofcall.count = @intCast(n orelse 0);
    respond(r, null);
}

pub fn authwrite(r: *Req) void {
    const afid = afidof(r.fid.?) orelse {
        respond(r, "not an auth fid");
        return;
    };
    if (auth.auth_rpc(afid.rpc.?, "write", r.ifcall.data[0..r.ifcall.count]) != .ARok) {
        p9.responderror(r);
        return;
    }
    r.ofcall.count = r.ifcall.count;
    respond(r, null);
}

pub fn authdestroy(fid: *Fid) void {
    if (fid.qid.type & fcall.QTAUTH == 0)
        return;
    const afid: *Afid = @ptrCast(@alignCast(fid.aux orelse return));
    if (afid.rpc) |rpc|
        auth.auth_freerpc(rpc);
    _ = sys.close(afid.afd);
    libc.allocator.free(afid.uname);
    libc.allocator.free(afid.aname);
    libc.allocator.destroy(afid);
    fid.aux = null;
}

/// For the start of a server's attach: false, with the request
/// answered, unless its afid is one on which the user was
/// authenticated for this uname and aname.
pub fn authattach(r: *Req) bool {
    var buf: [fcall.ERRMAX]u8 = undefined;

    const fid = r.afid orelse {
        respond(r, "not authenticated");
        return false;
    };

    const afid: *Afid = @ptrCast(@alignCast(fid.aux orelse {
        respond(r, "not an auth fid");
        return false;
    }));
    if (fid.qid.type & fcall.QTAUTH == 0) {
        respond(r, "not an auth fid");
        return false;
    }

    if (!std.mem.eql(u8, afid.uname, r.ifcall.uname)) {
        respond(r, libc.sprint(&buf, "auth uname mismatch: %s vs %s", .{ afid.uname, r.ifcall.uname }));
        return false;
    }

    if (!std.mem.eql(u8, afid.aname, r.ifcall.aname)) {
        respond(r, libc.sprint(&buf, "auth aname mismatch: %s vs %s", .{ afid.aname, r.ifcall.aname }));
        return false;
    }

    if (!afid.authok) {
        _ = _authread(afid, buf[0..0]) catch {
            p9.responderror(r);
            return false;
        };
    }
    return true;
}
