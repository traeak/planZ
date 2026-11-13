//! factor - factor a number
//! from cmd/factor.c

const libc = @import("libc");

const wheel = [_]f64{
    2, 10, 2, 4, 2, 4, 6, 2, 6, 4,
    2, 4,  6, 6, 2, 6, 4, 2, 6, 4,
    6, 8,  4, 2, 4, 2, 4, 8, 6, 4,
    6, 2,  4, 6, 2, 6, 6, 4, 2, 4,
    6, 2,  6, 4, 2, 4, 2, 10,
};

var bin: libc.Biobuf = .{};

pub fn main(argv: []const []const u8) void {
    if (argv.len > 1) {
        for (argv[1..]) |a|
            factor(libc.atof(a));
        libc.exits(null);
    }

    bin.init(0, libc.OREAD);
    while (true) {
        const l = bin.rdline('\n') orelse break;
        const n = libc.atof(l);
        if (n <= 0)
            break;
        factor(n);
    }
    libc.exits(null);
}

/// n/d's fraction is 0: the C's modf(n/d, &quot) == 0, with quot.
fn divides(n: f64, d: f64, quot: *f64) bool {
    const m = libc.modf(n / d);
    quot.* = m.i;
    return m.f == 0;
}

fn factor(n_: f64) void {
    var n = n_;
    var quot: f64 = 0;
    libc.print("%.0f\n", .{n});
    if (n == 0)
        return;
    var s = libc.sqrt(n) + 1;
    for ([_]f64{ 2, 3, 5, 7 }) |p| {
        while (divides(n, p, &quot)) {
            libc.print("     %.0f\n", .{p});
            n = quot;
            s = libc.sqrt(n) + 1;
        }
    }
    var d: f64 = 1;
    var i: usize = 1;
    while (true) {
        d += wheel[i];
        while (divides(n, d, &quot)) {
            libc.print("     %.0f\n", .{d});
            n = quot;
            s = libc.sqrt(n) + 1;
        }
        i += 1;
        if (i >= wheel.len) {
            i = 0;
            if (d > s)
                break;
        }
    }
    if (n > 1)
        libc.print("     %.0f\n", .{n});
    libc.print("\n", .{});
}
