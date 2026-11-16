//! ls - list contents of directory
//! from cmd/ls.c
//!
//! (9front 11952's, which the tests compare with: later ones clean the
//! name and print "dir/." as given, where this prints "dir/dir")
//!
//! DIFF:
//!   - Output is buffered with libc.FdWriter instead of bio.
//!   - %q is libc.quote, and %M is libc.dirmode.

const std = @import("std");
const libc = @import("libc");

const Dir = libc.Dir;

const NDir = struct {
    d: *const Dir,
    prefix: ?[]const u8,
};

var errs = false;
var dflag = false;
var lflag = false;
var mflag = false;
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
var vwidth: usize = 0; // max width of dev
var uwidth: usize = 0; // max width of userid
var mwidth: usize = 0; // max width of muid
var lwidth: usize = 0; // max width of length
var gwidth: usize = 0; // max width of groupid
var clk: u32 = 0;

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
        'l' => lflag = true,
        'm' => mflag = true,
        else => {
            libc.fprint(2, "usage: ls [-dlmnpqrstuFQT] [file ...]\n", .{});
            libc.exits("usage");
        },
    };
    const files = args.rest();

    if (lflag)
        clk = @truncate(@as(u64, @bitCast(libc.time())));

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
    var st = libc.dirstat(a, s0) catch |e| {
        if (e == error.OutOfMemory) return e;
        libc.fprint(2, "ls: %s: %r\n", .{s0});
        return true;
    };
    if ((st.dir.qid.type & libc.fcall.QTDIR) != 0 and !dflag) {
        st.deinit(a);
        try output();
        const fd = libc.open(s0, libc.OREAD) catch {
            libc.fprint(2, "ls: %s: %r\n", .{s0});
            return true;
        };
        defer libc.close(fd) catch {};
        const db = libc.dirreadall(a, fd) catch |e| {
            if (e == error.OutOfMemory) return e;
            libc.fprint(2, "ls: %s: %r\n", .{s0});
            return true;
        };
        const s = try xcleanname(s0);
        for (db.dirs) |*d|
            try dirbuf.append(a, .{ .d = d, .prefix = if (multi) s else null });
        try output();
    } else {
        const d = try a.create(Dir);
        d.* = st.dir;
        var nd: NDir = .{ .d = d, .prefix = null };
        const s = try xcleanname(s0);
        if (std.mem.findScalarLast(u8, s, '/')) |p|
            nd.prefix = s[0..p];
        try dirbuf.append(a, nd);
    }
    return false;
}

fn output() !void {
    if (!nflag)
        libc.qsort(NDir, dirbuf.items, {}, compar);
    for (dirbuf.items) |*nd|
        dowidths(nd.d);
    for (dirbuf.items) |*nd| {
        if (!pflag and nd.prefix != null) {
            var nb: [4096]u8 = undefined;
            var s = nd.prefix.?;
            if (std.mem.eql(u8, s, "/")) // / is a special case
                s = "";
            try format(nd.d, libc.fmt.snprint(&nb, "%s/%s", .{ s, nd.d.name }));
        } else try format(nd.d, nd.d.name);
    }
    dirbuf.clearRetainingCapacity();
    try bin.interface.flush();
}

fn printf(comptime fmt: []const u8, args: anytype) !void {
    var b: [4400]u8 = undefined;
    try bin.interface.writeAll(libc.fmt.snprint(&b, fmt, args));
}

/// The C's (db->length+1023)/1024, a vlong's, printed with %llud.
fn blocks(db: *const Dir) u64 {
    return @bitCast(@divTrunc(db.length +% 1023, 1024));
}

fn dowidths(db: *const Dir) void {
    var buf: [256]u8 = undefined;
    var qb: [600]u8 = undefined;
    if (sflag) {
        const n = libc.fmt.snprint(&buf, "%llud", .{blocks(db)}).len;
        if (n > swidth)
            swidth = n;
    }
    if (qflag) {
        const n = libc.fmt.snprint(&buf, "%lud", .{db.qid.vers}).len;
        if (n > qwidth)
            qwidth = n;
    }
    if (mflag) {
        const n = libc.fmt.snprint(&buf, "[%s]", .{libc.quote(&qb, db.muid)}).len;
        if (n > mwidth)
            mwidth = n;
    }
    if (lflag) {
        var n = libc.fmt.snprint(&buf, "%ud", .{db.dev}).len;
        if (n > vwidth)
            vwidth = n;
        n = libc.quote(&qb, db.uid).len;
        if (n > uwidth)
            uwidth = n;
        n = libc.quote(&qb, db.gid).len;
        if (n > gwidth)
            gwidth = n;
        n = libc.fmt.snprint(&buf, "%llud", .{@as(u64, @bitCast(db.length))}).len;
        if (n > lwidth)
            lwidth = n;
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

fn format(db: *const Dir, name: []const u8) !void {
    var qb: [600]u8 = undefined;
    var qb2: [600]u8 = undefined;

    if (sflag)
        try printf("%*llud ", .{ swidth, blocks(db) });
    if (mflag) {
        try printf("[%s] ", .{libc.quote(&qb, db.muid)});
        var i = 2 + db.muid.len;
        while (i < mwidth) : (i += 1)
            try printf(" ", .{});
    }
    if (qflag)
        try printf("(%.16llux %*lud %.2ux) ", .{ db.qid.path, qwidth, db.qid.vers, db.qid.type });
    if (Tflag)
        try printf("%c ", .{@as(u8, if ((db.mode & libc.fcall.DMTMP) != 0) 't' else '-')});

    if (lflag) {
        var mb: [11]u8 = undefined;
        try printf("%s %C %*ud %-*s %-*s %*llud %s ", .{
            libc.dirmode(&mb, db.mode), db.type,
            vwidth,                     db.dev,
            uwidth,                     libc.quote(&qb, db.uid),
            gwidth,                     libc.quote(&qb2, db.gid),
            lwidth,                     @as(u64, @bitCast(db.length)),
            asciitime(if (uflag) db.atime else db.mtime),
        });
    }
    var nq: [9000]u8 = undefined;
    try printf("%s%s\n", .{ if (Qflag) name else libc.quote(&nq, name), fileflag(db) });
}

var asciibuf: [13]u8 = undefined;

fn asciitime(l: u32) []const u8 {
    _ = libc.ctime(@bitCast(l));
    const t = libc.ascraw();
    // 6 months in the past or a day in the future
    // (the C compares its long with the ulong clk: unsigned)
    if (l < clk -% 180 * 24 * 60 * 60 or clk +% 24 * 60 * 60 < l) {
        @memcpy(asciibuf[0..7], t[4..11]); // month and day
        @memcpy(asciibuf[7..12], t[23..28]); // year
    } else @memcpy(asciibuf[0..12], t[4..16]); // skip day of week
    asciibuf[12] = 0;
    return asciibuf[0 .. std.mem.findScalar(u8, &asciibuf, 0) orelse 12];
}

/// Compress slashes, remove trailing slash.  Don't worry about . and ..
fn xcleanname(name: []const u8) ![]const u8 {
    const b = try a.alloc(u8, name.len);
    var w: usize = 0;
    for (name, 0..) |c, r| {
        if (c == '/' and r > 0 and name[r - 1] == '/')
            continue;
        b[w] = c;
        w += 1;
    }
    while (w > 1 and b[w - 1] == '/')
        w -= 1;
    return b[0..w];
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
