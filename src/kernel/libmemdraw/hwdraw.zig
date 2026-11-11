//! hwdraw: the hook through which the screen code sees every draw.
//! From /sys/src/libmemdraw/hwdraw.c.
//!
//! DIFF: in C the kernel's screen.c defines its own hwdraw, which
//! replaces this file's at link time.  Zig has no such link-time
//! override, so the screen code (port/screen.zig) stores its function
//! in `hook` instead.  With no hook the answer is the C file's: 0,
//! could not satisfy request.

const memdraw = @import("memdraw.zig");
const Memdrawparam = memdraw.Memdrawparam;

pub var hook: ?*const fn (par: *Memdrawparam) i32 = null;

pub fn hwdraw(par: *Memdrawparam) i32 {
    if (hook) |f|
        return f(par);
    return 0; // could not satisfy request
}
