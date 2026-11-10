//! Portable kernel data structures.
//! from 9/port/portdat.h
//!
//! Only what the machine core needs so far; the rest arrives with the
//! code that uses it.

const arch = @import("../arch.zig");

pub const Lock = struct {
    key: u32 = 0,
    sr: usize = 0,
    pc: usize = 0,
    p: ?*Proc = null,
    m: ?*arch.Mach = null,
    isilock: bool = false,
    lockcycles: i64 = 0,
};

/// Placeholder until proc.zig (M2): the fields the fault dump prints.
pub const Proc = struct {
    text: []const u8 = "",
    pid: u32 = 0,
    errstr: []const u8 = "",
};
