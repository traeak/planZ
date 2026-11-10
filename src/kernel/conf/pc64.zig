//! Kernel configuration for the amd64 PC.
//! Stands in for 9/pc64/pc64 (the configuration file) and the tables
//! that 9/port/mkdevc generates from it.
//!
//! The order matters only for the first entry: channel type 0 must be
//! the root device, whose close does nothing, because a channel that
//! fails before it is given to a device is closed as type 0.

const devmod = @import("../port/dev.zig");

pub const devtab = [_]*const devmod.Dev{
    &@import("../port/devroot.zig").rootdevtab,
    &@import("../port/devcons.zig").consdevtab,
    &@import("../port/devenv.zig").envdevtab,
    &@import("../port/devpipe.zig").pipedevtab,
    &@import("../port/devsrv.zig").srvdevtab,
    &@import("../port/devdup.zig").dupdevtab,
};
