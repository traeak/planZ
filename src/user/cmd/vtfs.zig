//! vtfs - virtual terminals: full-screen text consoles, switched with
//! keys, as Linux's.
//!
//! usage: vtfs [-d] [-t file]
//!
//! vtfs takes the screen through /dev/draw and the keyboard through
//! /dev/kbd, and shows one of four consoles at a time.  Consoles 1 to 3
//! each run `rc -i`, started again when it exits; console 4 shows the
//! kernel's messages, read from /dev/kprint.  Ctl-Alt-Left and
//! Ctl-Alt-Right step to the previous and next console, Ctl-Alt-1 to
//! Ctl-Alt-4 go to one (see vtfs/keys.zig).  Typing is cooked as in a
//! rio window (vtfs/text.zig); PgUp and PgDn, with Shift or without,
//! scroll back and forth.  The font is $font, or
//! /lib/font/bit/vga/unicode.font.
//!
//! -t: what is written to console 1 is written to file too: the serial
//! line, as riostart's console window has it.
//! -d: say on standard error what happens: each event, each mount.
//!
//! Each console is a file server, mounted before /dev for its rc as
//! rio's windows are; the attach name is the console's number:
//!    cons      read: a typed line; written: shown
//!    consctl   rawon, rawoff, holdon, holdoff
//!    label     a name (vtfs does not show it)
//!    text      all of the console's text
//!    winid     its number
//!    wctl      read: its rectangle, "current" or "notcurrent", and
//!              "visible" or "hidden", as rio's
//!    vt/       a directory of the consoles, 1 to 4, each with the
//!              files above
//!
//! Processes: vtfs reads its inputs (/dev/kbd, /dev/kprint, the 9P
//! connection) in a process each, which hand what they read to the
//! main process through one pipe; a keeper process per shell console
//! mounts the console and runs rc, again when it exits, and reports
//! its pid; a note process sends interrupts.  Only the main process
//! changes the consoles, so nothing is locked.
//!
//! Not part of 9front: rio's window files, without the mouse.

const std = @import("std");
const libc = @import("libc");
const D = @import("draw");
const text = @import("vtfs/text.zig");
const keys = @import("vtfs/keys.zig");

const srv = libc.srv;
const fcall = libc.fcall;
const Qid = srv.Qid;
const Dir = srv.Dir;
const Req = srv.Req;
const Answer = srv.Answer;
const Rune = libc.Rune;
const a = libc.allocator;

const NCON = 4;
const KCON = 3; // the kernel's messages
const Margin = 4; // between the screen's edge and the text

// ---- the consoles

const Console = struct {
    t: text.Text,
    win: *D.Image,
    pid: u32 = 0, // its rc
    reads: std.ArrayList(Req) = .empty, // cons reads waiting for a line
    label: std.ArrayList(u8) = .empty,
    dirty: bool = true,
    kpart: text.Partial = .{}, // of /dev/kprint
};

var con: [NCON]Console = undefined;
var cur: usize = 0;

var font: *D.Font = undefined;
var textr: D.Rectangle = undefined;
var back: *D.Image = undefined;
var fore: *D.Image = undefined;
var holdcol: *D.Image = undefined;
var asciiwid: [128]i32 = undefined;

fn runewidth(_: *const anyopaque, r: Rune) i32 {
    if (r < asciiwid.len)
        return asciiwid[r];
    return D.runestringnwidth(font, &.{r}, 1);
}

fn layout() text.Layout {
    return .{
        .wid = D.Dx(textr),
        .maxlines = @intCast(@max(@divTrunc(D.Dy(textr), font.height), 1)),
        .maxtab = 4 * runewidth(undefined, '0'),
        .ctx = undefined,
        .width = runewidth,
    };
}

fn isnav(r: Rune) bool {
    return switch (r) {
        text.Kdown, text.Kup, text.Kpgdown, text.Kpgup, text.Khome, text.Kend, text.Kscrolloneup, text.Kscrollonedown => true,
        else => false,
    };
}

// ---- drawing

