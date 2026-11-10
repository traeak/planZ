//! What the amd64 port provides to the portable kernel; see ../../arch.zig.

pub const mem = @import("mem.zig");
pub const dat = @import("dat.zig");
const l = @import("l.zig");
const mmu = @import("mmu.zig");
const memory = @import("memory.zig");
const trapmod = @import("trap.zig");
const mainmod = @import("main.zig");
const clock = @import("clock.zig");
const apic = @import("apic.zig");
const bootargs = @import("bootargs.zig");
const fpu = @import("fpu.zig");

pub const Mach = dat.Mach;
pub const Conf = dat.Conf;
pub const Confmem = dat.Confmem;
pub const Label = dat.Label;
pub const Ureg = dat.Ureg;

pub const m = dat.m;
pub const up = dat.up;
pub const MACHP = dat.MACHP;

pub const splhi = l.splhi;
pub const spllo = l.spllo;
pub const splx = l.splx;
pub const islo = l.islo;
pub const tas = l.tas;
pub const coherence = l.coherence;
pub const stop = l.stop;

pub const kaddr = mmu.kaddr;
pub const paddr = mmu.paddr;
pub const rampage = memory.rampage;
pub const dumpstack = trapmod.dumpstack;

pub const active = &dat.active;
pub const PFPU = dat.PFPU;
pub const PMMU = dat.PMMU;

pub const swtch = l.swtch;
pub const kprocchild = l.kprocchild;
pub const idlehands = l.idlehands;
pub const perfticks = l.perfticks;
pub const cycles = l.cycles;
pub const fastticks = clock.fastticks;
pub const delay = clock.delay;
pub const microdelay = clock.microdelay;
pub const timerset = apic.lapictimerset;
pub const userureg = trapmod.userureg;
pub const mmuswitch = mmu.mmuswitch;
pub const mmurelease = mmu.mmurelease;
pub const getconf = bootargs.getconf;

/// Machine-dependent part of making a process.
pub fn procnew(p: *dat.Proc) void {
    fpu.fpuprocnew(p);
}

/// Called when `p` gives up and regains the processor.
/// DIFF: nothing to save until processes have FPU and debug register state.
pub fn procsave(_: *dat.Proc) void {}
pub fn procrestore(_: *dat.Proc) void {}

/// The user pc of a process stopped in the kernel, for the process dump.
pub fn dbgpc(p: *dat.Proc) usize {
    return if (p.dbgreg) |u| u.pc else 0;
}

pub const _start = l._start;
pub const main = mainmod.main;
pub const trap = trapmod.trap;
