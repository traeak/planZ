//! A 9P file server, one message at a time, for programs that serve
//! files (vtfs).  Not a port: 9front's lib9p runs on libthread, which
//! this library has not got.  It imports only std and fcall, so the
//! host tests drive it in memory.
//!
//! Server(T) keeps the fids and answers version, auth, attach, walk,
//! open, read and stat of directories, stat and clunk itself; T is the
//! file tree and says what is in it and what reading and writing a file
//! does.  The caller reads a message (libc.read9pmsg) and hands it to
//! handle(), which sends the answer through `out`.  T's read and write
//! may answer later (a read of a console waits for a line): the request
//! is kept by its tag until T calls respondRead, respondWrite or
//! respondError, or until a Tflush drops it.
//!
//! T must have (a compile error says which is missing):
//!   root(t) Qid
//!   walk1(t, q: Qid, name) ?Qid            null: no such file
//!   stat(t, q: Qid) ?Dir                    strings may be T's own
//!   dirent(t, q: Qid, i: usize) ?Dir        the i'th entry of directory q
//!   open(t, fid: *Fid, mode: u8) ?[]const u8    an error, or null
//!   read(t, fid: *Fid, r: Req) Answer       .data, .err or .later
//!   write(t, fid: *Fid, r: Req, data) Answer    .count, .err or .later
//! and may have:
//!   Aux                                     a type, kept in each Fid
//!   clunk(t, fid: *Fid) void
//!   flush(t, r: Req) void                   a .later request is dropped
//! Create, remove and wstat are refused.
//!
//! Not part of 9front.

const std = @import("std");
const fcall = @import("fcall");

const Fcall = fcall.Fcall;
pub const Qid = fcall.Qid;
pub const Dir = fcall.Dir;

const OREAD = 0;
const OWRITE = 1;
const ORDWR = 2;
const OEXEC = 3;

/// The largest message, as lib9p's default.
pub const MAXMSG = 8192 + fcall.IOHDRSZ;

/// A request kept for an answer, by its tag.
pub const Req = struct {
    tag: u16,
    type: u8, // Tread or Twrite
    fid: u32,
    offset: i64,
    count: u32,
};

/// What T's read and write answer.
pub const Answer = union(enum) {
    data: []const u8, // read: the bytes (cut to the count asked)
    count: u32, // write: how much was taken
    err: []const u8,
    later, // T answers by the request's tag
};

/// Where answers go: a message, whole.
pub const Out = struct {
    ctx: *anyopaque,
    send: *const fn (ctx: *anyopaque, msg: []const u8) void,
};

pub const Eunknownfid = "unknown fid";
pub const Eduptag = "duplicate tag";
pub const Efidinuse = "fid in use";
pub const Enotfound = "file does not exist";
pub const Enotdir = "not a directory";
pub const Ewalknodir = "walk in non-directory";
pub const Eopen = "fid already opened";
pub const Enotopen = "fid not open";
pub const Ebotch = "9P protocol botch";
pub const Eperm = "permission denied";
pub const Enoauth = "authentication not required";
pub const Ebadoffset = "bad offset in directory read";