/// Draw console c's text from its origin, line by line.
fn paint(c: *Console) void {
    const t = &c.t;
    const img = c.win;
    const h: i32 = font.height;
    const col = if (t.holding) holdcol else fore;
    const r = t.r.items;
    var p = t.org;
    var y = textr.min.y;
    var tick: ?D.Point = null;
    var last = false;
    while (y + h <= textr.max.y) : (y += h) {
        if (last) {
            D.draw(img, D.Rect(textr.min.x, y, textr.max.x, y + h), back, null, D.ZP);
            continue;
        }
        const next = t.nextLine(p);
        const e = next orelse r.len;
        last = next == null;
        var x = textr.min.x;
        var q = p;
        while (q < e) {
            if (q == t.q0)
                tick = D.Pt(x, y);
            const ch = r[q];
            if (ch == '\n')
                break;
            if (ch == '\t') {
                const w = t.lay.runewidth(ch, x - textr.min.x);
                D.draw(img, D.Rect(x, y, x + w, y + h), back, null, D.ZP);
                x += w;
                q += 1;
                continue;
            }
            // a run with no tab or newline, as far as the cursor
            var s = q + 1;
            while (s < e and r[s] != '\t' and r[s] != '\n' and s != t.q0)
                s += 1;
            const pt = D.runestringnbg(img, D.Pt(x, y), col, D.ZP, font, r[q..s], @intCast(s - q), back, D.ZP);
            x = pt.x;
            q = s;
        }
        if (q == t.q0 or (last and t.q0 == e))
            tick = D.Pt(x, y);
        if (x < textr.max.x)
            D.draw(img, D.Rect(x, y, textr.max.x, y + h), back, null, D.ZP);
        if (next) |n| p = n;
    }
    if (y < textr.max.y)
        D.draw(img, D.Rect(textr.min.x, y, textr.max.x, textr.max.y), back, null, D.ZP);
    // the margins
    const wr = img.r;
    D.draw(img, D.Rect(wr.min.x, wr.min.y, wr.max.x, textr.min.y), back, null, D.ZP);
    D.draw(img, D.Rect(wr.min.x, textr.max.y, wr.max.x, wr.max.y), back, null, D.ZP);
    D.draw(img, D.Rect(wr.min.x, textr.min.y, textr.min.x, textr.max.y), back, null, D.ZP);
    D.draw(img, D.Rect(textr.max.x, textr.min.y, wr.max.x, textr.max.y), back, null, D.ZP);
    // rio's tick: a line with a box at each end
    if (tick) |pt| {
        if (&con[KCON] != c) {
            const x = @min(pt.x, textr.max.x - 2);
            D.draw(img, D.Rect(x, pt.y, x + 1, pt.y + h), col, null, D.ZP);
            D.draw(img, D.Rect(x - 1, pt.y, x + 2, pt.y + 3), col, null, D.ZP);
            D.draw(img, D.Rect(x - 1, pt.y + h - 3, x + 2, pt.y + h), col, null, D.ZP);
        }
    }
    c.dirty = false;
}

/// Show console n.
fn switchto(n: usize) void {
    if (n == cur)
        return;
    cur = n;
    D.topwindow(con[n].win);
    if (con[n].dirty)
        paint(&con[n]);
}

// ---- the file tree

const F = enum(u8) { dir, cons, consctl, label, text, winid, wctl, vt };
const files = [_]F{ .cons, .consctl, .label, .text, .winid, .wctl, .vt };

fn qid(c: usize, f: F) Qid {
    return .{
        .path = (@as(u64, c) << 8) | @intFromEnum(f),
        .type = if (f == .dir or f == .vt) fcall.QTDIR else fcall.QTFILE,
    };
}

fn qcon(q: Qid) usize {
    return @intCast((q.path >> 8) % NCON);
}

fn qfile(q: Qid) F {
    return std.enums.fromInt(F, @as(u8, @truncate(q.path))) orelse .dir;
}

const names = [_][]const u8{ "1", "2", "3", "4" };

