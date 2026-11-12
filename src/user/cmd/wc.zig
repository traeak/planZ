//! wc -- count things in utf-encoded text files
//! from cmd/wc.c
//!
//! Bugs (the C's):
//!   The only white space characters recognized are ' ', '\t' and '\n', even though
//!   ISO 10646 has many more blanks scattered through it.
//!   Should count characters that cannot occur in any rune (hex f8-ff) separately.
//!   Should count non-canonical runes (e.g. hex c1,80 instead of hex 40).
//!
//! DIFF: the five state tables are made at compile time from the
//! summary table in the C's comment (reproduced below), which is how
//! the C's tables are laid out.

const std = @import("std");
const libc = @import("libc");

const NBUF = 32768; // IOUNIT

var nline: u64 = 0;
var tnline: u64 = 0;
var pline = false;
var nword: u64 = 0;
var tnword: u64 = 0;
var pword = false;
var nrune: u64 = 0;
var tnrune: u64 = 0;
var prune = false;
var nbadr: u64 = 0;
var tnbadr: u64 = 0;
var pbadr = false;
var nchar: u64 = 0;
var tnchar: u64 = 0;
var pchar = false;

pub fn main(argv: []const []const u8) void {
    var status: ?[]const u8 = null;
    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'l' => pline = true,
        'w' => pword = true,
        'r' => prune = true,
        'b' => pbadr = true,
        'c' => pchar = true,
        else => {
            libc.fprint(2, "usage: %s [-lwrbc] [file ...]\n", .{libc.argv0});
            libc.exits("usage");
        },
    };
    const files = args.rest();
    if (!pline and !pword and !prune and !pbadr and !pchar) {
        pline = true;
        pword = true;
        pchar = true;
    }
    if (files.len == 0) {
        count(0, null);
    } else {
        for (files) |name| {
            const fd = libc.open(name, libc.OREAD) catch {
                libc.fprint(2, "%s: %r\n", .{name});
                status = "can't open";
                continue;
            };
            count(fd, name);
            tnline += nline;
            tnword += nword;
            tnrune += nrune;
            tnbadr += nbadr;
            tnchar += nchar;
            libc.close(fd) catch {};
        }
        if (files.len > 1)
            report(tnline, tnword, tnrune, tnbadr, tnchar, "total");
    }
    libc.exits(status);
}

fn report(nl: u64, nw: u64, nr: u64, nb: u64, nc: u64, fname: ?[]const u8) void {
    var line: [128]u8 = undefined;
    var e: usize = 0;
    if (pline)
        e += libc.fmt.snprint(line[e..], " %7llud", .{nl}).len;
    if (pword)
        e += libc.fmt.snprint(line[e..], " %7llud", .{nw}).len;
    if (prune)
        e += libc.fmt.snprint(line[e..], " %7llud", .{nr}).len;
    if (pbadr)
        e += libc.fmt.snprint(line[e..], " %7llud", .{nb}).len;
    if (pchar)
        e += libc.fmt.snprint(line[e..], " %7llud", .{nc}).len;
    const l = if (e > 0) line[1..e] else line[0..0];
    if (fname) |f|
        libc.print("%s %s\n", .{ l, f })
    else
        libc.print("%s\n", .{l});
}

// How it works.  Start in statesp.  Each time we read a character,
// increment various counts, and do state transitions according to the
// following table.  If we're not in statesp or statewd when done, the
// file ends with a partial rune.
//        |                character
//  state |09,20| 0a  |00-7f|80-bf|c0-df|e0-ef|f0-f7|f8-ff
// -------+-----+-----+-----+-----+-----+-----+-----+-----
// statesp|ASP  |ASPN |AWDW |AWDWX|AC2W |AC3W |AC4W |AWDWX
// statewd|ASP  |ASPN |AWD  |AWDX |AC2  |AC3  |AC4  |AWDX
// statec2|ASPX |ASPNX|AWDX |AWDR |AC2X |AC3X |AC4X |AWDX
// statec3|ASPX |ASPNX|AWDX |AC2R |AC2X |AC3X |AC4X |AWDX
// statec4|ASPX |ASPNX|AWDX |AC3R |AC2X |AC3X |AC4X |AWDX
const A = enum(u8) {
    AC2, // enter statec2
    AC2R, // enter statec2, don't count a rune
    AC2W, // enter statec2, count a word
    AC2X, // enter statec2, count a bad rune
    AC3, // enter statec3
    AC3R, // enter statec3, don't count a rune
    AC3W, // enter statec3, count a word
    AC3X, // enter statec3, count a bad rune
    AC4, // enter statec4
    AC4W, // enter statec4, count a word
    AC4X, // enter statec4, count a bad rune
    ASP, // enter statesp
    ASPN, // enter statesp, count a newline
    ASPNX, // enter statesp, count a newline, count a bad rune
    ASPX, // enter statesp, count a bad rune
    AWD, // enter statewd
    AWDR, // enter statewd, don't count a rune
    AWDW, // enter statewd, count a word
    AWDWX, // enter statewd, count a word, count a bad rune
    AWDX, // enter statewd, count a bad rune
};

