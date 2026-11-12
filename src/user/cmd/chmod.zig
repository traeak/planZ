//! chmod - change mode
//! from cmd/chmod.c

const libc = @import("libc");
const fcall = libc.fcall;

fn U(x: u32) u32 {
    return x << 6;
}
fn G(x: u32) u32 {
    return x << 3;
}
fn O(x: u32) u32 {
    return x;
}
fn A(x: u32) u32 {
    return U(x) | G(x) | O(x);
}

const DMRWE = fcall.DMREAD | fcall.DMWRITE | fcall.DMEXEC;

pub fn main(argv: []const []const u8) !void {
    if (argv.len < 3) {
        libc.fprint(2, "usage: chmod 0777 file ... or chmod [who]op[rwxalt] file ...\n", .{});
        libc.exits("usage");
    }
    var mode: u32 = undefined;
    var mask: u32 = undefined;
    const r = libc.strtol(argv[1], 8);
    if (r.n == argv[1].len) {
        mode = @truncate(@as(u64, @bitCast(r.v)));
        mask = A(DMRWE);
    } else if (!parsemode(argv[1], &mask, &mode)) {
        libc.fprint(2, "chmod: bad mode: %s\n", .{argv[1]});
        libc.exits("mode");
    }
    var ndir = libc.nulldir();
    const a = libc.allocator;
    for (argv[2..]) |f| {
        var st = libc.dirstat(a, f) catch {
            libc.fprint(2, "chmod: can't stat %s: %r\n", .{f});
            continue;
        };
        ndir.mode = (st.dir.mode & ~mask) | (mode & mask);
        st.deinit(a);
        libc.dirwstat(f, &ndir) catch {
            libc.fprint(2, "chmod: can't wstat %s: %r\n", .{f});
            continue;
        };
    }
}

fn parsemode(spec: []const u8, pmask: *u32, pmode: *u32) bool {
    var s: usize = 0;
    var mask: u32 = fcall.DMAPPEND | fcall.DMEXCL | fcall.DMTMP;
    var done = false;
    while (!done) {
        if (s >= spec.len)
            return false;
        switch (spec[s]) {
            'u' => mask |= U(DMRWE),
            'g' => mask |= G(DMRWE),
            'o' => mask |= O(DMRWE),
            'a' => mask |= A(DMRWE),
            else => done = true,
        }
        if (!done)
            s += 1;
    }
    if (s == 0)
        mask |= A(DMRWE);
    const op = spec[s];
    s += 1;
    if (op != '+' and op != '-' and op != '=')
        return false;
    var mode: u32 = 0;
    while (s < spec.len) : (s += 1) {
        switch (spec[s]) {
            'r' => mode |= A(fcall.DMREAD),
            'w' => mode |= A(fcall.DMWRITE),
            'x' => mode |= A(fcall.DMEXEC),
            'a' => mode |= fcall.DMAPPEND,
            'l' => mode |= fcall.DMEXCL,
            't' => mode |= fcall.DMTMP,
            else => return false,
        }
    }
    if (op == '+' or op == '-')
        mask &= mode;
    if (op == '-')
        mode = ~mode;
    pmask.* = mask;
    pmode.* = mode;
    return true;
}
