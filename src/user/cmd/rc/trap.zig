//! rc's notes, run as traps.
//! from cmd/rc/trap.c
//!
//! In progress: dotrap comes with the interpreter.

const rc = @import("rc.zig");

pub var ntrap: i32 = 0;
pub var trap: [rc.NSIG]i32 = @splat(0);

pub fn dotrap() void {
    @panic("rc: dotrap is not ported yet");
}
