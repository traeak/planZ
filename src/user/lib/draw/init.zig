//! Connecting to /dev/draw: the display, the program's window, and the
//! buffer of draw messages.
//! From /sys/src/libdraw/init.c (9front 11952).
//!
//! DIFF:
//!   - fontname, label, dev and win are optional slices; the error
//!     function takes the message as a slice.
//!   - geninitdraw, gengetwindow and getwindow return an error union
//!     for C's -1 and 1; initdisplay returns the Display or an error.
//!   - flushimage of no display does nothing, as the C's returns 0.
//!   - bufimage returns the slice of the n bytes it gives out;
//!     _bufimageop the slice after the op's two bytes.
//!   - The Display's locks, lockdisplay, unlockdisplay, rlockdisplay,
//!     runlockdisplay, _lockdisplay and _unlockdisplay are left out
//!     (see libdraw.zig).
//!   - fmtinstall('P'/'R') is left out: %P and %R are the fmt9 methods
//!     of Point and Rectangle.
//!   - oldlabel keeps its length (noldlabel).
//!   - The name in /env/font ends at its first NUL, as the C's string
//!     does (rc ends each element of a variable with one).

const std = @import("std");
const libc = @import("libc");
const D = @import("libdraw.zig");
const Display = D.Display;
const Image = D.Image;
const Screen = D.Screen;
const Subfont = D.Subfont;
const Error = D.Error;

const deffontname = "*default*";

const ErrorFn = *const fn (*Display, []const u8) void;

// note handler
fn drawshutdown() void {
    if (D.display) |d| {
        D.display = null;
        _closedisplay(d, true);
    }
}

pub fn geninitdraw(devdir: []const u8, @"error": ?ErrorFn, fontname_: ?[]const u8, label: ?[]const u8, windir: []const u8, ref: i32) Error!void {
    var fontname = fontname_;
    var buf: [128]u8 = undefined;

    const d = try initdisplay(devdir, windir, @"error");
    D.display = d;
    errdefer {
        closedisplay(d);
        D.display = null;
    }

    //
    // Set up default font
    //
    const df = try D.getdefont(d);
    d.defaultsubfont = df;
    if (fontname == null) {
        if (libc.open("/env/font", libc.OREAD | libc.OCEXEC)) |fd| {
            const n = libc.read(fd, &buf) catch 0;
            if (n > 0 and n < buf.len - 1)
                fontname = buf[0 .. std.mem.indexOfScalar(u8, buf[0..n], 0) orelse n];
            libc.close(fd) catch {};
        } else |_| {}
    }
    //
    // Build fonts with caches==depth of screen, for speed.
    // If conversion were faster, we'd use 0 and save memory.
    //
    if (fontname) |name| {
        D.font = try D.openfont(d, name); // BUG: grey fonts
    } else {
        const s = libc.sprint(&buf, "%d %d\n0 %d\t%s\n", .{ df.height, df.ascent, df.n - 1, deffontname });
        //BUG: Need something better for this installsubfont("*default*", df);
        D.font = try D.buildfont(d, s, deffontname);
    }
    d.defaultfont = D.font;

    //
    // Write label; ignore errors (we might not be running under rio)
    //
    if (label) |l| {
        const path = libc.sprint(&buf, "%s/label", .{d.windir});
        if (libc.open(path, libc.OREAD | libc.OCEXEC)) |fd| {
            d.noldlabel = libc.read(fd, d.oldlabel[0 .. d.oldlabel.len - 1]) catch 0;
            libc.close(fd) catch {};
            if (libc.create(path, libc.OWRITE | libc.OCEXEC, 0o666)) |wfd| {
                _ = libc.write(wfd, l) catch {};
                libc.close(wfd) catch {};
            } else |_| {}
        } else |_| {}
    }

    const winname = libc.sprint(&buf, "%s/winname", .{d.windir});
    try gengetwindow(d, winname, &D.screen, &D._screen, ref);

    _ = libc.atexit(drawshutdown);
}

pub fn initdraw(@"error": ?ErrorFn, fontname: ?[]const u8, label: ?[]const u8) Error!void {
    const dev = "/dev";
    return geninitdraw(dev, @"error", fontname, label, dev, D.Refnone);
}

