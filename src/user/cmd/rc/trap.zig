//! rc's notes, run as traps.
//! from cmd/rc/trap.c

const std = @import("std");
const rc = @import("rc.zig");
const exec = @import("exec.zig");
const @"var" = @import("var.zig");
const plan9 = @import("plan9.zig");

pub var ntrap: i32 = 0;
pub var trap: [rc.NSIG]i32 = @splat(0);

pub fn dotrap() void {
    const starval = @"var".vlook("*").val;
    while (ntrap != 0) {
        for (0..rc.NSIG) |i| {
            while (trap[i] != 0) {
                trap[i] -= 1;
                ntrap -= 1;
                if (@as(i32, @intCast(rc.libc.getpid())) != exec.mypid) plan9.Exit();
                const trapreq = @"var".vlook(plan9.Signame[i] orelse "");
                if (trapreq.@"fn" != null)
                    exec.startfunc(trapreq, exec.copywords(starval, null), null, null)
                else if (i == rc.SIGINT or i == rc.SIGQUIT) {
                    // run the stack down until we uncover the command
                    // reading loop.  Xreturn will exit if there is none
                    // (i.e. if this is not an interactive rc.)
                    while (!exec.rq().iflag) exec.Xreturn();
                } else if (std.mem.eql(u8, trapreq.name, "sigwinch")) {
                    // ignore if theres no handler
                } else plan9.Exit();
            }
        }
    }
}
