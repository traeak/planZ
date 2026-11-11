//! The draw device, #i: the kernel end of the draw(3) protocol.  Clients
//! open /dev/draw/new, allocate images, screens and windows by writing
//! messages to their data file, and read back image data and refresh
//! events.
//! from 9/port/devdraw.c
//!
//! DIFF:
//!   - Errors are Zig error returns.  Every function that can raise one
//!     (drawlookup with checkname, drawimage, drawfreedimage through
//!     drawfreedscreen, ...) returns an error union and its callers
//!     pass it on, so an error leaves a deep helper the same way the C's
//!     error() does, with drawlock still held until the device entry
//!     (drawopen, drawclose, drawread, drawwrite) releases it by defer.
//!     The waserror sites of drawmesg became: an errdefer for the
//!     debugging print; a catch that frees the Refx in 'b'; defers that
//!     free the point array ('p', 'P') and the window array ('t'); a
//!     defer that restores the destination's clipr ('s', 'x').  In
//!     drawread the sleep for a refresh event takes drawlock again
//!     before passing an error on, as the C's handler does.
//!   - The local error strings are raised with proc.errorf.
//!   - drawunpack takes its format at compile time and a tuple of
//!     pointers; an unknown format letter is a compile error, where the
//!     C raises "unknown unpack field format specifier".  There is no
//!     separate vdrawunpack.  'z' stores one slice (the C stores a
//!     count and a pointer), and checks that the count byte itself is
//!     inside the message before reading it (the C reads it first).
//!   - Message parsing indexes slices instead of moving pointers; `a`
//!     in drawmesg is the rest of the write and a.len is the C's n.
//!   - Arithmetic on coordinates and sizes a client supplies wraps
//!     (+%, -%), as it silently does in C; plain operators would panic
//!     a safe build on overflow.  The byte count of 'r' is refused when
//!     it wraps negative, where the C lets the allocation fail.
//!   - 'r' refuses a bad rectangle (empty, inverted) before working out
//!     its size.  rectinrect passes any rectangle whose max is below
//!     the image's min, so the C computes a size from it, a product of
//!     two negative numbers that can be gigabytes, allocates that, and
//!     only then has memunload refuse the rectangle.
//!   - sdraw.client and sdraw.name are slices; nclient is client.len.
//!     Client.readdata is a slice of exactly the bytes to return, so
//!     there is no nreaddata.  DImage.name and DName.name are slices,
//!     screenname is a slice of a 40 byte buffer.
//!   - drawclientofpath checks the slot against the table (the C
//!     indexes without looking; the slot comes from a qid this device
//!     made).
//!   - drawinstallscreen refuses to make a new screen without an
//!     image: Memscreen.image is not optional.  Its only caller that
//!     makes one ('A') has checked both images already.
//!   - drawopen checks the open mode before taking the lock, so a bad
//!     mode cannot leave a client marked busy and referenced without
//!     an open channel, as it can in C.
//!   - drawclose frees the client's unread 'r' data; the C leaks it.
//!   - printmesg is kept, switched off by the constant `drawdebug`
//!     where the C has `if(1|| ...)`.
//!   - ishwimage (a macro of screen.h) is a function of screen.zig.
//!   - drawactive, drawqlock/drawqunlock and drawreplacescreenimage are
//!     not here: 9front's devdraw.c does not have them (they belong to
//!     the Plan 9 4th edition file).  9front's equivalents are the
//!     exported `drawlock`, deletescreenimage and resetscreenimage.

