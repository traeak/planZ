//! Root for `zig build check-ports`: pulls in every portable file and
//! makes the compiler analyse all of it, not just what something calls.

const std = @import("std");

const files = .{
    @import("port/alarm.zig"),
    @import("port/alloc.zig"),
    @import("port/allocb.zig"),
    @import("port/chan.zig"),
    @import("port/dev.zig"),
    @import("port/devcons.zig"),
    @import("port/devdup.zig"),
    @import("port/devenv.zig"),
    @import("port/devpipe.zig"),
    @import("port/devroot.zig"),
    @import("port/devsrv.zig"),
    @import("port/error.zig"),
    @import("port/fault.zig"),
    @import("port/lib.zig"),
    @import("port/pgrp.zig"),
    @import("port/memmap.zig"),
    @import("port/page.zig"),
    @import("port/parse.zig"),
    @import("port/portclock.zig"),
    @import("port/portdat.zig"),
    @import("port/print.zig"),
    @import("port/proc.zig"),
    @import("port/qio.zig"),
    @import("port/qlock.zig"),
    @import("port/screen.zig"),
    @import("port/segment.zig"),
    @import("port/selftest.zig"),
    @import("port/sysfile.zig"),
    @import("port/syscall.zig"),
    @import("port/sysproc.zig"),
    @import("port/taslock.zig"),
    @import("port/tod.zig"),
    @import("port/userinit.zig"),
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
