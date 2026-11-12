//! test - set status according to condition
//! from cmd/test.c
//!
//!  POSIX standard
//!     test expression
//!     [ expression ]
//!
//!  Plan 9 additions:
//!     -A file exists and is append-only
//!     -L file exists and is exclusive-use
//!     -T file exists and is temporary
//!
//! DIFF: the arguments are a slice; the C's EQ treats a nil argument
//! (past the end) as equal to nothing, which `eq` keeps with an
//! optional.  Numbers are Plan 9's 32-bit long, as strtol returns them.

const std = @import("std");
const libc = @import("libc");

var ap: usize = 0;
var ac: usize = 0;
var av: []const []const u8 = &.{};

fn eq(a: ?[]const u8, b: []const u8) bool {
    const x = a orelse return false;
    return std.mem.eql(u8, x, b);
}

pub fn main(argv: []const []const u8) void {
    ac = argv.len;
    av = argv;
    ap = 1;
    if (ac > 0 and eq(argv[0], "[")) {
        ac -= 1;
        if (!eq(argv[ac], "]"))
            synbad("] missing", "");
    }
    if (ac <= 1)
        libc.exits("usage");
    const r = e(true);
    if (nxtarg(true)) |c|
        synbad("unexpected operator/operand: ", c);
    libc.exits(if (r) null else "false");
}

fn nxtarg(mt: bool) ?[]const u8 {
    if (ap >= ac) {
        if (mt) {
            ap += 1;
            return null;
        }
        synbad("argument expected", "");
    }
    ap += 1;
    return av[ap - 1];
}

fn nxtintarg(pans: *i32) bool {
    if (ap < ac and isint(av[ap], pans)) {
        ap += 1;
        return true;
    }
    return false;
}

fn e(eval: bool) bool {
    var p1 = e1(eval);
    while (true) {
        const op = nxtarg(true) orelse break;
        if (!eq(op, "-o")) {
            ap -= 1;
            return p1;
        }
        if (!p1 and eval)
            p1 = p1 or e1(true)
        else
            _ = e1(false);
    }
    return p1;
}

fn e1(eval: bool) bool {
    var p1 = e2(eval);
    while (true) {
        const op = nxtarg(true) orelse break;
        if (!eq(op, "-a")) {
            ap -= 1;
            return p1;
        }
        if (p1 and eval)
            p1 = p1 and e2(true)
        else
            _ = e2(false);
    }
    return p1;
}

fn e2(eval: bool) bool {
    var p1 = false;
    while (true) {
        const op = nxtarg(true) orelse return !p1;
        if (!eq(op, "!"))
            break;
        p1 = !p1;
    }
    ap -= 1;
    return p1 != e3(eval);
}

fn e3(eval: bool) bool {
    var int1: i32 = 0;
    var int2: i32 = 0;

    const a = nxtarg(false);
    if (eq(a, "(")) {
        const p1 = e(eval);
        if (!eq(nxtarg(false), ")"))
            synbad(") expected", "");
        return p1;
    }

    if (eq(a, "-A"))
        return eval and hasmode(nxtarg(false).?, libc.DMAPPEND);

    if (eq(a, "-L"))
        return eval and hasmode(nxtarg(false).?, libc.DMEXCL);

    if (eq(a, "-T"))
        return eval and hasmode(nxtarg(false).?, libc.DMTMP);

    if (eq(a, "-f"))
        return eval and isreg(nxtarg(false).?);

    if (eq(a, "-d"))
        return eval and isdir(nxtarg(false).?);

    if (eq(a, "-r"))
        return eval and tio(nxtarg(false).?, libc.AREAD);

    if (eq(a, "-w"))
        return eval and tio(nxtarg(false).?, libc.AWRITE);

    if (eq(a, "-x"))
        return eval and tio(nxtarg(false).?, libc.AEXEC);

    if (eq(a, "-e"))
        return eval and tio(nxtarg(false).?, libc.AEXIST);

    if (eq(a, "-c"))
        return false;

    if (eq(a, "-b"))
        return false;

    if (eq(a, "-u"))
        return false;

    if (eq(a, "-g"))
        return false;

    if (eq(a, "-s"))
        return eval and fsizep(nxtarg(false).?);

    if (eq(a, "-t")) {
        if (ap >= ac)
            return eval and isatty(1)
        else if (nxtintarg(&int1))
            return eval and isatty(int1)
        else
            synbad("not a valid file descriptor number ", "");
    }

    if (eq(a, "-n"))
        return !eq(nxtarg(false), "");
    if (eq(a, "-z"))
        return eq(nxtarg(false), "");

    const p2 = nxtarg(true) orelse return !eq(a, "");
    if (eq(p2, "="))
        return eq(nxtarg(false), a.?);

    if (eq(p2, "!="))
        return !eq(nxtarg(false), a.?);

    if (eq(p2, "-older"))
        return eval and isolder(nxtarg(false).?, a.?);

    if (eq(p2, "-ot"))
        return eval and isolderthan(nxtarg(false).?, a.?);

    if (eq(p2, "-nt"))
        return eval and isnewerthan(nxtarg(false).?, a.?);

    if (isint(a.?, &int1)) {
        if (nxtintarg(&int2)) {
            if (eq(p2, "-eq"))
                return int1 == int2;
            if (eq(p2, "-ne"))
                return int1 != int2;
            if (eq(p2, "-gt"))
                return int1 > int2;
            if (eq(p2, "-lt"))
                return int1 < int2;
            if (eq(p2, "-ge"))
                return int1 >= int2;
            if (eq(p2, "-le"))
                return int1 <= int2;
            ap -= 1;
        }
    }
    ap -= 1;
    return !eq(a, "");
}