//
// Attach, or possibly reattach, to window.
// If reattaching, maintain value of screen pointer.
//
pub fn gengetwindow(d: *Display, winname: []const u8, winp: *?*Image, scrp: *?*Screen, ref: i32) Error!void {
    var buf: [64 + 1]u8 = undefined;
    var obuf: [64 + 1]u8 = undefined;
    var nbuf: usize = 0;
    var nobuf: usize = 0;
    var image: ?*Image = null;

    while (true) { // retry:
        const fd = libc.open(winname, libc.OREAD | libc.OCEXEC) catch -1;
        const n = if (fd < 0) 0 else libc.read(fd, buf[0 .. buf.len - 1]) catch 0;
        if (fd < 0 or n <= 0) {
            if (fd >= 0) libc.close(fd) catch {};
            @memcpy(buf[0..8], "noborder");
            nbuf = 8;
            image = d.image;
        } else {
            libc.close(fd) catch {};
            nbuf = n;
            image = D.namedimage(d, buf[0..nbuf]) catch null;
            if (image == null) {
                //
                // theres a race where the winname can change after
                // we read it, so keep trying as long as the name
                // keeps changing.
                //
                if (!std.mem.eql(u8, buf[0..nbuf], obuf[0..nobuf])) {
                    @memcpy(obuf[0..nbuf], buf[0..nbuf]);
                    nobuf = nbuf;
                    continue;
                }
            }
        }
        break;
    }
    if (winp.*) |w| {
        D._freeimage1(w) catch {};
        if (scrp.*.?.image != d.image)
            D.freeimage(scrp.*.?.image) catch {};
        D.freescreen(scrp.*) catch {};
        scrp.* = null;
    }
    const img = image orelse {
        winp.* = null;
        d.screenimage = null;
        return error.Plan9;
    };
    d.screenimage = img;
    scrp.* = D.allocscreen(img, d.white, false) catch {
        winp.* = null;
        d.screenimage = null;
        if (@as(?*Image, img) != d.image)
            D.freeimage(img) catch {};
        return error.Plan9;
    };
    var r = img.r;
    if (!std.mem.startsWith(u8, buf[0..nbuf], "noborder"))
        r = D.insetrect(r, D.Borderwidth);
    winp.* = D._allocwindow(winp.*, scrp.*.?, r, ref, D.DWhite) catch {
        D.freescreen(scrp.*) catch {};
        scrp.* = null;
        d.screenimage = null;
        if (@as(?*Image, img) != d.image)
            D.freeimage(img) catch {};
        return error.Plan9;
    };
    d.screenimage = winp.*;
}

pub fn getwindow(d: *Display, ref: i32) Error!void {
    var winname: [128]u8 = undefined;
    return gengetwindow(d, libc.sprint(&winname, "%s/winname", .{d.windir}), &D.screen, &D._screen, ref);
}

const NINFO = 12 * 12;

/// A number in a 12-byte field of devdraw's text.
fn field(info: []const u8, i: usize) i32 {
    return @truncate(libc.atoi(info[i * 12 ..]));
}

pub fn initdisplay(dev_: ?[]const u8, win_: ?[]const u8, @"error": ?ErrorFn) Error!*Display {
    var buf: [128]u8 = undefined;
    var info: [NINFO + 1]u8 = undefined;
    const a = libc.allocator;

    const dev = dev_ orelse "/dev";
    const win = win_ orelse "/dev";
    if (dev.len > buf.len - 25 or win.len > buf.len - 25) {
        libc.werrstr("initdisplay: directory name too long", .{});
        return error.Plan9;
    }
    const t = a.dupe(u8, win) catch return D.nomem();
    errdefer a.free(t);

    var path = libc.sprint(&buf, "%s/draw/new", .{dev});
    errdefer libc.werrstr("initdisplay: %s: %r", .{path});
    const ctlfd = try libc.open(path, libc.ORDWR | libc.OCEXEC);
    errdefer libc.close(ctlfd) catch {};
    var n = libc.read(ctlfd, &info) catch 0;
    if (n < 12)
        return error.Plan9;
    if (n == NINFO + 1)
        n = NINFO;
    var isnew = false;
    if (n < NINFO) // this will do for now, we need something better here
        isnew = true;
    const infos = info[0..n];
    const dirno = field(infos, 0);
    path = libc.sprint(&buf, "%s/draw/%d/data", .{ dev, dirno });
    const datafd = try libc.open(path, libc.ORDWR | libc.OCEXEC);
    errdefer libc.close(datafd) catch {};
    path = libc.sprint(&buf, "%s/draw/%d/refresh", .{ dev, dirno });
    const reffd = try libc.open(path, libc.OREAD | libc.OCEXEC);
    errdefer libc.close(reffd) catch {};
    const disp = a.create(Display) catch return D.nomem();
    disp.* = .{};
    errdefer a.destroy(disp);
    var image: ?*Image = null;
    errdefer if (image) |i| a.destroy(i);
    if (n >= NINFO) {
        const i = a.create(Image) catch return D.nomem();
        image = i;
        i.* = .{ .display = disp };
        i.id = 0;
        i.chan = D.strtochan(infos[2 * 12 ..]);
        i.depth = D.chantodepth(i.chan);
        i.repl = field(infos, 3) != 0;
        i.r.min.x = field(infos, 4);
        i.r.min.y = field(infos, 5);
        i.r.max.x = field(infos, 6);
        i.r.max.y = field(infos, 7);
        i.clipr.min.x = field(infos, 8);
        i.clipr.min.y = field(infos, 9);
        i.clipr.max.x = field(infos, 10);
        i.clipr.max.y = field(infos, 11);
    }

    disp._isnewdisplay = isnew;
    disp.bufsize = @intCast(@min(libc.iounit(datafd), std.math.maxInt(i32)));
    if (disp.bufsize <= 0)
        disp.bufsize = 8000;
    if (disp.bufsize < 512) {
        libc.werrstr("iounit %d too small", .{disp.bufsize});
        return error.Plan9;
    }
    disp.buf = a.alloc(u8, @as(usize, @intCast(disp.bufsize)) + 5) catch return D.nomem(); // +5 for flush message
    errdefer a.free(disp.buf);

    disp.image = image;
    disp.dirno = dirno;
    disp.fd = datafd;
    disp.ctlfd = ctlfd;
    disp.reffd = reffd;
    disp.bufp = 0;
    disp.@"error" = @"error";
    disp.windir = t;
    disp.devdir = a.dupe(u8, dev) catch return D.nomem();
    errdefer a.free(disp.devdir);
    const white = try D.allocimage(disp, D.Rect(0, 0, 1, 1), D.GREY1, true, D.DWhite);
    errdefer a.destroy(white);
    const black = try D.allocimage(disp, D.Rect(0, 0, 1, 1), D.GREY1, true, D.DBlack);
    disp.white = white;
    disp.black = black;
    disp.@"opaque" = disp.white;
    disp.transparent = disp.black;
    if (libc.dirfstat(a, ctlfd)) |st| {
        var s = st;
        if (s.dir.type == 'i') {
            disp.local = true;
            disp.dataqid = @truncate(s.dir.qid.path);
        }
        if (s.dir.qid.vers == 1) // other way to tell
            disp._isnewdisplay = true;
        s.deinit(a);
    } else |_| {}

    return disp;
}

