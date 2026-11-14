//! libdraw: draw.h, and the library's functions under their C names,
//! as libc.zig is for libc.  The client side of /dev/draw, from 9front
//! 11952's /sys/src/libdraw (the release the guest's tests compare
//! against; later 9front packs messages with drawcmd()).
//!
//! The types, constants and functions that are plain functions of
//! their arguments (arith.c, badrect.c, bytesperline.c, chan.c,
//! computil.c, defont.c, drawrepl.c, icossin*.c, rectclip.c, rgb.c)
//! are the kernel's own ports in src/kernel/libdraw, through
//! src/kernel/drawlib.zig; this file re-exports them.  The rest, the
//! client, is in this directory, one file per C file, and the client's
//! types (Display, Image, Screen, Font, Subfont and the Cache*
//! structures), which the kernel's draw.zig leaves out, are here.
//!
//! What is ported: the display (init.c), images (alloc.c, draw.c,
//! replclipr.c, loadimage.c, unloadimage.c, readimage.c,
//! creadimage.c), screens and windows (window.c), and fonts and text
//! (font.c, buildfont.c, openfont.c, getdefont.c, subfont.c,
//! subfontcache.c, subfontname.c, getsubfont.c, freesubfont.c,
//! readsubfont.c, string.c, stringbg.c, stringwidth.c).  Not yet:
//! lines, ellipses, polygons, arcs, borders, colour maps, writing
//! images, the event and menu libraries.
//!
//! DIFF (all files):
//!   - Errors are the library's error union (libc.Error), with the
//!     text set by werrstr as in C, where the C returns nil or -1.
//!   - No locks: the library has none and its programs share no
//!     memory, so _lockdisplay, lockdisplay and the Display's locks
//!     are left out.
//!   - Strings are slices ([]const u8, []const Rune): a NUL in one is
//!     a character, not its end.
//!   - Memory is libc.allocator's; an allocation that fails is an
//!     error with the text "no memory".
//!   - setmalloctag and getcallerpc are left out.

const libc = @import("libc");
const k = @import("drawlib");

pub const Error = libc.Error;
pub const Rune = libc.Rune;

// ---------------------------------------------------------------------
// From the kernel's ports (src/kernel/libdraw).