const std = @import("std");
const fcall = @import("fcall");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const ql = @import("qlock.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const devmod = @import("dev.zig");
const devcons = @import("devcons.zig");
const parse = @import("parse.zig");
const netif = @import("netif.zig");
const p9 = @import("print.zig");

const draw = @import("../libdraw/draw.zig");
const arith = @import("../libdraw/arith.zig");
const memdraw_h = @import("../libmemdraw/memdraw.zig");
const memlayer_h = @import("../libmemlayer/memlayer.zig");
const screen = @import("screen.zig");

const rectclip = @import("../libdraw/rectclip.zig").rectclip;
const bytesperline = @import("../libdraw/bytesperline.zig").bytesperline;
const badrect = @import("../libdraw/badrect.zig").badrect;
const chantostr = @import("../libdraw/chan.zig").chantostr;

const memalloc = @import("../libmemdraw/alloc.zig");
const allocmemimage = memalloc.allocmemimage;
const allocmemimaged = memalloc.allocmemimaged;
const freememimage = memalloc.freememimage;
const memfillcolor = @import("../libmemdraw/draw.zig").memfillcolor;
const memlinebbox = @import("../libmemdraw/line.zig").memlinebbox;
const memlineendsize = @import("../libmemdraw/line.zig").memlineendsize;
const memarc = @import("../libmemdraw/arc.zig").memarc;
const memellipse = @import("../libmemdraw/ellipse.zig").memellipse;
const mempoly = @import("../libmemdraw/poly.zig").mempoly;
const memfillpoly = @import("../libmemdraw/fillpoly.zig").memfillpoly;

const memdraw = @import("../libmemlayer/draw.zig").memdraw;
const memline = @import("../libmemlayer/line.zig").memline;
const memlalloc = @import("../libmemlayer/lalloc.zig").memlalloc;
const memldelete = @import("../libmemlayer/ldelete.zig").memldelete;
const memlfree = @import("../libmemlayer/ldelete.zig").memlfree;
const memltofrontn = @import("../libmemlayer/ltofront.zig").memltofrontn;
const memltorearn = @import("../libmemlayer/ltorear.zig").memltorearn;
const memlsetrefresh = @import("../libmemlayer/lsetrefresh.zig").memlsetrefresh;
const memlorigin = @import("../libmemlayer/lorigin.zig").memlorigin;
const memlnorefresh = @import("../libmemlayer/lorigin.zig").memlnorefresh;
const memload = @import("../libmemlayer/load.zig").memload;
const memunload = @import("../libmemlayer/unload.zig").memunload;
const memlaffinewarp = @import("../libmemlayer/warp.zig").memlaffinewarp;

const attachscreen = screen.attachscreen;
const flushmemscreen = screen.flushmemscreen;
const getcolor = screen.getcolor;
const setcolor = screen.setcolor;
const ishwimage = screen.ishwimage;
const mouseresize = @import("devmouse.zig").mouseresize;

const print = p9.print;
const iprint = p9.iprint;
const panic = p9.panic;
const devdir = devmod.devdir;
const mkqid = devmod.mkqid;
const incref = portdat.incref;
const decref = portdat.decref;

pub const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Qid = portdat.Qid;
const Dir = portdat.Dir;
const Ref = portdat.Ref;
const Rendez = portdat.Rendez;
const QLock = portdat.QLock;
const Dirtab = devmod.Dirtab;
const QTDIR = fcall.QTDIR;
const QTFILE = fcall.QTFILE;
const DEVDOTDOT = portdat.DEVDOTDOT;
const COPEN = portdat.COPEN;

const Point = draw.Point;
const Rectangle = draw.Rectangle;
const Warp = draw.Warp;
const Memimage = memdraw_h.Memimage;
const Memdata = memdraw_h.Memdata;
const Memlayer = memlayer_h.Memlayer;
const Memscreen = memlayer_h.Memscreen;
const Refreshfn = memlayer_h.Refreshfn;
const Dx = draw.Dx;
const Dy = draw.Dy;
const ZP = draw.ZP;
const ZR = draw.ZR;
const BGSHORT = draw.BGSHORT;
const BGLONG = draw.BGLONG;
const BPLONG = draw.BPLONG;
const Pt = arith.Pt;
const Rect = arith.Rect;
const combinerect = arith.combinerect;
const rectaddpt = arith.rectaddpt;
const rectXrect = arith.rectXrect;
const rectinrect = arith.rectinrect;
const insetrect = arith.insetrect;

const Qtopdir = 0;
const Qnew = 1;
const Qwinname = 2;
const Q3rd = 3;
const Q2nd = 4;
const Qcolormap = 5;
const Qctl = 6;
const Qdata = 7;
const Qrefresh = 8;

//
// Qid path is:
//       4 bits of file type (qids above)
//      24 bits of mux slot number +1; 0 means not attached to client
//
const QSHIFT = 4; // location in qid of client #

fn QID(q: Qid) u32 {
    return @as(u32, @truncate(q.path)) & 0x0000000F;
}

fn CLIENTPATH(q: u64) u32 {
    return (@as(u32, @truncate(q)) & 0x7FFFFFF0) >> QSHIFT;
}

fn CLIENT(q: Qid) u32 {
    return CLIENTPATH(q.path);
}

const NHASH = 1 << 5;
const HASHMASK = NHASH - 1;
const IOUNIT = 64 * 1024;

fn hash(id: i32) usize {
    return @as(u32, @bitCast(id)) & HASHMASK;
}

const Draw = struct {
    clientid: i32 = 0,
    client: []?*Client = &.{}, // client.len is the C's nclient
    nname: usize = 0,
    name: []DName = &.{}, // the first nname are in use
    vers: i32 = 0,
    softscreen: bool = false,
};

const Client = struct {
    r: Ref = .{},
    dimage: [NHASH]?*DImage = @splat(null),
    cscreen: ?*CScreen = null,
    refresh: ?*Refresh = null,
    refrend: Rendez = .{},
    refq: QLock = .{},
    readdata: ?[]u8 = null,
    busy: bool = false,
    clientid: i32 = 0,
    slot: usize = 0,
    refreshme: bool = false,
    infoid: i32 = 0,
    op: i32 = draw.SoverD,
};

const Refresh = struct {
    dimage: *DImage,
    r: Rectangle,
    next: ?*Refresh,
};

const Refx = struct {
    client: *Client,
    dimage: ?*DImage,
};

const DName = struct {
    name: []u8,
    client: ?*Client,
    dimage: *DImage,
    vers: i32,
};

const FChar = struct {
    minx: i32 = 0, // left edge of bits
    maxx: i32 = 0, // right edge of bits
    miny: u8 = 0, // first non-zero scan-line
    maxy: u8 = 0, // last non-zero scan-line + 1
    left: i8 = 0, // offset of baseline
    width: u8 = 0, // width of baseline
};

//
// Reference counts in DImages:
//      one per open by original client
//      one per screen image or fill
//      one per image derived from this one by name
//
const DImage = struct {
    id: i32 = 0,
    ref: i32 = 0,
    name: ?[]u8 = null,
    vers: i32 = 0,
    image: *Memimage,
    ascent: i32 = 0,
    fchar: ?[]FChar = null, // fchar.len is the C's nfchar
    dscreen: ?*DScreen = null, // 0 if not a window
    fromname: ?*DImage = null, // image this one is derived from, by name
    next: ?*DImage = null,

    fn nfchar(d: *const DImage) usize {
        return if (d.fchar) |f| f.len else 0;
    }
};

const CScreen = struct {
    dscreen: *DScreen,
    next: ?*CScreen,
};

const DScreen = struct {
    id: i32,
    public: i32,
    ref: i32,
    dimage: ?*DImage,
    dfill: ?*DImage,
    screen: *Memscreen,
    owner: *Client,
    next: ?*DScreen,
};

var sdraw: Draw = .{};
pub var drawlock: QLock = .{};

var screenimage: ?*Memimage = null;
var screendimage: ?*DImage = null;
var screennamebuf: [40]u8 = @splat(0);
var screenname: []const u8 = "";
var screennameid: i32 = 0;

var flushrect: Rectangle = .{};
var waste: i32 = 0;
var dscreen: ?*DScreen = null;

const Enodrawimage = "unknown id for draw image";
const Enodrawscreen = "unknown id for draw screen";
const Eshortdraw = "short draw message";
const Eshortread = "draw read too short";
const Eimageexists = "image id in use";
const Escreenexists = "screen id in use";
const Edrawmem = "image memory allocation failed";
const Ereadoutside = "readimage outside image";
const Ewriteoutside = "writeimage outside image";
const Enotfont = "image not a font";
const Eindex = "character index out of range";
const Enoclient = "no such draw client";
const Enameused = "image name in use";
const Enoname = "no image with that name";
const Eoldname = "named image no longer valid";
const Enamed = "image already has name";
const Ewrongname = "wrong name for image";

/// The C's error("text").
fn err(comptime s: []const u8) Error {
    return proc.errorf(s, .{});
}

fn dlock() void {
    ql.qlock(&drawlock);
}

fn candlock() bool {
    return ql.canqlock(&drawlock);
}

fn dunlock() void {
    ql.qunlock(&drawlock);
}

fn drawgen(c: *Chan, _: ?[]const u8, _: []const Dirtab, s: i32, dp: *Dir) i32 {
    const up = arch.up().?;
    var q: Qid = .{ .path = 0, .vers = 0, .type = 0 };

    if (s == DEVDOTDOT) {
        switch (QID(c.qid)) {
            Qtopdir, Q2nd => {
                q = mkqid(Qtopdir, 0, QTDIR);
                devdir(c, q, "#i", 0, proc.eve, 0o500, dp);
            },
            Q3rd => {
                const name = if (drawclientofpath(c.qid.path)) |cl|
                    fmt.snprint(up.genbuf[0..], "%d", .{cl.clientid})
                else
                    fmt.snprint(up.genbuf[0..], "??", .{});
                q = mkqid(Q2nd, 0, QTDIR);
                devdir(c, q, name, 0, proc.eve, 0o500, dp);
            },
            else => panic("drawwalk %llux", .{c.qid.path}),
        }
        return 1;
    }

    const t = QID(c.qid);
    switch (t) {
        //
        // Top level directory contains the name of the device.
        //
        Qtopdir, Qwinname => {
            if (t == Qtopdir and s == 0) {
                q = mkqid(Q2nd, 0, QTDIR);
                devdir(c, q, "draw", 0, proc.eve, 0o555, dp);
                return 1;
            }
            if (t == Qwinname or s == 1) {
                q = mkqid(Qwinname, 0, QTFILE);
                devdir(c, q, "winname", 0, proc.eve, 0o444, dp);
                return 1;
            }
            return -1;
        },
        //
        // Second level contains "new" plus all the clients.
        //
        Q2nd, Qnew => {
            if (t == Qnew or s == 0) {
                q = mkqid(Qnew, 0, QTFILE);
                devdir(c, q, "new", 0, proc.eve, 0o666, dp);
                return 1;
            }
            if (s > 0 and @as(usize, @intCast(s)) <= sdraw.client.len) {
                const slot: usize = @intCast(s);
                const cl = sdraw.client[slot - 1] orelse
                    return 0;
                const name = fmt.snprint(up.genbuf[0..], "%d", .{cl.clientid});
                q = mkqid((slot << QSHIFT) | Q3rd, 0, QTDIR);
                devdir(c, q, name, 0, proc.eve, 0o555, dp);
                return 1;
            }
            return -1;
        },
        else => {},
    }

    //
    // Third level.
    //
    const path = c.qid.path & ~@as(u64, (1 << QSHIFT) - 1); // slot component
    q.vers = c.qid.vers;
    q.type = QTFILE;
    switch (s) {
        0 => {
            q.path = path | Qcolormap;
            devdir(c, q, "colormap", 0, proc.eve, 0o600, dp);
        },
        1 => {
            q.path = path | Qctl;
            devdir(c, q, "ctl", 0, proc.eve, 0o600, dp);
        },
        2 => {
            q.path = path | Qdata;
            devdir(c, q, "data", 0, proc.eve, 0o600, dp);
        },
        3 => {
            q.path = path | Qrefresh;
            devdir(c, q, "refresh", 0, proc.eve, 0o400, dp);
        },
        else => return -1,
    }
    return 1;
}

fn drawrefactive(a: ?*anyopaque) bool {
    const c: *Client = @ptrCast(@alignCast(a.?));
    return c.refreshme or c.refresh != null;
}

fn drawrefreshscreen(l_: ?*DImage, client: *Client) void {
    var l = l_;
    while (l != null and l.?.dscreen == null)
        l = l.?.fromname;
    if (l) |d| {
        if (d.dscreen.?.owner != client)
            d.dscreen.?.owner.refreshme = true;
    }
}

/// The refresh function of a Refmesg window: memlayer calls it, with
/// drawlock held by whoever is drawing, for a part of the window that
/// has become visible and has no backing store.
fn drawrefresh(_: *Memimage, r: Rectangle, v: ?*anyopaque) void {
    const x: *Refx = @ptrCast(@alignCast(v orelse return));
    const c = x.client;
    const d = x.dimage orelse return;
    var ref = c.refresh;
    while (ref) |rf| : (ref = rf.next) {
        if (rf.dimage == d) {
            combinerect(&rf.r, r);
            return;
        }
    }
    if (alloc.new(Refresh)) |rf| {
        rf.* = .{ .dimage = d, .r = r, .next = c.refresh };
        c.refresh = rf;
    }
}

const drawrefreshfn: Refreshfn = &drawrefresh;

fn addflush(r_: Rectangle) void {
    var r = r_;
    const si = screenimage orelse return;
    if (!sdraw.softscreen or !rectclip(&r, si.r))
        return;
    if (flushrect.min.x >= flushrect.max.x) {
        flushrect = r;
        waste = 0;
        return;
    }
    var nbb = flushrect;
    combinerect(&nbb, r);
    const ar = Dx(r) *% Dy(r);
    const abb = Dx(flushrect) *% Dy(flushrect);
    const anbb = Dx(nbb) *% Dy(nbb);
    //
    // Area of new waste is area of new bb minus area of old bb,
    // less the area of the new segment, which we assume is not waste.
    // This could be negative, but that's OK.
    //
    waste +%= anbb -% abb -% ar;
    if (waste < 0)
        waste = 0;
    //
    // absorb if:
    //      total area is small
    //      waste is less than half total area
    //      rectangles touch
    //
    if (anbb <= 1024 or waste *% 2 < anbb or rectXrect(flushrect, r)) {
        flushrect = nbb;
        return;
    }
    // emit current state
    if (flushrect.min.x < flushrect.max.x)
        flushmemscreen(flushrect);
    flushrect = r;
    waste = 0;
}

fn dstflush(dstid: i32, dst: ?*Memimage, r_: Rectangle) void {
    var r = r_;
    if (dstid == 0) {
        combinerect(&flushrect, r);
        return;
    }
    const si = screenimage orelse return;
    var l: *Memlayer = (dst orelse return).layer orelse return;
    while (true) {
        if (l.screen.image.data != si.data)
            return;
        r = wrapaddpt(r, l.delta);
        l = l.screen.image.layer orelse break;
    }
    addflush(r);
}

pub fn drawflush() void {
    if (screenimage != null and flushrect.min.x < flushrect.max.x)
        flushmemscreen(flushrect);
    flushrect = Rect(10000, 10000, -10000, -10000);
}

/// rectaddpt for a rectangle a client supplied: wraps (see DIFF).
fn wrapaddpt(r: Rectangle, p: Point) Rectangle {
    return .{
        .min = .{ .x = r.min.x +% p.x, .y = r.min.y +% p.y },
        .max = .{ .x = r.max.x +% p.x, .y = r.max.y +% p.y },
    };
}

/// Rect(p.x-d, p.y-d, p.x+d+1, p.y+d+1), wrapping.
fn boxaround(p: Point, d: i32) Rectangle {
    return .{
        .min = .{ .x = p.x -% d, .y = p.y -% d },
        .max = .{ .x = p.x +% d +% 1, .y = p.y +% d +% 1 },
    };
}

fn drawcmp(a: []const u8, b: []const u8) bool {
    return !std.mem.eql(u8, a, b);
}

fn drawlookupname(str: []const u8) ?*DName {
    for (sdraw.name[0..sdraw.nname]) |*name| {
        if (!drawcmp(name.name, str))
            return name;
    }
    return null;
}

fn drawgoodname(d: *DImage) bool {
    // if window, validate the screen's own images
    if (d.dscreen) |ds| {
        if (ds.dimage) |di| {
            if (!drawgoodname(di)) return false;
        }
        if (ds.dfill) |df| {
            if (!drawgoodname(df)) return false;
        }
    }
    const name = d.name orelse return true;
    const n = drawlookupname(name) orelse return false;
    if (n.vers != d.vers)
        return false;
    return true;
}

fn drawlookup(client: *Client, id: i32, checkname: bool) Error!?*DImage {
    var d = client.dimage[hash(id)];
    while (d) |di| {
        if (di.id == id) {
            if (checkname and !drawgoodname(di))
                return err(Eoldname);
            return di;
        }
        d = di.next;
    }
    return null;
}

fn drawlookupdscreen(id: i32) ?*DScreen {
    var s = dscreen;
    while (s) |ds| {
        if (ds.id == id)
            return ds;
        s = ds.next;
    }
    return null;
}

fn drawlookupscreen(client: *Client, id: i32, cs: *?*CScreen) Error!*DScreen {
    var s = client.cscreen;
    while (s) |c| {
        if (c.dscreen.id == id) {
            cs.* = c;
            return c.dscreen;
        }
        s = c.next;
    }
    return err(Enodrawscreen);
}

fn allocdimage(i: *Memimage) ?*DImage {
    const d = alloc.new(DImage) orelse return null;
    d.* = .{
        .ref = 1,
        .name = null,
        .vers = 0,
        .image = i,
        .dscreen = null,
        .fchar = null,
        .fromname = null,
    };
    return d;
}

fn drawinstall(client: *Client, id: i32, i: *Memimage, ds: ?*DScreen) ?*Memimage {
    const d = allocdimage(i) orelse return null;
    d.id = id;
    d.dscreen = ds;
    d.next = client.dimage[hash(id)];
    client.dimage[hash(id)] = d;
    return i;
}

fn drawinstallscreen(client: *Client, d_: ?*DScreen, id: i32, dimage: ?*DImage, dfill: ?*DImage, public: i32) ?*Memscreen {
    const c = alloc.new(CScreen);
    if (dimage) |di| {
        if (di.image.chan == 0)
            panic("bad image %p in drawinstallscreen", .{di.image});
    }

    if (c == null)
        return null;
    const d = d_ orelse blk: {
        const di = dimage orelse { // DIFF: a screen needs an image
            alloc.free(c);
            return null;
        };
        const d = alloc.new(DScreen) orelse {
            alloc.free(c);
            return null;
        };
        const s = alloc.new(Memscreen) orelse {
            alloc.free(c);
            alloc.free(d);
            return null;
        };
        s.* = .{
            .frontmost = null,
            .rearmost = null,
            .image = di.image,
            .fill = null,
        };
        di.ref += 1;
        if (dfill) |df| {
            s.fill = df.image;
            df.ref += 1;
        }
        d.* = .{
            .dimage = di,
            .dfill = dfill,
            .ref = 0,
            .id = id,
            .screen = s,
            .public = public,
            .next = dscreen,
            .owner = client,
        };
        dscreen = d;
        break :blk d;
    };
    c.?.* = .{ .dscreen = d, .next = client.cscreen };
    d.ref += 1;
    client.cscreen = c;
    return d.screen;
}

fn drawdelname(name: *DName) void {
    alloc.free(name.name);
    const i = (@intFromPtr(name) - @intFromPtr(sdraw.name.ptr)) / @sizeOf(DName);
    std.mem.copyForwards(DName, sdraw.name[i .. sdraw.nname - 1], sdraw.name[i + 1 .. sdraw.nname]);
    sdraw.nname -= 1;
}

fn drawfreedscreen(this: *DScreen) Error!void {
    this.ref -= 1;
    if (this.ref < 0)
        print("negative ref in drawfreedscreen\n", .{});
    if (this.ref > 0)
        return;
    found: {
        var ds = dscreen orelse return err(Enodrawimage);
        if (ds == this) {
            dscreen = this.next;
            break :found;
        }
        while (ds.next) |next| {
            if (next == this) {
                ds.next = this.next;
                break :found;
            }
            ds = next;
        }
        return err(Enodrawimage);
    }

    if (this.dimage) |di|
        try drawfreedimage(di);
    if (this.dfill) |df|
        try drawfreedimage(df);
    alloc.free(this.screen);
    alloc.free(this);
}

fn drawfreedimage(dimage: *DImage) Error!void {
    dimage.ref -= 1;
    if (dimage.ref < 0)
        print("negative ref in drawfreedimage\n", .{});
    if (dimage.ref > 0)
        return;

    // any names?
    var i: usize = 0;
    while (i < sdraw.nname) {
        if (sdraw.name[i].dimage == dimage)
            drawdelname(&sdraw.name[i])
        else
            i += 1;
    }
    if (dimage.fromname) |from| { // acquired by name; owned by someone else
        try drawfreedimage(from);
    } else if (dimage.dscreen) |ds| {
        const l = dimage.image;
        const layer = l.layer.?;
        if (screenimage != null and l.data == screenimage.?.data)
            addflush(layer.screenr);
        if (layer.refreshfn == drawrefreshfn) // else true owner will clean up
            alloc.free(layer.refreshptr);
        layer.refreshptr = null;
        if (drawgoodname(dimage))
            memldelete(l)
        else
            memlfree(l);
        try drawfreedscreen(ds);
    } else {
        freememimage(dimage.image);
    }
    if (dimage.fchar) |f| alloc.free(f);
    alloc.free(dimage);
}

fn drawuninstallscreen(client: *Client, this: *CScreen) Error!void {
    var cs = client.cscreen orelse return;
    if (cs == this) {
        client.cscreen = this.next;
        try drawfreedscreen(this.dscreen);
        alloc.free(this);
        return;
    }
    while (cs.next) |next| {
        if (next == this) {
            cs.next = this.next;
            try drawfreedscreen(this.dscreen);
            alloc.free(this);
            return;
        }
        cs = next;
    }
}

fn drawuninstall(client: *Client, id: i32) Error!void {
    var d = client.dimage[hash(id)] orelse
        return err(Enodrawimage);
    if (d.id == id) {
        client.dimage[hash(id)] = d.next;
        try drawfreedimage(d);
        return;
    }
    while (d.next) |next| {
        if (next.id == id) {
            d.next = next.next;
            try drawfreedimage(next);
            return;
        }
        d = next;
    }
    return err(Enodrawimage);
}

fn drawaddname(client: ?*Client, di: *DImage, str: []const u8) Error!void {
    for (sdraw.name[0..sdraw.nname]) |*name| {
        if (!drawcmp(name.name, str))
            return err(Enameused);
    }
    const t = alloc.snewslice(DName, sdraw.nname + 1);
    @memcpy(t[0..sdraw.nname], sdraw.name[0..sdraw.nname]);
    if (sdraw.name.len != 0)
        alloc.free(sdraw.name);
    sdraw.name = t;
    const new = &sdraw.name[sdraw.nname];
    sdraw.nname += 1;
    const name = alloc.snewslice(u8, str.len);
    @memcpy(name, str);
    sdraw.vers +%= 1;
    new.* = .{
        .name = name,
        .dimage = di,
        .client = client,
        .vers = sdraw.vers,
    };
}

fn drawnewclient() ?*Client {
    var i: usize = 0;
    while (i < sdraw.client.len) : (i += 1) {
        if (sdraw.client[i] == null)
            break;
    }
    if (i == sdraw.client.len) {
        const cp = alloc.newslice(?*Client, sdraw.client.len + 1) orelse
            return null;
        @memcpy(cp[0..sdraw.client.len], sdraw.client);
        if (sdraw.client.len != 0)
            alloc.free(sdraw.client);
        sdraw.client = cp;
        cp[i] = null;
    }
    const cl = alloc.new(Client) orelse
        return null;
    sdraw.clientid +%= 1;
    cl.* = .{
        .slot = i,
        .clientid = sdraw.clientid,
        .op = draw.SoverD,
    };
    sdraw.client[i] = cl;
    return cl;
}

fn drawclientop(cl: *Client) i32 {
    const op = cl.op;
    cl.op = draw.SoverD;
    return op;
}

fn drawclientofpath(path: u64) ?*Client {
    const slot = CLIENTPATH(path);
    if (slot == 0 or slot > sdraw.client.len) // DIFF: the second test
        return null;
    const cl = sdraw.client[slot - 1] orelse return null;
    if (cl.clientid == 0)
        return null;
    return cl;
}

fn drawclient(c: *Chan) Error!*Client {
    return drawclientofpath(c.qid.path) orelse
        return err(Enoclient);
}

fn drawimage(client: *Client, id: i32) Error!*Memimage {
    const d = try drawlookup(client, id, true) orelse
        return err(Enodrawimage);
    return d.image;
}

/// drawchar's scratch image; the C's function-level static.
var drawchartmp: ?*Memimage = null;

fn drawchar(dst: *Memimage, rdst: *Memimage, p_: Point, src: *Memimage, sp: *Point, font: *DImage, index: usize, op: i32) Point {
    var p = p_;
    const fc = &font.fchar.?[index];
    var r: Rectangle = undefined;
    r.min.x = p.x +% fc.left;
    r.min.y = p.y -% (font.ascent -% fc.miny);
    r.max.x = r.min.x +% (fc.maxx -% fc.minx);
    r.max.y = r.min.y +% (@as(i32, fc.maxy) - fc.miny);
    const sp1: Point = .{ .x = sp.x +% fc.left, .y = sp.y +% fc.miny };

    //
    // If we're drawing greyscale fonts onto a VGA screen,
    // it's very costly to read the screen memory to do the
    // alpha blending inside memdraw.  If this is really a stringbg,
    // then rdst is the bg image (in main memory) which we can
    // refer to for the underlying dst pixels instead of reading dst
    // directly.
    //
    fallback: {
        if (ishwimage(dst) and !ishwimage(rdst) and font.image.depth > 1) {
            const dx = Dx(r);
            const dy = Dy(r);
            if (drawchartmp == null or drawchartmp.?.chan != dst.chan or Dx(drawchartmp.?.r) < dx or Dy(drawchartmp.?.r) < dy) {
                if (drawchartmp) |t|
                    freememimage(t);
                drawchartmp = allocmemimage(Rect(0, 0, dx, dy), dst.chan);
                if (drawchartmp == null)
                    break :fallback;
            }
            const tmp = drawchartmp.?;
            memdraw(tmp, Rect(0, 0, dx, dy), rdst, r.min, memdraw_h.memopaque, ZP, draw.S);
            memdraw(tmp, Rect(0, 0, dx, dy), src, sp1, font.image, Pt(fc.minx, fc.miny), op);
            memdraw(dst, r, tmp, ZP, memdraw_h.memopaque, ZP, draw.S);
            p.x +%= fc.width;
            sp.x +%= fc.width;
            return p;
        }
    }
    memdraw(dst, r, src, sp1, font.image, Pt(fc.minx, fc.miny), op);

    p.x +%= fc.width;
    sp.x +%= fc.width;
    return p;
}

fn makescreenimage() ?*DImage {
    var width: i32 = 0;
    var depth: i32 = 0;
    var chan: u32 = 0;
    var r: Rectangle = .{};

    const md = attachscreen(&r, &chan, &depth, &width, &sdraw.softscreen) orelse
        return null;
    if (md.ref <= 0)
        panic("makescreenimage: md.ref %d", .{md.ref});
    const i = allocmemimaged(r, chan, md) orelse {
        md.ref -= 1;
        if (md.ref == 0 and md.allocd)
            alloc.free(md);
        return null;
    };
    i.width = @intCast(width);
    i.clipr = r;
    const di = allocdimage(i) orelse {
        freememimage(i); // frees md
        return null;
    };
    screennameid +%= 1;
    screenname = fmt.snprint(screennamebuf[0 .. screennamebuf.len - 1], "noborder.screen.%d", .{screennameid});
    // the C's waserror: carry on without the name
    drawaddname(null, di, screenname) catch {};
    return di;
}

fn initscreenimage() bool {
    if (screenimage != null)
        return true;

    screendimage = makescreenimage();
    const sd = screendimage orelse return false;
    screenimage = sd.image;
    // iprint("initscreenimage %p %p\n", screendimage, screenimage);
    mouseresize();
    return true;
}

/// Called with drawlock held.
pub fn deletescreenimage() Error!void {
    if (screenimage) |si| {
        // will be freed via screendimage; disable
        si.clipr = ZR;
        screenimage = null;
    }
    if (screendimage) |sd| {
        screendimage = null;
        try drawfreedimage(sd);
    }
}

/// Called with drawlock held.
pub fn resetscreenimage() void {
    _ = initscreenimage();
}

fn drawattach(spec: []const u8) Error!*Chan {
    dlock();
    if (!initscreenimage()) {
        dunlock();
        return err("no frame buffer");
    }
    dunlock();
    return devmod.devattach('i', spec);
}

fn drawwalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    if (screenimage == null)
        return err("no frame buffer");
    return devmod.devwalk(c, nc, name, &.{}, drawgen);
}