//
// Note that disp.defaultfont and defaultsubfont are not freed here.
//
pub fn closedisplay(disp: ?*Display) void {
    _closedisplay(disp, false);
}

fn _closedisplay(disp_: ?*Display, isshutdown: bool) void {
    var buf: [128]u8 = undefined;
    const a = libc.allocator;

    const disp = disp_ orelse return;
    if (disp == D.display)
        D.display = null;
    if (disp.noldlabel > 0) {
        const path = libc.sprint(&buf, "%s/label", .{disp.windir});
        if (libc.open(path, libc.OWRITE | libc.OCEXEC)) |fd| {
            _ = libc.write(fd, disp.oldlabel[0..disp.noldlabel]) catch {};
            libc.close(fd) catch {};
        } else |_| {}
    }

    //
    // if we're shutting down, don't free all the resources.
    // if other procs are getting shot down by notes too,
    // one might get shot down while holding the malloc lock.
    // just let the kernel clean things up when we exit.
    //
    if (isshutdown)
        return;

    a.free(disp.devdir);
    a.free(disp.windir);
    D.freeimage(disp.white) catch {};
    D.freeimage(disp.black) catch {};
    libc.close(disp.fd) catch {};
    libc.close(disp.ctlfd) catch {};
    // should cause refresh slave to shut down
    libc.close(disp.reffd) catch {};
    a.free(disp.buf);
    a.destroy(disp);
}

pub fn drawerror(d: ?*Display, s: []const u8) void {
    if (d) |disp| {
        if (disp.@"error") |f| {
            f(disp, s);
            return;
        }
    }
    libc.fprint(2, "draw: %s: %r\n", .{s});
    libc.exits(s);
}

fn doflush(d: *Display) Error!void {
    const n = d.bufp;
    if (n <= 0)
        return;

    const w = libc.write(d.fd, d.buf[0..n]) catch 0;
    d.bufp = 0; // on error: might as well; chance of continuing
    if (w != n)
        return error.Plan9;
}

pub fn flushimage(d_: ?*Display, visible: bool) Error!void {
    const d = d_ orelse return;
    if (visible) {
        d.buf[d.bufp] = 'v'; // five bytes always reserved for this
        d.bufp += 1;
        if (d._isnewdisplay) {
            D.BPLONG(d.buf[d.bufp..], @bitCast(d.screenimage.?.id));
            d.bufp += 4;
        }
    }
    return doflush(d);
}

pub fn bufimage(d: *Display, n: usize) Error![]u8 {
    const size: usize = @intCast(d.bufsize);
    if (n > size) {
        libc.werrstr("bad count in bufimage", .{});
        return error.Plan9;
    }
    if (d.bufp + n > size)
        try doflush(d);
    const p = d.bufp;
    d.bufp += n;
    return d.buf[p..][0..n];
}

pub fn _bufimageop(d: *Display, n: usize, op: D.Drawop) Error![]u8 {
    if (op != D.SoverD) {
        const a = try bufimage(d, 1 + 1 + n);
        a[0] = 'O';
        a[1] = @intCast(op);
        return a[2..];
    }
    return bufimage(d, n);
}
