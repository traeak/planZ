//! basename - strip file name affixes
//! from cmd/basename.c

const std = @import("std");
const libc = @import("libc");

pub fn main(argv_: []const []const u8) void {
    var argv = argv_;
    var dflag = false;
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "-d")) {
        argv = argv[1..];
        dflag = true;
    }
    if (argv.len < 2 or argv.len > 3) {
        libc.fprint(2, "usage: basename [-d] string [suffix]\n", .{});
        libc.exits("usage");
    }
    const s = argv[1];
    const slash = std.mem.findScalarLast(u8, s, '/');
    if (dflag) {
        if (slash) |i| {
            libc.print("%s\n", .{s[0..i]});
            return;
        }
        libc.print(".\n", .{});
        return;
    }
    var pr = if (slash) |i| s[i + 1 ..] else s;
    if (argv.len == 3) {
        if (pr.len >= argv[2].len and std.mem.endsWith(u8, pr, argv[2]))
            pr = pr[0 .. pr.len - argv[2].len];
    }
    libc.print("%s\n", .{pr});
}
