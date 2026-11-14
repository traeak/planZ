//! The kernel's libdraw files that are plain functions of their
//! arguments, for planZ's user libdraw (src/user/lib/draw), which is
//! built as a module with this file as its root.  The kernel itself
//! imports the files directly and never this one.
//!
//! Not part of 9front.

pub const draw = @import("libdraw/draw.zig");
pub const arith = @import("libdraw/arith.zig");
pub const badrect = @import("libdraw/badrect.zig");
pub const bytesperline = @import("libdraw/bytesperline.zig");
pub const chan = @import("libdraw/chan.zig");
pub const computil = @import("libdraw/computil.zig");
pub const defont = @import("libdraw/defont.zig");
pub const drawrepl = @import("libdraw/drawrepl.zig");
pub const icossin = @import("libdraw/icossin.zig");
pub const icossin2 = @import("libdraw/icossin2.zig");
pub const rectclip = @import("libdraw/rectclip.zig");
pub const rgb = @import("libdraw/rgb.zig");
