//! memimagedraw: the compositing engine of libmemdraw.
//! From /sys/src/libmemdraw/draw.c.
//!
//! DIFF:
//!   - memwhite, memblack, memopaque and memtransparent are variables
//!     of memdraw.zig; memimageinit sets them.
//!   - memimageinit returns nothing and panics if it cannot allocate
//!     its two one-pixel images (the C returns -1, which the kernel
//!     never checks).  The C sets `imagmem->move =
//!     memimagemove` here, which lets the image pool compact itself
//!     when it has reached its maximum size; that is left out (see
//!     alloc.zig), so the pool never moves a block.  The fmtinstall
//!     calls are gone: %R and %P are fmt9 methods in libdraw/draw.zig
//!     and %b is not used by the library.
//!   - hwdraw is hwdraw.zig's, which calls the screen's hook.
//!   - Buffer: the three mask fields m, bm, em and their skip counts,
//!     which nothing in the C uses, are left out.  A pointer the C
//!     leaves nil holds `nilp`, an address that is never dereferenced.
//!     `delta` is unsigned.  rgba is a pointer to unaligned words: the
//!     C relies on the machine tolerating that.
//!   - The Calcfn's `grey` argument is bool.
//!   - Dbuf.inuse is taken with an atomic exchange where the C calls
//!     _tas.
//!   - pixelbits, imgtorgba and rgbatoimg are public (static in C);
//!     the tests of other files use them.
//!   - assert() panics with a fixed message.
//!   - alphadraw: when the scratch buffer cannot be allocated the C
//!     leaves the old size beside a nil pointer, so the next draw that
//!     fits the old size would use nil.  Here the size is reset to 0.
//!   - As the C does, readbyte and writebyte handle a pixel of fewer
//!     than 4 bytes through a 4-byte word, so they touch up to 3 bytes
//!     past the last pixel of an image.  In the image pool that is
//!     the block's slack or the first bytes of its own tail, written
//!     back as they were; see kernel.zig's host.imagalloc for the
//!     tests.
//!   - A bug of the C fixed on purpose.  In the word-at-a-time branch
//!     of alphacalc2810 and alphacalc3679 (32-bit source and
//!     destination with matching channels) the C advances bdst.alpha
//!     after every pixel even when the destination has no alpha channel
//!     and the pointer is &ones.  From the second pixel on it then
//!     reads the destination alpha from whatever follows `ones` in
//!     memory, so SinD, SoutD, SatopD, DatopS, DoverS and DxorS onto
//!     an XRGB32 image give garbage.  Here the pointer stays on `ones`,
//!     as it does in the byte-at-a-time branch of the same functions.
//!   - A third.  rectclip assumes both rectangles are well formed.
//!     Given a clipr with max < min, or an empty one, that lies inside
//!     the rectangle being clipped, it answers "they overlap" and
//!     returns clipr itself; and devdraw puts whatever rectangle a
//!     program sends ('b', 'c', and for the length of an 's' or 'x')
//!     into the clipr of the destination, the source and the mask.
//!     The C's _drawclipnorepl then returns a rectangle of negative or
//!     zero width, its asserts hold (the three widths agree), and
//!     memimagedraw goes on to memmove a negative count: a program can
//!     crash the kernel with a 'c' and a 'd'.  Here _drawclipnorepl
//!     answers "nothing to draw" when what is left is not a proper
//!     rectangle.
//!   - _drawclipnorepl and drawclip do their arithmetic with wrapping
//!     operators, as the C does in effect: the points come from user
//!     programs, and the sums are meant to wrap (a source point at
//!     2^31-1 in a replicated image is legitimate).
//!   - readcmap and writecmap step through a scan line by the bytes
//!     of a pixel.  The C steps by 1 (no alpha) or 2 (alpha), which is
//!     right for m8, m8a8 and a8m8, the formats they were written
//!     for; but they are used for every format of 8 bits or more with
//!     an 8-bit colour map channel, and a program may allocate, say,
//!     m8a8x8.  Read as a replicated source, the C's pointer steps over
//!     the end of the 3-byte pixels without ever being equal to it,
//!     and goes on reading for the width of the destination.  For the
//!     three intended formats nothing changes.
//!   - A fourth, found by reading.  alphadraw adds up the size of its
//!     scratch buffer in an int: 4 bytes for each pixel of the width,
//!     times up to 16 cached lines each for a small replicated source
//!     and mask.  For a destination 2^24 pixels wide (a 1-bit image of
//!     that width and 17 lines is 34MB, which devdraw will allocate)
//!     the sum passes 2^31.  The C then sees a negative size, keeps
//!     the smaller buffer it has, or none, and writes the scan lines
//!     through it.  Here the sum saturates and a saturated sum is
//!     treated like the allocation failing: nothing is drawn.
//!   - Seen and left as in C: memoptdraw's third case (1-bit source,
//!     mask and destination, byte-aligned with each other) never looks
//!     at the operator and always computes SoverD.  arc.c relies on
//!     that path being taken for its S draw onto a cleared image, where
//!     the two agree.  The tests pin this down.
//!   - A second bug fixed.  pixelbits finds the pixel within its byte with
//!     `pt.x%npack`, which is negative for a negative x that is not a
//!     multiple of the pixels per byte; the shift then runs past the
//!     byte and the pixel reads as 0.  A 1x1 replicated mask or source
//!     of depth 1, 2 or 4 whose rectangle is at such an x is read
//!     through pixelbits, so it acted as all zeros.  Here the offset is
//!     `pt.x & (npack-1)`, the same for x >= 0.

const std = @import("std");
const draw = @import("../libdraw/draw.zig");
const memdraw = @import("memdraw.zig");
const kernel = @import("kernel.zig");
const arith = @import("../libdraw/arith.zig");
const alloc = @import("alloc.zig");
const cmap = @import("cmap.zig");
const hwdraw = @import("hwdraw.zig").hwdraw;
const rectclip = @import("../libdraw/rectclip.zig").rectclip;
const badrect = @import("../libdraw/badrect.zig").badrect;
const drawrepl = @import("../libdraw/drawrepl.zig").drawrepl;

const Point = draw.Point;
const Rectangle = draw.Rectangle;
const Memimage = memdraw.Memimage;
const Memdrawparam = memdraw.Memdrawparam;
const Dx = draw.Dx;
const Dy = draw.Dy;
const Pt = arith.Pt;
const Rect = arith.Rect;
const rectXrect = arith.rectXrect;
const ptinrect = arith.ptinrect;
const byteaddr = alloc.byteaddr;
const wordaddr = alloc.wordaddr;
const allocmemimage = alloc.allocmemimage;

const Frepl = memdraw.Frepl;
const Fsimple = memdraw.Fsimple;
const Fgrey = memdraw.Fgrey;
const Falpha = memdraw.Falpha;
const Fbytes = memdraw.Fbytes;
const Simplesrc = memdraw.Simplesrc;
const Simplemask = memdraw.Simplemask;
const Replsrc = memdraw.Replsrc;
const Replmask = memdraw.Replmask;
const Fullmask = memdraw.Fullmask;

const CRed = draw.CRed;
const CGreen = draw.CGreen;
const CBlue = draw.CBlue;
const CGrey = draw.CGrey;
const CAlpha = draw.CAlpha;
const CMap = draw.CMap;
const Ncomp = draw.Ncomp;

fn assert(ok: bool) void {
    if (!ok) @panic("memdraw: assertion failed");
}

/// What the C leaves nil in a Buffer.  Never dereferenced.
const nilp: [*]u8 = @ptrFromInt(1);

fn p16(p: [*]u8) [*]align(1) u16 {
    return @ptrCast(p);
}

fn p32(p: [*]u8) [*]align(1) u32 {
    return @ptrCast(p);
}

/// p + off for a signed off.
fn padd(p: [*]u8, off: isize) [*]u8 {
    return @ptrFromInt(@intFromPtr(p) +% @as(usize, @bitCast(off)));
}

// perfect approximation to NTSC = .299r+.587g+.114b when 0 <= r,g,b < 256
fn RGB2K(r: u32, g: u32, b: u32) u32 {
    return (156763 * r + 307758 * g + 59769 * b) >> 19;
}

//
// For 16-bit values, x / 255 == (t = x+1, (t+(t>>8)) >> 8).
// We add another 127 to round to the nearest value rather
// than truncate.
//
// CALCxy does x bytewise calculations on y input images (x=1,4; y=1,2).
// CALC2x does two parallel 16-bit calculations on y input images (y=1,2).
//
inline fn CALC11(a: u32, v: u32) u32 {
    const tmp = a *% v +% 128;
    return (tmp +% (tmp >> 8)) >> 8;
}

inline fn CALC12(a1: u32, v1: u32, a2: u32, v2: u32) u32 {
    const tmp = a1 *% v1 +% a2 *% v2 +% 128;
    return (tmp +% (tmp >> 8)) >> 8;
}

const MASK = 0xFF00FF;

inline fn CALC21(a: u32, vvuu: u32) u32 {
    const tmp = a *% vvuu +% 0x00800080;
    return ((tmp +% ((tmp >> 8) & MASK)) >> 8) & MASK;
}

inline fn CALC41(a: u32, rgba: u32) u32 {
    return CALC21(a, rgba & MASK) |
        (CALC21(a, (rgba >> 8) & MASK) << 8);
}

inline fn CALC22(a1: u32, vvuu1: u32, a2: u32, vvuu2: u32) u32 {
    const tmp = a1 *% vvuu1 +% a2 *% vvuu2 +% 0x00800080;
    return ((tmp +% ((tmp >> 8) & MASK)) >> 8) & MASK;
}

inline fn CALC42(a1: u32, rgba1: u32, a2: u32, rgba2: u32) u32 {
    return CALC22(a1, rgba1 & MASK, a2, rgba2 & MASK) |
        (CALC22(a1, (rgba1 >> 8) & MASK, a2, (rgba2 >> 8) & MASK) << 8);
}

const Subdraw = fn (*Memdrawparam) i32;

var memones: *Memimage = undefined;
var memzeros: *Memimage = undefined;

var didinit: bool = false;

pub fn memimageinit() void {
    if (didinit)
        return;

    mktables();
    cmap._memmkcmap();

    const ones1 = allocmemimage(Rect(0, 0, 1, 1), draw.GREY1);
    const zeros1 = allocmemimage(Rect(0, 0, 1, 1), draw.GREY1);
    if (ones1 == null or zeros1 == null)
        @panic("memimageinit: no memory");
    memones = ones1.?;
    memzeros = zeros1.?;

    memones.flags |= Frepl;
    memones.clipr = Rect(-0x3FFFFFF, -0x3FFFFFF, 0x3FFFFFF, 0x3FFFFFF);
    byteaddr(memones, draw.ZP)[0] = ~@as(u8, 0);

    memzeros.flags |= Frepl;
    memzeros.clipr = Rect(-0x3FFFFFF, -0x3FFFFFF, 0x3FFFFFF, 0x3FFFFFF);
    byteaddr(memzeros, draw.ZP)[0] = 0;

    memdraw.memwhite = memones;
    memdraw.memblack = memzeros;
    memdraw.memopaque = memones;
    memdraw.memtransparent = memzeros;

    didinit = true;
}

pub fn memimagedraw(dst: *Memimage, r_: Rectangle, src: *Memimage, p0_: Point, mask_: ?*Memimage, p1_: Point, op: i32) void {
    var par: Memdrawparam = undefined;
    var r = r_;
    var p0 = p0_;
    var p1 = p1_;

    const mask = mask_ orelse memdraw.memopaque;

    if (!drawclip(dst, &r, src, &p0, mask, &p1, &par.sr, &par.mr))
        return;

    if (op < 0 or op >= Ncomp)
        return;

    par.op = op;
    par.dst = dst;
    par.r = r;
    par.src = src;
    // par.sr set by drawclip
    par.mask = mask;
    // par.mr set by drawclip

    par.state = 0;
    if (src.flags & Frepl != 0) {
        par.state |= Replsrc;
        if (src.flags & Fsimple != 0) {
            par.sval = pixelbits(src, src.r.min);
            par.state |= Simplesrc;
            par.srgba = imgtorgba(src, par.sval);
            par.sdval = rgbatoimg(dst, par.srgba);
            if ((par.srgba & 0xFF) == 0 and (op & draw.DoutS) != 0)
                return; // no-op successfully handled
        }
    }

    if (mask.flags & Frepl != 0) {
        par.state |= Replmask;
        if (mask.flags & Fsimple != 0) {
            par.mval = pixelbits(mask, mask.r.min);
            if (par.mval == 0 and (op & draw.DoutS) != 0)
                return; // no-op successfully handled
            par.state |= Simplemask;
            if (par.mval == ~@as(u32, 0))
                par.state |= Fullmask;
            par.mrgba = imgtorgba(mask, par.mval);
        }
    }

    //
    // Now that we've clipped the parameters down to be consistent, we
    // simply try sub-drawing routines in order until we find one that was able
    // to handle us.  If the sub-drawing routine returns zero, it means it was
    // unable to satisfy the request, so we do not return.
    //

    //
    // Hardware support.  Each video driver provides this function,
    // which checks to see if there is anything it can help with.
    // There could be an if around this checking to see if dst is in video memory.
    //
    if (hwdraw(&par) != 0)
        return;

    //
    // Optimizations using memmove and memset.
    //
    if (memoptdraw(&par) != 0)
        return;

    //
    // Character drawing.
    // Solid source color being painted through a boolean mask onto a high res image.
    //
    if (chardraw(&par) != 0)
        return;

    //
    // General calculation-laden case that does alpha for each pixel.
    //
    _ = alphadraw(&par);
}