pub fn Server(comptime T: type) type {
    comptime {
        for ([_][]const u8{ "root", "walk1", "stat", "dirent", "open", "read", "write" }) |f|
            if (!@hasDecl(T, f)) @compileError("srv.Server: " ++ @typeName(T) ++ " has no " ++ f);
    }
    return struct {
        const S = @This();

        pub const Aux = if (@hasDecl(T, "Aux")) T.Aux else void;

        pub const Fid = struct {
            fid: u32,
            qid: Qid,
            omode: ?u8 = null, // null: not open
            // a directory read: where the last one ended
            diroff: i64 = 0,
            dirindex: usize = 0,
            aux: Aux = if (Aux == void) {} else undefined,
        };

        tree: *T,
        out: Out,
        alloc: std.mem.Allocator,
        msize: u32 = MAXMSG,
        fids: std.AutoHashMapUnmanaged(u32, Fid) = .empty,
        pending: std.AutoHashMapUnmanaged(u16, Req) = .empty,
        buf: [MAXMSG]u8 = undefined, // answers are packed here

        pub fn init(tree: *T, out: Out, alloc: std.mem.Allocator) S {
            return .{ .tree = tree, .out = out, .alloc = alloc };
        }

        pub fn deinit(s: *S) void {
            s.fids.deinit(s.alloc);
            s.pending.deinit(s.alloc);
        }

        fn send(s: *S, f: *Fcall) void {
            const n = fcall.convS2M(f, &s.buf);
            if (n == 0) {
                // too big or bad: say so instead (cannot itself fail)
                var e: Fcall = .{ .type = fcall.Rerror, .tag = f.tag, .ename = Ebotch };
                const m = fcall.convS2M(&e, &s.buf);
                s.out.send(s.out.ctx, s.buf[0..m]);
                return;
            }
            s.out.send(s.out.ctx, s.buf[0..n]);
        }

        fn rerror(s: *S, tag: u16, msg: []const u8) void {
            var f: Fcall = .{ .type = fcall.Rerror, .tag = tag, .ename = msg };
            s.send(&f);
        }

        /// A fid of this connection, or null.
        pub fn lookup(s: *S, fid: u32) ?*Fid {
            return s.fids.getPtr(fid);
        }

        /// Handle one T-message.  A message that does not parse is
        /// dropped: there is no tag to answer.
        pub fn handle(s: *S, msg: []const u8) void {
            var t: Fcall = .{};
            if (fcall.convM2S(msg, &t) != msg.len)
                return;
            if (t.type != fcall.Tversion and t.type != fcall.Tflush and s.pending.contains(t.tag))
                return s.rerror(t.tag, Eduptag);
            switch (t.type) {
                fcall.Tversion => s.version(&t),
                fcall.Tauth => s.rerror(t.tag, Enoauth),
                fcall.Tattach => s.attach(&t),
                fcall.Tflush => s.flush(&t),
                fcall.Twalk => s.walk(&t),
                fcall.Topen => s.open(&t),
                fcall.Tcreate, fcall.Tremove, fcall.Twstat => {
                    if (t.type == fcall.Tremove) s.clunkfid(t.fid);
                    s.rerror(t.tag, Eperm);
                },
                fcall.Tread => s.read(&t),
                fcall.Twrite => s.write(&t),
                fcall.Tclunk => {
                    if (s.fids.contains(t.fid)) {
                        s.clunkfid(t.fid);
                        var r: Fcall = .{ .type = fcall.Rclunk, .tag = t.tag };
                        s.send(&r);
                    } else s.rerror(t.tag, Eunknownfid);
                },
                fcall.Tstat => s.stat(&t),
                else => s.rerror(t.tag, Ebotch),
            }
        }

        fn clunkfid(s: *S, fid: u32) void {
            if (s.fids.getPtr(fid)) |f| {
                if (@hasDecl(T, "clunk")) s.tree.clunk(f);
                _ = s.fids.remove(fid);
            }
        }

        fn version(s: *S, t: *Fcall) void {
            // a new session: everything of the old one goes
            var it = s.pending.valueIterator();
            while (it.next()) |r|
                if (@hasDecl(T, "flush")) s.tree.flush(r.*);
            s.pending.clearRetainingCapacity();
            var fit = s.fids.keyIterator();
            var all: std.ArrayList(u32) = .empty;
            defer all.deinit(s.alloc);
            while (fit.next()) |k| all.append(s.alloc, k.*) catch {};
            for (all.items) |k| s.clunkfid(k);

            var r: Fcall = .{ .type = fcall.Rversion, .tag = t.tag };
            if (t.msize < 256)
                return s.rerror(t.tag, "version: message size too small");
            s.msize = @min(t.msize, MAXMSG);
            r.msize = s.msize;
            r.version = if (std.mem.startsWith(u8, t.version, "9P2000")) fcall.VERSION9P else "unknown";
            s.send(&r);
        }

        fn newfid(s: *S, fid: u32, q: Qid) ?*Fid {
            const g = s.fids.getOrPut(s.alloc, fid) catch return null;
            if (g.found_existing) return null;
            g.value_ptr.* = .{ .fid = fid, .qid = q };
            return g.value_ptr;
        }

        fn attach(s: *S, t: *Fcall) void {
            const q = s.tree.root();
            if (s.newfid(t.fid, q) == null)
                return s.rerror(t.tag, Efidinuse);
            var r: Fcall = .{ .type = fcall.Rattach, .tag = t.tag, .qid = q };
            s.send(&r);
        }

        fn flush(s: *S, t: *Fcall) void {
            if (s.pending.fetchRemove(t.oldtag)) |kv|
                if (@hasDecl(T, "flush")) s.tree.flush(kv.value);
            var r: Fcall = .{ .type = fcall.Rflush, .tag = t.tag };
            s.send(&r);
        }

        fn walk(s: *S, t: *Fcall) void {
            const f = s.fids.getPtr(t.fid) orelse return s.rerror(t.tag, Eunknownfid);
            if (f.omode != null) return s.rerror(t.tag, Eopen);
            if (t.newfid != t.fid and s.fids.contains(t.newfid))
                return s.rerror(t.tag, Efidinuse);
            var r: Fcall = .{ .type = fcall.Rwalk, .tag = t.tag };
            var q = f.qid;
            var i: usize = 0;
            while (i < t.nwname) : (i += 1) {
                if (q.type & fcall.QTDIR == 0) {
                    if (i == 0) return s.rerror(t.tag, Ewalknodir);
                    break;
                }
                q = s.tree.walk1(q, t.wname[i]) orelse {
                    if (i == 0) return s.rerror(t.tag, Enotfound);
                    break;
                };
                r.wqid[i] = q;
            }
            r.nwqid = @intCast(i);
            // only a walk of every name moves or makes the fid
            if (i == t.nwname) {
                if (t.newfid == t.fid) {
                    f.qid = q;
                } else {
                    const n = s.newfid(t.newfid, q) orelse return s.rerror(t.tag, Efidinuse);
                    if (Aux != void) n.aux = s.fids.getPtr(t.fid).?.aux;
                }
            }
            s.send(&r);
        }

        fn open(s: *S, t: *Fcall) void {
            const f = s.fids.getPtr(t.fid) orelse return s.rerror(t.tag, Eunknownfid);
            if (f.omode != null) return s.rerror(t.tag, Eopen);
            if (f.qid.type & fcall.QTDIR != 0 and t.mode & 3 != OREAD)
                return s.rerror(t.tag, Eperm);
            if (s.tree.open(f, t.mode)) |e| return s.rerror(t.tag, e);
            f.omode = t.mode;
            f.diroff = 0;
            f.dirindex = 0;
            var r: Fcall = .{ .type = fcall.Ropen, .tag = t.tag, .qid = f.qid, .iounit = s.msize - fcall.IOHDRSZ };
            s.send(&r);
        }

        fn readable(mode: u8) bool {
            return switch (mode & 3) {
                OREAD, ORDWR, OEXEC => true,
                else => false,
            };
        }

        fn read(s: *S, t: *Fcall) void {
            const f = s.fids.getPtr(t.fid) orelse return s.rerror(t.tag, Eunknownfid);
            const mode = f.omode orelse return s.rerror(t.tag, Enotopen);
            if (!readable(mode)) return s.rerror(t.tag, "permission denied: not open for reading");
            const count = @min(t.count, s.msize - fcall.IOHDRSZ);
            if (f.qid.type & fcall.QTDIR != 0)
                return s.readdir(f, t.tag, t.offset, count);
            const req: Req = .{ .tag = t.tag, .type = fcall.Tread, .fid = t.fid, .offset = t.offset, .count = count };
            s.answer(req, s.tree.read(f, req));
        }

        fn readdir(s: *S, f: *Fid, tag: u16, offset: i64, count: u32) void {
            if (offset == 0) {
                f.diroff = 0;
                f.dirindex = 0;
            } else if (offset != f.diroff) return s.rerror(tag, Ebadoffset);
            // the entries go after the Rread header in buf
            var data: [MAXMSG]u8 = undefined;
            var n: usize = 0;
            while (s.tree.dirent(f.qid, f.dirindex)) |d| {
                const m = fcall.convD2M(&d, data[n..count]);
                if (m <= fcall.BIT16SZ) break; // does not fit
                n += m;
                f.dirindex += 1;
            }
            f.diroff += @intCast(n);
            var r: Fcall = .{ .type = fcall.Rread, .tag = tag, .count = @intCast(n), .data = data[0..n] };
            s.send(&r);
        }

        fn write(s: *S, t: *Fcall) void {
            const f = s.fids.getPtr(t.fid) orelse return s.rerror(t.tag, Eunknownfid);
            const mode = f.omode orelse return s.rerror(t.tag, Enotopen);
            if (mode & 3 != OWRITE and mode & 3 != ORDWR)
                return s.rerror(t.tag, "permission denied: not open for writing");
            const req: Req = .{ .tag = t.tag, .type = fcall.Twrite, .fid = t.fid, .offset = t.offset, .count = t.count };
            s.answer(req, s.tree.write(f, req, t.data));
        }

        fn answer(s: *S, req: Req, a: Answer) void {
            switch (a) {
                .data => |d| s.sendRead(req.tag, d[0..@min(d.len, req.count)]),
                .count => |c| s.sendWrite(req.tag, c),
                .err => |e| s.rerror(req.tag, e),
                .later => s.pending.put(s.alloc, req.tag, req) catch s.rerror(req.tag, "out of memory"),
            }
        }

        fn sendRead(s: *S, tag: u16, d: []const u8) void {
            var r: Fcall = .{ .type = fcall.Rread, .tag = tag, .count = @intCast(d.len), .data = d };
            s.send(&r);
        }

        fn sendWrite(s: *S, tag: u16, c: u32) void {
            var r: Fcall = .{ .type = fcall.Rwrite, .tag = tag, .count = c };
            s.send(&r);
        }

        /// The requests T answered with .later, for T to look through.
        pub fn waiting(s: *S) std.AutoHashMapUnmanaged(u16, Req).ValueIterator {
            return s.pending.valueIterator();
        }

        /// Answer a read kept with .later; false if it is gone (flushed).
        pub fn respondRead(s: *S, tag: u16, d: []const u8) bool {
            const kv = s.pending.fetchRemove(tag) orelse return false;
            s.sendRead(tag, d[0..@min(d.len, kv.value.count)]);
            return true;
        }

        pub fn respondWrite(s: *S, tag: u16, c: u32) bool {
            _ = s.pending.fetchRemove(tag) orelse return false;
            s.sendWrite(tag, c);
            return true;
        }

        pub fn respondError(s: *S, tag: u16, e: []const u8) bool {
            _ = s.pending.fetchRemove(tag) orelse return false;
            s.rerror(tag, e);
            return true;
        }

        fn stat(s: *S, t: *Fcall) void {
            const f = s.fids.getPtr(t.fid) orelse return s.rerror(t.tag, Eunknownfid);
            const d = s.tree.stat(f.qid) orelse return s.rerror(t.tag, Enotfound);
            var data: [MAXMSG]u8 = undefined;
            const n = fcall.convD2M(&d, &data);
            if (n <= fcall.BIT16SZ) return s.rerror(t.tag, Ebotch);
            var r: Fcall = .{ .type = fcall.Rstat, .tag = t.tag, .nstat = @intCast(n), .stat = data[0..n] };
            s.send(&r);
        }
    };
}

