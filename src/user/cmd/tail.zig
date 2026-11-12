//! tail command, posix plus v10 option -r.
//! the simple command tail -c, legal in v10, is illegal
//! from cmd/tail.c
//!
//! DIFF: the buffers are slices from the allocator (keep, reverse) or
//! the program's data (skip, copy); the C has Bsize arrays on the
//! stack and realloc'd pointers.

const std = @import("std");
const libc = @import("libc");

const Bsize = libc.Bsize;

var fend: i64 = 0;
var count: i64 = 0;
var anycount: i32 = 0;
var follow = false;
var file: i32 = 0;
const umsg = "usage: tail [-n N] [-c N] [-f] [-r] [+-N[bc][fr]] [file]";

var bout: libc.Biobuf = .{};
var origin: enum { BEG, END } = .END;
var units: enum { CHARS, LINES } = .LINES;
var dir: enum { FWD, REV } = .FWD;

const a = libc.allocator;

pub fn main(argv_: []const []const u8) void {
    var argv = argv_;
    bout.init(1, libc.OWRITE);
    outer: while (argv.len > 1 and argv[1].len > 0 and (argv[1][0] == '-' or argv[1][0] == '+')) : (argv = argv[1..]) {
        const arg = argv[1];
        if (getnumber(arg)) {
            suffix(arg);
            continue;
        } else if (arg[0] == '-') {
            const c: u8 = if (arg.len > 1) arg[1] else 0;
            switch (c) {
                'c', 'n' => {
                    if (c == 'c')
                        units = .CHARS;
                    if (getnumber(arg[2..]))
                        continue;
                    if (argv.len > 2 and getnumber(argv[2])) {
                        argv = argv[1..];
                        continue;
                    }
                    usage();
                },
                'r' => {
                    dir = .REV;
                    continue;
                },
                'f' => {
                    follow = true;
                    continue;
                },
                '-' => argv = argv[1..],
                else => {},
            }
        }
        break :outer;
    }
    if (dir == .REV and (units == .CHARS or follow or origin == .BEG))
        fatal("incompatible options");
    if (anycount == 0)
        count = if (dir == .REV) std.math.maxInt(i32) else 10;
    if (origin == .BEG and units == .LINES and count > 0)
        count -= 1;
    if (argv.len > 2)
        usage();
    if (argv.len > 1)
        file = libc.open(argv[1], libc.OREAD) catch fatal(argv[1]);
    const seekable = isseekable(file);

    if (!seekable and origin == .END)
        keep()
    else if (!seekable and origin == .BEG)
        skip()
    else if (units == .CHARS and origin == .END) {
        _ = tseek(-count, 2);
        copy();
    } else if (units == .CHARS and origin == .BEG) {
        _ = tseek(count, 0);
        copy();
    } else if (units == .LINES and origin == .END)
        reverse()
    else if (units == .LINES and origin == .BEG)
        skip();
    if (follow and (seekable or fend == 0)) {
        var sb0: ?libc.Stat = null;
        var sb1: ?libc.Stat = null;
        while (true) {
            trunc(&sb1, &sb0);
            copy();
            trunc(&sb0, &sb1);
            _ = libc.sys.sleep(5000);
        }
    }
    bout.term() catch {};
}

fn trunc(old: *?libc.Stat, new: *?libc.Stat) void {
    var d = libc.dirfstat(a, file) catch return;
    var olength: i64 = 0;
    if (old.*) |o|
        olength = o.dir.length;
    if (d.dir.length < olength)
        d.dir.length = tseek(0, 0);
    if (new.*) |*n|
        n.deinit(a);
    new.* = d;
}

fn suffix(s: []const u8) void {
    var i: usize = 0;
    while (i < s.len and std.mem.findScalar(u8, "0123456789+-", s[i]) != null)
        i += 1;
    const c: u8 = if (i < s.len) s[i] else 0;
    switch (c) {
        'b', 'c', 'l' => {
            if (c == 'b') {
                count *%= 1024;
                if (count < 0)
                    fatal("too big");
            }
            if (c == 'b' or c == 'c')
                units = .CHARS;
            i += 1;
        },
        else => {},
    }
    const d: u8 = if (i < s.len) s[i] else 0;
    switch (d) {
        'r' => dir = .REV,
        'f' => follow = true,
        0 => {},
        else => usage(),
    }
}

var buf: [Bsize]u8 = undefined;

/// read past head of the file to find tail
fn skip() void {
    if (units == .CHARS) {
        while (count > 0) {
            var n: usize = if (count < Bsize) @intCast(count) else Bsize;
            n = tread(buf[0..n]);
            if (n == 0)
                return;
            count -= @intCast(n);
        }
    } else { // units == LINES
        var n: usize = 0;
        var i: usize = 0;
        while (count > 0) {
            n = tread(&buf);
            if (n == 0)
                return;
            i = 0;
            while (i < n and count > 0) : (i += 1) {
                if (buf[i] == '\n')
                    count -= 1;
            }
        }
        twrite(buf[i..n]);
    }
    copy();
}

