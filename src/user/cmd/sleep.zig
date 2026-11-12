//! sleep - suspend execution for an interval
//! from cmd/sleep.c

const libc = @import("libc");

pub fn main(argv: []const []const u8) void {
    const MAXSEC = 0x7ffffc00 / 1000;
    if (argv.len > 1) {
        const a = argv[1];
        const r = libc.strtol(a, 0);
        var n = r.v;
        while (n > MAXSEC) : (n -= MAXSEC)
            _ = libc.sys.sleep(MAXSEC * 1000);
        // no floating point because it is useful to
        // be able to run sleep when bootstrapping
        // a machine.
        var m: i64 = 0;
        var p = r.n;
        if (p < a.len and a[p] == '.') {
            p += 1;
            const f = libc.strtol(a[p..], 10);
            if (f.v > 0) {
                m = f.v;
                switch (f.n) {
                    0 => {},
                    1 => m *= 100,
                    2 => m *= 10,
                    else => m = libc.strtol(a[p..][0..3], 10).v,
                }
            }
        }
        m += n * 1000;
        if (m > 0)
            _ = libc.sys.sleep(@intCast(m));
    }
}