// Tests: a tree of one directory with three files, driven by messages
// made with fcall and answers decoded with it.

const TestTree = struct {
    note: [64]u8 = undefined,
    nnote: usize = 0,
    waiting: ?u16 = null,
    flushed: u32 = 0,
    clunked: u32 = 0,

    pub const Aux = u32; // opens of this fid

    const Qroot = 0;
    const Qhello = 1;
    const Qnote = 2;
    const Qwait = 3;
    const names = [_][]const u8{ ".", "hello", "note", "wait" };

    fn qid(p: u64) Qid {
        return .{ .path = p, .type = if (p == Qroot) fcall.QTDIR else fcall.QTFILE };
    }

    pub fn root(_: *TestTree) Qid {
        return qid(Qroot);
    }
    pub fn walk1(_: *TestTree, q: Qid, name: []const u8) ?Qid {
        if (q.path != Qroot) return null;
        if (std.mem.eql(u8, name, "..")) return qid(Qroot);
        for (names[1..], 1..) |n, i|
            if (std.mem.eql(u8, n, name)) return qid(i);
        return null;
    }
    pub fn stat(t: *TestTree, q: Qid) ?Dir {
        const p: usize = @intCast(q.path);
        if (p >= names.len) return null;
        return .{
            .qid = q,
            .mode = if (p == Qroot) fcall.DMDIR | 0o555 else 0o666,
            .length = if (p == Qnote) @intCast(t.nnote) else 0,
            .name = if (p == Qroot) "/" else names[p],
            .uid = "zig",
            .gid = "zig",
            .muid = "zig",
        };
    }
    pub fn dirent(t: *TestTree, q: Qid, i: usize) ?Dir {
        if (q.path != Qroot or i + 1 >= names.len) return null;
        return t.stat(qid(i + 1));
    }
    pub fn open(_: *TestTree, f: anytype, mode: u8) ?[]const u8 {
        if (f.qid.path == Qhello and mode & 3 != 0) return Eperm;
        f.aux = 1;
        return null;
    }
    pub fn read(t: *TestTree, f: anytype, r: Req) Answer {
        return switch (f.qid.path) {
            Qhello => .{ .data = slice("hello, world\n", r.offset) },
            Qnote => .{ .data = slice(t.note[0..t.nnote], r.offset) },
            Qwait => blk: {
                t.waiting = r.tag;
                break :blk .later;
            },
            else => .{ .err = Ebotch },
        };
    }
    pub fn write(t: *TestTree, f: anytype, _: Req, data: []const u8) Answer {
        if (f.qid.path != Qnote) return .{ .err = Eperm };
        const n = @min(data.len, t.note.len);
        @memcpy(t.note[0..n], data[0..n]);
        t.nnote = n;
        return .{ .count = @intCast(n) };
    }
    pub fn clunk(t: *TestTree, _: anytype) void {
        t.clunked += 1;
    }
    pub fn flush(t: *TestTree, r: Req) void {
        if (t.waiting == r.tag) t.waiting = null;
        t.flushed += 1;
    }

    fn slice(s: []const u8, off: i64) []const u8 {
        const o: usize = @intCast(@min(@max(off, 0), @as(i64, @intCast(s.len))));
        return s[o..];
    }
};