//
// Clip the destination rectangle further based on the properties of the
// source and mask rectangles.  Once the destination rectangle is properly
// clipped, adjust the source and mask rectangles to be the same size.
//
// Return zero if the final rectangle is null.
//
pub fn _drawclipnorepl(dr: *const Rectangle, dclipr: *const Rectangle, r: *Rectangle, src: *Memimage, p0: *Point, mask: *Memimage, p1: *Point, sr: *Rectangle, mr: *Rectangle) bool {
    var delta: Point = undefined;

    if (badrect(r.*))
        return false;
    const splitcoords = (p0.x != p1.x) or (p0.y != p1.y);
    // clip to destination
    const rmin = r.min;
    if (!rectclip(r, dr.*) or !rectclip(r, dclipr.*))
        return false;
    // move mask point
    p1.x +%= r.min.x -% rmin.x;
    p1.y +%= r.min.y -% rmin.y;
    // move source point
    p0.x +%= r.min.x -% rmin.x;
    p0.y +%= r.min.y -% rmin.y;
    // map destination rectangle into source
    sr.min = p0.*;
    sr.max.x = p0.x +% Dx(r.*);
    sr.max.y = p0.y +% Dy(r.*);
    // sr is r in source coordinates; clip to source
    if (src.flags & Frepl == 0 and !rectclip(sr, src.r))
        return false;
    if (!rectclip(sr, src.clipr))
        return false;
    // compute and clip rectangle in mask
    if (splitcoords) {
        // move mask point with source
        p1.x +%= sr.min.x -% p0.x;
        p1.y +%= sr.min.y -% p0.y;
        mr.min = p1.*;
        mr.max.x = p1.x +% Dx(sr.*);
        mr.max.y = p1.y +% Dy(sr.*);
        const omr = mr.*;
        // mr is now rectangle in mask; clip it
        if (mask.flags & Frepl == 0 and !rectclip(mr, mask.r))
            return false;
        if (!rectclip(mr, mask.clipr))
            return false;
        // reflect any clips back to source
        sr.min.x +%= mr.min.x -% omr.min.x;
        sr.min.y +%= mr.min.y -% omr.min.y;
        sr.max.x +%= mr.max.x -% omr.max.x;
        sr.max.y +%= mr.max.y -% omr.max.y;
    } else {
        if (mask.flags & Frepl == 0 and !rectclip(sr, mask.r))
            return false;
        if (!rectclip(sr, mask.clipr))
            return false;
        mr.* = sr.*;
    }
    // move source clipping back to destination
    delta.x = r.min.x -% p0.x;
    delta.y = r.min.y -% p0.y;
    r.min.x = sr.min.x +% delta.x;
    r.min.y = sr.min.y +% delta.y;
    r.max.x = sr.max.x +% delta.x;
    r.max.y = sr.max.y +% delta.y;
    p0.* = sr.min;
    p1.* = mr.min;

    // DIFF: an inverted or empty clipr leaves r inverted or empty, see
    // the header
    if (Dx(r.*) <= 0 or Dy(r.*) <= 0)
        return false;

    assert(Dx(sr.*) == Dx(mr.*) and Dx(mr.*) == Dx(r.*));
    assert(Dy(sr.*) == Dy(mr.*) and Dy(mr.*) == Dy(r.*));
    assert(ptinrect(r.min, dr.*));

    return true;
}

pub fn drawclipnorepl(dst: *Memimage, r: *Rectangle, src: *Memimage, p0: *Point, mask: *Memimage, p1: *Point, sr: *Rectangle, mr: *Rectangle) bool {
    return _drawclipnorepl(&dst.r, &dst.clipr, r, src, p0, mask, p1, sr, mr);
}

//
// like drawclipnorepl() above, but if source or mask is replicated,
// move its clipped rectangle so that its minimum point falls within
// the repl rectangle.
//
// Return zero if the final rectangle is null.
//
pub fn drawclip(dst: *Memimage, r: *Rectangle, src: *Memimage, p0: *Point, mask: *Memimage, p1: *Point, sr: *Rectangle, mr: *Rectangle) bool {
    if (!drawclipnorepl(dst, r, src, p0, mask, p1, sr, mr))
        return false;

    // move source rectangle so sr->min is in src->r
    if (src.flags & Frepl != 0) {
        p0.* = drawrepl(src.r, sr.min);
        sr.max.x +%= p0.x -% sr.min.x;
        sr.max.y +%= p0.y -% sr.min.y;
        sr.min = p0.*;
    }

    // move mask point so it is in mask->r
    p1.* = drawrepl(mask.r, p1.*);
    mr.min = p1.*;
    mr.max.x = p1.x +% Dx(sr.*);
    mr.max.y = p1.y +% Dy(sr.*);

    assert(ptinrect(p0.*, src.r));
    assert(ptinrect(p1.*, mask.r));

    return true;
}

//
// Conversion tables.
//
var replbit: [1 + 8][256]u8 = undefined; // replbit[x][y] is the replication of the x-bit quantity y to 8-bit depth

//
// bitmap of how to replicate n bits to fill 8, for 1 <= n <= 8.
// the X's are where to put the bottom (ones) bit of the n-bit pattern.
// only the top 8 bits of the result are actually used.
// (the lower 8 bits are needed to get bits in the right place
// when n is not a divisor of 8.)
//
// Should check to see if its easier to just refer to replmul than
// use the precomputed values in replbit.  On PCs it may well
// be; on machines with slow multiply instructions it probably isn't.
//
const replmul = [1 + 8]u32{
    0,
    0b1111111111111111, // a X X X X X X X X X X X X X X X X
    0b0101010101010101, // a _ X _ X _ X _ X _ X _ X _ X _ X
    0b0010010010010010, // a _ _ X _ _ X _ _ X _ _ X _ _ X _
    0b0001000100010001, // a _ _ _ X _ _ _ X _ _ _ X _ _ _ X
    0b0000100001000010, // a _ _ _ _ X _ _ _ _ X _ _ _ _ X _
    0b0000010000010000, // a _ _ _ _ _ X _ _ _ _ _ X _ _ _ _
    0b0000001000000100, // a _ _ _ _ _ _ X _ _ _ _ _ _ X _ _
    0b0000000100000001, // a _ _ _ _ _ _ _ X _ _ _ _ _ _ _ X
};

fn mktables() void {
    // bit replication up to 8 bits
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        var j: u32 = 0;
        while (j <= 8) : (j += 1) { // j <= 8 [sic]
            const small = i & ((@as(u32, 1) << @intCast(j)) - 1);
            replbit[j][i] = @truncate((small * replmul[j]) >> 8);
        }
    }
}

var ones: u8 = 0xff;
const onesp: [*]u8 = @ptrCast(&ones);

//
// General alpha drawing case.  Can handle anything.
//
const Buffer = struct {
    // used by most routines
    red: [*]u8 = nilp,
    grn: [*]u8 = nilp,
    blu: [*]u8 = nilp,
    alpha: [*]u8 = nilp, // is &ones when unused, never nil
    grey: [*]u8 = nilp,
    rgba: [*]align(1) u32 = @ptrCast(nilp),
    delta: usize = 0, // number of bytes to add to pointer to get next pixel to the right
};

const Readfn = fn (*Param, [*]u8, i32) Buffer;
const Writefn = fn (*Param, [*]u8, Buffer) void;
const Calcfn = fn (Buffer, Buffer, Buffer, i32, bool, i32) void;

const MAXBCACHE = 16;

// giant rathole to customize functions with
const Param = struct {
    replcall: ?*const Readfn = null,
    greymaskcall: ?*const Readfn = null,
    convreadcall: ?*const Readfn = null,
    convwritecall: ?*const Writefn = null,

    img: *Memimage = undefined,
    r: Rectangle = .{},
    dx: i32 = 0, // of r
    needbuf: bool = false,
    convgrey: bool = false,
    alphaonly: bool = false,

    bytey0s: [*]u8 = nilp, // byteaddr(Pt(img->r.min.x, img->r.min.y))
    bytermin: [*]u8 = nilp, // byteaddr(Pt(r.min.x, img->r.min.y))
    bytey0e: [*]u8 = nilp, // byteaddr(Pt(img->r.max.x, img->r.min.y))
    bwidth: usize = 0,

    replcache: bool = false, // if set, cache buffers
    bcache: [MAXBCACHE]Buffer = undefined,
    bfilled: u32 = 0,
    bufbase: [*]u8 = nilp,
    bufoff: i32 = 0,
    bufdelta: i32 = 0,

    dir: i32 = 0,

    convbufoff: i32 = 0,
    convbuf: [*]u8 = nilp,
    convdpar: ?*Param = null,
    convdx: i32 = 0,
};

const alphacalc = [Ncomp]*const Calcfn{
    alphacalc0, // Clear
    alphacalc14, // DoutS
    alphacalc2810, // SoutD
    alphacalc3679, // DxorS
    alphacalc14, // DinS
    alphacalc5, // D
    alphacalc3679, // DatopS
    alphacalc3679, // DoverS
    alphacalc2810, // SinD
    alphacalc3679, // SatopD
    alphacalc2810, // S
    alphacalc11, // SoverD
};

const boolcalc = [Ncomp]*const Calcfn{
    alphacalc0, // Clear
    boolcalc14, // DoutS
    boolcalc236789, // SoutD
    boolcalc236789, // DxorS
    boolcalc14, // DinS
    alphacalc5, // D
    boolcalc236789, // DatopS
    boolcalc236789, // DoverS
    boolcalc236789, // SinD
    boolcalc236789, // SatopD
    boolcalc1011, // S
    boolcalc1011, // SoverD
};

//
// Avoid standard Lock, QLock so that can be used in kernel.
//
const Dbuf = struct {
    p: ?[*]u8 = null,
    n: i32 = 0,
    spar: Param = .{},
    mpar: Param = .{},
    dpar: Param = .{},
    inuse: u32 = 0,
};
var dbuf: [10]Dbuf = @splat(.{});

fn allocdbuf() ?*Dbuf {
    for (&dbuf) |*z| {
        if (@atomicLoad(u32, &z.inuse, .monotonic) != 0)
            continue;
        if (@atomicRmw(u32, &z.inuse, .Xchg, 1, .seq_cst) == 0)
            return z;
    }
    return null;
}

fn getparam(p: *Param, img: *Memimage, r: Rectangle, convgrey: bool, needbuf: bool, ndrawbuf: *i32) void {
    // memset(p, 0, sizeof *p), field by field; bcache is only read
    // where bfilled says it was written.
    p.replcall = null;
    p.greymaskcall = null;
    p.convreadcall = null;
    p.convwritecall = null;
    p.alphaonly = false;
    p.replcache = false;
    p.bfilled = 0;
    p.bufbase = nilp;
    p.dir = 0;
    p.convbufoff = 0;
    p.convbuf = nilp;
    p.convdpar = null;
    p.convdx = 0;

    p.img = img;
    p.r = r;
    p.dx = Dx(r);
    p.needbuf = needbuf;
    p.convgrey = convgrey;

    assert(img.r.min.x <= r.min.x and r.min.x < img.r.max.x);

    p.bytey0s = byteaddr(img, Pt(img.r.min.x, img.r.min.y));
    p.bytermin = byteaddr(img, Pt(r.min.x, img.r.min.y));
    p.bytey0e = byteaddr(img, Pt(img.r.max.x, img.r.min.y));
    p.bwidth = @sizeOf(u32) * img.width;

    assert(@intFromPtr(p.bytey0s) <= @intFromPtr(p.bytermin) and @intFromPtr(p.bytermin) <= @intFromPtr(p.bytey0e));

    if (p.r.min.x == p.img.r.min.x)
        assert(p.bytermin == p.bytey0s);

    var nbuf: i32 = 1;
    if ((img.flags & Frepl) != 0 and Dy(img.r) <= MAXBCACHE and Dy(img.r) < Dy(r)) {
        p.replcache = true;
        nbuf = Dy(img.r);
    }
    p.bufdelta = 4 * p.dx;
    p.bufoff = ndrawbuf.*;
    ndrawbuf.* +|= p.bufdelta *| nbuf; // DIFF: saturates, see alphadraw
}

fn clipy(img: *Memimage, y: *i32) void {
    const dy = Dy(img.r);
    if (y.* == dy)
        y.* = 0
    else if (y.* == -1)
        y.* = dy - 1;
    assert(0 <= y.* and y.* < dy);
}

