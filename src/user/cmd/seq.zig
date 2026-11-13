//! seq - print sequences of numbers
//! from cmd/seq.c
//!
//! DIFF: the format, built here or given with -f, is applied by
//! fmt's run-time formatter (libc.runsnprint) into a 256-byte buffer,
//! where the C sprints into it without a bound; a verb that does not
//! fit a float prints fmt's %!v(float) marker where the C's behaviour
//! is undefined.

const std = @import("std");
const libc = @import("libc");

var min: f64 = 1.0;
var max: f64 = 0.0;
var incr: f64 = 1.0;
var constant = false;
var format: ?[]const u8 = null;

fn usage() noreturn {
    libc.fprint(2, "usage: seq [-fformat] [-w] [first [incr]] last\n", .{});
    libc.exits("usage");
}

var fmtbuf: [16]u8 = undefined;

fn buildfmt() void {
    format = "%g\n";
    if (!constant)
        return;
    var maxw: usize = 0;
    var maxp: usize = 0;
    var val = min;
    while (val <= max) : (val += incr) {
        var buf: [32]u8 = undefined;
        const s = libc.fmt.snprint(&buf, "%g", .{val});
        if (std.mem.findScalar(u8, s, 'e') != null)
            return;
        const dp = std.mem.findScalar(u8, s, '.');
        const w = dp orelse s.len;
        const p = if (dp) |d| s.len - d - 1 else 0;
        if (w > maxw)
            maxw = w;
        if (p > maxp)
            maxp = p;
    }
    if (maxp > 0)
        maxw += maxp + 1;
    format = libc.fmt.snprint(fmtbuf[0 .. fmtbuf.len - 1], "%%%d.%df\n", .{ maxw, maxp });
}

pub fn main(argv: []const []const u8) void {
    var ffmt: [4096]u8 = undefined;

    var args = libc.Args.init(argv);
    var rest: []const []const u8 = undefined;
    out: {
        while (args.next()) |c| switch (c) {
            'w' => constant = true,
            'f' => {
                const f = args.value() orelse usage();
                format = f;
                if (f.len == 0 or f[f.len - 1] != '\n')
                    format = libc.fmt.snprint(&ffmt, "%s\n", .{f});
            },
            else => {
                // the C's goto out: the arguments start with this one
                rest = argv[args.i..];
                break :out;
            },
        };
        rest = args.rest();
    }
    if (rest.len < 1 or rest.len > 3)
        usage();
    max = libc.atof(rest[rest.len - 1]);
    if (rest.len > 1)
        min = libc.atof(rest[0]);
    if (rest.len > 2)
        incr = libc.atof(rest[1]);
    if (incr == 0) {
        libc.fprint(2, "seq: zero increment\n", .{});
        libc.exits("zero increment");
    }
    if (format == null)
        buildfmt();
    var val = min;
    while (if (incr > 0) val <= max else val >= max) : (val += incr) {
        var buf: [256]u8 = undefined;
        const s = libc.runsnprint(&buf, format.?, &.{.{ .float = val }});
        if (constant) {
            for (s) |*c| {
                if (c.* != ' ') break;
                c.* = '0';
            }
        }
        _ = libc.write(1, s) catch {};
    }
    libc.exits(null);
}
