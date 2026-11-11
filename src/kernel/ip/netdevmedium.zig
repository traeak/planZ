//! The netdev medium: binds an IP interface to any device file that
//! carries one IPv4 packet per read and write.
//! from 9/ip/netdevmedium.c
//!
//! DIFF:
//!   - The medium is a constant and its routines have the Zig
//!     signatures of ipdat.Medium: errors are returned, argv is the
//!     whole bind request.
//!   - netdevbind checks for three arguments; the C checks for two and
//!     then uses argv[2].
//!   - Netdevrock.readp holds the C's three states (-1 not started,
//!     nil gone, the process) in one atomic word, since Zig has no
//!     (void*)-1 for a pointer and other processes poll it.
//!   - A device's bread cannot return "no block"; the reader takes an
//!     empty block where the C takes nil (compare netif.netifbread and
//!     devpipe).
//!   - The waserror sites: netdevunbind's `while(waserror());` are
//!     sleeps whose error is ignored; in netdevread the outer one is
//!     the `catch break` of bread and the inner one is gone, because
//!     ipiput4 cannot fail.
//!   - mediumunbindifc returns an error where the C returns a string.

const std = @import("std");
const arch = @import("../arch.zig");
const portdat = @import("../port/portdat.zig");
const lib = @import("../port/lib.zig");
const proc = @import("../port/proc.zig");
const ql = @import("../port/qlock.zig");
const alloc = @import("../port/alloc.zig");
const ab = @import("../port/allocb.zig");
const chan = @import("../port/chan.zig");
const devmod = @import("../port/dev.zig");
const ipdat = @import("ipdat.zig");
const ip = @import("ip.zig");
const ipifc = @import("ipifc.zig");

const Error = proc.Error;
const Block = ab.Block;
const Chan = portdat.Chan;
const Proc = portdat.Proc;
const Fs = ipdat.Fs;
const Ipifc = ipdat.Ipifc;
const Medium = ipdat.Medium;
const Routehint = ipdat.Routehint;

/// DIFF: the C's (void*)-1 in readp.
const Starting = std.math.maxInt(usize);

const Netdevrock = struct {
    f: *Fs, // file system we belong to
    readp: std.atomic.Value(usize) = .init(Starting), // reading process
    mchan: ?*Chan = null, // Data channel

    /// The reading process, if there is one and it is not `me`.
    fn reader(er: *const Netdevrock, me: *Proc) ?*Proc {
        const x = er.readp.load(.acquire);
        if (x == 0 or x == Starting or x == @intFromPtr(me))
            return null;
        return @ptrFromInt(x);
    }
};

fn rock(ifc: *Ipifc) *Netdevrock {
    return @ptrCast(@alignCast(ifc.arg.?));
}

fn dev(c: *const Chan) *const devmod.Dev {
    return devmod.devtab[c.type];
}

pub const netdevmedium: Medium = .{
    .name = "netdev",
    .hsize = 0,
    .mintu = 0,
    .maxtu = 64000,
    .maclen = 0,
    .bind = netdevbind,
    .unbind = netdevunbind,
    .bwrite = netdevbwrite,
    .unbindonclose = false,
};

/// called to bind an IP ifc to a generic network device
fn netdevbind(ifc: *Ipifc, argv: []const []const u8) Error!void {
    // DIFF: the C tests argc < 2 and uses argv[2].
    if (argv.len < 3)
        return error.Ebadarg;

    const mchan = try chan.namec(argv[2], portdat.Aopen, lib.ORDWR, 0);

    const er = alloc.snew(Netdevrock);
    er.* = .{ .f = ifc.conv.?.p.?.f.? };
    er.mchan = mchan;

    ifc.arg = er;

    proc.kproc("netdevread", netdevread, ifc);
}

fn netdevunbind(ifc: *Ipifc) void {
    const er = rock(ifc);
    const up = arch.up().?;

    // wait for reader to start
    // (a note must not end the wait: the C's while(waserror());)
    while (er.readp.load(.acquire) == Starting)
        proc.tsleep(&up.sleep, proc.return0, null, 300) catch {};

    if (er.reader(up)) |p|
        _ = proc.postnote(p, true, "unbind", 0);

    // wait for reader to die
    while (er.reader(up) != null)
        proc.tsleep(&up.sleep, proc.return0, null, 300) catch {};

    if (er.mchan) |c|
        chan.cclose(c);

    alloc.free(er);
}

/// called by ipoput with a single block to write
fn netdevbwrite(ifc: *Ipifc, bp: *Block, _: u8, _: []const u8, _: ?*Routehint) Error!void {
    const er = rock(ifc);
    _ = try dev(er.mchan.?).bwrite(er.mchan.?, bp, 0);
}

/// process to read from the device
fn netdevread(a: ?*anyopaque) void {
    const ifc: *Ipifc = @ptrCast(@alignCast(a.?));
    const er = rock(ifc);
    er.readp.store(@intFromPtr(arch.up()), .release); // hide identity under a rock for unbind
    while (true) {
        const bp = dev(er.mchan.?).bread(er.mchan.?, ifc.maxtu, 0) catch break;
        // DIFF: an empty block is the C's nil; see the head of the file.
        if (ab.BLEN(bp) == 0) {
            ab.freeb(bp);
            break;
        }
        ql.rlock(&ifc.rwlock);
        ip.ipiput4(er.f, ifc, bp);
        ql.runlock(&ifc.rwlock);
    }
    if (ipifc.mediumunbindifc(ifc)) |_| {} else |_| er.readp.store(0, .release); // someone else is doing the unbind
    proc.pexit("hangup", true);
}

pub fn netdevmediumlink() void {
    ipifc.addipmedium(&netdevmedium);
}
