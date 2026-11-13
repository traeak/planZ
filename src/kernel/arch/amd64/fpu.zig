//! Floating point.
//! from 9/pc64/fpu.c
//!
//! The FPU belongs to user processes.  Its state is saved and restored
//! lazily: a process starts with the FPU trapping (CR0.TS); its first
//! floating point instruction traps to mathemu, which gives it a clean
//! or restored state; switching away saves the state and sets the trap
//! again.
//!
//! DIFF:
//!   - xsave only.  The CPU baseline requires XSAVE, so the FXSAVE path
//!     and the fpsave/fprestore function pointers are not ported.
//!   - No kernel floating point.  The C lets the kernel and interrupt
//!     handlers use the FPU (kfpstate, m->fpsave, FPprotected,
//!     fpukenter/fpukexit).  planZ's kernel is compiled without
//!     floating point or vector instructions, so all of that is gone and
//!     a device-not-available trap from kernel mode is a bug.
//!   - Plain XSAVE and XRSTOR; XSAVEOPT and XSAVES are optimisations
//!     left for later.

const std = @import("std");
const mem = @import("mem.zig");
const dat = @import("dat.zig");
const l = @import("l.zig");
const irq = @import("irq.zig");
const trap = @import("trap.zig");
const alloc = @import("../../port/alloc.zig");
const portdat = @import("../../port/portdat.zig");
const proc = @import("../../port/proc.zig");
const ql = @import("../../port/qlock.zig");
const pgrp = @import("../../port/pgrp.zig");
const fmt = @import("fmt");
const p9 = @import("../../port/print.zig");

const m = dat.m;
const Proc = dat.Proc;
const Ureg = dat.Ureg;
const FPalloc = dat.FPalloc;
const FPinit = dat.FPinit;
const FPactive = dat.FPactive;
const FPinactive = dat.FPinactive;
const FPnotify = dat.FPnotify;

// CR0
const MP = 1 << 1; // monitor coprocessor
const EM = 1 << 2; // emulation
const TS = 1 << 3; // task switched
const NE = 1 << 5; // numeric error reported by exception

// CR4
const OSFXSR = 1 << 9;
const OSXMMEXCPT = 1 << 10;
const OSXSAVE = 1 << 18;

// The instructions are given as bytes: the kernel is built with the
// floating point and vector features off, and the assembler follows.

fn _clts() void {
    asm volatile (".byte 0x0f, 0x06");
}

fn _stts() void {
    l.putcr0(l.getcr0() | TS);
}

fn _fninit() void {
    asm volatile (".byte 0xdb, 0xe3");
}

fn _fnclex() void {
    asm volatile (".byte 0xdb, 0xe2");
}

fn _fwait() void {
    asm volatile (".byte 0x9b");
}

/// Load x87 FPU Control Word
fn _fldcw(cw: u16) void {
    asm volatile (".byte 0xd9, 0x2f" // fldcw (%rdi)
        :
        : [p] "{rdi}" (&cw),
        : .{ .memory = true });
}

/// Load MXCSR
fn _ldmxcsr(v: u32) void {
    asm volatile (".byte 0x0f, 0xae, 0x17" // ldmxcsr (%rdi)
        :
        : [p] "{rdi}" (&v),
        : .{ .memory = true });
}

fn fpsave(s: *FPalloc) void {
    asm volatile (".byte 0x48, 0x0f, 0xae, 0x27" // xsave64 (%rdi)
        :
        : [p] "{rdi}" (s),
          [lo] "{eax}" (@as(u32, @truncate(m().xcr0))),
          [hi] "{edx}" (@as(u32, 0)),
        : .{ .memory = true });
}

fn fprestore(s: *FPalloc) void {
    asm volatile (".byte 0x48, 0x0f, 0xae, 0x2f" // xrstor64 (%rdi)
        :
        : [p] "{rdi}" (s),
          [lo] "{eax}" (@as(u32, @truncate(m().xcr0))),
          [hi] "{edx}" (@as(u32, 0)),
        : .{ .memory = true });
}

fn putxcr0(v: u64) void {
    asm volatile ("xsetbv"
        :
        : [c] "{ecx}" (@as(u32, 0)),
          [lo] "{eax}" (@as(u32, @truncate(v))),
          [hi] "{edx}" (@as(u32, @truncate(v >> 32))),
    );
}

fn fpinit() void {
    _clts();
    _fninit();
    _fwait();
    _fldcw(0x0232);
    _ldmxcsr(0x1900);
}

