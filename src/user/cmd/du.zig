//! du - print disk usage
//! from cmd/du.c
//!
//! DIFF: -e and -h print floating point (%g), which the library's
//! formatting does not have yet: they print that and exit.  Names are
//! built with the allocator where the C uses String.  The seen cache is
//! a list per bucket, as the C's, holding the Dir fields it compares.

const std = @import("std");
const libc = @import("libc");

const Dir = libc.Dir;
const a = libc.allocator;

const Vkilo: i64 = 1024;

/// rounding up, how many units does amt occupy?
fn howmany(amt: i64, unit_: i64) i64 {
    return @divTrunc(amt +% unit_ - 1, unit_);
}

fn roundup(amt: i64, unit_: i64) i64 {
    return howmany(amt, unit_) * unit_;
}

var aflag = false;
var autoscale = false;
var fflag = false;
var fltflag = false;
var qflag = false;
var readflg = false;
var sflag = false;
var tflag = false;
var uflag = false;

var readbuf: []u8 = &.{};
var blocksize: i64 = Vkilo; // actually more likely to be 4K or 8K
var unit: i64 = 0; // scale factor for output

const pfxes = [_][]const u8{ // SI prefixes for units > 1
    "",
    "k", "M", "G",
    "T", "P", "E",
    "Z", "Y",
};

fn usage() noreturn {
    libc.fprint(2, "usage: du [-aefhnqstu] [-b size] [-p si-pfx] [file ...]\n", .{});
    libc.exits("usage");
}

fn printamt(amt: i64, name: []const u8) void {
    if (readflg)
        return;
    if (autoscale or fltflag) {
        // DIFF: see the head of the file
        libc.fprint(2, "du: -e and -h are not ported yet: they need %%g\n", .{});
        libc.exits("not ported");
    }
    const v: u64 = @bitCast(howmany(amt, unit));
    if (qflag)
        libc.print("%.16llux\t%q\n", .{ v, name })
    else
        libc.print("%llud\t%q\n", .{ v, name });
}

pub fn main(argv: []const []const u8) void {
    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'a' => aflag = true, // all files
        'b' => if (args.value()) |s| { // block size
            const r = libc.strtoul32(s, 0);
            blocksize = r.v;
            if (r.n == 0)
                blocksize = 1;
            var k = r.n;
            while (true) {
                const ch: u8 = if (k < s.len) s[k] else 0;
                k += 1;
                if (ch != 'k') break;
                blocksize *%= 1024;
            }
        },
        'e' => fltflag = true, // print in %g notation
        'f' => fflag = true, // don't print warnings
        'h' => autoscale = true, // similar to -h in bsd but more precise
        'n' => { // all files, number of bytes
            aflag = true;
            blocksize = 1;
            unit = 1;
        },
        'p' => if (args.value()) |s| {
            var scale: usize = 0;
            while (scale < pfxes.len) : (scale += 1) {
                if (std.ascii.eqlIgnoreCase(s, pfxes[scale]))
                    break;
            }
            if (scale == pfxes.len)
                libc.sysfatal("unknown suffix %s", .{s});
            unit = 1;
            while (scale > 0) : (scale -= 1)
                unit *%= Vkilo;
        },
        'q' => qflag = true, // qid
        'r' => readflg = true, // undocumented: just read & ignore every block of every file
        's' => sflag = true, // only top level
        't' => tflag = true, // return modified/accessed time
        'u' => uflag = true, // accessed time
        else => usage(),
    };
    const files = args.rest();

    if (unit == 0) {
        if (qflag or tflag or uflag or autoscale)
            unit = 1
        else
            unit = Vkilo;
    }
    if (blocksize < 1)
        blocksize = 1;

    if (readflg) {
        readbuf = a.alloc(u8, @intCast(blocksize)) catch libc.sysfatal("out of memory", .{});
    }
    if (files.len == 0)
        printamt(dustat("."), ".")
    else for (files) |name|
        printamt(dustat(name), name);
    libc.exits(null);
}

/// du(name, dirstat(name))
fn dustat(name: []const u8) i64 {
    var st = libc.dirstat(a, name) catch return warn(name);
    defer st.deinit(a);
    return du(name, &st.dir);
}

fn dirval(d: *const Dir, size: i64) i64 {
    if (qflag)
        return @bitCast(d.qid.path)
    else if (tflag) {
        if (uflag)
            return d.atime;
        return d.mtime;
    } else return size;
}

fn readfile(name: []const u8) void {
    const fd = libc.open(name, libc.OREAD) catch {
        _ = warn(name);
        return;
    };
    while (true) {
        const n = libc.read(fd, readbuf) catch {
            _ = warn(name);
            break;
        };
        if (n == 0)
            break;
    }
    libc.close(fd) catch {};
}

fn join(name: []const u8, elem: []const u8) []u8 {
    return std.mem.concat(a, u8, &.{ name, "/", elem }) catch err("malloc failure");
}

fn dufile(name: []const u8, d: *const Dir) i64 {
    var t = blkmultiple(d.length);

    if (aflag or readflg) {
        const file = join(name, d.name);
        defer a.free(file);
        if (readflg)
            readfile(file);
        t = dirval(d, t);
        printamt(t, file);
    }
    return t;
}

fn du(name: []const u8, dir: *const Dir) i64 {
    if (dir.qid.type & libc.QTDIR == 0)
        return dirval(dir, blkmultiple(dir.length));

    const fd = libc.open(name, libc.OREAD) catch return warn(name);
    var nk: i64 = 0;
    var failed = false;
    while (true) {
        var ds = libc.dirread(a, fd) catch {
            failed = true;
            break;
        };
        defer ds.deinit(a);
        if (ds.dirs.len == 0)
            break;
        for (ds.dirs) |*d| {
            if (d.qid.type & libc.QTDIR == 0) {
                nk +%= dufile(name, d);
                continue;
            }

            if (std.mem.eql(u8, d.name, ".") or
                std.mem.eql(u8, d.name, "..") or
                // !readflg &&
                seen(d))
                continue; // don't get stuck

            const file = join(name, d.name);
            defer a.free(file);

            var t = du(file, d);

            nk +%= t;
            t = dirval(d, t);
            if (!sflag)
                printamt(t, file);
        }
    }
    if (failed)
        _ = warn(name);
    libc.close(fd) catch {};
    return dirval(dir, nk);
}

const NCACHE = 256; // must be power of two

const Seen = struct { path: u64, type: u16, dev: u32 };

var cache: [NCACHE]std.ArrayList(Seen) = @splat(.empty);

fn seen(dir: *const Dir) bool {
    const c = &cache[@intCast(dir.qid.path & (NCACHE - 1))];
    for (c.items) |dp| {
        if (dir.qid.path == dp.path and
            dir.type == dp.type and
            dir.dev == dp.dev)
            return true;
    }
    c.append(a, .{ .path = dir.qid.path, .type = dir.type, .dev = dir.dev }) catch err("malloc failure");
    return false;
}

fn err(s: []const u8) noreturn {
    libc.fprint(2, "du: %s: %r\n", .{s});
    libc.exits(s);
}

fn warn(s: []const u8) i64 {
    if (!fflag)
        libc.fprint(2, "du: %s: %r\n", .{s});
    return 0;
}

/// round up n to nearest block
fn blkmultiple(n: i64) i64 {
    if (blocksize == 1) // no quantization
        return n;
    return roundup(n, blocksize);
}
