//! tr - translate characters
//! from cmd/tr.c
//!
//! DIFF: a specification is a slice and a position in it, where the C
//! walks a NUL-terminated string; the end of the slice reads as the C's
//! 0 byte.

const std = @import("std");
const libc = @import("libc");

/// Control block controlling specification parse
const Pcb = struct {
    base: []const u8 = "", // start of specification
    current: usize = 0, // current parse point
    last: i64 = 0, // last Rune returned
    final: i64 = 0, // final Rune in a span
};

const bits = [8]u8{ 1, 2, 4, 8, 16, 32, 64, 128 };

fn setbit(a: []u8, c: i64) void {
    const i: usize = @intCast(c);
    a[i / 8] |= bits[i & 7];
}

fn clearbit(a: []u8, c: i64) void {
    const i: usize = @intCast(c);
    a[i / 8] &= ~bits[i & 7];
}

fn bitset(a: []const u8, c: i64) bool {
    const i: usize = @intCast(c);
    return a[i / 8] & bits[i & 7] != 0;
}

var f: [(libc.Runemax + 1) / 8]u8 = @splat(0);
var t: [(libc.Runemax + 1) / 8]u8 = @splat(0);
var wbuf: [4096]u8 = undefined;
var wptr: usize = 0;

var pfrom: Pcb = .{};
var pto: Pcb = .{};

var cflag = false;
var dflag = false;
var sflag = false;

fn usage() noreturn {
    libc.fprint(2, "usage: %s [-cds] [string1 [string2]]\n", .{libc.argv0});
    libc.exits("usage");
}

pub fn main(argv: []const []const u8) void {
    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        's' => sflag = true,
        'd' => dflag = true,
        'c' => cflag = true,
        else => usage(),
    };
    const rest = args.rest();
    if (rest.len > 0)
        pinit(&pfrom, rest[0]);
    if (rest.len > 1)
        pinit(&pto, rest[1]);
    if (rest.len > 2)
        usage();
    if (dflag) {
        if ((sflag and rest.len != 2) or (!sflag and rest.len != 1))
            usage();
        delete();
    } else {
        if (rest.len != 2)
            usage();
        if (cflag)
            complement()
        else
            translit();
    }
    libc.exits(null);
}

fn delete() void {
    if (cflag) {
        @memset(&f, 0xff);
        while (true) {
            const c = canon(&pfrom);
            if (c < 0) break;
            clearbit(&f, c);
        }
    } else {
        while (true) {
            const c = canon(&pfrom);
            if (c < 0) break;
            setbit(&f, c);
        }
    }
    if (sflag) {
        while (true) {
            const c = canon(&pto);
            if (c < 0) break;
            setbit(&t, c);
        }
    }

    var last: i64 = libc.Runemax + 1;
    while (readrune(0)) |c| {
        if (!bitset(&f, c) and (c != last or !bitset(&t, c))) {
            last = c;
            writerune(1, c);
        }
    }
    wflush(1);
}

fn complement() void {
    var lastc: i64 = 0;
    var high: i64 = 0;
    var from: i64 = undefined;
    var to: i64 = undefined;
    while (true) {
        from = canon(&pfrom);
        if (from < 0) break;
        if (from > high) high = from;
        setbit(&f, from);
    }
    while (true) {
        to = canon(&pto);
        if (to <= 0) break;
        if (to > high) high = to;
        setbit(&t, to);
    }
    prewind(&pto);
    const p = libc.allocator.alloc(i64, @intCast(high + 1)) catch libc.sysfatal("no memory", .{});
    var i: i64 = 0;
    while (i <= high) : (i += 1) {
        if (!bitset(&f, i)) {
            to = canon(&pto);
            if (to < 0)
                to = lastc
            else
                lastc = to;
            p[@intCast(i)] = to;
        } else p[@intCast(i)] = i;
    }
    if (sflag) {
        lastc = libc.Runemax + 1;
        while (readrune(0)) |r| {
            from = r;
            if (from > high)
                from = to
            else
                from = p[@intCast(from)];
            if (from != lastc or !bitset(&t, from)) {
                lastc = from;
                writerune(1, from);
            }
        }
    } else {
        while (readrune(0)) |r| {
            from = r;
            if (from > high)
                from = to
            else
                from = p[@intCast(from)];
            writerune(1, from);
        }
    }
    wflush(1);
}

fn translit() void {
    var lastc: i64 = 0;
    var high: i64 = 0;
    var from: i64 = undefined;
    var to: i64 = undefined;
    while (true) {
        from = canon(&pfrom);
        if (from < 0) break;
        if (from > high) high = from;
    }
    prewind(&pfrom);
    const p = libc.allocator.alloc(i64, @intCast(high + 1)) catch libc.sysfatal("no memory", .{});
    for (p, 0..) |*x, k| x.* = @intCast(k);
    while (true) {
        from = canon(&pfrom);
        if (from < 0) break;
        to = canon(&pto);
        if (to < 0)
            to = lastc
        else
            lastc = to;
        if (bitset(&f, from) and p[@intCast(from)] != to)
            libc.sysfatal("ambiguous translation", .{});
        setbit(&f, from);
        p[@intCast(from)] = to;
        setbit(&t, to);
    }
    while (true) {
        to = canon(&pto);
        if (to < 0) break;
        setbit(&t, to);
    }
    if (sflag) {
        lastc = libc.Runemax + 1;
        while (readrune(0)) |r| {
            from = r;
            if (from <= high)
                from = p[@intCast(from)];
            if (from != lastc or !bitset(&t, from)) {
                lastc = from;
                writerune(1, from);
            }
        }
    } else {
        while (readrune(0)) |r| {
            from = r;
            if (from <= high)
                from = p[@intCast(from)];
            writerune(1, from);
        }
    }
    wflush(1);
}