//
// For each scan line, we expand the pixels from source, mask, and destination
// into byte-aligned red, green, blue, alpha, and grey channels.  If buffering is not
// needed and the channels were already byte-aligned (grey8, rgb24, rgba32, rgb32),
// the readers need not copy the data: they can simply return pointers to the data.
// If the destination image is grey and the source is not, it is converted using the NTSC
// formula.
//
// Once we have all the channels, we call either rgbcalc or greycalc, depending on
// whether the destination image is color.  This is allowed to overwrite the dst buffer (perhaps
// the actual data, perhaps a copy) with its result.  It should only overwrite the dst buffer
// with the same format (i.e. red bytes with red bytes, etc.)  A new buffer is returned from
// the calculator, and that buffer is passed to a function to write it to the destination.
// If the buffer is already pointing at the destination, the writing function is a no-op.
//
fn alphadraw(par: *Memdrawparam) i32 {
    var rdsrc: *const Readfn = undefined;
    var rdmask: *const Readfn = undefined;
    var rddst: *const Readfn = undefined;
    var calc: *const Calcfn = undefined;
    var wrdst: *const Writefn = undefined;
    var starty: i32 = undefined;
    var endy: i32 = undefined;

    const r = par.r;
    const dx = Dx(r);
    const dy = Dy(r);

    const z = allocdbuf() orelse return 0;

    const src = par.src.?;
    const mask = par.mask.?;
    const dst = par.dst;
    const sr = par.sr;
    const mr = par.mr;
    const op = par.op;

    const isgrey = dst.flags & Fgrey != 0;

    //
    // Buffering is only necessary when src and dst are the same
    // bitmap and both r and sr intersect each other and begin at
    // the same scanline.  We could even avoid this if it was
    // possible to walk the scanline pixels in the -x direction.
    //
    // The vector u = sr.min - r.min determines the safest
    // direction to follow on each axis.
    //
    const needbuf = (src.data == dst.data and r.min.y == sr.min.y and rectXrect(r, sr));
    const dir: i32 = if (src.data == dst.data and r.min.y > sr.min.y and rectXrect(r, sr)) -1 else 1;

    var ndrawbuf: i32 = 0;
    getparam(&z.spar, src, sr, isgrey, needbuf, &ndrawbuf);
    getparam(&z.dpar, dst, r, isgrey, needbuf, &ndrawbuf);
    getparam(&z.mpar, mask, mr, false, needbuf, &ndrawbuf);
    z.spar.dir = dir;
    z.mpar.dir = dir;
    z.dpar.dir = dir;

    //
    // If the mask is purely boolean, we can convert from src to dst format
    // when we read src, and then just copy it to dst where the mask tells us to.
    // This requires a boolean (1-bit grey) mask and lack of a source alpha channel.
    //
    // The computation is accomplished by assigning the function pointers as follows:
    //      rdsrc - read and convert source into dst format in a buffer
    //      rdmask - convert mask to bytes, set pointer to it
    //      rddst - fill with pointer to real dst data, but do no reads
    //      calc - copy src onto dst when mask says to.
    //      wrdst - do nothing
    // This is slightly sleazy, since things aren't doing exactly what their names say,
    // but it avoids a fair amount of code duplication to make this a case here
    // rather than have a separate booldraw.
    //
    if (src.flags & Falpha == 0 and mask.chan == draw.GREY1 and dst.depth >= 8 and op == draw.SoverD) {
        rdsrc = convfn(dst, &z.dpar, src, &z.spar, &ndrawbuf);
        rddst = readptr;
        rdmask = readfn(mask);
        calc = boolcopyfn(dst, mask);
        wrdst = nullwrite;
    } else {
        // usual alphadraw parameter fetching
        rdsrc = readfn(src);
        rddst = readfn(dst);
        wrdst = writefn(dst);
        calc = alphacalc[@intCast(op)];

        //
        // If there is no alpha channel, we'll ask for a grey channel
        // and pretend it is the alpha.
        //
        if (mask.flags & Falpha != 0) {
            rdmask = readalphafn(mask);
            z.mpar.alphaonly = true;
        } else {
            z.mpar.greymaskcall = readfn(mask);
            z.mpar.convgrey = true;
            rdmask = greymaskread;

            //
            // Should really be above, but then boolcopyfns would have
            // to deal with bit alignment, and I haven't written that.
            //
            // This is a common case for things like ellipse drawing.
            // When there's no alpha involved and the mask is boolean,
            // we can avoid all the division and multiplication.
            //
            if (mask.chan == draw.GREY1 and src.flags & Falpha == 0)
                calc = boolcalc[@intCast(op)]
            else if (op == draw.SoverD and src.flags & Falpha == 0)
                calc = alphacalcS;
        }
    }

    //
    // If the image has a small enough repl rectangle,
    // we can just read each line once and cache them.
    //
    if (z.spar.replcache) {
        z.spar.replcall = rdsrc;
        rdsrc = replread;
    }
    if (z.mpar.replcache) {
        z.mpar.replcall = rdmask;
        rdmask = replread;
    }

    // DIFF: the size of the scratch buffer is summed with saturating
    // arithmetic and a sum that reached the top is an allocation that
    // failed, see the header
    if (ndrawbuf == std.math.maxInt(i32)) {
        @atomicStore(u32, &z.inuse, 0, .release);
        return 0;
    }
    if (z.n < ndrawbuf) {
        kernel.free(z.p);
        z.p = kernel.malloc(@intCast(ndrawbuf));
        if (z.p == null) {
            z.n = 0;
            @atomicStore(u32, &z.inuse, 0, .release);
            return 0;
        }
        z.n = ndrawbuf;
    }
    const drawbuf = z.p.?;

    //
    // Before we were saving only offsets from drawbuf in the parameter
    // structures; now that drawbuf has been grown to accomodate us,
    // we can fill in the pointers.
    //
    z.spar.bufbase = drawbuf + @as(usize, @intCast(z.spar.bufoff));
    z.mpar.bufbase = drawbuf + @as(usize, @intCast(z.mpar.bufoff));
    z.dpar.bufbase = drawbuf + @as(usize, @intCast(z.dpar.bufoff));
    z.spar.convbuf = drawbuf + @as(usize, @intCast(z.spar.convbufoff));

    if (dir == 1) {
        starty = 0;
        endy = dy;
    } else {
        starty = dy - 1;
        endy = -1;
    }

    //
    // srcy, masky, and dsty are offsets from the top of their
    // respective Rectangles.  they need to be contained within
    // the rectangles, so clipy can keep them there without division.
    //
    var srcy = @rem(starty + sr.min.y - src.r.min.y, Dy(src.r));
    var masky = @rem(starty + mr.min.y - mask.r.min.y, Dy(mask.r));
    var dsty = starty + r.min.y - dst.r.min.y;

    assert(0 <= srcy and srcy < Dy(src.r));
    assert(0 <= masky and masky < Dy(mask.r));
    assert(0 <= dsty and dsty < Dy(dst.r));

    var y = starty;
    while (y != endy) : ({
        y += dir;
        srcy += dir;
        masky += dir;
        dsty += dir;
    }) {
        clipy(src, &srcy);
        clipy(dst, &dsty);
        clipy(mask, &masky);

        const bsrc = rdsrc(&z.spar, z.spar.bufbase, srcy);
        const bmask = rdmask(&z.mpar, z.mpar.bufbase, masky);
        const bdst = rddst(&z.dpar, z.dpar.bufbase, dsty);
        calc(bdst, bsrc, bmask, dx, isgrey, op);
        wrdst(&z.dpar, z.dpar.bytermin + @as(usize, @intCast(dsty)) * z.dpar.bwidth, bdst);
    }

    @atomicStore(u32, &z.inuse, 0, .release);
    return 1;
}

fn alphacalc0(bdst: Buffer, b1: Buffer, b2: Buffer, dx: i32, grey: bool, op: i32) void {
    _ = b1;
    _ = b2;
    _ = grey;
    _ = op;
    @memset(@as([*]u8, @ptrCast(bdst.rgba))[0 .. @as(usize, @intCast(dx)) * bdst.delta], 0);
}

//
// Do the channels in the buffers match enough
// that we can do word-at-a-time operations
// on the pixels?
//
fn chanmatch(bdst: *const Buffer, bsrc: *const Buffer) bool {
    //
    // first, r, g, b must be in the same place
    // in the rgba word.
    //
    const drgb = @intFromPtr(bdst.rgba);
    const srgb = @intFromPtr(bsrc.rgba);
    if (@intFromPtr(bdst.red) -% drgb != @intFromPtr(bsrc.red) -% srgb or
        @intFromPtr(bdst.blu) -% drgb != @intFromPtr(bsrc.blu) -% srgb or
        @intFromPtr(bdst.grn) -% drgb != @intFromPtr(bsrc.grn) -% srgb)
        return false;

    //
    // that implies alpha is in the same place,
    // if it is there at all (it might be == &ones).
    // if the destination is &ones, we can scribble
    // over the rgba slot just fine.
    //
    if (bdst.alpha == onesp)
        return true;

    //
    // if the destination is not ones but the src is,
    // then the simultaneous calculation will use
    // bogus bytes from the src's rgba.  no good.
    //
    if (bsrc.alpha == onesp)
        return false;

    //
    // otherwise, alphas are in the same place.
    //
    return true;
}

fn alphacalc14(bdst_: Buffer, bsrc_: Buffer, bmask_: Buffer, dx: i32, grey: bool, op: i32) void {
    var bdst = bdst_;
    var bsrc = bsrc_;
    var bmask = bmask_;

    const sadelta: usize = if (bsrc.alpha == onesp) 0 else bsrc.delta;
    const q = bsrc.delta == 4 and bdst.delta == 4 and chanmatch(&bdst, &bsrc);

    var i: i32 = 0;
    while (i < dx) : (i += 1) {
        const sa: u32 = bsrc.alpha[0];
        const ma: u32 = bmask.alpha[0];
        var fd = CALC11(sa, ma);
        if (op == draw.DoutS)
            fd = 255 - fd;

        if (grey) {
            bdst.grey[0] = @truncate(CALC11(fd, bdst.grey[0]));
            bsrc.grey += bsrc.delta;
            bdst.grey += bdst.delta;
        } else {
            if (q) {
                bdst.rgba[0] = CALC41(fd, bdst.rgba[0]);
                bsrc.rgba += 1;
                bdst.rgba += 1;
                bsrc.alpha += sadelta;
                bmask.alpha += bmask.delta;
                continue;
            }
            bdst.red[0] = @truncate(CALC11(fd, bdst.red[0]));
            bdst.grn[0] = @truncate(CALC11(fd, bdst.grn[0]));
            bdst.blu[0] = @truncate(CALC11(fd, bdst.blu[0]));
            bsrc.red += bsrc.delta;
            bsrc.blu += bsrc.delta;
            bsrc.grn += bsrc.delta;
            bdst.red += bdst.delta;
            bdst.blu += bdst.delta;
            bdst.grn += bdst.delta;
        }
        if (bdst.alpha != onesp) {
            bdst.alpha[0] = @truncate(CALC11(fd, bdst.alpha[0]));
            bdst.alpha += bdst.delta;
        }
        bmask.alpha += bmask.delta;
        bsrc.alpha += sadelta;
    }
}

fn alphacalc2810(bdst_: Buffer, bsrc_: Buffer, bmask_: Buffer, dx: i32, grey: bool, op: i32) void {
    var bdst = bdst_;
    var bsrc = bsrc_;
    var bmask = bmask_;

    const sadelta: usize = if (bsrc.alpha == onesp) 0 else bsrc.delta;
    const q = bsrc.delta == 4 and bdst.delta == 4 and chanmatch(&bdst, &bsrc);

    var i: i32 = 0;
    while (i < dx) : (i += 1) {
        const ma: u32 = bmask.alpha[0];
        var da: u32 = bdst.alpha[0];
        if (op == draw.SoutD)
            da = 255 - da;
        var fs = ma;
        if (op != draw.S)
            fs = CALC11(fs, da);

        if (grey) {
            bdst.grey[0] = @truncate(CALC11(fs, bsrc.grey[0]));
            bsrc.grey += bsrc.delta;
            bdst.grey += bdst.delta;
        } else {
            if (q) {
                bdst.rgba[0] = CALC41(fs, bsrc.rgba[0]);
                bsrc.rgba += 1;
                bdst.rgba += 1;
                bmask.alpha += bmask.delta;
                // DIFF: the C advances bdst.alpha even when it is &ones
                if (bdst.alpha != onesp)
                    bdst.alpha += bdst.delta;
                continue;
            }
            bdst.red[0] = @truncate(CALC11(fs, bsrc.red[0]));
            bdst.grn[0] = @truncate(CALC11(fs, bsrc.grn[0]));
            bdst.blu[0] = @truncate(CALC11(fs, bsrc.blu[0]));
            bsrc.red += bsrc.delta;
            bsrc.blu += bsrc.delta;
            bsrc.grn += bsrc.delta;
            bdst.red += bdst.delta;
            bdst.blu += bdst.delta;
            bdst.grn += bdst.delta;
        }
        if (bdst.alpha != onesp) {
            bdst.alpha[0] = @truncate(CALC11(fs, bsrc.alpha[0]));
            bdst.alpha += bdst.delta;
        }
        bmask.alpha += bmask.delta;
        bsrc.alpha += sadelta;
    }
}

fn alphacalc3679(bdst_: Buffer, bsrc_: Buffer, bmask_: Buffer, dx: i32, grey: bool, op: i32) void {
    var bdst = bdst_;
    var bsrc = bsrc_;
    var bmask = bmask_;
    var fs: u32 = undefined;
    var fd: u32 = undefined;

    const sadelta: usize = if (bsrc.alpha == onesp) 0 else bsrc.delta;
    const q = bsrc.delta == 4 and bdst.delta == 4 and chanmatch(&bdst, &bsrc);

    var i: i32 = 0;
    while (i < dx) : (i += 1) {
        const sa: u32 = bsrc.alpha[0];
        const ma: u32 = bmask.alpha[0];
        const da: u32 = bdst.alpha[0];
        if (op == draw.SatopD)
            fs = CALC11(ma, da)
        else
            fs = CALC11(ma, 255 - da);
        if (op == draw.DoverS)
            fd = 255
        else {
            fd = CALC11(sa, ma);
            if (op != draw.DatopS)
                fd = 255 - fd;
        }

        if (grey) {
            bdst.grey[0] = @truncate(CALC12(fs, bsrc.grey[0], fd, bdst.grey[0]));
            bsrc.grey += bsrc.delta;
            bdst.grey += bdst.delta;
        } else {
            if (q) {
                bdst.rgba[0] = CALC42(fs, bsrc.rgba[0], fd, bdst.rgba[0]);
                bsrc.rgba += 1;
                bdst.rgba += 1;
                bsrc.alpha += sadelta;
                bmask.alpha += bmask.delta;
                // DIFF: the C advances bdst.alpha even when it is &ones
                if (bdst.alpha != onesp)
                    bdst.alpha += bdst.delta;
                continue;
            }
            bdst.red[0] = @truncate(CALC12(fs, bsrc.red[0], fd, bdst.red[0]));
            bdst.grn[0] = @truncate(CALC12(fs, bsrc.grn[0], fd, bdst.grn[0]));
            bdst.blu[0] = @truncate(CALC12(fs, bsrc.blu[0], fd, bdst.blu[0]));
            bsrc.red += bsrc.delta;
            bsrc.blu += bsrc.delta;
            bsrc.grn += bsrc.delta;
            bdst.red += bdst.delta;
            bdst.blu += bdst.delta;
            bdst.grn += bdst.delta;
        }
        if (bdst.alpha != onesp) {
            bdst.alpha[0] = @truncate(CALC12(fs, sa, fd, da));
            bdst.alpha += bdst.delta;
        }
        bmask.alpha += bmask.delta;
        bsrc.alpha += sadelta;
    }
}

fn alphacalc5(bdst: Buffer, b1: Buffer, b2: Buffer, dx: i32, grey: bool, op: i32) void {
    _ = bdst;
    _ = b1;
    _ = b2;
    _ = dx;
    _ = grey;
    _ = op;
}

fn alphacalc11(bdst_: Buffer, bsrc_: Buffer, bmask_: Buffer, dx: i32, grey: bool, op: i32) void {
    var bdst = bdst_;
    var bsrc = bsrc_;
    var bmask = bmask_;

    _ = op;
    const sadelta: usize = if (bsrc.alpha == onesp) 0 else bsrc.delta;
    const q = bsrc.delta == 4 and bdst.delta == 4 and chanmatch(&bdst, &bsrc);

    var i: i32 = 0;
    while (i < dx) : (i += 1) {
        const sa: u32 = bsrc.alpha[0];
        const ma: u32 = bmask.alpha[0];
        const fd = 255 - CALC11(sa, ma);

        if (grey) {
            bdst.grey[0] = @truncate(CALC12(ma, bsrc.grey[0], fd, bdst.grey[0]));
            bsrc.grey += bsrc.delta;
            bdst.grey += bdst.delta;
        } else {
            if (q) {
                bdst.rgba[0] = CALC42(ma, bsrc.rgba[0], fd, bdst.rgba[0]);
                bsrc.rgba += 1;
                bdst.rgba += 1;
                bsrc.alpha += sadelta;
                bmask.alpha += bmask.delta;
                continue;
            }
            bdst.red[0] = @truncate(CALC12(ma, bsrc.red[0], fd, bdst.red[0]));
            bdst.grn[0] = @truncate(CALC12(ma, bsrc.grn[0], fd, bdst.grn[0]));
            bdst.blu[0] = @truncate(CALC12(ma, bsrc.blu[0], fd, bdst.blu[0]));
            bsrc.red += bsrc.delta;
            bsrc.blu += bsrc.delta;
            bsrc.grn += bsrc.delta;
            bdst.red += bdst.delta;
            bdst.blu += bdst.delta;
            bdst.grn += bdst.delta;
        }
        if (bdst.alpha != onesp) {
            bdst.alpha[0] = @truncate(CALC12(ma, sa, fd, bdst.alpha[0]));
            bdst.alpha += bdst.delta;
        }
        bmask.alpha += bmask.delta;
        bsrc.alpha += sadelta;
    }
}

