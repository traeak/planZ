//! pwd - print working (current) directory
//! from cmd/pwd.c

const libc = @import("libc");

pub fn main() void {
    var pathname: [512]u8 = undefined;
    const wd = libc.getwd(&pathname) catch {
        libc.fprint(2, "pwd: %r\n", .{});
        libc.exits("getwd");
    };
    libc.print("%s\n", .{wd});
}
