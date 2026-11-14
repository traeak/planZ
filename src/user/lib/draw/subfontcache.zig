//! The one-entry cache of the last subfont read.
//! From /sys/src/libdraw/subfontcache.c (9front 11952).
//!
//! Easy versions of the cache routines; may be substituted by fancier
//! ones for other purposes.
//!
//! DIFF: lookupsubfont's display is optional, as the C's may be nil.

const std = @import("std");
const libc = @import("libc");
const D = @import("libdraw.zig");
const Subfont = D.Subfont;

var lastname: ?[]u8 = null;
var lastsubfont: ?*Subfont = null;

pub fn lookupsubfont(d: ?*D.Display, name: []const u8) ?*Subfont {
    if (d != null and std.mem.eql(u8, name, "*default*"))
        return d.?.defaultsubfont;
    if (lastname) |ln| {
        if (std.mem.eql(u8, name, ln)) {
            const s = lastsubfont.?;
            if (d == s.bits.display) {
                s.ref += 1;
                return s;
            }
        }
    }
    return null;
}

pub fn installsubfont(name: []const u8, subfont: *Subfont) void {
    if (lastname) |ln| libc.allocator.free(ln);
    lastname = libc.allocator.dupe(u8, name) catch null;
    lastsubfont = subfont; // notice we don't free the old one; that's your business
}

pub fn uninstallsubfont(subfont: *Subfont) void {
    if (lastsubfont == subfont) {
        if (lastname) |ln| libc.allocator.free(ln);
        lastname = null;
        lastsubfont = null;
    }
}
