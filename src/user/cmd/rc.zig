//! rc - command language
//! from cmd/rc: the port is in rc/, one file per C file.

const exec = @import("rc/exec.zig");

pub fn main(argv: []const []const u8) void {
    exec.main(argv);
}
