//! strings - extract printable strings
//! from cmd/strings.c
//!
//! DIFF: the span is a slice of runes from the allocator, and "no span"
//! is null where the C sets its pointer to nil.

const libc = @import("libc");

var fin: libc.Biobuf = .{};
var fout: libc.Biobuf = .{};

var minspan: usize = 6; // Min characters in string (default)
var span: []libc.Rune = &.{};

fn usage() noreturn {
    libc.fprint(2, "usage: %s [-m min] [file...]\n", .{libc.argv0});
    libc.exits("usage");
}

pub fn main(argv: []const []const u8) void {
    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'm' => {
            const m = libc.atoi(args.value() orelse usage());
            if (m <= 0)
                usage();
            minspan = @intCast(m);
        },
        else => usage(),
    };
    const files = args.rest();

    span = libc.allocator.alloc(libc.Rune, minspan + 1) catch libc.sysfatal("out of memory", .{});

    fout.init(1, libc.OWRITE);
    if (files.len < 1) {
        stringit(0);
        libc.exits(null);
    }

    for (files) |name| {
        if (files.len > 1) {
            fout.print("%s:\n", .{name}) catch {};
            fout.flush() catch {};
        }
        const fd = libc.open(name, libc.OREAD) catch {
            libc.fprint(2, "open: %r\n", .{});
            continue;
        };
        stringit(fd);
        libc.close(fd) catch {};
    }

    libc.exits(null);
}

fn stringit(fd: i32) void {
    fin.init(fd, libc.OREAD);
    var sp: ?usize = 0;
    while (fin.getrune()) |c| {
        if (isprint(c)) {
            const n = sp orelse {
                _ = fout.putrune(c) catch {};
                continue;
            };
            span[n] = c;
            sp = n + 1;
            if (n + 1 < minspan)
                continue;
            fout.print("%8lld: ", .{fin.offset_() - @as(i64, @intCast(minspan))}) catch {};
            for (span[0 .. n + 1]) |r|
                _ = fout.putrune(r) catch {};
            sp = null;
        } else {
            if (sp == null)
                _ = fout.putrune('\n') catch {};
            sp = 0;
        }
    }
    if (sp == null)
        _ = fout.putrune('\n') catch {};
    fin.term() catch {};
}

fn isprint(r: libc.Rune) bool {
    if (r != libc.Runeerror)
        if ((r >= ' ' and r < 0x7F) or r > 0xA0)
            return true;
    return false;
}
