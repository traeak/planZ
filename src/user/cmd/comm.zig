//! comm - select or reject lines common to two sorted files
//! from cmd/comm.c
//!
//! DIFF: a line is a buffer and the length up to its first 0 byte (the
//! C keeps a NUL-terminated string, so a 0 in the input ends the line
//! there too).  The leaders are a length into "\t\t", where the C writes
//! 0 bytes into its string literals.  Plan 9's char is signed, so lines
//! compare as signed bytes, as in the C.

const std = @import("std");
const libc = @import("libc");

const LB = 2048;
var one = false;
var two = false;
var three = false;

/// ldr[i] is the first ldrlen[i] bytes of "\t\t"
var ldrlen = [3]usize{ 0, 1, 2 };

var ib1: libc.Biobuf = .{};
var ib2: libc.Biobuf = .{};

const Line = struct {
    buf: [LB]u8 = undefined,
    len: usize = 0,

    fn s(l: *const Line) []const u8 {
        return l.buf[0..l.len];
    }
};

pub fn main(argv: []const []const u8) void {
    var lb1: Line = .{};
    var lb2: Line = .{};

    var l: usize = 1;
    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        '1' => if (!one) {
            one = true;
            ldrlen[1] = @min(ldrlen[1], 0);
            ldrlen[2] = @min(ldrlen[2], l);
            l -%= 1;
        },
        '2' => if (!two) {
            two = true;
            ldrlen[2] = @min(ldrlen[2], l);
            l -%= 1;
        },
        '3' => three = true,
        else => usage(),
    };
    const files = args.rest();
    if (files.len < 2)
        usage();

    openfil(&ib1, files[0]);
    openfil(&ib2, files[1]);

    if (rd(&ib1, &lb1)) {
        if (rd(&ib2, &lb2))
            libc.exits(null);
        copy(&ib2, &lb2, 2);
    }
    if (rd(&ib2, &lb2))
        copy(&ib1, &lb1, 1);

    while (true) {
        switch (compare(lb1.s(), lb2.s())) {
            0 => {
                wr(&lb1, 3);
                if (rd(&ib1, &lb1)) {
                    if (rd(&ib2, &lb2))
                        libc.exits(null);
                    copy(&ib2, &lb2, 2);
                }
                if (rd(&ib2, &lb2))
                    copy(&ib1, &lb1, 1);
            },
            1 => {
                wr(&lb1, 1);
                if (rd(&ib1, &lb1))
                    copy(&ib2, &lb2, 2);
            },
            else => {
                wr(&lb2, 2);
                if (rd(&ib2, &lb2))
                    copy(&ib1, &lb1, 1);
            },
        }
    }
}

fn usage() noreturn {
    libc.fprint(2, "usage: comm [-123] file1 file2\n", .{});
    libc.exits("usage");
}

/// The next line into buf; true at the end of the file (the C's -1),
/// which drops a last line with no newline.
fn rd(file: *libc.Biobuf, buf: *Line) bool {
    var i: usize = 0;
    var nul: ?usize = null;
    while (file.getc()) |c| {
        buf.buf[i] = c;
        if (c == '\n' or i > LB - 2) {
            buf.len = nul orelse i;
            return false;
        }
        if (c == 0 and nul == null)
            nul = i;
        i += 1;
    }
    return true;
}

fn wr(str: *const Line, n: usize) void {
    switch (n) {
        1 => if (one) return,
        2 => if (two) return,
        3 => if (three) return,
        else => {},
    }
    libc.print("%s%s\n", .{ "\t\t"[0..ldrlen[n - 1]], str.s() });
}

fn copy(ibuf: *libc.Biobuf, lbuf: *Line, n: usize) noreturn {
    while (true) {
        wr(lbuf, n);
        if (rd(ibuf, lbuf))
            break;
    }
    libc.exits(null);
}

fn compare(a: []const u8, b: []const u8) u32 {
    var i: usize = 0;
    while (true) : (i += 1) {
        const ca: i8 = if (i < a.len) @bitCast(a[i]) else 0;
        const cb: i8 = if (i < b.len) @bitCast(b[i]) else 0;
        if (ca != cb)
            return if (ca < cb) 1 else 2;
        if (ca == 0)
            return 0;
    }
}

fn openfil(b: *libc.Biobuf, s_: []const u8) void {
    var s = s_;
    if (std.mem.eql(u8, s, "-"))
        s = "/fd/0";
    b.open(s, libc.OREAD) catch {
        libc.fprint(2, "comm: cannot open %s: %r\n", .{s});
        libc.exits("open");
    };
}
