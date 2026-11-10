//! The architecture the kernel is being built for.  Portable code
//! imports this and nothing under arch/.

const builtin = @import("builtin");

const impl = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/amd64/amd64.zig"),
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

/// Kernel virtual address of a physical address, and back.
pub const kaddr = impl.kaddr;
pub const paddr = impl.paddr;

/// A page of zeroed memory for the kernel's own tables, usable before
/// the allocators are up.
pub const rampage = impl.rampage;

/// Print a stack trace of the caller.
pub const dumpstack = impl.dumpstack;

/// The kernel's entry points, named in kernel.zig.
pub const _start = impl._start;
pub const main = impl.main;
pub const trap = impl.trap;