const Tree = struct {
    s: *srv.Server(Tree) = undefined,
    buf: [8192]u8 = undefined,
    tbuf: ?[]u8 = null, // the last text read
    sbuf: [64]u8 = undefined,

    pub const Aux = text.Partial;

    pub fn root(_: *Tree, aname: []const u8) ?Qid {
        if (aname.len == 0)
            return qid(0, .dir);
        for (names, 0..) |n, i|
            if (std.mem.eql(u8, n, aname)) return qid(i, .dir);
        return null;
    }

    pub fn walk1(_: *Tree, q: Qid, name: []const u8) ?Qid {
        const c = qcon(q);
        switch (qfile(q)) {
            .dir => {
                if (std.mem.eql(u8, name, "..")) return q;
                for (files) |f|
                    if (std.mem.eql(u8, @tagName(f), name)) return qid(c, f);
                return null;
            },
            .vt => {
                if (std.mem.eql(u8, name, "..")) return qid(c, .dir);
                for (names, 0..) |n, i|
                    if (std.mem.eql(u8, n, name)) return qid(i, .dir);
                return null;
            },
            else => return null,
        }
    }

    pub fn stat(t: *Tree, q: Qid) ?Dir {
        const c = qcon(q);
        const f = qfile(q);
        return .{
            .qid = q,
            .mode = switch (f) {
                .dir, .vt => fcall.DMDIR | 0o555,
                .consctl => 0o200,
                .winid, .wctl => 0o400,
                else => 0o600,
            },
            .length = 0,
            .name = switch (f) {
                .dir => names[c],
                else => @tagName(f),
            },
            .uid = t.user(),
            .gid = t.user(),
            .muid = t.user(),
        };
    }

    fn user(_: *Tree) []const u8 {
        return username;
    }

    pub fn dirent(t: *Tree, q: Qid, i: usize) ?Dir {
        const c = qcon(q);
        return switch (qfile(q)) {
            .dir => if (i < files.len) t.stat(qid(c, files[i])) else null,
            .vt => if (i < NCON) t.stat(qid(i, .dir)) else null,
            else => null,
        };
    }

    pub fn open(t: *Tree, f: anytype, mode: u8) ?[]const u8 {
        const d = t.stat(f.qid).?;
        const want: u32 = switch (mode & 3) {
            0 => 4,
            1 => 2,
            2 => 6,
            else => 1,
        };
        // the files are their user's, as rio's
        if ((d.mode >> 6) & want != want) return srv.Eperm;
        f.aux = .{};
        return null;
    }

    pub fn clunk(_: *Tree, f: anytype) void {
        if (f.omode != null and qfile(f.qid) == .consctl) {
            const c = &con[qcon(f.qid)];
            c.t.ctlclose() catch {};
            c.dirty = true;
        }
    }

    pub fn read(t: *Tree, f: anytype, r: Req) Answer {
        const c = &con[qcon(f.qid)];
        switch (qfile(f.qid)) {
            .cons => {
                if (c.reads.items.len == 0 and c.t.readable())
                    return .{ .data = t.buf[0..c.t.read(t.buf[0..@min(r.count, t.buf.len)])] };
                c.reads.append(a, r) catch return .{ .err = "out of memory" };
                return .later;
            },
            .text => {
                if (t.tbuf) |b| a.free(b);
                t.tbuf = c.t.bytes(a) catch return .{ .err = "out of memory" };
                return .{ .data = from(t.tbuf.?, r.offset) };
            },
            .label => return .{ .data = from(c.label.items, r.offset) },
            .winid => return .{ .data = from(libc.sprint(&t.sbuf, "%11d ", .{qcon(f.qid) + 1}), r.offset) },
            .wctl => {
                const w = c.win.r;
                return .{ .data = from(libc.sprint(&t.sbuf, "%11d %11d %11d %11d %11s %11s ", .{
                    w.min.x,                                                    w.min.y, w.max.x, w.max.y,
                    if (c == &con[cur]) @as([]const u8, "current") else "notcurrent", if (c == &con[cur]) @as([]const u8, "visible") else "hidden",
                }), r.offset) };
            },
            else => return .{ .err = srv.Ebotch },
        }
    }

    pub fn write(_: *Tree, f: anytype, _: Req, data: []const u8) Answer {
        const ci = qcon(f.qid);
        const c = &con[ci];
        switch (qfile(f.qid)) {
            .cons, .text => {
                const rs = f.aux.runes(a, data) catch return .{ .err = "out of memory" };
                defer a.free(rs);
                c.t.write(rs) catch return .{ .err = "out of memory" };
                c.dirty = true;
                if (ci == 0 and teefd >= 0)
                    libc.writeall(teefd, data) catch {};
            },
            .consctl => {
                if (!(c.t.ctl(data) catch return .{ .err = "out of memory" }))
                    return .{ .err = "unknown control message" };
                c.dirty = true;
            },
            .label => {
                c.label.clearRetainingCapacity();
                c.label.appendSlice(a, data) catch return .{ .err = "out of memory" };
            },
            else => return .{ .err = srv.Eperm },
        }
        return .{ .count = @intCast(data.len) };
    }

    pub fn flush(_: *Tree, r: Req) void {
        for (&con) |*c| {
            for (c.reads.items, 0..) |q, i| {
                if (q.tag == r.tag) {
                    _ = c.reads.orderedRemove(i);
                    return;
                }
            }
        }
    }

    fn from(s: []const u8, off: i64) []const u8 {
        const o: usize = @intCast(std.math.clamp(off, 0, @as(i64, @intCast(s.len))));
        return s[o..];
    }

    /// Answer the cons reads that can be answered now.
    fn pump(t: *Tree) void {
        for (&con) |*c| {
            while (c.reads.items.len > 0 and c.t.readable()) {
                const r = c.reads.orderedRemove(0);
                const n = c.t.read(t.buf[0..@min(r.count, t.buf.len)]);
                _ = t.s.respondRead(r.tag, t.buf[0..n]);
                c.dirty = true;
            }
        }
    }
};