// source and mask alpha 1
fn alphacalcS0(bdst_: Buffer, bsrc_: Buffer, bmask: Buffer, dx: i32, grey: bool, op: i32) void {
    var bdst = bdst_;
    var bsrc = bsrc_;

    _ = bmask;
    _ = op;
    if (bsrc.delta == bdst.delta) {
        const n = @as(usize, @intCast(dx)) * bdst.delta;
        @memmove(@as([*]u8, @ptrCast(bdst.rgba))[0..n], @as([*]u8, @ptrCast(bsrc.rgba))[0..n]);
        return;
    }
    var i: i32 = 0;
    while (i < dx) : (i += 1) {
        if (grey) {
            bdst.grey[0] = bsrc.grey[0];
            bsrc.grey += bsrc.delta;
            bdst.grey += bdst.delta;
        } else {
            bdst.red[0] = bsrc.red[0];
            bdst.grn[0] = bsrc.grn[0];
            bdst.blu[0] = bsrc.blu[0];
            bsrc.red += bsrc.delta;
            bsrc.blu += bsrc.delta;
            bsrc.grn += bsrc.delta;
            bdst.red += bdst.delta;
            bdst.blu += bdst.delta;
            bdst.grn += bdst.delta;
        }
        if (bdst.alpha != onesp) {
            bdst.alpha[0] = 255;
            bdst.alpha += bdst.delta;
        }
    }
}

// source alpha 1
fn alphacalcS(bdst_: Buffer, bsrc_: Buffer, bmask_: Buffer, dx: i32, grey: bool, op: i32) void {
    var bdst = bdst_;
    var bsrc = bsrc_;
    var bmask = bmask_;

    _ = op;
    var i: i32 = 0;
    while (i < dx) : (i += 1) {
        const ma: u32 = bmask.alpha[0];
        const fd = 255 - ma;

        if (grey) {
            bdst.grey[0] = @truncate(CALC12(ma, bsrc.grey[0], fd, bdst.grey[0]));
            bsrc.grey += bsrc.delta;
            bdst.grey += bdst.delta;
        } else {
            bdst.red[0] = @truncate(CALC12(ma, bsrc.red[0], fd, bdst.red[0]));
            bdst.grn[0] = @truncate(CALC12(ma, bsrc.grn[0], fd, bdst.grn[0]));
            bdst.blu[0] = @truncate(CALC12(ma, bsrc.blu[0], fd, bdst.blu[0]));
            bsrc.red += bsrc.delta;
            bsrc.blu += bsrc.delta;
            bsrc.grn += bsrc.delta;
            bdst.red += bdst.delta;
            bdst.blu += bdst.delta;
            bdst.grn += bdst.delta;
        }
        if (bdst.alpha != onesp) {
            bdst.alpha[0] = @truncate(ma + CALC11(fd, bdst.alpha[0]));
            bdst.alpha += bdst.delta;
        }
        bmask.alpha += bmask.delta;
    }
}

fn boolcalc14(bdst_: Buffer, b1: Buffer, bmask_: Buffer, dx: i32, grey: bool, op: i32) void {
    var bdst = bdst_;
    var bmask = bmask_;

    _ = b1;

    var i: i32 = 0;
    while (i < dx) : (i += 1) {
        const ma: u32 = bmask.alpha[0];
        const zero = if (ma != 0) op == draw.DoutS else op == draw.DinS;

        if (grey) {
            if (zero)
                bdst.grey[0] = 0;
            bdst.grey += bdst.delta;
        } else {
            if (zero) {
                bdst.blu[0] = 0;
                bdst.grn[0] = 0;
                bdst.red[0] = 0;
            }
            bdst.red += bdst.delta;
            bdst.blu += bdst.delta;
            bdst.grn += bdst.delta;
        }
        bmask.alpha += bmask.delta;
        if (bdst.alpha != onesp) {
            if (zero)
                bdst.alpha[0] = 0;
            bdst.alpha += bdst.delta;
        }
    }
}

fn boolcalc236789(bdst_: Buffer, bsrc_: Buffer, bmask_: Buffer, dx: i32, grey: bool, op: i32) void {
    var bdst = bdst_;
    var bsrc = bsrc_;
    var bmask = bmask_;

    const zero = (op & 1) == 0;

    var i: i32 = 0;
    while (i < dx) : (i += 1) {
        const ma: u32 = bmask.alpha[0];
        const da: u32 = bdst.alpha[0];
        var fs = da;
        if (op & 2 != 0)
            fs = 255 - da;
        var fd: u32 = 0;
        if (op & 4 != 0)
            fd = 255;

        if (grey) {
            if (ma != 0)
                bdst.grey[0] = @truncate(CALC12(fs, bsrc.grey[0], fd, bdst.grey[0]))
            else if (zero)
                bdst.grey[0] = 0;
            bsrc.grey += bsrc.delta;
            bdst.grey += bdst.delta;
        } else {
            if (ma != 0) {
                bdst.red[0] = @truncate(CALC12(fs, bsrc.red[0], fd, bdst.red[0]));
                bdst.grn[0] = @truncate(CALC12(fs, bsrc.grn[0], fd, bdst.grn[0]));
                bdst.blu[0] = @truncate(CALC12(fs, bsrc.blu[0], fd, bdst.blu[0]));
            } else if (zero) {
                bdst.blu[0] = 0;
                bdst.grn[0] = 0;
                bdst.red[0] = 0;
            }
            bsrc.red += bsrc.delta;
            bsrc.blu += bsrc.delta;
            bsrc.grn += bsrc.delta;
            bdst.red += bdst.delta;
            bdst.blu += bdst.delta;
            bdst.grn += bdst.delta;
        }
        bmask.alpha += bmask.delta;
        if (bdst.alpha != onesp) {
            if (ma != 0)
                bdst.alpha[0] = @truncate(fs + CALC11(fd, da))
            else if (zero)
                bdst.alpha[0] = 0;
            bdst.alpha += bdst.delta;
        }
    }
}

fn boolcalc1011(bdst_: Buffer, bsrc_: Buffer, bmask_: Buffer, dx: i32, grey: bool, op: i32) void {
    var bdst = bdst_;
    var bsrc = bsrc_;
    var bmask = bmask_;

    const zero = (op & 1) == 0;

    var i: i32 = 0;
    while (i < dx) : (i += 1) {
        const ma: u32 = bmask.alpha[0];

        if (grey) {
            if (ma != 0)
                bdst.grey[0] = bsrc.grey[0]
            else if (zero)
                bdst.grey[0] = 0;
            bsrc.grey += bsrc.delta;
            bdst.grey += bdst.delta;
        } else {
            if (ma != 0) {
                bdst.red[0] = bsrc.red[0];
                bdst.grn[0] = bsrc.grn[0];
                bdst.blu[0] = bsrc.blu[0];
            } else if (zero) {
                bdst.blu[0] = 0;
                bdst.grn[0] = 0;
                bdst.red[0] = 0;
            }
            bsrc.red += bsrc.delta;
            bsrc.blu += bsrc.delta;
            bsrc.grn += bsrc.delta;
            bdst.red += bdst.delta;
            bdst.blu += bdst.delta;
            bdst.grn += bdst.delta;
        }
        bmask.alpha += bmask.delta;
        if (bdst.alpha != onesp) {
            if (ma != 0)
                bdst.alpha[0] = 255
            else if (zero)
                bdst.alpha[0] = 0;
            bdst.alpha += bdst.delta;
        }
    }
}

//
// Replicated cached scan line read.  Call the function listed in the Param,
// but cache the result so that for replicated images we only do the work once.
//
fn replread(p: *Param, s: [*]u8, y: i32) Buffer {
    _ = s;
    const b = &p.bcache[@intCast(y)];
    const bit = @as(u32, 1) << @intCast(y);
    if ((p.bfilled & bit) == 0) {
        p.bfilled |= bit;
        b.* = p.replcall.?(p, p.bufbase + @as(usize, @intCast(y * p.bufdelta)), y);
    }
    return b.*;
}

//
// Alpha reading function that simply relabels the grey pointer.
//
fn greymaskread(p: *Param, buf: [*]u8, y: i32) Buffer {
    var b = p.greymaskcall.?(p, buf, y);
    b.alpha = b.grey;
    return b;
}

fn readnbit(p: *Param, buf: [*]u8, y: i32) Buffer {
    var b: Buffer = .{};
    var w = buf;

    b.rgba = @ptrCast(buf);
    b.grey = w;
    b.red = w;
    b.blu = w;
    b.grn = w;
    b.alpha = onesp;
    b.delta = 1;

    var dx = p.dx;
    const img = p.img;
    const depth: u32 = @intCast(img.depth);
    const repl: *const [256]u8 = &replbit[depth];
    const npack: i32 = @intCast(8 / depth);
    const sh: u3 = @intCast(8 - depth);
    const yoff = @as(usize, @intCast(y)) * p.bwidth;

    // copy from p->r.min.x until end of repl rectangle
    var x = p.r.min.x;
    var n = dx;
    if (n > p.img.r.max.x - x)
        n = p.img.r.max.x - x;

    var r = p.bytermin + yoff;
    var bits: u8 = r[0];
    r += 1;
    var nbits: u32 = 8;
    var i: i32 = x & (npack - 1);
    if (i != 0) {
        bits = @truncate(@as(u32, bits) << @intCast(depth * @as(u32, @intCast(i))));
        nbits -= depth * @as(u32, @intCast(i));
    }
    i = 0;
    while (i < n) : (i += 1) {
        if (nbits == 0) {
            bits = r[0];
            r += 1;
            nbits = 8;
        }
        w[0] = repl[bits >> sh];
        w += 1;
        bits = @truncate(@as(u32, bits) << @intCast(depth));
        nbits -= depth;
    }
    dx -= n;
    if (dx == 0)
        return b;

    assert(x + i == p.img.r.max.x);

    // copy from beginning of repl rectangle until where we were before.
    x = p.img.r.min.x;
    n = dx;
    if (n > p.r.min.x - x)
        n = p.r.min.x - x;

    r = p.bytey0s + yoff;
    bits = r[0];
    r += 1;
    nbits = 8;
    i = x & (npack - 1);
    if (i != 0) {
        bits = @truncate(@as(u32, bits) << @intCast(depth * @as(u32, @intCast(i))));
        nbits -= depth * @as(u32, @intCast(i));
    }
    i = 0;
    while (i < n) : (i += 1) {
        if (nbits == 0) {
            bits = r[0];
            r += 1;
            nbits = 8;
        }
        w[0] = repl[bits >> sh];
        w += 1;
        bits = @truncate(@as(u32, bits) << @intCast(depth));
        nbits -= depth;
    }
    dx -= n;
    if (dx > 0) {
        // now we have exactly one full scan line: just replicate the buffer itself until we are done
        var ow = buf;
        while (dx != 0) : (dx -= 1) {
            w[0] = ow[0];
            w += 1;
            ow += 1;
        }
    }
    return b;
}

fn writenbit(p: *Param, w_: [*]u8, src: Buffer) void {
    var w = w_;

    assert(src.grey != nilp and src.delta == 1);

    var x = p.r.min.x;
    const ex = x + p.dx;
    const depth: u32 = @intCast(p.img.depth);
    const npack: i32 = @intCast(8 / depth);

    const i: u32 = @intCast(x & (npack - 1));
    var bits: u32 = if (i != 0) (@as(u32, w[0]) >> @intCast(8 - depth * i)) else 0;
    var nbits: u32 = depth * i;
    var sh: u32 = 8 - depth;
    var r = src.grey;

    while (x < ex) : (x += 1) {
        bits <<= @intCast(depth);
        bits |= (@as(u32, r[0]) >> @intCast(sh));
        r += 1;
        nbits += depth;
        if (nbits == 8) {
            w[0] = @truncate(bits);
            w += 1;
            nbits = 0;
        }
    }

    if (nbits != 0) {
        sh = 8 - nbits;
        bits <<= @intCast(sh);
        bits |= @as(u32, w[0]) & ((@as(u32, 1) << @intCast(sh)) - 1);
        w[0] = @truncate(bits);
    }
    return;
}

fn readcmap(p: *Param, buf_: [*]u8, y: i32) Buffer {
    var b: Buffer = .{};
    var buf = buf_;
    const yoff = @as(usize, @intCast(y)) * p.bwidth;

    const begin = p.bytey0s + yoff;
    var r = p.bytermin + yoff;
    const end = p.bytey0e + yoff;
    const cmap2rgb: [*]const u8 = &p.img.cmap.cmap2rgb;
    const convgrey = p.convgrey;
    const copyalpha: usize = @intFromBool((p.img.flags & Falpha) != 0);

    var w = buf;
    const dx = p.dx;
    var i: i32 = 0;
    // DIFF: the bytes of a pixel, where the C has 2 and 1; see the header
    const step: usize = @intCast(@divTrunc(p.img.depth, 8));
    const m: usize = @intCast(@divTrunc(p.img.shift[CMap], 8));
    if (copyalpha != 0) {
        b.alpha = buf;
        buf += 1;
        const a: usize = @intCast(@divTrunc(p.img.shift[CAlpha], 8));
        while (i < dx) : (i += 1) {
            w[0] = r[a];
            w += 1;
            const q = cmap2rgb + @as(usize, r[m]) * 3;
            r += step;
            if (r == end)
                r = begin;
            if (convgrey) {
                w[0] = @truncate(RGB2K(q[0], q[1], q[2]));
                w += 1;
            } else {
                w[0] = q[2]; // blue
                w[1] = q[1]; // green
                w[2] = q[0]; // red
                w += 3;
            }
        }
    } else {
        b.alpha = onesp;
        while (i < dx) : (i += 1) {
            const q = cmap2rgb + @as(usize, r[m]) * 3;
            r += step;
            if (r == end)
                r = begin;
            if (convgrey) {
                w[0] = @truncate(RGB2K(q[0], q[1], q[2]));
                w += 1;
            } else {
                w[0] = q[2]; // blue
                w[1] = q[1]; // green
                w[2] = q[0]; // red
                w += 3;
            }
        }
    }

    b.rgba = @ptrCast(buf - copyalpha);

    if (convgrey) {
        b.grey = buf;
        b.red = buf;
        b.blu = buf;
        b.grn = buf;
        b.delta = 1 + copyalpha;
    } else {
        b.blu = buf;
        b.grn = buf + 1;
        b.red = buf + 2;
        b.grey = nilp;
        b.delta = 3 + copyalpha;
    }
    return b;
}

fn writecmap(p: *Param, w_: [*]u8, src: Buffer) void {
    var w = w_;
    const rgb2cmap: [*]const u8 = &p.img.cmap.rgb2cmap;

    const delta = src.delta;
    var red = src.red;
    var grn = src.grn;
    var blu = src.blu;

    const dx = p.dx;
    var i: i32 = 0;
    // DIFF: as in readcmap
    const step: usize = @intCast(@divTrunc(p.img.depth, 8));
    const m: usize = @intCast(@divTrunc(p.img.shift[CMap], 8));
    if (p.img.flags & Falpha != 0) {
        var alpha = src.alpha;
        const a: usize = @intCast(@divTrunc(p.img.shift[CAlpha], 8));
        while (i < dx) : ({
            i += 1;
            red += delta;
            grn += delta;
            blu += delta;
            w += step;
        }) {
            w[a] = alpha[0];
            if (alpha != onesp)
                alpha += delta;
            w[m] = rgb2cmap[@as(usize, red[0] >> 4) * 256 + @as(usize, grn[0] >> 4) * 16 + (blu[0] >> 4)];
        }
    } else {
        while (i < dx) : ({
            i += 1;
            red += delta;
            grn += delta;
            blu += delta;
        }) {
            w[m] = rgb2cmap[@as(usize, red[0] >> 4) * 256 + @as(usize, grn[0] >> 4) * 16 + (blu[0] >> 4)];
            w += step;
        }
    }
}

