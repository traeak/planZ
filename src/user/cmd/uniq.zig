//! uniq - report repeated lines in a file
//! from cmd/uniq.c

const std = @import("std");
const libc = @import("libc");

var fields: usize = 0;
var letters: usize = 0;
var linec: i32 = 0;
var mode: u8 = 0;
var uniq: i32 = 0;
var fin: libc.Biobuf = .{};
var fout: libc.Biobuf = .{};

/// A line, without its newline.  DIFF: a slice of a Bsize buffer, where
/// the C keeps a NUL-terminated string.
const Line = struct {
    buf: [libc.Bsize]u8 = undefined,
    len: usize = 0,

    fn s(l: *const Line) []const u8 {
        return l.buf[0..l.len];
    }
};

var b1: Line = .{};
var b2: Line = .{};

pub fn main(argv_: []const []const u8) void {
    var argv = argv_;
    var f: i32 = 0;
    while (argv.len > 1) {
        const a = argv[1];
        if (a.len > 0 and a[0] == '-') {
            if (a.len > 1 and a[1] >= '0' and a[1] <= '9')
                fields = @intCast(@max(0, libc.atoi(a[1..])))
            else
                mode = if (a.len > 1) a[1] else 0;
            argv = argv[1..];
            continue;
        }
        if (a.len > 0 and a[0] == '+') {
            letters = @intCast(@max(0, libc.atoi(a[1..])));
            argv = argv[1..];
            continue;
        }
        f = libc.open(a, libc.OREAD) catch
            libc.sysfatal("cannot open %s", .{a});
        break;
    }
    if (argv.len > 2)
        libc.sysfatal("unexpected argument %s", .{argv[2]});
    fin.init(f, libc.OREAD);
    fout.init(1, libc.OWRITE);

    if (gline(&b1))
        libc.exits(null);
    while (true) {
        linec += 1;
        if (gline(&b2)) {
            pline(&b1);
            libc.exits(null);
        }
        if (!equal(b1.s(), b2.s())) {
            pline(&b1);
            linec = 0;
            while (true) {
                linec += 1;
                if (gline(&b1)) {
                    pline(&b2);
                    libc.exits(null);
                }
                if (!equal(b2.s(), b1.s()))
                    break;
            }
            pline(&b2);
            linec = 0;
        }
    }
}

fn gline(buf: *Line) bool {
    const p = fin.rdline('\n') orelse return true;
    if (p.len > libc.Bsize)
        libc.sysfatal("line too long", .{});
    @memcpy(buf.buf[0 .. p.len - 1], p[0 .. p.len - 1]);
    buf.len = p.len - 1;
    return false;
}

fn pline(buf: *const Line) void {
    switch (mode) {
        'u' => if (uniq != 0) {
            uniq = 0;
            return;
        },
        'd' => if (uniq == 0) return,
        'c' => fout.print("%4d ", .{linec}) catch {},
        else => {},
    }
    uniq = 0;
    fout.print("%s\n", .{buf.s()}) catch {};
}

fn equal(x_: []const u8, y_: []const u8) bool {
    var x = x_;
    var y = y_;
    if (fields != 0 or letters != 0) {
        x = skip(x);
        y = skip(y);
    }
    // DIFF: the C walks to the NUL; the end of a slice stands for it
    var i: usize = 0;
    while (true) : (i += 1) {
        const c: u8 = if (i < x.len) x[i] else 0;
        const d: u8 = if (i < y.len) y[i] else 0;
        if (c != d) {
            if (c == 0 and mode == 's')
                return true;
            return false;
        }
        if (c == 0) {
            uniq += 1;
            return true;
        }
    }
}

fn skip(s: []const u8) []const u8 {
    var i: usize = 0;
    var nf: usize = 0;
    while (nf < fields) : (nf += 1) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t'))
            i += 1;
        while (i < s.len and !(s[i] == ' ' or s[i] == '\t'))
            i += 1;
    }
    var nl: usize = 0;
    while (nl < letters and i < s.len) : (nl += 1)
        i += 1;
    return s[i..];
}
