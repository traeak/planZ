//! rc's globbing.
//! from cmd/rc/glob.c
//!
//! In progress: so far deglob, which the compiler uses.

const std = @import("std");
const rc = @import("rc.zig");

/// Remove the GLOB marks from s (a GLOB GLOB becomes one GLOB); the
/// string shrinks to fit.
pub fn deglob(s: []u8) []u8 {
    const r0 = std.mem.indexOfScalar(u8, s, rc.GLOB) orelse return s;
    var w = r0;
    var r = r0 + 1;
    while (r < s.len) {
        if (s[r] == rc.GLOB) {
            r += 1;
            if (r == s.len) break; // the C copies the string's 0 here
        }
        s[w] = s[r];
        w += 1;
        r += 1;
    }
    return rc.erealloc(s, w);
}