var rbuf: [4096]u8 = undefined;
var ri: usize = 0;
var rn: usize = 0;

/// The next rune of fd, or null at the end.
fn readrune(fd: i32) ?i64 {
    var j = ri;
    while (true) {
        if (ri >= rn) {
            wflush(1);
            if (j != ri)
                std.mem.copyForwards(u8, rbuf[0 .. rn - j], rbuf[j..rn]);
            ri = rn - j;
            const n = libc.read(fd, rbuf[ri..]) catch libc.sysfatal("read error: %r", .{});
            if (n == 0) {
                rn = 0; // DIFF: the C leaves n at 0 too
                return null;
            }
            j = 0;
            rn = n + ri;
        }
        ri += 1;
        if (libc.fullrune(rbuf[j..ri]))
            break;
    }
    return libc.chartorune(rbuf[j..rn]).r;
}

fn writerune(fd: i32, r: i64) void {
    var buf: [libc.UTFmax]u8 = undefined;
    const n = libc.runetochar(&buf, @truncate(@as(u64, @bitCast(r))));
    if (wptr + n >= wbuf.len)
        wflush(fd);
    @memcpy(wbuf[wptr..][0..n], buf[0..n]);
    wptr += n;
}

fn wflush(fd: i32) void {
    if (wptr > 0) {
        const n = libc.write(fd, wbuf[0..wptr]) catch libc.sysfatal("write error: %r", .{});
        if (n != wptr)
            libc.sysfatal("write error: %r", .{});
    }
    wptr = 0;
}

/// The rune at position s of spec, as the C reads it: past the end is
/// the string's 0 byte.
fn runeat(spec: []const u8, s: usize) struct { r: i64, n: usize } {
    if (s >= spec.len)
        return .{ .r = 0, .n = 1 };
    const d = libc.chartorune(spec[s..]);
    return .{ .r = d.r, .n = d.n };
}

/// The rune at position s_ of spec, with its escapes; returns it and
/// the position after it.
fn getrune(spec: []const u8, s_: usize) struct { r: i64, s: usize } {
    var s = s_;
    const d = runeat(spec, s);
    s += d.n;
    var rp: i64 = d.r;
    if (rp == '\\' and s < spec.len) {
        var n: i64 = 0;
        if (spec[s] == 'x') {
            s += 1;
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                const save = s;
                const e = runeat(spec, s);
                s += e.n;
                const r = e.r;
                if ('0' <= r and r <= '9')
                    n = 16 * n + r - '0'
                else if ('a' <= r and r <= 'f')
                    n = 16 * n + r - 'a' + 10
                else if ('A' <= r and r <= 'F')
                    n = 16 * n + r - 'A' + 10
                else {
                    if (i == 0)
                        rp = 'x'
                    else
                        rp = n;
                    return .{ .r = rp, .s = save };
                }
            }
        } else {
            var i: usize = 0;
            while (i < 3) : (i += 1) {
                const save = s;
                const e = runeat(spec, s);
                s += e.n;
                const r = e.r;
                if ('0' <= r and r <= '7')
                    n = 8 * n + r - '0'
                else {
                    if (i == 0)
                        return .{ .r = r, .s = s };
                    return .{ .r = n, .s = save };
                }
            }
            if (n > 0o377)
                libc.sysfatal("character > 0377", .{});
        }
        rp = n;
    }
    return .{ .r = rp, .s = s };
}

fn canon(p: *Pcb) i64 {
    if (p.final >= 0) {
        if (p.last < p.final) {
            p.last += 1;
            return p.last;
        }
        p.final = -1;
    }
    if (p.current >= p.base.len)
        return -1;
    if (p.base[p.current] == '-' and p.last >= 0 and p.current + 1 < p.base.len) {
        const g = getrune(p.base, p.current + 1);
        p.current = g.s;
        if (g.r < p.last)
            libc.sysfatal("invalid range specification", .{});
        if (g.r > p.last) {
            p.final = g.r;
            p.last += 1;
            return p.last;
        }
    }
    const g = getrune(p.base, p.current);
    p.current = g.s;
    p.last = g.r;
    return p.last;
}

fn pinit(p: *Pcb, cp: []const u8) void {
    p.base = cp;
    p.current = 0;
    p.last = -1;
    p.final = -1;
}

fn prewind(p: *Pcb) void {
    p.current = 0;
    p.last = -1;
    p.final = -1;
}