pub const DOpaque = k.draw.DOpaque;
pub const DTransparent = k.draw.DTransparent;
pub const DBlack = k.draw.DBlack;
pub const DWhite = k.draw.DWhite;
pub const DRed = k.draw.DRed;
pub const DGreen = k.draw.DGreen;
pub const DBlue = k.draw.DBlue;
pub const DCyan = k.draw.DCyan;
pub const DMagenta = k.draw.DMagenta;
pub const DYellow = k.draw.DYellow;
pub const DPaleyellow = k.draw.DPaleyellow;
pub const DDarkyellow = k.draw.DDarkyellow;
pub const DDarkgreen = k.draw.DDarkgreen;
pub const DPalegreen = k.draw.DPalegreen;
pub const DMedgreen = k.draw.DMedgreen;
pub const DDarkblue = k.draw.DDarkblue;
pub const DPalebluegreen = k.draw.DPalebluegreen;
pub const DPaleblue = k.draw.DPaleblue;
pub const DBluegreen = k.draw.DBluegreen;
pub const DGreygreen = k.draw.DGreygreen;
pub const DPalegreygreen = k.draw.DPalegreygreen;
pub const DYellowgreen = k.draw.DYellowgreen;
pub const DMedblue = k.draw.DMedblue;
pub const DGreyblue = k.draw.DGreyblue;
pub const DPalegreyblue = k.draw.DPalegreyblue;
pub const DPurpleblue = k.draw.DPurpleblue;
pub const DNotacolor = k.draw.DNotacolor;
pub const DNofill = k.draw.DNofill;
pub const Displaybufsize = k.draw.Displaybufsize;
pub const ICOSSCALE = k.draw.ICOSSCALE;
pub const Borderwidth = k.draw.Borderwidth;
pub const Refbackup = k.draw.Refbackup;
pub const Refnone = k.draw.Refnone;
pub const Refmesg = k.draw.Refmesg;
pub const Endsquare = k.draw.Endsquare;
pub const Enddisc = k.draw.Enddisc;
pub const Endarrow = k.draw.Endarrow;
pub const Endmask = k.draw.Endmask;
pub const ARROW = k.draw.ARROW;
pub const Drawop = k.draw.Drawop;
pub const Clear = k.draw.Clear;
pub const SinD = k.draw.SinD;
pub const DinS = k.draw.DinS;
pub const SoutD = k.draw.SoutD;
pub const DoutS = k.draw.DoutS;
pub const S = k.draw.S;
pub const SoverD = k.draw.SoverD;
pub const SatopD = k.draw.SatopD;
pub const SxorD = k.draw.SxorD;
pub const D = k.draw.D;
pub const DoverS = k.draw.DoverS;
pub const DatopS = k.draw.DatopS;
pub const DxorS = k.draw.DxorS;
pub const Ncomp = k.draw.Ncomp;
pub const CRed = k.draw.CRed;
pub const CGreen = k.draw.CGreen;
pub const CBlue = k.draw.CBlue;
pub const CGrey = k.draw.CGrey;
pub const CAlpha = k.draw.CAlpha;
pub const CMap = k.draw.CMap;
pub const CIgnore = k.draw.CIgnore;
pub const NChan = k.draw.NChan;
pub const __DC = k.draw.__DC;
pub const CHAN1 = k.draw.CHAN1;
pub const CHAN2 = k.draw.CHAN2;
pub const CHAN3 = k.draw.CHAN3;
pub const CHAN4 = k.draw.CHAN4;
pub const NBITS = k.draw.NBITS;
pub const TYPE = k.draw.TYPE;
pub const GREY1 = k.draw.GREY1;
pub const GREY2 = k.draw.GREY2;
pub const GREY4 = k.draw.GREY4;
pub const GREY8 = k.draw.GREY8;
pub const CMAP8 = k.draw.CMAP8;
pub const RGB15 = k.draw.RGB15;
pub const RGB16 = k.draw.RGB16;
pub const RGB24 = k.draw.RGB24;
pub const RGBA32 = k.draw.RGBA32;
pub const ARGB32 = k.draw.ARGB32;
pub const XRGB32 = k.draw.XRGB32;
pub const BGR15 = k.draw.BGR15;
pub const BGR24 = k.draw.BGR24;
pub const ABGR32 = k.draw.ABGR32;
pub const XBGR32 = k.draw.XBGR32;
pub const WFintupscale = k.draw.WFintupscale;
pub const Point = k.draw.Point;
pub const Rectangle = k.draw.Rectangle;
pub const RGB = k.draw.RGB;
pub const Warp = k.draw.Warp;
pub const Fontchar = k.draw.Fontchar;
pub const Dx = k.draw.Dx;
pub const Dy = k.draw.Dy;
pub const ZP = k.draw.ZP;
pub const ZR = k.draw.ZR;
pub const BGSHORT = k.draw.BGSHORT;
pub const BGLONG = k.draw.BGLONG;
pub const BPSHORT = k.draw.BPSHORT;
pub const BPLONG = k.draw.BPLONG;
pub const NMATCH = k.draw.NMATCH;
pub const NRUN = k.draw.NRUN;
pub const NMEM = k.draw.NMEM;
pub const NDUMP = k.draw.NDUMP;
pub const NCBLOCK = k.draw.NCBLOCK;
pub const Pt = k.arith.Pt;
pub const Rect = k.arith.Rect;
pub const Rpt = k.arith.Rpt;
pub const addpt = k.arith.addpt;
pub const subpt = k.arith.subpt;
pub const insetrect = k.arith.insetrect;
pub const divpt = k.arith.divpt;
pub const mulpt = k.arith.mulpt;
pub const rectsubpt = k.arith.rectsubpt;
pub const rectaddpt = k.arith.rectaddpt;
pub const eqpt = k.arith.eqpt;
pub const eqrect = k.arith.eqrect;
pub const rectXrect = k.arith.rectXrect;
pub const rectinrect = k.arith.rectinrect;
pub const ptinrect = k.arith.ptinrect;
pub const canonrect = k.arith.canonrect;
pub const combinerect = k.arith.combinerect;
pub const drawld2chan = k.arith.drawld2chan;
pub const setalpha = k.arith.setalpha;
pub const badrect = k.badrect.badrect;
pub const wordsperline = k.bytesperline.wordsperline;
pub const bytesperline = k.bytesperline.bytesperline;
pub const chantostr = k.chan.chantostr;
pub const strtochan = k.chan.strtochan;
pub const chantodepth = k.chan.chantodepth;
pub const _twiddlecompressed = k.computil._twiddlecompressed;
pub const _compblocksize = k.computil._compblocksize;
pub const _unpackinfo = k.defont._unpackinfo;
pub const drawreplxy = k.drawrepl.drawreplxy;
pub const drawrepl = k.drawrepl.drawrepl;
pub const icossin = k.icossin.icossin;
pub const icossin2 = k.icossin2.icossin2;
pub const rectclip = k.rectclip.rectclip;
pub const rgb2cmap = k.rgb.rgb2cmap;
pub const cmap2rgb = k.rgb.cmap2rgb;
pub const cmap2rgba = k.rgb.cmap2rgba;