fn drawstat(c: *Chan, db: []u8) Error!usize {
    return devmod.devstat(c, db, &.{}, drawgen);
}

fn drawopen(c_: *Chan, omode: u32) Error!*Chan {
    var c = c_;
    if (c.qid.type & QTDIR != 0) {
        c = try devmod.devopen(c, omode, &.{}, drawgen);
        c.iounit = IOUNIT;
    }
    const mode = try devmod.openmode(omode); // DIFF: before the lock

    {
        dlock();
        defer dunlock();

        if (QID(c.qid) == Qnew) {
            const cl = drawnewclient() orelse
                return error.Enodev;
            c.qid.path = Qctl | ((cl.slot + 1) << QSHIFT);
        }

        switch (QID(c.qid)) {
            Qwinname => {},

            Qnew => {},

            Qctl => {
                const cl = try drawclient(c);
                if (cl.busy)
                    return error.Einuse;
                cl.busy = true;
                flushrect = Rect(10000, 10000, -10000, -10000);
                const dn = drawlookupname(screenname) orelse
                    return err("draw: cannot happen 2");
                if (drawinstall(cl, 0, dn.dimage.image, null) == null)
                    return err(Edrawmem);
                const di = try drawlookup(cl, 0, false) orelse
                    return err("draw: cannot happen 1");
                di.vers = dn.vers;
                const name = alloc.snewslice(u8, screenname.len);
                @memcpy(name, screenname);
                di.name = name;
                di.fromname = dn.dimage;
                dn.dimage.ref += 1;
                _ = incref(&cl.r);
            },

            Qcolormap, Qdata, Qrefresh => {
                const cl = try drawclient(c);
                _ = incref(&cl.r);
            },

            else => {},
        }
    }
    c.mode = @intCast(mode);
    c.flag |= COPEN;
    c.offset = 0;
    c.iounit = IOUNIT;
    return c;
}

