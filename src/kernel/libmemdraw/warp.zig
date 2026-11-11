//! Affine warps and image correlation on Memimages.
//! From /sys/src/libmemdraw/warp.c.
//!
//! DIFF:
//!   - Sampler.Δx and Δy are dx and dy; the subscripted locals of
//!     bilinear (c0₀ ...) are small arrays; p2x₀ and p2₀ are p2x0 and
//!     p20.
//!   - The macros are functions.  lerp works on signed 32-bit values;
//!     the C mixes uchar, ulong and long there, and what it finally
//!     stores (the low 8 bits) is the same.
//!   - Pixel addresses are computed from the address of pixel (0,0)
//!     with wrapping arithmetic, as the C's pointer sums are.
//!   - The generic getpixel and putpixel shift with std.math.shr/shl,
//!     so a shift count of 32 or more, which a negative x coordinate
//!     gives in images less than 8 bits deep, yields 0 rather than
//!     being undefined.
//!   - memaffinewarp's static Memdrawparam has no nil for mask in Zig:
//!     mask is memopaque and the other fields the C leaves zero are
//!     zero.  It is there only so hwdraw can keep the software cursor
//!     out of the way.
//!   - A bug of the C fixed: memaffinewarp clips the destination's
//!     clipr to its r and ignores the answer.  When the two do not
//!     meet (devdraw's 'c' message sets any clipr) rectclip leaves
//!     clipr as it was, and the warp is then clipped to a rectangle
//!     outside the image and written there, over whatever memory
//!     follows or precedes the pixels.  Here nothing is drawn.
//!   - Another: memaffinewarp does not refuse a rectangle with
//!     max.x < min.x, which rectclip can pass unchanged or make (from a
//!     clipr with max < min, see libmemdraw/draw.zig).  The integer
//!     upscaling path (the WFintupscale flag comes straight from the
//!     'w' message) then computes its bytes per line from the negative
//!     width, as an unsigned long, and memmoves that much.  Here an
//!     empty or inverted destination rectangle draws nothing.  The
//!     same for the source: with an empty source rectangle the C's
//!     sample1 divides by zero in drawrepl when the source is
//!     replicated, and with an inverted one reads outside the image.
//!   - `smooth` is bool.  allocmemimagekernel takes the coefficients as
//!     a slice (dx*dy of them); flt2fix saturates where the C's
//!     conversion is undefined.  The kernel is built with soft float,
//!     and nothing in it calls allocmemimagekernel.
//!   - memimagecorrelate reads the kernel image's coefficients
//!     unaligned.

const std = @import("std");
const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const memdraw_h = @import("memdraw.zig");
const malloc = @import("alloc.zig");
const kernel = @import("kernel.zig");

const Point = draw.Point;
const Rectangle = draw.Rectangle;
const Warp = draw.Warp;
const Memimage = memdraw_h.Memimage;
const Memdrawparam = memdraw_h.Memdrawparam;
const Dx = draw.Dx;
const Dy = draw.Dy;
const Pt = arith.Pt;
const Rect = arith.Rect;
const rectclip = @import("../libdraw/rectclip.zig").rectclip;
const drawrepl = @import("../libdraw/drawrepl.zig").drawrepl;
const hwdraw = @import("hwdraw.zig").hwdraw;
const allocmemimage = malloc.allocmemimage;

const CRed = draw.CRed;
const CGreen = draw.CGreen;
const CBlue = draw.CBlue;
const CGrey = draw.CGrey;
const CAlpha = draw.CAlpha;
const CMap = draw.CMap;
const CIgnore = draw.CIgnore;

/// perfect approximation to NTSC = .299r+.587g+.114b when 0 ≤ r,g,b < 256
fn RGB2K(r: u32, g: u32, b: u32) u32 {
    return (156763 * r + 307758 * g + 59769 * b) >> 19;
}

// alpha calculation from draw.c
const AMASK = 0xFF00FF;

fn CALC22(a1: u32, vvuu1: u32, a2: u32, vvuu2: u32) u32 {
    const tmp = a1 *% vvuu1 +% a2 *% vvuu2 +% 0x00800080;
    return ((tmp +% ((tmp >> 8) & AMASK)) >> 8) & AMASK;
}

fn CALC42(a1: u32, rgba1: u32, a2: u32, rgba2: u32) u32 {
    return CALC22(a1, rgba1 & AMASK, a2, rgba2 & AMASK) |
        (CALC22(a1, (rgba1 >> 8) & AMASK, a2, (rgba2 >> 8) & AMASK) << 8);
}

// 19.13 fixed-point number operations

const FMASK = (1 << 13) - 1;

fn flt2fix(n: f64) i32 {
    return std.math.lossyCast(i32, n * (1 << 13) + @as(f64, if (n < 0) -0.5 else 0.5));
}
fn int2fix(n: i32) i64 {
    return @as(i64, n) << 13;
}
fn fix2int(n: i32) i32 {
    return n >> 13;
}
fn fixmul(a: i32, b: i32) i64 {
    return (@as(i64, a) * @as(i64, b)) >> 13;
}
fn fixfrac(n: i32) i32 {
    return n & FMASK;
}
fn lerp(a: i32, b: i32, t: i32) i32 {
    return a +% (((b -% a) *% t) >> 13);
}

fn clamp(a: i32, b: i32, c: i32) i32 {
    return if (a < b) b else if (a > c) c else a;
}

const Sampler = struct {
    i: *Memimage,
    a: [*]u8,
    r: Rectangle,
    bpl: i32,
    cmask: u32,
    dx: i32,
    dy: i32,
    k: *Memimage, // filtering kernel
    kcp: Point, // kernel center point
    @"fn": *const fn (*Sampler, Point) u32,
};

const Blitter = struct {
    i: *Memimage,
    a: [*]u8,
    bpl: i32,
    cmask: u32,
    samp: Sampler, // only used for blending
    @"fn": *const fn (*Blitter, Point, u32) void,
};

