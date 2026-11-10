//! Root of the planZ kernel: selects the architecture and exports the
//! symbols the linker and the loader look for.

const std = @import("std");
const builtin = @import("builtin");

pub const arch = switch (builtin.cpu.arch) {
    .x86_64 => struct {
        pub const l = @import("arch/amd64/l.zig");
        pub const main = @import("arch/amd64/main.zig");
        pub const mem = @import("arch/amd64/mem.zig");
    },
    else => @compileError("planZ: unsupported architecture"),
};

const print = @import("port/print.zig");

comptime {
    @export(&arch.l._start, .{ .name = "_start" });
    @export(&arch.main.main, .{ .name = "main" });
}

fn zigpanic(msg: []const u8, _: ?usize) noreturn {
    print.panic(msg);
}

pub const panic = std.debug.FullPanic(zigpanic);
