//! Screens and the windows on them.
//! From /sys/src/libdraw/window.c (9front 11952).
//!
//! DIFF:
//!   - public and top are bools.
//!   - freescreen and originwindow return an error union for the C's
//!     -1 and 0; bottomnwindows and topnwindows take a slice.
//!   - allocscreen's assert that the image has a channel is left out:
//!     an Image always has one.

const libc = @import("libc");
const D = @import("libdraw.zig");
const Display = D.Display;
const Image = D.Image;
const Screen = D.Screen;
const Rectangle = D.Rectangle;
const Point = D.Point;
const Error = D.Error;
const BPLONG = D.BPLONG;

var screenid: i32 = 0;

pub fn allocscreen(image: *Image, fill: *Image, public: bool) Error!*Screen {
    const d = image.display;
    if (d != fill.display) {
        libc.werrstr("allocscreen: image and fill on different displays", .{});
        return error.Plan9;
    }
    const s = libc.allocator.create(Screen) catch return D.nomem();
    if (screenid == 0)
        screenid = @bitCast(libc.getpid());
    var id: i32 = 0;
    var try_: i32 = 0;
    while (try_ < 25) : (try_ += 1) {
        // loop until we find a free id
        const a = D.bufimage(d, 1 + 4 + 4 + 4 + 1) catch break;
        screenid +%= 1;
        id = screenid & 0xffff; // old devdraw bug
        a[0] = 'A';
        BPLONG(a[1..], @bitCast(id));
        BPLONG(a[5..], @bitCast(image.id));
        BPLONG(a[9..], @bitCast(fill.id));
        a[13] = @intFromBool(public);
        if (D.flushimage(d, false)) |_| {
            s.* = .{ .display = d, .id = id, .image = image, .fill = fill };
            return s;
        } else |_| {}
    }
    libc.allocator.destroy(s);
    return error.Plan9;
}

pub fn publicscreen(d: *Display, id: i32, chan: u32) Error!*Screen {
    const s = libc.allocator.create(Screen) catch return D.nomem();
    errdefer libc.allocator.destroy(s);
    const a = try D.bufimage(d, 1 + 4 + 4);
    a[0] = 'S';
    BPLONG(a[1..], @bitCast(id));
    BPLONG(a[5..], chan);
    try D.flushimage(d, false);

    s.* = .{ .display = d, .id = id, .image = null, .fill = null };
    return s;
}

pub fn freescreen(s_: ?*Screen) Error!void {
    const s = s_ orelse return;
    const d = s.display;
    defer libc.allocator.destroy(s);
    const a = try D.bufimage(d, 1 + 4);
    a[0] = 'F';
    BPLONG(a[1..], @bitCast(s.id));
}

pub fn allocwindow(s: *Screen, r: Rectangle, ref: i32, col: u32) Error!*Image {
    return _allocwindow(null, s, r, ref, col);
}

pub fn _allocwindow(ai: ?*Image, s: *Screen, r: Rectangle, ref: i32, col: u32) Error!*Image {
    const d = s.display;
    const i = try D._allocimage(ai, d, r, d.screenimage.?.chan, false, col, s.id, ref);
    i.screen = s;
    i.next = d.windows;
    d.windows = i;
    return i;
}

fn topbottom(w: []const *Image, top: bool) void {
    const n = w.len;
    if (n == 0)
        return;
    if (n > @divTrunc(w[0].display.bufsize - 100, 4)) {
        // Ridiculous:
        libc.fprint(2, "top/bottom: ridiculous number of windows\n", .{});
        return;
    }
    //
    // this used to check that all images were on the same screen.
    // we don't know the screen associated with images we acquired
    // by name.  instead, check that all images are on the same display.
    // the display will check that they are all on the same screen.
    //
    const d = w[0].display;
    for (w[1..]) |wi|
        if (wi.display != d) {
            libc.fprint(2, "top/bottom: windows not on same screen\n", .{});
            return;
        };

    const b = D.bufimage(d, 1 + 1 + 2 + 4 * n) catch return;
    b[0] = 't';
    b[1] = @intFromBool(top);
    D.BPSHORT(b[2..], @intCast(n));
    for (w, 0..) |wi, i|
        BPLONG(b[4 + 4 * i ..], @bitCast(wi.id));
}

pub fn bottomwindow(w: *Image) void {
    if (w.screen != null)
        topbottom(&.{w}, false);
}

pub fn topwindow(w: *Image) void {
    if (w.screen != null)
        topbottom(&.{w}, true);
}

pub fn bottomnwindows(w: []const *Image) void {
    topbottom(w, false);
}

pub fn topnwindows(w: []const *Image) void {
    topbottom(w, true);
}

pub fn originwindow(w: *Image, log: Point, scr: Point) Error!void {
    const b = try D.bufimage(w.display, 1 + 4 + 2 * 4 + 2 * 4);
    b[0] = 'o';
    BPLONG(b[1..], @bitCast(w.id));
    BPLONG(b[5..], @bitCast(log.x));
    BPLONG(b[9..], @bitCast(log.y));
    BPLONG(b[13..], @bitCast(scr.x));
    BPLONG(b[17..], @bitCast(scr.y));
    const delta = D.subpt(log, w.r.min);
    w.r = D.rectaddpt(w.r, delta);
    w.clipr = D.rectaddpt(w.clipr, delta);
}
