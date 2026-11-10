//! Low-level machine code.
//! from 9/pc64/l.s
//!
//! DIFF: the protected-mode and long-mode bring-up (_protected, _warp64,
//! _lme, _identity) is done by the UEFI loader; _start here corresponds
//! to _start64v.  Leaf routines are inline assembly instead of TEXT
//! blocks.  m and up are not kept in R15/R14 (see dat.zig), so the trap
//! entry saves and restores those two like any other register.

const std = @import("std");
const mem = @import("mem.zig");
const dat = @import("dat.zig");

/// Mach for the bootstrap processor.  The Mach structure is at the
/// bottom and the processor's stack grows down from the top, as with
/// CPU0MACH in the C kernel.
pub export var mach0: [mem.MACHSIZE]u8 align(mem.BY2PG) linksection(".bss") = undefined;

/// Kernel entry.  The loader arrives here in long mode on its own stack,
/// with the kernel mapped at its link address, interrupts off, and the
/// physical address of the BootInfo in RDI.
pub fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ cli
        \\ cld
        \\ leaq mach0(%%rip), %%rsp
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

// The CPUID instruction is always supported on the amd64.

pub const Cpuid = struct { ax: u32, bx: u32, cx: u32, dx: u32 };

pub fn cpuid(ax: u32, cx: u32) Cpuid {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [ia] "{eax}" (ax),
          [ic] "{ecx}" (cx),
    );
    return .{ .ax = a, .bx = b, .cx = c, .dx = d };
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

// Descriptor tables.

/// Operand of LGDT and LIDT.
pub const Tableptr = extern struct {
    _pad: [3]u16 = undefined,
    lim: u16,
    off: u64,
};

pub fn lgdt(lim: u16, off: usize) void {
    const p: Tableptr = .{ .lim = lim, .off = off };
    asm volatile ("lgdt (%[p])"
        :
        : [p] "r" (&p.lim),
    );
}

pub fn lidt(lim: u16, off: usize) void {
    const p: Tableptr = .{ .lim = lim, .off = off };
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&p.lim),
    );
}

pub fn ltr(sel: u16) void {
    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (sel),
    );
}

/// Load CS with `cs` and clear the data segment registers, as
/// _start64v does after loading its GDT.  Loading FS and GS clears
/// their base registers on some processors, so GSbase must be set after
/// this, not before.
pub fn setsegs(cs: u16) void {
    asm volatile (
        \\ pushq %[cs]
        \\ leaq 1f(%%rip), %%rax
        \\ pushq %%rax
        \\ lretq
        \\1:
        \\ xorl %%eax, %%eax
        \\ movw %%ax, %%ds
        \\ movw %%ax, %%es
        \\ movw %%ax, %%fs
        \\ movw %%ax, %%gs
        \\ movw %%ax, %%ss
        \\ lldt %%ax
        :
        : [cs] "r" (@as(u64, cs)),
        : .{ .rax = true, .memory = true });
}

// Read/write various system registers.

