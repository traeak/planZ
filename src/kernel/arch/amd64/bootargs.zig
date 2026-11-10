//! Boot configuration: the name=value lines of plan9.ini, which the
//! loader passes as the kernel command line.
//! from 9/pc/bootargs.c
//!
//! DIFF: the text is searched in place instead of being split into a
//! table, and there is no CONFADDR; it arrives in the BootInfo.
//!
//! DIFF, setconfenv: with no table, it walks the lines and sets each
//! name once, at its first line and with the value of its last, which
//! is the order and content of the C's table.  Names are matched
//! without regard to case, as the C's cistrcmp does (getconf above
//! still compares exactly), and there is no limit of MAXCONF (64)
//! lines.  Blanks around names and values are dropped, as getconf
//! drops them; the C keeps them.  A line with nothing before the = is
//! skipped; in the C it fails.  An error from ksetenv ends the walk:
//! in the C it unwinds to init0's waserror, which has the same effect.
//!
//! Not ported: multibootargs (the loader is planZ's own) and writeconf
//! (it rewrites CONFADDR for a kernel started by /dev/reboot).

const std = @import("std");
const bootinfo = @import("bootinfo");
const mmu = @import("mmu.zig");
const alloc = @import("../../port/alloc.zig");
const devenv = @import("../../port/devenv.zig");

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

const Setting = struct { name: []const u8, val: []const u8 };

/// The settings of plan9.ini, a line at a time.
const Settings = struct {
    it: std.mem.TokenIterator(u8, .any),

    fn init() Settings {
        return .{ .it = std.mem.tokenizeAny(u8, ini, "\r\n") };
    }

    fn next(s: *Settings) ?Setting {
        while (s.it.next()) |line| {
            const l = std.mem.trimStart(u8, line, " \t");
            if (l.len == 0 or l[0] == '#') continue;
            const eq = std.mem.findScalar(u8, l, '=') orelse continue;
            return .{
                .name = std.mem.trimEnd(u8, l[0..eq], " \t"),
                .val = std.mem.trim(u8, l[eq + 1 ..], " \t"),
            };
        }
        return null;
    }
};

/// Make every setting an environment variable: all of them in #ec,
/// and those whose names do not start with * in #e as well.
pub fn setconfenv() void {
    var i: usize = 0;
    var it = Settings.init();
    next: while (it.next()) |first| : (i += 1) {
        // Set a name where it first appears, with its last value.
        // (The C's table keeps the spelling of the last line too.)
        var name = first.name;
        var val = first.val;
        var j: usize = 0;
        var jt = Settings.init();
        while (jt.next()) |s| : (j += 1) {
            if (!std.ascii.eqlIgnoreCase(s.name, first.name))
                continue;
            if (j < i)
                continue :next;
            name = s.name;
            val = s.val;
        }
        if (name.len == 0)
            continue;

        // Change '\t' -> ' ', which the C does to the whole text.
        var tmp: ?[*]u8 = null;
        defer alloc.free(tmp);
        if (std.mem.findScalar(u8, val, '\t') != null) {
            const p = alloc.malloc(val.len) orelse return;
            tmp = p;
            for (p[0..val.len], val) |*d, ch|
                d.* = if (ch == '\t') ' ' else ch;
            val = p[0..val.len];
        }

        if (name[0] != '*')
            devenv.ksetenv(name, val, false) catch return;
        devenv.ksetenv(name, val, true) catch return;
    }
}
