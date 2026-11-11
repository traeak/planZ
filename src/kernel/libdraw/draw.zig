//! draw.h: the types and constants of libdraw that the kernel side uses.
//! From /sys/include/draw.h.
//!
//! Convention for all three "header" files (libdraw/draw.zig,
//! libmemdraw/memdraw.zig, libmemlayer/memlayer.zig): a header holds
//! types, constants, the C header's macros and its extern variables.
//! It does NOT re-export functions.  A function lives in the Zig file
//! named after the C file that implements it, and consumers import that
//! file: `rectclip` is in libdraw/rectclip.zig, `Pt`, `Rect`, `addpt`
//! ... in libdraw/arith.zig, `memimagedraw` in libmemdraw/draw.zig.
//! The end of this file lists the libdraw functions and where they are.
//!
//! Type rules used throughout libdraw, libmemdraw and libmemlayer:
//!   int -> i32, ulong -> u32, uchar -> u8, Rune -> lib.Rune;
//!   an int that only ever holds a truth value (predicates such as
//!   rectclip, eqpt, ptinrect; fields such as Memlayer.clear and
//!   Memdata.allocd) is bool;
//!   a (pointer, count) pair of bytes is a slice;
//!   a pointer the C may pass or store as nil is optional;
//!   functions that fail by returning nil return an optional, functions
//!   that fail by returning -1 return i32 as in C.
//!
//! DIFF:
//!   - Only the declarations the kernel links are here: Display, Image,
//!     Screen, Font, Subfont and the Cache* structures, the font cache
//!     constants, NOREFRESH, the BG*/BP* macros taking a Display and
//!     all client-side prototypes are left out.
//!   - The enums are plain constants.  Small ones (Drawop, Refresh
//!     methods, line ends, channel types) are untyped so they fit i32
//!     and usize uses alike; colours, channel descriptors are u32.
//!   - ZP and ZR are constants here; the C defines them in arith.c.
//!   - Point and Rectangle print themselves for %P and %R (fmt.c's Pfmt
//!     and Rfmt) through fmt9, so libdraw/fmt.zig does not exist.
//!   - Dx and Dy subtract with wrapping, as C does on its compilers:
//!     they are applied to rectangles that come straight from user
//!     programs.
//!   - Dx and Dy are functions.  BGSHORT and friends take slices or
//!     many-pointers.

const std = @import("std");
const fmt = @import("fmt");

pub const Rune = u21;

pub const DOpaque: u32 = 0xFFFFFFFF;
pub const DTransparent: u32 = 0x00000000; // only useful for allocimage, memfillcolor
pub const DBlack: u32 = 0x000000FF;
pub const DWhite: u32 = 0xFFFFFFFF;
pub const DRed: u32 = 0xFF0000FF;
pub const DGreen: u32 = 0x00FF00FF;
pub const DBlue: u32 = 0x0000FFFF;
pub const DCyan: u32 = 0x00FFFFFF;
pub const DMagenta: u32 = 0xFF00FFFF;
pub const DYellow: u32 = 0xFFFF00FF;
pub const DPaleyellow: u32 = 0xFFFFAAFF;
pub const DDarkyellow: u32 = 0xEEEE9EFF;
pub const DDarkgreen: u32 = 0x448844FF;
pub const DPalegreen: u32 = 0xAAFFAAFF;
pub const DMedgreen: u32 = 0x88CC88FF;
pub const DDarkblue: u32 = 0x000055FF;
pub const DPalebluegreen: u32 = 0xAAFFFFFF;
pub const DPaleblue: u32 = 0x0000BBFF;
pub const DBluegreen: u32 = 0x008888FF;
pub const DGreygreen: u32 = 0x55AAAAFF;
pub const DPalegreygreen: u32 = 0x9EEEEEFF;
pub const DYellowgreen: u32 = 0x99994CFF;
pub const DMedblue: u32 = 0x000099FF;
pub const DGreyblue: u32 = 0x005DBBFF;
pub const DPalegreyblue: u32 = 0x4993DDFF;
pub const DPurpleblue: u32 = 0x8888CCFF;

pub const DNotacolor: u32 = 0xFFFFFF00;
pub const DNofill: u32 = DNotacolor;

pub const Displaybufsize = 8000;
pub const ICOSSCALE = 1024;
pub const Borderwidth = 4;

// refresh methods
pub const Refbackup = 0;
pub const Refnone = 1;
pub const Refmesg = 2;

// line ends
pub const Endsquare = 0;
pub const Enddisc = 1;
pub const Endarrow = 2;
pub const Endmask = 0x1F;