// ---------------------------------------------------------------------
// The client's types.

/// struct Display.  DIFF: no qlock, usrlock or locking; buf is a slice
/// with the offset bufp into it; the strings are slices.
pub const Display = struct {
    dirno: i32 = 0,
    fd: i32 = -1,
    reffd: i32 = -1,
    ctlfd: i32 = -1,
    imageid: i32 = 0,
    local: bool = false,
    @"error": ?*const fn (*Display, []const u8) void = null,
    devdir: []u8 = &.{},
    windir: []u8 = &.{},
    oldlabel: [64]u8 = undefined,
    noldlabel: usize = 0,
    dataqid: u32 = 0,
    white: *Image = undefined,
    black: *Image = undefined,
    @"opaque": *Image = undefined,
    transparent: *Image = undefined,
    image: ?*Image = null,
    buf: []u8 = &.{},
    bufsize: i32 = 0,
    bufp: usize = 0,
    defaultfont: ?*Font = null,
    defaultsubfont: ?*Subfont = null,
    windows: ?*Image = null,
    screenimage: ?*Image = null,
    _isnewdisplay: bool = false,
};

/// struct Image.  DIFF: repl is a bool.
pub const Image = struct {
    display: *Display, // display holding data
    id: i32 = 0, // id of system-held Image
    r: Rectangle = .{}, // rectangle in data area, local coords
    clipr: Rectangle = .{}, // clipping region
    depth: i32 = 0, // number of bits per pixel
    chan: u32 = 0,
    repl: bool = false, // flag: data replicates to tile clipr
    screen: ?*Screen = null, // null if not a window
    next: ?*Image = null, // next in list of windows
};

pub const Screen = struct {
    display: *Display, // display holding data
    id: i32 = 0, // id of system-held Screen
    image: ?*Image = null, // unused; for reference only
    fill: ?*Image = null, // color to paint behind windows
};

pub const Cachefont = struct {
    min: Rune, // lowest rune value to be taken from subfont
    max: Rune, // highest rune value+1 to be taken from subfont
    offset: i32, // position in subfont of character at min
    name: []u8, // stored in font
    subfontname: ?[]u8 = null, // to access subfont
};

pub const Cacheinfo = struct {
    x: u16 = 0, // left edge of bits
    width: u8 = 0, // width of baseline
    left: i8 = 0, // offset of baseline
    value: Rune = 0, // value of character at this slot in cache
    age: u16 = 0,
};

pub const Cachesubf = struct {
    age: u32 = 0, // for replacement
    cf: ?*Cachefont = null, // font info that owns us
    f: ?*Subfont = null, // attached subfont
};

/// struct Font.  DIFF: cache, subf and sub are slices, whose lengths
/// are the C's ncache, nsubf and nsub.
pub const Font = struct {
    name: []u8,
    display: ?*Display,
    height: i16 = 0, // max height of image, interline spacing
    ascent: i16 = 0, // top of image to baseline
    width: i16 = 0, // widest so far; used in caching only
    age: u32 = 0, // increasing counter; used for LRU
    maxdepth: i32 = 0, // maximum depth of all loaded subfonts
    cache: []Cacheinfo = &.{},
    subf: []Cachesubf = &.{},
    sub: []*Cachefont = &.{}, // as read from file
    cacheimage: ?*Image = null,
};

/// struct Subfont.  DIFF: info is a slice of n+1 entries.
pub const Subfont = struct {
    name: ?[]u8,
    n: i16, // number of chars in font
    height: u8, // height of image
    ascent: i8, // top of image to baseline
    info: []Fontchar, // n+1 character descriptors
    bits: *Image, // of font
    ref: i32,
};

pub const LOG2NFCACHE = 6;
pub const NFCACHE = 1 << LOG2NFCACHE; // #chars cached
pub const NFLOOK = 5; // #chars to scan in cache
pub const NFSUBF = 2; // #subfonts to cache
pub const MAXFCACHE = 1024 + NFLOOK; // upper limit
pub const MAXSUBF = 50; // generous upper limit
pub const DSUBF = 4;
pub const SUBFAGE = 10000;
pub const CACHEAGE = 10000;

/// The program's display, its default font, its window and the screen
/// the window is on, set by initdraw (draw.h's externs).
pub var display: ?*Display = null;
pub var font: ?*Font = null;
pub var screen: ?*Image = null;
pub var _screen: ?*Screen = null;

