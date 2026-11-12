//! The root file of a user program built on the library: build.zig
//! compiles every such program with this as its root and the program's
//! own file as the module "program".  Being the root, this file's
//! declarations are always looked at, so it is where _start is
//! exported and the panic handler is set; a file imported as a module
//! is only analysed as far as it is used.

const std = @import("std");
const libc = @import("libc");
pub const program = @import("program");

comptime {
    @export(&libc.start._start, .{ .name = "_start", .section = ".text.start" });
}

pub const panic = if (@hasDecl(program, "panic")) program.panic else std.debug.FullPanic(libc.panicfn);