pub fn ARROW(a: i32, b: i32, c: i32) i32 {
    return Endarrow | (a << 5) | (b << 14) | (c << 23);
}

// Porter-Duff compositing operators (Drawop); an op is carried as i32
pub const Drawop = i32;
pub const Clear = 0;

pub const SinD = 8;
pub const DinS = 4;
pub const SoutD = 2;
pub const DoutS = 1;

pub const S = SinD | SoutD;
pub const SoverD = SinD | SoutD | DoutS;
pub const SatopD = SinD | DoutS;
pub const SxorD = SoutD | DoutS;

pub const D = DinS | DoutS;
pub const DoverS = DinS | DoutS | SoutD;
pub const DatopS = DinS | SoutD;
pub const DxorS = DoutS | SoutD; // == SxorD

pub const Ncomp = 12;

//
// image channel descriptors
//
pub const CRed = 0;
pub const CGreen = 1;
pub const CBlue = 2;
pub const CGrey = 3;
pub const CAlpha = 4;
pub const CMap = 5;
pub const CIgnore = 6;
pub const NChan = 7;

pub fn __DC(typ: u32, nbits: u32) u32 {
    return ((typ & 15) << 4) | (nbits & 15);
}
pub fn CHAN1(a: u32, b: u32) u32 {
    return __DC(a, b);
}
pub fn CHAN2(a: u32, b: u32, c: u32, d: u32) u32 {
    return CHAN1(a, b) << 8 | __DC(c, d);
}
pub fn CHAN3(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32) u32 {
    return CHAN2(a, b, c, d) << 8 | __DC(e, f);
}
pub fn CHAN4(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32, h: u32) u32 {
    return CHAN3(a, b, c, d, e, f) << 8 | __DC(g, h);
}

pub fn NBITS(c: u32) u32 {
    return c & 15;
}
pub fn TYPE(c: u32) u32 {
    return (c >> 4) & 15;
}

pub const GREY1: u32 = CHAN1(CGrey, 1);
pub const GREY2: u32 = CHAN1(CGrey, 2);
pub const GREY4: u32 = CHAN1(CGrey, 4);
pub const GREY8: u32 = CHAN1(CGrey, 8);
pub const CMAP8: u32 = CHAN1(CMap, 8);
pub const RGB15: u32 = CHAN4(CIgnore, 1, CRed, 5, CGreen, 5, CBlue, 5);
pub const RGB16: u32 = CHAN3(CRed, 5, CGreen, 6, CBlue, 5);
pub const RGB24: u32 = CHAN3(CRed, 8, CGreen, 8, CBlue, 8);
pub const RGBA32: u32 = CHAN4(CRed, 8, CGreen, 8, CBlue, 8, CAlpha, 8);
pub const ARGB32: u32 = CHAN4(CAlpha, 8, CRed, 8, CGreen, 8, CBlue, 8); // stupid VGAs
pub const XRGB32: u32 = CHAN4(CIgnore, 8, CRed, 8, CGreen, 8, CBlue, 8);
pub const BGR15: u32 = CHAN4(CIgnore, 1, CBlue, 5, CGreen, 5, CRed, 5); // beloved GBA
pub const BGR24: u32 = CHAN3(CBlue, 8, CGreen, 8, CRed, 8);
pub const ABGR32: u32 = CHAN4(CAlpha, 8, CBlue, 8, CGreen, 8, CRed, 8);
pub const XBGR32: u32 = CHAN4(CIgnore, 8, CBlue, 8, CGreen, 8, CRed, 8);

//
// Warp flags used to enable optimized paths
// based on the encoded affine map's properties.
//
pub const WFintupscale = 1; // integer upscaling

pub const Point = struct {
    x: i32 = 0,
    y: i32 = 0,

    /// %P
    pub fn fmt9(p: Point, f: *fmt.Fmt) void {
        f.print("[%d %d]", .{ p.x, p.y });
    }
};

pub const Rectangle = struct {
    min: Point = .{},
    max: Point = .{},

    /// %R
    pub fn fmt9(r: Rectangle, f: *fmt.Fmt) void {
        f.print("%P %P", .{ r.min, r.max });
    }
};

pub const RGB = struct {
    red: u32,
    green: u32,
    blue: u32,
};

pub const Warp = struct {
    m: [3][3]i32,
    flags: i32, // set by mkwarp(2). do not touch
};