/// a + off, as C's pointer arithmetic
fn padd(a: [*]u8, off: isize) [*]u8 {
    return @ptrFromInt(@intFromPtr(a) +% @as(usize, @bitCast(off)));
}

/// a + y*bpl + x
fn paddr(a: [*]u8, bpl: i32, y: i32, x: i32) [*]u8 {
    return padd(a, @as(isize, y) * bpl + x);
}

fn initsampler(s: *Sampler, i: *Memimage) void {
    s.i = i;
    s.a = padd(i.data.bdata, i.zero);
    s.bpl = @bitCast(@as(u32, @sizeOf(u32)) *% i.width);
    s.cmask = @truncate((@as(u64, 1) << @intCast(i.depth)) - 1);
    s.@"fn" = getsampfn(i.chan);
}

fn initblitter(b: *Blitter, i: *Memimage) void {
    b.i = i;
    b.a = padd(i.data.bdata, i.zero);
    b.bpl = @bitCast(@as(u32, @sizeOf(u32)) *% i.width);
    b.cmask = @truncate((@as(u64, 1) << @intCast(i.depth)) - 1);
    b.@"fn" = getblitfn(i.chan);
}

fn xform(p: Point, m: *const Warp) Point {
    return .{
        .x = @truncate(fixmul(p.x, m.m[0][0]) +% fixmul(p.y, m.m[0][1]) +% m.m[0][2]),
        .y = @truncate(fixmul(p.x, m.m[1][0]) +% fixmul(p.y, m.m[1][1]) +% m.m[1][2]),
    };
}

fn getpixel_k1(s: *Sampler, pt: Point) u32 {
    const p = paddr(s.a, s.bpl, pt.y, pt.x >> 3);
    const npack: u32 = 8 - 1;
    const off: u32 = @as(u32, @bitCast(pt.x)) & npack;
    const v: u32 = (p[0] >> @intCast(npack - off)) & 0x1;
    return v *% 0xFFFFFF00 | 0xFF;
}

fn getpixel_k2(s: *Sampler, pt: Point) u32 {
    const p = paddr(s.a, s.bpl, pt.y, (pt.x *% 2) >> 3);
    const npack: u32 = 8 / 2 - 1;
    const off: u32 = @as(u32, @bitCast(pt.x)) & npack;
    const v: u32 = (p[0] >> @intCast(2 * (npack - off))) & 0x3;
    return v *% 0x55555500 | 0xFF;
}

fn getpixel_k4(s: *Sampler, pt: Point) u32 {
    const p = paddr(s.a, s.bpl, pt.y, (pt.x *% 4) >> 3);
    const npack: u32 = 8 / 4 - 1;
    const off: u32 = @as(u32, @bitCast(pt.x)) & npack;
    const v: u32 = (p[0] >> @intCast(4 * (npack - off))) & 0xF;
    return v *% 0x11111100 | 0xFF;
}

fn getpixel_k8(s: *Sampler, pt: Point) u32 {
    const p = paddr(s.a, s.bpl, pt.y, pt.x);
    return @as(u32, p[0]) *% 0x01010100 | 0xFF;
}

fn getpixel_m8(s: *Sampler, pt: Point) u32 {
    const m: usize = paddr(s.a, s.bpl, pt.y, pt.x)[0];
    const p = s.i.cmap.cmap2rgb[3 * m ..];
    return (@as(u32, p[0]) << 24) | (@as(u32, p[1]) << 16) | (@as(u32, p[2]) << 8) | 0xFF;
}

fn getpixel_x1r5g5b5(s: *Sampler, pt: Point) u32 {
    const p = paddr(s.a, s.bpl, pt.y, pt.x *% 2);
    var val: u32 = p[0] | (@as(u32, p[1]) << 8);
    var b = val & 0x1F;
    b = (b << 3) | (b >> 2);
    val >>= 5;
    var g = val & 0x1F;
    g = (g << 3) | (g >> 2);
    val >>= 5;
    var r = val & 0x1F;
    r = (r << 3) | (r >> 2);
    return (r << 24) | (g << 16) | (b << 8) | 0xFF;
}

fn getpixel_r5g6b5(s: *Sampler, pt: Point) u32 {
    const p = paddr(s.a, s.bpl, pt.y, pt.x *% 2);
    var val: u32 = p[0] | (@as(u32, p[1]) << 8);
    var b = val & 0x1F;
    b = (b << 3) | (b >> 2);
    val >>= 5;
    var g = val & 0x3F;
    g = (g << 2) | (g >> 4);
    val >>= 6;
    var r = val & 0x1F;
    r = (r << 3) | (r >> 2);
    return (r << 24) | (g << 16) | (b << 8) | 0xFF;
}

fn getpixel_r8g8b8(s: *Sampler, pt: Point) u32 {
    const p = paddr(s.a, s.bpl, pt.y, pt.x *% 3);
    return (@as(u32, p[2]) << 24) | (@as(u32, p[1]) << 16) | (@as(u32, p[0]) << 8) | 0xFF;
}

fn getpixel_r8g8b8a8(s: *Sampler, pt: Point) u32 {
    const p = paddr(s.a, s.bpl, pt.y, pt.x *% 4);
    return (@as(u32, p[3]) << 24) | (@as(u32, p[2]) << 16) | (@as(u32, p[1]) << 8) | p[0];
}

fn getpixel_a8r8g8b8(s: *Sampler, pt: Point) u32 {
    const p = paddr(s.a, s.bpl, pt.y, pt.x *% 4);
    return (@as(u32, p[2]) << 24) | (@as(u32, p[1]) << 16) | (@as(u32, p[0]) << 8) | p[3];
}