fn readbyte(p: *Param, buf: [*]u8, y: i32) Buffer {
    var b: Buffer = .{};
    const yoff = @as(usize, @intCast(y)) * p.bwidth;

    const img = p.img;
    const begin = p.bytey0s + yoff;
    var r = p.bytermin + yoff;
    const end = p.bytey0e + yoff;

    var w = buf;
    const dx = p.dx;
    const nb: usize = @intCast(@divTrunc(img.depth, 8));

    const convgrey = p.convgrey; // convert rgb to grey
    const isgrey = img.flags & Fgrey != 0;
    const alphaonly = p.alphaonly;
    const copyalpha: usize = @intFromBool((img.flags & Falpha) != 0);

    // if we can, avoid processing everything
    if (img.flags & Frepl == 0 and !convgrey and (img.flags & Fbytes) != 0) {
        if (p.needbuf) {
            const n = @as(usize, @intCast(dx)) * nb;
            @memmove(buf[0..n], r[0..n]);
            r = buf;
        }
        b.rgba = @ptrCast(r);
        if (copyalpha != 0)
            b.alpha = r + @as(usize, @intCast(@divTrunc(img.shift[CAlpha], 8)))
        else
            b.alpha = onesp;
        if (isgrey) {
            b.grey = r + @as(usize, @intCast(@divTrunc(img.shift[CGrey], 8)));
            b.red = b.grey;
            b.grn = b.grey;
            b.blu = b.grey;
        } else {
            b.red = r + @as(usize, @intCast(@divTrunc(img.shift[CRed], 8)));
            b.grn = r + @as(usize, @intCast(@divTrunc(img.shift[CGreen], 8)));
            b.blu = r + @as(usize, @intCast(@divTrunc(img.shift[CBlue], 8)));
        }
        b.delta = nb;
        return b;
    }

    const rrepl: *const [256]u8 = &replbit[@intCast(img.nbits[CRed])];
    const grepl: *const [256]u8 = &replbit[@intCast(img.nbits[CGreen])];
    const brepl: *const [256]u8 = &replbit[@intCast(img.nbits[CBlue])];
    const arepl: *const [256]u8 = &replbit[@intCast(img.nbits[CAlpha])];
    const krepl: *const [256]u8 = &replbit[@intCast(img.nbits[CGrey])];

    var i: i32 = 0;
    while (i < dx) : (i += 1) {
        const u: u32 = @as(u32, r[0]) | (@as(u32, r[1]) << 8) | (@as(u32, r[2]) << 16) | (@as(u32, r[3]) << 24);
        if (copyalpha != 0) {
            w[0] = arepl[(u >> @intCast(img.shift[CAlpha])) & img.mask[CAlpha]];
            w += 1;
        }

        if (isgrey) {
            w[0] = krepl[(u >> @intCast(img.shift[CGrey])) & img.mask[CGrey]];
            w += 1;
        } else if (!alphaonly) {
            const ured = rrepl[(u >> @intCast(img.shift[CRed])) & img.mask[CRed]];
            const ugrn = grepl[(u >> @intCast(img.shift[CGreen])) & img.mask[CGreen]];
            const ublu = brepl[(u >> @intCast(img.shift[CBlue])) & img.mask[CBlue]];
            if (convgrey) {
                w[0] = @truncate(RGB2K(ured, ugrn, ublu));
                w += 1;
            } else {
                w[0] = ublu;
                w[1] = ugrn;
                w[2] = ured;
                w += 3;
            }
        }
        r += nb;
        if (r == end)
            r = begin;
    }

    b.alpha = if (copyalpha != 0) buf else onesp;
    b.rgba = @ptrCast(buf);
    if (alphaonly) {
        b.red = nilp;
        b.grn = nilp;
        b.blu = nilp;
        b.grey = nilp;
        if (copyalpha == 0)
            b.rgba = @ptrCast(nilp);
        b.delta = 1;
    } else if (isgrey or convgrey) {
        b.grey = buf + copyalpha;
        b.red = buf + copyalpha;
        b.grn = buf + copyalpha;
        b.blu = buf + copyalpha;
        b.delta = copyalpha + 1;
    } else {
        b.blu = buf + copyalpha;
        b.grn = buf + copyalpha + 1;
        b.grey = nilp;
        b.red = buf + copyalpha + 2;
        b.delta = copyalpha + 3;
    }
    return b;
}

fn writebyte(p: *Param, w_: [*]u8, src: Buffer) void {
    var w = w_;
    const img = p.img;

    var red = src.red;
    var grn = src.grn;
    var blu = src.blu;
    var alpha = src.alpha;
    const delta = src.delta;
    var grey = src.grey;
    const dx = p.dx;

    const nb: usize = @intCast(@divTrunc(img.depth, 8));

    const isalpha = img.flags & Falpha != 0;
    const isgrey = img.flags & Fgrey != 0;
    var adelta = src.delta;

    if (isalpha and alpha == onesp)
        adelta = 0;

    var i: i32 = 0;
    if ((img.flags & Fbytes) != 0) {
        const ogry: usize = @intCast(@divTrunc(img.shift[CGrey], 8));
        const ored: usize = @intCast(@divTrunc(img.shift[CRed], 8));
        const ogrn: usize = @intCast(@divTrunc(img.shift[CGreen], 8));
        const oblu: usize = @intCast(@divTrunc(img.shift[CBlue], 8));
        const oalp: usize = @intCast(@divTrunc(img.shift[CAlpha], 8));

        while (i < dx) : (i += 1) {
            if (isgrey) {
                w[ogry] = grey[0];
                grey += delta;
            } else {
                w[ored] = red[0];
                w[ogrn] = grn[0];
                w[oblu] = blu[0];
                red += delta;
                grn += delta;
                blu += delta;
            }
            if (isalpha) {
                w[oalp] = alpha[0];
                alpha += adelta;
            }
            w += nb;
        }
        return;
    }

    const mask: u32 = if (nb == 4) 0 else ~((@as(u32, 1) << @intCast(img.depth)) - 1);
    while (i < dx) : (i += 1) {
        var u: u32 = @as(u32, w[0]) | (@as(u32, w[1]) << 8) | (@as(u32, w[2]) << 16) | (@as(u32, w[3]) << 24);
        u &= mask;
        if (isgrey) {
            u |= ((@as(u32, grey[0]) >> @intCast(8 - img.nbits[CGrey])) & img.mask[CGrey]) << @intCast(img.shift[CGrey]);
            grey += delta;
        } else {
            u |= ((@as(u32, red[0]) >> @intCast(8 - img.nbits[CRed])) & img.mask[CRed]) << @intCast(img.shift[CRed]);
            u |= ((@as(u32, grn[0]) >> @intCast(8 - img.nbits[CGreen])) & img.mask[CGreen]) << @intCast(img.shift[CGreen]);
            u |= ((@as(u32, blu[0]) >> @intCast(8 - img.nbits[CBlue])) & img.mask[CBlue]) << @intCast(img.shift[CBlue]);
            red += delta;
            grn += delta;
            blu += delta;
        }

        if (isalpha) {
            u |= ((@as(u32, alpha[0]) >> @intCast(8 - img.nbits[CAlpha])) & img.mask[CAlpha]) << @intCast(img.shift[CAlpha]);
            alpha += adelta;
        }

        w[0] = @truncate(u);
        w[1] = @truncate(u >> 8);
        w[2] = @truncate(u >> 16);
        w[3] = @truncate(u >> 24);
        w += nb;
    }
}

fn readfn(img: *Memimage) *const Readfn {
    if (img.depth < 8)
        return readnbit;
    if (img.nbits[CMap] == 8)
        return readcmap;
    return readbyte;
}

fn readalphafn(m: *Memimage) *const Readfn {
    _ = m;
    return readbyte;
}

fn writefn(img: *Memimage) *const Writefn {
    if (img.depth < 8)
        return writenbit;
    if (img.nbits[CMap] == 8)
        return writecmap;
    return writebyte;
}

fn nullwrite(p: *Param, s: [*]u8, b: Buffer) void {
    _ = p;
    _ = s;
    _ = b;
}

fn readptr(p: *Param, s: [*]u8, y: i32) Buffer {
    var b: Buffer = .{};

    _ = s;
    const q = p.bytermin + @as(usize, @intCast(y)) * p.bwidth;
    b.red = q; // ptr to data
    b.grn = nilp;
    b.blu = nilp;
    b.grey = nilp;
    b.alpha = onesp;
    b.rgba = @ptrCast(q);
    b.delta = @intCast(@divTrunc(p.img.depth, 8));
    return b;
}

fn boolmemmove(bdst: Buffer, bsrc: Buffer, b1: Buffer, dx: i32, i: bool, o: i32) void {
    _ = i;
    _ = o;
    _ = b1;
    const n = @as(usize, @intCast(dx)) * bdst.delta;
    @memmove(bdst.red[0..n], bsrc.red[0..n]);
}

fn boolcopy8(bdst: Buffer, bsrc: Buffer, bmask: Buffer, dx: i32, i: bool, o: i32) void {
    _ = i;
    _ = o;
    var m = bmask.grey;
    var w = bdst.red;
    var r = bsrc.red;
    const ew = w + @as(usize, @intCast(dx));
    while (@intFromPtr(w) < @intFromPtr(ew)) : ({
        w += 1;
        r += 1;
    }) {
        if (m[0] != 0)
            w[0] = r[0];
        m += 1;
    }
}

fn boolcopy16(bdst: Buffer, bsrc: Buffer, bmask: Buffer, dx: i32, i: bool, o: i32) void {
    _ = i;
    _ = o;
    var m = bmask.grey;
    var w = p16(bdst.red);
    var r = p16(bsrc.red);
    const ew = w + @as(usize, @intCast(dx));
    while (@intFromPtr(w) < @intFromPtr(ew)) : ({
        w += 1;
        r += 1;
    }) {
        if (m[0] != 0)
            w[0] = r[0];
        m += 1;
    }
}

fn boolcopy24(bdst: Buffer, bsrc: Buffer, bmask: Buffer, dx: i32, i: bool, o: i32) void {
    _ = i;
    _ = o;
    var m = bmask.grey;
    var w = bdst.red;
    var r = bsrc.red;
    const ew = w + @as(usize, @intCast(dx)) * 3;
    while (@intFromPtr(w) < @intFromPtr(ew)) {
        if (m[0] != 0) {
            w[0] = r[0];
            w[1] = r[1];
            w[2] = r[2];
        }
        m += 1;
        w += 3;
        r += 3;
    }
}

fn boolcopy32(bdst: Buffer, bsrc: Buffer, bmask: Buffer, dx: i32, i: bool, o: i32) void {
    _ = i;
    _ = o;
    var m = bmask.grey;
    var w = p32(bdst.red);
    var r = p32(bsrc.red);
    const ew = w + @as(usize, @intCast(dx));
    while (@intFromPtr(w) < @intFromPtr(ew)) : ({
        w += 1;
        r += 1;
    }) {
        if (m[0] != 0)
            w[0] = r[0];
        m += 1;
    }
}

fn genconv(p: *Param, buf: [*]u8, y: i32) Buffer {
    // read from source into RGB format in convbuf
    var b = p.convreadcall.?(p, p.convbuf, y);

    // write RGB format into dst format in buf
    p.convwritecall.?(p.convdpar.?, buf, b);

    if (p.convdx != 0) {
        const nb: usize = @intCast(@divTrunc(p.convdpar.?.img.depth, 8));
        var r = buf;
        var w = buf + nb * @as(usize, @intCast(p.dx));
        const ew = buf + nb * @as(usize, @intCast(p.convdx));
        while (@intFromPtr(w) < @intFromPtr(ew)) {
            w[0] = r[0];
            w += 1;
            r += 1;
        }
    }

    b.red = buf;
    b.blu = nilp;
    b.grn = nilp;
    b.grey = nilp;
    b.alpha = onesp;
    b.rgba = @ptrCast(buf);
    b.delta = 0;

    return b;
}

fn convfn(dst: *Memimage, dpar: *Param, src: *Memimage, spar: *Param, ndrawbuf: *i32) *const Readfn {
    if (dst.chan == src.chan and src.flags & Frepl == 0)
        return readptr;

    if (dst.chan == draw.CMAP8 and (src.chan == draw.GREY1 or src.chan == draw.GREY2 or src.chan == draw.GREY4)) {
        // cheat because we know the replicated value is exactly the color map entry.
        return readnbit;
    }

    spar.convreadcall = readfn(src);
    spar.convwritecall = writefn(dst);
    spar.convdpar = dpar;

    // allocate a conversion buffer
    spar.convbufoff = ndrawbuf.*;
    ndrawbuf.* +|= spar.dx *| 4; // DIFF: saturates, see alphadraw

    if (spar.dx > Dx(spar.img.r)) {
        spar.convdx = spar.dx;
        spar.dx = Dx(spar.img.r);
    }

    return genconv;
}

pub fn pixelbits(i: *Memimage, pt: Point) u32 {
    var val: u32 = 0;
    const p = byteaddr(i, pt);
    var bpp: u32 = @intCast(i.depth);
    switch (bpp) {
        1, 2, 4 => {
            const npack: i32 = @intCast(8 / bpp);
            // DIFF: the C has pt.x%npack, wrong for negative x
            const off = pt.x & (npack - 1);
            const sh: u32 = bpp * @as(u32, @intCast(npack - 1 - off));
            val = @as(u32, p[0]) >> @intCast(sh);
            val &= (@as(u32, 1) << @intCast(bpp)) - 1;
        },
        8 => val = p[0],
        16 => val = @as(u32, p[0]) | (@as(u32, p[1]) << 8),
        24 => val = @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16),
        32 => val = @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24),
        else => {},
    }
    while (bpp < 32) {
        val |= val << @intCast(bpp);
        bpp *= 2;
    }
    return val;
}

fn boolcopyfn(img: *Memimage, mask: *Memimage) *const Calcfn {
    const m = Frepl | Fsimple;
    if ((mask.flags & m) == m and pixelbits(mask, mask.r.min) == ~@as(u32, 0))
        return boolmemmove;

    switch (img.depth) {
        8 => return boolcopy8,
        16 => return boolcopy16,
        24 => return boolcopy24,
        32 => return boolcopy32,
        else => @panic("boolcopyfn"),
    }
}

