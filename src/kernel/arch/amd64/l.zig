//! Low-level machine code.
//! from 9/pc64/l.s
//!
//! DIFF: the protected-mode and long-mode bring-up (_protected, _warp64,
//! _lme, _identity) is done by the UEFI loader; _start here corresponds
//! to _start64v.  Leaf routines are inline assembly instead of TEXT
//! blocks.

const mem = @import("mem.zig");

/// Stack for the bootstrap processor until it has a Mach.
export var cpu0stack: [mem.MACHSIZE]u8 align(16) linksection(".bss") = undefined;

/// Kernel entry.  The loader arrives here in long mode on its own stack,
/// with the kernel mapped at its link address, interrupts off, and the
/// physical address of the BootInfo in RDI.
pub fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ cli
        \\ cld
        \\ leaq cpu0stack(%%rip), %%rsp
        \\ addq %[size], %%rsp
        \\ xorl %%ebp, %%ebp
        \\ pushq $0            /* clear flags */
        \\ popfq
        \\ call main
        \\1:
        \\ hlt
        \\ jmp 1b
        :
        : [size] "i" (@as(u32, mem.MACHSIZE)),
    );
}

/// Park a processor.
pub fn idle() noreturn {
    while (true) asm volatile (
        \\ sti
        \\ hlt
    );
}

// Port I/O.

pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub fn ins(port: u16) u16 {
    return asm volatile ("inw %[port], %[ret]"
        : [ret] "={ax}" (-> u16),
        : [port] "{dx}" (port),
    );
}

pub fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[ret]"
        : [ret] "={eax}" (-> u32),
        : [port] "{dx}" (port),
    );
}

pub fn outb(port: u16, v: u8) void {
    asm volatile ("outb %[v], %[port]"
        :
        : [v] "{al}" (v),
          [port] "{dx}" (port),
    );
}

pub fn outs(port: u16, v: u16) void {
    asm volatile ("outw %[v], %[port]"
        :
        : [v] "{ax}" (v),
          [port] "{dx}" (port),
    );
}

pub fn outl(port: u16, v: u32) void {
    asm volatile ("outl %[v], %[port]"
        :
        : [v] "{eax}" (v),
          [port] "{dx}" (port),
    );
}