//
// Subfonts
//
// given char c, Subfont *f, Fontchar *i, and Point p, one says
//      i = f->info+c;
//      draw(b, Rect(p.x+i->left, p.y+i->top,
//              p.x+i->left+((i+1)->x-i->x), p.y+i->bottom),
//              color, f->bits, Pt(i->x, i->top));
//      p.x += i->width;
// to draw characters in the specified color (itself an Image) in Image b.
//
pub const Fontchar = struct {
    x: i32 = 0, // left edge of bits
    top: u8 = 0, // first non-zero scan-line
    bottom: u8 = 0, // last non-zero scan-line + 1
    left: i8 = 0, // offset of baseline
    width: u8 = 0, // width of baseline
};

pub fn Dx(r: Rectangle) i32 {
    return r.max.x -% r.min.x;
}
pub fn Dy(r: Rectangle) i32 {
    return r.max.y -% r.min.y;
}

//
// Predefined
//
pub const ZP: Point = .{ .x = 0, .y = 0 };
pub const ZR: Rectangle = .{ .min = ZP, .max = ZP };

pub fn BGSHORT(p: anytype) u16 {
    return @as(u16, p[0]) | (@as(u16, p[1]) << 8);
}
pub fn BGLONG(p: anytype) u32 {
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);
}
pub fn BPSHORT(p: anytype, v: u16) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
}
pub fn BPLONG(p: anytype, v: u32) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
    p[2] = @truncate(v >> 16);
    p[3] = @truncate(v >> 24);
}

//
// Compressed image file parameters and helper routines
//
pub const NMATCH = 3; // shortest match possible
pub const NRUN = NMATCH + 31; // longest match possible
pub const NMEM = 1024; // window size
pub const NDUMP = 128; // maximum length of dump
pub const NCBLOCK = 6000; // size of compressed blocks

// =====================================================================
// Where the functions of draw.h are (only those the kernel links):
//
// arith.zig:
//   pub fn Pt(x: i32, y: i32) Point
//   pub fn Rect(x: i32, y: i32, bx: i32, by: i32) Rectangle
//   pub fn Rpt(min: Point, max: Point) Rectangle
//   pub fn addpt(a: Point, b: Point) Point
//   pub fn subpt(a: Point, b: Point) Point
//   pub fn divpt(a: Point, b: i32) Point
//   pub fn mulpt(a: Point, b: i32) Point
//   pub fn eqpt(p: Point, q: Point) bool
//   pub fn eqrect(r: Rectangle, s: Rectangle) bool
//   pub fn insetrect(r: Rectangle, n: i32) Rectangle
//   pub fn rectaddpt(r: Rectangle, p: Point) Rectangle
//   pub fn rectsubpt(r: Rectangle, p: Point) Rectangle
//   pub fn canonrect(r: Rectangle) Rectangle
//   pub fn rectXrect(r: Rectangle, s: Rectangle) bool
//   pub fn rectinrect(r: Rectangle, s: Rectangle) bool
//   pub fn ptinrect(p: Point, r: Rectangle) bool
//   pub fn combinerect(r1: *Rectangle, r2: Rectangle) void
//   pub const drawld2chan: [4]u32
//   pub fn setalpha(color: u32, alpha: u8) u32
// rectclip.zig:
//   pub fn rectclip(rp: *Rectangle, b: Rectangle) bool
// bytesperline.zig:
//   pub fn wordsperline(r: Rectangle, d: i32) i32
//   pub fn bytesperline(r: Rectangle, d: i32) i32
// chan.zig:
//   pub fn chantostr(buf: []u8, cc: u32) ?[]u8      (the text, in buf)
//   pub fn strtochan(s: []const u8) u32             (0 on error)
//   pub fn chantodepth(c: u32) i32                  (0 on error)
// rgb.zig:
//   pub fn rgb2cmap(cr: i32, cg: i32, cb: i32) i32
//   pub fn cmap2rgb(c: i32) i32
//   pub fn cmap2rgba(c: i32) i32
// drawrepl.zig:
//   pub fn drawreplxy(min: i32, max: i32, x: i32) i32
//   pub fn drawrepl(r: Rectangle, p: Point) Point
// icossin.zig, icossin2.zig:
//   pub fn icossin(deg: i32, cosp: *i32, sinp: *i32) void
//   pub fn icossin2(x: i32, y: i32, cosp: *i32, sinp: *i32) void
// badrect.zig:
//   pub fn badrect(r: Rectangle) bool
// defont.zig:
//   pub var defontdata: [N]u8 align(4)
//   pub fn _unpackinfo(fc: []Fontchar, p: [*]const u8, n: i32) void
//   pub const sizeofdefont: i32
// computil.zig:
//   pub fn _twiddlecompressed(buf: []u8) void
//   pub fn _compblocksize(r: Rectangle, depth: i32) i32
// =====================================================================
