//! split - split a file into pieces
//! from cmd/split.c
//!
//! DIFF: a name made from a match is cut to fit the C's 200-byte name
//! buffer, which the C overruns.  fold works on a copy from the
//! allocator; badexp is never reached, as in the C, since the default
//! regerror exits first.
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

    if (pattern) |pat| {
        var diag: libc.regexp.Diag = .{};
        const exp = libc.regexp.regcomp(libc.allocator, if (iflag) fold(pat) else pat, &diag) catch |e| {
            if (e == error.Regexp)
                libc.regerror(diag.msg);
            badexp();
        };
        var match: [2]libc.regexp.Resub = @splat(.{});
        _ = matchfile(&match, "");
        while (b.rdline('\n')) |full| {
            match = @splat(.{});
            const line = full[0 .. full.len - 1];
            const subject = if (iflag) fold(line) else line;
            if (exp.exec(subject, &match)) {
                if (matchfile(&match, subject) and xflag)
                    continue;
            }
            // the C's `else if(output == 0) nextfile();` cannot happen:
            // output is never nil
            _ = bout.write(line) catch {};
            bout.putc('\n') catch {};
        }
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

var foldbuf: []u8 = &.{};

/// s in lower case (ASCII), in a buffer kept from call to call.  As in
/// the C, a 0 byte ends it.
fn fold(s_: []const u8) []const u8 {
    const s = s_[0 .. std.mem.findScalar(u8, s_, 0) orelse s_.len];
    if (foldbuf.len < s.len + 1)
        foldbuf = libc.allocator.realloc(foldbuf, s.len + 1) catch libc.sysfatal("out of memory", .{});
    for (s, 0..) |c, i| foldbuf[i] = std.ascii.toLower(c);
    return foldbuf[0..s.len];
}

/// Open the file the match names (subexpression 1 plus the suffix), or
/// the next one in sequence.
fn matchfile(match: []const libc.regexp.Resub, subject: []const u8) bool {
    if (match[1].sp) |sp| {
        const m = subject[sp..match[1].ep.?];
        const room = namebuf.len - 1;
        const n = @min(m.len, room);
        @memcpy(namebuf[0..n], m[0..n]);
        const k = @min(suffix.len, room - n);
        @memcpy(namebuf[n..][0..k], suffix[0..k]);
        name = namebuf[0 .. n + k];
        openf();
        return true;
    }
    return nextfile();
}

fn badexp() noreturn {
    libc.fprint(2, "split: bad regular expression\n", .{});
    libc.exits("bad regular expression");
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