fn drawclose(c: *Chan) Error!void {
    if (QID(c.qid) < Qcolormap) // Qtopdir, Qnew, Q3rd, Q2nd have no client
        return;
    dlock();
    defer dunlock();

    const cl = try drawclient(c);
    if (QID(c.qid) == Qctl)
        cl.busy = false;
    if (c.flag & COPEN != 0 and decref(&cl.r) == 0) {
        while (cl.refresh) |r| {
            cl.refresh = r.next;
            alloc.free(r);
        }
        // free names
        var i: usize = 0;
        while (i < sdraw.nname) {
            if (sdraw.name[i].client == cl)
                drawdelname(&sdraw.name[i])
            else
                i += 1;
        }
        while (cl.cscreen) |cs|
            try drawuninstallscreen(cl, cs);
        // all screens are freed, so now we can free images
        for (&cl.dimage) |*dp| {
            while (dp.*) |d| {
                dp.* = d.next;
                try drawfreedimage(d);
            }
        }
        sdraw.client[cl.slot] = null;
        drawflush(); // to erase visible, now dead windows
        if (cl.readdata) |d| alloc.free(d); // DIFF: the C leaks it
        alloc.free(cl);
    }
}

fn drawread(c: *Chan, a: []u8, off: i64) Error!usize {
    var n = a.len;
    const offset: u32 = @truncate(@as(u64, @bitCast(off)));

    if (c.qid.type & QTDIR != 0)
        return devmod.devdirread(c, a, &.{}, drawgen);
    if (QID(c.qid) == Qwinname)
        return devcons.readstr(offset, a, screenname);

    const cl = try drawclient(c);
    dlock();
    defer dunlock();
    switch (QID(c.qid)) {
        Qctl => {
            if (n < 12 * 12)
                return err(Eshortread);
            if (cl.infoid < 0)
                return err(Enodrawimage);
            var i: *Memimage = undefined;
            if (cl.infoid == 0) {
                i = screenimage orelse
                    return err(Enodrawimage);
            } else {
                const di = try drawlookup(cl, cl.infoid, true) orelse
                    return err(Enodrawimage);
                i = di.image;
            }
            var buf: [16]u8 = undefined;
            const chanstr: []const u8 = chantostr(&buf, i.chan) orelse "";
            n = fmt.snprint(a[0 .. 12 * 12 - 1], "%11d %11d %11s %11d %11d %11d %11d %11d %11d %11d %11d %11d", .{
                cl.clientid,   cl.infoid,     chanstr,       @intFromBool(i.flags & memdraw_h.Frepl == memdraw_h.Frepl),
                i.r.min.x,     i.r.min.y,     i.r.max.x,     i.r.max.y,
                i.clipr.min.x, i.clipr.min.y, i.clipr.max.x, i.clipr.max.y,
            }).len;
            a[n] = ' ';
            n += 1;
            cl.infoid = -1;
        },

        Qcolormap => {
            const p = alloc.newslice(u8, 4 * 12 * 256 + 1) orelse
                return error.Enomem;
            defer alloc.free(p);
            var m: usize = 0;
            var index: u32 = 0;
            while (index < 256) : (index += 1) {
                var red: u32 = 0;
                var green: u32 = 0;
                var blue: u32 = 0;
                getcolor(index, &red, &green, &blue);
                m += fmt.snprint(p[m..], "%11d %11lud %11lud %11lud\n", .{ index, red >> 24, green >> 24, blue >> 24 }).len;
            }
            n = devcons.readstr(offset, a, p[0..m]);
        },

        Qdata => {
            const data = cl.readdata orelse
                return err("no draw data");
            if (n < data.len)
                return err(Eshortread);
            n = data.len;
            @memcpy(a[0..n], data);
            alloc.free(data);
            cl.readdata = null;
        },

        Qrefresh => {
            if (n < 5 * 4)
                return error.Ebadarg;
            while (true) {
                if (cl.refreshme or cl.refresh != null)
                    break;
                dunlock();
                // on error, hold the lock again: the defer above
                // releases it, as the C's outer handler does
                ql.eqlock(&cl.refq) catch |e| {
                    dlock();
                    return e;
                };
                proc.sleep(&cl.refrend, drawrefactive, cl) catch |e| {
                    ql.qunlock(&cl.refq);
                    dlock();
                    return e;
                };
                ql.qunlock(&cl.refq);
                dlock();
            }
            var p: usize = 0;
            while (cl.refresh != null and n >= 5 * 4) {
                const r = cl.refresh.?;
                BPLONG(a[p + 0 * 4 ..], @bitCast(r.dimage.id));
                BPLONG(a[p + 1 * 4 ..], @bitCast(r.r.min.x));
                BPLONG(a[p + 2 * 4 ..], @bitCast(r.r.min.y));
                BPLONG(a[p + 3 * 4 ..], @bitCast(r.r.max.x));
                BPLONG(a[p + 4 * 4 ..], @bitCast(r.r.max.y));
                cl.refresh = r.next;
                alloc.free(r);
                p += 5 * 4;
                n -= 5 * 4;
            }
            cl.refreshme = false;
            n = p;
        },

        else => {},
    }
    return n;
}