// ---------------------------------------------------------------------
// The client's functions.

const init_ = @import("init.zig");
pub const geninitdraw = init_.geninitdraw;
pub const initdraw = init_.initdraw;
pub const gengetwindow = init_.gengetwindow;
pub const getwindow = init_.getwindow;
pub const initdisplay = init_.initdisplay;
pub const closedisplay = init_.closedisplay;
pub const drawerror = init_.drawerror;
pub const flushimage = init_.flushimage;
pub const bufimage = init_.bufimage;
pub const _bufimageop = init_._bufimageop;

const alloc_ = @import("alloc.zig");
pub const allocimage = alloc_.allocimage;
pub const _allocimage = alloc_._allocimage;
pub const namedimage = alloc_.namedimage;
pub const nameimage = alloc_.nameimage;
pub const _freeimage1 = alloc_._freeimage1;
pub const freeimage = alloc_.freeimage;

const draw_ = @import("draw.zig");
pub const draw = draw_.draw;
pub const drawop = draw_.drawop;
pub const gendraw = draw_.gendraw;
pub const gendrawop = draw_.gendrawop;

pub const replclipr = @import("replclipr.zig").replclipr;
pub const loadimage = @import("loadimage.zig").loadimage;
pub const unloadimage = @import("unloadimage.zig").unloadimage;
pub const readimage = @import("readimage.zig").readimage;
pub const creadimage = @import("creadimage.zig").creadimage;

const window_ = @import("window.zig");
pub const allocscreen = window_.allocscreen;
pub const publicscreen = window_.publicscreen;
pub const freescreen = window_.freescreen;
pub const allocwindow = window_.allocwindow;
pub const _allocwindow = window_._allocwindow;
pub const bottomwindow = window_.bottomwindow;
pub const topwindow = window_.topwindow;
pub const bottomnwindows = window_.bottomnwindows;
pub const topnwindows = window_.topnwindows;
pub const originwindow = window_.originwindow;

const font_ = @import("font.zig");
pub const Text = font_.Text;
pub const cachechars = font_.cachechars;
pub const agefont = font_.agefont;
pub const loadchar = font_.loadchar;

const buildfont_ = @import("buildfont.zig");
pub const buildfont = buildfont_.buildfont;
pub const freefont = buildfont_.freefont;
pub const openfont = @import("openfont.zig").openfont;
pub const getdefont = @import("getdefont.zig").getdefont;
pub const allocsubfont = @import("subfont.zig").allocsubfont;
const subfontcache_ = @import("subfontcache.zig");
pub const lookupsubfont = subfontcache_.lookupsubfont;
pub const installsubfont = subfontcache_.installsubfont;
pub const uninstallsubfont = subfontcache_.uninstallsubfont;
pub const subfontname = @import("subfontname.zig").subfontname;
pub const _getsubfont = @import("getsubfont.zig")._getsubfont;
pub const freesubfont = @import("freesubfont.zig").freesubfont;
const readsubfont_ = @import("readsubfont.zig");
pub const readsubfonti = readsubfont_.readsubfonti;
pub const readsubfont = readsubfont_.readsubfont;

const string_ = @import("string.zig");
pub const string = string_.string;
pub const stringop = string_.stringop;
pub const stringn = string_.stringn;
pub const stringnop = string_.stringnop;
pub const runestring = string_.runestring;
pub const runestringop = string_.runestringop;
pub const runestringn = string_.runestringn;
pub const runestringnop = string_.runestringnop;
pub const _string = string_._string;
const stringbg_ = @import("stringbg.zig");
pub const stringbg = stringbg_.stringbg;
pub const stringbgop = stringbg_.stringbgop;
pub const stringnbg = stringbg_.stringnbg;
pub const stringnbgop = stringbg_.stringnbgop;
pub const runestringbg = stringbg_.runestringbg;
pub const runestringbgop = stringbg_.runestringbgop;
pub const runestringnbg = stringbg_.runestringnbg;
pub const runestringnbgop = stringbg_.runestringnbgop;
const stringwidth_ = @import("stringwidth.zig");
pub const _stringnwidth = stringwidth_._stringnwidth;
pub const stringnwidth = stringwidth_.stringnwidth;
pub const stringwidth = stringwidth_.stringwidth;
pub const stringsize = stringwidth_.stringsize;
pub const runestringnwidth = stringwidth_.runestringnwidth;
pub const runestringwidth = stringwidth_.runestringwidth;
pub const runestringsize = stringwidth_.runestringsize;

/// The text of an allocation failure.
pub fn nomem() Error {
    libc.werrstr("no memory", .{});
    return error.Plan9;
}

