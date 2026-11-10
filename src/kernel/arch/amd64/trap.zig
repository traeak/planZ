//! Traps: the interrupt descriptor table, dispatch, and the dumps
//! printed when the kernel itself faults.
//! from 9/pc64/trap.c
//!
//! DIFF: kernel mode only so far.  User traps, notes, system calls and
//! the debug registers arrive with user mode; the places they attach
//! are marked.

const mem = @import("mem.zig");
const dat = @import("dat.zig");
const l = @import("l.zig");
const irq = @import("irq.zig");
const proc = @import("../../port/proc.zig");
const p9 = @import("../../port/print.zig");
const print = p9.print;
const iprint = p9.iprint;
const panic = p9.panic;

const Ureg = dat.Ureg;
const Segdesc = dat.Segdesc;
const m = dat.m;
const up = dat.up;

/// DIFF: in the kernel's data, not at the fixed address IDTADDR.
var idt: [512]Segdesc align(16) = @splat(.{});

/// End of kernel text, from the linker script.
extern const etext: u8;

pub fn trapinit0() void {
    var vaddr = @intFromPtr(&l.vectortable);
    var v: usize = 0;
    while (v < 256) : (v += 1) {
        var d1: u32 = @as(u32, @truncate(vaddr & 0xFFFF0000)) | mem.SEGP;
        switch (v) {
            dat.VectorBPT, dat.VectorSYSCALL => d1 |= mem.SEGPL(3) | mem.SEGIG,
            else => d1 |= mem.SEGPL(0) | mem.SEGIG,
        }
        idt[2 * v] = .{ .d0 = @as(u32, @truncate(vaddr & 0xFFFF)) | (@as(u32, mem.KESEL) << 16), .d1 = d1 };
        idt[2 * v + 1] = .{ .d0 = @truncate(vaddr >> 32), .d1 = 0 };
        vaddr += 6;
    }
    idtload();
}

/// Each processor loads the one table.
pub fn idtload() void {
    l.lidt(@sizeOf(@TypeOf(idt)) - 1, @intFromPtr(&idt));
}

pub fn trapinit() void {
    // Special traps.
    // Syscall() is called directly without going through trap().
    irq.trapenable(dat.VectorPF, faultamd64, null, "faultamd64");
    irq.trapenable(dat.Vector2F, doublefault, null, "doublefault");
    irq.trapenable(dat.Vector15, unexpected, null, "unexpected");
}

const excname = [32][]const u8{
    "divide error",
    "debug exception",
    "nonmaskable interrupt",
    "breakpoint",
    "overflow",
    "bounds check",
    "invalid opcode",
    "coprocessor not available",
    "double fault",
    "coprocessor segment overrun",
    "invalid TSS",
    "segment not present",
    "stack exception",
    "general protection violation",
    "page fault",
    "15 (reserved)",
    "coprocessor error",
    "alignment check",
    "machine check",
    "simd error",
    "20 (reserved)",
    "21 (reserved)",
    "22 (reserved)",
    "23 (reserved)",
    "24 (reserved)",
    "25 (reserved)",
    "26 (reserved)",
    "27 (reserved)",
    "28 (reserved)",
    "29 (reserved)",
    "30 (reserved)",
    "31 (reserved)",
};

pub fn userureg(ureg: *const Ureg) bool {
    return ureg.cs & 0xFFFF == mem.UESEL;
}

/// All traps and interrupts come here from the stubs in l.zig.
pub fn trap(ureg: *Ureg) callconv(.c) void {
    const vno: usize = @intCast(ureg.type & 0xff);
    const user = proc.kenter(ureg);
    // DIFF: fpukenter and the user half (usertrap, notes, kexit)
    // attach here.
    if (irq.irqhandled(ureg, vno) == 0) {
        if (!user) {
            // early fault before trapinit()
            if (vno == dat.VectorPF)
                faultamd64(ureg, null);
        }
        dumpregs(ureg);
        if (!user) {
            ureg.sp = @intFromPtr(&ureg.sp);
            _dumpstack(ureg);
        }
        if (vno < excname.len)
            panic("%s", .{excname[vno]});
        panic("unknown trap/intr: %d", .{vno});
    }
    _ = l.splhi();
}