fn drawwakeall() void {
    for (sdraw.client) |c| {
        const cl = c orelse continue;
        if (cl.refreshme or cl.refresh != null)
            _ = proc.wakeup(&cl.refrend);
    }
}

fn drawwrite(c: *Chan, a_: []const u8, _: i64) Error!usize {
    var a = a_;
    var n = a.len;

    if (c.qid.type & QTDIR != 0)
        return error.Eisdir;
    const cl = try drawclient(c);
    dlock();
    defer dunlock();
    errdefer drawwakeall();
    switch (QID(c.qid)) {
        Qctl => {
            if (n != 4)
                return err("unknown draw control request");
            cl.infoid = @bitCast(BGLONG(a));
        },

        Qcolormap => {
            var buf: [128]u8 = undefined;
            var fields: [4][]u8 = undefined;
            var m = n;
            n = 0;
            while (m > 0) {
                var x = m;
                if (x > buf.len - 1)
                    x = buf.len - 1;
                // memccpy(buf, a, '\n', x)
                const i = (std.mem.findScalar(u8, a[0..x], '\n') orelse break) + 1;
                @memcpy(buf[0..i], a[0..i]);
                n += i;
                a = a[i..];
                m -= i;
                if (parse.tokenize(buf[0..i], &fields) != 4)
                    return error.Ebadarg;
                const index = netif.strtoul(fields[0], 0).v;
                var red = netif.strtoul(fields[1], 0).v;
                var green = netif.strtoul(fields[2], 0).v;
                const b = netif.strtoul(fields[3], 0);
                var blue = b.v;
                if (b.n == 0)
                    return error.Ebadarg;
                if (red > 255 or green > 255 or blue > 255 or index > 255)
                    return error.Ebadarg;
                red |= red << 8;
                red |= red << 16;
                green |= green << 8;
                green |= green << 16;
                blue |= blue << 8;
                blue |= blue << 16;
                _ = setcolor(index, red, green, blue);
            }
        },

        Qdata => {
            try drawmesg(cl, a);
            drawwakeall();
        },

        else => return error.Ebadusefd,
    }
    return n;
}

/// Decode one coordinate of a polygon at a[p]: a signed 7 bit delta
/// from oldx, or (high bit set) three bytes of absolute value.  Returns
/// the index after it.
fn drawcoord(a: []const u8, p_: usize, oldx: i32, newx: *i32) Error!usize {
    var p = p_;
    if (p >= a.len)
        return err(Eshortdraw);
    const b: u32 = a[p];
    p += 1;
    var x: u32 = b & 0x7F;
    if (b & 0x80 != 0) {
        if (p + 1 >= a.len)
            return err(Eshortdraw);
        x |= @as(u32, a[p]) << 7;
        p += 1;
        x |= @as(u32, a[p]) << 15;
        p += 1;
        if (x & (1 << 22) != 0)
            x |= ~@as(u32, 0) << 23;
    } else {
        if (b & 0x40 != 0)
            x |= ~@as(u32, 0) << 7;
        x +%= @bitCast(oldx);
    }
    newx.* = @bitCast(x);
    return p;
}

/// Store a field of a message in an i32 or u32.
fn put(ptr: anytype, v: u32) void {
    ptr.* = switch (@typeInfo(@TypeOf(ptr)).pointer.child) {
        i32 => @bitCast(v),
        u32 => v,
        else => @compileError("drawunpack: field must be i32 or u32"),
    };
}

fn glong(b: []const u8, a: usize) i32 {
    return @bitCast(BGLONG(b[a..]));
}

/// Unpack the start of the message b as format says, into what the
/// pointers of args point at:
///      _  a byte to skip
///      b  a byte, s  two bytes, l  four bytes: *i32 or *u32
///      P  *Point, R  *Rectangle, M  *Warp (the matrix)
///      z  a count byte and that many bytes: *[]const u8
/// Returns the number of bytes used.
fn drawunpack(b: []const u8, comptime format: []const u8, args: anytype) Error!usize {
    var a: usize = 0;
    const e = b.len;
    comptime var ai: usize = 0;
    inline for (format) |ch| {
        switch (ch) {
            'b' => {
                if (a + 1 > e)
                    return err(Eshortdraw);
                put(args[ai], b[a]);
                ai += 1;
                a += 1;
            },
            's' => {
                if (a + 2 > e)
                    return err(Eshortdraw);
                put(args[ai], BGSHORT(b[a..]));
                ai += 1;
                a += 2;
            },
            'l' => {
                if (a + 4 > e)
                    return err(Eshortdraw);
                put(args[ai], BGLONG(b[a..]));
                ai += 1;
                a += 4;
            },
            'P' => {
                if (a + 2 * 4 > e)
                    return err(Eshortdraw);
                const p: *Point = args[ai];
                ai += 1;
                p.x = glong(b, a);
                p.y = glong(b, a + 4);
                a += 2 * 4;
            },
            'R' => {
                if (a + 4 * 4 > e)
                    return err(Eshortdraw);
                const r: *Rectangle = args[ai];
                ai += 1;
                r.min.x = glong(b, a);
                r.min.y = glong(b, a + 4);
                r.max.x = glong(b, a + 8);
                r.max.y = glong(b, a + 12);
                a += 4 * 4;
            },
            'M' => {
                if (a + 3 * 3 * 4 > e)
                    return err(Eshortdraw);
                const w: *Warp = args[ai];
                ai += 1;
                for (0..3) |i| {
                    for (0..3) |j|
                        w.m[i][j] = glong(b, a + (i * 3 + j) * 4);
                }
                a += 3 * 3 * 4;
            },
            'z' => {
                if (a + 1 > e or a + 1 + b[a] > e)
                    return err(Eshortdraw);
                const z: *[]const u8 = args[ai];
                ai += 1;
                z.* = b[a + 1 ..][0..b[a]];
                a += 1 + @as(usize, b[a]);
            },
            '_' => {
                a += 1;
                if (a > e)
                    return err(Eshortdraw);
            },
            else => @compileError("unknown unpack field format specifier"),
        }
    }
    if (ai != args.len)
        @compileError("drawunpack: more arguments than fields");
    return a;
}