fn getpixel_x8r8g8b8(s: *Sampler, pt: Point) u32 {
    const p = paddr(s.a, s.bpl, pt.y, pt.x *% 4);
    return (@as(u32, p[2]) << 24) | (@as(u32, p[1]) << 16) | (@as(u32, p[0]) << 8) | 0xFF;
}

fn getpixel_x1b5g5r5(s: *Sampler, pt: Point) u32 {
    const p = paddr(s.a, s.bpl, pt.y, pt.x *% 2);
    var val: u32 = p[0] | (@as(u32, p[1]) << 8);
    var r = val & 0x1F;
    r = (r << 3) | (r >> 2);
    val >>= 5;
    var g = val & 0x1F;
    g = (g << 3) | (g >> 2);
    val >>= 5;
    var b = val & 0x1F;
    b = (b << 3) | (b >> 2);
    return (r << 24) | (g << 16) | (b << 8) | 0xFF;
}

fn getpixel_b8g8r8(s: *Sampler, pt: Point) u32 {
    const p = paddr(s.a, s.bpl, pt.y, pt.x *% 3);
    return (@as(u32, p[0]) << 24) | (@as(u32, p[1]) << 16) | (@as(u32, p[2]) << 8) | 0xFF;
}

fn getpixel_a8b8g8r8(s: *Sampler, pt: Point) u32 {
    const p = paddr(s.a, s.bpl, pt.y, pt.x *% 4);
    return (@as(u32, p[0]) << 24) | (@as(u32, p[1]) << 16) | (@as(u32, p[2]) << 8) | p[3];
}

fn getpixel_x8b8g8r8(s: *Sampler, pt: Point) u32 {
    const p = paddr(s.a, s.bpl, pt.y, pt.x *% 4);
    return (@as(u32, p[0]) << 24) | (@as(u32, p[1]) << 16) | (@as(u32, p[2]) << 8) | 0xFF;
}

fn getpixel(s: *Sampler, pt: Point) u32 {
    var val: u32 = 0;
    var a: u32 = 0xFF;
    var r: u32 = 0xAA; // garbage
    var g: u32 = 0xAA;
    var b: u32 = 0xAA;
    const p = paddr(s.a, s.bpl, pt.y, (pt.x *% s.i.depth) >> 3);

    // pixelbits()
    var bpp = s.i.depth;
    switch (bpp) {
        1, 2, 4 => {
            const npack = @divTrunc(8, bpp);
            const off = @rem(pt.x, npack);
            val = std.math.shr(u32, p[0], @as(u32, @bitCast(bpp *% (npack - 1 - off))));
            val &= s.cmask;
        },
        8 => val = p[0],
        16 => val = p[0] | (@as(u32, p[1]) << 8),
        24 => val = p[0] | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16),
        32 => val = p[0] | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24),
        else => {},
    }

    while (bpp < 32) {
        val |= std.math.shl(u32, val, @as(u32, @bitCast(bpp)));
        bpp *= 2;
    }

    // imgtorgba()
    var chan = s.i.chan;
    while (chan != 0) : (chan >>= 8) {
        const ctype = draw.TYPE(chan);
        if (ctype == CIgnore) {
            val = std.math.shr(u32, val, @as(u32, @bitCast(s.i.nbits[ctype])));
            continue;
        }
        var nb = s.i.nbits[ctype];
        const ov = val & s.i.mask[ctype];
        var v = ov;
        val = std.math.shr(u32, val, @as(u32, @bitCast(nb)));

        while (nb < 8) {
            v |= std.math.shl(u32, v, @as(u32, @bitCast(nb)));
            if (nb <= 0) // not in the C, which would spin here
                break;
            nb *= 2;
        }
        v = std.math.shr(u32, v, @as(u32, @bitCast(nb -% 8)));
        v &= 0xFF; // the C assigns to uchar

        switch (ctype) {
            CRed => r = v,
            CGreen => g = v,
            CBlue => b = v,
            CAlpha => a = v,
            CGrey => {
                r = v;
                g = v;
                b = v;
            },
            CMap => {
                const cp = s.i.cmap.cmap2rgb[3 * @as(usize, ov & 0xFF) ..];
                r = cp[0];
                g = cp[1];
                b = cp[2];
            },
            else => {},
        }
    }
    return (r << 24) | (g << 16) | (b << 8) | a;
}

fn putpixel_k1(blt: *Blitter, dp: Point, rgba: u32) void {
    const p = paddr(blt.a, blt.bpl, dp.y, dp.x >> 3);

    const r = (rgba >> 24) & 0xFF;
    const g = (rgba >> 16) & 0xFF;
    const b = (rgba >> 8) & 0xFF;
    var m = RGB2K(r, g, b) & 0xFF;
    m >>= 8 - 1;

    var mask: u32 = 0x1;
    const npack: u32 = 8 - 1;
    const off = @as(u32, @bitCast(dp.x)) & npack;
    const sh: u5 = @intCast(npack - off);
    mask <<= sh;
    m = (m << sh) & 0xFF;
    p[0] = @truncate(((p[0] ^ m) & mask) ^ p[0]);
}

fn putpixel_k2(blt: *Blitter, dp: Point, rgba: u32) void {
    const p = paddr(blt.a, blt.bpl, dp.y, (dp.x *% 2) >> 3);

    const r = (rgba >> 24) & 0xFF;
    const g = (rgba >> 16) & 0xFF;
    const b = (rgba >> 8) & 0xFF;
    var m = RGB2K(r, g, b) & 0xFF;
    m >>= 8 - 2;

    var mask: u32 = 0x3;
    const npack: u32 = 8 / 2 - 1;
    const off = @as(u32, @bitCast(dp.x)) & npack;
    const sh: u5 = @intCast(2 * (npack - off));
    mask <<= sh;
    m = (m << sh) & 0xFF;
    p[0] = @truncate(((p[0] ^ m) & mask) ^ p[0]);
}

