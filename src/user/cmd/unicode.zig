//! unicode - interpret Unicode characters
//! from cmd/unicode.c
//!
//! DIFF: strchr(hex, c) is true for c == 0 as well, since the C finds
//! the string's terminator; isHexStart keeps that, so an empty argument
//! counts as starting with a hex digit, as in the C.

const std = @import("std");
const libc = @import("libc");

const usagestr = "unicode { [-t] hex hex ... | hexmin-hexmax ... | [-n] char ... }";
const hex = "0123456789abcdefABCDEF";
var numout = false;
var text = false;
var bout: libc.Biobuf = .{};

fn first(s: []const u8) u8 {
    return if (s.len > 0) s[0] else 0;
}

fn isHexStart(c: u8) bool {
    return c == 0 or std.mem.findScalar(u8, hex, c) != null;
}

pub fn main(argv: []const []const u8) void {
    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'n' => numout = true,
        't' => text = true,
        else => {},
    };
    const rest = args.rest();
    bout.init(1, libc.OWRITE);
    if (rest.len == 0) {
        libc.fprint(2, "usage: %s\n", .{usagestr});
        libc.exits("usage");
    }
    if (!numout and libc.utfrune(rest[0], '-') != null)
        libc.exits(range(rest));
    if (numout or !isHexStart(first(rest[0])))
        libc.exits(nums(rest));
    libc.exits(chars(rest));
}

fn range(argv: []const []const u8) ?[]const u8 {
    for (argv) |q| {
        const bad: ?[]const u8 = blk: {
            if (!isHexStart(first(q)))
                break :blk "bad range";
            const a = libc.strtoul32(q, 16);
            var min: i32 = @bitCast(a.v);
            var p = a.n;
            if (min < 0 or min > libc.Runemax or p >= q.len or q[p] != '-')
                break :blk "bad range";
            p += 1;
            if (!isHexStart(if (p < q.len) q[p] else 0))
                break :blk "bad range";
            const b = libc.strtoul32(q[p..], 16);
            const max: i32 = @bitCast(b.v);
            p += b.n;
            if (max < 0 or max > libc.Runemax or max < min or p != q.len)
                break :blk "bad range";
            var i: u32 = 0;
            while (true) {
                bout.print("%.4x %C", .{ min, min }) catch {};
                i += 1;
                if (min == max or i & 7 == 0)
                    bout.print("\n", .{}) catch {}
                else
                    bout.print("\t", .{}) catch {};
                min += 1;
                if (min > max)
                    break;
            }
            break :blk null;
        };
        if (bad) |e| {
            libc.fprint(2, "unicode: bad range %s\n", .{q});
            return e;
        }
    }
    return null;
}

fn nums(argv: []const []const u8) ?[]const u8 {
    for (argv) |arg| {
        var q: usize = 0;
        while (q < arg.len) {
            const d = libc.chartorune(arg[q..]);
            if (d.r == libc.Runeerror) {
                var b: [libc.UTFmax]u8 = undefined;
                const n = libc.runetochar(&b, d.r);
                if (n != d.n or !std.mem.eql(u8, b[0..n], arg[q..][0..@min(n, arg.len - q)])) {
                    libc.fprint(2, "unicode: invalid utf string %s\n", .{arg});
                    return "bad utf";
                }
            }
            bout.print("%.4x\n", .{d.r}) catch {};
            q += d.n;
        }
    }
    return null;
}

fn chars(argv: []const []const u8) ?[]const u8 {
    for (argv) |q| {
        const bad = blk: {
            if (!isHexStart(first(q)))
                break :blk true;
            const a = libc.strtoul32(q, 16);
            const m: i32 = @bitCast(a.v);
            if (m < 0 or m > libc.Runemax or a.n != q.len)
                break :blk true;
            bout.print("%C", .{m}) catch {};
            if (!text)
                bout.print("\n", .{}) catch {};
            break :blk false;
        };
        if (bad) {
            libc.fprint(2, "unicode: bad unicode value %s\n", .{q});
            return "bad char";
        }
    }
    return null;
}