pub fn dumpregs(ureg: *const Ureg) void {
    const mach = m();
    if (up()) |p|
        iprint("cpu%d: registers for %s %lud\n", .{ mach.machno, p.text, p.pid })
    else
        iprint("cpu%d: registers for kernel\n", .{mach.machno});

    iprint("  AX %.16lluX  BX %.16lluX  CX %.16lluX\n", .{ ureg.ax, ureg.bx, ureg.cx });
    iprint("  DX %.16lluX  SI %.16lluX  DI %.16lluX\n", .{ ureg.dx, ureg.si, ureg.di });
    iprint("  BP %.16lluX  R8 %.16lluX  R9 %.16lluX\n", .{ ureg.bp, ureg.r8, ureg.r9 });
    iprint(" R10 %.16lluX R11 %.16lluX R12 %.16lluX\n", .{ ureg.r10, ureg.r11, ureg.r12 });
    iprint(" R13 %.16lluX R14 %.16lluX R15 %.16lluX\n", .{ ureg.r13, ureg.r14, ureg.r15 });
    iprint("  CS %.4lluX   SS %.4lluX    PC %.16lluX  SP %.16lluX\n", .{ ureg.cs & 0xffff, ureg.ss & 0xffff, ureg.pc, ureg.sp });
    iprint("TYPE %.2lluX  ERROR %.4lluX FLAGS %.8lluX\n", .{ ureg.type & 0xff, ureg.@"error" & 0xffff, ureg.flags & 0xffffffff });

    // Processor control registers.
    iprint(" CR0 %8.8llux CR2 %16.16llux CR3 %16.16llux", .{ l.getcr0(), l.getcr2(), l.getcr3() });
    iprint(" CR4 %16.16llux\n", .{l.getcr4()});
    iprint("  ur %#p up %#p\n", .{ ureg, up() });
}

/// Print the words on the current stack that look like return
/// addresses, in the form the ktrace command reads.
fn _dumpstack(ureg: *const Ureg) void {
    var here: usize = undefined;
    const sp = @intFromPtr(&here);
    const mach = @intFromPtr(m());

    iprint("dumpstack\n", .{});
    iprint("ktrace /kernel/path %#p %#p <<EOF\n", .{ ureg.pc, ureg.sp });
    var estack: usize = undefined;
    const p = @intFromPtr(up());
    if (p != 0 and sp >= p - mem.KSTACK and sp <= p)
        estack = p
    else if (sp >= mach and sp <= mach + mem.MACHSIZE)
        estack = mach + mem.MACHSIZE
    else
        return;
    iprint("estackx %p\n", .{estack});

    var i: usize = 0;
    var a = sp & ~@as(usize, 7);
    while (a < estack) : (a += @sizeOf(usize)) {
        const v = @as(*const usize, @ptrFromInt(a)).*;
        if ((mem.KTZERO < v and v < @intFromPtr(&etext)) or estack - a < 32) {
            iprint("%.8lux=%.8lux ", .{ a, v });
            i += 1;
        }
        if (i == 4) {
            i = 0;
            iprint("\n", .{});
        }
    }
    if (i != 0) iprint("\n", .{});
    iprint("EOF\n", .{});
}

/// Fill in enough of Ureg to get a stack trace, and call a function.
pub fn dumpstack() void {
    var ureg: Ureg = undefined;
    ureg.pc = @returnAddress();
    ureg.sp = @frameAddress();
    _dumpstack(&ureg);
}

fn doublefault(_: *Ureg, _: ?*anyopaque) void {
    panic("double fault", .{});
}

fn unexpected(ureg: *Ureg, _: ?*anyopaque) void {
    print("unexpected trap %llud; ignoring\n", .{ureg.type});
}

fn faultamd64(ureg: *Ureg, _: ?*anyopaque) void {
    const addr = l.getcr2();
    const read = ureg.@"error" & 2 == 0;

    // DIFF: no user memory yet, so every fault is the kernel's own and
    // fatal; fault() and the user half attach here.
    dumpregs(ureg);
    if (addr >= mem.USTKTOP)
        panic("kernel fault: bad address pc=%#p addr=%#p", .{ ureg.pc, addr });
    panic("kernel fault: %s addr=%#p pc=%#p", .{ if (read) "read" else "write", addr, ureg.pc });
}
