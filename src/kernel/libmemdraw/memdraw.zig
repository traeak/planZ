//! memdraw.h: the types, flags and predefined images of libmemdraw.
//! From /sys/include/memdraw.h.
//!
//! Convention (see libdraw/draw.zig for the whole of it and for the
//! type rules): this file holds types, constants and the header's
//! extern variables.  It does NOT re-export functions; import the file
//! named after the C file that implements one (`memimagedraw` is in
//! libmemdraw/draw.zig, `allocmemimage` in libmemdraw/alloc.zig,
//! `memline` in libmemdraw/line.zig).  The end of this file lists them.
//!
//! DIFF:
//!   - memwhite, memblack, memopaque, memtransparent are defined here
//!     (the C defines them in draw.c) and are undefined until
//!     memimageinit (libmemdraw/draw.zig) has run.  memdefcmap is
//!     defined here and points at cmap.zig's table from the start.
//!   - Memimage.mask is unsigned (the C has int; the values are bit
//!     masks of at most 8 bits).
//!   - Memdata.allocd is bool.
//!   - Memsubfont.name is an optional slice.
//!   - hwdraw: the kernel's screen code supplies hwdraw in C by
//!     defining the symbol, which replaces libmemdraw's hwdraw.c at link
//!     time.  Here libmemdraw/hwdraw.zig keeps `pub var hook`, nil by
//!     default (meaning "not handled", as hwdraw.c answers); screen.zig
//!     sets `hwdraw.hook = &its_hwdraw` when it attaches the screen.
//!   - The image pool: see libmemdraw/alloc.zig and kernel.zig.
//!   - libmemdraw/kernel.zig (not from a C file) is where the library
//!     gets malloc, free and werrstr: port/alloc.zig and up.errstr in
//!     the kernel, a test allocator under `zig test`.  A file that
//!     allocates through it can run its test blocks on the host.

const draw = @import("../libdraw/draw.zig");
const memlayer = @import("../libmemlayer/memlayer.zig");

pub const Point = draw.Point;
pub const Rectangle = draw.Rectangle;
pub const Fontchar = draw.Fontchar;
pub const Warp = draw.Warp;
pub const Rune = draw.Rune;
pub const NChan = draw.NChan;
pub const Memlayer = memlayer.Memlayer;

//
// Memdata is allocated from main pool, but .data from the image pool.
// Memdata is allocated separately to permit patching its pointer after
// compaction when windows share the image data.
// The first word of data is a back pointer to the Memdata, to find
// The word to patch.
//
pub const Memdata = struct {
    base: ?[*]u32 = null, // allocated data pointer
    bdata: [*]u8 = undefined, // pointer to first byte of actual data; word-aligned
    ref: i32 = 0, // number of Memimages using this data
    imref: ?*anyopaque = null,
    allocd: bool = false, // is this malloc'd?
};

pub const Frepl: u32 = 1 << 0; // is replicated
pub const Fsimple: u32 = 1 << 1; // is 1x1
pub const Fgrey: u32 = 1 << 2; // is grey
pub const Falpha: u32 = 1 << 3; // has explicit alpha
pub const Fcmap: u32 = 1 << 4; // has cmap channel
pub const Fbytes: u32 = 1 << 5; // has only 8-bit channels

pub const Memimage = struct {
    r: Rectangle, // rectangle in data area, local coords
    clipr: Rectangle, // clipping region
    depth: i32, // number of bits of storage per pixel
    nchan: i32, // number of channels
    chan: u32, // channel descriptions
    cmap: *Memcmap,

    data: *Memdata, // pointer to data; shared by windows in this image
    zero: i32, // data->bdata+zero==&byte containing (0,0)
    width: u32, // width in words of a single scan line
    layer: ?*Memlayer, // nil if not a layer
    flags: u32,

    shift: [NChan]i32,
    mask: [NChan]u32,
    nbits: [NChan]i32,
};