//
// Optimized draw for filling and scrolling; uses memset and memmove.
//
fn memsets(vp: [*]u8, val_: u16, n: usize) void {
    // make little endian
    const val = std.mem.nativeToLittle(u16, val_);

    const p = p16(vp);
    var k: usize = 0;
    while (k < n) : (k += 1)
        p[k] = val;
}

fn memsetl(vp: [*]u8, val_: u32, n: usize) void {
    // make little endian
    const val = std.mem.nativeToLittle(u32, val_);

    const p = p32(vp);
    var k: usize = 0;
    while (k < n) : (k += 1)
        p[k] = val;
}

fn memset24(vp: [*]u8, val: u32, n: usize) void {
    const a: u8 = @truncate(val);
    const b: u8 = @truncate(val >> 8);
    const c: u8 = @truncate(val >> 16);

    var p = vp;
    const ep = p + 3 * n;
    while (@intFromPtr(p) < @intFromPtr(ep)) {
        p[0] = a;
        p[1] = b;
        p[2] = c;
        p += 3;
    }
}

pub fn imgtorgba(img: *Memimage, val_: u32) u32 {
    var val = val_;
    var a: u32 = 0xFF;
    var r: u32 = 0xAA; // garbage
    var g: u32 = 0xAA;
    var b: u32 = 0xAA;
    var chan = img.chan;
    while (chan != 0) : (chan >>= 8) {
        var nb = draw.NBITS(chan);
        var v: u32 = val & ((@as(u32, 1) << @intCast(nb)) - 1);
        const ov = v;
        val >>= @intCast(nb);

        while (nb < 8) {
            v |= v << @intCast(nb);
            nb *= 2;
        }
        v >>= @intCast(nb - 8);
        v &= 0xFF;

        switch (draw.TYPE(chan)) {
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
                const p: [*]const u8 = @as([*]const u8, &img.cmap.cmap2rgb) + 3 * ov;
                r = p[0];
                g = p[1];
                b = p[2];
            },
            else => {},
        }
    }
    return (r << 24) | (g << 16) | (b << 8) | a;
}

pub fn rgbatoimg(img: *Memimage, rgba: u32) u32 {
    var v: u32 = 0;
    const r: u32 = rgba >> 24;
    const g: u32 = (rgba >> 16) & 0xFF;
    const b: u32 = (rgba >> 8) & 0xFF;
    const a: u32 = rgba & 0xFF;
    var d: u32 = 0;
    var chan = img.chan;
    while (chan != 0) : (chan >>= 8) {
        const nb = draw.NBITS(chan);
        const sh: u5 = @intCast(8 - nb);
        const ds: u5 = @intCast(d);
        switch (draw.TYPE(chan)) {
            CRed => v |= (r >> sh) << ds,
            CGreen => v |= (g >> sh) << ds,
            CBlue => v |= (b >> sh) << ds,
            CAlpha => v |= (a >> sh) << ds,
            CGrey => {
                const m: u32 = RGB2K(r, g, b) & 0xFF;
                v |= (m >> sh) << ds;
            },
            CMap => {
                const p: [*]const u8 = &img.cmap.rgb2cmap;
                const m: u32 = p[(r >> 4) * 256 + (g >> 4) * 16 + (b >> 4)];
                v |= (m >> sh) << ds;
            },
            else => {},
        }
        d += nb;
    }
    return v;
}

fn memoptdraw(par: *Memdrawparam) i32 {
    var dx = Dx(par.r);
    const dy = Dy(par.r);
    const src = par.src.?;
    const dst = par.dst;
    const op = par.op;
    var y: i32 = 0;

    //
    // If we have an opaque mask and source is one opaque pixel we can convert to the
    // destination format and just replicate with memset.
    //
    var m: u32 = Simplesrc | Simplemask | Fullmask;
    if ((par.state & m) == m and (par.srgba & 0xFF) == 0xFF and (op == draw.S or op == draw.SoverD)) {
        var dwid: usize = dst.width * @sizeOf(u32);
        var dp = byteaddr(dst, par.r.min);
        var v = par.sdval;
        switch (dst.depth) {
            1, 2, 4 => {
                const depth: u32 = @intCast(dst.depth);
                var d = depth;
                while (d < 8) : (d *= 2)
                    v |= (v << @intCast(d));
                const vb: u8 = @truncate(v);
                const ppb: i32 = @intCast(8 / depth); // pixels per byte
                const pm: i32 = ppb - 1;

                // left edge
                var np: i32 = par.r.min.x & pm; // no. pixels unused on left side of word
                dx -= (ppb - np);
                var nb: u32 = 8 - @as(u32, @intCast(np)) * depth; // no. bits used on right side of word
                var lm: u8 = @truncate((@as(u32, 1) << @intCast(nb)) - 1);

                // right edge
                np = par.r.max.x & pm; // no. pixels used on left side of word
                dx -= np;
                nb = 8 - @as(u32, @intCast(np)) * depth; // no. bits unused on right side of word
                const rm: u8 = @truncate(~((@as(u32, 1) << @intCast(nb)) - 1));

                // lm, rm are masks that are 1 where we should touch the bits
                if (dx < 0) { // just one byte
                    lm &= rm;
                    while (y < dy) : ({
                        y += 1;
                        dp += dwid;
                    })
                        dp[0] ^= (vb ^ dp[0]) & lm;
                } else if (dx == 0) { // no full bytes
                    if (lm != 0)
                        dwid -= 1;

                    while (y < dy) : ({
                        y += 1;
                        dp += dwid;
                    }) {
                        if (lm != 0) {
                            dp[0] ^= (vb ^ dp[0]) & lm;
                            dp += 1;
                        }
                        dp[0] ^= (vb ^ dp[0]) & rm;
                    }
                } else { // full bytes in middle
                    const nfull: usize = @intCast(@divTrunc(dx, ppb));
                    if (lm != 0)
                        dwid -= 1;
                    dwid -= nfull;

                    while (y < dy) : ({
                        y += 1;
                        dp += dwid;
                    }) {
                        if (lm != 0) {
                            dp[0] ^= (vb ^ dp[0]) & lm;
                            dp += 1;
                        }
                        @memset(dp[0..nfull], vb);
                        dp += nfull;
                        dp[0] ^= (vb ^ dp[0]) & rm;
                    }
                }
                return 1;
            },
            8 => {
                while (y < dy) : ({
                    y += 1;
                    dp += dwid;
                })
                    @memset(dp[0..@intCast(dx)], @as(u8, @truncate(v)));
                return 1;
            },
            16 => {
                while (y < dy) : ({
                    y += 1;
                    dp += dwid;
                })
                    memsets(dp, @truncate(v), @intCast(dx));
                return 1;
            },
            24 => {
                while (y < dy) : ({
                    y += 1;
                    dp += dwid;
                })
                    memset24(dp, v, @intCast(dx));
                return 1;
            },
            32 => {
                while (y < dy) : ({
                    y += 1;
                    dp += dwid;
                })
                    memsetl(dp, v, @intCast(dx));
                return 1;
            },
            else => @panic("bad dest depth in memoptdraw"),
        }
    }

    //
    // If no source alpha, an opaque mask, we can just copy the
    // source onto the destination.  If the channels are the same and
    // the source is not replicated, memmove suffices.
    //
    m = Simplemask | Fullmask;
    if ((par.state & (m | Replsrc)) == m and src.depth >= 8 and
        src.chan == dst.chan and src.flags & Falpha == 0 and (op == draw.S or op == draw.SoverD))
    {
        var swid: isize = @intCast(src.width * @sizeOf(u32));
        var dwid: isize = @intCast(dst.width * @sizeOf(u32));
        var sp = byteaddr(src, par.sr.min);
        var dp = byteaddr(dst, par.r.min);
        if (src.data == dst.data and @intFromPtr(dp) > @intFromPtr(sp)) {
            // walk scanlines in the opposite direction
            sp = padd(sp, (dy - 1) * swid);
            dp = padd(dp, (dy - 1) * dwid);
            swid = -swid;
            dwid = -dwid;
        }
        const nb: usize = @intCast(@divTrunc(dx * src.depth, 8));
        while (y < dy) : ({
            y += 1;
            sp = padd(sp, swid);
            dp = padd(dp, dwid);
        })
            @memmove(dp[0..nb], sp[0..nb]);
        return 1;
    }

    //
    // If we have a 1-bit mask, 1-bit source, and 1-bit destination, and
    // they're all bit aligned, we can just use bit operators.  This happens
    // when we're manipulating boolean masks, e.g. in the arc code.
    //
    if ((par.state & (Simplemask | Simplesrc | Replmask | Replsrc)) == 0 and
        dst.chan == draw.GREY1 and src.chan == draw.GREY1 and par.mask.?.chan == draw.GREY1 and
        (par.r.min.x & 7) == (par.sr.min.x & 7) and (par.r.min.x & 7) == (par.mr.min.x & 7))
    {
        var sp = byteaddr(src, par.sr.min);
        var dp = byteaddr(dst, par.r.min);
        var mp = byteaddr(par.mask.?, par.mr.min);
        var swid: isize = @intCast(src.width * @sizeOf(u32));
        var dwid: isize = @intCast(dst.width * @sizeOf(u32));
        var mwid: isize = @intCast(par.mask.?.width * @sizeOf(u32));
        const dir: i32 = if (src.data == dst.data and @intFromPtr(dp) > @intFromPtr(sp)) -1 else 1;

        var lm: u8 = @as(u8, 0xFF) >> @intCast(par.r.min.x & 7);
        const rm: u8 = @truncate(@as(u32, 0xFF) << @intCast(8 - (par.r.max.x & 7)));
        dx -= (8 - (par.r.min.x & 7)) + (par.r.max.x & 7);

        if (dx < 0) { // one byte wide
            lm &= rm;
            if (dir == -1) {
                dp = padd(dp, dwid * (dy - 1));
                sp = padd(sp, swid * (dy - 1));
                mp = padd(mp, mwid * (dy - 1));
                dwid = -dwid;
                swid = -swid;
                mwid = -mwid;
            }
            while (y < dy) : (y += 1) {
                dp[0] ^= (dp[0] ^ sp[0]) & mp[0] & lm;
                dp = padd(dp, dwid);
                sp = padd(sp, swid);
                mp = padd(mp, mwid);
            }
            return 1;
        }

        dx = @divTrunc(dx, 8);
        var x: i32 = undefined;
        if (dir == 1) {
            const i: isize = @as(isize, @intFromBool(lm != 0)) + dx + @intFromBool(rm != 0);
            mwid -= i;
            swid -= i;
            dwid -= i;
            while (y < dy) : ({
                y += 1;
                dp = padd(dp, dwid);
                sp = padd(sp, swid);
                mp = padd(mp, mwid);
            }) {
                if (lm != 0) {
                    dp[0] ^= (dp[0] ^ sp[0]) & mp[0] & lm;
                    sp += 1;
                    mp += 1;
                    dp += 1;
                }
                x = 0;
                while (x < dx) : (x += 1) {
                    dp[0] ^= (dp[0] ^ sp[0]) & mp[0];
                    sp += 1;
                    mp += 1;
                    dp += 1;
                }
                if (rm != 0) {
                    dp[0] ^= (dp[0] ^ sp[0]) & mp[0] & rm;
                    sp += 1;
                    mp += 1;
                    dp += 1;
                }
            }
        } else {
            // dir == -1
            const i: isize = @as(isize, @intFromBool(lm != 0)) + dx + @intFromBool(rm != 0);
            dp = padd(dp, dwid * (dy - 1) + i - 1);
            sp = padd(sp, swid * (dy - 1) + i - 1);
            mp = padd(mp, mwid * (dy - 1) + i - 1);
            dwid = -dwid + i;
            swid = -swid + i;
            mwid = -mwid + i;
            while (y < dy) : ({
                y += 1;
                dp = padd(dp, dwid);
                sp = padd(sp, swid);
                mp = padd(mp, mwid);
            }) {
                if (rm != 0) {
                    dp[0] ^= (dp[0] ^ sp[0]) & mp[0] & rm;
                    sp -= 1;
                    mp -= 1;
                    dp -= 1;
                }
                x = 0;
                while (x < dx) : (x += 1) {
                    dp[0] ^= (dp[0] ^ sp[0]) & mp[0];
                    sp -= 1;
                    mp -= 1;
                    dp -= 1;
                }
                if (lm != 0) {
                    dp[0] ^= (dp[0] ^ sp[0]) & mp[0] & lm;
                    sp -= 1;
                    mp -= 1;
                    dp -= 1;
                }
            }
        }
        return 1;
    }
    return 0;
}

//
// Boolean character drawing.
// Solid opaque color through a 1-bit greyscale mask.
//
fn chardraw(par: *Memdrawparam) i32 {
    var sp: [4]u8 = undefined;

    const mask = par.mask.?;
    const src = par.src.?;
    const dst = par.dst;
    const r = par.r;
    const mr = par.mr;
    const op = par.op;

    if ((par.state & (Replsrc | Simplesrc | Replmask)) != (Replsrc | Simplesrc) or
        mask.chan != draw.GREY1 or src.flags & Falpha != 0 or dst.depth < 8 or dst.data == src.data or
        op != draw.SoverD)
        return 0;

    const maskwid: usize = mask.width * @sizeOf(u32);
    var rp = byteaddr(mask, mr.min);
    const bsh = mr.min.x & 7;

    var wp = byteaddr(dst, r.min);
    const dstwid: usize = dst.width * @sizeOf(u32);
    const dy = Dy(r);
    const dx = Dx(r);

    const ddepth = dst.depth;

    //
    // for loop counts from bsh to bsh+dx
    //
    // we want the bottom bits to be the amount
    // to shift the pixels down, so for n = 0 (mod 8) we want
    // bottom bits 7.  for n = 1, 6, etc.
    // the bits come from -n-1.
    //

    const bx = -bsh - 1;
    const ex = -bsh - 1 - dx;
    var bits: u32 = 0;
    const v = par.sdval;

    // make little endian
    sp[0] = @truncate(v);
    sp[1] = @truncate(v >> 8);
    sp[2] = @truncate(v >> 16);
    sp[3] = @truncate(v >> 24);

    var y: i32 = 0;
    while (y < dy) : ({
        y += 1;
        rp += maskwid;
        wp += dstwid;
    }) {
        var q = rp;
        if (bsh != 0) {
            bits = q[0];
            q += 1;
        }
        var x = bx;
        switch (ddepth) {
            8 => {
                var wc = wp;
                while (x > ex) : ({
                    x -= 1;
                    wc += 1;
                }) {
                    const i: u5 = @intCast(x & 7);
                    if (i == 8 - 1) {
                        bits = q[0];
                        q += 1;
                    }
                    if ((bits >> i) & 1 != 0)
                        wc[0] = @truncate(v);
                }
            },
            16 => {
                var ws = p16(wp);
                const v16 = p16(&sp)[0];
                while (x > ex) : ({
                    x -= 1;
                    ws += 1;
                }) {
                    const i: u5 = @intCast(x & 7);
                    if (i == 8 - 1) {
                        bits = q[0];
                        q += 1;
                    }
                    if ((bits >> i) & 1 != 0)
                        ws[0] = v16;
                }
            },
            24 => {
                var wc = wp;
                while (x > ex) : ({
                    x -= 1;
                    wc += 3;
                }) {
                    const i: u5 = @intCast(x & 7);
                    if (i == 8 - 1) {
                        bits = q[0];
                        q += 1;
                    }
                    if ((bits >> i) & 1 != 0) {
                        wc[0] = sp[0];
                        wc[1] = sp[1];
                        wc[2] = sp[2];
                    }
                }
            },
            32 => {
                var wl = p32(wp);
                const v32 = p32(&sp)[0];
                while (x > ex) : ({
                    x -= 1;
                    wl += 1;
                }) {
                    const i: u5 = @intCast(x & 7);
                    if (i == 8 - 1) {
                        bits = q[0];
                        q += 1;
                    }
                    if ((bits >> i) & 1 != 0)
                        wl[0] = v32;
                }
            },
            else => {},
        }
    }
    return 1;
}