fn putpixel_k4(blt: *Blitter, dp: Point, rgba: u32) void {
    const p = paddr(blt.a, blt.bpl, dp.y, (dp.x *% 4) >> 3);

    const r = (rgba >> 24) & 0xFF;
    const g = (rgba >> 16) & 0xFF;
    const b = (rgba >> 8) & 0xFF;
    var m = RGB2K(r, g, b) & 0xFF;
    m >>= 8 - 4;

    var mask: u32 = 0xF;
    const npack: u32 = 8 / 4 - 1;
    const off = @as(u32, @bitCast(dp.x)) & npack;
    const sh: u5 = @intCast(4 * (npack - off));
    mask <<= sh;
    m = (m << sh) & 0xFF;
    p[0] = @truncate(((p[0] ^ m) & mask) ^ p[0]);
}

fn putpixel_k8(blt: *Blitter, dp: Point, rgba: u32) void {
    const r = (rgba >> 24) & 0xFF;
    const g = (rgba >> 16) & 0xFF;
    const b = (rgba >> 8) & 0xFF;
    const m = RGB2K(r, g, b);
    const p = paddr(blt.a, blt.bpl, dp.y, dp.x);
    p[0] = @truncate(m);
}

fn putpixel_m8(blt: *Blitter, dp: Point, rgba: u32) void {
    const r = (rgba >> 24) & 0xFF;
    const g = (rgba >> 16) & 0xFF;
    const b = (rgba >> 8) & 0xFF;
    const m = blt.i.cmap.rgb2cmap[(r >> 4) * 256 + (g >> 4) * 16 + (b >> 4)];
    const p = paddr(blt.a, blt.bpl, dp.y, dp.x);
    p[0] = m;
}

fn putpixel_x1r5g5b5(blt: *Blitter, dp: Point, rgba: u32) void {
    const r = (rgba >> 24) & 0xFF;
    const g = (rgba >> 16) & 0xFF;
    const b = (rgba >> 8) & 0xFF;
    var v: u32 = r >> (8 - 5);
    v = (v << 5) | (g >> (8 - 5));
    v = (v << 5) | (b >> (8 - 5));
    const p = paddr(blt.a, blt.bpl, dp.y, dp.x *% 2);
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
}

fn putpixel_r5g6b5(blt: *Blitter, dp: Point, rgba: u32) void {
    const r = (rgba >> 24) & 0xFF;
    const g = (rgba >> 16) & 0xFF;
    const b = (rgba >> 8) & 0xFF;
    var v: u32 = r >> (8 - 5);
    v = (v << 6) | (g >> (8 - 6));
    v = (v << 5) | (b >> (8 - 5));
    const p = paddr(blt.a, blt.bpl, dp.y, dp.x *% 2);
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
}

fn putpixel_r8g8b8(blt: *Blitter, dp: Point, rgba: u32) void {
    const p = paddr(blt.a, blt.bpl, dp.y, dp.x *% 3);
    p[0] = @truncate(rgba >> 8);
    p[1] = @truncate(rgba >> 16);
    p[2] = @truncate(rgba >> 24);
}

fn putpixel_r8g8b8a8(blt: *Blitter, dp: Point, rgba: u32) void {
    const p = paddr(blt.a, blt.bpl, dp.y, dp.x *% 4);
    p[0] = @truncate(rgba);
    p[1] = @truncate(rgba >> 8);
    p[2] = @truncate(rgba >> 16);
    p[3] = @truncate(rgba >> 24);
}

fn putpixel_a8r8g8b8(blt: *Blitter, dp: Point, rgba: u32) void {
    const p = paddr(blt.a, blt.bpl, dp.y, dp.x *% 4);
    p[0] = @truncate(rgba >> 8);
    p[1] = @truncate(rgba >> 16);
    p[2] = @truncate(rgba >> 24);
    p[3] = @truncate(rgba);
}

fn putpixel_x8r8g8b8(blt: *Blitter, dp: Point, rgba: u32) void {
    const p = paddr(blt.a, blt.bpl, dp.y, dp.x *% 4);
    p[0] = @truncate(rgba >> 8);
    p[1] = @truncate(rgba >> 16);
    p[2] = @truncate(rgba >> 24);
}

fn putpixel_x1b5g5r5(blt: *Blitter, dp: Point, rgba: u32) void {
    const r = (rgba >> 24) & 0xFF;
    const g = (rgba >> 16) & 0xFF;
    const b = (rgba >> 8) & 0xFF;
    var v: u32 = b >> (8 - 5);
    v = (v << 5) | (g >> (8 - 5));
    v = (v << 5) | (r >> (8 - 5));
    const p = paddr(blt.a, blt.bpl, dp.y, dp.x *% 2);
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
}

fn putpixel_b8g8r8(blt: *Blitter, dp: Point, rgba: u32) void {
    const p = paddr(blt.a, blt.bpl, dp.y, dp.x *% 3);
    p[0] = @truncate(rgba >> 24);
    p[1] = @truncate(rgba >> 16);
    p[2] = @truncate(rgba >> 8);
}

fn putpixel_a8b8g8r8(blt: *Blitter, dp: Point, rgba: u32) void {
    const p = paddr(blt.a, blt.bpl, dp.y, dp.x *% 4);
    p[0] = @truncate(rgba >> 24);
    p[1] = @truncate(rgba >> 16);
    p[2] = @truncate(rgba >> 8);
    p[3] = @truncate(rgba);
}

fn putpixel_x8b8g8r8(blt: *Blitter, dp: Point, rgba: u32) void {
    const p = paddr(blt.a, blt.bpl, dp.y, dp.x *% 4);
    p[0] = @truncate(rgba >> 24);
    p[1] = @truncate(rgba >> 16);
    p[2] = @truncate(rgba >> 8);
}