const mathmsg = [_][]const u8{
    "", // handled below
    "denormalized operand",
    "division by zero",
    "numeric overflow",
    "numeric underflow",
    "precision loss",
};

fn mathnote(status: u32, pc: usize, kernel: bool) void {
    // Some attention should probably be paid here to the
    // exception masks and error summary.
    var msg: []const u8 = "unknown exception";
    var i: u5 = 1;
    while (i <= 5) : (i += 1) {
        if ((@as(u32, 1) << i) & status == 0)
            continue;
        msg = mathmsg[i];
        break;
    }
    if (status & 0x01 != 0) {
        if (status & 0x40 != 0) {
            msg = if (status & 0x200 != 0) "stack overflow" else "stack underflow";
        } else msg = "invalid operation";
    }
    var note: [portdat.ERRMAX]u8 = undefined;
    const s = fmt.snprint(&note, "sys: fp: %s fppc=%#p status=0x%lux", .{ msg, pc, status });
    if (kernel)
        p9.panic("%s", .{s});

    _ = proc.postnote(dat.up(), true, s, portdat.NDebug);
}

/// math coprocessor error
fn matherror(ureg: *Ureg, _: ?*anyopaque) void {
    if (!trap.userureg(ureg))
        p9.panic("floating point error in the kernel pc=%#p", .{ureg.pc});

    const up = dat.up().?;
    if (up.fpu.fpstate != FPinactive) {
        _clts();
        fpsave(up.fpu.fpsave.?);
        up.fpu.fpstate = FPinactive;
    }
    const save = up.fpu.fpsave.?;
    mathnote(save.fsw(), save.rip(), false);
}

/// SIMD error
fn simderror(ureg: *Ureg, _: ?*anyopaque) void {
    if (!trap.userureg(ureg))
        p9.panic("SIMD error in the kernel pc=%#p", .{ureg.pc});

    const up = dat.up().?;
    if (up.fpu.fpstate != FPinactive) {
        _clts();
        fpsave(up.fpu.fpsave.?);
        up.fpu.fpstate = FPinactive;
    }
    mathnote(up.fpu.fpsave.?.mxcsr() & 0x3f, ureg.pc, false);
}

/// Turn on the FPU of this processor and leave it trapping.
/// (mathinit and fpuinit in the C.)
pub fn mathinit() void {
    const mach = m();
    if (mach.machno == 0) {
        irq.trapenable(dat.VectorCERR, matherror, null, "matherror");
        irq.trapenable(dat.VectorCNA, mathemu, null, "mathemu");
        irq.trapenable(dat.VectorSIMD, simderror, null, "simderror");
    }

    l.putcr4(l.getcr4() | OSFXSR | OSXMMEXCPT | OSXSAVE);

    // x87 and SSE state always; AVX state if the processor has it.
    mach.xcr0 = 3;
    if (mach.cpuidcx & dat.Avx != 0)
        mach.xcr0 |= 4;
    putxcr0(mach.xcr0);

    l.putcr0((l.getcr0() & ~@as(u64, EM)) | MP | NE);
    _stts();
}

fn fpalloc(link: ?*FPalloc) *FPalloc {
    while (true) {
        if (alloc.mallocalign(@sizeOf(FPalloc), mem.FPalign, 0, 0)) |p| {
            const a: *FPalloc = @ptrCast(@alignCast(p));
            // DIFF: cleared.  XSAVE writes only XSTATE_BV of the header,
            // and XRSTOR faults on anything else there but zeros.
            @memset(&a.save, 0);
            a.link = link;
            return a;
        }
        const x = l.spllo();
        if (dat.up() != null)
            pgrp.resrcwait("no memory for FPalloc") catch {};
        l.splx(x);
    }
}

fn fpfree(a: *FPalloc) void {
    alloc.free(a);
}

pub fn fpuprocnew(p: *Proc) void {
    p.fpu.fpstate = FPinit;
}

/// exec: the new program starts with no floating point state.
/// Fixed from C: the C sets FPinit and leaves the registers live and
/// CR0.TS clear if the old program had the FPU and the exec never slept
/// (a program from the kernel's own /boot: planZ's initcode, in Zig,
/// uses SSE and then execs /boot/boot).  Nothing then traps on that
/// processor, and procsave saves and sets TS only for an FPactive
/// process, so from then on every process run there shares one set of
/// registers.  Here the old state is dropped and TS set, as for an
/// exiting process.
pub fn fpuprocsetup(p: *Proc) void {
    const s = l.splhi();
    if (p.fpu.fpstate & ~@as(i32, FPnotify) == FPactive) {
        _fnclex();
        _stts();
    }
    l.splx(s);
    p.fpu.fpstate = FPinit;
    while (p.fpu.fpsave) |a| {
        p.fpu.fpsave = a.link;
        fpfree(a);
    }
}

