//! split - split a file into pieces
//! from cmd/split.c
//!
//! DIFF: -e (split at lines matching a regular expression), and with it
//! -i and -x, wait for a port of libregexp: -e prints that and exits.
//! The options are still parsed as in the C.
//!
//! Kept from the C: openf's descriptor starts at 0, so the first output
//! file it opens closes standard input first; the error message for a
//! file it cannot create says "grep".

const std = @import("std");
const libc = @import("libc");

var suffix: []const u8 = "";
var stem: []const u8 = "x";
var suff = [2]u8{ 'a', 'a' };
var namebuf: [200]u8 = undefined;
var name: []const u8 = "";
var bout: libc.Biobuf = .{};
var bin: libc.Biobuf = .{};

fn usage() noreturn {
    libc.fprint(2, "usage: split [-n num] [-e exp] [-f stem] [-s suff] [-x] [-i] [file]\n", .{});
    libc.exits("usage");
}

pub fn main(argv: []const []const u8) void {
    var pattern: ?[]const u8 = null;
    var n: i64 = 1000;
    var xflag = false;
    var iflag = false;

    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'l', 'n' => n = @as(i32, @truncate(libc.atoi(args.value() orelse usage()))),
        'e' => pattern = args.value() orelse usage(),
        'f' => stem = args.value() orelse usage(),
        's' => suffix = args.value() orelse usage(),
        'x' => xflag = true,
        'i' => iflag = true,
        else => usage(),
    };
    const rest = args.rest();

    if (rest.len > 1)
        usage();

    const b = &bin;
    if (rest.len != 0) {
        b.open(rest[0], libc.OREAD) catch {
            libc.fprint(2, "split: can't open %s: %r\n", .{rest[0]});
            libc.exits("open");
        };
    } else b.init(0, libc.OREAD);

    if (pattern != null) {
        libc.fprint(2, "split: -e is not ported yet: it needs regular expressions\n", .{});
        libc.exits("-e not ported");
    } else {
        var linecnt = n;

        while (b.rdline('\n')) |line| {
            linecnt += 1;
            if (linecnt > n) {
                _ = nextfile();
                linecnt = 1;
            }
            _ = bout.write(line) catch {};
        }

        // in case we didn't end with a newline, tack whatever's
        // left onto the last file
        var buf: [256]u8 = undefined;
        while (true) {
            const m = b.read(&buf) catch break;
            if (m == 0)
                break;
            _ = bout.write(buf[0..m]) catch {};
        }
    }
    b.term() catch {};
    libc.exits(null);
}

var canopen = true;

fn nextfile() bool {
    if (suff[0] > 'z') {
        if (canopen)
            libc.fprint(2, "split: file %szz not split\n", .{stem});
        canopen = false;
    } else {
        name = libc.fmt.snprint(namebuf[0 .. namebuf.len - 1], "%s%s", .{ stem, suff[0..] });
        suff[1] += 1;
        if (suff[1] > 'z') {
            suff[1] = 'a';
            suff[0] += 1;
        }
        openf();
    }
    return canopen;
}

var ofd: i32 = 0;

fn openf() void {
    bout.flush() catch {};
    bout.term() catch {};
    if (ofd >= 0)
        libc.close(ofd) catch {};
    ofd = libc.create(name, libc.OWRITE, 0o666) catch -1;
    if (ofd < 0) {
        libc.fprint(2, "grep: can't create %s: %r\n", .{name});
        libc.exits("create");
    }
    bout.init(ofd, libc.OWRITE);
}
