//! Program start: what the kernel's exec leaves to the program, and the
//! call of the program's main.
//! from libc/amd64/main9.s and libc/9sys/callmain.c
//!
//! exec enters at _start with RAX pointing at the Tos (the per-process
//! block at the top of the stack) and the stack holding argc and then
//! argv, a nil-terminated array of strings.
//!
//! DIFF:
//!   - main is the program's `pub fn main`, which takes either nothing
//!     or the arguments as a slice and returns void or an error union.
//!     Returning normally exits with no status; the C exits("main").
//!     Returning an error exits with the error string for error.Plan9
//!     and with the error's name otherwise, after printing it to
//!     standard error with the program's name.
//!   - No _privates: privalloc is not ported.
//!   - No profiling (main9p.s).

const std = @import("std");
const root = @import("root");
const libc = @import("libc.zig");
const sys = @import("sys.zig");

/// Exported as _start, in .text.start, by root.zig.
pub fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ movq %rsp, %rdi             /* argc, argv */
        \\ movq %rax, %rsi             /* Tos, as exec returns it */
        \\ andq $-16, %rsp
        \\ call _callmain
        \\ hlt
    );
}

export fn _callmain(sp: [*]usize, tos: *libc.Tos) callconv(.c) noreturn {
    libc.tos = tos;
    const argc = sp[0];
    const argvp: [*]const [*:0]const u8 = @ptrCast(sp + 1);
    // DIFF: the arguments as slices, in memory from the allocator
    const args = libc.allocator.alloc([]const u8, argc) catch
        sys.exits("no memory for arguments");
    for (args, 0..) |*a, i|
        a.* = std.mem.span(argvp[i]);
    libc.argv = args;
    if (argc > 0)
        libc.argv0 = args[0];

    const main = root.program.main;
    const Main = @typeInfo(@TypeOf(main)).@"fn";
    const r = if (Main.param_types.len == 0) main() else main(libc.argv);
    switch (@typeInfo(Main.return_type.?)) {
        .error_union => {
            r catch |e| {
                if (e == error.Plan9) {
                    var buf: [sys.ERRMAX]u8 = undefined;
                    const m = libc.rerrstr(&buf);
                    libc.fprint(2, "%s: %s\n", .{ libc.argv0, m });
                    libc.exits(m);
                }
                libc.fprint(2, "%s: %s\n", .{ libc.argv0, @errorName(e) });
                libc.exits(@errorName(e));
            };
        },
        .void => {},
        else => @compileError("main must return void or !void"),
    }
    libc.exits(null);
}