pub fn fpuprocfork(p: *Proc) void {
    const up = dat.up().?;
    const s = l.splhi();
    var st = up.fpu.fpstate & ~@as(i32, FPnotify);
    if (st == FPactive) {
        fpsave(up.fpu.fpsave.?);
        _stts();
        up.fpu.fpstate = FPinactive | (up.fpu.fpstate & FPnotify);
        st = FPinactive;
    }
    if (st == FPinactive) {
        if (p.fpu.fpsave == null)
            p.fpu.fpsave = fpalloc(null);
        p.fpu.fpsave.?.save = up.fpu.fpsave.?.save;
        p.fpu.fpstate = FPinactive;
    }
    l.splx(s);
}

pub fn fpuprocsave(p: *Proc) void {
    if (p.state == .Moribund) {
        if (p.fpu.fpstate == FPactive) {
            _fnclex();
            _stts();
        }
        p.fpu.fpstate = FPinit;
        while (p.fpu.fpsave) |a| {
            p.fpu.fpsave = a.link;
            fpfree(a);
        }
        return;
    }
    if (p.fpu.fpstate != FPactive)
        return;
    fpsave(p.fpu.fpsave.?);
    _stts();
    p.fpu.fpstate = FPinactive;
}

/// The process is about to run a note handler: put its floating point
/// state aside.
pub fn fpunotify(p: *Proc) void {
    fpuprocsave(p);
    p.fpu.fpstate |= FPnotify;
}

/// The note handler is done.
pub fn fpunoted(p: *Proc) void {
    if (p.fpu.fpstate & FPnotify != 0) {
        p.fpu.fpstate &= ~@as(i32, FPnotify);
        return;
    }
    // The handler used the FPU: drop its state, uncover the old one.
    if (p.fpu.fpstate == FPactive) {
        _fnclex();
        _stts();
    }
    const top = p.fpu.fpsave orelse {
        p.fpu.fpstate = FPinit;
        return;
    };
    if (top.link) |o| {
        fpfree(top);
        p.fpu.fpsave = o;
        p.fpu.fpstate = FPinactive;
    } else {
        p.fpu.fpstate = FPinit;
    }
}

/// The floating point state from before the note, for the debugger.
/// Called the first time a note handler touches the FPU: gives the
/// handler a save area of its own on top of the interrupted one.
pub fn notefpsave(p: *Proc) ?*FPalloc {
    const cur = p.fpu.fpsave orelse return null;
    if (p.fpu.fpstate == (FPinactive | FPnotify)) {
        const n = fpalloc(cur);
        n.save = cur.save;
        p.fpu.fpsave = n;
        p.fpu.fpstate = FPinactive;
    }
    return p.fpu.fpsave.?.link;
}

fn fpcheck(save: *FPalloc, kernel: bool) bool {
    const status = save.fsw();
    const control = save.fcw();
    if ((status & ~control) & 0x07F != 0) {
        mathnote(status, save.rip(), kernel);
        return true;
    }
    return false;
}

/// math coprocessor emulation fault: the first floating point
/// instruction since the process got the processor.
fn mathemu(ureg: *Ureg, _: ?*anyopaque) void {
    if (!trap.userureg(ureg))
        p9.panic("floating point used in the kernel pc=%#p", .{ureg.pc});

    const up = dat.up().?;
    const st = up.fpu.fpstate;
    if (st == FPinit or st == (FPinit | FPnotify)) {
        if (up.fpu.fpsave == null)
            up.fpu.fpsave = fpalloc(null);
        up.fpu.fpstate = FPactive;
        fpinit();
    } else if (st == FPinactive or st == (FPinactive | FPnotify)) {
        if (st & FPnotify != 0) {
            _ = l.spllo();
            ql.qlock(&up.debug);
            _ = notefpsave(up);
            ql.qunlock(&up.debug);
            _ = l.splhi();
        }
        if (fpcheck(up.fpu.fpsave.?, false))
            return;
        _clts();
        fprestore(up.fpu.fpsave.?);
        up.fpu.fpstate = FPactive;
    } else if (st == FPactive) {
        _ = proc.postnote(up, true, "sys: floating point error", portdat.NDebug);
    }
}