/// The C's `if(1|| ...)` in printmesg.
const drawdebug = false;

fn printmesg(mfmt: []const u8, a_: []const u8, plsprnt: bool) void {
    if (!drawdebug or !plsprnt)
        return;
    var buf: [256]u8 = undefined;
    var a = a_;
    var q: usize = 0;
    buf[q] = a[0];
    q += 1;
    a = a[1..];
    for (mfmt) |ch| {
        const need: usize = switch (ch) {
            'l', 'L' => 4,
            'R' => 16,
            'P' => 8,
            'M' => 36,
            'b' => 1,
            's', 'S' => 2,
            'z' => if (a.len > 0) 1 + @as(usize, a[0]) else 1,
            else => 0,
        };
        if (a.len < need)
            break;
        const out = buf[q .. buf.len - 1];
        q += switch (ch) {
            'l' => fmt.snprint(out, " %ld", .{glong(a, 0)}).len,
            'L' => fmt.snprint(out, " %.8lux", .{BGLONG(a)}).len,
            'R' => fmt.snprint(out, " [%d %d %d %d]", .{ glong(a, 0), glong(a, 4), glong(a, 8), glong(a, 12) }).len,
            'P' => fmt.snprint(out, " [%d %d]", .{ glong(a, 0), glong(a, 4) }).len,
            'M' => fmt.snprint(out, " [[%d %d %d][%d %d %d][%d %d %d]]", .{
                glong(a, 0),  glong(a, 4),  glong(a, 8),
                glong(a, 12), glong(a, 16), glong(a, 20),
                glong(a, 24), glong(a, 28), glong(a, 32),
            }).len,
            'b' => fmt.snprint(out, " %d", .{a[0]}).len,
            's' => fmt.snprint(out, " %d", .{BGSHORT(a)}).len,
            'S' => fmt.snprint(out, " %.4ux", .{BGSHORT(a)}).len,
            'z' => fmt.snprint(out, " %q", .{a[1..need]}).len,
            else => 0,
        };
        a = a[need..];
    }
    buf[q] = '\n';
    q += 1;
    iprint("%s", .{buf[0..q]});
}

