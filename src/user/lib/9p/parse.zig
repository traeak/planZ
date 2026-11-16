//! Kernel-style command parser
//! from lib9p/parse.c
//!
//! DIFF:
//!   - A Cmdbuf's fields are a slice of slices; the Cmdbuf and its
//!     text are freed with freecmd (the C's are one block for free).
//!   - lookupcmd returns an error, with the C's text in the error
//!     string.

const std = @import("std");
const libc = @import("libc");
const p9 = @import("lib9p.zig");
const mem = @import("mem.zig");
const fcall = libc.fcall;

pub const Cmdbuf = struct {
    buf: []u8 = &.{},
    f: [][]u8 = &.{},
    all: [][]u8 = &.{},
};

pub const Cmdtab = struct {
    index: i32, // used by client to switch on result
    cmd: []const u8, // command name
    narg: usize, // expected #args; 0 ==> variadic
};

/// Generous estimate of number of fields
fn ncmdfield(p: []const u8) usize {
    var nf: usize = 0;
    var white = true; // first text will start field
    for (p) |c| {
        const nwhite = std.mem.indexOfScalar(u8, " \t\r\n", c) != null; // UTF is irrelevant
        if (white and !nwhite) // beginning of field
            nf += 1;
        white = nwhite;
    }
    return nf;
}

/// parse a command written to a device
pub fn parsecmd(p: []const u8) *Cmdbuf {
    const cb = mem.create9p(Cmdbuf);
    cb.all = libc.allocator.alloc([]u8, ncmdfield(p)) catch
        libc.sysfatal("out of memory allocating %d", .{p.len});
    cb.buf = mem.estrdup9p(p);

    // dump new line
    var n = p.len;
    if (n > 0 and cb.buf[n - 1] == '\n')
        n -= 1;

    cb.f = cb.all[0..libc.tokenize(cb.buf[0..n], cb.all)];
    return cb;
}

pub fn freecmd(cb: *Cmdbuf) void {
    libc.allocator.free(cb.all);
    libc.allocator.free(cb.buf);
    libc.allocator.destroy(cb);
}

/// Reconstruct original message, for error diagnostic
pub fn respondcmderror(r: *p9.Req, cb: *Cmdbuf, comptime format: []const u8, args: anytype) void {
    var err: [fcall.ERRMAX]u8 = undefined;
    const e = fcall.ERRMAX - 10;

    var n = libc.sprint(err[0..e], format, args).len;
    n += libc.sprint(err[n..e], ": \"", .{}).len;
    for (cb.f, 0..) |f, i| {
        if (i > 0)
            n += libc.sprint(err[n..e], " ", .{}).len;
        n += libc.sprint(err[n..e], "%q", .{f}).len;
    }
    err[n] = '"';
    p9.respond(r, err[0 .. n + 1]);
}

/// Look up entry in table
pub fn lookupcmd(cb: *Cmdbuf, ctab: []const Cmdtab) libc.Error!*const Cmdtab {
    if (cb.f.len == 0) {
        libc.werrstr("empty control message", .{});
        return error.Plan9;
    }

    for (ctab) |*ct| {
        if (!std.mem.eql(u8, ct.cmd, "*")) { // wildcard always matches
            if (!std.mem.eql(u8, ct.cmd, cb.f[0]))
                continue;
        }
        if (ct.narg != 0 and ct.narg != cb.f.len) {
            libc.werrstr("bad # args to command", .{});
            return error.Plan9;
        }
        return ct;
    }

    libc.werrstr("unknown control message", .{});
    return error.Plan9;
}