/// (c >> (8-nbits)) << shift, for one channel of putpixel
fn chanbits(i: *Memimage, c: u32, ctype: usize) u32 {
    const down: u32 = @bitCast(8 -% i.nbits[ctype]);
    const up: u32 = @bitCast(i.shift[ctype]);
    return std.math.shl(u32, std.math.shr(u32, c, down), up);
}

fn putpixel(blt: *Blitter, dp: Point, rgba: u32) void {
    const i = blt.i;
    const p = paddr(blt.a, blt.bpl, dp.y, (dp.x *% i.depth) >> 3);

    // rgbatoimg()
    var v: u32 = 0;
    const r = (rgba >> 24) & 0xFF;
    const g = (rgba >> 16) & 0xFF;
    const b = (rgba >> 8) & 0xFF;
    const a = rgba & 0xFF;
    var chan = i.chan;
    while (chan != 0) : (chan >>= 8) {
        switch (draw.TYPE(chan)) {
            CIgnore => continue,
            CRed => v |= chanbits(i, r, CRed),
            CGreen => v |= chanbits(i, g, CGreen),
            CBlue => v |= chanbits(i, b, CBlue),
            CAlpha => v |= chanbits(i, a, CAlpha),
            CMap => {
                const m: u32 = i.cmap.rgb2cmap[(r >> 4) * 256 + (g >> 4) * 16 + (b >> 4)];
                v |= chanbits(i, m, CMap);
            },
            CGrey => {
                const m = RGB2K(r, g, b) & 0xFF;
                v |= chanbits(i, m, CGrey);
            },
            else => {},
        }
    }

    // blit op
    const ov: u32 = p[0] | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);

    var mask = blt.cmask;
    if (i.depth < 8) {
        const npack = @divTrunc(8, i.depth);
        const off = @rem(dp.x, npack);
        const sh: u32 = @bitCast(i.depth *% (npack - 1 - off));
        mask = std.math.shl(u32, mask, sh);
        v = std.math.shl(u32, v, sh);
    }
    v = ((ov ^ v) & mask) ^ ov; // ≡ (ov &~ mask) | (v & mask)
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
    p[2] = @truncate(v >> 16);
    p[3] = @truncate(v >> 24);
}

fn getsampfn(chan: u32) *const fn (*Sampler, Point) u32 {
    return switch (chan) {
        draw.GREY1 => getpixel_k1,
        draw.GREY2 => getpixel_k2,
        draw.GREY4 => getpixel_k4,
        draw.GREY8 => getpixel_k8,
        draw.CMAP8 => getpixel_m8,
        draw.RGB15 => getpixel_x1r5g5b5,
        draw.RGB16 => getpixel_r5g6b5,
        draw.RGB24 => getpixel_r8g8b8,
        draw.RGBA32 => getpixel_r8g8b8a8,
        draw.ARGB32 => getpixel_a8r8g8b8,
        draw.XRGB32 => getpixel_x8r8g8b8,
        draw.BGR15 => getpixel_x1b5g5r5,
        draw.BGR24 => getpixel_b8g8r8,
        draw.ABGR32 => getpixel_a8b8g8r8,
        draw.XBGR32 => getpixel_x8b8g8r8,
        else => getpixel,
    };
}

fn getblitfn(chan: u32) *const fn (*Blitter, Point, u32) void {
    return switch (chan) {
        draw.GREY1 => putpixel_k1,
        draw.GREY2 => putpixel_k2,
        draw.GREY4 => putpixel_k4,
        draw.GREY8 => putpixel_k8,
        draw.CMAP8 => putpixel_m8,
        draw.RGB15 => putpixel_x1r5g5b5,
        draw.RGB16 => putpixel_r5g6b5,
        draw.RGB24 => putpixel_r8g8b8,
        draw.RGBA32 => putpixel_r8g8b8a8,
        draw.ARGB32 => putpixel_a8r8g8b8,
        draw.XRGB32 => putpixel_x8r8g8b8,
        draw.BGR15 => putpixel_x1b5g5r5,
        draw.BGR24 => putpixel_b8g8r8,
        draw.ABGR32 => putpixel_a8b8g8r8,
        draw.XBGR32 => putpixel_x8b8g8r8,
        else => putpixel,
    };
}

fn blendblit(b: *Blitter, dp: Point, c: u32) void {
    const sa = c & 0xFF;
    if (sa == 0)
        return;
    if (sa == 0xFF) {
        b.@"fn"(b, dp, c);
        return;
    }
    var dc = b.samp.@"fn"(&b.samp, dp);
    const da = 255 - sa;
    dc = CALC42(sa, c, da, dc);
    b.@"fn"(b, dp, dc);
}

fn sample1(s: *Sampler, p: Point) u32 {
    if (p.y >= s.r.min.y and p.y < s.r.max.y and
        p.x >= s.r.min.x and p.x < s.r.max.x)
        return s.@"fn"(s, p)
    else if (s.i.flags & memdraw_h.Frepl != 0) {
        return s.@"fn"(s, drawrepl(s.r, p));
    }
    // edge handler: constant
    return 0;
}

fn bilinear(s: *Sampler, p_: Point) u32 {
    var p = p_;
    var c0: [4]i32 = undefined;
    var c1: [4]i32 = undefined;

    const c00 = sample1(s, p);
    p.x +%= 1;
    const c01 = sample1(s, p);
    p.x -%= 1;
    p.y +%= 1;
    const c10 = sample1(s, p);
    p.x +%= 1;
    const c11 = sample1(s, p);

    for (0..4) |n| {
        const sh: u5 = @intCast(24 - 8 * n);
        c0[n] = @intCast((c00 >> sh) & 0xFF);
        c1[n] = @intCast((c10 >> sh) & 0xFF);
        c0[n] = lerp(c0[n], @intCast((c01 >> sh) & 0xFF), s.dx) & 0xFF;
        c1[n] = lerp(c1[n], @intCast((c11 >> sh) & 0xFF), s.dx) & 0xFF;
    }
    return @as(u32, @bitCast(lerp(c0[0], c1[0], s.dy))) << 24 |
        @as(u32, @bitCast(lerp(c0[1], c1[1], s.dy))) << 16 |
        @as(u32, @bitCast(lerp(c0[2], c1[2], s.dy))) << 8 |
        @as(u32, @bitCast(lerp(c0[3], c1[3], s.dy)));
}