const Wire = struct {
    msgs: std.ArrayList([]u8) = .empty,

    fn send(ctx: *anyopaque, msg: []const u8) void {
        const w: *Wire = @ptrCast(@alignCast(ctx));
        w.msgs.append(std.testing.allocator, std.testing.allocator.dupe(u8, msg) catch unreachable) catch unreachable;
    }

    fn deinit(w: *Wire) void {
        for (w.msgs.items) |m| std.testing.allocator.free(m);
        w.msgs.deinit(std.testing.allocator);
    }

    /// The answers so far, decoded; they point into the wire's copies.
    fn take(w: *Wire, out: []Fcall) []Fcall {
        for (w.msgs.items, 0..) |m, i| {
            out[i] = .{};
            std.debug.assert(fcall.convM2S(m, &out[i]) == m.len);
        }
        return out[0..w.msgs.items.len];
    }
};

const TS = Server(TestTree);

fn tmsg(s: *TS, f: Fcall) void {
    var b: [MAXMSG]u8 = undefined;
    var ff = f;
    const n = fcall.convS2M(&ff, &b);
    std.debug.assert(n != 0);
    s.handle(b[0..n]);
}

fn setup(tree: *TestTree, wire: *Wire) TS {
    var s = TS.init(tree, .{ .ctx = wire, .send = Wire.send }, std.testing.allocator);
    tmsg(&s, .{ .type = fcall.Tversion, .tag = fcall.NOTAG, .msize = 65536, .version = "9P2000" });
    tmsg(&s, .{ .type = fcall.Tattach, .tag = 1, .fid = 0, .afid = fcall.NOFID, .uname = "glenda" });
    return s;
}

