//! The first user process: sets up the boot name space and execs
//! /boot/boot.
//! from 9/port/initcode.c and 9/pc64/init9.s
//!
//! The kernel copies this program's text into one page at UTZERO and
//! enters it at UTZERO+0x28, so it must fit in a page and have no data
//! segment: everything it writes is on the stack.

const sys = @import("sys.zig");

comptime {
    asm (
        \\ .section .text.start, "ax"
        \\ .globl _start
        \\_start:
        \\ movq %rsp, %rdi             /* argc, argv as the kernel left them */
        \\ andq $-16, %rsp
        \\ call startboot
    );
}

export fn startboot(sp: [*]usize) callconv(.c) noreturn {
    const argv: [*]const ?[*:0]const u8 = @ptrCast(sp + 1);

    _ = sys.bind("#c", "/dev", sys.MAFTER);
    _ = sys.bind("#d", "/fd", sys.MREPL);
    _ = sys.bind("#e", "/env", sys.MREPL | sys.MCREATE);
    _ = sys.bind("#ec", "/env", sys.MAFTER);
    _ = sys.bind("#p", "/proc", sys.MREPL);
    _ = sys.bind("#s", "/srv", sys.MREPL | sys.MCREATE);
    _ = sys.bind("#σ", "/shr", sys.MREPL);

    _ = sys.open("/dev/cons", sys.OREAD);
    _ = sys.open("/dev/cons", sys.OWRITE);
    _ = sys.open("/dev/cons", sys.OWRITE);

    _ = sys.exec("/boot/boot", argv);

    var buf: [200]u8 = undefined; // keep this fairly large to capture error details
    buf[0] = 0;
    _ = sys.errstr(&buf);
    buf[buf.len - 1] = 0;
    sys.exits(@ptrCast(&buf));
}
