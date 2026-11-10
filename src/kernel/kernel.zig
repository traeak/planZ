//! Root of the planZ kernel: exports the symbols the linker and the
//! assembly look for, and routes Zig's own panics to the kernel's.

const std = @import("std");
const arch = @import("arch.zig");
const p9 = @import("port/print.zig");

comptime {
    @export(&arch._start, .{ .name = "_start" });
    @export(&arch.main, .{ .name = "main" });
    @export(&arch.trap, .{ .name = "trap" });
    @export(&arch.syscall, .{ .name = "syscall" });
}

fn zigpanic(msg: []const u8, _: ?usize) noreturn {
    p9.panic("%s", .{msg});
}

pub const panic = std.debug.FullPanic(zigpanic);
