//! some hacks for commonality twixt inferno and plan9
//! from 9/ip/inferno.c
//!
//! DIFF: the strings are slices: commonerror gives the text of
//! up.errstr up to its NUL, and bootpread takes its buffer as a slice
//! and its offset as a usize.

const std = @import("std");
const arch = @import("../arch.zig");

pub fn commonuser() []const u8 {
    return arch.up().?.user;
}

pub fn commonerror() []const u8 {
    return std.mem.sliceTo(arch.up().?.errstr, 0);
}

pub fn bootpread(_: []u8, _: usize) usize {
    return 0;
}
