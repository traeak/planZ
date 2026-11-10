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

// User address spaces.

/// Enter the mapping va -> pa for the current process; the low bits of
/// pa are the PTE flags from mem (PTEVALID, PTEWRITE ...).
pub const putmmu = impl.putmmu;
/// Throw away the current process's page tables; faults rebuild them.
pub const flushmmu = impl.flushmmu;
/// Complain if va is mapped to something other than pa.
pub const checkmmu = impl.checkmmu;
/// A kernel address for the contents of a page, and its release.
pub const kmap = impl.kmap;
pub const kunmap = impl.kunmap;
/// Touch one byte at a user address, for writing if `write` (without
/// changing it).  False if the access faults and cannot be resolved.
pub const probe = impl.probe;
/// The PTE bit that forbids execution, or 0 if the processor has none.
pub const PTENOEXEC = impl.PTENOEXEC;
/// Per-page instruction-cache flush state (see Portability rules).
pub const Txtflush = impl.Txtflush;
pub const inittxtflush = impl.inittxtflush;
pub const settxtflush = impl.settxtflush;

// Processes entering and leaving user mode.

/// Magic number of this architecture's executables.
pub const AOUT_MAGIC = impl.AOUT_MAGIC;
/// Reset the machine state of a process that is about to run a new
/// program.
pub const procsetup = impl.procsetup;
/// Copy machine state from up to a new process.
pub const procfork = impl.procfork;
/// Make p return from rfork in user mode with the registers in ureg
/// and result 0.
pub const forkchild = impl.forkchild;
/// Set the user registers to start a new program; returns the value
/// exec gives back (the address of the Tos).
pub const execregs = impl.execregs;
/// The user pc of the current process's last trap.
pub const userpc = impl.userpc;
/// Copy user-supplied registers over ureg, keeping what a user may not
/// change.
pub const setregisters = impl.setregisters;
/// Fill ureg with enough to trace a sleeping process's kernel stack.
pub const setkernur = impl.setkernur;
/// Is this a valid address for a stack pointer or instruction?
pub const validalign = impl.validalign;
/// Leave the kernel for user mode for the first time.
pub const touser = impl.touser;
/// Arrange for the current process to run its note handler with msg:
/// push the registers and the note on its stack and redirect ureg.
/// Returns where the saved registers went, or null if the stack is bad.
pub const notify = impl.notify;
/// Restore the registers saved by notify from the user's copy; false if
/// they are not acceptable.
pub const noted = impl.noted;
/// Put a process's floating point state aside for a note handler, and
/// bring it back.
pub const fpunotify = impl.fpunotify;
pub const fpunoted = impl.fpunoted;

/// The kernel's entry points, named in kernel.zig.
pub const _start = impl._start;
pub const main = impl.main;
pub const trap = impl.trap;
pub const syscall = impl.syscall;