test "version, attach, walk, open, read, write, stat" {
    var tree: TestTree = .{};
    var wire: Wire = .{};
    defer wire.deinit();
    var s = setup(&tree, &wire);
    defer s.deinit();

    var w: Fcall = .{ .type = fcall.Twalk, .tag = 2, .fid = 0, .newfid = 1, .nwname = 1 };
    w.wname[0] = "hello";
    tmsg(&s, w);
    tmsg(&s, .{ .type = fcall.Topen, .tag = 3, .fid = 1, .mode = 0 });
    tmsg(&s, .{ .type = fcall.Tread, .tag = 4, .fid = 1, .offset = 7, .count = 100 });
    tmsg(&s, .{ .type = fcall.Twrite, .tag = 5, .fid = 1, .count = 1, .data = "x" });
    w = .{ .type = fcall.Twalk, .tag = 6, .fid = 0, .newfid = 2, .nwname = 1 };
    w.wname[0] = "note";
    tmsg(&s, w);
    tmsg(&s, .{ .type = fcall.Topen, .tag = 7, .fid = 2, .mode = 2 });
    tmsg(&s, .{ .type = fcall.Twrite, .tag = 8, .fid = 2, .count = 5, .data = "abcde" });
    tmsg(&s, .{ .type = fcall.Tread, .tag = 9, .fid = 2, .offset = 0, .count = 3 });
    tmsg(&s, .{ .type = fcall.Tstat, .tag = 10, .fid = 2 });
    tmsg(&s, .{ .type = fcall.Tclunk, .tag = 11, .fid = 2 });
    tmsg(&s, .{ .type = fcall.Tclunk, .tag = 12, .fid = 2 });

    var buf: [20]Fcall = undefined;
    const r = wire.take(&buf);
    try std.testing.expectEqual(13, r.len);
    try std.testing.expectEqual(fcall.Rversion, r[0].type);
    try std.testing.expectEqualStrings("9P2000", r[0].version);
    try std.testing.expectEqual(@as(u32, MAXMSG), r[0].msize);
    try std.testing.expectEqual(fcall.Rattach, r[1].type);
    try std.testing.expectEqual(@as(u8, fcall.QTDIR), r[1].qid.type);
    try std.testing.expectEqual(fcall.Rwalk, r[2].type);
    try std.testing.expectEqual(1, r[2].nwqid);
    try std.testing.expectEqual(fcall.Ropen, r[3].type);
    try std.testing.expectEqualStrings("world\n", r[4].data);
    try std.testing.expectEqual(fcall.Rerror, r[5].type); // write on OREAD
    try std.testing.expectEqual(fcall.Ropen, r[7].type);
    try std.testing.expectEqual(5, r[8].count);
    try std.testing.expectEqualStrings("abc", r[9].data);
    try std.testing.expectEqual(fcall.Rstat, r[10].type);
    var d: Dir = undefined;
    var strs: [64]u8 = undefined;
    try std.testing.expect(fcall.convM2D(r[10].stat, &d, &strs) != 0);
    try std.testing.expectEqualStrings("note", d.name);
    try std.testing.expectEqual(5, d.length);
    try std.testing.expectEqual(fcall.Rclunk, r[11].type);
    try std.testing.expectEqualStrings(Eunknownfid, r[12].ename);
    try std.testing.expectEqual(1, tree.clunked);
}

