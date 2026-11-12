//! cleanname - clean a path name
//! from cmd/cleanname.c
//!
//! Fixed from C: the C cleans each name in place in argv.  Cleaning the
//! empty name gives ".", two bytes with the NUL, in a one-byte string,
//! so the first byte of the next argument becomes a NUL:
//! `cleanname '' ../../a` prints "." twice.  Here each name is copied
//! into a buffer of its own.

const libc = @import("libc");

fn usage() noreturn {
    libc.fprint(2, "usage: cleanname [-d pwd] name...\n", .{});
    libc.exits("usage");
}

pub fn main(argv: []const []const u8) !void {
    var dir: ?[]const u8 = null;
    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'd' => dir = args.value() orelse usage(),
        else => usage(),
    };
    const names = args.rest();
    if (names.len < 1)
        usage();

    const a = libc.allocator;
    for (names) |n| {
        // DIFF: the name is copied (with room for cleanname's two extra
        // bytes); the C edits argv in place.
        const buf = try a.alloc(u8, (if (dir) |d| d.len else 0) + 1 + n.len + 2);
        defer a.free(buf);
        const s = if (dir != null and !(n.len > 0 and n[0] == '/'))
            libc.sprint(buf, "%s/%s", .{ dir.?, n })
        else
            libc.sprint(buf, "%s", .{n});
        libc.print("%s\n", .{buf[0..libc.cleanname(buf, s.len)]});
    }
}
