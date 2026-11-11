//! The packet medium: an interface whose packets are read and written
//! by a user program through the interface's own data file.
//! from 9/ip/pktmedium.c
//!
//! DIFF:
//!   - The medium is a constant and its routines have the Zig
//!     signatures of ipdat.Medium.

const proc = @import("../port/proc.zig");
const ab = @import("../port/allocb.zig");
const qio = @import("../port/qio.zig");
const p9 = @import("../port/print.zig");
const ipdat = @import("ipdat.zig");

const ipifc = @import("ipifc.zig");

const Error = proc.Error;
const Block = ab.Block;
const BLEN = ab.BLEN;
const Ipifc = ipdat.Ipifc;
const Medium = ipdat.Medium;
const Routehint = ipdat.Routehint;

pub const pktmedium: Medium = .{
    .name = "pkt",
    .hsize = 0,
    .mintu = 0,
    .maxtu = 4 * 1024,
    .maclen = 0,
    .bind = pktbind,
    .unbind = pktunbind,
    .bwrite = pktbwrite,
    .unbindonclose = true,
};

/// called to bind an IP ifc to an packet device
fn pktbind(_: *Ipifc, _: []const []const u8) Error!void {}

fn pktunbind(_: *Ipifc) void {}

/// called by ipoput with a single packet to write
fn pktbwrite(ifc: *Ipifc, bp: *Block, _: u8, _: []const u8, _: ?*Routehint) Error!void {
    const conv = ifc.conv.?;

    // enqueue onto the conversation's rq
    if (conv.snoopers.ref > 0)
        _ = qio.qpass(conv.sq.?, qio.copyblock(bp, BLEN(bp)));
    _ = qio.qpass(conv.rq.?, bp);
}

pub fn pktmediumlink() void {
    ipifc.addipmedium(&pktmedium);
}