test "walk errors and partial walks" {
    var tree: TestTree = .{};
    var wire: Wire = .{};
    defer wire.deinit();
    var s = setup(&tree, &wire);
    defer s.deinit();

    var w: Fcall = .{ .type = fcall.Twalk, .tag = 2, .fid = 0, .newfid = 1, .nwname = 2 };
    w.wname[0] = "hello";
    w.wname[1] = "x"; // hello is not a directory: a partial walk
    tmsg(&s, w);
    w = .{ .type = fcall.Twalk, .tag = 3, .fid = 0, .newfid = 1, .nwname = 1 };
    w.wname[0] = "nothere";
    tmsg(&s, w);
    w = .{ .type = fcall.Twalk, .tag = 4, .fid = 0, .newfid = 1, .nwname = 0 }; // clone
    tmsg(&s, w);
    w = .{ .type = fcall.Twalk, .tag = 5, .fid = 0, .newfid = 1, .nwname = 0 };
    tmsg(&s, w); // newfid in use
    w = .{ .type = fcall.Twalk, .tag = 6, .fid = 9, .newfid = 10, .nwname = 0 };
    tmsg(&s, w);

    var buf: [10]Fcall = undefined;
    const r = wire.take(&buf);
    try std.testing.expectEqual(fcall.Rwalk, r[2].type);
    try std.testing.expectEqual(1, r[2].nwqid);
    try std.testing.expect(s.lookup(1) != null); // made by the clone, not the partial walk
    try std.testing.expectEqualStrings(Enotfound, r[3].ename);
    try std.testing.expectEqual(fcall.Rwalk, r[4].type);
    try std.testing.expectEqual(0, r[4].nwqid);
    try std.testing.expectEqualStrings(Efidinuse, r[5].ename);
    try std.testing.expectEqualStrings(Eunknownfid, r[6].ename);
}

