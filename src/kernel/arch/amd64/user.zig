//! Entering and leaving user mode: the machine-dependent parts of
//! fork, exec and process set-up.
//! from 9/pc64/trap.c (execregs, forkchild, setregisters, setkernur,
//! userpc) and 9/pc64/main.c (procsetup, procfork, procsave,
//! procrestore)
//!
//! DIFF: the debug registers (Proc.dr, watchpoints) and vmx are not
//! ported, so procsetup/procsave/procrestore only deal with the FPU.

const mem = @import("mem.zig");
const dat = @import("dat.zig");
const l = @import("l.zig");
const fpu = @import("fpu.zig");
const mmu = @import("mmu.zig");
const portdat = @import("../../port/portdat.zig");

const Ureg = dat.Ureg;
const Proc = dat.Proc;

/// from /sys/include/a.out.h: S_MAGIC, HDR_MAGIC | _MAGIC(26)
pub const AOUT_MAGIC: u32 = 0x8000 | (4 * 26 * 26 + 7);

/// A process is about to start a new program.
pub fn procsetup(p: *Proc) void {
    fpu.fpuprocsetup(p);
}

/// Copy the machine state of up to its new child p.
pub fn procfork(p: *Proc) void {
    fpu.fpuprocfork(p);
}

/// p is about to lose the processor.
pub fn procsave(p: *Proc) void {
    fpu.fpuprocsave(p);

    // While this processor is in the scheduler, the process could run
    // on another processor and exit, returning the page tables to
    // the free list where they could be reallocated and overwritten.
    // When this processor eventually has to get an entry from the
    // trashed page tables it will crash.
    //
    // If there's only one processor, this can't happen.
    // You might think it would be a win not to do this in that case,
    // especially on VMware, but it turns out not to matter.
    mmu.mmuflushtlb();
}

/// p has the processor again.
pub fn procrestore(_: *Proc) void {}

/// Set the registers of the current process to start a program at
/// `entry`.  `argv` is the user address of its argument vector on the
/// new stack; the argument count goes in the word below it.  Returns
/// what exec returns to the new program: the address of its Tos.
pub fn execregs(entry: usize, argc: usize, argv: usize, tos: usize) usize {
    const sp = argv - @sizeOf(usize);
    @as(*usize, @ptrFromInt(sp)).* = argc;

    const ureg = dat.up().?.dbgreg.?;
    ureg.sp = sp;
    ureg.pc = entry;
    ureg.cs = mem.UESEL;
    ureg.ss = mem.UDSEL;
    ureg.r14 = 0; // extern user registers
    ureg.r15 = 0;
    return tos; // address of kernel/user shared data
}

/// return the userpc the last exception happened at
pub fn userpc() usize {
    return dat.up().?.dbgreg.?.pc;
}

/// This routine must save the values of registers the user is not permitted
/// to write from devproc and noted() and then restore the saved values before returning.
pub fn setregisters(ureg: *Ureg, uva: *const Ureg) void {
    const flags = ureg.flags;
    ureg.* = uva.*;
    ureg.cs = mem.UESEL;
    ureg.ss = mem.UDSEL;
    ureg.flags = (ureg.flags & 0x00ff) | (flags & 0xff00);
    ureg.pc &= mem.UADDRMASK;
}

/// Make p, a copy of the current process, return from rfork in user
/// mode with the registers in ureg and a result of 0.
pub fn forkchild(p: *Proc, ureg: *const Ureg) void {
    // The child's kernel stack, from the top: the Ureg, the word
    // forkret expects below it, then the frame swtch pops (six saved
    // registers and the address to return to).
    const top = @intFromPtr(p);
    const cureg: *Ureg = @ptrFromInt(top - @sizeOf(Ureg));
    cureg.* = ureg.*;
    cureg.ax = 0;

    const frame: *[8]usize = @ptrFromInt(@intFromPtr(cureg) - 8 * @sizeOf(usize));
    frame.* = @splat(0); // r15, r14, r13, r12, rbx, rbp ...
    frame[6] = @intFromPtr(&l.forkret); // ... swtch returns to forkret ...
    // ... which finds the Ureg one word above its stack pointer.
    p.sched.sp = @intFromPtr(frame);
    p.sched.pc = @intFromPtr(&l.forkret);
}

/// Give enough context in the ureg to produce a kernel stack for
/// a sleeping process
pub fn setkernur(ureg: *Ureg, p: *Proc) void {
    ureg.pc = p.sched.pc;
    ureg.sp = p.sched.sp + 8;
    ureg.r14 = @intFromPtr(p);
}

/// Any address will do for a stack pointer or an instruction.
pub fn validalign(_: usize) bool {
    return true;
}