pub fn memfillcolor(i: *Memimage, val: u32) void {
    if (val == draw.DNofill)
        return;

    var bits = rgbatoimg(i, val);
    switch (i.depth) {
        24 => { // 24-bit images suck
            var y = i.r.min.y;
            while (y < i.r.max.y) : (y += 1)
                memset24(byteaddr(i, Pt(i.r.min.x, y)), bits, @intCast(Dx(i.r)));
        },
        else => { // 1, 2, 4, 8, 16, 32
            var d: u32 = @intCast(i.depth);
            while (d < 32) : (d *= 2)
                bits = (bits << @intCast(d)) | bits;
            memsetl(@ptrCast(wordaddr(i, i.r.min)), bits, i.width * @as(usize, @intCast(Dy(i.r))));
        },
    }
}

// ---------------------------------------------------------------------
// Tests.  They run on the host: see kernel.zig.
//
// The reference is the definition in draw(2), computed one pixel at a
// time from the images as they were before the call:
//      dst = (src in mask) * fs + dst * fd
// with fs and fd chosen by the bits of the operator.  memimagedraw is
// required to match it exactly when every alpha involved is 0 or 255
// (then every rounding in draw.c is exact), for every pairing of
// channel formats, and to within 2 in each 8-bit channel otherwise.
// Pixels outside the clipped rectangle must keep their exact bits.

const testing = std.testing;
const loadmemimage = @import("load.zig").loadmemimage;

pub const T = struct {
    var prng: std.Random.DefaultPrng = undefined;

    fn rnd() std.Random {
        return prng.random();
    }

    pub fn done() void {
        for (&dbuf) |*z| {
            kernel.free(z.p);
            z.* = .{};
        }
        if (didinit) {
            alloc.freememimage(memones);
            alloc.freememimage(memzeros);
            didinit = false;
        }
    }

    /// The pixel's bits, exactly depth of them.
    fn getpix(i: *Memimage, pt: Point) u32 {
        const p = byteaddr(i, pt);
        const d: u32 = @intCast(i.depth);
        if (d < 8) {
            const npack: i32 = @intCast(8 / d);
            const off: u32 = @intCast(pt.x & (npack - 1));
            return (@as(u32, p[0]) >> @intCast(d * (@as(u32, @intCast(npack)) - 1 - off))) & ((@as(u32, 1) << @intCast(d)) - 1);
        }
        var v: u32 = 0;
        var k: u32 = 0;
        while (k < d / 8) : (k += 1)
            v |= @as(u32, p[k]) << @intCast(8 * k);
        return v;
    }

    fn setpix(i: *Memimage, pt: Point, v: u32) void {
        var b: [4]u8 = undefined;
        const d: u32 = @intCast(i.depth);
        if (d < 8) {
            const npack: i32 = @intCast(8 / d);
            const off: u32 = @intCast(pt.x & (npack - 1));
            b[0] = @truncate(v << @intCast(d * (@as(u32, @intCast(npack)) - 1 - off)));
        } else std.mem.writeInt(u32, &b, v, .little);
        const n = loadmemimage(i, .{ .min = pt, .max = .{ .x = pt.x + 1, .y = pt.y + 1 } }, b[0 .. (d + 7) / 8]);
        std.debug.assert(n > 0);
    }

    const Mode = enum { boolean, any };

    /// cmap indices that survive cmap -> rgb -> cmap through the 4-bit table.
    fn cmapstable(v: u32) bool {
        const p = cmap.def.cmap2rgb[3 * v ..];
        return cmap.def.rgb2cmap[@as(usize, p[0] >> 4) * 256 + @as(usize, p[1] >> 4) * 16 + (p[2] >> 4)] == v;
    }

    /// A random pixel for img: premultiplied if it has alpha; with only
    /// extreme alpha (and extreme grey, for use as a mask) in boolean mode.
    fn randpix(img: *Memimage, mode: Mode, asmask: bool) u32 {
        const r = rnd();
        if (img.nbits[CMap] != 0) {
            while (true) {
                const v = r.int(u8);
                if (cmapstable(v)) return v;
            }
        }
        var a: u32 = 255;
        if (img.flags & Falpha != 0)
            a = if (mode == .boolean) (if (r.boolean()) 255 else 0) else r.int(u8);
        var red: u32 = r.uintAtMost(u32, a);
        var grn: u32 = r.uintAtMost(u32, a);
        var blu: u32 = r.uintAtMost(u32, a);
        if (asmask and mode == .boolean and img.flags & Falpha == 0) {
            red = if (r.boolean()) 255 else 0;
            grn = red;
            blu = red;
        }
        if (img.flags & Fgrey != 0) {
            grn = red;
            blu = red;
        }
        return rgbatoimg(img, (red << 24) | (grn << 16) | (blu << 8) | a);
    }

    fn fill(img: *Memimage, mode: Mode, asmask: bool) void {
        var y = img.r.min.y;
        while (y < img.r.max.y) : (y += 1) {
            var x = img.r.min.x;
            while (x < img.r.max.x) : (x += 1)
                setpix(img, Pt(x, y), randpix(img, mode, asmask));
        }
    }

    /// A copy of img's pixels (same rectangle and format, own data).
    fn snapshot(img: *Memimage) *Memimage {
        const c = allocmemimage(img.r, img.chan).?;
        var y = img.r.min.y;
        while (y < img.r.max.y) : (y += 1) {
            var x = img.r.min.x;
            while (x < img.r.max.x) : (x += 1)
                setpix(c, Pt(x, y), getpix(img, Pt(x, y)));
        }
        return c;
    }

    /// The pixel of a possibly replicated image that a draw reads at pt,
    /// or null if clipping keeps the draw away from it.
    fn sample(img: *Memimage, pt: Point) ?u32 {
        if (!ptinrect(pt, img.clipr)) return null;
        if (img.flags & Frepl != 0) return getpix(img, drawrepl(img.r, pt));
        if (!ptinrect(pt, img.r)) return null;
        return getpix(img, pt);
    }

    fn chans(v: u32) [4]f64 {
        return .{
            @floatFromInt(v >> 24),
            @floatFromInt((v >> 16) & 0xFF),
            @floatFromInt((v >> 8) & 0xFF),
            @floatFromInt(v & 0xFF),
        };
    }

    /// One draw checked against the reference.  `old` is dst before the
    /// call and srcold is src before it (they are the same image when
    /// src is dst).
    fn check(dst: *Memimage, old: *Memimage, r: Rectangle, src: *Memimage, srcold: *Memimage, p0: Point, mask: ?*Memimage, p1: Point, op: i32, mode: Mode) !void {
        const tol: f64 = if (mode == .boolean) 0 else 2;
        const dgrey = dst.flags & Fgrey != 0;
        var y = dst.r.min.y;
        while (y < dst.r.max.y) : (y += 1) {
            var x = dst.r.min.x;
            while (x < dst.r.max.x) : (x += 1) {
                const pt = Pt(x, y);
                const got = getpix(dst, pt);
                const was = getpix(old, pt);
                const sp = Pt(x - r.min.x + p0.x, y - r.min.y + p0.y);
                const mp = Pt(x - r.min.x + p1.x, y - r.min.y + p1.y);
                const drawn = !badrect(r) and ptinrect(pt, r) and ptinrect(pt, dst.clipr) and op >= 0 and op < Ncomp;
                const spix: ?u32 = if (drawn) sample(srcold, sp) else null;
                const mpix: ?u32 = if (!drawn) null else if (mask) |m| sample(m, mp) else 1;
                if (spix == null or mpix == null) {
                    if (got != was) {
                        std.debug.print("pixel %d,%d outside the draw changed: {x} -> {x}\n", .{ was, got });
                        return error.TestUnexpectedResult;
                    }
                    continue;
                }
                const s = chans(imgtorgba(srcold, spix.?));
                const d = chans(imgtorgba(old, was));
                var ma: f64 = 255;
                if (mask) |m| {
                    const mv = imgtorgba(m, mpix.?);
                    ma = if (m.flags & Falpha != 0)
                        @floatFromInt(mv & 0xFF)
                    else
                        @floatFromInt(RGB2K(mv >> 24, (mv >> 16) & 0xFF, (mv >> 8) & 0xFF));
                }
                const sa = s[3];
                const da = d[3];
                // As in C: memoptdraw's bit-operator path for three
                // aligned 1-bit images does not look at the operator
                // and always computes SoverD.
                var eop = op;
                if (mask) |m| {
                    if (dst.chan == draw.GREY1 and src.chan == draw.GREY1 and m.chan == draw.GREY1 and
                        (src.flags | m.flags) & Frepl == 0 and
                        ((r.min.x - p0.x) & 7) == 0 and ((r.min.x - p1.x) & 7) == 0)
                        eop = draw.SoverD;
                }
                const sam = sa * ma / 255;
                const fs = (if (eop & draw.SinD != 0) da else 0) + (if (eop & draw.SoutD != 0) 255 - da else 0);
                const fd = (if (eop & draw.DinS != 0) sam else 0) + (if (eop & draw.DoutS != 0) 255 - sam else 0);
                var e: [4]f64 = undefined;
                var sc = s;
                if (dgrey) {
                    // colour is converted to grey as it is read
                    const k: f64 = @floatFromInt(RGB2K(@intFromFloat(s[0]), @intFromFloat(s[1]), @intFromFloat(s[2])));
                    sc = .{ k, k, k, sa };
                }
                for (&e, sc, d) |*ev, sv, dv|
                    ev.* = (sv * ma * fs / 255 + dv * fd) / 255;

                var g: [4]f64 = undefined;
                if (mode == .boolean) {
                    // exact: quantise the way the destination format does
                    const ei = (@as(u32, @intFromFloat(@round(e[0]))) << 24) | (@as(u32, @intFromFloat(@round(e[1]))) << 16) |
                        (@as(u32, @intFromFloat(@round(e[2]))) << 8) | @as(u32, @intFromFloat(@round(e[3])));
                    e = chans(imgtorgba(dst, rgbatoimg(dst, ei)));
                }
                g = chans(imgtorgba(dst, got));
                if (dst.flags & Falpha == 0) e[3] = 255;
                for (e, g) |ev, gv| {
                    if (@abs(ev - gv) > tol) {
                        var b1: [16]u8 = undefined;
                        var b2: [16]u8 = undefined;
                        var b3: [16]u8 = undefined;
                        const chantostr = @import("../libdraw/chan.zig").chantostr;
                        std.debug.print("op {d} dst {s} src {s}{s} mask {s}{s} at {d},{d}: want {any} got {any} (s {any} d {any} ma {d})\n", .{
                            op,                                                chantostr(&b1, dst.chan).?,
                            chantostr(&b2, src.chan).?,                        if (src.flags & Frepl != 0) "*" else "",
                            if (mask) |m| chantostr(&b3, m.chan).? else "nil", if (mask != null and mask.?.flags & Frepl != 0) "*" else "",
                            x,                                                 y,
                            e,                                                 g,
                            s,                                                 d,
                            ma,
                        });
                        return error.TestUnexpectedResult;
                    }
                }
            }
        }
    }

    fn randrect(within: Rectangle, slop: i32) Rectangle {
        const r = rnd();
        const x0 = r.intRangeAtMost(i32, within.min.x - slop, within.max.x - 1);
        const y0 = r.intRangeAtMost(i32, within.min.y - slop, within.max.y - 1);
        return Rect(x0, y0, r.intRangeAtMost(i32, x0 + 1, within.max.x + slop), r.intRangeAtMost(i32, y0 + 1, within.max.y + slop));
    }

    const big = Rectangle{ .min = .{ .x = -0x3FFFFFF, .y = -0x3FFFFFF }, .max = .{ .x = 0x3FFFFFF, .y = 0x3FFFFFF } };

    /// A random image: an ordinary one a little different from `near`,
    /// or (repl) a small tile replicated everywhere.
    fn randimage(chan: u32, near: Rectangle, repl: bool, mode: Mode, asmask: bool) *Memimage {
        const r = rnd();
        var ir: Rectangle = undefined;
        if (repl) {
            const x0 = r.intRangeAtMost(i32, -9, 9);
            const y0 = r.intRangeAtMost(i32, -9, 9);
            ir = switch (r.uintLessThan(u32, 3)) {
                0 => Rect(x0, y0, x0 + 1, y0 + 1),
                1 => Rect(x0, y0, x0 + r.intRangeAtMost(i32, 1, 9), y0 + r.intRangeAtMost(i32, 1, 5)),
                else => Rect(x0, y0, x0 + r.intRangeAtMost(i32, 1, 40), y0 + r.intRangeAtMost(i32, 1, 20)),
            };
        } else {
            ir = Rect(
                near.min.x + r.intRangeAtMost(i32, -4, 4),
                near.min.y + r.intRangeAtMost(i32, -4, 4),
                near.max.x + r.intRangeAtMost(i32, -4, 4),
                near.max.y + r.intRangeAtMost(i32, -4, 4),
            );
        }
        const i = allocmemimage(ir, chan).?;
        fill(i, mode, asmask);
        if (repl) {
            i.flags |= Frepl;
            i.clipr = if (r.boolean()) big else randrect(near, 3);
        } else if (r.uintLessThan(u32, 4) == 0) {
            i.clipr = randrect(ir, 0);
        }
        return i;
    }

    const allchans = [_]u32{
        draw.GREY1, draw.GREY2,  draw.GREY4,  draw.GREY8,  draw.CMAP8, draw.RGB15,  draw.RGB16,
        draw.RGB24, draw.RGBA32, draw.ARGB32, draw.XRGB32, draw.BGR24, draw.ABGR32, draw.XBGR32,
    };
    const bytechans = [_]u32{ draw.GREY8, draw.RGB24, draw.RGBA32, draw.ARGB32, draw.XRGB32, draw.BGR24, draw.ABGR32, draw.XBGR32 };
    const maskchans = [_]u32{ draw.GREY1, draw.GREY1, draw.GREY8, draw.RGBA32, draw.GREY2, draw.GREY4, draw.RGB24, draw.CMAP8, draw.ARGB32 };

    fn pick(comptime list: []const u32) u32 {
        return list[rnd().uintLessThan(usize, list.len)];
    }

    fn run(mode: Mode, iterations: usize, seed: u64) !void {
        prng = std.Random.DefaultPrng.init(seed);
        memimageinit();
        defer done();
        const r = rnd();
        var it: usize = 0;
        while (it < iterations) : (it += 1) {
            const dr = Rect(r.intRangeAtMost(i32, -40, 8), r.intRangeAtMost(i32, -9, 9), r.intRangeAtMost(i32, 20, 50), r.intRangeAtMost(i32, 20, 30));
            const dst = allocmemimage(dr, if (mode == .boolean) pick(&allchans) else pick(&bytechans)).?;
            defer alloc.freememimage(dst);
            fill(dst, mode, false);
            if (r.uintLessThan(u32, 4) == 0) dst.clipr = randrect(dr, 2);

            // the source: another image, a tile, or dst itself
            const self = r.uintLessThan(u32, 6) == 0;
            const src = if (self) dst else randimage(pick(&allchans), dr, r.uintLessThan(u32, 3) == 0, mode, false);
            defer if (!self) alloc.freememimage(src);

            // the mask: none, opaque, transparent, or an image or tile
            var mask: ?*Memimage = null;
            var ownmask = false;
            switch (r.uintLessThan(u32, 8)) {
                0, 1 => {},
                2 => mask = memdraw.memopaque,
                3 => mask = if (r.boolean()) memdraw.memtransparent else memdraw.memopaque,
                else => {
                    // a mask in CMAP8 is read through the colour map
                    // as a grey level; only extreme greys are exact
                    var mc = pick(&maskchans);
                    if (mc == draw.CMAP8 and mode == .boolean) mc = draw.GREY1;
                    mask = randimage(mc, dr, r.uintLessThan(u32, 3) == 0, mode, true);
                    ownmask = true;
                },
            }
            defer if (ownmask) alloc.freememimage(mask.?);

            const old = snapshot(dst);
            defer alloc.freememimage(old);
            old.clipr = dst.clipr;
            // src as it was: for src == dst the snapshot, read with
            // dst's own replication and clipping (there are none)
            const srcold = if (self) old else src;

            const op: i32 = switch (r.uintLessThan(u32, 4)) {
                0 => draw.SoverD,
                1 => draw.S,
                else => r.intRangeLessThan(i32, 0, Ncomp),
            };
            const rr = randrect(dr, 6);
            const near = r.boolean();
            const p0 = if (near) Pt(rr.min.x + r.intRangeAtMost(i32, -5, 5), rr.min.y + r.intRangeAtMost(i32, -5, 5)) else Pt(r.intRangeAtMost(i32, -60, 60), r.intRangeAtMost(i32, -40, 40));
            const p1 = if (r.boolean()) p0 else Pt(rr.min.x + r.intRangeAtMost(i32, -9, 9), rr.min.y + r.intRangeAtMost(i32, -9, 9));

            memimagedraw(dst, rr, src, p0, mask, p1, op);
            check(dst, old, rr, src, srcold, p0, mask, p1, op, mode) catch |e| {
                std.debug.print("iteration {d} seed {d}: r {any} p0 {any} p1 {any} dst.r {any} src.r {any} self {}\n", .{ it, seed, rr, p0, p1, dst.r, src.r, self });
                return e;
            };
        }
    }
};

