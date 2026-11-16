//! date - print the date
//! from cmd/date.c
//!
//! DIFF: the date is formatted into a buffer of 1024 bytes and then
//! written, where the C prints it with %τ; as there, a garbled format
//! writes nothing and is fatal.

const libc = @import("libc");

const Nsec = 1000 * 1000 * 1000;

fn usage() noreturn {
    libc.fprint(2, "usage: date [-itun] [-f fmt] [seconds]\n", .{});
    libc.exits("usage");
}

pub fn main(argv: []const []const u8) void {
    var nflg = false;
    var uflg = false;
    var tz: ?*const libc.Tzone = null;
    var format: []const u8 = "WW MMM _D hh:mm:ss ZZZ YYYY";
    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'n' => nflg = true,
        'u' => uflg = true,
        't' => format = "YYYY-MM-DDThh:mm:ssZZ",
        'i' => format = "YYYY-MM-DD",
        'f' => format = args.value() orelse usage(),
        else => usage(),
    };
    const rest = args.rest();
    var s: i64 = 0;
    var ns: i64 = 0;
    switch (rest.len) {
        0 => {
            ns = libc.nsec();
            s = @divTrunc(ns, Nsec);
            ns = @rem(ns, Nsec);
        },
        1 => {
            s = libc.strtol(rest[0], 0).v;
            ns = 0;
        },
        else => usage(),
    }
    if (!uflg) {
        tz = libc.tzload("local") orelse libc.sysfatal("timezone: %r", .{});
    }
    var tm: libc.Tm = .{};
    libc.tmtimens(&tm, s, @intCast(ns), tz);
    if (nflg)
        libc.print("%lld\n", .{libc.tmnorm(&tm)})
    else {
        var buf: [1024]u8 = undefined;
        var f: libc.fmt.Fmt = .{ .buf = &buf };
        libc.tmfmt(&f, &tm, format) catch libc.sysfatal("%r", .{});
        f.putc('\n');
        libc.writeall(1, buf[0..f.n]) catch libc.sysfatal("%r", .{});
    }
    libc.exits(null);
}
