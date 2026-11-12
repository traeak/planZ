//! freq - print histogram of character frequencies
//! from cmd/freq.c
//!
//! DIFF: the input Biobuf is static, where the C has it on the stack.

const libc = @import("libc");

var count: [libc.Runemax + 1]u64 = undefined;
var bout: libc.Biobuf = .{};
var bin: libc.Biobuf = .{};

var flag: u32 = 0;
const Fdec = 1 << 0;
const Fhex = 1 << 1;
const Foct = 1 << 2;
const Fchar = 1 << 3;
const Frune = 1 << 4;

pub fn main(argv: []const []const u8) void {
    bout.init(1, libc.OWRITE);
    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'd' => flag |= Fdec,
        'x' => flag |= Fhex,
        'o' => flag |= Foct,
        'c' => flag |= Fchar,
        'r' => flag |= Frune,
        else => usage(),
    };
    const files = args.rest();
    if (flag & (Fdec | Fhex | Foct | Fchar) == 0)
        flag |= Fdec | Fhex | Foct | Fchar;
    if (files.len < 1) {
        freq(0, "-");
        libc.exits(null);
    }
    for (files) |name| {
        const f = libc.open(name, 0) catch {
            libc.fprint(2, "open %s: %r\n", .{name});
            continue;
        };
        freq(f, name);
        libc.close(f) catch {};
    }
    libc.exits(null);
}

fn usage() noreturn {
    libc.fprint(2, "usage: freq [-cdorx] [file ...]\n", .{});
    libc.exits("usage");
}

fn freq(f: i32, s: []const u8) void {
    @memset(&count, 0);
    bin.init(f, libc.OREAD);
    if (flag & Frune != 0) {
        while (bin.getrune()) |c|
            count[c] += 1;
    } else {
        while (bin.getc()) |c|
            count[c] += 1;
    }
    // DIFF: Bgetc and Bgetrune return null both at the end and on an
    // error; an error leaves the Biobuf inactive.
    const failed = bin.state == .inactive;
    bin.term() catch {};
    if (failed)
        libc.fprint(2, "freq: read error on %s\n", .{s});

    for (count, 0..) |n, i| {
        if (n == 0)
            continue;
        if (flag & Fdec != 0)
            bout.print("%3ld ", .{i}) catch {};
        if (flag & Foct != 0)
            bout.print("%.3lo ", .{i}) catch {};
        if (flag & Fhex != 0)
            bout.print("%.2lx ", .{i}) catch {};
        if (flag & Fchar != 0) {
            if (i <= 0x20 or
                i >= 0x7f and i < 0xa0 or
                i > 0xff and flag & Frune == 0)
                bout.print("- ", .{}) catch {}
            else
                bout.print("%C ", .{i}) catch {};
        }
        bout.print("%8llud\n", .{n}) catch {};
    }
    bout.flush() catch {};
}
