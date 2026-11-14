//! draw, drawop, gendraw, gendrawop.
//! From /sys/src/libdraw/draw.c (9front 11952).
//!
//! DIFF: draw1 takes its arguments by value.  When the buffer cannot
//! take the message the drawing is dropped, as in C, which says nothing
//! either.

const D = @import("libdraw.zig");
const Image = D.Image;
const Rectangle = D.Rectangle;
const Point = D.Point;
const Drawop = D.Drawop;
const BPLONG = D.BPLONG;

fn draw1(dst: *Image, r: Rectangle, src_: ?*Image, p0: Point, mask_: ?*Image, p1: Point, op: Drawop) void {
    const a = D._bufimageop(dst.display, 1 + 4 + 4 + 4 + 4 * 4 + 2 * 4 + 2 * 4, op) catch return;
    const src = src_ orelse dst.display.black;
    const mask = mask_ orelse dst.display.@"opaque";
    a[0] = 'd';
    BPLONG(a[1..], @bitCast(dst.id));
    BPLONG(a[5..], @bitCast(src.id));
    BPLONG(a[9..], @bitCast(mask.id));
    BPLONG(a[13..], @bitCast(r.min.x));
    BPLONG(a[17..], @bitCast(r.min.y));
    BPLONG(a[21..], @bitCast(r.max.x));
    BPLONG(a[25..], @bitCast(r.max.y));
    BPLONG(a[29..], @bitCast(p0.x));
    BPLONG(a[33..], @bitCast(p0.y));
    BPLONG(a[37..], @bitCast(p1.x));
    BPLONG(a[41..], @bitCast(p1.y));
}

pub fn draw(dst: *Image, r: Rectangle, src: ?*Image, mask: ?*Image, p1: Point) void {
    draw1(dst, r, src, p1, mask, p1, D.SoverD);
}

pub fn drawop(dst: *Image, r: Rectangle, src: ?*Image, mask: ?*Image, p1: Point, op: Drawop) void {
    draw1(dst, r, src, p1, mask, p1, op);
}

pub fn gendraw(dst: *Image, r: Rectangle, src: ?*Image, p0: Point, mask: ?*Image, p1: Point) void {
    draw1(dst, r, src, p0, mask, p1, D.SoverD);
}

pub fn gendrawop(dst: *Image, r: Rectangle, src: ?*Image, p0: Point, mask: ?*Image, p1: Point, op: Drawop) void {
    draw1(dst, r, src, p0, mask, p1, op);
}