var username: []const u8 = "none";
var debug = false;
var teefd: i32 = -1;

// ---- the processes

/// What the readers and keepers tell the main process: one write each,
/// a type, a length (2 bytes, little-endian) and the data.
const Ev = enum(u8) { nine = '9', kbd = 'k', kprint = 'p', started = 's', exited = 'x' };

var evbuf: [3 + srv.MAXMSG]u8 = undefined;

fn sendev(fd: i32, e: Ev, data: []const u8) void {
    var b: [3 + srv.MAXMSG]u8 = undefined;
    const n = @min(data.len, srv.MAXMSG);
    b[0] = @intFromEnum(e);
    std.mem.writeInt(u16, b[1..3], @intCast(n), .little);
    @memcpy(b[3..][0..n], data[0..n]);
    _ = libc.write(fd, b[0 .. 3 + n]) catch libc.exits("event pipe");
}

fn readev(fd: i32) struct { e: u8, data: []u8 } {
    if ((libc.readn(fd, evbuf[0..3]) catch 0) != 3)
        libc.sysfatal("event pipe: %r", .{});
    const n = std.mem.readInt(u16, evbuf[1..3], .little);
    if ((libc.readn(fd, evbuf[3..][0..n]) catch 0) != n)
        libc.sysfatal("event pipe: %r", .{});
    return .{ .e = evbuf[0], .data = evbuf[3..][0..n] };
}

/// A process that reads a file and hands each read on.
fn reader(evfd: i32, e: Ev, path: ?[]const u8, fd_: i32) void {
    const pid = libc.fork() catch libc.sysfatal("fork: %r", .{});
    if (pid != 0)
        return;
    const fd = if (path) |p| libc.open(p, libc.OREAD) catch {
        libc.fprint(2, "vtfs: %s: %r\n", .{p});
        libc.exits("open");
    } else fd_;
    var buf: [srv.MAXMSG]u8 = undefined;
    while (true) {
        const n = (if (e == .nine) libc.read9pmsg(fd, &buf) else libc.read(fd, &buf)) catch 0;
        if (n == 0) {
            libc.fprint(2, "vtfs: reading %s: %r\n", .{path orelse "9P"});
            sendev(evfd, e, "");
            libc.exits(null);
        }
        sendev(evfd, e, buf[0..n]);
    }
}

