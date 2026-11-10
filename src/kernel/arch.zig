//! The architecture the kernel is being built for.  Portable code
//! imports this and nothing under arch/.

const builtin = @import("builtin");

const impl = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/amd64/amd64.zig"),
    // Not ports: see arch/stub/stub.zig.
    .aarch64, .riscv64 => @import("arch/stub/stub.zig"),
    else => @compileError("planZ: unsupported architecture"),
};

pub const mem = impl.mem;

pub const Mach = impl.Mach;
pub const Conf = impl.Conf;
pub const Confmem = impl.Confmem;
pub const Label = impl.Label;
pub const Ureg = impl.Ureg;

pub const m = impl.m;
pub const up = impl.up;
pub const MACHP = impl.MACHP;

/// Global configuration, filled in by confinit.
pub const conf = &impl.dat.conf;

pub const splhi = impl.splhi;
pub const spllo = impl.spllo;
pub const splx = impl.splx;
pub const islo = impl.islo;
pub const tas = impl.tas;
pub const coherence = impl.coherence;
/// Stop this processor for good, interrupts off.
pub const stop = impl.stop;

/// Kernel virtual address of a physical address, and back.
pub const kaddr = impl.kaddr;
pub const paddr = impl.paddr;

/// A page of zeroed memory for the kernel's own tables, usable before
/// the allocators are up.
pub const rampage = impl.rampage;

/// Print a stack trace of the caller.
pub const dumpstack = impl.dumpstack;

pub const active = impl.active;

/// Per-process machine state, embedded in Proc.
pub const PFPU = impl.PFPU;
pub const PMMU = impl.PMMU;

/// swtch(from, to) saves the running context in *from and resumes the
/// one in *to; it returns when a later swtch resumes *from.
pub const swtch = impl.swtch;
/// Arrange for a new process to start in the given function.
pub const kprocchild = impl.kprocchild;
pub const procnew = impl.procnew;
pub const procsave = impl.procsave;
pub const procrestore = impl.procrestore;
pub const mmuswitch = impl.mmuswitch;
pub const mmurelease = impl.mmurelease;
pub const userureg = impl.userureg;
pub const dbgpc = impl.dbgpc;

/// Wait for an interrupt unless *nrdy is non-zero.
pub const idlehands = impl.idlehands;

pub const cycles = impl.cycles;
pub const perfticks = impl.perfticks;
/// The fast clock, and optionally its rate in Hz.
pub const fastticks = impl.fastticks;
/// Ask for the timer interrupt when the fast clock reaches a value.
pub const timerset = impl.timerset;
pub const delay = impl.delay;
pub const microdelay = impl.microdelay;

/// A setting from plan9.ini, or null.
pub const getconf = impl.getconf;

/// The kernel's entry points, named in kernel.zig.
pub const _start = impl._start;
pub const main = impl.main;
pub const trap = impl.trap;