fn tio(a: []const u8, f: u32) bool {
    return libc.access(a, f);
}

fn stat(f: []const u8) ?libc.Stat {
    return libc.dirstat(libc.allocator, f) catch null;
}

fn hasmode(f: []const u8, m: u32) bool {
    var dir = stat(f) orelse return false;
    defer dir.deinit(libc.allocator);
    return dir.dir.mode & m != 0;
}

fn isdir(f: []const u8) bool {
    return hasmode(f, libc.DMDIR);
}

fn isreg(f: []const u8) bool {
    var dir = stat(f) orelse return false;
    defer dir.deinit(libc.allocator);
    return dir.dir.mode & libc.DMDIR == 0;
}

fn isatty(fd: i32) bool {
    var d1 = libc.dirfstat(libc.allocator, fd) catch null;
    defer if (d1) |*d| d.deinit(libc.allocator);
    var d2 = stat("/dev/cons");
    defer if (d2) |*d| d.deinit(libc.allocator);
    if (d1 == null or d2 == null)
        return false;
    const x = d1.?.dir;
    const y = d2.?.dir;
    return x.type == y.type and x.dev == y.dev and x.qid.path == y.qid.path;
}

fn fsizep(f: []const u8) bool {
    var dir = stat(f) orelse return false;
    defer dir.deinit(libc.allocator);
    return dir.dir.length > 0;
}

fn synbad(s1: []const u8, s2: []const u8) noreturn {
    _ = libc.write(2, "test: ") catch {};
    if (s1.len != 0)
        _ = libc.write(2, s1) catch {};
    if (s2.len != 0)
        _ = libc.write(2, s2) catch {};
    _ = libc.write(2, "\n") catch {};
    libc.exits("bad syntax");
}

fn isint(s: []const u8, pans: *i32) bool {
    const r = libc.strtol32(s, 0);
    pans.* = r.v;
    return r.n == s.len;
}

fn isolder(pin: []const u8, f: []const u8) bool {
    var dir = stat(f) orelse return false;
    defer dir.deinit(libc.allocator);

    // parse time
    var n: u32 = 0;
    var r = true;
    var p: usize = 0;
    while (p < pin.len) {
        const s = libc.strtoul32(pin[p..], 0);
        var m = s.v;
        p += s.n;
        const c: u8 = if (p < pin.len) pin[p] else 0;
        switch (c) {
            0 => {
                n = m;
                r = false;
            },
            'y', 'M', 'd', 'h', 'm', 's' => {
                // the C's cases fall through, multiplying on the way
                if (c == 'y') m *%= 12;
                if (c == 'y' or c == 'M') m *%= 30;
                if (c == 'y' or c == 'M' or c == 'd') m *%= 24;
                if (c != 'm' and c != 's') m *%= 60;
                if (c != 's') m *%= 60;
                n +%= m;
                p += 1;
            },
            else => synbad("bad time syntax, ", pin),
        }
    }

    if (r)
        n = @truncate(@as(u64, @bitCast(libc.time())) -% n);
    return dir.dir.mtime < n;
}

fn isolderthan(a: []const u8, b: []const u8) bool {
    var ad = stat(a);
    defer if (ad) |*d| d.deinit(libc.allocator);
    var bd = stat(b);
    defer if (bd) |*d| d.deinit(libc.allocator);
    if (ad == null or bd == null)
        return false;
    return ad.?.dir.mtime > bd.?.dir.mtime;
}

fn isnewerthan(a: []const u8, b: []const u8) bool {
    var ad = stat(a);
    defer if (ad) |*d| d.deinit(libc.allocator);
    var bd = stat(b);
    defer if (bd) |*d| d.deinit(libc.allocator);
    if (ad == null or bd == null)
        return false;
    return ad.?.dir.mtime < bd.?.dir.mtime;
}
