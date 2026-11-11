//! Dialing from inside the kernel: open a protocol's clone file,
//! connect, and return the data file.
//! from 9/ip/chandial.c
//!
//! DIFF:
//!   - Errors are Zig error returns; the waserror in call became
//!     errdefer.
//!   - The DS holds slices of its buffer where the C cuts the buffer
//!     up with NULs, and call is handed the network directory and
//!     the protocol where the C hands it the clone file's name and
//!     cuts that back at its last '/'.
//!   - dir is a buffer of Maxpath bytes that receives the conversation
//!     directory NUL terminated; ctlp is an optional pointer.

const std = @import("std");
const fmt = @import("fmt");
const portdat = @import("../port/portdat.zig");
const lib = @import("../port/lib.zig");
const proc = @import("../port/proc.zig");
const chan = @import("../port/chan.zig");
const devmod = @import("../port/dev.zig");
const netif = @import("../port/netif.zig");
const ipdat = @import("ipdat.zig");

const Error = proc.Error;
const Chan = portdat.Chan;
const Maxpath = ipdat.Maxpath;

const Maxstring = 128;

const DS = struct {
    buf: [Maxstring]u8 = undefined, // dist string
    netdir: ?[]const u8 = null,
    proto: []const u8 = "",
    rem: []const u8 = "",
    local: ?[]const u8 = null, // other args
    dir: ?*[Maxpath]u8 = null,
    ctlp: ?*?*Chan = null,
};

/// the dialstring is of the form '[/net/]proto!dest'
pub fn chandial(dest: []const u8, local: ?[]const u8, dir: ?*[Maxpath]u8, ctlp: ?*?*Chan) Error!*Chan {
    var ds: DS = .{};

    ds.local = local;
    ds.dir = dir;
    ds.ctlp = ctlp;

    try _dial_string_parse(dest, &ds);
    if (ds.netdir == null)
        ds.netdir = "/net";

    // no connection server, don't translate
    return call(ds.netdir.?, ds.proto, ds.rem, &ds);
}

/// DIFF: netdir and proto where the C has the name of the clone file;
/// see the head of the file.
fn call(netdir: []const u8, proto: []const u8, dest: []const u8, ds: *DS) Error!*Chan {
    var clonebuf: [Maxpath]u8 = undefined;
    var name: [Maxpath]u8 = undefined;
    var databuf: [Maxpath]u8 = undefined;

    var clone = fmt.snprint(clonebuf[0 .. Maxpath - 1], "%s/%s/clone", .{ netdir, proto });
    const cchan = try chan.namec(clone, portdat.Aopen, lib.ORDWR, 0);

    // get directory name
    errdefer chan.cclose(cchan);
    const n = try devmod.devtab[cchan.type].read(cchan, name[0 .. Maxpath - 1], 0);
    var p: usize = 0;
    while (p < n and name[p] == ' ')
        p += 1;
    const num = netif.strtoul(name[p..n], 0).v;
    const conv = fmt.snprint(name[0 .. Maxpath - 1], "%lud", .{num});
    // the C cuts clone at its last '/'
    clone = clone[0 .. std.mem.findScalarLast(u8, clone, '/') orelse 0];
    if (ds.dir) |dir| {
        const d = fmt.snprint(dir[0 .. Maxpath - 1], "%s/%s", .{ clone, conv });
        dir[d.len] = 0;
    }
    const data = fmt.snprint(databuf[0 .. Maxpath - 1], "%s/%s/data", .{ clone, conv });

    // connect
    const msg = if (ds.local) |local|
        fmt.snprint(name[0 .. Maxpath - 1], "connect %s %s", .{ dest, local })
    else
        fmt.snprint(name[0 .. Maxpath - 1], "connect %s", .{dest});
    _ = try devmod.devtab[cchan.type].write(cchan, msg, 0);

    // open data connection
    const dchan = try chan.namec(data, portdat.Aopen, lib.ORDWR, 0);
    if (ds.ctlp) |ctlp|
        ctlp.* = cchan
    else
        chan.cclose(cchan);
    return dchan;
}

/// parse a dial string
fn _dial_string_parse(str: []const u8, ds: *DS) Error!void {
    const len = @min(str.len, Maxstring - 1);
    @memcpy(ds.buf[0..len], str[0..len]);
    const buf: []const u8 = ds.buf[0..len];

    const p = std.mem.findScalar(u8, buf, '!') orelse {
        ds.netdir = null;
        ds.proto = "net";
        ds.rem = buf;
        return;
    };
    if (buf[0] != '/' and buf[0] != '#') {
        ds.netdir = null;
        ds.proto = buf[0..p];
    } else {
        var p2 = p;
        while (buf[p2] != '/' and p2 != 0)
            p2 -= 1;
        if (p2 == 0)
            return error.Ebadarg;
        ds.netdir = buf[0..p2];
        ds.proto = buf[p2 + 1 .. p];
    }
    ds.rem = buf[p + 1 ..];
}
