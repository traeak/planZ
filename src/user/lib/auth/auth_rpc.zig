//! One exchange with factotum's rpc file.
//! from libauth/auth_rpc.c

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;

const AuthRpcMax = 4096;

/// rpc return values
pub const Rpc = enum(u32) {
    ARok = 0,
    ARdone,
    ARerror,
    ARneedkey,
    ARbadkey,
    ARwritenext,
    ARtoosmall,
    ARtoobig,
    ARrpcfailure,
    ARphase,
    /// auth_proxy's own: the key was asked for and not given
    ARgiveup = 100,
};

pub const AuthRpc = struct {
    afd: i32,
    ibuf: [AuthRpcMax + 1]u8 = undefined,
    obuf: [AuthRpcMax]u8 = undefined,
    /// What came after the verb in the answer: a slice of ibuf.
    arg: []u8 = &.{},
};

const tab = [_]struct { verb: []const u8, val: Rpc }{
    .{ .verb = "ok", .val = .ARok },
    .{ .verb = "done", .val = .ARdone },
    .{ .verb = "error", .val = .ARerror },
    .{ .verb = "needkey", .val = .ARneedkey },
    .{ .verb = "badkey", .val = .ARbadkey },
    .{ .verb = "phase", .val = .ARphase },
    .{ .verb = "toosmall", .val = .ARtoosmall },
    .{ .verb = "error", .val = .ARerror },
};

fn classify(buf: []u8, rpc: *AuthRpc) Rpc {
    const n = buf.len;
    for (tab) |t| {
        const len = t.verb.len;
        if (n >= len and std.mem.eql(u8, buf[0..len], t.verb) and (n == len or buf[len] == ' ')) {
            rpc.arg = if (n == len) buf[n..n] else buf[len + 1 ..];
            return t.val;
        }
    }
    libc.werrstr("malformed rpc response: %s", .{buf});
    return .ARrpcfailure;
}

pub fn auth_allocrpc(afd: i32) ?*AuthRpc {
    const rpc = libc.allocator.create(AuthRpc) catch return null;
    rpc.* = .{ .afd = afd };
    return rpc;
}

pub fn auth_freerpc(rpc: *AuthRpc) void {
    libc.allocator.destroy(rpc);
}

/// Write "verb a" to factotum and read its answer, whose kind is
/// returned and whose text is rpc.arg.  For the kinds that are
/// failures the error string is set.
pub fn auth_rpc(rpc: *AuthRpc, verb: []const u8, a: []const u8) Rpc {
    var f: [4][]u8 = undefined;

    const l = verb.len;
    const na = a.len;
    if (na + l + 1 > AuthRpcMax) {
        libc.werrstr("rpc too big", .{});
        return .ARtoobig;
    }

    @memcpy(rpc.obuf[0..l], verb);
    rpc.obuf[l] = ' ';
    @memcpy(rpc.obuf[l + 1 ..][0..na], a);
    var n = sys.write(rpc.afd, rpc.obuf[0 .. l + 1 + na]);
    if (n != l + 1 + na) {
        if (n >= 0)
            libc.werrstr("auth_rpc short write", .{});
        return .ARrpcfailure;
    }

    n = sys.read(rpc.afd, rpc.ibuf[0..AuthRpcMax]);
    if (n < 0)
        return .ARrpcfailure;
    const len: usize = @intCast(n);
    rpc.ibuf[len] = 0;

    // Set error string for good default behavior.
    const t = classify(rpc.ibuf[0..len], rpc);
    switch (t) {
        .ARok, .ARdone, .ARrpcfailure => {},
        .ARerror => {
            if (rpc.arg.len == 0)
                libc.werrstr("unspecified rpc error", .{})
            else
                libc.werrstr("%s", .{rpc.arg});
        },
        .ARneedkey => libc.werrstr("needkey %s", .{rpc.arg}),
        .ARbadkey => {
            // as in C, the answer is cut at its first line from here on
            if (libc.getfields(rpc.arg, &f, false, "\n") < 2)
                libc.werrstr("badkey %s", .{f[0]})
            else
                libc.werrstr("badkey %s", .{f[1]});
        },
        .ARphase => libc.werrstr("phase error %s", .{rpc.arg}),
        else => libc.werrstr("unknown rpc type %d (bug in auth_rpc.c)", .{@intFromEnum(t)}),
    }
    return t;
}
