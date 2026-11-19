//! from nusb/usbd/hname.c
//!
//! DIFF: the SHA-1 is the Zig library's (libsec is not ported).

const std = @import("std");
const libc = @import("libc");

/// Replace the text in buf with its hash name, five hexadecimal
/// digits of its SHA-1; returns the name.
pub fn hname(buf: []u8, n: usize) []u8 {
    var d: [std.crypto.hash.Sha1.digest_length]u8 = undefined;

    std.crypto.hash.Sha1.hash(buf[0..n], &d, .{});
    const x: u32 = @as(u32, d[0]) | @as(u32, d[1]) << 8 | @as(u32, d[2]) << 16;
    return libc.sprint(buf[0..n], "%.5ux", .{x & 0xfffff});
}
