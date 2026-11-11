//! The loopback medium: packets written to the interface are queued
//! and read back in by a kernel process.
//! from 9/ip/loopbackmedium.c
//!
//! DIFF:
//!   - The medium is a constant and its routines have the Zig
//!     signatures of ipdat.Medium.
//!   - readloopback: `while(waserror());` is the `catch continue` of
//!     qbread, and the waserror around ipiput4 is gone because ipiput4
//!     cannot fail.

const proc = @import("../port/proc.zig");
const ql = @import("../port/qlock.zig");
const ab = @import("../port/allocb.zig");
const qio = @import("../port/qio.zig");
const ipdat = @import("ipdat.zig");
const ip = @import("ip.zig");
const ipifc = @import("ipifc.zig");

const Error = proc.Error;
const Block = ab.Block;
const Ipifc = ipdat.Ipifc;
const Medium = ipdat.Medium;
const Routehint = ipdat.Routehint;

fn readloopback(x: ?*anyopaque) void {
    const ifc: *Ipifc = @ptrCast(@alignCast(x.?));
    const f = ifc.conv.?.p.?.f.?;

    while (true) {
        const bp = (qio.qbread(ifc.loopback.?, ipdat.IP_MAX) catch continue) orelse break;
        ql.rlock(&ifc.rwlock);
        ip.ipiput4(f, ifc, bp);
        ql.runlock(&ifc.rwlock);
    }
    proc.pexit("hangup", true);
}

fn loopbackbind(ifc: *Ipifc, _: []const []const u8) Error!void {
    if (ifc.loopback != null)
        return;

    ifc.loopback = qio.qopen(1024 * 1024, qio.Qmsg, null, null) orelse
        return error.Enomem;
    proc.kproc("loopbackread", readloopback, ifc);
}

fn loopbackbwrite(ifc: *Ipifc, bp: *Block, _: u8, _: []const u8, _: ?*Routehint) Error!void {
    _ = try qio.qbwrite(ifc.loopback.?, bp);
}

pub const loopbackmedium: Medium = .{
    .hsize = 0,
    .mintu = 0,
    .maxtu = ipdat.IP_MAX,
    .maclen = 0,
    .name = "loopback",
    .bind = loopbackbind,
    .bwrite = loopbackbwrite,
};

pub fn loopbackmediumlink() void {
    ipifc.addipmedium(&loopbackmedium);
}