fn copy() void {
    while (true) {
        const n = tread(&buf);
        if (n == 0)
            break;
        twrite(buf[0..n]);
        bout.flush() catch {}; // for FWD on pipe; else harmless
    }
}

/// read whole file, keeping the tail
///   complexity is length(file)*length(tail).
///   could be linear.
fn keep() void {
    var len: usize = 0;
    var b: []u8 = &.{};
    var n: usize = 1;
    while (n != 0) {
        if (len + Bsize > b.len) {
            b = a.realloc(b, b.len + 2 * Bsize + 1) catch fatal("out of space");
        }
        const bufsiz = b.len - 1;
        while (n != 0 and len < bufsiz) : (len += n)
            n = tread(b[len..bufsiz]);
        if (count >= len)
            continue;
        var j: usize = undefined;
        if (units == .CHARS) {
            j = len - @as(usize, @intCast(count));
        } else {
            // units == LINES
            j = if (b[len - 1] == '\n') len - 1 else len;
            var k: i64 = 0;
            while (j > 0) : (j -= 1) {
                if (b[j - 1] == '\n') {
                    k += 1;
                    if (k >= count)
                        break;
                }
            }
        }
        std.mem.copyForwards(u8, b[0 .. len - j], b[j..len]);
        len -= j;
    }
    if (dir == .REV) {
        if (len > 0 and b[len - 1] != '\n') {
            b[len] = '\n';
            len += 1;
        }
        var j = len - 1;
        while (j > 0) : (j -= 1) {
            if (b[j - 1] == '\n') {
                twrite(b[j..len]);
                count -= 1;
                if (count <= 0)
                    return;
                len = j;
            }
        }
    }
    if (count > 0)
        twrite(b[0..len]);
}

/// count backward and print tail of file
fn reverse() void {
    var len: usize = 0;
    var n: usize = 0;
    var b: []u8 = &.{};
    var pos = tseek(0, 2);
    var first = true;

    while (pos > 0 and count > 0) : (first = false) {
        n = if (pos > Bsize) Bsize else @intCast(pos);
        pos -= @intCast(n);
        if (len + n > if (b.len > 0) b.len - 1 else 0) {
            b = a.realloc(b, b.len + 2 * Bsize + 1) catch fatal("out of space");
        }
        std.mem.copyBackwards(u8, b[n .. n + len], b[0..len]);
        len += n;
        _ = tseek(pos, 0);
        if (tread(b[0..n]) != n)
            fatal("length error");
        if (first and b[len - 1] != '\n') {
            b[len] = '\n';
            len += 1;
        }
        n = len - 1;
        while (n > 0 and count > 0) : (n -= 1) {
            if (b[n - 1] == '\n') {
                count -= 1;
                if (dir == .REV)
                    twrite(b[n..len]);
                len = n;
            }
        }
    }
    if (dir == .FWD) {
        if (n != 0)
            _ = tseek(pos + @as(i64, @intCast(n)) + 1, 0)
        else
            _ = tseek(0, 0);
        copy();
    } else if (count > 0)
        twrite(b[0..len]);
}

fn tseek(o: i64, p: u32) i64 {
    return libc.seek(file, o, p) catch fatal("");
}

fn tread(b: []u8) usize {
    return libc.read(file, b) catch fatal("");
}

fn twrite(s: []const u8) void {
    if ((bout.write(s) catch fatal("")) != s.len)
        fatal("");
}

fn getnumber(s0: []const u8) bool {
    var s = s0;
    var signed = false;
    var plus = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        plus = s[0] == '+';
        signed = true;
        s = s[1..];
    }
    if (s.len == 0 or s[0] < '0' or s[0] > '9')
        return false;
    // DIFF: the C looks at s[-1] whether or not there was a sign; here
    // a '+' counts only as the sign.
    if (signed and plus)
        origin = .BEG;
    anycount += 1;
    if (anycount > 1)
        fatal("excess option");
    count = libc.atoi(s);

    // check range of count
    if (count < 0 or count > std.math.maxInt(i32))
        fatal("too big");
    return true;
}

fn fatal(s: []const u8) noreturn {
    var b: [libc.ERRMAX]u8 = undefined;
    const e = libc.rerrstr(&b);
    libc.fprint(2, "tail: %s: %s\n", .{ s, e });
    libc.exits(s);
}

fn usage() noreturn {
    libc.fprint(2, "%s\n", .{umsg});
    libc.exits("usage");
}

fn isseekable(fd: i32) bool {
    fend = libc.seek(fd, 0, 2) catch -1;
    return fend > 0 and (libc.seek(fd, 0, 0) catch -1) == 0;
}
