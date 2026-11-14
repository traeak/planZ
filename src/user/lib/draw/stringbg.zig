//! Drawing text on a background.
//! From /sys/src/libdraw/stringbg.c (9front 11952).
//!
//! DIFF: as string.zig.

const D = @import("libdraw.zig");
const Image = D.Image;
const Point = D.Point;
const Font = D.Font;
const Rune = D.Rune;
const Drawop = D.Drawop;

pub fn stringbg(dst: *Image, pt: Point, src: *Image, sp: Point, f: *Font, s: []const u8, bg: *Image, bgp: Point) Point {
    return D._string(dst, pt, src, sp, f, .{ .bytes = s }, 1 << 24, dst.clipr, bg, bgp, D.SoverD);
}

pub fn stringbgop(dst: *Image, pt: Point, src: *Image, sp: Point, f: *Font, s: []const u8, bg: *Image, bgp: Point, op: Drawop) Point {
    return D._string(dst, pt, src, sp, f, .{ .bytes = s }, 1 << 24, dst.clipr, bg, bgp, op);
}

pub fn stringnbg(dst: *Image, pt: Point, src: *Image, sp: Point, f: *Font, s: []const u8, len: i32, bg: *Image, bgp: Point) Point {
    return D._string(dst, pt, src, sp, f, .{ .bytes = s }, len, dst.clipr, bg, bgp, D.SoverD);
}

pub fn stringnbgop(dst: *Image, pt: Point, src: *Image, sp: Point, f: *Font, s: []const u8, len: i32, bg: *Image, bgp: Point, op: Drawop) Point {
    return D._string(dst, pt, src, sp, f, .{ .bytes = s }, len, dst.clipr, bg, bgp, op);
}

pub fn runestringbg(dst: *Image, pt: Point, src: *Image, sp: Point, f: *Font, r: []const Rune, bg: *Image, bgp: Point) Point {
    return D._string(dst, pt, src, sp, f, .{ .runes = r }, 1 << 24, dst.clipr, bg, bgp, D.SoverD);
}

pub fn runestringbgop(dst: *Image, pt: Point, src: *Image, sp: Point, f: *Font, r: []const Rune, bg: *Image, bgp: Point, op: Drawop) Point {
    return D._string(dst, pt, src, sp, f, .{ .runes = r }, 1 << 24, dst.clipr, bg, bgp, op);
}

pub fn runestringnbg(dst: *Image, pt: Point, src: *Image, sp: Point, f: *Font, r: []const Rune, len: i32, bg: *Image, bgp: Point) Point {
    return D._string(dst, pt, src, sp, f, .{ .runes = r }, len, dst.clipr, bg, bgp, D.SoverD);
}

pub fn runestringnbgop(dst: *Image, pt: Point, src: *Image, sp: Point, f: *Font, r: []const Rune, len: i32, bg: *Image, bgp: Point, op: Drawop) Point {
    return D._string(dst, pt, src, sp, f, .{ .runes = r }, len, dst.clipr, bg, bgp, op);
}