/// Carry out the draw messages in av for client.  Called, and left by
/// an error too, with drawlock held.  Messages before a bad one have
/// taken effect.
fn drawmesg(client: *Client, av: []const u8) Error!void {
    var c: i32 = 0;
    var dstid: i32 = 0;
    var scrnid: i32 = 0;
    var ni: i32 = 0;
    var ci: i32 = 0;
    var j: i32 = 0;
    var nw: i32 = 0;
    var e0: i32 = 0;
    var e1: i32 = 0;
    var ox: i32 = 0;
    var oy: i32 = 0;
    var refresh: i32 = 0;
    var repl: i32 = 0;
    var value: u32 = 0;
    var chan: u32 = 0;
    var r: Rectangle = .{};
    var clipr: Rectangle = .{};
    var p: Point = .{};
    var q: Point = .{};
    var sp: Point = .{};
    var cs: ?*CScreen = null;
    var w: Warp = undefined;

    var a = av;
    var m: usize = 0;
    var mfmt: ?[]const u8 = null;
    errdefer {
        if (mfmt) |f| printmesg(f, a, true);
        // iprint("error: %s\n", up->errstr);
    }
    while (m < a.len) {
        a = a[m..];
        const n = a.len;
        switch (a[0]) {
            else => return err("bad draw command"),

            // new allocate: 'b' id[4] screenid[4] refresh[1] chan[4] repl[1] R[4*4] clipR[4*4] rrggbbaa[4]
            'b' => {
                mfmt = "LLbLbRRL";
                printmesg(mfmt.?, a, false);
                m = try drawunpack(a, "_llblbRRl", .{ &dstid, &scrnid, &refresh, &chan, &repl, &r, &clipr, &value });
                if (try drawlookup(client, dstid, false) != null)
                    return err(Eimageexists);
                if (scrnid != 0) {
                    const dscrn = try drawlookupscreen(client, scrnid, &cs);
                    const scrn = dscrn.screen;
                    if (repl != 0 or chan != scrn.image.chan)
                        return err("image parameters incompatible with screen");
                    var reffn: ?Refreshfn = null;
                    switch (refresh) {
                        draw.Refbackup => {},
                        draw.Refnone => reffn = &memlnorefresh,
                        draw.Refmesg => reffn = drawrefreshfn,
                        else => return err("unknown refresh method"),
                    }
                    const l = memlalloc(scrn, r, reffn, null, value) orelse
                        return err(Edrawmem);
                    addflush(l.layer.?.screenr);
                    l.clipr = clipr;
                    _ = rectclip(&l.clipr, r);
                    if (drawinstall(client, dstid, l, dscrn) == null) {
                        memldelete(l);
                        return err(Edrawmem);
                    }
                    dscrn.ref += 1;
                    if (reffn) |fn_| {
                        var refx: ?*Refx = null;
                        if (fn_ == drawrefreshfn) {
                            refx = alloc.new(Refx) orelse {
                                try drawuninstall(client, dstid);
                                return err(Edrawmem);
                            };
                            refx.?.client = client;
                            refx.?.dimage = drawlookup(client, dstid, true) catch |e| {
                                alloc.free(refx);
                                return e;
                            };
                        }
                        _ = memlsetrefresh(l, fn_, refx);
                    }
                    continue;
                }
                const i = allocmemimage(r, chan) orelse
                    return err(Edrawmem);
                if (repl != 0)
                    i.flags |= memdraw_h.Frepl;
                i.clipr = clipr;
                if (repl == 0)
                    _ = rectclip(&i.clipr, r);
                if (drawinstall(client, dstid, i, null) == null) {
                    freememimage(i);
                    return err(Edrawmem);
                }
                memfillcolor(i, value);
                continue;
            },

            // DEPRECATED in favor of 'w'
            'a' => return err("deprecated draw command"),

            // allocate screen: 'A' id[4] imageid[4] fillid[4] public[1]
            'A' => {
                mfmt = "LLLb";
                printmesg(mfmt.?, a, true);
                m = try drawunpack(a, "_lllb", .{ &dstid, &ci, &ni, &value });
                if (dstid == 0)
                    return error.Ebadarg;
                if (drawlookupdscreen(dstid) != null)
                    return err(Escreenexists);
                const ddst = try drawlookup(client, ci, true);
                const dsrc = try drawlookup(client, ni, true);
                if (ddst == null or dsrc == null)
                    return err(Enodrawimage);
                if (drawinstallscreen(client, null, dstid, ddst, dsrc, @bitCast(value)) == null)
                    return err(Edrawmem);
                continue;
            },

            // set repl and clip: 'c' dstid[4] repl[1] clipR[4*4]
            'c' => {
                mfmt = "LbR";
                printmesg(mfmt.?, a, false);
                m = try drawunpack(a, "_lbR", .{ &dstid, &repl, &clipr });
                const ddst = try drawlookup(client, dstid, true) orelse
                    return err(Enodrawimage);
                if (ddst.name != null)
                    return err("cannot change repl/clipr of shared image");
                const dst = ddst.image;
                if (repl != 0)
                    dst.flags |= memdraw_h.Frepl;
                dst.clipr = clipr;
                continue;
            },

            // draw: 'd' dstid[4] srcid[4] maskid[4] R[4*4] P[2*4] P[2*4]
            'd' => {
                mfmt = "LLLRPP";
                printmesg(mfmt.?, a, false);
                m = try drawunpack(a, "_lllRPP", .{ &dstid, &ci, &ni, &r, &p, &q });
                const dst = try drawimage(client, dstid);
                const src = try drawimage(client, ci);
                const mask = try drawimage(client, ni);
                const op = drawclientop(client);
                memdraw(dst, r, src, p, mask, q, op);
                dstflush(dstid, dst, r);
                continue;
            },

            // toggle debugging: 'D' val[1]
            'D' => {
                mfmt = "b";
                printmesg(mfmt.?, a, false);
                m = try drawunpack(a, "_b", .{&value});
                continue;
            },

            // ellipse: 'e' dstid[4] srcid[4] center[2*4] a[4] b[4] thick[4] sp[2*4] alpha[4] phi[4]
            'e', 'E' => {
                mfmt = "LLPlllPll";
                printmesg(mfmt.?, a, false);
                m = try drawunpack(a, "_llPlllPll", .{ &dstid, &ci, &p, &e0, &e1, &j, &sp, &ox, &oy });
                const dst = try drawimage(client, dstid);
                const src = try drawimage(client, ci);
                if (e0 < 0 or e1 < 0)
                    return err("invalid ellipse semidiameter");
                if (j < 0)
                    return err("negative ellipse thickness");
                c = j;
                if (a[0] == 'E')
                    c = -1;
                const op = drawclientop(client);
                // high bit indicates arc angles are present
                if (ox < 0) {
                    if (ox & (1 << 30) == 0)
                        ox &= 0x7FFFFFFF;
                    memarc(dst, p, e0, e1, c, src, sp, ox, oy, op);
                } else {
                    memellipse(dst, p, e0, e1, c, src, sp, op);
                }
                dstflush(dstid, dst, .{
                    .min = .{ .x = p.x -% e0 -% j, .y = p.y -% e1 -% j },
                    .max = .{ .x = p.x +% e0 +% j +% 1, .y = p.y +% e1 +% j +% 1 },
                });
                continue;
            },

            // free: 'f' id[4]
            'f' => {
                mfmt = "L";
                printmesg(mfmt.?, a, true);
                m = try drawunpack(a, "_l", .{&dstid});
                if (try drawlookup(client, dstid, false)) |ll| {
                    if (ll.dscreen) |ds| {
                        if (ds.owner != client)
                            ds.owner.refreshme = true;
                    }
                }
                try drawuninstall(client, dstid);
                continue;
            },

            // free screen: 'F' id[4]
            'F' => {
                mfmt = "L";
                printmesg(mfmt.?, a, true);
                m = try drawunpack(a, "_l", .{&scrnid});
                _ = try drawlookupscreen(client, scrnid, &cs);
                try drawuninstallscreen(client, cs.?);
                continue;
            },

            // initialize font: 'i' fontid[4] nchars[4] ascent[1]
            'i' => {
                mfmt = "Llb";
                printmesg(mfmt.?, a, true);
                m = try drawunpack(a, "_llb", .{ &dstid, &ni, &j });
                if (dstid == 0)
                    return err("cannot use display as font");
                const font = try drawlookup(client, dstid, true) orelse
                    return err(Enodrawimage);
                if (font.image.layer != null)
                    return err("cannot use window as font");
                if (ni <= 0 or ni > 4096)
                    return err("bad font size (4096 chars max)");
                if (font.fchar) |f| alloc.free(f); // should we complain if non-zero?
                font.fchar = alloc.newslice(FChar, @intCast(ni));
                const fchar = font.fchar orelse
                    return err("no memory for font");
                @memset(fchar, .{});
                font.ascent = j;
                continue;
            },

            // load character: 'l' fontid[4] srcid[4] index[2] R[4*4] P[2*4] left[1] width[1]
            'l' => {
                mfmt = "LLSRPbb";
                printmesg(mfmt.?, a, false);
                m = try drawunpack(a, "_llsRPbb", .{ &dstid, &ni, &ci, &r, &p, &c, &j });
                const font = try drawlookup(client, dstid, true) orelse
                    return err(Enodrawimage);
                if (font.nfchar() == 0)
                    return err(Enotfont);
                const src = try drawimage(client, ni);
                if (ci < 0 or @as(usize, @intCast(ci)) >= font.nfchar())
                    return err(Eindex);
                memdraw(font.image, r, src, p, memdraw_h.memopaque, p, draw.S);
                const fc = &font.fchar.?[@intCast(ci)];
                fc.minx = r.min.x;
                fc.maxx = r.max.x;
                fc.miny = @truncate(@as(u32, @bitCast(r.min.y)));
                fc.maxy = @truncate(@as(u32, @bitCast(r.max.y)));
                fc.left = @bitCast(@as(u8, @truncate(@as(u32, @bitCast(c)))));
                fc.width = @truncate(@as(u32, @bitCast(j)));
                continue;
            },

            // draw line: 'L' dstid[4] p0[2*4] p1[2*4] end0[4] end1[4] radius[4] srcid[4] sp[2*4]
            'L' => {
                mfmt = "LPPlllLP";
                printmesg(mfmt.?, a, false);
                m = try drawunpack(a, "_lPPllllP", .{ &dstid, &p, &q, &e0, &e1, &j, &ci, &sp });
                const dst = try drawimage(client, dstid);
                if (j < 0)
                    return err("negative line width");
                const src = try drawimage(client, ci);
                const op = drawclientop(client);
                memline(dst, p, q, e0, e1, j, src, sp, op);
                // avoid memlinebbox if possible
                if (dstid == 0 or dst.layer != null) {
                    // BUG: this is terribly inefficient: update maximal containing rect
                    r = memlinebbox(p, q, e0, e1, j);
                    const d = 1 +% 1 +% j;
                    dstflush(dstid, dst, .{
                        .min = .{ .x = r.min.x -% d, .y = r.min.y -% d },
                        .max = .{ .x = r.max.x +% d, .y = r.max.y +% d },
                    });
                }
                continue;
            },

            // create image mask: 'm' newid[4] id[4]
            //
            //      case 'm':
            //              printmesg("LL", a, 0);
            //              m = drawunpack(a, n, "_ll", &dstid, &ci);
            //              break;
            //

            // attach to a named image: 'n' dstid[4] j[1] name[j]
            'n' => {
                mfmt = "Lz";
                printmesg(mfmt.?, a, false);
                var u: []const u8 = &.{};
                m = try drawunpack(a, "_lz", .{ &dstid, &u });
                if (u.len == 0) // give me a non-empty name please
                    return err(Eshortdraw);
                if (try drawlookup(client, dstid, false) != null)
                    return err(Eimageexists);
                const dn = drawlookupname(u) orelse
                    return err(Enoname);
                if (drawinstall(client, dstid, dn.dimage.image, null) == null)
                    return err(Edrawmem);
                const di = try drawlookup(client, dstid, false) orelse
                    return err("draw: cannot happen");
                di.vers = dn.vers;
                const name = alloc.snewslice(u8, u.len);
                di.fromname = dn.dimage;
                dn.dimage.ref += 1;
                @memcpy(name, u);
                di.name = name;
                client.infoid = dstid;
                continue;
            },

            // name an image: 'N' dstid[4] in[1] j[1] name[j]
            'N' => {
                mfmt = "Lbz";
                printmesg(mfmt.?, a, false);
                var u: []const u8 = &.{};
                m = try drawunpack(a, "_lbz", .{ &dstid, &c, &u });
                if (u.len == 0) // give me a non-empty name please
                    return err(Eshortdraw);
                const di = try drawlookup(client, dstid, false) orelse
                    return err(Enodrawimage);
                if (di.name != null)
                    return err(Enamed);
                if (c != 0) {
                    try drawaddname(client, di, u);
                } else {
                    const dn = drawlookupname(u) orelse
                        return err(Enoname);
                    if (dn.dimage != di)
                        return err(Ewrongname);
                    drawdelname(dn);
                }
                continue;
            },

            // position window: 'o' id[4] r.min [2*4] screenr.min [2*4]
            'o' => {
                mfmt = "LPP";
                printmesg(mfmt.?, a, false);
                m = try drawunpack(a, "_lPP", .{ &dstid, &p, &q });
                const dst = try drawimage(client, dstid);
                if (dst.layer) |layer| {
                    r = layer.screenr;
                    ni = memlorigin(dst, p, q);
                    if (ni < 0)
                        return err("image origin failed");
                    if (ni > 0) {
                        addflush(r);
                        addflush(dst.layer.?.screenr);
                        const ll = try drawlookup(client, dstid, true);
                        drawrefreshscreen(ll, client);
                    }
                }
                continue;
            },

            // set compositing operator for next draw operation: 'O' op
            'O' => {
                mfmt = "b";
                printmesg(mfmt.?, a, false);
                m = try drawunpack(a, "_b", .{&client.op});
                continue;
            },

            // filled polygon: 'P' dstid[4] n[2] wind[4] ignore[2*4] srcid[4] sp[2*4] p0[2*4] dp[2*2*n]
            // polygon: 'p' dstid[4] n[2] end0[4] end1[4] radius[4] srcid[4] sp[2*4] p0[2*4] dp[2*2*n]
            'p', 'P' => {
                mfmt = "LslllLPP";
                printmesg(mfmt.?, a, false);
                m = try drawunpack(a, "_lsllllP", .{ &dstid, &ni, &e0, &e1, &c, &ci, &sp });
                const dst = try drawimage(client, dstid);
                j = 0;
                if (a[0] == 'p') {
                    j = c;
                    if (j < 0)
                        return err("negative polygon line width");
                }
                const src = try drawimage(client, ci);
                ni += 1;
                const pp = alloc.newslice(Point, @intCast(ni)) orelse
                    return error.Enomem;
                defer alloc.free(pp);
                var doflush = false;
                if (dstid == 0 or (screenimage != null and dst.layer != null and dst.layer.?.screen.image.data == screenimage.?.data))
                    doflush = true; // simplify test in loop
                ox = 0;
                oy = 0;
                var esize: i32 = 0;
                var u = m;
                var y: usize = 0;
                while (y < pp.len) : (y += 1) {
                    q = p;
                    const oesize = esize;
                    u = try drawcoord(a, u, ox, &p.x);
                    u = try drawcoord(a, u, oy, &p.y);
                    ox = p.x;
                    oy = p.y;
                    if (doflush) {
                        esize = j;
                        if (a[0] == 'p') {
                            if (y == 0) {
                                c = memlineendsize(e0);
                                if (c > esize)
                                    esize = c;
                            }
                            if (y == pp.len - 1) {
                                c = memlineendsize(e1);
                                if (c > esize)
                                    esize = c;
                            }
                        }
                        if (a[0] == 'P' and e0 != 1 and e0 != ~@as(i32, 0)) {
                            r = dst.clipr;
                        } else if (y > 0) {
                            r = boxaround(q, oesize);
                            combinerect(&r, boxaround(p, esize));
                        }
                        if (rectclip(&r, dst.clipr)) // should perhaps be an arg to dstflush
                            dstflush(dstid, dst, r);
                    }
                    pp[y] = p;
                }
                if (y == 1)
                    dstflush(dstid, dst, boxaround(p, esize));
                const op = drawclientop(client);
                if (a[0] == 'p')
                    mempoly(dst, pp, e0, e1, j, src, sp, op)
                else
                    memfillpoly(dst, pp, e0, src, sp, op);
                m = u;
                continue;
            },

            // read: 'r' id[4] R[4*4]
            'r' => {
                mfmt = "LR";
                printmesg(mfmt.?, a, false);
                m = try drawunpack(a, "_lR", .{ &dstid, &r });
                const i = try drawimage(client, dstid);
                if (!rectinrect(r, i.r))
                    return err(Ereadoutside);
                // DIFF: rectinrect passes an inverted rectangle
                if (badrect(r))
                    return err("bad readimage call");
                c = bytesperline(r, i.depth);
                c *%= Dy(r);
                if (client.readdata) |d| alloc.free(d);
                client.readdata = null;
                if (c < 0) // DIFF: the C leaves it to mallocz to fail
                    return err("readimage malloc failed");
                const data = alloc.newslice(u8, @intCast(c)) orelse
                    return err("readimage malloc failed");
                const nreaddata = memunload(i, r, data);
                if (nreaddata < 0) {
                    alloc.free(data);
                    return err("bad readimage call");
                }
                client.readdata = data[0..@intCast(nreaddata)];
                continue;
            },

            // string: 's' dstid[4] srcid[4] fontid[4] P[2*4] clipr[4*4] sp[2*4] ni[2] ni*(index[2])
            // stringbg: 'x' dstid[4] srcid[4] fontid[4] P[2*4] clipr[4*4] sp[2*4] ni[2] bgid[4] bgpt[2*4] ni*(index[2])
            's', 'x' => {
                if (a[0] == 's') {
                    mfmt = "LLLPRPs";
                    printmesg(mfmt.?, a, false);
                    m = try drawunpack(a, "_lllPRPs", .{ &dstid, &ci, &c, &p, &r, &sp, &ni });
                } else {
                    mfmt = "LLLPRPsLP";
                    printmesg(mfmt.?, a, false);
                    m = try drawunpack(a, "_lllPRPslP", .{ &dstid, &ci, &c, &p, &r, &sp, &ni, &j, &q });
                }
                if (ni == 0)
                    continue;
                const nchars: usize = @intCast(ni);
                var u = m;
                m += nchars * 2;
                if (n < m)
                    return err(Eshortdraw);
                const dst = try drawimage(client, dstid);
                const src = try drawimage(client, ci);
                const font = try drawlookup(client, c, true) orelse
                    return err(Enodrawimage);
                if (font.nfchar() == 0)
                    return err(Enotfont);
                {
                    clipr = dst.clipr;
                    dst.clipr = r;
                    defer dst.clipr = clipr;
                    const op = drawclientop(client);
                    var bg = dst;
                    if (a[0] == 'x') {
                        // paint background
                        bg = try drawimage(client, j);
                        r.min.x = p.x;
                        r.min.y = p.y -% font.ascent;
                        r.max.x = p.x;
                        r.max.y = r.min.y +% Dy(font.image.r);
                        for (0..nchars) |k| {
                            const index: usize = BGSHORT(a[u + 2 * k ..]);
                            if (index >= font.nfchar())
                                return err(Eindex);
                            r.max.x +%= font.fchar.?[index].width;
                        }
                        memdraw(dst, r, bg, q, memdraw_h.memopaque, ZP, op);
                    }
                    q = p;
                    for (0..nchars) |_| {
                        const index: usize = BGSHORT(a[u..]);
                        if (index >= font.nfchar())
                            return err(Eindex);
                        q = drawchar(dst, bg, q, src, &sp, font, index, op);
                        u += 2;
                    }
                }
                p.y -%= font.ascent;
                dstflush(dstid, dst, .{
                    .min = .{ .x = p.x, .y = p.y },
                    .max = .{ .x = q.x, .y = p.y +% Dy(font.image.r) },
                });
                continue;
            },

            // use public screen: 'S' id[4] chan[4]
            'S' => {
                mfmt = "Ll";
                printmesg(mfmt.?, a, false);
                m = try drawunpack(a, "_ll", .{ &dstid, &chan });
                if (dstid == 0)
                    return error.Ebadarg;
                const dscrn = drawlookupdscreen(dstid) orelse
                    return err(Enodrawscreen);
                if (dscrn.public == 0 and dscrn.owner != client)
                    return err(Enodrawscreen);
                if (dscrn.screen.image.chan != chan)
                    return err("inconsistent chan");
                if (drawinstallscreen(client, dscrn, 0, null, null, 0) == null)
                    return err(Edrawmem);
                continue;
            },

            // top or bottom windows: 't' top[1] nw[2] n*id[4]
            't' => {
                mfmt = "bsL";
                printmesg(mfmt.?, a, false);
                m = try drawunpack(a, "_bs", .{ &c, &nw });
                if (nw == 0)
                    continue;
                var u = m;
                m += @as(usize, @intCast(nw)) * 4;
                if (n < m)
                    return err(Eshortdraw);
                const lp = alloc.newslice(*Memimage, @intCast(nw)) orelse
                    return error.Enomem;
                defer alloc.free(lp);
                dstid = glong(a, u);
                for (lp) |*l| {
                    l.* = try drawimage(client, glong(a, u));
                    u += 4;
                    const layer = l.*.layer orelse
                        return err("images are not windows");
                    if (layer.screen != lp[0].layer.?.screen)
                        return err("images not on same screen");
                }
                if (c != 0)
                    memltofrontn(lp)
                else
                    memltorearn(lp);
                if (screenimage != null and lp[0].layer.?.screen.image.data == screenimage.?.data) {
                    for (lp) |l|
                        addflush(l.layer.?.screenr);
                }
                const ll = try drawlookup(client, dstid, true);
                drawrefreshscreen(ll, client);
                continue;
            },

            // visible: 'v'
            'v' => {
                mfmt = "";
                printmesg(mfmt.?, a, false);
                m = 1;
                drawflush();
                continue;
            },

            // apply affine transform: 'w' dstid[4] P[2*4] R[4*4] srcid[4] P[2*4] mskid[4] P[2*4] M[3*3*4] flags[1]
            'w' => {
                mfmt = "LPRLPLPMb";
                printmesg(mfmt.?, a, false);
                m = try drawunpack(a, "_lPRlPlPMb", .{ &dstid, &p, &r, &ci, &sp, &ni, &q, &w, &value });
                const dst = try drawimage(client, dstid);
                const src = try drawimage(client, ci);
                const mask = try drawimage(client, ni);
                w.flags = @bitCast(value >> 1);
                const op = drawclientop(client);
                memlaffinewarp(dst, p, r, src, sp, mask, q, &w, value & 1 != 0, op);
                dstflush(dstid, dst, r);
                continue;
            },

            // write: 'y' id[4] R[4*4] data[x*1]
            // write from compressed data: 'Y' id[4] R[4*4] data[x*1]
            'y', 'Y' => {
                mfmt = "LR";
                printmesg(mfmt.?, a, false);
                m = try drawunpack(a, "_lR", .{ &dstid, &r });
                const dst = try drawimage(client, dstid);
                if (!rectinrect(r, dst.r))
                    return err(Ewriteoutside);
                const y = memload(dst, r, a[m..], a[0] == 'Y');
                if (y < 0)
                    return err("bad writeimage call");
                dstflush(dstid, dst, r);
                m += @intCast(y);
                continue;
            },
        }
    }
}