const S = enum { sp, wd, c2, c3, c4 };

fn mktable(comptime row: [8]A) [256]A {
    @setEvalBranchQuota(10000);
    var t: [256]A = undefined;
    for (0..256) |c| {
        t[c] = switch (c) {
            0x09, 0x20 => row[0],
            0x0a => row[1],
            0x00...0x08, 0x0b...0x1f, 0x21...0x7f => row[2],
            0x80...0xbf => row[3],
            0xc0...0xdf => row[4],
            0xe0...0xef => row[5],
            0xf0...0xf7 => row[6],
            else => row[7],
        };
    }
    return t;
}

const tables = [5][256]A{
    mktable(.{ .ASP, .ASPN, .AWDW, .AWDWX, .AC2W, .AC3W, .AC4W, .AWDWX }), // statesp: looking for the start of a word
    mktable(.{ .ASP, .ASPN, .AWD, .AWDX, .AC2, .AC3, .AC4, .AWDX }), // statewd: looking for the next character in a word
    mktable(.{ .ASPX, .ASPNX, .AWDX, .AWDR, .AC2X, .AC3X, .AC4X, .AWDX }), // statec2: looking for 10xxxxxx to complete a rune
    mktable(.{ .ASPX, .ASPNX, .AWDX, .AC2R, .AC2X, .AC3X, .AC4X, .AWDX }), // statec3: looking for 10xxxxxx,10xxxxxx to complete a rune
    mktable(.{ .ASPX, .ASPNX, .AWDX, .AC3R, .AC2X, .AC3X, .AC4X, .AWDX }), // statec4: looking for 10xxxxxx,10xxxxxx,10xxxxxx to complete a rune
};

var buf: [NBUF]u8 = undefined;

fn count(f: i32, name: ?[]const u8) void {
    var state: S = .sp;

    nline = 0;
    nword = 0;
    nrune = 0;
    nbadr = 0;
    nchar = 0;

    var failed = false;
    while (true) {
        const n = libc.read(f, &buf) catch {
            failed = true;
            break;
        };
        if (n == 0)
            break;
        nchar += n;
        nrune += n; // might be too large, gets decreased later
        for (buf[0..n]) |c| {
            switch (tables[@intFromEnum(state)][c]) {
                .AC2 => state = .c2,
                .AC2R => {
                    state = .c2;
                    nrune -= 1;
                },
                .AC2W => {
                    state = .c2;
                    nword += 1;
                },
                .AC2X => {
                    state = .c2;
                    nbadr += 1;
                },
                .AC3 => state = .c3,
                .AC3R => {
                    state = .c3;
                    nrune -= 1;
                },
                .AC3W => {
                    state = .c3;
                    nword += 1;
                },
                .AC3X => {
                    state = .c3;
                    nbadr += 1;
                },
                .AC4 => state = .c4,
                .AC4W => {
                    state = .c4;
                    nword += 1;
                },
                .AC4X => {
                    state = .c4;
                    nbadr += 1;
                },
                .ASP => state = .sp,
                .ASPN => {
                    state = .sp;
                    nline += 1;
                },
                .ASPNX => {
                    state = .sp;
                    nline += 1;
                    nbadr += 1;
                },
                .ASPX => {
                    state = .sp;
                    nbadr += 1;
                },
                .AWD => state = .wd,
                .AWDR => {
                    state = .wd;
                    nrune -= 1;
                },
                .AWDW => {
                    state = .wd;
                    nword += 1;
                },
                .AWDWX => {
                    state = .wd;
                    nword += 1;
                    nbadr += 1;
                },
                .AWDX => {
                    state = .wd;
                    nbadr += 1;
                },
            }
        }
    }
    if (state != .sp and state != .wd)
        nbadr += 1;
    if (failed)
        libc.fprint(2, "%s: %r\n", .{name orelse ""});
    report(nline, nword, nrune, nbadr, nchar, name);
}
