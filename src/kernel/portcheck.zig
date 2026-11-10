//! Root for `zig build check-ports`: pulls in every portable file and
//! makes the compiler analyse all of it, not just what something calls.

const std = @import("std");

const files = .{
    @import("port/alarm.zig"),
    @import("port/alloc.zig"),
    @import("port/error.zig"),
    @import("port/memmap.zig"),
    @import("port/portclock.zig"),
    @import("port/portdat.zig"),
    @import("port/print.zig"),
    @import("port/proc.zig"),
    @import("port/qlock.zig"),
    @import("port/screen.zig"),
    @import("port/selftest.zig"),
    @import("port/taslock.zig"),
    @import("port/tod.zig"),
    @import("port/xalloc.zig"),
    @import("plat/acpi.zig"),
    @import("drv/uart16550.zig"),
};

comptime {
    for (files) |f| {
        for (@typeInfo(f).@"struct".decl_names) |name|
            _ = &@field(f, name);
    }
}

pub const panic = std.debug.no_panic;