/// A process that sends an interrupt to the note group of each pid
/// written to fd, so that the main process never waits on a dying
/// process (rio's interruptproc).
fn noter(fd: i32) void {
    const pid = libc.fork() catch libc.sysfatal("fork: %r", .{});
    if (pid != 0)
        return;
    var b: [4]u8 = undefined;
    while ((libc.readn(fd, &b) catch 0) == 4)
        libc.postnote(libc.PNGROUP, std.mem.readInt(u32, &b, .little), "interrupt") catch {};
    libc.exits(null);
}

/// The process that keeps an rc running on shell console c: in a name
/// space of its own with the console before /dev, and an environment
/// of its own (rio's winshell).  Each rc has a note group of its own.
fn keeper(c: usize, mfd: i32, evfd: i32, closefds: []const i32) void {
    const pid = libc.rfork(libc.sys.RFPROC | libc.sys.RFFDG | libc.sys.RFNAMEG | libc.sys.RFENVG | libc.sys.RFREND) catch
        libc.sysfatal("fork: %r", .{});
    if (pid != 0)
        return;
    for (closefds) |fd| libc.close(fd) catch {};
    libc.mount(mfd, -1, "/dev", libc.sys.MBEFORE, names[c]) catch {
        libc.fprint(2, "vtfs: mount console %s: %r\n", .{names[c]});
        libc.exits("mount");
    };
    libc.close(mfd) catch {};
    if (debug) libc.fprint(2, "vtfs: console %s mounted\n", .{names[c]});
    var b: [16]u8 = undefined;
    while (true) {
        const t0 = libc.nsec();
        const rc = libc.rfork(libc.sys.RFPROC | libc.sys.RFCFDG | libc.sys.RFNOTEG | libc.sys.RFREND) catch {
            libc.sleep(1000) catch {};
            continue;
        };
        if (rc == 0) {
            _ = libc.open("/dev/cons", libc.OREAD) catch libc.exits("cons");
            _ = libc.open("/dev/cons", libc.OWRITE) catch libc.exits("cons");
            _ = libc.dup(1, 2) catch {};
            libc.exec("/bin/rc", &.{ "rc", "-i" }) catch {};
            libc.fprint(2, "vtfs: exec rc: %r\n", .{});
            libc.exits("exec");
        }
        sendev(evfd, .started, libc.sprint(&b, "%d %d", .{ c, rc }));
        while (true) {
            const w = libc.wait() catch break;
            if (w.pid == rc)
                break;
        }
        sendev(evfd, .exited, libc.sprint(&b, "%d", .{c}));
        // an rc that cannot start must not spin
        if (libc.nsec() - t0 < 1_000_000_000)
            libc.sleep(1000) catch {};
    }
}

fn usage() noreturn {
    libc.fprint(2, "usage: vtfs [-d] [-t file]\n", .{});
    libc.exits("usage");
}

