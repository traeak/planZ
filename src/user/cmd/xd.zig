//! xd - hex, octal, decimal, or ASCII dump
//! from cmd/xd.c
//!
//! DIFF: the formats are picked at run time in the C and passed to
//! Bprint; here a format is a pair of indices into the same tables,
//! and the print goes through a switch over all the entries, since
//! src/lib/fmt.zig parses formats at compile time.  The address is a
//! u32, as the C's unsigned long is on amd64.  A file is opened into
//! one static Biobuf, where the C Bopens a new one each time.

const std = @import("std");
const libc = @import("libc");

var odata: [16]u8 = @splat(0);
var data: [16]u8 = @splat(0);
var ndata: usize = 0;
var addr: u32 = 0;
var repeats = false;
var le = false; // little endian
var flush = false;
var abase: usize = 2;

const Narg = 10;

const Fn = enum { fmt0, fmt1, fmt2, fmt3, fmtc };

const Arg = struct {
    ascii: bool = false, // false==none, true==ascii
    loglen: usize = 0, // 0==1, 1==2, 2==4, 3==8
    base: usize = 0, // 0==8, 1==10, 2==16
    fn_: Fn = .fmt2, // function to call with data
    afmt: usize = 0, // format to use to print address: afmt[afmt/3][afmt%3]
    fmt: usize = 0, // format to use to print data: dfmt[fmt/3][fmt%3]
};

var arg: [Narg]Arg = @splat(.{});
var narg: usize = 0;

const fmtfns = [4]Fn{ .fmt0, .fmt1, .fmt2, .fmt3 };

const dfmt = [4 * 3][]const u8{
    " %.3uo",    " %.3ud",    " %.2ux",
    " %.6uo",    " %.5ud",    " %.4ux",
    " %.11luo",  " %.10lud",  " %.8lux",
    " %.22lluo", " %.20llud", " %.16llux",
};

const afmts = [2 * 3][]const u8{
    "%.7luo ", "%.7lud ", "%.7lux ",
    "%7luo ",  "%7lud ",  "%7lux ",
};

var bin: libc.Biobuf = .{};
var bout: libc.Biobuf = .{};

fn flushout(bp: *libc.Biobuf, v: []u8) isize {
    bout.flush() catch {};
    return libc.sys.read(bp.fid, v);
}

fn usage() noreturn {
    libc.fprint(2, "usage: xd [-u] [-r] [-s] [-a{odx}] [-c|{b1w2l4v8}{odx}] ... file ...\n", .{});
    libc.exits("usage");
}

pub fn main(argv_: []const []const u8) void {
    var argv = argv_;
    bout.init(1, libc.OWRITE);
    var err = false;
    while (argv.len > 1 and argv[1].len > 1 and argv[1][0] == '-') {
        argv = argv[1..];
        const a = argv[0];
        // DIFF: at(k) is the C's argv[0][k] after its argv[0]++
        const S = struct {
            fn at(s: []const u8, k: usize) u8 {
                return if (k < s.len) s[k] else 0;
            }
        };
        const at = S.at;
        var k: usize = 1;
        if (at(a, k) == 'r') {
            repeats = true;
            if (at(a, k + 1) != 0)
                usage();
            continue;
        }
        if (at(a, k) == 's') {
            le = true;
            if (at(a, k + 1) != 0)
                usage();
            continue;
        }
        if (at(a, k) == 'u') {
            flush = true;
            if (at(a, k + 1) != 0)
                usage();
            continue;
        }
        if (at(a, k) == 'a') {
            k += 1;
            switch (at(a, k)) {
                'o' => abase = 0,
                'd' => abase = 1,
                'x' => abase = 2,
                else => usage(),
            }
            if (at(a, k + 1) != 0)
                usage();
            continue;
        }
        const ap = &arg[narg];
        initarg();
        while (at(a, k) != 0) : (k += 1) {
            switch (at(a, k)) {
                'c' => {
                    ap.ascii = true;
                    ap.loglen = 0;
                    if (at(a, k + 1) != 0 or at(a, k - 1) != '-')
                        usage();
                },
                'o' => ap.base = 0,
                'd' => ap.base = 1,
                'x' => ap.base = 2,
                'b', '1' => ap.loglen = 0,
                'w', '2' => ap.loglen = 1,
                'l', '4' => ap.loglen = 2,
                'v', '8' => ap.loglen = 3,
                else => usage(),
            }
        }
        ap.fn_ = if (ap.ascii) .fmtc else fmtfns[ap.loglen];
        ap.fmt = ap.loglen * 3 + ap.base;
        ap.afmt = @as(usize, @intFromBool(ap != &arg[0])) * 3 + abase;
    }
    if (narg == 0)
        initarg();
    if (argv.len == 1)
        err = xd(null, false)
    else if (argv.len == 2)
        err = xd(argv[1], false)
    else for (argv[1..]) |name| {
        if (xd(name, true))
            err = true;
    }
    libc.exits(if (err) "error" else null);
}

