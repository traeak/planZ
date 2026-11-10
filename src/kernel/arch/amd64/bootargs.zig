//! Boot configuration: the name=value lines of plan9.ini, which the
//! loader passes as the kernel command line.
//! from 9/pc/bootargs.c
//!
//! DIFF: the text is searched in place instead of being split into a
//! table, and there is no CONFADDR; it arrives in the BootInfo.

const std = @import("std");
const bootinfo = @import("bootinfo");
const mmu = @import("mmu.zig");

pub var bootinfop: *const bootinfo.BootInfo = undefined;

var ini: []const u8 = "";

pub fn bootargsinit(bi: *const bootinfo.BootInfo) void {
    bootinfop = bi;
    if (bi.cmdline_len != 0)
        ini = @as([*]const u8, @ptrFromInt(mmu.kaddr(bi.cmdline)))[0..bi.cmdline_len];
}

/// The value of the last line that sets `name`, or null.
pub fn getconf(name: []const u8) ?[]const u8 {
    var val: ?[]const u8 = null;
    var it = std.mem.tokenizeAny(u8, ini, "\r\n");
    while (it.next()) |line| {
        const l = std.mem.trimStart(u8, line, " \t");
        if (l.len == 0 or l[0] == '#') continue;
        const eq = std.mem.findScalar(u8, l, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trimEnd(u8, l[0..eq], " \t"), name))
            val = std.mem.trim(u8, l[eq + 1 ..], " \t");
    }
    return val;
}