pub fn main() void {
    var args = libc.argv[1..];
    var tee: ?[]const u8 = null;
    while (args.len > 0 and args[0].len > 1 and args[0][0] == '-') {
        if (std.mem.eql(u8, args[0], "-d")) {
            debug = true;
            args = args[1..];
        } else if (std.mem.eql(u8, args[0], "-t") and args.len > 1) {
            tee = args[1];
            args = args[2..];
        } else usage();
    }
    if (args.len != 0)
        usage();
    if (tee) |f|
        teefd = libc.open(f, libc.OWRITE) catch libc.sysfatal("%s: %r", .{f});

    if (libc.getenv(a, "user") catch null) |u| username = u;

    const fontname = (libc.getenv(a, "font") catch null) orelse "/lib/font/bit/vga/unicode.font";
    D.initdraw(null, fontname, null) catch libc.sysfatal("initdraw: %r", .{});
    const d = D.display.?;
    font = D.font.?;
    // The mouse is no use here: while vtfs holds /dev/cursor open with
    // an empty cursor, the kernel draws none.
    if (libc.open("/dev/cursor", libc.OWRITE | libc.OCEXEC)) |fd| {
        const empty: [2 * 4 + 2 * 2 * 16]u8 = @splat(0);
        _ = libc.write(fd, &empty) catch {};
    } else |_| {}
    const whole = D.screen.?.r;
    textr = D.insetrect(whole, Margin);
    back = d.white;
    fore = d.black;
    holdcol = D.allocimage(d, D.Rect(0, 0, 1, 1), d.screenimage.?.chan, true, D.DMedblue) catch libc.sysfatal("allocimage: %r", .{});
    for (&asciiwid, 0..) |*w, i| {
        const r: Rune = @intCast(i);
        w.* = D.runestringnwidth(font, &.{r}, 1);
    }
    for (&con) |*c| {
        c.* = .{
            .t = .{ .a = a, .lay = layout() },
            .win = D.allocwindow(D._screen.?, whole, D.Refbackup, D.DWhite) catch libc.sysfatal("allocwindow: %r", .{}),
        };
    }
    D.topwindow(con[0].win);
    paint(&con[0]);
    D.flushimage(d, true) catch {};

    // 9P: the mount side and the server side
    const sp = libc.pipe() catch libc.sysfatal("pipe: %r", .{});
    const ev = libc.pipe() catch libc.sysfatal("pipe: %r", .{});
    const np = libc.pipe() catch libc.sysfatal("pipe: %r", .{});
    reader(ev[1], .kbd, "/dev/kbd", -1);
    reader(ev[1], .kprint, "/dev/kprint", -1);
    reader(ev[1], .nine, null, sp[1]);
    noter(np[0]);
    for (0..NCON) |c| {
        if (c != KCON)
            keeper(c, sp[0], ev[1], &.{ sp[1], ev[0], np[0], np[1] });
    }
    libc.close(sp[0]) catch {};
    libc.close(np[0]) catch {};
    libc.close(ev[1]) catch {};
    const sfd = sp[1];
    const notefd = np[1];

    var tree: Tree = .{};
    const Out = struct {
        fn send(ctx: *anyopaque, msg: []const u8) void {
            const fd: *const i32 = @ptrCast(@alignCast(ctx));
            libc.writeall(fd.*, msg) catch libc.sysfatal("9P: %r", .{});
        }
    };
    var sfdv = sfd;
    var s = srv.Server(Tree).init(&tree, .{ .ctx = &sfdv, .send = Out.send }, a);
    tree.s = &s;
    var k: keys.Keys = .{ .nconsole = NCON };

    while (true) {
        const e = readev(ev[0]);
        if (debug) libc.fprint(2, "vtfs: event %c %d\n", .{ e.e, e.data.len });
        switch (std.enums.fromInt(Ev, e.e) orelse continue) {
            .nine => {
                if (e.data.len == 0)
                    libc.sysfatal("9P connection closed", .{});
                s.handle(e.data);
            },
            .kbd => {
                if (e.data.len == 0)
                    libc.sysfatal("no keyboard", .{});
                var it = keys.split(e.data);
                while (it.next()) |m| {
                    switch (k.msg(m)) {
                        .none => {},
                        .prev => switchto((cur + NCON - 1) % NCON),
                        .next => switchto((cur + 1) % NCON),
                        .go => |n| switchto(n),
                        .key => |kk| {
                            const c = &con[cur];
                            if (cur == KCON and !isnav(kk.r))
                                continue;
                            const act = c.t.key(kk.r, kk.shift) catch .none;
                            c.dirty = true;
                            if (act == .interrupt and c.pid != 0) {
                                var b: [4]u8 = undefined;
                                std.mem.writeInt(u32, &b, c.pid, .little);
                                libc.writeall(notefd, &b) catch {};
                            }
                        },
                    }
                }
            },
            .kprint => {
                if (e.data.len == 0)
                    continue;
                const c = &con[KCON];
                const rs = c.kpart.runes(a, e.data) catch continue;
                defer a.free(rs);
                c.t.write(rs) catch {};
                c.dirty = true;
            },
            .started => {
                var f: [2][]u8 = undefined;
                if (libc.tokenize(e.data, &f) == 2)
                    con[@intCast(libc.atoi(f[0]))].pid = @intCast(libc.atoi(f[1]));
            },
            .exited => {
                con[@intCast(libc.atoi(e.data))].pid = 0;
            },
        }
        tree.pump();
        if (con[cur].dirty) {
            paint(&con[cur]);
        }
        D.flushimage(d, true) catch {};
    }
}
