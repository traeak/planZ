//! The medium of an interface that sends nowhere, and the stand-in an
//! interface has while it is being bound or unbound.
//! from 9/ip/nullmedium.c
//!
//! DIFF:
//!   - The media are constants and their routines have the Zig
//!     signatures of ipdat.Medium; nullbwrite returns its error.

const proc = @import("../port/proc.zig");
const ab = @import("../port/allocb.zig");
const p9 = @import("../port/print.zig");
const ipdat = @import("ipdat.zig");

const ipifc = @import("ipifc.zig");

const Error = proc.Error;
const Block = ab.Block;
const Ipifc = ipdat.Ipifc;
const Medium = ipdat.Medium;
const Routehint = ipdat.Routehint;

fn nullbind(_: *Ipifc, _: []const []const u8) Error!void {}

fn nullunbind(_: *Ipifc) void {}

fn nullbwrite(_: *Ipifc, bp: *Block, _: u8, _: []const u8, _: ?*Routehint) Error!void {
    ab.freeb(bp);
    return proc.errorf("nullbwrite", .{});
}

pub const nullmedium: Medium = .{
    .maxtu = 64 * 1024,
    .name = "null",
    .bind = nullbind,
    .unbind = nullunbind,
    .bwrite = nullbwrite,
};

/// used in ipifc to prevent unbind while bind is in progress
pub const unboundmedium: Medium = .{
    .maxtu = 64 * 1024,
    .name = "unbound",
    .bind = nullbind,
    .unbind = nullunbind,
    .bwrite = nullbwrite,
};

pub fn nullmediumlink() void {
    ipifc.addipmedium(&nullmedium);
}