fn correlate(s: *Sampler, p: Point) u32 {
    var sp: Point = undefined;
    var sr: i32 = 0;
    var sg: i32 = 0;
    var sb: i32 = 0;
    var sa: i32 = 0;

    const kp: [*]align(1) const i32 = @ptrCast(padd(s.k.data.bdata, s.k.zero));

    sp.y = 0;
    while (sp.y < s.k.r.max.y) : (sp.y += 1) {
        sp.x = 0;
        while (sp.x < s.k.r.max.x) : (sp.x += 1) {
            const v = sample1(s, .{ .x = p.x +% (sp.x -% s.kcp.x), .y = p.y +% (sp.y -% s.kcp.y) });
            var r: i32 = @truncate(int2fix(@intCast((v >> 24) & 0xFF)));
            var g: i32 = @truncate(int2fix(@intCast((v >> 16) & 0xFF)));
            var b: i32 = @truncate(int2fix(@intCast((v >> 8) & 0xFF)));
            var a: i32 = @truncate(int2fix(@intCast((v >> 0) & 0xFF)));

            const kv = kp[@intCast(sp.y * s.k.r.max.x + sp.x)];
            r = @truncate(fixmul(r, kv));
            g = @truncate(fixmul(g, kv));
            b = @truncate(fixmul(b, kv));
            a = @truncate(fixmul(a, kv));

            sr +%= r;
            sg +%= g;
            sb +%= b;
            sa +%= a;
        }
    }
    const r: u32 = @intCast(clamp(fix2int(sr), 0, 0xFF));
    const g: u32 = @intCast(clamp(fix2int(sg), 0, 0xFF));
    const b: u32 = @intCast(clamp(fix2int(sb), 0, 0xFF));
    const a: u32 = @intCast(clamp(fix2int(sa), 0, 0xFF));

    return r << 24 | g << 16 | b << 8 | a;
}

//
// integer upscaling optimization
//
fn intupscalewarp(blit: *Blitter, dp0: Point, r: Rectangle, samp: *Sampler, sp0: Point, m: *const Warp, op: i32) void {
    var blitfn: *const fn (*Blitter, Point, u32) void = undefined;
    var sp: Point = undefined;
    var dp: Point = undefined;
    var p2: Point = undefined;

    if (op == draw.SoverD and (samp.i.flags & memdraw_h.Falpha) != 0) {
        initsampler(&blit.samp, blit.i);
        blitfn = blendblit;
    } else blitfn = blit.@"fn";
    const bpl: usize = @intCast((Dx(r) * blit.i.depth) >> 3);

    p2.x = @truncate(int2fix(r.min.x -% dp0.x) +% (1 << 12));
    p2.y = @truncate(int2fix(r.min.y -% dp0.y) +% (1 << 12));
    p2 = xform(p2, m);
    const p2x0 = p2.x;

    const dxdx = m.m[0][0];
    const dydy = m.m[1][1];

    dp.y = r.min.y;
    while (dp.y < r.max.y) {
        sp.y = sp0.y +% fix2int(p2.y);
        dp.x = r.min.x;
        while (dp.x < r.max.x) {
            sp.x = sp0.x +% fix2int(p2.x);

            const c = sample1(samp, sp);
            var i = fixfrac(p2.x);
            while (i < int2fix(1) and dp.x < r.max.x) : (i +%= dxdx) {
                blitfn(blit, dp, c);
                dp.x += 1;
                p2.x +%= dxdx;
            }
        }
        var p = paddr(blit.a, blit.bpl, dp.y, (r.min.x *% blit.i.depth) >> 3);
        dp.y += 1;
        var i = fixfrac(p2.y);
        p2.y +%= dydy;
        i +%= dydy;
        while (i < int2fix(1) and dp.y < r.max.y) : (i +%= dydy) {
            const np = padd(p, blit.bpl);
            @memmove(np[0..bpl], p[0..bpl]);
            p = np;
            dp.y += 1;
            p2.y +%= dydy;
        }
        p2.x = p2x0;
    }
}

/// memaffinewarp's static Memdrawparam
var par: Memdrawparam = undefined;

