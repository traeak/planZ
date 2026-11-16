//! unmount - undo a bind or a mount
//! from cmd/unmount.c

const libc = @import("libc");

pub fn main(argv: []const []const u8) void {
    var mnted: ?[]const u8 = null;
    var mtpt: []const u8 = undefined;

    switch (argv.len) {
        2 => mtpt = argv[1],
        3 => {
            mnted = argv[1];
            mtpt = argv[2];
        },
        else => {
            libc.fprint(2, "usage: unmount mountpoint\n", .{});
            libc.fprint(2, "       unmount mounted mountpoint\n", .{});
            libc.exits("usage");
        },
    }

    // unmount takes arguments in the same order as mount
    libc.unmount(mnted, mtpt) catch libc.sysfatal("%s: %r", .{mtpt});
    libc.exits(null);
}