pub const drawdevtab: devmod.Dev = .{
    .dc = 'i',
    .name = "draw",

    .attach = drawattach,
    .walk = drawwalk,
    .stat = drawstat,
    .open = drawopen,
    .close = drawclose,
    .read = drawread,
    .write = drawwrite,
};

/// On 8 bit displays, load the default color map
pub fn drawcmap() void {
    var r: i32 = 0;
    var i: i32 = 0;
    while (r != 4) : (r += 1) {
        var v: i32 = 0;
        while (v != 4) : ({
            v += 1;
            i += 16;
        }) {
            var g: i32 = 0;
            var j: i32 = v - r;
            while (g != 4) : (g += 1) {
                var b: i32 = 0;
                while (b != 4) : ({
                    b += 1;
                    j += 1;
                }) {
                    var den = r;
                    if (g > den)
                        den = g;
                    if (b > den)
                        den = b;
                    var cr: i32 = undefined;
                    var cg: i32 = undefined;
                    var cb: i32 = undefined;
                    if (den == 0) { // divide check -- pick grey shades
                        cr = v * 17;
                        cg = cr;
                        cb = cr;
                    } else {
                        const num = 17 * (4 * den + v);
                        cr = @divTrunc(r * num, den);
                        cg = @divTrunc(g * num, den);
                        cb = @divTrunc(b * num, den);
                    }
                    _ = setcolor(
                        @intCast(i + (j & 15)),
                        @as(u32, @intCast(cr)) * 0x01010101,
                        @as(u32, @intCast(cg)) * 0x01010101,
                        @as(u32, @intCast(cb)) * 0x01010101,
                    );
                }
            }
        }
    }
}