test "a directory read in pieces" {
    var tree: TestTree = .{};
    var wire: Wire = .{};
    defer wire.deinit();
    var s = setup(&tree, &wire);
    defer s.deinit();

    tmsg(&s, .{ .type = fcall.Topen, .tag = 2, .fid = 0, .mode = 0 });
    // room for one entry (63 bytes) at a time
    tmsg(&s, .{ .type = fcall.Tread, .tag = 3, .fid = 0, .offset = 0, .count = 70 });
    var buf: [10]Fcall = undefined;
    var r = wire.take(&buf);
    const first = r[3].data.len;
    try std.testing.expect(first > 0 and first <= 70);
    tmsg(&s, .{ .type = fcall.Tread, .tag = 4, .fid = 0, .offset = @intCast(first), .count = 8192 });
    tmsg(&s, .{ .type = fcall.Tread, .tag = 5, .fid = 0, .offset = 3, .count = 8192 });
    r = wire.take(&buf);
    var names: [3][]const u8 = undefined;
    var nn: usize = 0;
    var strs: [256]u8 = undefined;
    for ([_][]const u8{ r[3].data, r[4].data }) |data| {
        var i: usize = 0;
        while (i < data.len) {
            const m = fcall.GBIT16(data, i) + fcall.BIT16SZ;
            var d: Dir = undefined;
            try std.testing.expect(fcall.convM2D(data[i..][0..m], &d, strs[nn * 64 ..][0..64]) == m);
            names[nn] = d.name;
            nn += 1;
            i += m;
        }
    }
    try std.testing.expectEqual(3, nn);
    try std.testing.expectEqualStrings("hello", names[0]);
    try std.testing.expectEqualStrings("wait", names[2]);
    try std.testing.expectEqualStrings(Ebadoffset, r[5].ename);
}

test "a read answered later, and one flushed" {
    var tree: TestTree = .{};
    var wire: Wire = .{};
    defer wire.deinit();
    var s = setup(&tree, &wire);
    defer s.deinit();

    var w: Fcall = .{ .type = fcall.Twalk, .tag = 2, .fid = 0, .newfid = 1, .nwname = 1 };
    w.wname[0] = "wait";
    tmsg(&s, w);
    tmsg(&s, .{ .type = fcall.Topen, .tag = 3, .fid = 1, .mode = 0 });
    tmsg(&s, .{ .type = fcall.Tread, .tag = 4, .fid = 1, .count = 100 });
    try std.testing.expectEqual(4, wire.msgs.items.len); // no answer yet
    tmsg(&s, .{ .type = fcall.Tread, .tag = 4, .fid = 1, .count = 100 }); // the tag is taken
    try std.testing.expect(s.respondRead(tree.waiting.?, "go\n"));
    try std.testing.expect(!s.respondRead(4, "again")); // answered already

    tmsg(&s, .{ .type = fcall.Tread, .tag = 6, .fid = 1, .count = 100 });
    tmsg(&s, .{ .type = fcall.Tflush, .tag = 7, .oldtag = 6 });
    try std.testing.expect(!s.respondRead(6, "late")); // flushed
    try std.testing.expectEqual(1, tree.flushed);

    var buf: [10]Fcall = undefined;
    const r = wire.take(&buf);
    try std.testing.expectEqualStrings(Eduptag, r[4].ename);
    try std.testing.expectEqual(fcall.Rread, r[5].type);
    try std.testing.expectEqual(4, r[5].tag);
    try std.testing.expectEqualStrings("go\n", r[5].data);
    try std.testing.expectEqual(fcall.Rflush, r[6].type);
    try std.testing.expectEqual(7, r[6].tag);
    try std.testing.expectEqual(7, r.len);
}

test "a new version drops fids and waiting requests" {
    var tree: TestTree = .{};
    var wire: Wire = .{};
    defer wire.deinit();
    var s = setup(&tree, &wire);
    defer s.deinit();

    var w: Fcall = .{ .type = fcall.Twalk, .tag = 2, .fid = 0, .newfid = 1, .nwname = 1 };
    w.wname[0] = "wait";
    tmsg(&s, w);
    tmsg(&s, .{ .type = fcall.Topen, .tag = 3, .fid = 1, .mode = 0 });
    tmsg(&s, .{ .type = fcall.Tread, .tag = 4, .fid = 1, .count = 100 });
    tmsg(&s, .{ .type = fcall.Tversion, .tag = fcall.NOTAG, .msize = 8192, .version = "9P2000.u" });
    try std.testing.expect(s.lookup(0) == null and s.lookup(1) == null);
    try std.testing.expectEqual(1, tree.flushed);
    try std.testing.expectEqual(2, tree.clunked);
    var buf: [10]Fcall = undefined;
    const r = wire.take(&buf);
    try std.testing.expectEqual(fcall.Rversion, r[4].type);
    try std.testing.expectEqual(8192, r[4].msize);
}
