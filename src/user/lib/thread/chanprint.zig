//! from libthread/chanprint.c
//!
//! DIFF:
//!   - The channel carries the text as a slice ([]u8, from the
//!     allocator, for the receiver to free); the C's carries a char*.
//!     The text is at most 1,024 bytes; the C's has no limit.

const libc = @import("libc");
const channel = @import("channel.zig");
const sched = @import("sched.zig");

pub fn chanprint(c: *channel.Channel, comptime format: []const u8, args: anytype) i32 {
    var buf: [1024]u8 = undefined;
    const p: []u8 = libc.allocator.dupe(u8, libc.sprint(&buf, format, args)) catch
        libc.sysfatal("vsmprint failed: %r", .{});
    if (c.e != @sizeOf([]u8))
        @panic("chanprint: not a channel of []u8");
    const n = channel.send(c, @ptrCast(&p));
    sched.yield(); // let recipient handle message immediately
    return n;
}
