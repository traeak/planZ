//! mtime - print the modification times of files
//! from cmd/mtime.c

const libc = @import("libc");

fn usage() noreturn {
    libc.fprint(2, "usage: mtime file...\n", .{});
    libc.exits("usage");
}

pub fn main(argv: []const []const u8) void {
    var args = libc.Args.init(argv);
    while (args.next()) |_|
        usage();
    var errors = false;
    for (args.rest()) |name| {
        var d = libc.dirstat(libc.allocator, name) catch {
            libc.fprint(2, "stat %s: %r\n", .{name});
            errors = true;
            continue;
        };
        libc.print("%11lud %s\n", .{ d.dir.mtime, name });
        d.deinit(libc.allocator);
    }
    libc.exits(if (errors) "errors" else null);
}