test "memimagedraw against the definition, alphas 0 or 255, all formats" {
    try T.run(.boolean, 30000, 1);
}

test "memimagedraw against the definition, any alpha, 8-bit channels" {
    try T.run(.any, 20000, 2);
}

test "one-bit images: bit operators, source overlapping destination" {
    T.prng = std.Random.DefaultPrng.init(3);
    memimageinit();
    defer T.done();
    const r = T.rnd();
    var it: usize = 0;
    while (it < 6000) : (it += 1) {
        const dr = Rect(r.intRangeAtMost(i32, -40, 8), r.intRangeAtMost(i32, -9, 9), r.intRangeAtMost(i32, 20, 70), r.intRangeAtMost(i32, 20, 30));
        const dst = allocmemimage(dr, draw.GREY1).?;
        defer alloc.freememimage(dst);
        T.fill(dst, .boolean, false);
        const self = r.boolean();
        const src = if (self) dst else T.randimage(draw.GREY1, dr, false, .boolean, false);
        defer if (!self) alloc.freememimage(src);
        const mask = T.randimage(draw.GREY1, dr, false, .boolean, true);
        defer alloc.freememimage(mask);
        const old = T.snapshot(dst);
        defer alloc.freememimage(old);
        const rr = T.randrect(dr, 3);
        // source and mask a whole number of bytes away, any number of lines
        const p0 = Pt(rr.min.x + 8 * r.intRangeAtMost(i32, -3, 3), rr.min.y + r.intRangeAtMost(i32, -6, 6));
        const p1 = Pt(rr.min.x + 8 * r.intRangeAtMost(i32, -1, 1), rr.min.y + r.intRangeAtMost(i32, -2, 2));
        const op: i32 = if (r.boolean()) draw.SoverD else r.intRangeLessThan(i32, 0, Ncomp);
        memimagedraw(dst, rr, src, p0, mask, p1, op);
        try T.check(dst, old, rr, src, if (self) old else src, p0, mask, p1, op, .boolean);
    }
}

test "pixel conversions" {
    memimageinit();
    defer T.done();
    const one = Rect(0, 0, 1, 1);
    const Case = struct { chan: u32, rgba: u32, pix: u32, back: u32 };
    const cases = [_]Case{
        .{ .chan = draw.RGB24, .rgba = 0x112233FF, .pix = 0x112233, .back = 0x112233FF },
        .{ .chan = draw.BGR24, .rgba = 0x112233FF, .pix = 0x332211, .back = 0x112233FF },
        .{ .chan = draw.RGBA32, .rgba = 0x11223344, .pix = 0x11223344, .back = 0x11223344 },
        .{ .chan = draw.ARGB32, .rgba = 0x11223344, .pix = 0x44112233, .back = 0x11223344 },
        .{ .chan = draw.XRGB32, .rgba = 0x11223344, .pix = 0x00112233, .back = 0x112233FF },
        .{ .chan = draw.RGB16, .rgba = 0xFF8000FF, .pix = 0xFC00, .back = 0xFF8200FF },
        .{ .chan = draw.RGB15, .rgba = 0xFF8008FF, .pix = 0x7E01, .back = 0xFF8408FF },
        .{ .chan = draw.GREY8, .rgba = 0xFFFFFFFF, .pix = 0xFF, .back = 0xFFFFFFFF },
        .{ .chan = draw.GREY8, .rgba = 0xFF0000FF, .pix = 76, .back = 0x4C4C4CFF },
        .{ .chan = draw.GREY1, .rgba = 0x808080FF, .pix = 1, .back = 0xFFFFFFFF },
        .{ .chan = draw.GREY2, .rgba = 0x808080FF, .pix = 2, .back = 0xAAAAAAFF },
        .{ .chan = draw.GREY4, .rgba = 0x7F7F7FFF, .pix = 7, .back = 0x777777FF },
        .{ .chan = draw.CMAP8, .rgba = 0xFFFFFFFF, .pix = 0xFF, .back = 0xFFFFFFFF },
        .{ .chan = draw.CMAP8, .rgba = 0x000000FF, .pix = 0, .back = 0x000000FF },
    };
    for (cases) |c| {
        const i = allocmemimage(one, c.chan).?;
        defer alloc.freememimage(i);
        try testing.expectEqual(c.pix, rgbatoimg(i, c.rgba));
        try testing.expectEqual(c.back, imgtorgba(i, c.pix));
        // memfillcolor stores it, pixelbits reads it back replicated
        memfillcolor(i, c.rgba);
        var want = c.pix;
        var d: u32 = @intCast(i.depth);
        while (d < 32) : (d *= 2) want |= want << @intCast(d);
        try testing.expectEqual(want, pixelbits(i, draw.ZP));
    }
}

test "memfillcolor fills exactly the image, DNofill leaves it" {
    memimageinit();
    defer T.done();
    for (T.allchans) |chan| {
        const i = allocmemimage(Rect(-3, -2, 21, 5), chan).?;
        defer alloc.freememimage(i);
        memfillcolor(i, draw.DRed);
        const want = rgbatoimg(i, draw.DRed);
        var y = i.r.min.y;
        while (y < i.r.max.y) : (y += 1) {
            var x = i.r.min.x;
            while (x < i.r.max.x) : (x += 1)
                try testing.expectEqual(want, T.getpix(i, Pt(x, y)));
        }
        memfillcolor(i, draw.DNofill);
        try testing.expectEqual(want, T.getpix(i, i.r.min));
    }
}

test "drawclip" {
    memimageinit();
    defer T.done();
    const dst = allocmemimage(Rect(0, 0, 100, 100), draw.GREY8).?;
    defer alloc.freememimage(dst);
    const src = allocmemimage(Rect(10, 10, 30, 30), draw.GREY8).?;
    defer alloc.freememimage(src);
    const tile = allocmemimage(Rect(0, 0, 4, 4), draw.GREY8).?;
    defer alloc.freememimage(tile);
    tile.flags |= Frepl;
    tile.clipr = T.big;

    var r = Rect(-5, 50, 60, 70);
    var p0 = Pt(0, 5);
    var p1 = Pt(0, 5);
    var sr: Rectangle = undefined;
    var mr: Rectangle = undefined;
    // dst clips x to 0 (source point moves to 5), then src.r clips to
    // x 10..30, y 10..25
    try testing.expect(drawclip(dst, &r, src, &p0, memdraw.memopaque, &p1, &sr, &mr));
    try testing.expectEqual(Rect(5, 55, 25, 70), r);
    try testing.expectEqual(Rect(10, 10, 30, 25), sr);
    try testing.expectEqual(Pt(10, 10), p0);
    try testing.expectEqual(Pt(0, 0), p1); // the 1x1 mask: moved into its rectangle
    try testing.expectEqual(Rect(0, 0, 20, 15), mr);

    // a replicated source: the point is brought into the tile
    r = Rect(10, 10, 20, 20);
    p0 = Pt(-3, 9);
    p1 = p0;
    try testing.expect(drawclip(dst, &r, tile, &p0, memdraw.memopaque, &p1, &sr, &mr));
    try testing.expectEqual(Rect(10, 10, 20, 20), r);
    try testing.expectEqual(Pt(1, 1), p0);
    try testing.expectEqual(Rect(1, 1, 11, 11), sr);

    // nothing left
    r = Rect(0, 0, 10, 10);
    p0 = Pt(40, 40);
    p1 = p0;
    try testing.expect(!drawclip(dst, &r, src, &p0, memdraw.memopaque, &p1, &sr, &mr));
    r = Rect(10, 10, 10, 20);
    try testing.expect(!drawclip(dst, &r, tile, &p0, memdraw.memopaque, &p1, &sr, &mr));
}

test "hwdraw sees every draw and can take it" {
    memimageinit();
    defer T.done();
    const hw = @import("hwdraw.zig");
    const H = struct {
        var calls: u32 = 0;
        var take: i32 = 0;
        var last: Rectangle = .{};
        fn f(par: *Memdrawparam) i32 {
            calls += 1;
            last = par.r;
            return take;
        }
    };
    hw.hook = &H.f;
    defer hw.hook = null;
    const dst = allocmemimage(Rect(0, 0, 8, 8), draw.XRGB32).?;
    defer alloc.freememimage(dst);
    memfillcolor(dst, draw.DBlack);
    const red = allocmemimage(Rect(0, 0, 1, 1), draw.XRGB32).?;
    defer alloc.freememimage(red);
    red.flags |= Frepl;
    red.clipr = T.big;
    memfillcolor(red, draw.DRed);

    memimagedraw(dst, Rect(2, 2, 20, 4), red, draw.ZP, null, draw.ZP, draw.SoverD);
    try testing.expectEqual(@as(u32, 1), H.calls);
    try testing.expectEqual(Rect(2, 2, 8, 4), H.last);
    try testing.expectEqual(@as(u32, 0xFF0000), T.getpix(dst, Pt(7, 3)) & 0xFFFFFF);
    try testing.expectEqual(@as(u32, 0), T.getpix(dst, Pt(1, 3)) & 0xFFFFFF);
    // when the hook says it did the work, nothing else is drawn
    H.take = 1;
    memimagedraw(dst, Rect(0, 0, 8, 8), red, draw.ZP, null, draw.ZP, draw.SoverD);
    try testing.expectEqual(@as(u32, 2), H.calls);
    try testing.expectEqual(@as(u32, 0), T.getpix(dst, Pt(0, 0)) & 0xFFFFFF);
    H.take = 0;
}

test "characters through chardraw" {
    memimageinit();
    defer T.done();
    const subfont = @import("subfont.zig");
    const f = @import("defont.zig").getmemdefont().?;
    defer subfont.freememsubfont(f);
    for ([_]u32{ draw.CMAP8, draw.RGB16, draw.RGB24, draw.XRGB32 }) |chan| {
        const dst = allocmemimage(Rect(0, 0, 40, 20), chan).?;
        defer alloc.freememimage(dst);
        memfillcolor(dst, draw.DWhite);
        const ink = allocmemimage(Rect(0, 0, 1, 1), chan).?;
        defer alloc.freememimage(ink);
        ink.flags |= Frepl;
        ink.clipr = T.big;
        memfillcolor(ink, draw.DBlue);
        // what memimagestring does for one character, at an odd x
        const c: usize = 'A';
        const info = f.info[c];
        const p = Pt(3, 2);
        memimagedraw(dst, Rect(p.x + info.left, p.y + info.top, p.x + info.left + (f.info[c + 1].x - info.x), p.y + info.bottom), ink, draw.ZP, f.bits, Pt(info.x, info.top), draw.SoverD);
        const white = rgbatoimg(dst, draw.DWhite);
        const blue = rgbatoimg(dst, draw.DBlue);
        var nink: u32 = 0;
        var y: i32 = 0;
        while (y < 20) : (y += 1) {
            var x: i32 = 0;
            while (x < 40) : (x += 1) {
                const inglyph = x >= 3 and x < 11 and y >= 2 + info.top and y < 2 + info.bottom;
                const bit = inglyph and T.getpix(f.bits, Pt(info.x + x - 3, y - 2)) != 0;
                try testing.expectEqual(if (bit) blue else white, T.getpix(dst, Pt(x, y)));
                nink += @intFromBool(bit);
            }
        }
        try testing.expect(nink > 10);
    }
}
