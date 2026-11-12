//! ls - list contents of directory
//! from cmd/ls.c
//!
//! DIFF:
//!   - No -l and no -m yet: they need the local time (ctime and the
//!     time zone) and the %M and %C formats, which the library does not
//!     have.  Both are refused with a message.
//!   - Output is buffered with libc.FdWriter instead of bio.
//!   - %q is libc.quote.

const std = @import("std");
const libc = @import("libc");

const Dir = libc.Dir;

const NDir = struct {
    d: *const Dir,
    prefix: ?[]const u8,
    name: []const u8,
};

var errs = false;
var dflag = false;
var nflag = false;
var pflag = false;
var qflag = false;
var Qflag = false;
var rflag = false;
var sflag = false;
var tflag = false;
var Tflag = false;
var uflag = false;
var Fflag = false;
var dirbuf: std.ArrayList(NDir) = .empty;
var swidth: usize = 0; // max width of -s size
var qwidth: usize = 0; // max width of -q version

var outbuf: [8192]u8 = undefined;
var bin: libc.FdWriter = undefined;

const a = libc.allocator;

pub fn main(argv: []const []const u8) !void {
    bin = libc.FdWriter.init(1, &outbuf);
    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'F' => Fflag = true,
        'd' => dflag = true,
        'n' => nflag = true,
        'p' => pflag = true,
        'q' => qflag = true,
        'Q' => Qflag = true,
        'r' => rflag = true,
        's' => sflag = true,
        't' => tflag = true,
        'T' => Tflag = true,
        'u' => uflag = true,
        'l', 'm' => {
            libc.fprint(2, "ls: -%c is not supported yet\n", .{c});
            libc.exits("usage");
        },
        else => {
            libc.fprint(2, "usage: ls [-dnpqrstuFQT] [file ...]\n", .{});
            libc.exits("usage");
        },
    };
    const files = args.rest();

    if (files.len == 0) {
        errs = try ls(".", false);
    } else for (files) |f| {
        if (try ls(f, true))
            errs = true;
    }
    try output();
    libc.exits(if (errs) "errors" else null);
}

fn ls(s0: []const u8, multi: bool) !bool {
    const sb = try a.alloc(u8, s0.len + 2);
    @memcpy(sb[0..s0.len], s0);
    const s = sb[0..libc.cleanname(sb, s0.len)];

    var st = libc.dirstat(a, s) catch |e| {
        if (e == error.OutOfMemory) return e;
        libc.fprint(2, "ls: %s: %r\n", .{s});
        return true;
    };
    if ((st.dir.qid.type & libc.fcall.QTDIR) != 0 and !dflag) {
        st.deinit(a);
        try output();
        const fd = libc.open(s, libc.OREAD) catch {
            libc.fprint(2, "ls: %s: %r\n", .{s});
            return true;
        };
        defer libc.close(fd) catch {};
        const db = libc.dirreadall(a, fd) catch |e| {
            if (e == error.OutOfMemory) return e;
            libc.fprint(2, "ls: %s: %r\n", .{s});
            return true;
        };
        for (db.dirs) |*d|
            try dirbuf.append(a, .{ .d = d, .prefix = if (multi) s else null, .name = d.name });
        try output();
    } else {
        const d = try a.create(Dir);
        d.* = st.dir;
        var nd: NDir = .{ .d = d, .prefix = null, .name = s };
        if (std.mem.findScalarLast(u8, s, '/')) |p| {
            // if we 'ls foo/.', we don't want to
            // replace '.' with the name from the
            // dir and get 'foo/foo'; intead, use
            // the name we used to get here.
            nd.prefix = s[0..p];
            nd.name = s[p + 1 ..];
        }
        try dirbuf.append(a, nd);
    }
    return false;
}

fn output() !void {
    if (!nflag)
        libc.qsort(NDir, dirbuf.items, {}, compar);
    for (dirbuf.items) |*nd|
        dowidths(nd.d);
    const w = &bin.interface;
    var qb: [512]u8 = undefined;
    for (dirbuf.items) |*nd| {
        var nb: [1024]u8 = undefined;
        const p = if (!pflag and nd.prefix != null)
            (if (std.mem.eql(u8, nd.prefix.?, "/"))
                libc.fmt.snprint(&nb, "/%s", .{nd.name})
            else
                libc.fmt.snprint(&nb, "%s/%s", .{ nd.prefix.?, nd.name }))
        else
            libc.fmt.snprint(&nb, "%s", .{nd.name});
        const d = nd.d;
        if (sflag)
            try printf(w, "%*llud ", .{ swidth, @divTrunc(@as(u64, @bitCast(d.length)) + 1023, 1024) });
        if (qflag)
            try printf(w, "(%.16llux %*lud %.2ux) ", .{ d.qid.path, qwidth, d.qid.vers, d.qid.type });
        if (Tflag)
            try printf(w, "%c ", .{@as(u8, if ((d.mode & libc.fcall.DMTMP) != 0) 't' else '-')});
        const name = if (Qflag) p else libc.quote(&qb, p);
        try printf(w, "%s%s\n", .{ name, fileflag(d) });
    }
    dirbuf.clearRetainingCapacity();
    try w.flush();
}

fn printf(w: *std.Io.Writer, comptime format: []const u8, args: anytype) !void {
    var b: [1100]u8 = undefined;
    try w.writeAll(libc.fmt.snprint(&b, format, args));
}

fn dowidths(db: *const Dir) void {
    var buf: [256]u8 = undefined;
    if (sflag) {
        const n = libc.fmt.snprint(&buf, "%llud", .{@divTrunc(@as(u64, @bitCast(db.length)) + 1023, 1024)}).len;
        if (n > swidth)
            swidth = n;
    }
    if (qflag) {
        const n = libc.fmt.snprint(&buf, "%lud", .{db.qid.vers}).len;
        if (n > qwidth)
            qwidth = n;
    }
}

fn fileflag(db: *const Dir) []const u8 {
    if (!Fflag)
        return "";
    if ((libc.fcall.QTDIR & db.qid.type) != 0)
        return "/";
    if ((0o111 & db.mode) != 0)
        return "*";
    return "";
}

fn strcmp(x: []const u8, y: []const u8) i32 {
    return switch (std.mem.order(u8, x, y)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn compar(_: void, x: *const NDir, y: *const NDir) i32 {
    const ad = x.d;
    const bd = y.d;
    var i: i64 = 0;
    if (tflag) {
        if (uflag)
            i = @as(i32, @bitCast(bd.atime -% ad.atime)) // the C's ulong difference as a long
        else
            i = @as(i32, @bitCast(bd.mtime -% ad.mtime));
    } else {
        if (x.prefix != null and y.prefix != null) {
            i = strcmp(x.prefix.?, y.prefix.?);
            if (i == 0)
                i = strcmp(ad.name, bd.name);
        } else if (x.prefix != null) {
            i = strcmp(x.prefix.?, bd.name);
            if (i == 0)
                i = 1; // a is longer than b
        } else if (y.prefix != null) {
            i = strcmp(ad.name, y.prefix.?);
            if (i == 0)
                i = -1; // b is longer than a
        } else i = strcmp(ad.name, bd.name);
    }
    if (i == 0)
        i = if (@intFromPtr(x) < @intFromPtr(y)) -1 else 1;
    if (rflag)
        i = -i;
    return if (i < 0) -1 else if (i > 0) 1 else 0;
}
