//! from libauth/auth_proxy.c

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const fcall = libc.fcall;
const auth = @import("libauth.zig");

const AuthRpc = auth.AuthRpc;
const Rpc = auth.Rpc;
const Error = libc.Error;

pub const AuthInfo = struct {
    cuid: []u8 = &.{}, // caller id
    suid: []u8 = &.{}, // server id
    cap: []u8 = &.{}, // capability (only valid on server side)
    secret: []u8 = &.{}, // secret
};

fn gstring(b: []const u8, p_: ?usize, s: *[]u8) ?usize {
    var p = p_ orelse return null;
    if (p + fcall.BIT16SZ > b.len)
        return null;
    const n = fcall.GBIT16(b, p);
    p += fcall.BIT16SZ;
    if (p + n > b.len)
        return null;
    s.* = libc.allocator.dupe(u8, b[p..][0..n]) catch return null;
    return p + n;
}

pub fn auth_freeAI(ai_: ?*AuthInfo) void {
    const ai = ai_ orelse return;
    libc.allocator.free(ai.cuid);
    libc.allocator.free(ai.suid);
    libc.allocator.free(ai.cap);
    libc.allocator.free(ai.secret);
    libc.allocator.destroy(ai);
}

fn convM2AI(b: []const u8) ?*AuthInfo {
    const ai = libc.allocator.create(AuthInfo) catch return null;
    ai.* = .{};

    var p: ?usize = 0;
    p = gstring(b, p, &ai.cuid);
    p = gstring(b, p, &ai.suid);
    p = gstring(b, p, &ai.cap);
    p = gstring(b, p, &ai.secret);
    if (p == null) {
        auth_freeAI(ai);
        return null;
    }
    return ai;
}

/// Who the finished conversation says the two sides are.
pub fn auth_getinfo(rpc: *AuthRpc) Error!*AuthInfo {
    if (auth.auth_rpc(rpc, "authinfo", "") != .ARok)
        return error.Plan9;
    return convM2AI(rpc.arg) orelse {
        libc.werrstr("bad auth info from factotum", .{});
        return error.Plan9;
    };
}

fn dorpc(rpc: *AuthRpc, verb: []const u8, val: []const u8, getkey: ?auth.AuthGetkey) Rpc {
    while (true) {
        const ret = auth.auth_rpc(rpc, verb, val);
        if (ret != .ARneedkey and ret != .ARbadkey)
            return ret;
        const gk = getkey orelse return .ARgiveup; // don't know how
        if (!gk(std.mem.sliceTo(rpc.arg, 0)))
            return .ARgiveup; // user punted
    }
}

/// this just proxies what the factotum tells it to.
pub fn fauth_proxy(fd: i32, rpc_: ?*AuthRpc, getkey: ?auth.AuthGetkey, params: []const u8) Error!*AuthInfo {
    var oerr: [libc.ERRMAX]u8 = undefined;

    const rpc = rpc_ orelse {
        libc.werrstr("fauth_proxy - no factotum", .{});
        return error.Plan9;
    };

    const unknown = "UNKNOWN AUTH ERROR";
    @memcpy(oerr[0..unknown.len], unknown);
    oerr[unknown.len] = 0;
    _ = sys.errstr(&oerr);

    if (dorpc(rpc, "start", params, getkey) != .ARok) {
        libc.werrstr("fauth_proxy start: %r", .{});
        return error.Plan9;
    }

    const buf = libc.allocator.alloc(u8, auth.AuthRpcMax) catch return error.Plan9;
    defer libc.allocator.free(buf);
    while (true) {
        switch (dorpc(rpc, "read", "", getkey)) {
            .ARdone => {
                const a = auth_getinfo(rpc);
                // no error, restore whatever was there
                _ = sys.errstr(&oerr);
                return a;
            },
            .ARok => {
                if (sys.write(fd, rpc.arg) != rpc.arg.len) {
                    libc.werrstr("auth_proxy write fd: %r", .{});
                    return error.Plan9;
                }
            },
            .ARphase => {
                var n: usize = 0;
                @memset(buf, 0);
                var ret: Rpc = undefined;
                while (true) {
                    ret = dorpc(rpc, "write", buf[0..n], getkey);
                    if (ret != .ARtoosmall)
                        break;
                    const want = libc.atoi(std.mem.sliceTo(rpc.arg, 0));
                    if (want <= n or want > auth.AuthRpcMax)
                        break;
                    const m = sys.read(fd, buf[n..@intCast(want)]);
                    if (m <= 0) {
                        if (m == 0)
                            libc.werrstr("auth_proxy short read", .{})
                        else
                            libc.werrstr("auth_proxy read fd: %r", .{});
                        return error.Plan9;
                    }
                    n += @intCast(m);
                }
                if (ret != .ARok) {
                    libc.werrstr("auth_proxy rpc write: %r", .{});
                    return error.Plan9;
                }
            },
            else => {
                libc.werrstr("auth_proxy rpc: %r", .{});
                return error.Plan9;
            },
        }
    }
}

/// Prove who we are over fd (an authentication file from fauth, or a
/// connection), by carrying what factotum says between it and fd.
/// The format and arguments make the key's description, as
/// "proto=p9any role=client".
pub fn auth_proxy(fd: i32, getkey: ?auth.AuthGetkey, comptime format: []const u8, args: anytype) Error!*AuthInfo {
    var pb: [1024]u8 = undefined;
    // DIFF: the description is at most 1,024 bytes; the C's has no limit
    const p = libc.sprint(&pb, format, args);

    const afd = sys.open("/mnt/factotum/rpc", sys.ORDWR | sys.OCEXEC);
    if (afd < 0) {
        libc.werrstr("opening /mnt/factotum/rpc: %r", .{});
        return error.Plan9;
    }
    defer _ = sys.close(afd);

    const rpc = auth.auth_allocrpc(@intCast(afd)) orelse return error.Plan9;
    defer auth.auth_freerpc(rpc);
    return fauth_proxy(fd, rpc, getkey, p);
}
