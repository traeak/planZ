//! Processor identification.
//! from cpuidentify and cpuidprint in 9/pc/devarch.c
//!
//! DIFF: the tables of processor names and delay-loop timings are gone,
//! along with the Pentium-era quirks.  New: the processor is checked
//! against the planZ baseline (see PLAN.md, "CPU baseline") and the
//! kernel refuses to go on without it (cpucheck).  Machine check and MTRR set-up
//! are not ported yet.

const std = @import("std");
const dat = @import("dat.zig");
const l = @import("l.zig");
const p9 = @import("../../port/print.zig");
const print = p9.print;
const panic = p9.panic;

const m = dat.m;

// cpuid leaves
const Highstdfunc = 0; // also returns vendor string
const Procsig = 1;
const Highextfunc = 0x80000000;
const Procextfeat = 0x80000001;
const Advpower = 0x80000007;

pub fn cpuidentify() void {
    const mach = m();

    var r = l.cpuid(Highstdfunc, 0);
    std.mem.writeInt(u32, mach.cpuidid[0..4], r.bx, .little);
    std.mem.writeInt(u32, mach.cpuidid[4..8], r.dx, .little);
    std.mem.writeInt(u32, mach.cpuidid[8..12], r.cx, .little);
    mach.cpuidid[12] = 0;

    r = l.cpuid(Procsig, 0);
    mach.cpuidax = r.ax;
    mach.cpuidcx = r.cx;
    mach.cpuiddx = r.dx;

    var family: u32 = r.ax >> 8 & 0xf;
    var model: u32 = r.ax >> 4 & 0xf;
    mach.cpuidstepping = @truncate(r.ax & 0xf);
    switch (family) {
        15 => {
            family += r.ax >> 20 & 0xff;
            model += (r.ax >> 16 & 0xf) << 4;
        },
        6 => model += (r.ax >> 16 & 0xf) << 4,
        else => {},
    }
    mach.cpuidfamily = @truncate(family);
    mach.cpuidmodel = @truncate(model);

    mach.havetsc = r.dx & dat.Tsc != 0;
    mach.havewatchpt8 = true; // 8-byte watchpoints are supported in Long Mode

    // Extended features: no-execute, SYSCALL, invariant TSC.
    var syscall = false;
    var invtsc = false;
    const maxext = l.cpuid(Highextfunc, 0).ax;
    if (maxext >= Procextfeat) {
        const x = l.cpuid(Procextfeat, 0);
        syscall = x.dx & (1 << 11) != 0;
        if (x.dx & (1 << 20) != 0) {
            // check and enable NX bit
            l.wrmsr(dat.Efer, l.rdmsr(dat.Efer) | (1 << 11));
            mach.havenx = true;
        }
    }
    if (maxext >= Advpower)
        invtsc = l.cpuid(Advpower, 0).dx & (1 << 8) != 0;

    mach.havesyscall = syscall;
    mach.haveinvtsc = invtsc;

    // Enable the page global bit.  We flag all kernel pages with it:
    // ``don't bother removing this from the TLB when CR3 changes.''
    var cr4 = l.getcr4();
    if (mach.cpuiddx & dat.Pge != 0) {
        cr4 |= 0x80; // page global enable bit
        mach.havepge = true;
    }
    l.putcr4(cr4);

    // Write protect applies to the kernel too.
    l.putcr0(l.getcr0() | 0x10000);

    // IA32_PAT write combining
    if (mach.cpuiddx & dat.Pat != 0) {
        const mem = @import("mem.zig");
        var pat = l.rdmsr(0x277);
        pat &= ~(@as(u64, 255) << (mem.PATWC * 8));
        pat |= @as(u64, 1) << (mem.PATWC * 8); // WC
        l.wrmsr(0x277, pat);
    }
}

/// Refuse to run on a processor without the planZ baseline.
/// DIFF: not in the C.  Apart from cpuidentify so that the bootstrap
/// processor can put the console on the screen in between: on a
/// machine with no serial port a panic before that is never seen.
pub fn cpucheck() void {
    const mach = m();
    if (!mach.havetsc) panic("cpu: no time stamp counter", .{});
    if (mach.cpuiddx & dat.Cpuapic == 0) panic("cpu: no local APIC", .{});
    if (mach.cpuidcx & dat.Xsave == 0) panic("cpu: no XSAVE; planZ needs a 2011 or later processor", .{});
    if (!mach.havenx) panic("cpu: no NX", .{});
    if (!mach.havesyscall) panic("cpu: no SYSCALL", .{});
    if (!mach.haveinvtsc) {
        // Emulators and hypervisors often hide the flag while still
        // providing a steady counter.
        if (mach.cpuidcx & dat.Hypervisor != 0 or mach.machno != 0) {
            if (mach.machno == 0)
                print("cpu%d: no invariant TSC reported (virtual machine)\n", .{mach.machno});
        } else panic("cpu: time stamp counter is not invariant", .{});
    }
}

pub fn cpuidprint() void {
    const mach = m();
    print("cpu%d: %dMHz %s family %d model %d stepping %d (AX %8.8uX CX %8.8uX DX %8.8uX)\n", .{
        mach.machno,
        mach.cpumhz,
        mach.cpuidid[0..12],
        mach.cpuidfamily,
        mach.cpuidmodel,
        mach.cpuidstepping,
        mach.cpuidax,
        mach.cpuidcx,
        mach.cpuiddx,
    });
}