pub fn getcr0() u64 {
    return asm volatile ("movq %%cr0, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

pub fn putcr0(v: u64) void {
    asm volatile ("movq %[v], %%cr0"
        :
        : [v] "r" (v),
    );
}

/// #PF Linear Address
pub fn getcr2() u64 {
    return asm volatile ("movq %%cr2, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

/// PML4 Base
pub fn getcr3() u64 {
    return asm volatile ("movq %%cr3, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

pub fn putcr3(v: u64) void {
    asm volatile ("movq %[v], %%cr3"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

pub fn getcr4() u64 {
    return asm volatile ("movq %%cr4, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

pub fn putcr4(v: u64) void {
    asm volatile ("movq %[v], %%cr4"
        :
        : [v] "r" (v),
    );
}

/// Time stamp counter.
pub fn cycles() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}

/// Model-Specific Register.
/// DIFF: no trap fixup yet; reading an MSR the processor lacks faults.
pub fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [msr] "{ecx}" (msr),
    );
    return @as(u64, hi) << 32 | lo;
}

pub fn wrmsr(msr: u32, v: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [lo] "{eax}" (@as(u32, @truncate(v))),
          [hi] "{edx}" (@as(u32, @truncate(v >> 32))),
    );
}

pub fn invlpg(va: usize) void {
    asm volatile ("invlpg (%[va])"
        :
        : [va] "r" (va),
        : .{ .memory = true });
}

// Serialisation.

pub fn mfence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

/// Make this processor's stores visible to the others before going on.
pub fn coherence() void {
    mfence();
}

// Interrupt priority.  splhi and splx return and take the flags
// register; only the interrupt flag (0x200) matters.

fn getflags() usize {
    return asm volatile (
        \\ pushfq
        \\ popq %[ret]
        : [ret] "=r" (-> usize),
    );
}

pub fn splhi() usize {
    const f = getflags();
    if (f & 0x200 != 0) {
        asm volatile ("cli");
        dat.m().splpc = @returnAddress();
    }
    return f;
}

pub fn spllo() usize {
    const f = getflags();
    if (f & 0x200 == 0) {
        dat.m().splpc = 0;
        asm volatile ("sti");
    }
    return f;
}

pub fn splx(f: usize) void {
    if (f & 0x200 != 0) _ = spllo() else _ = splhi();
}

pub fn islo() bool {
    return getflags() & 0x200 != 0;
}

/// Stop this processor for good.
pub fn stop() noreturn {
    while (true) asm volatile (
        \\ cli
        \\ hlt
    );
}

/// Wait for an interrupt.
pub fn halt() void {
    asm volatile (
        \\ sti
        \\ hlt
    );
}

/// Halt until the next interrupt, unless a process became ready in the
/// meantime.  The test and the halt cannot be separated by an
/// interrupt: STI takes effect after the instruction that follows it.
/// from halt in l.s
pub fn idlehands(nrdy: *const i32) void {
    asm volatile (
        \\ cli
        \\ cmpl $0, (%[nrdy])
        \\ jne 1f
        \\ sti
        \\ hlt
        \\1:
        \\ sti
        :
        : [nrdy] "r" (nrdy),
    );
}

/// Low bits of the cycle counter, for the idle and interrupt time
/// statistics.
pub fn perfticks() u32 {
    return @truncate(cycles());
}

// Synchronisation

pub fn tas(key: *u32) u32 {
    return @atomicRmw(u32, key, .Xchg, 0xdeaddead, .seq_cst);
}

pub fn cas(addr: *u32, exp: u32, new: u32) bool {
    return @cmpxchgStrong(u32, addr, exp, new, .seq_cst, .seq_cst) == null;
}

// Interrupt/exception handling.
//
// The processor has pushed SS, SP, flags, CS and PC, and for some
// exceptions an error code.  Each vectortable entry is a CALL followed
// by the vector number, so the return address the CALL pushes points at
// that number: _strayintr and _strayintrx turn it into Ureg.type and go
// on to push the rest of the Ureg.

const vectors = blk: {
    @setEvalBranchQuota(2_000_000);
    var s: []const u8 =
        \\ .text
        \\ .balign 16
        \\ .globl vectortable
        \\vectortable:
        \\
    ;
    for (0..256) |v| {
        const stub = switch (v) {
            // double fault, invalid TSS, segment not present, stack
            // exception, general protection, page fault, alignment check
            8, 10, 11, 12, 13, 14, 17 => "_strayintrx",
            else => "_strayintr",
        };
        s = s ++ std.fmt.comptimePrint(" call {s}\n .byte {d}\n", .{ stub, v });
    }
    break :blk s;
};

comptime {
    asm (vectors ++ std.fmt.comptimePrint(
            \\
            \\_strayintr:                     /* no error code pushed */
            \\ pushq %rax                     /* save AX */
            \\ movq 8(%rsp), %rax             /* vectortable PC */
            \\ jmp _intrcommon
            \\_strayintrx:                    /* error code pushed */
            \\ xchgq %rax, (%rsp)
            \\_intrcommon:
            \\ movzbq (%rax), %rax
            \\ xchgq %rax, (%rsp)
            \\ subq $24, %rsp                 /* R1[45], [DEFG]S */
            \\ movq %r14, 0(%rsp)
            \\ movq %r15, 8(%rsp)
            \\ cmpw ${[kesel]d}, 48(%rsp)     /* old CS */
            \\ je 1f
            \\ swapgs
            \\1:
            \\ pushq %r13
            \\ pushq %r12
            \\ pushq %r11
            \\ pushq %r10
            \\ pushq %r9
            \\ pushq %r8
            \\ pushq %rbp
            \\ pushq %rdi
            \\ pushq %rsi
            \\ pushq %rdx
            \\ pushq %rcx
            \\ pushq %rbx
            \\ pushq %rax
            \\ movq %rsp, %rdi                /* Ureg* */
            \\ xorl %ebp, %ebp
            \\ pushq %rsp                     /* keeps the stack 16-byte aligned */
            \\ cld
            \\ call trap
            \\ .globl noteret
            \\noteret:
            \\ popq %rax
            \\ popq %rax
            \\ popq %rbx
            \\ popq %rcx
            \\ popq %rdx
            \\ popq %rsi
            \\ popq %rdi
            \\ popq %rbp
            \\ popq %r8
            \\ popq %r9
            \\ popq %r10
            \\ popq %r11
            \\ popq %r12
            \\ popq %r13
            \\ movq 0(%rsp), %r14
            \\ movq 8(%rsp), %r15
            \\ cmpw ${[kesel]d}, 48(%rsp)
            \\ je 1f
            \\ swapgs
            \\1:
            \\ addq $40, %rsp
            \\ iretq
            \\
            \\ /*
            \\  * swtch(from, to): save the running context in Label *from
            \\  * and resume the one saved in Label *to.  Returns when some
            \\  * later swtch resumes *from.  The callee-saved registers
            \\  * live on the stack being left; a Label holds the stack
            \\  * pointer, and the return pc for the debugger's benefit.
            \\  * DIFF: replaces setlabel and gotolabel.
            \\  */
            \\ .globl swtch
            \\swtch:
            \\ pushq %rbp
            \\ pushq %rbx
            \\ pushq %r12
            \\ pushq %r13
            \\ pushq %r14
            \\ pushq %r15
            \\ movq %rsp, 0(%rdi)
            \\ movq 48(%rsp), %rax
            \\ movq %rax, 8(%rdi)
            \\ movq 0(%rsi), %rsp
            \\ popq %r15
            \\ popq %r14
            \\ popq %r13
            \\ popq %r12
            \\ popq %rbx
            \\ popq %rbp
            \\ ret
            \\
            \\ /*
            \\  * System calls arrive here by SYSCALL: the user's pc is in RCX and
            \\  * flags in R11, interrupts are off, and the stack is still the
            \\  * user's.  The call number is in RBP and the arguments are on the
            \\  * user stack.  Build a Ureg on the process's kernel stack, which
            \\  * ends where its Proc begins.
            \\  * DIFF: every register is saved, where the C saves only the ones
            \\  * it uses (R14, R15) and leaves the rest of the Ureg unset.
            \\  */
            \\ .globl syscallentry
            \\syscallentry:
            \\ swapgs
            \\ movq %gs:0, %rax                /* m-> */
            \\ movq 16(%rax), %rax             /* m->proc: top of its kernel stack */
            \\ xchgq %rax, %rsp
            \\ pushq ${[udsel]d}               /* old stack segment */
            \\ pushq %rax                      /* old sp */
            \\ pushq %r11                      /* old flags */
            \\ pushq ${[uesel]d}               /* old code segment */
            \\ pushq %rcx                      /* old ip */
            \\ pushq $0                        /* error code */
            \\ pushq $64                       /* trap number (VectorSYSCALL) */
            \\ pushq $0                        /* [DEFG]S */
            \\ pushq %r15
            \\ pushq %r14
            \\ pushq %r13
            \\ pushq %r12
            \\ pushq %r11
            \\ pushq %r10
            \\ pushq %r9
            \\ pushq %r8
            \\ pushq %rbp                      /* system call number */
            \\ pushq %rdi
            \\ pushq %rsi
            \\ pushq %rdx
            \\ pushq %rcx
            \\ pushq %rbx
            \\ pushq $0                        /* ax: the result goes here */
            \\ movq %rsp, %rdi                 /* Ureg* */
            \\ xorl %ebp, %ebp
            \\ pushq %rsp                      /* keeps the stack 16-byte aligned */
            \\ cld
            \\ call syscall
            \\ /* A note was delivered or noted() ran: restore every register. */
            \\ testq %rax, %rax
            \\ jnz noteret
            \\ .globl forkret
            \\forkret:
            \\ swapgs
            \\ movq 8(%rsp), %rax              /* return value */
            \\ movq (15*8)(%rsp), %r15
            \\ movq (14*8)(%rsp), %r14
            \\ movq (19*8)(%rsp), %rcx         /* ip */
            \\ movq (21*8)(%rsp), %r11         /* flags */
            \\ movq (22*8)(%rsp), %rsp         /* sp */
            \\ xorl %ebx, %ebx
            \\ xorl %edx, %edx
            \\ xorl %esi, %esi
            \\ xorl %edi, %edi
            \\ xorl %r8d, %r8d
            \\ xorl %r9d, %r9d
            \\ xorl %r10d, %r10d
            \\ xorl %r12d, %r12d
            \\ xorl %r13d, %r13d
            \\ xorl %ebp, %ebp
            \\ sysretq
            \\
            \\ /*
            \\  * probe(addr, write): touch one byte of user memory, for reading
            \\  * or for writing without changing it.  Returns 1, or 0 if the
            \\  * access faults and the fault cannot be resolved: the trap
            \\  * handler knows these two instructions and resumes at
            \\  * _probefail.  (The C does the same for peek.)
            \\  */
            \\ .globl probe
            \\probe:
            \\ testl %esi, %esi
            \\ jnz _probew
            \\ .globl _prober
            \\_prober:
            \\ movb (%rdi), %al
            \\ movl $1, %eax
            \\ ret
            \\ .globl _probew
            \\_probew:
            \\ lock orb $0, (%rdi)
            \\ movl $1, %eax
            \\ ret
            \\ .globl _probefail
            \\_probefail:
            \\ xorl %eax, %eax
            \\ ret
            \\
            \\ /* touser(sp): leave the kernel for the first time. */
            \\ .globl touser
            \\touser:
            \\ swapgs
            \\ xorl %r15d, %r15d
            \\ xorl %r14d, %r14d
            \\ movq ${[utentry]d}, %rcx        /* ip: UTZERO+0x28 */
            \\ movl $0x200, %r11d              /* flags */
            \\ movq %rdi, %rsp                 /* sp */
            \\ xorl %eax, %eax
            \\ xorl %ebx, %ebx
            \\ xorl %edx, %edx
            \\ xorl %esi, %esi
            \\ xorl %edi, %edi
            \\ xorl %r8d, %r8d
            \\ xorl %r9d, %r9d
            \\ xorl %r10d, %r10d
            \\ xorl %r12d, %r12d
            \\ xorl %r13d, %r13d
            \\ xorl %ebp, %ebp
            \\ sysretq
        , .{ .kesel = mem.KESEL, .udsel = mem.UDSEL, .uesel = mem.UESEL, .utentry = mem.UTZERO + 0x28 }));
}

/// 256 six-byte entries; see trapinit0.
pub extern const vectortable: [256 * 6]u8;

pub extern fn swtch(from: *dat.Label, to: *dat.Label) callconv(.c) void;

/// Touch a byte of user memory; false if it cannot be made accessible.
pub extern fn probe(addr: usize, write: bool) callconv(.c) bool;
pub extern fn _prober() callconv(.c) void;
pub extern fn _probew() callconv(.c) void;
pub extern fn _probefail() callconv(.c) void;

/// Where SYSCALL enters the kernel; its address goes in the Lstar MSR.
pub extern fn syscallentry() callconv(.c) void;
/// Return to user mode from the Ureg on the stack.  A process made by
/// rfork starts here.
pub extern fn forkret() callconv(.c) void;
/// Leave the kernel for user mode with stack pointer sp, at the entry
/// point of an executable.  Call it splhi.
pub extern fn touser(sp: usize) callconv(.c) noreturn;

/// Make `p` start in `entry` the first time it is switched to: build
/// the stack frame swtch expects to find.
/// from kprocchild in 9/pc64/trap.c
pub fn kprocchild(p: *dat.Proc, entry: *const fn () callconv(.c) noreturn) void {
    // The kernel stack ends where the Proc begins.
    const top = @intFromPtr(p);
    const frame: *[8]usize = @ptrFromInt(top - 8 * @sizeOf(usize));
    frame.* = @splat(0); // r15, r14, r13, r12, rbx, rbp ...
    frame[6] = @intFromPtr(entry); // ... swtch's return address ...
    // ... and a null return address for entry itself, which also leaves
    // the stack aligned as the ABI wants on function entry.
    p.sched.sp = @intFromPtr(frame);
    p.sched.pc = @intFromPtr(entry);
}

/// Where the AP bootstrap code is copied to and started: a page in the
/// first 64KB of physical memory.
pub const APBOOTSTRAP = 0x7000;

comptime {
    asm (std.fmt.comptimePrint(
            \\ /*
            \\  * Start an Application Processor.  This is copied to a 4KB boundary
            \\  * in the first 64KB of memory (APBOOTSTRAP).  The AP starts in
            \\  * real-mode, with
            \\  *   CS selector set to the startup memory address/16;
            \\  *   CS base set to startup memory address;
            \\  *   CS limit set to 64KB;
            \\  *   CPL and IP set to 0.
            \\  * from 9/pc64/apbootstrap.s
            \\  *
            \\  * DIFF: the code runs at APBOOTSTRAP, not where it is linked, so every
            \\  * address in it is written as AP+(label-apbootstrap).  The processor is
            \\  * handed its Mach in the first argument register; there is no Apic
            \\  * structure to pass.
            \\  */
            \\ .section .rodata
            \\ .balign 16
            \\ .globl apbootstrap
            \\ .globl apbootstrapend
            \\ .set AP, {[ap]d}
            \\apbootstrap:
            \\ .code16
            \\ ljmpw $0, $(AP + (_apstart - apbootstrap))
            \\ .balign 8
            \\_apvector:                         /* address APBOOTSTRAP+0x08 */
            \\ .quad 0
            \\_appml4:                           /* address APBOOTSTRAP+0x10 */
            \\ .quad 0
            \\_apmach:                           /* address APBOOTSTRAP+0x18 */
            \\ .quad 0
            \\_apefer:                           /* address APBOOTSTRAP+0x20 */
            \\ .quad 0x100                       /* Long Mode Enable */
            \\_apstart:
            \\ movw %cs, %ax
            \\ movw %ax, %ds                     /* initialise DS */
            \\ lgdtl AP + (_apgdtptr - apbootstrap)   /* load a basic gdt */
            \\ movl %cr0, %eax
            \\ orl $1, %eax
            \\ movl %eax, %cr0                   /* turn on protected mode */
            \\ ljmpl $(3 << 3), $(AP + (_ap32 - apbootstrap))
            \\
            \\ /*
            \\  * Enable and activate Long Mode. From the manual:
            \\  *  make sure Page Size Extentions are off, and Page Global
            \\  *  Extensions and Physical Address Extensions are on in CR4;
            \\  *  set Long Mode Enable in the Extended Feature Enable MSR;
            \\  *  set Paging Enable in CR0;
            \\  *  make an inter-segment jump to the Long Mode code.
            \\  * It's all in 32-bit mode until the jump is made.
            \\  */
            \\ .code32
            \\_ap32:
            \\ movw $(2 << 3), %ax
            \\ movw %ax, %ds
            \\ movw %ax, %es
            \\ movw %ax, %fs
            \\ movw %ax, %gs
            \\ movw %ax, %ss
            \\ movl AP + (_appml4 - apbootstrap), %eax   /* physical address of PML4 */
            \\ movl %eax, %cr3                   /* load the mmu */
            \\ movl %cr4, %eax
            \\ andl $~0x00000010, %eax           /* Page Size */
            \\ orl $0x000000A0, %eax             /* Page Global, Phys. Address */
            \\ movl %eax, %cr4
            \\ movl $0xc0000080, %ecx            /* Extended Feature Enable */
            \\ rdmsr
            \\ orl AP + (_apefer - apbootstrap), %eax
            \\ wrmsr
            \\ movl %cr0, %edx
            \\ andl $~0x6000000a, %edx
            \\ orl $0x80010000, %edx             /* Paging Enable, Write Protect */
            \\ movl %edx, %cr0
            \\ ljmpl $(1 << 3), $(AP + (_ap64 - apbootstrap))
            \\
            \\ /*
            \\  * Long mode. Welcome to 2003.
            \\  * Initialise the stack and call the startup code in _apvector,
            \\  * which is in the kernel proper and loads the real tables.
            \\  */
            \\ .code64
            \\_ap64:
            \\ xorl %eax, %eax
            \\ movw %ax, %ds
            \\ movw %ax, %es
            \\ movw %ax, %fs
            \\ movw %ax, %gs
            \\ movw %ax, %ss
            \\ movl $(AP + (_apmach - apbootstrap)), %eax
            \\ movq (%rax), %rdi                 /* Mach* */
            \\ movq %rdi, %rsp
            \\ addq ${[machsize]d}, %rsp
            \\ xorl %ebp, %ebp
            \\ pushq $0                          /* clear flags */
            \\ popfq
            \\ movl $(AP + (_apvector - apbootstrap)), %eax
            \\ movq (%rax), %rax
            \\ call *%rax
            \\1:
            \\ hlt
            \\ jmp 1b
            \\
            \\ .balign 8
            \\_apgdt:
            \\ /* null descriptor */
            \\ .long 0
            \\ .long 0
            \\ /* (KESEG) 64 bit long mode exec segment */
            \\ .long 0xFFFF
            \\ .long {[seg64]d}
            \\ /* 32 bit data segment descriptor for 4 gigabytes (PL 0) */
            \\ .long 0xFFFF
            \\ .long {[seg32d]d}
            \\ /* 32 bit exec segment descriptor for 4 gigabytes (PL 0) */
            \\ .long 0xFFFF
            \\ .long {[seg32x]d}
            \\_apgdtptr:
            \\ .word 4*8-1
            \\ .long AP + (_apgdt - apbootstrap)
            \\apbootstrapend:
            \\ .text
        , .{
            .ap = APBOOTSTRAP,
            .machsize = mem.MACHSIZE,
            .seg64 = mem.SEGL | mem.SEGG | mem.SEGP | (0xF << 16) | mem.SEGPL(0) | mem.SEGEXEC | mem.SEGR,
            .seg32d = mem.SEGG | mem.SEGB | (0xF << 16) | mem.SEGP | mem.SEGPL(0) | mem.SEGDATA | mem.SEGW,
            .seg32x = mem.SEGG | mem.SEGD | (0xF << 16) | mem.SEGP | mem.SEGPL(0) | mem.SEGEXEC | mem.SEGR,
        }));
}

/// The AP bootstrap code and where it ends.  Its first words, at fixed
/// offsets, are filled in before each processor is started.
pub extern const apbootstrap: u8;
pub extern const apbootstrapend: u8;
pub const ApVector = 0x08; // address of the startup function
pub const ApPml4 = 0x10; // physical address of the page tables to start on
pub const ApMach = 0x18; // the processor's Mach
pub const ApEfer = 0x20; // bits to set in the EFER MSR