pub fn memaffinewarp(d: *Memimage, dp0: Point, r_: Rectangle, s: *Memimage, sp0: Point, _: ?*Memimage, _: Point, w: *const Warp, smooth: bool, op: i32) void {
    var r = r_;
    var blitfn: *const fn (*Blitter, Point, u32) void = undefined;
    var samp: Sampler = undefined;
    var blit: Blitter = undefined;
    var sp: Point = undefined;
    var dp: Point = undefined;

    var dr = d.clipr;
    // DIFF: the C does not look at the result, see the header
    if (!rectclip(&dr, d.r))
        return;
    if (!rectclip(&r, dr))
        return;
    // DIFF: rectclip lets an inverted rectangle through, see the header
    if (Dx(r) <= 0 or Dy(r) <= 0)
        return;

    samp.r = s.clipr;
    if (!rectclip(&samp.r, s.r))
        return;
    // DIFF: likewise
    if (Dx(samp.r) <= 0 or Dy(samp.r) <= 0)
        return;

    // avoid sw cursor
    par = .{
        .dst = d,
        .r = r,
        .src = s,
        .sr = draw.ZR,
        .mask = memdraw_h.memopaque,
        .mr = draw.ZR,
        .op = 0,
        .state = 0,
        .mval = 0,
        .mrgba = 0,
        .sval = 0,
        .srgba = 0,
        .sdval = 0,
    };
    _ = hwdraw(&par);

    initsampler(&samp, s);
    initblitter(&blit, d);

    if (!smooth and (w.flags & draw.WFintupscale) != 0) {
        intupscalewarp(&blit, dp0, r, &samp, sp0, w, op);
        return;
    }
    const sampfn: *const fn (*Sampler, Point) u32 = if (smooth) bilinear else sample1;
    if (op == draw.SoverD and (s.flags & memdraw_h.Falpha) != 0) {
        initsampler(&blit.samp, d);
        blitfn = blendblit;
    } else blitfn = blit.@"fn";

    //
    // incremental affine warping technique from:
    //      “Fast Affine Transform for Real-Time Machine Vision Applications”,
    //      Lee, S., Lee, GG., Jang, E.S., Kim, WY,
    //      Intelligent Computing.  ICIC 2006. LNCS, vol 4113.
    //
    var p20 = xform(.{
        .x = @truncate(int2fix(r.min.x -% dp0.x) +% (1 << 12)),
        .y = @truncate(int2fix(r.min.y -% dp0.y) +% (1 << 12)),
    }, w);
    var p2 = p20;
    dp.y = r.min.y;
    while (dp.y < r.max.y) : (dp.y += 1) {
        dp.x = r.min.x;
        while (dp.x < r.max.x) : (dp.x += 1) {
            samp.dx = fixfrac(p2.x);
            samp.dy = fixfrac(p2.y);

            sp.x = sp0.x +% fix2int(p2.x);
            sp.y = sp0.y +% fix2int(p2.y);

            const c = sampfn(&samp, sp);
            blitfn(&blit, dp, c);

            p2.x +%= w.m[0][0];
            p2.y +%= w.m[1][0];
        }
        p20.x +%= w.m[0][1];
        p2.x = p20.x;
        p20.y +%= w.m[1][1];
        p2.y = p20.y;
    }
}

fn coeffsum(m: []const f64) f64 {
    var sum: f64 = 0;
    for (m) |v|
        sum += v;
    return sum;
}

pub fn allocmemimagekernel(k: []const f64, dx: i32, dy: i32, denom_: f64) ?*Memimage {
    var denom = denom_;

    const ik = allocmemimage(Rect(0, 0, dx, dy), draw.RGBA32) orelse { // any 32-bit depth chan would do
        kernel.werrstr("could not allocate image kernel: %r", .{});
        return null;
    };

    const udx: usize = @intCast(dx);
    const udy: usize = @intCast(dy);
    if (denom == 0)
        denom = coeffsum(k[0 .. udx * udy]);
    denom = if (denom != 0) 1 / denom else 1;

    const kern: [*]align(1) i32 = @ptrCast(padd(ik.data.bdata, ik.zero));
    for (0..udy) |y| {
        for (0..udx) |x| {
            var t = k[y * udx + x];
            t *= denom;
            kern[y * udx + x] = flt2fix(t);
        }
    }

    return ik;
}

pub fn memimagecorrelate(d: *Memimage, r_: Rectangle, s: *Memimage, sp0: Point, k_: ?*Memimage) i32 {
    var r = r_;
    var samp: Sampler = undefined;
    var blit: Blitter = undefined;
    var sp: Point = undefined;
    var dp: Point = undefined;

    var dr = d.clipr;
    _ = rectclip(&dr, d.r);
    if (!rectclip(&r, dr))
        return 0;

    samp.r = s.clipr;
    if (!rectclip(&samp.r, s.r))
        return 0;

    initsampler(&samp, s);
    initblitter(&blit, d);

    const k = k_ orelse {
        kernel.werrstr("kernel image is nil", .{});
        return -1;
    };
    if (k.depth != 32) {
        kernel.werrstr("kernel image depth is not 32", .{});
        return -1;
    }
    samp.k = k;
    samp.kcp = Pt(@divTrunc(Dx(k.r), 2), @divTrunc(Dy(k.r), 2));

    dp.y = r.min.y;
    while (dp.y < r.max.y) : (dp.y += 1) {
        dp.x = r.min.x;
        while (dp.x < r.max.x) : (dp.x += 1) {
            sp.x = sp0.x +% dp.x -% dr.min.x;
            sp.y = sp0.y +% dp.y -% dr.min.y;
            const c = correlate(&samp, sp);
            blit.@"fn"(&blit, dp, c);
        }
    }
    return 0;
}

