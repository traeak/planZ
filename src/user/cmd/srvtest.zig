//! srvtest - a small file server on the library's srv.zig, for the
//! guest's check of it (usbzig.rc).
//!
//! usage: srvtest name
//!
//! Posts /srv/name and serves, until "exit" is written to ctl:
//!    hello    "hello, world\n"
//!    note    what was last written to it (up to 1K)
//!    wait    a read at offset 0 waits until something is written to go,
//!            and gets it; a read past it is the end of the file
//!    go    written to: answers every read of wait
//!    ctl    "exit" stops the server
//!
//! Not part of 9front.

const std = @import("std");
const libc = @import("libc");
const srv = libc.srv;
const fcall = libc.fcall;

const Qid = srv.Qid;
const Dir = srv.Dir;
const Req = srv.Req;
const Answer = srv.Answer;

const Q = enum(u64) { root, hello, note, wait, go, ctl };
const files = [_]Q{ .hello, .note, .wait, .go, .ctl };

const Tree = struct {
    s: *srv.Server(Tree) = undefined,
    note: [1024]u8 = undefined,
    nnote: usize = 0,
    waiting: std.ArrayList(u16) = .empty,
    done: bool = false,

    fn qid(q: Q) Qid {
        return .{ .path = @intFromEnum(q), .type = if (q == .root) fcall.QTDIR else fcall.QTFILE };
    }

    pub fn root(_: *Tree) Qid {
        return qid(.root);
    }

    pub fn walk1(_: *Tree, q: Qid, name: []const u8) ?Qid {
        if (q.path != @intFromEnum(Q.root)) return null;
        if (std.mem.eql(u8, name, "..")) return qid(.root);
        for (files) |f|
            if (std.mem.eql(u8, @tagName(f), name)) return qid(f);
        return null;
    }

    pub fn stat(t: *Tree, q: Qid) ?Dir {
        const f = std.enums.fromInt(Q, q.path) orelse return null;
        return .{
            .qid = q,
            .mode = switch (f) {
                .root => fcall.DMDIR | 0o555,
                .hello => 0o444,
                .go, .ctl => 0o222,
                else => 0o666,
            },
            .length = if (f == .note) @intCast(t.nnote) else if (f == .hello) 13 else 0,
            .name = if (f == .root) "/" else @tagName(f),
            .uid = "zig",
            .gid = "zig",
            .muid = "zig",
        };
    }

    pub fn dirent(t: *Tree, q: Qid, i: usize) ?Dir {
        if (q.path != @intFromEnum(Q.root) or i >= files.len) return null;
        return t.stat(qid(files[i]));
    }

    pub fn open(t: *Tree, f: anytype, mode: u8) ?[]const u8 {
        const d = t.stat(f.qid).?;
        const want: u32 = switch (mode & 3) {
            0 => 4,
            1 => 2,
            2 => 6,
            else => 1,
        };
        if (d.mode & want != want) return srv.Eperm;
        return null;
    }

    pub fn read(t: *Tree, f: anytype, r: Req) Answer {
        return switch (std.enums.fromInt(Q, f.qid.path).?) {
            .hello => .{ .data = from("hello, world\n", r.offset) },
            .note => .{ .data = from(t.note[0..t.nnote], r.offset) },
            .wait => blk: {
                if (r.offset > 0) break :blk .{ .data = "" };
                t.waiting.append(libc.allocator, r.tag) catch break :blk .{ .err = "out of memory" };
                break :blk .later;
            },
            else => .{ .err = srv.Ebotch },
        };
    }

    pub fn write(t: *Tree, f: anytype, _: Req, data: []const u8) Answer {
        switch (std.enums.fromInt(Q, f.qid.path).?) {
            .note => {
                const n = @min(data.len, t.note.len);
                @memcpy(t.note[0..n], data[0..n]);
                t.nnote = n;
                return .{ .count = @intCast(n) };
            },
            .go => {
                for (t.waiting.items) |tag|
                    _ = t.s.respondRead(tag, data);
                t.waiting.clearRetainingCapacity();
                return .{ .count = @intCast(data.len) };
            },
            .ctl => {
                if (!std.mem.eql(u8, std.mem.trimEnd(u8, data, "\n"), "exit"))
                    return .{ .err = "bad control message" };
                t.done = true;
                return .{ .count = @intCast(data.len) };
            },
            else => return .{ .err = srv.Eperm },
        }
    }

    pub fn flush(t: *Tree, r: Req) void {
        for (t.waiting.items, 0..) |tag, i| {
            if (tag == r.tag) {
                _ = t.waiting.swapRemove(i);
                break;
            }
        }
    }

    fn from(s: []const u8, off: i64) []const u8 {
        const o: usize = @intCast(std.math.clamp(off, 0, @as(i64, @intCast(s.len))));
        return s[o..];
    }
};

var outfd: i32 = -1;

fn send(_: *anyopaque, msg: []const u8) void {
    libc.writeall(outfd, msg) catch libc.exits("write");
}

pub fn main() void {
    if (libc.argv.len != 2) {
        libc.fprint(2, "usage: srvtest name\n", .{});
        libc.exits("usage");
    }
    const p = libc.pipe() catch libc.sysfatal("pipe: %r", .{});
    var name: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&name, "/srv/{s}", .{libc.argv[1]}) catch libc.sysfatal("name too long", .{});
    const sfd = libc.create(path, libc.OWRITE | libc.ORCLOSE, 0o600) catch libc.sysfatal("create %s: %r", .{path});
    libc.fprint(sfd, "%d", .{p[0]});
    libc.close(p[0]) catch {};
    outfd = p[1];

    var tree: Tree = .{};
    var s = srv.Server(Tree).init(&tree, .{ .ctx = &tree, .send = send }, libc.allocator);
    tree.s = &s;
    var buf: [srv.MAXMSG]u8 = undefined;
    while (!tree.done) {
        const n = libc.read9pmsg(p[1], &buf) catch libc.sysfatal("read9pmsg: %r", .{});
        if (n == 0) break;
        s.handle(buf[0..n]);
    }
    libc.close(sfd) catch {};
    libc.exits(null);
}