pub const Memcmap = struct {
    cmap2rgb: [3 * 256]u8,
    rgb2cmap: [16 * 16 * 16]u8,
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
// to draw characters in the specified color (itself a Memimage) in Memimage b.
//
pub const Memsubfont = struct {
    name: ?[]u8,
    n: i16, // number of chars in font
    height: u8, // height of bitmap
    ascent: i8, // top of bitmap to baseline
    min: Rune, // rune offset for first glyph in subfont
    info: [*]Fontchar, // n+1 character descriptors
    bits: *Memimage, // of font
};

//
// Encapsulated parameters and information for sub-draw routines.
//
pub const Simplesrc: u32 = 1 << 0;
pub const Simplemask: u32 = 1 << 1;
pub const Replsrc: u32 = 1 << 2;
pub const Replmask: u32 = 1 << 3;
pub const Fullmask: u32 = 1 << 4;

pub const Memdrawparam = struct {
    dst: *Memimage,
    r: Rectangle,
    src: ?*Memimage,
    sr: Rectangle,
    mask: ?*Memimage,
    mr: Rectangle,
    op: i32,

    state: u32,
    mval: u32, // if Simplemask, the mask pixel in mask format
    mrgba: u32, // mval in rgba
    sval: u32, // if Simplesrc, the source pixel in src format
    srgba: u32, // sval in rgba
    sdval: u32, // sval in dst format
};

//
// Predefined
//
pub var memwhite: *Memimage = undefined;
pub var memblack: *Memimage = undefined;
pub var memopaque: *Memimage = undefined;
pub var memtransparent: *Memimage = undefined;
pub var memdefcmap: *Memcmap = &@import("cmap.zig").def;

// =====================================================================
// Where the functions of memdraw.h are.
//
// alloc.zig:
//   pub fn memimagemove(from: *anyopaque, to: *anyopaque) void
//   pub fn allocmemimaged(r: Rectangle, chan: u32, md: *Memdata) ?*Memimage
//   pub fn allocmemimage(r: Rectangle, chan: u32) ?*Memimage
//   pub fn freememimage(i: ?*Memimage) void
//   pub fn wordaddr(i: *Memimage, p: Point) [*]u32
//   pub fn byteaddr(i: *Memimage, p: Point) [*]u8
//   pub fn memsetchan(i: *Memimage, chan: u32) i32          (-1: bad chan)
// draw.zig:
//   pub fn memimageinit() void
//   pub fn memimagedraw(dst: *Memimage, r: Rectangle, src: *Memimage, p0: Point,
//       mask: ?*Memimage, p1: Point, op: i32) void
//   pub fn _drawclipnorepl(dr: *const Rectangle, dclipr: *const Rectangle, r: *Rectangle,
//       src: *Memimage, p0: *Point, mask: *Memimage, p1: *Point,
//       sr: *Rectangle, mr: *Rectangle) bool
//   pub fn drawclipnorepl(dst: *Memimage, r: *Rectangle, src: *Memimage, p0: *Point,
//       mask: *Memimage, p1: *Point, sr: *Rectangle, mr: *Rectangle) bool
//   pub fn drawclip(dst: *Memimage, r: *Rectangle, src: *Memimage, p0: *Point,
//       mask: *Memimage, p1: *Point, sr: *Rectangle, mr: *Rectangle) bool
//   pub fn memfillcolor(i: *Memimage, val: u32) void
//   pub fn pixelbits(i: *Memimage, pt: Point) u32
//   pub fn imgtorgba(img: *Memimage, val: u32) u32
//   pub fn rgbatoimg(img: *Memimage, rgba: u32) u32
// hwdraw.zig:
//   pub var hook: ?*const fn (par: *Memdrawparam) i32
//   pub fn hwdraw(par: *Memdrawparam) i32
// load.zig, cload.zig, unload.zig:
//   pub fn loadmemimage(i: *Memimage, r: Rectangle, data: []const u8) i32
//   pub fn cloadmemimage(i: *Memimage, r: Rectangle, data: []const u8) i32
//   pub fn unloadmemimage(i: *Memimage, r: Rectangle, data: []u8) i32
//       bytes consumed or produced, -1 on error.
// cmap.zig:
//   pub var def: Memcmap                 (what memdefcmap points at)
// subfont.zig:
//   pub fn allocmemsubfont(name: ?[]const u8, n: i32, height: i32, ascent: i32,
//       info: [*]Fontchar, i: *Memimage) ?*Memsubfont
//   pub fn freememsubfont(f: ?*Memsubfont) void
// defont.zig:
//   pub fn getmemdefont() ?*Memsubfont
//
// Task 2's files (signatures follow the same rules):
//   line.zig: memimageline, _memimageline, memlinebbox, memlineendsize.
//   ellipse.zig: memellipse.  arc.zig: memarc.  poly.zig: mempoly.
//   fillpoly.zig: memfillpoly, _memfillpolysc.
//   string.zig: memimagestring, memsubfontwidth.
//   warp.zig: memaffinewarp, memlaffinewarp, ...
//   memdraw and memline, the layer-aware ones, are in libmemlayer
//   (draw.zig and line.zig there).
// =====================================================================