test "warps, against the C library" {
    const T = @import("line.zig").testing;
    const mdraw = @import("draw.zig");
    const freememimage = malloc.freememimage;
    T.init();
    defer T.deinit();
    var ref = T.Ref.init(want);

    const cases = [_]struct { d: u32, s: u32, name: []const u8 }{
        .{ .d = draw.XRGB32, .s = draw.RGB24, .name = "x-rgb24" },
        .{ .d = draw.RGB16, .s = draw.RGBA32, .name = "r5g6b5-rgba" },
        .{ .d = draw.GREY8, .s = draw.CMAP8, .name = "k8-m8" },
        .{ .d = draw.GREY2, .s = draw.GREY4, .name = "k2-k4" },
        .{ .d = draw.RGBA32, .s = draw.RGB15, .name = "rgba-rgb15" },
        .{ .d = draw.ABGR32, .s = draw.ARGB32, .name = "abgr-argb" },
        .{ .d = draw.BGR24, .s = draw.XBGR32, .name = "bgr24-xbgr" },
        .{ .d = draw.CHAN2(draw.CAlpha, 8, draw.CGrey, 8), .s = draw.CHAN2(draw.CGrey, 8, draw.CAlpha, 8), .name = "a8k8-k8a8" },
    };
    for (cases) |cs| {
        const s = T.tex(Rect(0, 0, 16, 12), cs.s);
        defer freememimage(s);
        const d = T.mk(Rect(0, 0, 64, 48), cs.d, draw.DWhite);
        defer freememimage(d);

        // scale by 1/3 (source step) with a little shear and an offset
        var w: Warp = .{ .m = .{ .{ 2731, 300, -4096 }, .{ -200, 2731, 8192 }, .{ 0, 0, 8192 } }, .flags = 0 };
        memaffinewarp(d, Pt(2, 3), Rect(2, 3, 60, 44), s, draw.ZP, null, draw.ZP, &w, false, draw.S);
        ref.out(cs.name, "warp_nearest", d);
        memaffinewarp(d, Pt(2, 3), Rect(2, 3, 60, 44), s, draw.ZP, null, draw.ZP, &w, true, draw.SoverD);
        ref.out(cs.name, "warp_smooth", d);

        // integer upscale by 4
        w = .{ .m = .{ .{ 2048, 0, 0 }, .{ 0, 2048, 0 }, .{ 0, 0, 8192 } }, .flags = draw.WFintupscale };
        mdraw.memfillcolor(d, draw.DBlack);
        memaffinewarp(d, Pt(0, 0), d.r, s, draw.ZP, null, draw.ZP, &w, false, draw.S);
        ref.out(cs.name, "warp_upscale", d);
        s.flags |= memdraw_h.Frepl;
        s.clipr = Rect(-1000, -1000, 1000, 1000);
        memaffinewarp(d, Pt(5, 5), Rect(1, 1, 63, 47), s, Pt(3, 2), null, draw.ZP, &w, false, draw.SoverD);
        ref.out(cs.name, "warp_upscale_repl", d);

        const k = [9]f64{ 1, 2, 1, 2, 4, 2, 1, 2, -1 };
        var ik = allocmemimagekernel(&k, 3, 3, 0).?;
        _ = memimagecorrelate(d, Rect(4, 4, 60, 40), s, Pt(-2, -1), ik);
        ref.out(cs.name, "warp_correlate", d);
        freememimage(ik);
        ik = allocmemimagekernel(&k, 3, 3, 7.5).?;
        _ = memimagecorrelate(d, Rect(0, 0, 30, 48), s, Pt(5, 5), ik);
        ref.out(cs.name, "warp_correlate2", d);
        freememimage(ik);
    }
    try ref.done();
}

/// What the C program printed (see `testing` in libmemdraw/line.zig).
const want =
    \\x-rgb24.warp_nearest 647b022de3be0940
    \\x-rgb24.warp_smooth c0ae9d5cd5c2dd4d
    \\x-rgb24.warp_upscale 6097438419a59ea5
    \\x-rgb24.warp_upscale_repl b752f04606f3c3df
    \\x-rgb24.warp_correlate 85c19819f1f1d89c
    \\x-rgb24.warp_correlate2 6579f2bf882b880e
    \\r5g6b5-rgba.warp_nearest dd0bac5893b90df9
    \\r5g6b5-rgba.warp_smooth 4a0801f2312034bb
    \\r5g6b5-rgba.warp_upscale 3ab07bd81c78c525
    \\r5g6b5-rgba.warp_upscale_repl edc9795028618370
    \\r5g6b5-rgba.warp_correlate 8e58ff0c30ab4d6f
    \\r5g6b5-rgba.warp_correlate2 4c22cde1b0b3fcf3
    \\k8-m8.warp_nearest 55cedf0179aa9d7d
    \\k8-m8.warp_smooth b331f8a5f715b12a
    \\k8-m8.warp_upscale 2a9540855fa56a55
    \\k8-m8.warp_upscale_repl 3e23e82fb2a1e225
    \\k8-m8.warp_correlate cc717cdf802ea33b
    \\k8-m8.warp_correlate2 0bf94428c07ee5b7
    \\k2-k4.warp_nearest 320174bb0582e8ee
    \\k2-k4.warp_smooth 3a351f9056f2d4d2
    \\k2-k4.warp_upscale 31eff55074b5d455
    \\k2-k4.warp_upscale_repl 49d209b02cfd16d6
    \\k2-k4.warp_correlate d3aae48706f841fa
    \\k2-k4.warp_correlate2 9c3129976ac490fd
    \\rgba-rgb15.warp_nearest d80e71642f5e8dd0
    \\rgba-rgb15.warp_smooth 5b1c733f33232310
    \\rgba-rgb15.warp_upscale 7ef979f582775a05
    \\rgba-rgb15.warp_upscale_repl 6609af18c5c910cb
    \\rgba-rgb15.warp_correlate be9217d6d53c9110
    \\rgba-rgb15.warp_correlate2 5c6410692d0472b5
    \\abgr-argb.warp_nearest f05b2dd807c18118
    \\abgr-argb.warp_smooth 871e26f4ef42588f
    \\abgr-argb.warp_upscale 6fed732128bdc5a5
    \\abgr-argb.warp_upscale_repl 7fd511cb59330813
    \\abgr-argb.warp_correlate 92842ae2421301c8
    \\abgr-argb.warp_correlate2 5562309c351150f2
    \\bgr24-xbgr.warp_nearest cf7ea93069cbfc06
    \\bgr24-xbgr.warp_smooth e59eb2c8f7b4df77
    \\bgr24-xbgr.warp_upscale 8c92c5234e2cc9a5
    \\bgr24-xbgr.warp_upscale_repl aae9ba06e83e31a9
    \\bgr24-xbgr.warp_correlate e59fdc668eeb0e36
    \\bgr24-xbgr.warp_correlate2 03a4c922b6c9ad6c
    \\a8k8-k8a8.warp_nearest cd4598f32125fca1
    \\a8k8-k8a8.warp_smooth e557ac87260e0928
    \\a8k8-k8a8.warp_upscale c1260e3ba5e092c5
    \\a8k8-k8a8.warp_upscale_repl 33d0e6cccd85c788
    \\a8k8-k8a8.warp_correlate 67be57b14b4e8d98
    \\a8k8-k8a8.warp_correlate2 6cde5c0eaaf3665f
;
