//! cmp - compare two files
//! from cmd/cmp.c

const libc = @import("libc");

const BUF = 65536;

var sflag = false;
var lflag = false;
var Lflag = false;

fn usage() noreturn {
    libc.fprint(2, "usage: cmp [-lLs] file1 file2 [offset1 [offset2] ]\n", .{});
    libc.exits("usage");
}

fn seekoff(fd: i32, name: []const u8, argv: []const []const u8) []const []const u8 {
    if (argv.len > 0) {
        const a = argv[0];
        if (a.len == 0 or a[0] < '0' or a[0] > '9')
            usage();
        const o = libc.strtol(a, 0).v;
        _ = libc.seek(fd, o, 0) catch {
            if (!sflag)
                libc.fprint(2, "cmp: %s: seek by %lld: %r\n", .{ name, o });
            libc.exits("seek");
        };
        return argv[1..];
    }
    return argv;
}

var buf1: [BUF]u8 = undefined;
var buf2: [BUF]u8 = undefined;

fn rd(fd: i32, b: []u8) isize {
    return libc.sys.read(fd, b);
}

pub fn main(argv: []const []const u8) void {
    var nc: i64 = 1;
    var l: i64 = 1;

    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        's' => sflag = true,
        'l' => lflag = true,
        'L' => Lflag = true,
        else => usage(),
    };
    var rest = args.rest();
    if (rest.len < 2 or rest.len > 4)
        usage();
    const name1 = rest[0];
    const name2 = rest[1];
    rest = rest[2..];
    const f1 = libc.open(name1, libc.OREAD) catch {
        if (!sflag) libc.fprint(2, "%s: %r\n", .{name1});
        libc.exits("open");
    };
    const f2 = libc.open(name2, libc.OREAD) catch {
        if (!sflag) libc.fprint(2, "%s: %r\n", .{name2});
        libc.exits("open");
    };
    rest = seekoff(f1, name1, rest);
    rest = seekoff(f2, name2, rest);
    if (rest.len > 0)
        usage();

    // DIFF: indices for the C's pointers; an end may fall before its
    // start after a read error, as in C, so they are signed.
    var b1s: isize = 0;
    var b1e: isize = 0;
    var b2s: isize = 0;
    var b2e: isize = 0;
    while (true) {
        if (b1s >= b1e) {
            if (b1s >= BUF)
                b1s = 0;
            const n = rd(f1, buf1[@intCast(b1s)..]);
            b1e = b1s + n;
        }
        if (b2s >= b2e) {
            if (b2s >= BUF)
                b2s = 0;
            const n = rd(f2, buf2[@intCast(b2s)..]);
            b2e = b2s + n;
        }
        var n = b2e - b2s;
        if (n > b1e - b1s)
            n = b1e - b1s;
        if (n <= 0)
            break;
        const p = buf1[@intCast(b1s)..][0..@intCast(n)];
        const q = buf2[@intCast(b2s)..][0..@intCast(n)];
        if (!@import("std").mem.eql(u8, p, q)) {
            if (sflag)
                libc.exits("differ");
            for (p, q, 0..) |x, y, i| {
                if (x == '\n')
                    l += 1;
                if (x != y) {
                    if (!lflag) {
                        libc.print("%s %s differ: char %lld", .{ name1, name2, nc + @as(i64, @intCast(i)) });
                        if (Lflag)
                            libc.print(" line %lld\n", .{l})
                        else
                            libc.print("\n", .{});
                        libc.exits("differ");
                    }
                    libc.print("%6lld 0x%.2x 0x%.2x\n", .{ nc + @as(i64, @intCast(i)), x, y });
                }
            }
        }
        if (Lflag) {
            for (buf1[@intCast(b1s)..@intCast(b1e)]) |c| {
                if (c == '\n')
                    l += 1;
            }
        }
        nc += n;
        b1s += n;
        b2s += n;
    }
    if (b1e - b1s < 0 or b2e - b2s < 0) {
        if (!sflag) {
            if (b1e - b1s < 0)
                libc.print("error on %s after %lld bytes\n", .{ name1, nc - 1 });
            if (b2e - b2s < 0)
                libc.print("error on %s after %lld bytes\n", .{ name2, nc - 1 });
        }
        libc.exits("read error");
    }
    if (b1e - b1s == b2e - b2s)
        libc.exits(null);
    if (!sflag)
        libc.print("EOF on %s after %lld bytes\n", .{ if (b1e - b1s > b2e - b2s) name2 else name1, nc - 1 });
    libc.exits("EOF");
}
