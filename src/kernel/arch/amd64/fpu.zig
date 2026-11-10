//! Floating point.
//! from 9/pc64/fpu.c
//!
//! DIFF: xsave only — the CPU baseline requires XSAVE, so the FXSAVE
//! path and the fpsave/fprestore function pointers are not ported.
//!
//! So far this only switches the processor's FPU support on and leaves
//! it trapping: the kernel is compiled without floating point or vector
//! instructions, so the first use will be by a user process, and until
//! then a device-not-available trap means something in the kernel is
//! using registers it must not.  Saving and restoring process state
//! arrives with user mode.

const dat = @import("dat.zig");
const l = @import("l.zig");

const m = dat.m;

// CR0
const MP = 1 << 1; // monitor coprocessor
const EM = 1 << 2; // emulation
const TS = 1 << 3; // task switched
const NE = 1 << 5; // numeric error reported by exception

// CR4
const OSFXSR = 1 << 9;
const OSXMMEXCPT = 1 << 10;
const OSXSAVE = 1 << 18;

fn putxcr0(v: u64) void {
    asm volatile ("xsetbv"
        :
        : [c] "{ecx}" (@as(u32, 0)),
          [lo] "{eax}" (@as(u32, @truncate(v))),
          [hi] "{edx}" (@as(u32, @truncate(v >> 32))),
    );
}

/// Turn on the FPU of this processor.
pub fn mathinit() void {
    const mach = m();
    l.putcr4(l.getcr4() | OSFXSR | OSXMMEXCPT | OSXSAVE);

    // x87 and SSE state always; AVX state if the processor has it.
    mach.xcr0 = 3;
    if (mach.cpuidcx & dat.Avx != 0)
        mach.xcr0 |= 4;
    putxcr0(mach.xcr0);

    l.putcr0((l.getcr0() & ~@as(u64, EM)) | MP | NE | TS);
}

/// A new process starts with no floating point state.
pub fn fpuprocnew(p: *dat.Proc) void {
    p.fpu.fpstate = dat.FPinit;
    p.fpu.kfpstate = dat.FPinit;
}
