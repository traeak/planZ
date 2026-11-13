//! primes - generate primes
//! from cmd/primes.c

const libc = @import("libc");

const big: f64 = 9.007199254740992e15;

const pt = [_]i32{
    2,   3,   5,   7,   11,  13,  17,  19,  23,  29,
    31,  37,  41,  43,  47,  53,  59,  61,  67,  71,
    73,  79,  83,  89,  97,  101, 103, 107, 109, 113,
    127, 131, 137, 139, 149, 151, 157, 163, 167, 173,
    179, 181, 191, 193, 197, 199, 211, 223, 227, 229,
};
const wheel = [_]f64{
    10, 2, 4, 2, 4, 6, 2, 6, 4, 2,
    4,  6, 6, 2, 6, 4, 2, 6, 4, 6,
    8,  4, 2, 4, 2, 4, 8, 6, 4, 6,
    2,  4, 6, 2, 6, 6, 4, 2, 4, 6,
    2,  6, 4, 2, 4, 2, 10, 2,
};
var table: [1000]u8 = @splat(0);
const bittab = [_]u8{ 1, 2, 4, 8, 16, 32, 64, 128 };

const tsiz8 = table.len * 8;

fn usage() noreturn {
    libc.fprint(2, "usage: %s [start [finish]]\n", .{libc.argv0});
    libc.exits("limits");
}

fn ouch() noreturn {
    libc.fprint(2, "limits exceeded\n", .{});
    libc.exits("limits");
}

var bin: libc.Biobuf = .{};

pub fn main(argv: []const []const u8) void {
    var args = libc.Args.init(argv);
    while (args.next()) |_|
        usage();
    const rest = args.rest();

    var nn: f64 = 0;
    var limit = big;
    switch (rest.len) {
        0 => {
            bin.init(0, libc.OREAD);
            while (bin.rdline('\n')) |l| {
                if (l[0] == '\n')
                    continue;
                nn = libc.atof(l);
                if (nn < 0)
                    libc.sysfatal("negative start", .{});
                break;
            }
            bin.term() catch {};
        },
        1, 2 => {
            if (rest.len == 2) {
                limit = libc.atof(rest[1]);
                if (limit < nn)
                    libc.exits(null);
                if (limit > big)
                    ouch();
            }
            nn = libc.atof(rest[0]);
        },
        else => usage(),
    }

    if (nn < 0 or nn > big)
        ouch();
    if (nn == 0)
        nn = 1;

    if (nn < 230) {
        for (pt) |p| {
            if (@as(f64, @floatFromInt(p)) < nn)
                continue;
            if (@as(f64, @floatFromInt(p)) > limit)
                libc.exits(null);
            libc.print("%d\n", .{p});
        }
        nn = 230;
    }

    nn = 2 * libc.modf(nn / 2).i + 1;
    while (true) {
        // clear the sieve table.
        @memset(&table, 0);
        // run the sieve.
        const v = libc.sqrt(nn + tsiz8);
        mark(nn, 3);
        mark(nn, 5);
        mark(nn, 7);
        var i: usize = 0;
        var k: f64 = 11;
        while (k <= v) : (k += wheel[i]) {
            mark(nn, @intFromFloat(k));
            i += 1;
            if (i >= wheel.len)
                i = 0;
        }
        // now get the primes from the table
        // and print them.
        var j: usize = 0;
        while (j < tsiz8) : (j += 2) {
            if (table[j >> 3] & bittab[j & 7] != 0)
                continue;
            const temp = nn + @as(f64, @floatFromInt(j));
            if (temp > limit)
                libc.exits(null);
            libc.print("%.0f\n", .{temp});
        }
        nn += tsiz8;
    }
}

fn mark(nn: f64, k: i32) void {
    const kf: f64 = @floatFromInt(k);
    const t1 = libc.modf(nn / kf).i;
    // the C's long j = k*t1 - nn: a double truncated to 32 bits
    var j: i32 = @intFromFloat(kf * t1 - nn);
    if (j < 0)
        j += k;
    while (j < tsiz8) : (j += k)
        table[@intCast(j >> 3)] |= bittab[@intCast(j & 7)];
}