fn initarg() void {
    const ap = &arg[narg];
    narg += 1;
    if (narg >= Narg) {
        libc.fprint(2, "xd: too many formats (max %d)\n", .{Narg});
        libc.exits("usage");
    }
    ap.ascii = false;
    ap.loglen = 2;
    ap.base = 2;
    ap.fn_ = .fmt2;
    ap.fmt = ap.loglen * 3 + ap.base;
    ap.afmt = @as(usize, @intFromBool(narg > 1)) * 3 + abase;
}

/// Returns true on an error.
fn xd(name: ?[]const u8, title: bool) bool {
    const bp = &bin;
    if (name) |n| {
        bp.open(n, libc.OREAD) catch {
            libc.fprint(2, "xd: can't open %s\n", .{n});
            return true;
        };
    } else bp.init(0, libc.OREAD);
    if (flush)
        bp.setiofn(flushout);
    if (title)
        xprint("%s\n", .{name.?});
    addr = 0;
    var star = false;
    while (true) {
        ndata = bp.read(&data) catch break;
        if (ndata < 16)
            @memset(data[ndata..], 0);
        if (ndata == 16 and repeats) {
            if (addr > 0 and data[0] == odata[0]) {
                if (std.mem.eql(u8, data[1..], odata[1..])) {
                    addr +%= 16;
                    if (!star) {
                        star = true;
                        xprint("*\n", .{});
                    }
                    continue;
                }
            }
            odata = data;
            star = false;
        }
        for (arg[0..narg]) |*ap| {
            printaddr(ap.afmt, addr);
            switch (ap.fn_) {
                .fmt0 => fmt0(ap.fmt),
                .fmt1 => fmt1(ap.fmt),
                .fmt2 => fmt2(ap.fmt),
                .fmt3 => fmt3(ap.fmt),
                .fmtc => fmtc(),
            }
            xprint("\n", .{});
        }
        addr +%= @intCast(ndata);
        if (ndata < 16) {
            printaddr(abase, addr);
            xprint("\n", .{});
            break;
        }
    }
    bp.term() catch {};
    bp.setiofn(null);
    return false;
}

fn printaddr(f: usize, a: u32) void {
    switch (f) {
        inline 0...afmts.len - 1 => |k| xprint(afmts[k], .{a}),
        else => unreachable,
    }
}

fn printdata(f: usize, v: anytype) void {
    switch (f) {
        inline 0...dfmt.len - 1 => |k| xprint(dfmt[k], .{v}),
        else => unreachable,
    }
}

fn fmt0(f: usize) void {
    for (data[0..ndata]) |d|
        printdata(f, d);
}

fn fmt1(f: usize) void {
    var i: usize = 0;
    while (i < ndata) : (i += 2) {
        const v: u16 = if (le)
            @as(u16, data[i + 1]) << 8 | data[i]
        else
            @as(u16, data[i]) << 8 | data[i + 1];
        printdata(f, v);
    }
}

fn be32(d: []const u8) u32 {
    return std.mem.readInt(u32, d[0..4], .big);
}

fn le32(d: []const u8) u32 {
    return std.mem.readInt(u32, d[0..4], .little);
}

fn fmt2(f: usize) void {
    var i: usize = 0;
    while (i < ndata) : (i += 4)
        printdata(f, if (le) le32(data[i..]) else be32(data[i..]));
}

fn fmt3(f: usize) void {
    var i: usize = 0;
    while (i < ndata) : (i += 8) {
        var v: u64 = undefined;
        if (le) {
            v = le32(data[i + 4 ..]);
            v <<= 32;
            v |= le32(data[i..]);
        } else {
            v = be32(data[i..]);
            v <<= 32;
            v |= be32(data[i + 4 ..]);
        }
        printdata(f, v);
    }
}

fn fmtc() void {
    for (data[0..ndata]) |d| {
        switch (d) {
            '\t' => xprint(" %.2s", .{"\\t"}),
            '\r' => xprint(" %.2s", .{"\\r"}),
            '\n' => xprint(" %.2s", .{"\\n"}),
            0x08 => xprint(" %.2s", .{"\\b"}),
            else => if (d >= 0x7F or ' ' > d)
                xprint(" %.2ux", .{d})
            else
                xprint("  %c", .{d}),
        }
    }
}

fn xprint(comptime f: []const u8, args: anytype) void {
    bout.print(f, args) catch {
        libc.fprint(2, "xd: i/o error\n", .{});
        libc.exits("i/o error");
    };
}
